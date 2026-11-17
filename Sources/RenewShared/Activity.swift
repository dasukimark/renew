import Foundation

// Activity monitoring: Renew records the pages you visit (URL, title, time on
// page) and flags the ones that match watched sites or explicit words. The
// app watches and matches; renewd keeps the log (see `ActivityLogStore`).

/// What activity monitoring watches for. renewd owns it, like `Protections`.
/// Off out of the box.
public struct MonitoringSettings: Codable, Equatable, Sendable {
    /// Record page visits at all.
    public var enabled: Bool
    /// Lists whose sites get flagged: `explicitListName` (the bundled preset)
    /// or any blocklist name (social, video, your own lists…).
    public var watchLists: [String]
    /// Extra sites to flag, in blocklist rule syntax.
    public var customDomains: [String]
    /// Flag page titles containing a word from `ExplicitTerms.preset`.
    public var flagExplicitTerms: Bool
    /// Extra words or phrases to flag in page titles.
    public var customTerms: [String]

    public static let explicitListName = "explicit"
    /// The flag label used for `customDomains`.
    public static let customListName = "custom"
    public static let maxWatchLists = 50
    public static let maxCustomDomains = 500
    public static let maxCustomTerms = 200
    public static let maxTermLength = 64

    public init(enabled: Bool = false, watchLists: [String] = [],
                customDomains: [String] = [], flagExplicitTerms: Bool = false, customTerms: [String] = []) {
        self.enabled = enabled
        self.watchLists = watchLists
        self.customDomains = customDomains
        self.flagExplicitTerms = flagExplicitTerms
        self.customTerms = customTerms
    }

    /// Off, with nothing watched: no lists, sites or words are flagged
    /// until you pick them.
    public static let off = MonitoringSettings()

    private enum CodingKeys: String, CodingKey {
        case enabled, watchLists, customDomains, flagExplicitTerms, customTerms
    }

