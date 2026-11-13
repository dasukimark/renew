import Foundation

public enum SocketError: Error, CustomStringConvertible {
    case setup(String)
    case connect(String)
    case io(String)
    case decode(String)

    public var description: String {
        switch self {
        case .setup(let s): return "socket setup failed: \(s)"
        case .connect(let s): return "can't reach renewd (\(s)). Is Renew installed and running?"
        case .io(let s): return "socket I/O failed: \(s)"
        case .decode(let s): return "bad reply from renewd: \(s)"
        }
    }
}

public func makeUnixAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        buf.copyBytes(from: bytes)
        buf[bytes.count] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return addr
}

public func setSocketTimeouts(_ fd: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    let size = socklen_t(MemoryLayout<timeval>.size)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}

public func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
        var offset = 0
        while offset < buf.count {
            let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketError.io(String(cString: strerror(errno)))
            }
            offset += n
        }
    }
}

/// Reads up to the first newline (exclusive). Fails past `max` bytes.
public func readLine(_ fd: Int32, max: Int = 1 << 20) throws -> Data {
    var out = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while out.count < max {
        let n = read(fd, &chunk, chunk.count)
        if n < 0 {
            if errno == EINTR { continue }
            throw SocketError.io(String(cString: strerror(errno)))
        }
        if n == 0 { break }
        if let nl = chunk[0..<n].firstIndex(of: 0x0A) {
            out.append(contentsOf: chunk[0..<nl])
            return out
        }
        out.append(contentsOf: chunk[0..<n])
    }
    if out.isEmpty { throw SocketError.io("connection closed") }
    return out
}

public enum DaemonClient {
    public static func send(_ request: Request, path: String = Paths.socketPath, timeout: Int = 5) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.setup(String(cString: strerror(errno))) }
        defer { close(fd) }
        setSocketTimeouts(fd, seconds: timeout)

        guard var addr = makeUnixAddress(path) else { throw SocketError.setup("socket path too long") }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw SocketError.connect(String(cString: strerror(errno))) }

        var payload = try Wire.encoder.encode(request)
        payload.append(0x0A)
        try writeAll(fd, payload)
        let line = try readLine(fd)
        do {
            return try Wire.decoder.decode(Response.self, from: line)
        } catch {
            throw SocketError.decode(String(describing: error))
        }
    }
}
