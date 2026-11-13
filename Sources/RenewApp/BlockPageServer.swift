import Foundation
import Network
import RenewShared

/// Serves the block page on 127.0.0.1 only.
final class BlockPageServer {
    let port: UInt16
    private let queue = DispatchQueue(label: "agent.http")
    private var listener: NWListener?
    private let lock = NSLock()
    private var endsAt: Date?
    private let template: String

    init(port: UInt16) {
        self.port = port
        if let url = Bundle.main.url(forResource: "blocked", withExtension: "html"),
           let html = try? String(contentsOf: url, encoding: .utf8) {
            template = html
        } else {
            template = Self.fallbackTemplate
        }
    }

    func update(endsAt: Date?) {
        lock.lock()
        self.endsAt = endsAt
        lock.unlock()
    }

    /// `http://127.0.0.1:<port>/blocked?u=<url>&r=<rule>`
    func blockURL(for blocked: String, rule: Rule) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#/:")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return "http://127.0.0.1:\(port)/blocked?u=\(enc(blocked))&r=\(enc(rule.description))"
    }

    func start() {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] c in self?.handle(c) }
            l.stateUpdateHandler = { [weak self] state in
                if case .failed(let err) = state {
                    log("block page server failed: \(err); retrying")
                    self?.listener?.cancel()
                    self?.queue.asyncAfter(deadline: .now() + 2) { self?.start() }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            log("block page server couldn't start on port \(port): \(error)")
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
        }
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { c.cancel(); return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let firstLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
            let parts = firstLine.split(separator: " ")
            let target = parts.count >= 2 ? String(parts[1]) : "/"
            let (status, type, body) = self.respond(target)
            let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
                + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
            c.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
    }

    func respond(_ target: String) -> (String, String, Data) {
        let comps = URLComponents(string: "http://127.0.0.1" + target)
        guard let path = comps?.path, path == "/blocked" || path == "/" else {
            return ("404 Not Found", "text/plain; charset=utf-8", Data("not found".utf8))
        }
        let items = comps?.queryItems ?? []
        let blocked = items.first { $0.name == "u" }?.value ?? ""
        let rule = items.first { $0.name == "r" }?.value ?? ""
        let host = NormalizedURL(blocked)?.host ?? blocked

        lock.lock()
        let ends = endsAt
        lock.unlock()
        let endsMs = ends.map { String(Int64($0.timeIntervalSince1970 * 1000)) } ?? "0"

        let html = template
            .replacingOccurrences(of: "{{BLOCKED_HOST}}", with: Self.escape(host.isEmpty ? "This site" : host))
            .replacingOccurrences(of: "{{BLOCKED_URL}}", with: Self.escape(blocked))
            .replacingOccurrences(of: "{{RULE}}", with: Self.escape(rule))
            .replacingOccurrences(of: "{{ENDS_AT_MS}}", with: endsMs)
        return ("200 OK", "text/html; charset=utf-8", Data(html.utf8))
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static let fallbackTemplate = """
    <!doctype html><html><head><meta charset="utf-8"><title>Blocked</title></head>
    <body style="font-family:-apple-system;background:#111;color:#eee;display:grid;place-items:center;height:100vh;margin:0">
    <div style="text-align:center"><h1>{{BLOCKED_HOST}} is blocked</h1><p>Blocked by Renew ({{RULE}}).</p></div>
    </body></html>
    """
}
