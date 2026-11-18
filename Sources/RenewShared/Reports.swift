import Foundation

/// Email reports for an accountability partner. renewd POSTs a `Report` to
/// your report server (see `server/reports/`), which emails it to the
/// partner's address set here. Like the rest of the destination, the address
/// can only be changed between sessions, and the old partner is told.
///
/// The server is normally the built-in one (`ReportServer`, installed with
/// Renew), so only the partner's address is needed; `url` and `token` are
/// set only for a different server.
///
/// A report names the site, the page title, why it was flagged, when and
/// for how long. It never carries the full address.
public struct ReportDestination: Codable, Equatable, Sendable {
    /// Where the server emails reports.
    public var partnerEmail: String
    /// A different report server, or nil for the built-in one.
    public var url: String?
    /// Sent as `Authorization: Bearer <token>`; nil with `url`.
    public var token: String?

    public init(partnerEmail: String, url: String? = nil, token: String? = nil) {
        self.partnerEmail = partnerEmail
        self.url = url
        self.token = token
    }

    public static let maxTokenLength = 512

    public var usesBuiltInServer: Bool { url == nil }

    /// The server to send to: `url` and `token`, or the built-in server's.
    public func server(builtIn: ReportServer?) -> ReportServer? {
        if let url, let token { return ReportServer(url: url, token: token) }
        return builtIn
    }

    /// A plausible single address, trimmed and lowercased, or nil. The
    /// server checks it again.
    public static func normalizeEmail(_ raw: String) -> String? {
        let e = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = e.split(separator: "@", omittingEmptySubsequences: false)
        guard e.count <= 254, parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              e.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7f && !"<>(),;:\\\"[]".unicodeScalars.contains($0) })
        else { return nil }
        return e
    }

    /// A usable destination, trimmed, or nil. Without a URL it uses the
    /// built-in server; with one it needs a token too.
    public static func normalize(partnerEmail rawEmail: String, url rawURL: String? = nil,
                                 token rawToken: String? = nil) -> ReportDestination? {
        guard let email = normalizeEmail(rawEmail) else { return nil }
        let urlText = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !urlText.isEmpty else { return ReportDestination(partnerEmail: email) }
        guard let server = ReportServer.normalize(url: urlText, token: rawToken ?? "") else { return nil }
        return ReportDestination(partnerEmail: email, url: server.url, token: server.token)
    }
}

/// A report server's address and token. The built-in one is set up by
/// `server/reports/configure-mac.sh` and copied by the installer into
/// renewd's root-only folder (`Paths.reportServerFile`).
public struct ReportServer: Codable, Equatable, Sendable {
    public var url: String
    public var token: String

    public init(url: String, token: String) {
        self.url = url
        self.token = token
    }

    /// An https URL (the token travels with every report; plain http only
    /// to this Mac, for testing) and a non-empty token without spaces.
    public static func normalize(url rawURL: String, token rawToken: String) -> ReportServer? {
        guard let url = Alerts.normalize(rawURL), let parsed = URL(string: url) else { return nil }
        let local = ["localhost", "127.0.0.1", "::1"].contains(parsed.host?.lowercased() ?? "")
        guard parsed.scheme?.lowercased() == "https" || local else { return nil }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.count <= ReportDestination.maxTokenLength,
              token.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7f })
        else { return nil }
        return ReportServer(url: url, token: token)
    }

    /// The built-in server, if one is installed and valid.
    public static func builtIn(path: String = Paths.reportServerFile) -> ReportServer? {
        guard let data = FileManager.default.contents(atPath: path),
              let raw = try? JSONDecoder().decode(ReportServer.self, from: data) else { return nil }
        return normalize(url: raw.url, token: raw.token)
    }
}

