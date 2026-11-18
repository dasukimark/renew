import Foundation

/// What macOS recorded about the Mac sleeping, waking and shutting down,
/// for working out how long it was awake after renewd stopped and before
/// it restarted (see `AliveRecord.assessRestart`).
///
/// Sleep and wake come from the power log (`pmset -g log`), which keeps
/// about a week; clean shutdowns from wtmp (what `last` reads). Reading the
/// power log takes a few seconds, so renewd does it off its state queue and
/// only after a restart it wasn't told about.
public struct PowerHistory: Sendable {
    public enum Event: Sendable, Equatable {
        case sleep, wake
    }

    public struct Entry: Sendable, Equatable {
        public var date: Date
        /// nil for the log's other lines (assertions, notifications, …):
        /// they still show the Mac was running then.
        public var event: Event?

        public init(date: Date, event: Event?) {
            self.date = date
            self.event = event
        }
    }

    /// Every power log line, oldest first.
    public var entries: [Entry]
    /// Clean shutdowns, from wtmp.
    public var shutdowns: [Date]

    public init(entries: [Entry] = [], shutdowns: [Date] = []) {
        self.entries = entries.sorted { $0.date < $1.date }
        self.shutdowns = shutdowns
    }

    /// How the Mac went down after `since` (when renewd was last known to
    /// be running, so the Mac was awake) and before it booted at `bootedAt`.
    ///
    /// The Mac went down at the clean shutdown after `since`, or (a crash or
    /// power loss) at the last power log line before `bootedAt`. Awake time
    /// is the time not between a sleep and the next wake (dark wakes count:
    /// renewd runs in them). nil when the power log doesn't reach back to
    /// `since` (deleted, or too old), so nothing can be said.
    public func awake(after since: Date, before bootedAt: Date) -> (awakeSeconds: TimeInterval?, shutdownAt: Date?) {
        let shutdown = shutdowns.filter { $0 > since && $0 <= bootedAt }.min()
        guard entries.contains(where: { $0.date <= since }) else { return (nil, shutdown) }
        let end = shutdown ?? entries.last(where: { $0.date > since && $0.date < bootedAt })?.date ?? since
        var awake: TimeInterval = 0
        var awakeSince: Date? = since
        for e in entries where e.date > since && e.date <= end {
            switch e.event {
            case .sleep:
                if let a = awakeSince { awake += e.date.timeIntervalSince(a) }
                awakeSince = nil
            case .wake:
                if awakeSince == nil { awakeSince = e.date }
            case nil:
                break
            }
        }
        if let a = awakeSince { awake += max(0, end.timeIntervalSince(a)) }
        return (awake, shutdown)
    }

    // MARK: reading

    /// Reads the power log and wtmp. Slow (seconds); don't call it on a
    /// queue that has other work.
    public static func read() -> PowerHistory {
        let r = shell("/usr/bin/pmset", ["-g", "log"])
        if !r.ok { log("power log: pmset failed: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return PowerHistory(entries: parse(pmsetLog: r.out), shutdowns: readShutdowns())
    }

    /// The lines of `pmset -g log` that start with a time stamp, e.g.
    /// `2026-11-18 07:16:57 -0500 Sleep               \tEntering Sleep state…`.
    /// The domain (`Sleep`, `Wake`, `DarkWake`, `Assertions`, …) runs up to
    /// the tab.
    public static func parse(pmsetLog text: String) -> [Entry] {
        var out: [Entry] = []
        text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).forEach { raw in
            let line = Array(raw)
            guard line.count > 26, let date = parseStamp(line) else { return }
            let rest = line[26...]
            let domainEnd = rest.firstIndex(of: UInt8(ascii: "\t")) ?? rest.endIndex
            let domain = String(decoding: line[26..<domainEnd], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let event: Event?
            switch domain {
            case "Sleep": event = .sleep
            case "Wake", "DarkWake": event = .wake
            default: event = nil
            }
            out.append(Entry(date: date, event: event))
        }
        return out
    }

    /// `yyyy-MM-dd HH:mm:ss ±hhmm` at the start of `b`.
    static func parseStamp(_ b: [UInt8]) -> Date? {
        func num(_ from: Int, _ len: Int) -> Int? {
            var v = 0
            for i in from..<(from + len) {
                let c = b[i]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard b.count >= 25, b[4] == 45, b[7] == 45, b[10] == 32, b[13] == 58, b[16] == 58, b[19] == 32,
              b[20] == 43 || b[20] == 45,
              let year = num(0, 4), let month = num(5, 2), let day = num(8, 2),
              let hour = num(11, 2), let minute = num(14, 2), let second = num(17, 2),
              let oh = num(21, 2), let om = num(23, 2) else { return nil }
        var tm = Darwin.tm()
        tm.tm_year = Int32(year - 1900)
        tm.tm_mon = Int32(month - 1)
        tm.tm_mday = Int32(day)
        tm.tm_hour = Int32(hour)
        tm.tm_min = Int32(minute)
        tm.tm_sec = Int32(second)
        let utc = timegm(&tm)
        guard utc != -1 else { return nil }
        let offset = (oh * 3600 + om * 60) * (b[20] == 45 ? -1 : 1)
        return Date(timeIntervalSince1970: TimeInterval(utc - offset))
    }

    /// Clean shutdowns recorded in wtmp.
    static func readShutdowns() -> [Date] {
        var out: [Date] = []
        setutxent_wtmp(0)
        defer { endutxent_wtmp() }
        while let e = getutxent_wtmp() {
            if e.pointee.ut_type == SHUTDOWN_TIME {
                out.append(Date(timeIntervalSince1970: TimeInterval(e.pointee.ut_tv.tv_sec)))
            }
        }
        return out
    }
}
