import Foundation
import SystemConfiguration

/// Email reports for accountability partners. renewd POSTs a `Report` to
/// your report server (see `server/reports/`), which emails it to the
/// partners' addresses set here. Like the rest of the destination, the
/// addresses can only be changed between sessions, and removed partners are
/// told.
///
/// The server is normally the built-in one (`ReportServer`, installed with
/// Renew), so only the partners' addresses are needed; `url` and `token` are
/// set only for a different server.
///
/// A report names the site, the page title, why it was flagged, when and
/// for how long. It never carries the full address.
public struct ReportDestination: Codable, Equatable, Sendable {
    /// Where the server emails reports. Never empty once normalized.
    public var partnerEmails: [String]
    /// A different report server, or nil for the built-in one.
    public var url: String?
    /// Sent as `Authorization: Bearer <token>`; nil with `url`.
    public var token: String?

    public init(partnerEmails: [String], url: String? = nil, token: String? = nil) {
        self.partnerEmails = partnerEmails
        self.url = url
        self.token = token
    }

    public static let maxTokenLength = 512
    public static let maxPartners = 10

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

    /// The addresses normalized, without blanks or repeats, in order. nil if
    /// any is invalid, none are given, or there are more than `maxPartners`.
    public static func normalizeEmails(_ raw: [String]) -> [String]? {
        var out: [String] = []
        for r in raw where !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let e = normalizeEmail(r) else { return nil }
            if !out.contains(e) { out.append(e) }
        }
        guard !out.isEmpty, out.count <= maxPartners else { return nil }
        return out
    }

    /// A usable destination, trimmed, or nil. Without a URL it uses the
    /// built-in server; with one it needs a token too.
    public static func normalize(partnerEmails rawEmails: [String], url rawURL: String? = nil,
                                 token rawToken: String? = nil) -> ReportDestination? {
        guard let emails = normalizeEmails(rawEmails) else { return nil }
        let urlText = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !urlText.isEmpty else { return ReportDestination(partnerEmails: emails) }
        guard let server = ReportServer.normalize(url: urlText, token: rawToken ?? "") else { return nil }
        return ReportDestination(partnerEmails: emails, url: server.url, token: server.token)
    }

    private enum CodingKeys: String, CodingKey { case partnerEmails, partnerEmail, url, token }

    /// Reads state files from before there could be several partners
    /// (`partnerEmail`) too.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try c.decodeIfPresent([String].self, forKey: .partnerEmails) {
            partnerEmails = list
        } else {
            partnerEmails = [try c.decode(String.self, forKey: .partnerEmail)]
        }
        url = try c.decodeIfPresent(String.self, forKey: .url)
        token = try c.decodeIfPresent(String.self, forKey: .token)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(partnerEmails, forKey: .partnerEmails)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(token, forKey: .token)
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
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.count <= 2_048, let parsed = URL(string: url), let host = parsed.host?.lowercased(), !host.isEmpty
        else { return nil }
        switch parsed.scheme?.lowercased() {
        case "https": break
        case "http" where ["localhost", "127.0.0.1", "::1"].contains(host): break
        default: return nil
        }
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
    /// The partners' addresses, filled in when sent (from the destination).
    public var to: Recipients?
    /// The Mac's time zone (e.g. `America/New_York`), so the email shows its times.
    public var timeZone: String?

    /// This Mac's name, as reports show it.
    public static var macName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "a Mac"
    }

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

    /// What a report says for anything explicit: an explicit site, explicit
    /// words, a likely-explicit score or a site's own NSFW label. Partners
    /// don't need to see which word or rule matched.
    public static let explicitReason = "Potentially explicit content detected"
    /// What a report says for a site's own 18+ or age gate.
    public static let ageRestrictedReason = "Attempted to access age restricted content"
    /// The built-in explicit words, normalized like `TermMatcher` matches them.
    static let explicitWords = Set(ExplicitTerms.preset.map(TermMatcher.key))

    /// Readable reasons, without repeats. Explicit flags of every kind read
    /// the same (`explicitReason`), without the word or domain that matched;
    /// your own words and lists are still named.
    public static func reasons(for flags: [ActivityFlag]) -> [String] {
        var out: [String] = []
        for f in flags {
            let text: String
            switch f.kind {
            case .domain:
                switch f.list {
                case MonitorSettings.explicitListName: text = explicitReason
                case MonitorSettings.customListName, nil: text = "watched site"
                case let list?: text = "on list '\(list)'"
                }
            case .term:
                if f.isSiteLabel { text = SiteLabel.named(f.match)?.isAgeGate == true ? ageRestrictedReason : explicitReason }
                else if f.isScore || f.isPageWords { text = explicitReason }
                else if explicitWords.contains(TermMatcher.key(f.match)) { text = explicitReason }
                else { text = "word: \(f.match)" }
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
    /// report: the Monitor turned off, monitoring lists turned off, deleted
    /// or with sites removed, explicit content turned off, other sites or
    /// words removed. Adding anything isn't listed.
    public func loosenings(to new: MonitorSettings) -> [String] {
        var out: [String] = []
        if enabled && !new.enabled { out.append("The Monitor was turned off.") }
        // Lists that watch nothing aren't looser for being off.
        if flagLists && !new.flagLists && (lists.values.contains { !$0.isEmpty } || !customDomains.isEmpty) {
            out.append("Sites on monitoring lists are no longer flagged.")
        }
        // With lists already off their sites weren't flagged, so removing
        // them (or deleting a list) watches nothing less.
        for name in sortedListNames where flagLists {
            guard let after = new.lists[name] else {
                // An empty list watched nothing, so deleting it isn't looser.
                if !(lists[name] ?? []).isEmpty { out.append("The monitoring list '\(name)' was deleted.") }
                continue
            }
            let removed = (lists[name] ?? []).filter { !after.contains($0) }
            if !removed.isEmpty { out.append("Sites removed from '\(name)': \(Self.listed(removed)).") }
        }
        if flagExplicit && !new.flagExplicit { out.append("Explicit content is no longer flagged.") }
        let sites = flagLists ? customDomains.filter { !new.customDomains.contains($0) } : []
        if !sites.isEmpty { out.append("Watched sites removed: \(Self.listed(sites)).") }
        let words = customTerms.filter { !new.customTerms.contains($0) }
        if !words.isEmpty { out.append("Watched words removed: \(Self.listed(words)).") }
        return out
    }

    public static let lockedMessage = "Monitoring can't be turned off or watch less while you have an accountability partner. Remove your partners first (they'll be asked to approve)."
    public static let needsPartnerMessage = "Add an accountability partner before turning on the Monitor."

    /// Why going from `self` to `new` isn't allowed, or nil if it is. With
    /// a partner and the Monitor on, nothing may loosen (see `loosenings`);
    /// adding is always fine. Without one, the Monitor can't be turned on,
    /// but settings left on from before can still be edited or turned off.
    public func refusal(changingTo new: MonitorSettings, hasPartner: Bool) -> String? {
        if hasPartner {
            return enabled && !loosenings(to: new).isEmpty ? Self.lockedMessage : nil
        }
        return !enabled && new.enabled ? Self.needsPartnerMessage : nil
    }

    /// The first `limit` items, then how many more, so a report sentence
    /// stays short enough to show in full.
    static func listed(_ items: [String], limit: Int = 15) -> String {
        let shown = items.prefix(limit).joined(separator: ", ")
        return items.count > limit ? "\(shown) and \(items.count - limit) more" : shown
    }
}

extension ActivitySettings {
    public static let lockedMessage = "Activity can't be turned off while the Monitor is on and you have an accountability partner: the Monitor checks what Activity records. Remove your partners first (they'll be asked to approve)."

    /// Why going from `self` to `new` isn't allowed, or nil if it is:
    /// turning Activity off would quietly stop a Monitor a partner relies on.
    public func refusal(changingTo new: ActivitySettings, monitor: MonitorSettings, hasPartner: Bool) -> String? {
        enabled && !new.enabled && hasPartner && monitor.enabled ? Self.lockedMessage : nil
    }
}

/// A report's recipients. Sent as one string for a single address, which
/// report servers from before several partners also accept, or as a list.
public struct Recipients: Codable, Equatable, Sendable {
    public var emails: [String]

    public init(_ emails: [String]) { self.emails = emails }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let one = try? c.decode(String.self) { emails = [one] } else { emails = try c.decode([String].self) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if emails.count == 1 { try c.encode(emails[0]) } else { try c.encode(emails) }
    }
}

/// Who a report goes to and through which server, fully resolved.
public struct ReportTarget: Codable, Equatable, Sendable {
    public var partnerEmails: [String]
    public var server: ReportServer

    public init(partnerEmails: [String], server: ReportServer) {
        self.partnerEmails = partnerEmails
        self.server = server
    }

    private enum CodingKeys: String, CodingKey { case partnerEmails, partnerEmail, server }

    /// Reads outboxes from before there could be several partners too.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try c.decodeIfPresent([String].self, forKey: .partnerEmails) {
            partnerEmails = list
        } else {
            partnerEmails = [try c.decode(String.self, forKey: .partnerEmail)]
        }
        server = try c.decode(ReportServer.self, forKey: .server)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(partnerEmails, forKey: .partnerEmails)
        try c.encode(server, forKey: .server)
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
        report.to = Recipients(target.partnerEmails)
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
