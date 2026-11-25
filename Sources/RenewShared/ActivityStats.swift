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

/// Splits a site into the parts people think of as separate apps, so
/// `mail.google.com` (Gmail) and `docs.google.com/spreadsheets` (Google
/// Sheets) can be told apart while both still count towards `google.com`.
public enum SiteSection {
    /// Prefixes that are the same page on another device, not another part.
    static let samePrefixes = ["www.", "m.", "mobile."]

    /// Hosts where the first part of the path picks the app.
    static let pathSections: [String: Set<String>] = [
        "docs.google.com": ["document", "spreadsheets", "presentation", "forms", "drawings"],
        "google.com": ["maps"],
    ]

    /// Names for well-known sections. Anything else is shown by its host.
    static let names: [String: String] = [
        "mail.google.com": "Gmail",
        "docs.google.com/document": "Google Docs",
        "docs.google.com/spreadsheets": "Google Sheets",
        "docs.google.com/presentation": "Google Slides",
        "docs.google.com/forms": "Google Forms",
        "docs.google.com/drawings": "Google Drawings",
        "drive.google.com": "Google Drive",
        "calendar.google.com": "Google Calendar",
        "meet.google.com": "Google Meet",
        "chat.google.com": "Google Chat",
        "photos.google.com": "Google Photos",
        "keep.google.com": "Google Keep",
        "news.google.com": "Google News",
        "translate.google.com": "Google Translate",
        "gemini.google.com": "Gemini",
        "google.com/maps": "Google Maps",
        "maps.google.com": "Google Maps",
        "music.youtube.com": "YouTube Music",
        "studio.youtube.com": "YouTube Studio",
        "mail.yahoo.com": "Yahoo Mail",
        "outlook.live.com": "Outlook",
        "outlook.office.com": "Outlook",
        "onedrive.live.com": "OneDrive",
        "web.whatsapp.com": "WhatsApp",
        "old.reddit.com": "Old Reddit",
    ]

    /// The section a visit belongs to: its host without `www.` or `m.`,
    /// plus the first path part on hosts like `docs.google.com`.
    public static func section(forHost host: String, url: String = "") -> String {
        var h = Rule.normalizeHost(host)
        // Only while what's left is still the site or under it (`m.co` stays).
        for p in samePrefixes where h.hasPrefix(p) {
            let rest = String(h.dropFirst(p.count))
            if rest.hasSuffix(SiteKey.site(forHost: h)) && rest.contains(".") { h = rest }
        }
        guard let parts = pathSections[h], let first = firstPathPart(url), parts.contains(first) else { return h }
        return h + "/" + first
    }

    /// Where a site's parts past a cap are added up (`google.com/(other)`).
    public static func otherParts(of site: String) -> String { site + "/" + DaySummary.otherSite }

    public static func isOtherParts(_ section: String) -> Bool { section.hasSuffix("/" + DaySummary.otherSite) }

    /// The site (see `SiteKey`) a section counts towards.
    public static func site(of section: String) -> String {
        SiteKey.site(forHost: String(section.prefix { $0 != "/" }))
    }

    /// The section's everyday name ("Gmail"), or nil if it's only known by its host.
    public static func name(_ section: String) -> String? { isOtherParts(section) ? "Other parts" : names[section] }

