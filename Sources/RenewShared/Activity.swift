import Foundation

// Activity records the pages you visit (URL, title, time on page): the app
// watches, renewd keeps the log (see `ActivityLogStore`). The Monitor reads
// that activity as it arrives in renewd and flags visits that match its rules
// (see `MonitorSettings`, `MonitorLogStore`).

/// Whether Activity records page visits. renewd owns it, per user. Off out of the box.
public struct ActivitySettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// When renewd last turned it off, so visits that started while it was
    /// still on (sent late by the app) are still taken. Set by renewd only;
    /// nil if it was never on.
    public var offSince: Date?

    public init(enabled: Bool = false, offSince: Date? = nil) {
        self.enabled = enabled
        self.offSince = offSince
    }

    public static let off = ActivitySettings()

    private enum CodingKeys: String, CodingKey { case enabled, offSince }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        offSince = try c.decodeIfPresent(Date.self, forKey: .offSince)
    }

    /// Whether renewd should take a visit that started at `start`: any while
    /// it's on, and ones that started before it was turned off.
    public func accepts(visitStartingAt start: Date) -> Bool {
        if enabled { return true }
        guard let offSince else { return false }
        return start <= offSince
    }
}

/// What the Monitor flags in recorded activity. renewd owns it, per user,
/// and does the matching itself. Off out of the box, with nothing watched.
public struct MonitorSettings: Codable, Equatable, Sendable {
    /// Check new visits at all. Needs Activity on to have anything to check.
    public var enabled: Bool
    /// Lists whose sites get flagged: `explicitListName` (the bundled preset)
    /// or any blocklist name (social, video, your own lists…).
    public var watchLists: [String]
    /// The rules of each watched blocklist, copied in by the app or CLI:
    /// blocklists live in the user's home folder, where renewd doesn't look.
    public var listRules: [String: [String]]
    /// Extra sites to flag, in blocklist rule syntax.
    public var customDomains: [String]
    /// Flag explicit content: page titles with words from `ExplicitTerms`,
    /// and on mixed sites (`SiteCategory.mixed`) stricter title scoring and
    /// reading the page for the site's own NSFW labels and strong explicit
    /// words (`PageSignals`). Shown as "Flag explicit content".
    public var flagExplicitTerms: Bool
    /// Extra words or phrases to flag in page titles.
    public var customTerms: [String]

    public static let explicitListName = "explicit"
    /// The flag label used for `customDomains`.
    public static let customListName = "custom"
    public static let maxWatchLists = 50
    /// The most rules kept across all of `listRules`.
    public static let maxListRules = 5_000
    public static let maxCustomDomains = 500
    public static let maxCustomTerms = 200
    public static let maxTermLength = 64

    public init(enabled: Bool = false, watchLists: [String] = [], listRules: [String: [String]] = [:],
                customDomains: [String] = [], flagExplicitTerms: Bool = false, customTerms: [String] = []) {
        self.enabled = enabled
        self.watchLists = watchLists
        self.listRules = listRules
        self.customDomains = customDomains
        self.flagExplicitTerms = flagExplicitTerms
        self.customTerms = customTerms
    }

    /// Off, with nothing watched: no lists, sites or words are flagged
    /// until you pick them.
    public static let off = MonitorSettings()

    private enum CodingKeys: String, CodingKey {
        case enabled, watchLists, listRules, customDomains, flagExplicitTerms, customTerms
    }

