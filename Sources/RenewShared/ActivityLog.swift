import Foundation

/// Which part of the activity log to read.
public struct ActivityQuery: Codable, Equatable, Sendable {
    /// Local day, `yyyy-MM-dd`.
    public var day: String
    public var flaggedOnly: Bool
    /// Read only what was added after this point in the day's file (the
    /// `offset` of an earlier read), so refreshing doesn't re-read the day.
    public var fromOffset: Int?

    public init(day: String, flaggedOnly: Bool = false, fromOffset: Int? = nil) {
        self.day = day
        self.flaggedOnly = flaggedOnly
        self.fromOffset = fromOffset
    }

    public init(date: Date, flaggedOnly: Bool = false, fromOffset: Int? = nil) {
        self.init(day: ActivityLogStore.dayKey(date), flaggedOnly: flaggedOnly, fromOffset: fromOffset)
    }
}

/// What a read of the activity log found.
public struct ActivityPage: Sendable {
    public var events: [ActivityEvent]
    /// Where the next incremental read should start.
    public var offset: Int
    /// The events follow on from the query's `fromOffset` (rather than being
    /// the whole day, because the file was replaced or no offset was given).
    public var isIncremental: Bool
}

/// The activity log renewd keeps: one append-only JSON-lines file per user
/// per day, `<directory>/<uid>/<yyyy-MM-dd>.jsonl`, readable only by root.
/// Visits are filed under the day they started, in the Mac's current time
/// zone. Files older than `retentionDays` are deleted.
///
/// Not thread-safe: renewd calls it from its one state queue.
public final class ActivityLogStore {
    public static let retentionDays = 30
    /// How long per-site daily totals (`DaySummary`) are kept.
    public static let summaryRetentionDays = 365
    public static let maxEventsPerRequest = 100
    /// The most events one read returns (the latest ones).
    public static let maxQueryResults = 3_000
    /// A user's log stops growing past these, so nobody can fill the disk.
    public static let maxBytesPerDay = 16 << 20
    public static let maxBytesPerUser = 256 << 20
    /// Ids remembered per user to drop re-sent visits.
    static let rememberedIDs = 20_000

    public let directory: String
    let maxBytesPerDay: Int
    let maxBytesPerUser: Int
    private var recent: [uid_t: (ids: Set<UUID>, order: [UUID])] = [:]
    private var lastQuotaLog: [uid_t: Date] = [:]

    public init(directory: String, maxBytesPerDay: Int = ActivityLogStore.maxBytesPerDay,
                maxBytesPerUser: Int = ActivityLogStore.maxBytesPerUser) {
        self.directory = directory
        self.maxBytesPerDay = maxBytesPerDay
        self.maxBytesPerUser = maxBytesPerUser
    }

    // MARK: naming

    private static let formatterLock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    private static func formatter(_ timeZone: TimeZone) -> DateFormatter {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        if let f = formatters[timeZone.identifier] { return f }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        formatters[timeZone.identifier] = f
        return f
    }

    /// The Mac's time zone now. A long-running process otherwise keeps the
    /// zone it started in, even after the user travels or changes it.
    public static var systemTimeZone: TimeZone {
        NSTimeZone.resetSystemTimeZone()
        return TimeZone.current
    }

    public static func dayKey(_ date: Date, timeZone: TimeZone = systemTimeZone) -> String {
        formatter(timeZone).string(from: date)
    }

    /// The start of the day a key names, or nil if it isn't a valid key.
    public static func date(ofDay key: String, timeZone: TimeZone = systemTimeZone) -> Date? {
        guard key.count == 10 else { return nil }
        let f = formatter(timeZone)
        guard let d = f.date(from: key), f.string(from: d) == key else { return nil }
        return d
    }

    /// Whether a day's file is past the retention period at `now`.
    public static func isExpired(day key: String, now: Date, timeZone: TimeZone = systemTimeZone,
                                 retention: Int = retentionDays) -> Bool {
        guard let day = date(ofDay: key, timeZone: timeZone) else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        guard let cutoff = cal.date(byAdding: .day, value: -retention, to: cal.startOfDay(for: now)) else { return false }
        return day < cutoff
    }

    private func userDir(_ uid: uid_t) -> String { directory + "/\(uid)" }

    private func file(_ uid: uid_t, day: String) -> String { userDir(uid) + "/\(day).jsonl" }

    private func summaryDir(_ uid: uid_t) -> String { userDir(uid) + "/summary" }

    private func summaryFile(_ uid: uid_t, day: String) -> String { summaryDir(uid) + "/\(day).json" }

    private static func size(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func userBytes(_ uid: uid_t) -> Int {
        let dir = userDir(uid)
        // Only the visit logs; the summaries are small and capped by design.
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }
            .reduce(0) { $0 + Self.size(dir + "/" + $1) }
    }

