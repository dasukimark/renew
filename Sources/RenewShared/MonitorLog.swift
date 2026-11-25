import Foundation

/// One visit the Monitor flagged, and why.
public struct MonitorFlag: Codable, Equatable, Sendable {
    /// The visit's id in the activity log (nil only for visits without one).
    public var eventID: UUID?
    public var start: Date
    public var end: Date
    public var browser: String
    public var url: String
    public var host: String
    public var title: String
    public var flags: [ActivityFlag]
    /// When renewd flagged it.
    public var flaggedAt: Date

    public init(event: ActivityEvent, flags: [ActivityFlag], flaggedAt: Date) {
        eventID = event.id
        start = event.start
        end = event.end
        browser = event.browser
        url = event.url
        host = event.host
        title = event.title
        self.flags = flags
        self.flaggedAt = flaggedAt
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Which day of the Monitor's flags to read.
public struct MonitorQuery: Codable, Equatable, Sendable {
    /// Local day, `yyyy-MM-dd`.
    public var day: String
    /// Read only what was added after this point (an earlier read's `offset`).
    public var fromOffset: Int?

    public init(day: String, fromOffset: Int? = nil) {
        self.day = day
        self.fromOffset = fromOffset
    }

    public init(date: Date, fromOffset: Int? = nil) {
        self.init(day: ActivityLogStore.dayKey(date), fromOffset: fromOffset)
    }
}

/// A page of the Monitor's flags across a range of days, newest first.
public struct MonitorRangeQuery: Codable, Equatable, Sendable {
    public static let maxLimit = 500

    /// First local day to include, `yyyy-MM-dd`; nil for every day kept.
    public var sinceDay: String?
    /// Last local day to include, `yyyy-MM-dd`.
    public var throughDay: String
    /// How many of the newest flags to pass over.
    public var skip: Int
    /// How many to return (at most `maxLimit`).
    public var limit: Int

    public init(sinceDay: String?, throughDay: String, skip: Int = 0, limit: Int = 50) {
        self.sinceDay = sinceDay
        self.throughDay = throughDay
        self.skip = skip
        self.limit = limit
    }

    public init(since: Date?, through: Date, skip: Int = 0, limit: Int = 50) {
        self.init(sinceDay: since.map { ActivityLogStore.dayKey($0) }, throughDay: ActivityLogStore.dayKey(through),
                  skip: skip, limit: limit)
    }

    public var isValid: Bool {
        ActivityLogStore.date(ofDay: throughDay) != nil
            && (sinceDay.map { ActivityLogStore.date(ofDay: $0) != nil } ?? true)
            && skip >= 0 && limit > 0 && limit <= Self.maxLimit
    }
}

/// What a range read found: one page, newest first, and how many flags the
/// whole range holds.
public struct MonitorRangePage: Sendable {
    public var flags: [MonitorFlag]
    public var total: Int
}

/// What a read of the Monitor's flags found.
public struct MonitorPage: Sendable {
    public var flags: [MonitorFlag]
    public var offset: Int
    public var isIncremental: Bool
}

/// The Monitor's flags, kept by renewd apart from the activity log: one
/// append-only JSON-lines file per user per day,
/// `<directory>/<uid>/<yyyy-MM-dd>.jsonl`, readable only by root. Flags are
/// written once, when a visit arrives, and never rewritten. Kept for
/// `retentionDays`, longer than the visits themselves.
///
/// Not thread-safe: renewd calls it from its one state queue.
public final class MonitorLogStore {
    public static let retentionDays = 365
    public static let maxQueryResults = 3_000
    public static let maxBytesPerDay = 4 << 20
    public static let maxBytesPerUser = 64 << 20

    public let directory: String
    let maxBytesPerDay: Int
    let maxBytesPerUser: Int
    private var lastQuotaLog: [uid_t: Date] = [:]
    /// How many flags each day file held at `end` (just past its last whole
    /// line), so range reads only decode what was appended since.
    private var flagCounts: [String: (end: Int, count: Int)] = [:]

    public init(directory: String, maxBytesPerDay: Int = MonitorLogStore.maxBytesPerDay,
                maxBytesPerUser: Int = MonitorLogStore.maxBytesPerUser) {
        self.directory = directory
        self.maxBytesPerDay = maxBytesPerDay
        self.maxBytesPerUser = maxBytesPerUser
    }

    private func userDir(_ uid: uid_t) -> String { directory + "/\(uid)" }
    private func file(_ uid: uid_t, day: String) -> String { userDir(uid) + "/\(day).jsonl" }

    private static func size(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// The day keys of the `.jsonl` files in a user's directory, unchecked.
    private static func dayFiles(inUserDir dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }
            .map { String($0.dropLast(".jsonl".count)) }
    }

    private func userBytes(_ uid: uid_t) -> Int {
        Self.dayFiles(inUserDir: userDir(uid)).reduce(0) { $0 + Self.size(file(uid, day: $1)) }
    }

    /// The whole lines in `data` that decode as flags.
    private static func decodeLines(_ data: Data) -> [MonitorFlag] {
        let end = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
        let decoder = Wire.decoder
        return data[data.startIndex..<end].split(separator: 0x0A)
            .compactMap { try? decoder.decode(MonitorFlag.self, from: $0) }
    }

    /// How many flags a day file holds, decoding only what was appended
    /// since the last call. Files are append-only; a shorter file starts over.
    private func flagCount(atPath path: String) -> Int {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            flagCounts[path] = nil
            return 0
        }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        var known = flagCounts[path] ?? (0, 0)
        if known.end > size { known = (0, 0) }
        guard known.end < size else { return known.count }
        try? handle.seek(toOffset: UInt64(known.end))
        let data = handle.readData(ofLength: size - known.end)
        guard let last = data.lastIndex(of: 0x0A) else { return known.count }
        known.count += Self.decodeLines(data).count
        known.end += last - data.startIndex + 1
        flagCounts[path] = known
        return known.count
    }

    /// Appends `flags` to `uid`'s log, filed under the day each visit
    /// started. Returns how many were stored.
    @discardableResult
    public func append(_ flags: [MonitorFlag], uid: uid_t, now: Date = Date()) -> Int {
        guard !flags.isEmpty else { return 0 }
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(atPath: userDir(uid), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            log("monitor log: couldn't create \(userDir(uid)): \(error)")
            return 0
        }
        let tz = ActivityLogStore.systemTimeZone
        let encoder = Wire.encoder
        var byDay: [String: (data: Data, count: Int)] = [:]
        for f in flags {
            guard var line = try? encoder.encode(f) else { continue }
            line.append(0x0A)
            let key = ActivityLogStore.dayKey(f.start, timeZone: tz)
            byDay[key, default: (Data(), 0)].data.append(line)
            byDay[key, default: (Data(), 0)].count += 1
        }
        var total = userBytes(uid)
        var stored = 0
        for (day, chunk) in byDay.sorted(by: { $0.key < $1.key }) {
            let path = file(uid, day: day)
            guard Self.size(path) + chunk.data.count <= maxBytesPerDay, total + chunk.data.count <= maxBytesPerUser else {
                if now.timeIntervalSince(lastQuotaLog[uid] ?? .distantPast) > 3_600 {
                    lastQuotaLog[uid] = now
                    log("monitor log: uid \(uid) is over its quota; dropping flags")
                }
                continue
            }
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
            guard fd >= 0 else {
                log("monitor log: couldn't open \(path): \(String(cString: strerror(errno)))")
                continue
            }
            defer { close(fd) }
            do {
                try writeAll(fd, chunk.data)
                stored += chunk.count
                total += chunk.data.count
            } catch {
                log("monitor log: write to \(path) failed: \(error)")
            }
        }
        return stored
    }

    /// `uid`'s flags for the query's day, oldest first (at most the latest
    /// `maxQueryResults`). With `fromOffset`, only those added since.
    public func read(_ query: MonitorQuery, uid: uid_t) -> MonitorPage {
        guard ActivityLogStore.date(ofDay: query.day) != nil,
              let handle = FileHandle(forReadingAtPath: file(uid, day: query.day)) else {
            return MonitorPage(flags: [], offset: 0, isIncremental: false)
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
        let end = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
        let decoder = Wire.decoder
        var flags = data[data.startIndex..<end].split(separator: 0x0A)
            .compactMap { $0.isEmpty ? nil : try? decoder.decode(MonitorFlag.self, from: $0) }
        flags.sort { $0.start < $1.start }
        return MonitorPage(flags: Array(flags.suffix(Self.maxQueryResults)),
                           offset: start + (end - data.startIndex), isIncremental: incremental)
    }

    /// One page of `uid`'s flags across the query's days, newest first, and
    /// how many the range holds. Counts come from `flagCount`; only the days
    /// the page touches are decoded in full.
    public func read(_ query: MonitorRangeQuery, uid: uid_t) -> MonitorRangePage {
        guard query.isValid else { return MonitorRangePage(flags: [], total: 0) }
        let days = Self.dayFiles(inUserDir: userDir(uid))
            .filter { day in
                ActivityLogStore.date(ofDay: day) != nil && day <= query.throughDay
                    && (query.sinceDay.map { day >= $0 } ?? true)
            }
            .sorted(by: >)
        let pageEnd = query.skip + query.limit
        var total = 0
        var page: [MonitorFlag] = []
        for day in days {
            let path = file(uid, day: day)
            let first = total
            total += flagCount(atPath: path)
            guard total > query.skip, first < pageEnd,
                  let data = FileManager.default.contents(atPath: path) else { continue }
            // Decoded the same way it was counted, so the page lines up with
            // the total. Capped at the count in case the file grew since.
            let newest = Self.decodeLines(data).prefix(total - first).sorted { $0.start > $1.start }
            let lo = max(0, query.skip - first)
            let hi = min(newest.count, pageEnd - first)
            if lo < hi { page += newest[lo..<hi] }
        }
        return MonitorRangePage(flags: page, total: total)
    }

    // MARK: flags from before the split

    /// Marks that `importLegacyFlags` has run.
    public var legacyImportMarker: String { directory + "/.imported-activity-flags" }

    public var legacyFlagsImported: Bool { FileManager.default.fileExists(atPath: legacyImportMarker) }

    /// The flags the app saved inside visits before the Monitor had its own
    /// log, read from an activity log directory, per user. Only reads, so it
    /// can run off renewd's state queue.
    public static func legacyFlags(inActivityDir activityDir: String) -> [uid_t: [MonitorFlag]] {
        struct OldLine: Decodable {
            var id: UUID?
            var start: Date
            var end: Date
            var browser: String
            var url: String
            var host: String
            var title: String
            var flags: [ActivityFlag]?
        }
        let fm = FileManager.default
        let decoder = Wire.decoder
        var out: [uid_t: [MonitorFlag]] = [:]
        for user in (try? fm.contentsOfDirectory(atPath: activityDir)) ?? [] {
            guard let uid = uid_t(user) else { continue }
            let dir = activityDir + "/" + user
            for name in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where name.hasSuffix(".jsonl") {
                guard let data = fm.contents(atPath: dir + "/" + name) else { continue }
                for line in data.split(separator: 0x0A) where !line.isEmpty {
                    // Cheap check first: most lines never had flags.
                    guard line.range(of: Data(#""flags":[{"#.utf8)) != nil,
                          let old = try? decoder.decode(OldLine.self, from: line),
                          let flags = old.flags, !flags.isEmpty else { continue }
                    let e = ActivityEvent(id: old.id, start: old.start, end: old.end, browser: old.browser,
                                          url: old.url, host: old.host, title: old.title)
                    out[uid, default: []].append(MonitorFlag(event: e, flags: Array(flags.prefix(ActivityFlag.maxPerVisit)),
                                                             flaggedAt: old.end))
                }
            }
        }
        return out
    }

    /// Adds old flags (from `legacyFlags`) to the log, skipping visits it
    /// already has, and marks the import done.
    @discardableResult
    public func importLegacyFlags(_ byUser: [uid_t: [MonitorFlag]], now: Date = Date()) -> Int {
        let tz = ActivityLogStore.systemTimeZone
        var imported = 0
        for (uid, flags) in byUser {
            var known: [String: Set<UUID>] = [:]
            let fresh = flags.filter { f in
                guard let id = f.eventID else { return true }
                let day = ActivityLogStore.dayKey(f.start, timeZone: tz)
                if known[day] == nil {
                    known[day] = Set(read(MonitorQuery(day: day), uid: uid).flags.compactMap(\.eventID))
                }
                return known[day]!.insert(id).inserted
            }
            imported += append(fresh, uid: uid, now: now)
        }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: legacyImportMarker, contents: Data(), attributes: [.posixPermissions: 0o600])
        return imported
    }

    /// Deletes day files past the retention period. Returns how many went.
    @discardableResult
    public func prune(now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let users = try? fm.contentsOfDirectory(atPath: directory) else { return 0 }
        let tz = ActivityLogStore.systemTimeZone
        var removed = 0
        for user in users where uid_t(user) != nil {
            let dir = directory + "/" + user
            for day in Self.dayFiles(inUserDir: dir) {
                guard ActivityLogStore.isExpired(day: day, now: now, timeZone: tz, retention: Self.retentionDays) else { continue }
                let path = dir + "/\(day).jsonl"
                if (try? fm.removeItem(atPath: path)) != nil {
                    flagCounts[path] = nil
                    removed += 1
                }
            }
        }
        return removed
    }
}