    /// Missing keys take their defaults, so older and newer files both read.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MonitoringSettings.off
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        watchLists = try c.decodeIfPresent([String].self, forKey: .watchLists) ?? d.watchLists
        customDomains = try c.decodeIfPresent([String].self, forKey: .customDomains) ?? d.customDomains
        flagExplicitTerms = try c.decodeIfPresent(Bool.self, forKey: .flagExplicitTerms) ?? d.flagExplicitTerms
        customTerms = try c.decodeIfPresent([String].self, forKey: .customTerms) ?? d.customTerms
    }

    /// Lowercased, de-duplicated and capped; invalid sites and empty words dropped.
    public func normalized() -> MonitoringSettings {
        var s = self
        s.watchLists = Array(Self.dedupe(watchLists.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            .prefix(Self.maxWatchLists))
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

/// Why a visit was flagged.
public struct ActivityFlag: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case domain, term }

    public var kind: Kind
    /// For `.domain`: the watch list that matched (`explicit`, `custom`, or a blocklist name).
    public var list: String?
    /// The rule or domain that matched, or the word found in the title.
    public var match: String

    public init(kind: Kind, list: String? = nil, match: String) {
        self.kind = kind
        self.list = list
        self.match = match
    }

    public static func domain(_ list: String, _ match: String) -> ActivityFlag { ActivityFlag(kind: .domain, list: list, match: match) }
    public static func term(_ match: String) -> ActivityFlag { ActivityFlag(kind: .term, match: match) }

    /// "Explicit site", "Social list", "Watched site", or "Word: …".
    public var label: String {
        switch kind {
        case .term: return "Word: \(match)"
        case .domain:
            switch list {
            case MonitoringSettings.explicitListName?: return "Explicit site"
            case MonitoringSettings.customListName?, nil: return "Watched site"
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
    public var flags: [ActivityFlag]
    /// A running block session replaced the page with the block page.
    public var blocked: Bool

    public init(id: UUID? = UUID(), start: Date, end: Date, browser: String, url: String, host: String, title: String,
                flags: [ActivityFlag] = [], blocked: Bool = false) {
        self.id = id
        self.start = start
        self.end = end
        self.browser = browser
        self.url = url
        self.host = host
        self.title = title
        self.flags = flags
        self.blocked = blocked
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var isFlagged: Bool { !flags.isEmpty || blocked }

    public static let maxURLLength = 2_048
    public static let maxTitleLength = 512
    public static let maxNameLength = 128
    public static let maxFlags = 20
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
        guard !e.host.isEmpty else { return nil }
        if e.duration > Self.maxDuration { e.end = e.start.addingTimeInterval(Self.maxDuration) }
        e.flags = Array(flags.prefix(Self.maxFlags)).map {
            var f = $0
            f.match = String(f.match.prefix(256))
            f.list = f.list.map { String($0.prefix(Self.maxNameLength)) }
            return f
        }
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

/// Explicit words and phrases flagged in page titles when
/// `MonitoringSettings.flagExplicitTerms` is on. Matched as whole words, so
/// "Essex" or "analysis" never match.
public enum ExplicitTerms {
    public static let preset: [String] = [
        "porn", "porno", "pornography", "pornographic", "xxx", "nsfw", "nude", "nudes", "nudity", "naked",
        "topless", "sex", "sexting", "sex tape", "sex cam", "live sex", "hentai", "milf", "milfs", "onlyfans",
        "fansly", "camgirl", "camgirls", "erotic", "erotica", "fetish", "bdsm", "bondage", "orgasm",
        "masturbate", "masturbation", "blowjob", "blow job", "handjob", "creampie", "gangbang", "threesome",
        "striptease", "boobs", "tits", "pussy", "dildo", "anal", "hardcore", "horny", "r34", "rule34",
        "rule 34", "xvideos", "xhamster", "pornhub", "redtube", "youporn", "brazzers", "chaturbate",
        "stripchat", "leaked nudes",
    ]
}

/// Finds whole words or phrases in text, ignoring case and accents.
public struct TermMatcher: Sendable {
    private let terms: [(term: String, words: [String])]

    public init(_ terms: [String]) {
        var seen = Set<String>()
        self.terms = terms.compactMap {
            let words = Self.words($0)
            guard !words.isEmpty, seen.insert(words.joined(separator: " ")).inserted else { return nil }
            return ($0, words)
        }
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// Every term found in `text`, in the order they were given.
    public func matches(in text: String) -> [String] {
        guard !terms.isEmpty else { return [] }
        let words = Self.words(text)
        guard !words.isEmpty else { return [] }
        return terms.filter { Self.contains(words, $0.words) }.map(\.term)
    }

    /// Lowercased, accent-free runs of letters and digits.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private static func contains(_ words: [String], _ phrase: [String]) -> Bool {
        guard phrase.count <= words.count else { return false }
        if phrase.count == 1 { return words.contains(phrase[0]) }
        for i in 0...(words.count - phrase.count) where words[i] == phrase[0] {
            if Array(words[i..<(i + phrase.count)]) == phrase { return true }
        }
        return false
    }
}

/// Decides which flags a page gets under the current settings.
public struct ActivityMatcher: Sendable {
    private let explicit: DomainSet?
    private let watched: [(list: String, rules: RuleSet)]
    private let terms: TermMatcher

    /// `lists` are the blocklists (`ListStore.all()`); `explicitDomains` is
    /// the bundled preset, or nil if it isn't loaded (yet).
    public init(settings: MonitoringSettings, lists: [String: [String]], explicitDomains: DomainSet?) {
        let s = settings.normalized()
        explicit = s.watchLists.contains(MonitoringSettings.explicitListName) ? explicitDomains : nil
        var watched: [(String, RuleSet)] = []
        for name in s.watchLists where name != MonitoringSettings.explicitListName {
            if let rules = lists[name], !rules.isEmpty { watched.append((name, RuleSet(strings: rules))) }
        }
        if !s.customDomains.isEmpty { watched.append((MonitoringSettings.customListName, RuleSet(strings: s.customDomains))) }
        self.watched = watched
        terms = TermMatcher((s.flagExplicitTerms ? ExplicitTerms.preset : []) + s.customTerms)
    }

    public func flags(url: String, title: String) -> [ActivityFlag] {
        var out: [ActivityFlag] = []
        if let n = NormalizedURL(url) {
            if let hit = explicit?.match(host: n.host) { out.append(.domain(MonitoringSettings.explicitListName, hit)) }
            for (list, rules) in watched {
                if let rule = rules.match(url) { out.append(.domain(list, rule.description)) }
            }
        }
        for t in terms.matches(in: title) { out.append(.term(t)) }
        return out
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
    public var flags: [ActivityFlag]
    public var blocked: Bool

    public init(source: String, browser: String, url: String, title: String,
                flags: [ActivityFlag] = [], blocked: Bool = false) {
        self.source = source
        self.browser = browser
        self.url = url
        self.title = title
        self.flags = flags
        self.blocked = blocked
    }
}

/// Turns repeated looks at the screen into visits.
///
/// Each channel (the front browser, the built-in browser of the front app…)
/// reports everything it sees on every look. A page still there extends its
/// visit; a page that's gone ends it. A new title on the same URL (single-page
/// sites) updates the visit and adds any new flags, rather than starting a
/// new one.
public struct VisitTracker: Sendable {
    private struct Key: Hashable { var channel: String; var source: String; var url: String }
    private struct Open { var event: ActivityEvent; var order: Int }

    private var open: [Key: Open] = [:]
    private var counter = 0
    /// Unflagged visits shorter than this are dropped (redirects, pages
    /// flicked past).
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
                for f in p.flags where !o.event.flags.contains(f) { o.event.flags.append(f) }
                o.event.blocked = o.event.blocked || p.blocked
                o.event.end = now
                open[key] = o
            } else {
                counter += 1
                open[key] = Open(event: ActivityEvent(start: now, end: now, browser: p.browser, url: p.url, host: host,
                                                      title: p.title.isEmpty ? host : p.title,
                                                      flags: p.flags, blocked: p.blocked),
                                 order: counter)
            }
        }
        let gone = open.keys.filter { $0.channel == channel && !seen.contains($0) }
        return finish(gone, at: now)
    }

    /// Ends every open visit (monitoring turned off, the user went idle, Renew quitting).
    public mutating func closeAll(at now: Date) -> [ActivityEvent] {
        finish(Array(open.keys), at: now)
    }

    private mutating func finish(_ keys: [Key], at now: Date) -> [ActivityEvent] {
        var done: [(Int, ActivityEvent)] = []
        for k in keys {
            guard var o = open.removeValue(forKey: k) else { continue }
            o.event.end = max(o.event.start, now)
            if o.event.duration >= minDuration || o.event.isFlagged { done.append((o.order, o.event)) }
        }
        return done.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