    /// Missing keys take their defaults, so older and newer files both read
    /// (including the combined settings kept before Activity and the Monitor
    /// were split).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MonitorSettings.off
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        watchLists = try c.decodeIfPresent([String].self, forKey: .watchLists) ?? d.watchLists
        listRules = try c.decodeIfPresent([String: [String]].self, forKey: .listRules) ?? d.listRules
        customDomains = try c.decodeIfPresent([String].self, forKey: .customDomains) ?? d.customDomains
        flagExplicitTerms = try c.decodeIfPresent(Bool.self, forKey: .flagExplicitTerms) ?? d.flagExplicitTerms
        customTerms = try c.decodeIfPresent([String].self, forKey: .customTerms) ?? d.customTerms
    }

    /// Lowercased, de-duplicated and capped; invalid sites and empty words
    /// dropped, and rules kept only for watched lists.
    public func normalized() -> MonitorSettings {
        var s = self
        s.watchLists = Array(Self.dedupe(watchLists.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            .prefix(Self.maxWatchLists))
        var rules: [String: [String]] = [:]
        var budget = Self.maxListRules
        for name in s.watchLists where name != Self.explicitListName {
            guard budget > 0, let r = listRules[name] ?? listRules.first(where: { $0.key.lowercased() == name })?.value
            else { continue }
            let kept = Array(Self.dedupe(r.map { $0.trimmingCharacters(in: .whitespaces) }).prefix(budget))
                .map { String($0.prefix(512)) }
            budget -= kept.count
            if !kept.isEmpty { rules[name] = kept }
        }
        s.listRules = rules
        s.customDomains = Array(canonicalRules(customDomains).valid.prefix(Self.maxCustomDomains))
        s.customTerms = Array(Self.dedupe(customTerms.map(Self.cleanTerm)).filter { $0.count <= Self.maxTermLength }
            .prefix(Self.maxCustomTerms))
        return s
    }

    /// These settings with `listRules` filled in from `lists` (normally
    /// `ListStore.all()`) for every watched blocklist.
    public func withListRules(from lists: [String: [String]]) -> MonitorSettings {
        var s = self
        var rules: [String: [String]] = [:]
        for name in watchLists where name != Self.explicitListName {
            if let r = lists[name.lowercased()] { rules[name.lowercased()] = r }
        }
        s.listRules = rules
        return s
    }

    /// Collapses whitespace and lowercases a typed word or phrase.
    public static func cleanTerm(_ raw: String) -> String {
        raw.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// The combined settings kept before Activity and the Monitor were split.
/// Only read, to move old state files over (and from daemons that predate
/// the split).
public struct LegacyMonitoringSettings: Codable, Equatable, Sendable {
    public var activity: ActivitySettings
    public var monitor: MonitorSettings

    public init(from decoder: Decoder) throws {
        activity = try ActivitySettings(from: decoder)
        monitor = try MonitorSettings(from: decoder)
    }

    /// Written back as one combined value (only if a migration hasn't run yet).
    public func encode(to encoder: Encoder) throws {
        var m = monitor
        m.enabled = activity.enabled
        try m.encode(to: encoder)
    }
}

/// Why a visit was flagged.
public struct ActivityFlag: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case domain, term }

    public var kind: Kind
    /// For `.domain`: the watch list that matched (`explicit`, `custom`, or a blocklist name).
    /// For `.term`: `scoreList` when no single word matched but enough
    /// suggestive words added up (see `isScore`), `labelList` for a site's
    /// own NSFW marking, `pageList` for explicit words in the page text;
    /// otherwise nil.
    public var list: String?
    /// The rule or domain that matched, the word found in the title, or for
    /// a score flag the words that added up ("a, b, c").
    public var match: String

    public init(kind: Kind, list: String? = nil, match: String) {
        self.kind = kind
        self.list = list
        self.match = match
    }

    public static let maxPerVisit = 20

    public static func domain(_ list: String, _ match: String) -> ActivityFlag { ActivityFlag(kind: .domain, list: list, match: match) }
    public static func term(_ match: String) -> ActivityFlag { ActivityFlag(kind: .term, match: match) }
    /// A score flag is stored as a `.term` flag tagged with `scoreList`, so
    /// builds that predate scores still read it (as "Word: …") instead of
    /// dropping the visit.
    public static func score(_ words: String) -> ActivityFlag { ActivityFlag(kind: .term, list: scoreList, match: words) }
    public static let scoreList = "score"
    public var isScore: Bool { kind == .term && list == Self.scoreList }

    /// A site's own NSFW/18+ marking on the page (`SiteLabel`), stored like
    /// a score flag for the same reason.
    public static func siteLabel(_ id: String) -> ActivityFlag { ActivityFlag(kind: .term, list: labelList, match: id) }
    public static let labelList = "label"
    public var isSiteLabel: Bool { kind == .term && list == Self.labelList }

    /// Strong explicit words in the page text ("a, b, c").
    public static func pageWords(_ words: String) -> ActivityFlag { ActivityFlag(kind: .term, list: pageList, match: words) }
    public static let pageList = "page"
    public var isPageWords: Bool { kind == .term && list == Self.pageList }

    /// "Explicit site", "Social list", "Watched site", "Word: …", "Likely explicit: …",
    /// "Site label: …" or "Page words: …".
    public var label: String {
        switch kind {
        case .term:
            if isScore { return "Likely explicit: \(match)" }
            if isSiteLabel { return "Site label: \(match)" }
            if isPageWords { return "Page words: \(match)" }
            return "Word: \(match)"
        case .domain:
            switch list {
            case MonitorSettings.explicitListName?: return "Explicit site"
            case MonitorSettings.customListName?, nil: return "Watched site"
            case let name?: return "\(name.capitalized) list"
            }
        }
    }
}