    // MARK: writing

    /// Appends the valid events among `events` (at most
    /// `maxEventsPerRequest`) to `uid`'s log, skipping ones already stored
    /// and anything over the user's quota. Returns how many were stored.
    @discardableResult
    public func append(_ events: [ActivityEvent], uid: uid_t, now: Date = Date()) -> Int {
        let tz = Self.systemTimeZone
        var seen = rememberedIDs(uid, now: now, timeZone: tz)
        var clean: [ActivityEvent] = []
        for e in events.prefix(Self.maxEventsPerRequest) {
            guard let s = e.sanitized(now: now) else { continue }
            if let id = s.id {
                guard !seen.ids.contains(id) else { continue }
                seen.ids.insert(id)
                seen.order.append(id)
            }
            clean.append(s)
        }
        if seen.order.count > Self.rememberedIDs {
            let drop = seen.order.prefix(seen.order.count - Self.rememberedIDs)
            seen.ids.subtract(drop)
            seen.order.removeFirst(drop.count)
        }
        recent[uid] = seen
        guard !clean.isEmpty else { return 0 }

        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(atPath: userDir(uid), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            log("activity log: couldn't create \(userDir(uid)): \(error)")
            return 0
        }
        let encoder = Wire.encoder
        var byDay: [String: (data: Data, count: Int)] = [:]
        for e in clean {
            guard var line = try? encoder.encode(e) else { continue }
            line.append(0x0A)
            let key = Self.dayKey(e.start, timeZone: tz)
            byDay[key, default: (Data(), 0)].data.append(line)
            byDay[key, default: (Data(), 0)].count += 1
        }
        var total = userBytes(uid)
        var stored = 0
        for (day, chunk) in byDay.sorted(by: { $0.key < $1.key }) {
            let path = file(uid, day: day)
            let daySize = Self.size(path)
            guard daySize + chunk.data.count <= maxBytesPerDay, total + chunk.data.count <= maxBytesPerUser else {
                if now.timeIntervalSince(lastQuotaLog[uid] ?? .distantPast) > 3_600 {
                    lastQuotaLog[uid] = now
                    log("activity log: uid \(uid) is over its quota; dropping visits")
                }
                continue
            }
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
            guard fd >= 0 else {
                log("activity log: couldn't open \(path): \(String(cString: strerror(errno)))")
                continue
            }
            defer { close(fd) }
            do {
                try writeAll(fd, chunk.data)
                stored += chunk.count
                total += chunk.data.count
            } catch {
                log("activity log: write to \(path) failed: \(error)")
            }
        }
        return stored
    }

    /// The ids stored for `uid` lately: remembered since renewd started,
    /// seeded from today's and yesterday's files the first time.
    private func rememberedIDs(_ uid: uid_t, now: Date, timeZone tz: TimeZone) -> (ids: Set<UUID>, order: [UUID]) {
        if let r = recent[uid] { return r }
        var order: [UUID] = []
        for day in [now.addingTimeInterval(-86_400), now] {
            for e in decode(FileManager.default.contents(atPath: file(uid, day: Self.dayKey(day, timeZone: tz)))) {
                if let id = e.id { order.append(id) }
            }
        }
        order = Array(order.suffix(Self.rememberedIDs))
        return (Set(order), order)
    }

    private func decode(_ data: Data?) -> [ActivityEvent] {
        guard let data else { return [] }
        let decoder = Wire.decoder
        return data.split(separator: 0x0A).compactMap { $0.isEmpty ? nil : try? decoder.decode(ActivityEvent.self, from: $0) }
    }

    // MARK: reading

    /// `uid`'s visits for the query's day, oldest first (at most the latest
    /// `maxQueryResults`). With `fromOffset`, only those added since.
    /// Unreadable lines are skipped.
    public func read(_ query: ActivityQuery, uid: uid_t) -> ActivityPage {
        guard Self.date(ofDay: query.day) != nil,
              let handle = FileHandle(forReadingAtPath: file(uid, day: query.day)) else {
            return ActivityPage(events: [], offset: 0, isIncremental: false)
        }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        var start = 0
        var incremental = false
        if let from = query.fromOffset, from >= 0, from <= size {
            start = from
            incremental = true
        }
        try? handle.seek(toOffset: UInt64(start))
        let data = handle.readData(ofLength: size - start)
        // Only whole lines; a half-written one is read next time.
        let end = (data.lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex)
        var events = decode(data[data.startIndex..<end])
        if query.flaggedOnly { events = events.filter(\.isFlagged) }
        events.sort { $0.start < $1.start }
        return ActivityPage(events: Array(events.suffix(Self.maxQueryResults)),
                            offset: start + (end - data.startIndex), isIncremental: incremental)
    }

    // MARK: summaries