/// One report, as POSTed to the report server.
public struct Report: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case flags, change, test }

    public struct Flag: Codable, Equatable, Sendable {
        public var host: String
        /// The page title, shortened to `maxTitleLength`.
        public var title: String
        public var reasons: [String]
        public var start: Date
        public var seconds: Int

        public static let maxTitleLength = 200

        public init(host: String, title: String = "", reasons: [String], start: Date, seconds: Int) {
            self.host = host
            self.title = title
            self.reasons = reasons
            self.start = start
            self.seconds = seconds
        }
    }

    public var id: UUID
    public var mac: String
    public var user: String
    public var kind: Kind
    public var sentAt: Date
    public var flags: [Flag]
    /// Flagged visits left out because the report was full.
    public var omitted: Int
    public var changes: [String]
    /// The partner's address, filled in when sent (from the destination).
    public var to: String?
    /// The Mac's time zone (e.g. `America/New_York`), so the email shows its times.
    public var timeZone: String?

    public static let maxFlags = 200
    /// Reports are trimmed to stay under this many bytes of JSON (the server
    /// takes up to 256 KB).
    public static let maxBytes = 192 * 1024

    public init(id: UUID = UUID(), mac: String, user: String, kind: Kind, sentAt: Date,
                flags: [Flag] = [], omitted: Int = 0, changes: [String] = []) {
        self.id = id
        self.mac = mac
        self.user = user
        self.kind = kind
        self.sentAt = sentAt
        self.flags = flags
        self.omitted = omitted
        self.changes = changes
    }

    /// A `flags` report for `monitorFlags`, oldest first, capped at
    /// `maxFlags` (the rest are counted in `omitted`). Only the host, title,
    /// reasons, start and length are kept; the URL is dropped.
    public static func flags(from monitorFlags: [MonitorFlag], mac: String, user: String, at now: Date,
                             maxBytes: Int = Report.maxBytes) -> Report {
        let sorted = monitorFlags.sorted { $0.start < $1.start }
        let kept = sorted.prefix(maxFlags).map { f in
            Flag(host: f.host, title: shortened(f.title), reasons: reasons(for: f.flags), start: f.start,
                 seconds: max(0, Int(f.duration.rounded())))
        }
        var report = Report(mac: mac, user: user, kind: .flags, sentAt: now, flags: Array(kept),
                            omitted: sorted.count - kept.count)
        // Long titles in many scripts can push a full report past the
        // server's limit; drop visits from the end until it fits.
        while report.flags.count > 1, let size = try? encoder.encode(report).count, size > maxBytes {
            let drop = max(1, report.flags.count / 10)
            report.flags.removeLast(drop)
            report.omitted += drop
        }
        return report
    }

    static func shortened(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > Flag.maxTitleLength ? String(t.prefix(Flag.maxTitleLength - 1)) + "…" : t
    }

    /// Readable reasons, without repeats.
    public static func reasons(for flags: [ActivityFlag]) -> [String] {
        var out: [String] = []
        for f in flags {
            let text: String
            switch f.kind {
            case .domain:
                switch f.list {
                case MonitorSettings.explicitListName: text = "explicit site"
                case MonitorSettings.customListName, nil: text = "watched site"
                case let list?: text = "on list '\(list)'"
                }
            case .term:
                text = "word: \(f.match)"
            }
            if !out.contains(text) { out.append(text) }
        }
        return out
    }

    /// The JSON the server expects: ISO 8601 dates, sorted keys.
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension MonitorSettings {
    /// What changed from `self` to `new` that flags less, as sentences for a
    /// report: the Monitor turned off, watched lists removed, explicit words
    /// turned off, sites or words removed. Adding rules isn't listed, and
    /// neither are edits to a watched blocklist's rules (`listRules`), which
    /// come from editing the blocklist.
    public func loosenings(to new: MonitorSettings) -> [String] {
        var out: [String] = []
        if enabled && !new.enabled { out.append("The Monitor was turned off.") }
        for list in watchLists where !new.watchLists.contains(list) {
            out.append(list == MonitorSettings.explicitListName
                       ? "Explicit sites are no longer watched."
                       : "The list '\(list)' is no longer watched.")
        }
        if flagExplicitTerms && !new.flagExplicitTerms { out.append("Explicit words in page titles are no longer watched.") }
        let sites = customDomains.filter { !new.customDomains.contains($0) }
        if !sites.isEmpty { out.append("Watched sites removed: \(Self.listed(sites)).") }
        let words = customTerms.filter { !new.customTerms.contains($0) }
        if !words.isEmpty { out.append("Watched words removed: \(Self.listed(words)).") }
        return out
    }

    /// The first `limit` items, then how many more, so a report sentence
    /// stays short enough to show in full.
    static func listed(_ items: [String], limit: Int = 15) -> String {
        let shown = items.prefix(limit).joined(separator: ", ")
        return items.count > limit ? "\(shown) and \(items.count - limit) more" : shown
    }
}

/// Who a report goes to and through which server, fully resolved.
public struct ReportTarget: Codable, Equatable, Sendable {
    public var partnerEmail: String
    public var server: ReportServer

    public init(partnerEmail: String, server: ReportServer) {
        self.partnerEmail = partnerEmail
        self.server = server
    }
}

/// A report waiting in the outbox. `target` is set for reports owed to a
/// previous destination (reports were moved or turned off); the rest go to
/// the current one.
public struct OutboxEntry: Codable, Equatable, Sendable {
    public var report: Report
    public var target: ReportTarget?

    public init(report: Report, target: ReportTarget? = nil) {
        self.report = report
        self.target = target
    }
}

/// Reports waiting to be sent, kept by renewd in a root-only file so they
/// survive restarts and time offline. Oldest first; when full, the oldest
/// are dropped. Writes replace the file atomically.
public struct ReportOutbox {
    public static let maxReports = 500

    public let path: String
    let maxReports: Int

    public init(path: String = Paths.dataDir + "/reports-outbox.json", maxReports: Int = ReportOutbox.maxReports) {
        self.path = path
        self.maxReports = maxReports
    }

    public func load() -> [OutboxEntry] {
        withLock { $0 }
    }