/// One page visit.
public struct ActivityEvent: Codable, Equatable, Sendable {
    /// Lets renewd drop a visit it already stored (a batch re-sent after the
    /// app quit mid-upload). nil only in events from before ids existed.
    public var id: UUID?
    public var start: Date
    public var end: Date
    /// The browser or app showing the page ("Safari", "T3 Code"…).
    public var browser: String
    public var url: String
    public var host: String
    public var title: String
    /// A running block session replaced the page with the block page.
    public var blocked: Bool
    /// What page reading found on a mixed site, if anything.
    public var signals: PageSignals?

    public init(id: UUID? = UUID(), start: Date, end: Date, browser: String, url: String, host: String, title: String,
                blocked: Bool = false, signals: PageSignals? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.browser = browser
        self.url = url
        self.host = host
        self.title = title
        self.blocked = blocked
        self.signals = signals.flatMap { $0.isEmpty ? nil : $0 }
    }

    // Old log lines also carry `flags` (from when the app flagged visits);
    // they're ignored; the Monitor keeps its own log.
    private enum CodingKeys: String, CodingKey { case id, start, end, browser, url, host, title, blocked, signals }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        browser = try c.decode(String.self, forKey: .browser)
        url = try c.decode(String.self, forKey: .url)
        host = try c.decode(String.self, forKey: .host)
        title = try c.decode(String.self, forKey: .title)
        blocked = try c.decodeIfPresent(Bool.self, forKey: .blocked) ?? false
        signals = try c.decodeIfPresent(PageSignals.self, forKey: .signals)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(browser, forKey: .browser)
        try c.encode(url, forKey: .url)
        try c.encode(host, forKey: .host)
        try c.encode(title, forKey: .title)
        try c.encode(blocked, forKey: .blocked)
        if let signals, !signals.isEmpty { try c.encode(signals, forKey: .signals) }
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public static let maxURLLength = 2_048
    public static let maxTitleLength = 512
    public static let maxNameLength = 128
    /// Longer visits are cut to this.
    public static let maxDuration: TimeInterval = 24 * 3_600

    /// The event with every field capped, or nil if it's malformed (no host,
    /// ends before it starts, dated in the future, or older than the log keeps).
    public func sanitized(now: Date = Date()) -> ActivityEvent? {
        let oldest = now.addingTimeInterval(-TimeInterval(ActivityLogStore.retentionDays) * 86_400)
        guard end >= start, start <= now.addingTimeInterval(300), start >= oldest else { return nil }
        var e = self
        e.url = String(url.prefix(Self.maxURLLength))
        e.title = String(title.prefix(Self.maxTitleLength))
        e.browser = String(browser.prefix(Self.maxNameLength))
        e.host = String(host.prefix(253))
        e.signals = signals.map { $0.capped() }.flatMap { $0.isEmpty ? nil : $0 }
        guard !e.host.isEmpty else { return nil }
        if e.duration > Self.maxDuration { e.end = e.start.addingTimeInterval(Self.maxDuration) }
        return e
    }
}

// MARK: matching

/// A large set of domains, each matching itself and its subdomains. Lookups
/// walk the host's suffixes, so they cost one hash per label however big the
/// set is.
public struct DomainSet: Sendable {
    private let hosts: Set<String>

    public init<S: Sequence>(_ domains: S) where S.Element == String {
        var set = Set<String>()
        for d in domains {
            let h = Rule.normalizeHost(d.trimmingCharacters(in: .whitespaces))
            if h.contains(".") { set.insert(h) }
        }
        hosts = set
    }

