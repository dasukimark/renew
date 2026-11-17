import Foundation

// Time per site: renewd sums each day's visits into a small per-site summary
// (`DaySummary`), kept for a year, long after the visits themselves go. The
// app and CLI ask for a range of days and work out totals and averages from
// those summaries (`ActivityStatsReport`).

/// Groups hosts under the site they belong to, so `m.youtube.com` and
/// `music.youtube.com` both count as `youtube.com`.
public enum SiteKey {
    /// Second-level labels used under two-letter country domains
    /// (`bbc.co.uk`, `abc.net.au`).
    static let secondLevels: Set<String> = ["co", "com", "net", "org", "ac", "gov", "edu"]

    /// The main site `host` belongs to: its last two labels, or three under a
    /// country domain like `co.uk`. IP addresses and single-label hosts are
    /// returned as they are.
    public static func site(forHost host: String) -> String {
        let h = Rule.normalizeHost(host)
        guard !h.contains(":") else { return h } // IPv6
        let labels = h.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count > 2, !labels.contains(where: \.isEmpty) else { return h }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return h } // IPv4
        let tld = labels[labels.count - 1], second = labels[labels.count - 2]
        let keep = tld.count == 2 && secondLevels.contains(second) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }
}

/// Seconds spent on each site in one day.
public struct DaySummary: Codable, Equatable, Sendable {
    /// Local day, `yyyy-MM-dd`.
    public var day: String
    /// Time on any site. Overlapping visits count once, so this can be less
    /// than the sum of `sites`.
    public var totalSeconds: Int
    /// Site (see `SiteKey`) → seconds.
    public var sites: [String: Int]

    /// The most sites kept per day; the rest are added up under `otherSite`.
    public static let maxSites = 500
    /// Where sites past a cap are added up. Not a valid host name, so no real
    /// site can collide with it.
    public static let otherSite = "(other)"

    public init(day: String, totalSeconds: Int, sites: [String: Int]) {
        self.day = day
        self.totalSeconds = totalSeconds
        self.sites = sites
    }

    /// Sums one day's visits. Overlapping visits to the same site (two windows
    /// showing it, a browser and an app's built-in browser) count once.
    public static func build(day: String, events: [ActivityEvent]) -> DaySummary {
        var b = Builder()
        b.add(events)
        return b.summary(day: day)
    }

    /// Adds up visits a batch at a time, keeping each site's time as merged
    /// intervals, so a growing day can be updated without re-reading it.
    public struct Builder: Sendable {
        private var bySite: [String: [(Date, Date)]] = [:]
        private var all: [(Date, Date)] = []

        public init() {}

        public mutating func add(_ events: [ActivityEvent]) {
            guard !events.isEmpty else { return }
            var touched = Set<String>()
            for e in events where e.end > e.start {
                let site = SiteKey.site(forHost: e.host)
                bySite[site, default: []].append((e.start, e.end))
                all.append((e.start, e.end))
                touched.insert(site)
            }
            for site in touched { bySite[site] = DaySummary.merge(bySite[site] ?? []) }
            all = DaySummary.merge(all)
        }

        public func summary(day: String) -> DaySummary {
            let sites = bySite.mapValues { Int(DaySummary.length($0).rounded()) }.filter { $0.value > 0 }
            return DaySummary(day: day, totalSeconds: Int(DaySummary.length(all).rounded()), sites: sites)
                .capped(DaySummary.maxSites)
        }
    }

    /// Keeps the same sites on every day: the `limit - 1` with the most time
    /// over all of `summaries`, plus `keep` if given. The rest are added up
    /// under `otherSite`, so a site's total over the range is never cut short
    /// on days it happened to rank low.
    public static func cappedTogether(_ summaries: [DaySummary], limit: Int, keep: String? = nil) -> [DaySummary] {
        var totals: [String: Int] = [:]
        for s in summaries { for (site, secs) in s.sites where site != otherSite { totals[site, default: 0] += secs } }
        guard totals.count > limit - 1 else { return summaries }
        var kept = Set(totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(max(0, limit - 1)).map(\.key))
        if let keep { kept.insert(keep) }
        return summaries.map { s in
            var sites: [String: Int] = [:]
            for (site, secs) in s.sites {
                if kept.contains(site) { sites[site] = secs } else { sites[otherSite, default: 0] += secs }
            }
            return DaySummary(day: s.day, totalSeconds: s.totalSeconds, sites: sites)
        }
    }

    /// The summary with at most `limit` sites, the rest folded into `otherSite`.
    public func capped(_ limit: Int) -> DaySummary {
        guard sites.count > limit else { return self }
        let sorted = sites.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var kept = Dictionary(uniqueKeysWithValues: sorted.prefix(max(0, limit - 1)).map { ($0.key, $0.value) })
        kept[Self.otherSite, default: 0] += sorted.dropFirst(max(0, limit - 1)).reduce(0) { $0 + $1.value }
        return DaySummary(day: day, totalSeconds: totalSeconds, sites: kept)
    }

    /// `intervals` sorted, with overlapping ones joined.
    static func merge(_ intervals: [(Date, Date)]) -> [(Date, Date)] {
        var out: [(Date, Date)] = []
        for iv in intervals.sorted(by: { $0.0 < $1.0 }) {
            if let last = out.last, iv.0 <= last.1 {
                out[out.count - 1].1 = max(last.1, iv.1)
            } else {
                out.append(iv)
            }
        }
        return out
    }

