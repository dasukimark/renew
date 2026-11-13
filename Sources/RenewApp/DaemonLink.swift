import Foundation
import RenewShared

/// Talks to renewd off the main thread.
final class DaemonLink {
    private let queue = DispatchQueue(label: "agent.daemon-link")

    /// Sends a heartbeat/permission report; the reply carries the session.
    /// `completion` runs on the main thread with nil if renewd is unreachable.
    func report(_ report: AgentReport, completion: @escaping (Status?) -> Void) {
        queue.async {
            let response = try? DaemonClient.send(Request(cmd: .report, report: report), timeout: 3)
            let status = (response?.ok ?? false) ? response?.status : nil
            DispatchQueue.main.async { completion(status) }
        }
    }
}

/// Last session seen from renewd, so a restarted agent keeps enforcing even
/// if the daemon is briefly unreachable.
enum SessionCache {
    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Renew/agent-session.json")
    }

    static func load() -> SessionInfo? {
        guard let data = try? Data(contentsOf: url),
              let s = try? Wire.decoder.decode(SessionInfo.self, from: data),
              s.isActive() else { return nil }
        return s
    }

    static func save(_ session: SessionInfo?) {
        guard let session else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? Wire.encoder.encode(session) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