    static func firstPathPart(_ url: String) -> String? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let rest = url[schemeEnd.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let path = rest[rest.index(after: slash)...]
        let first = path.prefix { $0 != "/" && $0 != "?" && $0 != "#" }.lowercased()
        return first.isEmpty ? nil : first
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
    /// Section (see `SiteSection`) → seconds, for the sites in `sites`.
    /// Overlapping visits count once per section, so a site's sections can
    /// add up to a little more than the site. nil in summaries saved before
    /// sections were kept.
    public var sections: [String: Int]?

    /// The most sites kept per day; the rest are added up under `otherSite`.
    public static let maxSites = 500
    /// The most parts kept per site per day; the rest are added up under
    /// `SiteSection.otherParts(of:)`.
    public static let maxPartsPerSite = 50
    /// Where sites past a cap are added up. Not a valid host name, so no real
    /// site can collide with it.
    public static let otherSite = "(other)"

    public init(day: String, totalSeconds: Int, sites: [String: Int], sections: [String: Int]? = nil) {
        self.day = day
        self.totalSeconds = totalSeconds
        self.sites = sites
        self.sections = sections
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
        private var bySection: [String: [(Date, Date)]] = [:]
        private var all: [(Date, Date)] = []

        public init() {}

        public mutating func add(_ events: [ActivityEvent]) {
            guard !events.isEmpty else { return }
            var touched = Set<String>(), touchedSections = Set<String>()
            for e in events where e.end > e.start {
                let site = SiteKey.site(forHost: e.host)
                let section = SiteSection.section(forHost: e.host, url: e.url)
                bySite[site, default: []].append((e.start, e.end))
                bySection[section, default: []].append((e.start, e.end))
                all.append((e.start, e.end))
                touched.insert(site)
                touchedSections.insert(section)
            }
            for site in touched { bySite[site] = DaySummary.merge(bySite[site] ?? []) }
            for s in touchedSections { bySection[s] = DaySummary.merge(bySection[s] ?? []) }
            all = DaySummary.merge(all)
        }

        public func summary(day: String) -> DaySummary {
            let sites = bySite.mapValues { Int(DaySummary.length($0).rounded()) }.filter { $0.value > 0 }
            let sections = bySection.mapValues { Int(DaySummary.length($0).rounded()) }.filter { $0.value > 0 }
            return DaySummary(day: day, totalSeconds: Int(DaySummary.length(all).rounded()), sites: sites,
                              sections: sections)
                .capped(DaySummary.maxSites)
        }
    }

    /// Keeps the same sites on every day: the `limit - 1` with the most time
    /// over all of `summaries`, plus `keep` if given. The rest are added up
    /// under `otherSite`, so a site's total over the range is never cut short
    /// on days it happened to rank low. Each kept site keeps its
    /// `partsPerSite` biggest parts over the range; the rest of its parts are
    /// added up under `SiteSection.otherParts(of:)`, so its breakdown still
    /// covers all of its time.
    public static func cappedTogether(_ summaries: [DaySummary], limit: Int, partsPerSite: Int = 10,
                                      keep: String? = nil) -> [DaySummary] {
        var totals: [String: Int] = [:]
        for s in summaries { for (site, secs) in s.sites where site != otherSite { totals[site, default: 0] += secs } }
        let kept: Set<String>? = totals.count > limit - 1
            ? Set(ranked(totals).prefix(max(0, limit - 1)).map(\.key) + (keep.map { [$0] } ?? []))
            : nil
        var sectionTotals: [String: Int] = [:]
        for s in summaries { for (section, secs) in s.sections ?? [:] { sectionTotals[section, default: 0] += secs } }
        let keptParts = topParts(sectionTotals, perSite: partsPerSite)
        if kept == nil && keptParts.count == sectionTotals.count { return summaries }
        return summaries.map { s in
            var sites = s.sites
            if let kept {
                sites = [:]
                for (site, secs) in s.sites {
                    if kept.contains(site) { sites[site] = secs } else { sites[otherSite, default: 0] += secs }
                }
            }
            return DaySummary(day: s.day, totalSeconds: s.totalSeconds, sites: sites,
                              sections: s.sections.map { fold($0, keeping: keptParts, sites: sites) })
        }
    }

    /// The summary with at most `limit` sites, the rest folded into
    /// `otherSite`, and at most `maxPartsPerSite` parts per site.
    public func capped(_ limit: Int) -> DaySummary {
        var out = self
        if sites.count > limit {
            let sorted = Self.ranked(sites)
            var kept = Dictionary(uniqueKeysWithValues: sorted.prefix(max(0, limit - 1)).map { ($0.key, $0.value) })
            kept[Self.otherSite, default: 0] += sorted.dropFirst(max(0, limit - 1)).reduce(0) { $0 + $1.value }
            out.sites = kept
        }
        if let sections = out.sections {
            out.sections = Self.fold(sections, keeping: Self.topParts(sections, perSite: Self.maxPartsPerSite), sites: out.sites)
        }
        return out
    }

    /// Most time first, then by name.
    static func ranked(_ t: [String: Int]) -> [(key: String, value: Int)] {
        t.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
    }

    /// Each site's `perSite` biggest parts in `totals`.
    static func topParts(_ totals: [String: Int], perSite: Int) -> Set<String> {
        var bySite: [String: [(key: String, value: Int)]] = [:]
        for (section, secs) in totals where !SiteSection.isOtherParts(section) {
            bySite[SiteSection.site(of: section), default: []].append((section, secs))
        }
        return Set(bySite.values.flatMap { ranked(Dictionary(uniqueKeysWithValues: $0.map { ($0.key, $0.value) }))
            .prefix(max(1, perSite)).map(\.key) })
    }

    /// `sections` for the sites in `sites`, with parts not in `keeping`
    /// added up under their site's `SiteSection.otherParts(of:)`.
    static func fold(_ sections: [String: Int], keeping: Set<String>, sites: [String: Int]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (section, secs) in sections {
            let site = SiteSection.site(of: section)
            guard sites[site] != nil else { continue }
            if keeping.contains(section) { out[section, default: 0] += secs }
            else { out[SiteSection.otherParts(of: site), default: 0] += secs }
        }
        return out
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

    /// Parts kept per site in a reply; fewer over long ranges, for size.
    public static func partsPerSite(forDays days: Int) -> Int { days > 31 ? 5 : 10 }
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
        /// The site's parts (see `SiteSection`), most time first. Empty when
        /// the days in range predate sections or it's `DaySummary.otherSite`.
        public var sections: [Section] = []

        /// Whether there's a split to show: at least two parts. A site only
        /// ever visited on one subdomain (`app.slack.com`) has nothing to compare.
        public var hasBreakdown: Bool { sections.count > 1 }

        /// The biggest part that says something the site's name doesn't: not
        /// the site itself, nor its "Other parts".
        public var topPart: Section? {
            sections.first { $0.section != site && !SiteSection.isOtherParts($0.section) }
        }
    }

    public struct Section: Equatable, Sendable {
        public var section: String
        public var totalSeconds: Int
        /// Of the time on its site (0…1). Overlaps between a site's sections
        /// count in each, so these can add up to a little over 1.
        public var share: Double
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
    /// How many of the days with activity have parts (see `SiteSection`).
    public enum PartsCoverage: Sendable { case all, some, none }
    /// Days summed before parts were kept (or by an older renewd) count
    /// towards each site but not towards its parts.
    public let partsCoverage: PartsCoverage
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
        var sectionTotals: [String: Int] = [:]
        for s in byDay.values { for (section, secs) in s.sections ?? [:] { sectionTotals[section, default: 0] += secs } }
        var sectionsBySite: [String: [Section]] = [:]
        for (section, secs) in sectionTotals {
            let site = SiteSection.site(of: section)
            let siteTotal = totals[site] ?? 0
            sectionsBySite[site, default: []].append(
                Section(section: section, totalSeconds: secs, share: siteTotal > 0 ? Double(secs) / Double(siteTotal) : 0,
                        dailyAverage: n > 0 ? Double(secs) / Double(n) : 0))
        }
        let active = byDay.values.filter { !$0.sites.isEmpty }
        let withParts = active.filter { $0.sections != nil }.count
        partsCoverage = withParts == active.count ? .all : withParts == 0 ? .none : .some
        sites = totals.map { site, secs in
            Site(site: site, totalSeconds: secs, share: siteSum > 0 ? Double(secs) / Double(siteSum) : 0,
                 dailyAverage: n > 0 ? Double(secs) / Double(n) : 0,
                 // Most time first, with "Other parts" last whatever its size.
                 sections: (sectionsBySite[site] ?? []).sorted { a, b in
                     let ao = SiteSection.isOtherParts(a.section), bo = SiteSection.isOtherParts(b.section)
                     if ao != bo { return bo }
                     return a.totalSeconds != b.totalSeconds ? a.totalSeconds > b.totalSeconds : a.section < b.section
                 })
        }
        .sorted { $0.totalSeconds != $1.totalSeconds ? $0.totalSeconds > $1.totalSeconds : $0.site < $1.site }
    }

    /// Seconds on `site` each day of the range, zero-filled.
    public func days(for site: String) -> [Day] {
        days.map { d in var d = d; d.seconds = byDay[d.day]?.sites[site] ?? 0; return d }
    }

    public func site(_ name: String) -> Site? { sites.first { $0.site == name } }

    /// Seconds on `section` each day of the range, zero-filled.
    public func days(forSection section: String) -> [Day] {
        days.map { d in var d = d; d.seconds = byDay[d.day]?.sections?[section] ?? 0; return d }
    }

    public func section(_ name: String) -> Section? { site(SiteSection.site(of: name))?.sections.first { $0.section == name } }

    /// The site with the most time, not counting `DaySummary.otherSite`.
    public var topSite: Site? { sites.first { $0.site != DaySummary.otherSite } }
}