    /// A saved `DaySummary`, with the size of the log it was built from.
    /// Logs only grow, so a different size means it's out of date.
    private struct StoredSummary: Codable {
        var logBytes: Int
        var summary: DaySummary
    }

    /// The day being added to most recently, per user (normally today):
    /// its totals so far and how far into its log they go, so a refresh only
    /// reads what was added since.
    private struct Running {
        var day: String
        var offset: Int
        var builder: DaySummary.Builder
    }
    private var running: [uid_t: Running] = [:]

    /// `uid`'s per-site totals for each day in the range that has any, oldest
    /// first. The same sites are kept every day (at most
    /// `ActivityStatsQuery.sitesPerDay`, plus the query's `site`); the rest
    /// are added up under `DaySummary.otherSite`. Summaries are brought up to
    /// date with the day's log first. nil if the range isn't valid.
    public func summaries(_ query: ActivityStatsQuery, uid: uid_t) -> [DaySummary]? {
        guard let keys = query.dayKeys() else { return nil }
        let days = keys.compactMap { summary(uid, day: $0) }
        return DaySummary.cappedTogether(days, limit: ActivityStatsQuery.sitesPerDay(forDays: keys.count), keep: query.site)
    }

    /// One day's totals: the saved summary if it's current, else brought up
    /// to date from the day's log and saved. nil if there's neither.
    func summary(_ uid: uid_t, day: String) -> DaySummary? {
        let logPath = file(uid, day: day)
        let path = summaryFile(uid, day: day)
        let saved = FileManager.default.contents(atPath: path).flatMap { try? Wire.decoder.decode(StoredSummary.self, from: $0) }
        guard let handle = FileHandle(forReadingAtPath: logPath) else { return saved?.summary }
        defer { try? handle.close() }
        let logBytes = Int((try? handle.seekToEnd()) ?? 0)
        if let saved, saved.logBytes == logBytes { return saved.summary }

        // Carry on from where the last update of this day stopped, if it's
        // the one in memory; otherwise read the day from the start.
        var r = running[uid]
        if r == nil || r!.day != day || r!.offset > logBytes {
            r = Running(day: day, offset: 0, builder: DaySummary.Builder())
        }
        var current = r!
        try? handle.seek(toOffset: UInt64(current.offset))
        let data = handle.readData(ofLength: logBytes - current.offset)
        // Whole lines only, as in `read`; a half-written one is read next time.
        let end = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
        current.builder.add(decode(data[data.startIndex..<end]))
        current.offset += end - data.startIndex
        running[uid] = current

        let built = current.builder.summary(day: day)
        save(StoredSummary(logBytes: current.offset == logBytes ? logBytes : -1, summary: built), to: path, uid: uid)
        return built
    }

    private func save(_ stored: StoredSummary, to path: String, uid: uid_t) {
        guard let data = try? Wire.encoder.encode(stored) else { return }
        do {
            try FileManager.default.createDirectory(atPath: summaryDir(uid), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            log("activity log: couldn't create \(summaryDir(uid)): \(error)")
            return
        }
        // Written aside and renamed into place, so a reader never sees half a file.
        let tmp = path + ".tmp"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            log("activity log: couldn't open \(tmp): \(String(cString: strerror(errno)))")
            return
        }
        do {
            try writeAll(fd, data)
            close(fd)
            if rename(tmp, path) != 0 { unlink(tmp) }
        } catch {
            close(fd)
            unlink(tmp)
            log("activity log: write to \(tmp) failed: \(error)")
        }
    }

    // MARK: retention

    /// Deletes day files past the retention period. Returns how many went.
    @discardableResult
    public func prune(now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let users = try? fm.contentsOfDirectory(atPath: directory) else { return 0 }
        let tz = Self.systemTimeZone
        var removed = 0
        for user in users {
            guard let uid = uid_t(user) else { continue }
            let dir = directory + "/" + user
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".jsonl") {
                let day = String(name.dropLast(".jsonl".count))
                guard Self.isExpired(day: day, now: now, timeZone: tz) else { continue }
                // Keep the day's totals after its visits go.
                if !Self.isExpired(day: day, now: now, timeZone: tz, retention: Self.summaryRetentionDays) {
                    _ = summary(uid, day: day)
                }
                if (try? fm.removeItem(atPath: dir + "/" + name)) != nil { removed += 1 }
            }
            let sdir = summaryDir(uid)
            for name in (try? fm.contentsOfDirectory(atPath: sdir)) ?? [] where name.hasSuffix(".json") {
                let day = String(name.dropLast(".json".count))
                guard Self.isExpired(day: day, now: now, timeZone: tz, retention: Self.summaryRetentionDays) else { continue }
                try? fm.removeItem(atPath: sdir + "/" + name)
            }
        }
        return removed
    }
}