    /// Total length of already merged intervals.
    static func length(_ merged: [(Date, Date)]) -> TimeInterval {
        merged.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
    }
}

/// A range of days to sum, both ends included.
public struct ActivityStatsQuery: Codable, Equatable, Sendable {
    /// First and last local day, `yyyy-MM-dd`.
    public var from: String
    public var to: String
    /// A site (see `SiteKey`) to keep in the reply however little time it
    /// had, so it's never folded into `DaySummary.otherSite`.
    public var site: String?

    public static let maxDays = 366
    public static let maxSiteLength = 253

    public init(from: String, to: String, site: String? = nil) {
        self.from = from
        self.to = to
        self.site = site.map { String($0.prefix(Self.maxSiteLength)) }
    }

    /// The `days` days ending with the one `end` falls on.
    public init(lastDays days: Int, endingAt end: Date = Date(), site: String? = nil,
                timeZone: TimeZone = ActivityLogStore.systemTimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let last = cal.startOfDay(for: end)
        let first = cal.date(byAdding: .day, value: -(max(1, days) - 1), to: last) ?? last
        self.init(from: ActivityLogStore.dayKey(first, timeZone: timeZone), to: ActivityLogStore.dayKey(end, timeZone: timeZone),
                  site: site)
    }

    /// Every day in the range, oldest first, or nil if either end isn't a
    /// valid day, they're reversed, or the range is longer than `maxDays`.
    public func dayKeys(timeZone: TimeZone = ActivityLogStore.systemTimeZone) -> [String]? {
        guard let start = ActivityLogStore.date(ofDay: from, timeZone: timeZone),
              ActivityLogStore.date(ofDay: to, timeZone: timeZone) != nil, from <= to else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var keys: [String] = []
        var i = 0
        while true {
            // Noon, so a daylight-saving change never lands on the wrong day.
            guard let d = cal.date(byAdding: DateComponents(day: i, hour: 12), to: start) else { return nil }
            let key = ActivityLogStore.dayKey(d, timeZone: timeZone)
            if key > to { break }
            keys.append(key)
            if keys.count > Self.maxDays { return nil }
            i += 1
        }
        return keys
    }

    /// Sites kept in a reply (the same ones every day), so a year's worth
    /// stays a manageable size.
    public static func sitesPerDay(forDays days: Int) -> Int {
        min(DaySummary.maxSites, max(50, 40_000 / max(1, days)))
    }
}

/// Totals and averages over a range of days.
public struct ActivityStatsReport: Sendable {
    public struct Day: Equatable, Sendable {
        public var day: String
        public var date: Date
        public var seconds: Int
    }

    public struct Site: Equatable, Sendable {
        public var site: String
        public var totalSeconds: Int
        /// Of the time on all sites (0…1).
        public var share: Double
        /// `totalSeconds` over `ActivityStatsReport.averageDays`.
        public var dailyAverage: Double
    }

    /// Every day in the range, oldest first, with zero for days without data.
    public let days: [Day]
    public let totalSeconds: Int
    /// The days averages are taken over: from the first day with any data
    /// through the end of the range. 0 if there's no data.
    public let averageDays: Int
    /// Most time first.
    public let sites: [Site]
    private let byDay: [String: DaySummary]

    public var dailyAverage: Double { averageDays > 0 ? Double(totalSeconds) / Double(averageDays) : 0 }
    public var isEmpty: Bool { totalSeconds == 0 && sites.isEmpty }

    public init(query: ActivityStatsQuery, summaries: [DaySummary], timeZone: TimeZone = ActivityLogStore.systemTimeZone) {
        let keys = query.dayKeys(timeZone: timeZone) ?? []
        let inRange = Set(keys)
        var byDay: [String: DaySummary] = [:]
        for s in summaries where inRange.contains(s.day) { byDay[s.day] = s }
        self.byDay = byDay
        days = keys.map { Day(day: $0, date: ActivityLogStore.date(ofDay: $0, timeZone: timeZone) ?? Date(),
                              seconds: byDay[$0]?.totalSeconds ?? 0) }
        totalSeconds = days.reduce(0) { $0 + $1.seconds }
        if let first = keys.firstIndex(where: { byDay[$0].map { $0.totalSeconds > 0 || !$0.sites.isEmpty } ?? false }) {
            averageDays = keys.count - first
        } else {
            averageDays = 0
        }
        var totals: [String: Int] = [:]
        for s in byDay.values { for (site, secs) in s.sites { totals[site, default: 0] += secs } }
        let siteSum = totals.values.reduce(0, +)
        let n = averageDays
        sites = totals.map { site, secs in
            Site(site: site, totalSeconds: secs, share: siteSum > 0 ? Double(secs) / Double(siteSum) : 0,
                 dailyAverage: n > 0 ? Double(secs) / Double(n) : 0)
        }
        .sorted { $0.totalSeconds != $1.totalSeconds ? $0.totalSeconds > $1.totalSeconds : $0.site < $1.site }
    }

    /// Seconds on `site` each day of the range, zero-filled.
    public func days(for site: String) -> [Day] {
        days.map { d in var d = d; d.seconds = byDay[d.day]?.sites[site] ?? 0; return d }
    }

    public func site(_ name: String) -> Site? { sites.first { $0.site == name } }

    /// The site with the most time, not counting `DaySummary.otherSite`.
    public var topSite: Site? { sites.first { $0.site != DaySummary.otherSite } }
}
