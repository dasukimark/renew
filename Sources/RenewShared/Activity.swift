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
    /// Monitoring lists: name → sites in blocklist rule syntax. Separate from
    /// blocklists (sites you still visit but want flagged); every list here
    /// is watched.
    public var lists: [String: [String]]
    /// Extra sites to flag, in blocklist rule syntax ("Other sites").
    public var customDomains: [String]
    /// Flag visits to sites on `lists` and `customDomains`. On unless turned
    /// off, so settings from before the switch keep watching their lists;
    /// turning it off keeps the lists for later.
    public var flagLists: Bool
    /// Flag explicit content: visits to the bundled adult-site preset, page
    /// titles with words from `ExplicitTerms`, and on mixed sites
    /// (`SiteCategory.mixed`) stricter title scoring and reading the page for
    /// the site's own NSFW labels and strong explicit words (`PageSignals`).
    /// Shown as "Flag explicit content".
    public var flagExplicit: Bool
    /// Extra words or phrases to flag in page titles.
    public var customTerms: [String]
    /// Read from the format before monitoring lists (no `lists` key). Not
    /// stored or compared: renewd refuses such settings from a client, since
    /// an app or CLI that predates monitoring lists would wipe them.
    public private(set) var isLegacyFormat = false
    /// Whether decoded settings had no `flagLists`: sent by a client from
    /// before the lists switch, which can't mean to turn it on (renewd keeps
    /// the stored value).
    public private(set) var omitsFlagLists = false

    /// The flag label for the adult-site preset; not a list name.
    public static let explicitListName = "explicit"
    /// The flag label used for `customDomains`; not a list name.
    public static let customListName = "custom"
    /// Starter monitoring lists, copied from the built-in blocklists' sites.
    public static let starterLists = ["social", "video", "news"]
    public static let maxLists = 50
    public static let maxListNameLength = 64
    /// The most rules kept across all of `lists`.
    public static let maxListRules = 5_000
    public static let maxCustomDomains = 500
    public static let maxCustomTerms = 200
    public static let maxTermLength = 64

    public init(enabled: Bool = false, lists: [String: [String]] = [:],
                customDomains: [String] = [], flagLists: Bool = true,
                flagExplicit: Bool = false, customTerms: [String] = []) {
        self.enabled = enabled
        self.lists = lists
        self.customDomains = customDomains
        self.flagLists = flagLists
        self.flagExplicit = flagExplicit
        self.customTerms = customTerms
    }

    /// Off, with nothing watched: no lists, sites or words are flagged
    /// until you pick them.
    public static let off = MonitorSettings()

    public static func == (a: MonitorSettings, b: MonitorSettings) -> Bool {
        a.enabled == b.enabled && a.lists == b.lists && a.customDomains == b.customDomains
            && a.flagLists == b.flagLists && a.flagExplicit == b.flagExplicit && a.customTerms == b.customTerms
    }

    public static let legacyClientMessage = "This Renew app or command-line tool predates monitoring lists. Update it (reinstall Renew) to change the Monitor."

    /// The sites of a starter list (see `starterLists`).
    public static func starter(_ name: String) -> [String]? {
        let key = name.lowercased()
        return starterLists.contains(key) ? ListStore.builtIn[key] : nil
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, lists, customDomains, flagLists, flagExplicit = "flagExplicitTerms", customTerms
        /// Before monitoring lists, the Monitor watched blocklists by name and
        /// kept a copy of their rules. Still written, so an older renewd
        /// (after a downgrade) reads the same lists, but only read when
        /// `lists` is missing.
        case watchLists, listRules
    }

    /// Missing keys take their defaults, so older and newer files both read
    /// (including the combined settings kept before Activity and the Monitor
    /// were split). Blocklists watched before monitoring lists become
    /// monitoring lists with the sites the Monitor had, and watching the
    /// explicit preset turns `flagExplicit` on: only ever more is flagged.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MonitorSettings.off
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        lists = try c.decodeIfPresent([String: [String]].self, forKey: .lists) ?? d.lists
        customDomains = try c.decodeIfPresent([String].self, forKey: .customDomains) ?? d.customDomains
        flagLists = try c.decodeIfPresent(Bool.self, forKey: .flagLists) ?? d.flagLists
        omitsFlagLists = !c.contains(.flagLists)
        flagExplicit = try c.decodeIfPresent(Bool.self, forKey: .flagExplicit) ?? d.flagExplicit
        customTerms = try c.decodeIfPresent([String].self, forKey: .customTerms) ?? d.customTerms
        if !c.contains(.lists), let watched = try c.decodeIfPresent([String].self, forKey: .watchLists) {
            isLegacyFormat = true
            let rules = try c.decodeIfPresent([String: [String]].self, forKey: .listRules) ?? [:]
            for raw in watched {
                let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
                let copied = rules[name] ?? rules.first(where: { $0.key.lowercased() == name })?.value ?? []
                if name == Self.explicitListName {
                    flagExplicit = true
                } else if name == Self.customListName {
                    customDomains += copied // a blocklist named like the reserved label
                } else if !name.isEmpty {
                    // Long blocklist names are shortened rather than dropped.
                    lists[String(name.prefix(Self.maxListNameLength)), default: []] += copied
                }
            }
        }
    }

    /// Writes the current keys, plus the same lists in the old format
    /// (`watchLists` with "explicit" for `flagExplicit`, and `listRules`) so
    /// an older renewd reading this after a downgrade watches the same. With
    /// `flagLists` off the old format names no lists, since an older renewd
    /// has no switch for them.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(lists, forKey: .lists)
        try c.encode(customDomains, forKey: .customDomains)
        try c.encode(flagLists, forKey: .flagLists)
        try c.encode(flagExplicit, forKey: .flagExplicit)
        try c.encode(customTerms, forKey: .customTerms)
        try c.encode((flagExplicit ? [Self.explicitListName] : []) + (flagLists ? sortedListNames : []), forKey: .watchLists)
        try c.encode(lists, forKey: .listRules)
    }

    /// Adds `sites` to the list `name` (creating it), skipping ones it has.
    public mutating func addSites(_ sites: [String], to name: String) {
        let current = lists[name] ?? []
        lists[name] = current + sites.filter { !current.contains($0) }
    }

    /// Why these settings can't be stored as asked, or nil: more lists or
    /// sites than the limits, which `normalized()` would otherwise cut
    /// without saying so.
    public var limitError: String? {
        let names = Set(lists.keys.compactMap(Self.cleanListName))
        if names.count > Self.maxLists { return "You can have at most \(Self.maxLists) monitoring lists." }
        var merged: [String: [String]] = [:]
        for (raw, rules) in lists { if let n = Self.cleanListName(raw) { merged[n, default: []] += rules } }
        let total = merged.values.reduce(0) { $0 + canonicalRules($1).valid.count }
        if total > Self.maxListRules {
            return "Monitoring lists can hold at most \(Self.maxListRules.formatted()) sites in all."
        }
        if canonicalRules(customDomains).valid.count > Self.maxCustomDomains {
            return "You can add at most \(Self.maxCustomDomains) other sites."
        }
        return nil
    }

    /// A typed list name, trimmed and lowercased, or nil if it can't be used
    /// (empty, too long, or a reserved flag label).
    public static func cleanListName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, name.count <= maxListNameLength,
              name != explicitListName, name != customListName else { return nil }
        return name
    }

    /// List names in display order.
    public var sortedListNames: [String] { lists.keys.sorted() }

    /// Lowercased, de-duplicated and capped; invalid sites, unusable list
    /// names and empty words dropped. Empty lists are kept.
    public func normalized() -> MonitorSettings {
        var s = self
        var merged: [String: [String]] = [:]
        for (raw, rules) in lists {
            guard let name = Self.cleanListName(raw) else { continue }
            merged[name, default: []] += rules
        }
        var out: [String: [String]] = [:]
        var budget = Self.maxListRules
        for name in merged.keys.sorted().prefix(Self.maxLists) {
            let kept = Array(canonicalRules(merged[name] ?? []).valid.prefix(max(0, budget)))
            budget -= kept.count
            out[name] = kept
        }
        s.lists = out
        s.customDomains = Array(canonicalRules(customDomains).valid.prefix(Self.maxCustomDomains))
        s.customTerms = Array(Self.dedupe(customTerms.map(Self.cleanTerm)).filter { $0.count <= Self.maxTermLength }
            .prefix(Self.maxCustomTerms))
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
    /// For `.domain`: what matched (`explicit`, `custom`, or a monitoring list's name).
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
/// Work sites (`SiteCategory.work`) are never flagged, and recovery sites
/// (`SiteCategory.recovery`) never by the built-in words. Mixed sites get
/// stricter title scoring and their page findings (`PageSignals`) checked
/// when `flagExplicit` is on.
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

    /// Watched sites come from `settings.lists` and `customDomains` (with
    /// `flagLists` on); `explicitDomains` is the bundled preset (used with `flagExplicit`),
    /// or nil if it isn't loaded.
    public init(settings: MonitorSettings, explicitDomains: DomainSet?) {
        let s = settings.normalized()
        explicit = s.flagExplicit ? explicitDomains : nil
        var watched: [(String, RuleSet)] = []
        if s.flagLists {
            for name in s.sortedListNames {
                if let rules = s.lists[name], !rules.isEmpty { watched.append((name, RuleSet(strings: rules))) }
            }
            if !s.customDomains.isEmpty { watched.append((MonitorSettings.customListName, RuleSet(strings: s.customDomains))) }
        }
        self.watched = watched
        explicitTerms = s.flagExplicit ? .preset : nil
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
        // Recovery sites talk about pornography to help people quit.
        let scorer = category == .recovery ? nil : explicitTerms
        let variants = scorer == nil && terms.isEmpty ? [] : TitleNormalizer.variants(title)
        var found = Set<String>()
        if let r = scorer?.evaluate(variants: variants, masked: TitleNormalizer.maskedWords(title),
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