    /// One domain per line; blank lines and `#` comments are skipped.
    public init(fileContents: String) {
        self.init(fileContents.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    public var count: Int { hosts.count }

    /// The listed domain `host` falls under, or nil.
    public func match(host: String) -> String? {
        let h = Rule.normalizeHost(host)
        var rest = Substring(h)
        while rest.contains(".") {
            if hosts.contains(String(rest)) { return String(rest) }
            guard let dot = rest.firstIndex(of: ".") else { break }
            rest = rest[rest.index(after: dot)...]
        }
        return nil
    }
}

/// Finds whole words or phrases in text, ignoring case and accents. Terms
/// of `minDisguisedLength`+ characters also match disguised spellings
/// (`TitleNormalizer.variants`); shorter ones match only as written, so a
/// word like "ed" doesn't start matching "3D".
public struct TermMatcher: Sendable {
    private let terms: [(term: String, words: [String], disguisable: Bool)]

    public static let minDisguisedLength = 4

    public init(_ terms: [String]) {
        var seen = Set<String>()
        self.terms = terms.compactMap {
            let words = Self.words($0)
            guard !words.isEmpty, seen.insert(words.joined(separator: " ")).inserted else { return nil }
            return ($0, words, words.joined().count >= Self.minDisguisedLength)
        }
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// Every term found in `text`, in the order they were given.
    public func matches(in text: String) -> [String] {
        terms.isEmpty ? [] : matches(variants: TitleNormalizer.variants(text))
    }

    /// The same, for words already normalized by `TitleNormalizer.variants`.
    func matches(variants: [[String]]) -> [String] {
        guard let plain = variants.first else { return [] }
        return terms.filter { t in
            Self.contains(plain, t.words) || (t.disguisable && variants.dropFirst().contains { Self.contains($0, t.words) })
        }.map(\.term)
    }

    /// Lowercased, accent-free runs of letters and digits.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    static func contains(_ words: [String], _ phrase: [String]) -> Bool {
        guard phrase.count <= words.count else { return false }
        if phrase.count == 1 { return words.contains(phrase[0]) }
        for i in 0...(words.count - phrase.count) where words[i] == phrase[0] {
            if Array(words[i..<(i + phrase.count)]) == phrase { return true }
        }
        return false
    }
}

/// Decides which flags a page gets under the Monitor's settings.
///
/// Work sites (`SiteCategory.work`) are never flagged. Mixed sites get
/// stricter title scoring and their page findings (`PageSignals`) checked
/// when `flagExplicitTerms` is on.
public struct ActivityMatcher: Sendable {
    private let explicit: DomainSet?
    private let watched: [(list: String, rules: RuleSet)]
    private let explicitTerms: ExplicitScorer?
    private let terms: TermMatcher

    /// Strong words in a page's text needed to flag it.
    public static let minPageWords = 3
    /// What site labels on a feed (post labels and hints) add to the title
    /// score, all together: never enough to flag on their own, so the title
    /// must also have explicit words.
    public static let feedLabelWeight = 0.5

    /// Blocklist rules come from `settings.listRules`; `explicitDomains` is
    /// the bundled preset, or nil if it isn't loaded.
    public init(settings: MonitorSettings, explicitDomains: DomainSet?) {
        let s = settings.normalized()
        explicit = s.watchLists.contains(MonitorSettings.explicitListName) ? explicitDomains : nil
        var watched: [(String, RuleSet)] = []
        for name in s.watchLists where name != MonitorSettings.explicitListName {
            if let rules = s.listRules[name], !rules.isEmpty { watched.append((name, RuleSet(strings: rules))) }
        }
        if !s.customDomains.isEmpty { watched.append((MonitorSettings.customListName, RuleSet(strings: s.customDomains))) }
        self.watched = watched
        explicitTerms = s.flagExplicitTerms ? .preset : nil
        terms = TermMatcher(s.customTerms)
    }

    /// Whether nothing at all is watched.
    public var isEmpty: Bool {
        explicit == nil && watched.isEmpty && explicitTerms == nil && terms.isEmpty
    }

    public func flags(url: String, title: String, signals: PageSignals? = nil) -> [ActivityFlag] {
        let n = NormalizedURL(url)
        let category = SiteCategory.of(url: url)
        if category == .work { return [] }
        let mixed = explicitTerms != nil && category == .mixed

        var out: [ActivityFlag] = []
        if let n {
            if let hit = explicit?.match(host: n.host) { out.append(.domain(MonitorSettings.explicitListName, hit)) }
            for (list, rules) in watched {
                if let rule = rules.match(url) { out.append(.domain(list, rule.description)) }
            }
        }

        // The site's own labels: page-wide ones, or post ones on a single
        // post, flag; post ones on a feed, and hints, only add to the score.
        var feedLabels: [String] = []
        if mixed, let signals {
            let single = PostURL.isSinglePost(url)
            for id in signals.labels {
                switch SiteLabel.named(id)?.scope {
                case .page?: out.append(.siteLabel(id))
                case .post?, nil: if single { out.append(.siteLabel(id)) } else { feedLabels.append(id) }
                case .hint?: feedLabels.append(id)
                }
            }
            if signals.strongWords.count >= Self.minPageWords {
                out.append(.pageWords(signals.strongWords.joined(separator: ", ")))
            }
        }

        // Normalized once for both the built-in words and your own.
        let variants = explicitTerms == nil && terms.isEmpty ? [] : TitleNormalizer.variants(title)
        var found = Set<String>()
        if let r = explicitTerms?.evaluate(variants: variants, masked: TitleNormalizer.maskedWords(title),
                                           policy: mixed ? .mixed : .standard,
                                           extra: feedLabels.isEmpty ? [] : [(feedLabels.map { "site label: \($0)" }
                                               .joined(separator: ", "), Self.feedLabelWeight)]) {
            for t in r.strong { out.append(.term(t)); found.insert(TermMatcher.words(t).joined(separator: " ")) }
            if r.strong.isEmpty && r.flagged { out.append(.score(r.contributors.joined(separator: ", "))) }
        }
        for t in terms.matches(variants: variants) where !found.contains(TermMatcher.words(t).joined(separator: " ")) {
            out.append(.term(t))
        }
        return Array(out.prefix(ActivityFlag.maxPerVisit))
    }
}

// MARK: visits

/// A page seen on screen at one moment.
public struct PageObservation: Equatable, Sendable {
    /// What's showing it: a browser's bundle ID, or an app with a built-in browser.
    public var source: String
    public var browser: String
    public var url: String
    public var title: String
    public var blocked: Bool
    /// What page reading found, if the page was read this time.
    public var signals: PageSignals?

    public init(source: String, browser: String, url: String, title: String, blocked: Bool = false,
                signals: PageSignals? = nil) {
        self.source = source
        self.browser = browser
        self.url = url
        self.title = title
        self.blocked = blocked
        self.signals = signals
    }
}

/// Turns repeated looks at the screen into visits.
///
/// Each channel (the front browser, the built-in browser of the front app…)
/// reports everything it sees on every look. A page still there extends its
/// visit; a page that's gone ends it. A new title on the same URL (single-page
/// sites) updates the visit rather than starting a new one.
public struct VisitTracker: Sendable {
    private struct Key: Hashable { var channel: String; var source: String; var url: String }
    private struct Open { var event: ActivityEvent; var order: Int }

    private var open: [Key: Open] = [:]
    private var counter = 0
    /// Visits shorter than this are dropped (redirects, pages flicked past),
    /// unless the page was blocked.
    public var minDuration: TimeInterval

    public init(minDuration: TimeInterval = 1) {
        self.minDuration = minDuration
    }

    public var openCount: Int { open.count }

    /// Records what `channel` sees at `now` and returns the visits that ended.
    public mutating func observe(_ pages: [PageObservation], channel: String, at now: Date) -> [ActivityEvent] {
        var seen = Set<Key>()
        for p in pages {
            guard let host = NormalizedURL(p.url)?.host else { continue }
            let key = Key(channel: channel, source: p.source, url: p.url)
            guard seen.insert(key).inserted else { continue }
            if var o = open[key] {
                if !p.title.isEmpty { o.event.title = p.title }
                o.event.blocked = o.event.blocked || p.blocked
                if let found = p.signals, !found.isEmpty {
                    o.event.signals = (o.event.signals ?? PageSignals()).merged(with: found)
                }
                o.event.end = now
                open[key] = o
            } else {
                counter += 1
                open[key] = Open(event: ActivityEvent(start: now, end: now, browser: p.browser, url: p.url, host: host,
                                                      title: p.title.isEmpty ? host : p.title,
                                                      blocked: p.blocked, signals: p.signals?.capped()),
                                 order: counter)
            }
        }
        let gone = open.keys.filter { $0.channel == channel && !seen.contains($0) }
        return finish(gone, at: now)
    }

    /// Ends every open visit (Activity turned off, the user went idle, Renew quitting).
    public mutating func closeAll(at now: Date) -> [ActivityEvent] {
        finish(Array(open.keys), at: now)
    }

    private mutating func finish(_ keys: [Key], at now: Date) -> [ActivityEvent] {
        var done: [(Int, ActivityEvent)] = []
        for k in keys {
            guard var o = open.removeValue(forKey: k) else { continue }
            o.event.end = max(o.event.start, now)
            if o.event.duration >= minDuration || o.event.blocked { done.append((o.order, o.event)) }
        }
        return done.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
