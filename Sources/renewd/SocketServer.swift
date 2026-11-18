import Foundation
import RenewShared

/// Accepts one JSON request per connection on a world-writable Unix socket.
/// The caller's uid and audit token come from the kernel, not the payload.
final class SocketServer {
    typealias Handler = (Request, uid_t, _ auditToken: Data?) -> Response

    private let path: String
    private let handler: Handler
    private let lock = NSLock()
    private let acceptQueue = DispatchQueue(label: "renewd.accept")
    /// Owns the listening socket; cancelling it closes the fd (see cancel handler),
    /// so a rebind never leaves a thread blocked on a closed or reused descriptor.
    private var source: DispatchSourceRead?

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        source?.cancel()
        source = nil

        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw SocketError.setup(String(cString: strerror(errno))) }
        guard var addr = makeUnixAddress(path) else { close(s); throw SocketError.setup("path too long") }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let msg = String(cString: strerror(errno))
            close(s)
            throw SocketError.setup("bind \(path): \(msg)")
        }
        chmod(path, 0o666)
        guard listen(s, 32) == 0 else {
            close(s)
            throw SocketError.setup("listen: \(String(cString: strerror(errno)))")
        }
        // Non-blocking, so the accept loop below drains pending clients and returns.
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: acceptQueue)
        src.setEventHandler { [weak self] in self?.acceptPending(s) }
        src.setCancelHandler { close(s) }
        src.resume()
        source = src
    }

    /// Re-creates the socket if someone deleted it.
    func ensureBound() {
        var st = stat()
        if lstat(path, &st) != 0 || (st.st_mode & S_IFMT) != S_IFSOCK {
            log("control socket missing; re-binding")
            try? start()
        }
    }

    private func acceptPending(_ listenFD: Int32) {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return // EAGAIN: nothing more pending
            }
            // Accepted sockets inherit O_NONBLOCK on Darwin; serve() uses blocking I/O.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            DispatchQueue.global().async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        setSocketTimeouts(client, seconds: 5)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0 else { return }

        let response: Response
        do {
            let line = try readLine(client, max: 1 << 20)
            let request = try Wire.decoder.decode(Request.self, from: line)
            response = handler(request, uid, PeerCheck.auditToken(of: client))
        } catch {
            response = Response(ok: false, error: "bad request: \(error)")
        }
        guard var data = try? Wire.encoder.encode(response) else { return }
        data.append(0x0A)
        try? writeAll(client, data)
    }
}
