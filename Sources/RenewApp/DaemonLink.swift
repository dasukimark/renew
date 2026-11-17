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

    enum RecordResult {
        case stored
        /// renewd answered but refused the batch; sending it again won't help.
        case rejected(String)
        /// renewd couldn't be reached; try again later.
        case unreachable
    }

    /// Sends finished visits to the activity log. `completion` runs on the
    /// main thread.
    func record(_ events: [ActivityEvent], completion: @escaping (RecordResult) -> Void) {
        queue.async {
            let result: RecordResult
            do {
                let r = try DaemonClient.send(Request(cmd: .recordActivity, events: events), timeout: 5)
                result = r.ok ? .stored : .rejected(r.error ?? "refused")
            } catch {
                result = .unreachable
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

/// The Activity setting renewd last reported, so a relaunched app keeps
/// recording while renewd is unreachable. (The file name predates the split
/// from the Monitor; the old combined settings read fine as this.)
enum ActivityCache {
    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Renew/agent-monitoring.json")
    }

    static func load() -> ActivitySettings {
        guard let data = try? Data(contentsOf: url),
              let a = try? Wire.decoder.decode(ActivitySettings.self, from: data) else { return .off }
        return a
    }

    static func save(_ m: ActivitySettings) {
        guard let data = try? Wire.encoder.encode(m) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
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

/// The last protections renewd reported, so a relaunched app enforces them
/// while renewd is unreachable, just as it keeps enforcing the cached session.
enum ProtectionsCache {
    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Renew/agent-protections.json")
    }

    static func load() -> Protections {
        guard let data = try? Data(contentsOf: url),
              let p = try? Wire.decoder.decode(Protections.self, from: data) else { return .off }
        return p
    }

    static func save(_ p: Protections) {
        guard let data = try? Wire.encoder.encode(p) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
