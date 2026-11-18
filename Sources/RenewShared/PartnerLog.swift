import Foundation

/// One thing your accountability partner was told (or is about to be): an
/// email report, an instant alert, or a check-in email the report server
/// sent. Shown on the Accountability page so you can see what they see.
public struct PartnerLogEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Channel: String, Codable, Sendable { case email, alert, checkin }
    public enum Status: String, Codable, Sendable { case sent, waiting, failed }

    public var id: UUID
    public var date: Date
    public var channel: Channel
    public var status: Status
    public var title: String
    public var lines: [String]
    /// The user an email was about (from the report). Entries with a user
    /// are shown only to that user; the rest (alerts, check-ins) are about
    /// the whole Mac.
    public var user: String?

    public init(id: UUID = UUID(), date: Date, channel: Channel, status: Status, title: String, lines: [String] = [],
                user: String? = nil) {
        self.user = user
        self.id = id
        self.date = date
        self.channel = channel
        self.status = status
        self.title = title
        self.lines = lines
    }

    /// Flags listed per entry, so a big report stays readable.
    public static let maxLines = 25

    /// An entry for `report`. Flags are listed as site and reasons, never
    /// the full address (reports don't carry it).
    public static func email(_ report: Report, status: Status, date: Date? = nil) -> PartnerLogEntry {
        let title: String
        var lines: [String] = []
        switch report.kind {
        case .flags:
            let n = report.flags.count + report.omitted
            title = n == 1 ? "1 flagged visit" : "\(n) flagged visits"
            for f in report.flags.prefix(maxLines) {
                let reasons = f.reasons.isEmpty ? "flagged" : f.reasons.joined(separator: ", ")
                lines.append("\(f.host): \(reasons)")
            }
            let more = n - min(report.flags.count, maxLines)
            if more > 0 { lines.append("…and \(more) more") }
        case .change:
            title = report.changes.first ?? "Monitoring changed"
            lines = report.changes.count > 1 ? Array(report.changes.prefix(maxLines)) : []
        case .test:
            title = "Test email"
        }
        return PartnerLogEntry(id: report.id, date: date ?? report.sentAt, channel: .email, status: status,
                               title: title, lines: lines, user: report.user.isEmpty ? nil : report.user)
    }

    /// The history to show `viewer` (a user name; nil shows everything):
    /// what's waiting in the outbox, then what was sent, newest first. Other
    /// users' emails are left out, like their Monitor flags.
    public static func history(log: [PartnerLogEntry], waiting: [OutboxEntry], viewer: String?,
                               limit: Int = PartnerLog.maxEntries) -> [PartnerLogEntry] {
        let sentIDs = Set(log.map(\.id))
        let pending = waiting.filter { !sentIDs.contains($0.report.id) }.map { email($0.report, status: .waiting) }
        let visible = (pending + log).filter { viewer == nil || $0.user == nil || $0.user == viewer }
        return Array(visible.sorted { $0.date > $1.date }.prefix(limit))
    }
}

/// renewd's record of what the partner was told, in a root-only file.
/// Newest last; when full, the oldest are dropped.
public struct PartnerLog: Sendable {
    public static let maxEntries = 200

    public let path: String
    let maxEntries: Int

    public init(path: String = Paths.partnerLogFile, maxEntries: Int = PartnerLog.maxEntries) {
        self.path = path
        self.maxEntries = maxEntries
    }

    private var file: LockedJSONFile<[PartnerLogEntry]> {
        LockedJSONFile(path: path, label: "partner log", empty: [])
    }

    public func load() -> [PartnerLogEntry] { file.load() }

    public func append(_ entries: [PartnerLogEntry]) {
        guard !entries.isEmpty else { return }
        file.update { current in
            let all = current + entries
            return Array(all.suffix(maxEntries))
        }
    }

    public func append(_ entry: PartnerLogEntry) { append([entry]) }
}