    /// Adds `report` at the end. Returns how many old ones were dropped to make room.
    @discardableResult
    public func append(_ report: Report, target: ReportTarget? = nil) -> Int {
        var dropped = 0
        withLock { current in
            var entries = current + [OutboxEntry(report: report, target: target)]
            dropped = max(0, entries.count - maxReports)
            entries.removeFirst(dropped)
            return entries
        }
        return dropped
    }

    /// Removes the report with `id` (delivered, or refused for good).
    public func remove(_ id: UUID) {
        withLock { $0.filter { $0.report.id != id } }
    }

    /// Points every report meant for the current destination at `target`,
    /// or drops them when there's none. Returns how many were changed.
    @discardableResult
    public func retargetCurrent(to target: ReportTarget?) -> Int {
        var n = 0
        withLock { entries in
            n = entries.filter { $0.target == nil }.count
            guard let target else { return entries.filter { $0.target != nil } }
            return entries.map { $0.target == nil ? OutboxEntry(report: $0.report, target: target) : $0 }
        }
        return n
    }

    public func removeAll() {
        withLock { _ in [] }
    }

    @discardableResult
    private func withLock(_ change: ([OutboxEntry]) -> [OutboxEntry]) -> [OutboxEntry] {
        LockedJSONFile(path: path, label: "report outbox", empty: []).update(change)
    }
}

/// POSTs reports to a report server.
public enum ReportClient {
    public enum Outcome: Equatable, Sendable {
        case delivered
        /// Try again later: offline, timed out, throttled or a server error.
        case retry
        /// The server won't take this destination (wrong token, recipient
        /// not allowed). Every report to it would fail the same way.
        case refused(Int)
        /// The server won't take this report (malformed, too large).
        /// Sending it again won't help.
        case rejected(Int)
    }

    public static func outcome(status code: Int) -> Outcome {
        switch code {
        case 200..<300: return .delivered
        case 401, 403: return .refused(code)
        case 408, 429: return .retry
        case 400..<500: return .rejected(code)
        default: return .retry
        }
    }

    /// Generous: the server may take a while to sign in to Gmail and send,
    /// and giving up early would send the email twice.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 75
        c.timeoutIntervalForResource = 90
        return URLSession(configuration: c)
    }()

    /// The JSON body for `report` sent to `target`.
    public static func body(_ report: Report, to target: ReportTarget) -> Data? {
        var report = report
        report.to = target.partnerEmail
        report.timeZone = TimeZone.current.identifier
        return try? Report.encoder.encode(report)
    }

    /// POSTs `body` (JSON) to `server` with its token. `done` gets the
    /// outcome and, when delivered, the response body; `error` is set when
    /// the request didn't get an HTTP response at all.
    public static func post(json body: Data, to server: ReportServer, timeout: TimeInterval? = nil,
                            done: @escaping @Sendable (_ outcome: Outcome, _ code: Int, _ response: Data?, _ error: Error?) -> Void) {
        guard let url = URL(string: server.url) else { return done(.rejected(0), 0, nil, nil) }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        if let timeout { r.timeoutInterval = timeout }
        r.httpBody = body
        session.dataTask(with: r) { data, response, error in
            if let error { return done(.retry, 0, nil, error) }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result = outcome(status: code)
            done(result, code, result == .delivered ? data : nil, nil)
        }.resume()
    }

    public static func post(_ report: Report, to target: ReportTarget, done: @escaping @Sendable (Outcome) -> Void) {
        guard let body = body(report, to: target) else { return done(.rejected(0)) }
        let kind = report.kind.rawValue, id = report.id
        post(json: body, to: target.server) { result, code, _, error in
            if let error {
                log("reports: sending '\(kind)' report failed: \(error.localizedDescription)")
                return done(.retry)
            }
            switch result {
            case .delivered: log("reports: delivered '\(kind)' report \(id)")
            case .refused(401): log("reports: the report server refused the token (HTTP 401)")
            case .refused(let c): log("reports: the report server refused the recipient (HTTP \(c))")
            case .rejected(let c): log("reports: the report server rejected '\(kind)' report \(id) (HTTP \(c)); it won't be sent again")
            case .retry: log("reports: sending '\(kind)' report failed: HTTP \(code)")
            }
            done(result)
        }
    }

    /// Sends `reports` one at a time, waiting for each, and stops at the
    /// first that can't be delivered now. For use right before exiting.
    /// Returns how many were delivered or rejected for good.
    @discardableResult
    public static func sendAndWait(_ reports: [Report], to target: ReportTarget, timeoutEach: TimeInterval = 30) -> Int {
        var done = 0
        for report in reports {
            let sem = DispatchSemaphore(value: 0)
            let result = ResultBox()
            post(report, to: target) { outcome in
                result.set(outcome)
                sem.signal()
            }
            guard sem.wait(timeout: .now() + timeoutEach) == .success else { break }
            switch result.get() {
            case .delivered, .rejected: done += 1
            default: return done
            }
        }
        return done
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Outcome?
        func set(_ v: Outcome) { lock.lock(); value = v; lock.unlock() }
        func get() -> Outcome? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
