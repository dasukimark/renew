import Foundation

/// What Renew found in the visible text of a page on a mixed site (see
/// `SiteCategory`), with `MonitorSettings.flagExplicit` on. Only these
/// findings leave the app: the page text itself is never kept or sent.
public struct PageSignals: Codable, Equatable, Sendable {
    /// Ids of the site's own NSFW/18+ markings found (`SiteLabel.id`).
    public var labels: [String]
    /// Distinct strong explicit words found in the page text.
    public var strongWords: [String]

    public static let maxItems = 20
    public static let maxItemLength = 64

    public init(labels: [String] = [], strongWords: [String] = []) {
        self.labels = labels
        self.strongWords = strongWords
    }

    public var isEmpty: Bool { labels.isEmpty && strongWords.isEmpty }

    /// Both sets of findings, without repeats.
    public func merged(with other: PageSignals) -> PageSignals {
        PageSignals(labels: Self.union(labels, other.labels), strongWords: Self.union(strongWords, other.strongWords))
            .capped()
    }

    /// At most `maxItems` of each, each at most `maxItemLength` characters.
    public func capped() -> PageSignals {
        func cap(_ items: [String]) -> [String] {
            Self.union(items.map { String($0.prefix(Self.maxItemLength)) }.filter { !$0.isEmpty }, [])
                .prefix(Self.maxItems).map { $0 }
        }
        return PageSignals(labels: cap(labels), strongWords: cap(strongWords))
    }

    private static func union(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set<String>()
        return (a + b).filter { seen.insert($0).inserted }
    }

    /// Reads the visible text of a page on `host`, one piece per page
    /// element, for the site's labels and strong explicit words. Each piece
    /// is read on its own, so letters from neighbouring elements (buttons,
    /// avatar initials) never join into a word, and repeated pieces are read
    /// once. Each piece is normalized once for both checks.
    ///
    /// `others` is text around the main post (replies, other posts below
    /// it): read the same way, except that a post label there isn't taken
    /// as the page's own, since it may belong to a reply.
    public static func find(host: String, parts: [String], others: [String] = []) -> PageSignals {
        let scorer = ExplicitScorer.preset
        let candidates = SiteLabel.all.filter { $0.applies(to: host) }
        var labels: [String] = []
        var strong: [String] = []
        var seen = Set<String>()
        let all = parts.map { ($0, true) } + others.map { ($0, false) }
        for (part, main) in all where seen.insert(part).inserted {
            let variants = TitleNormalizer.variants(part, safeWords: ExplicitTerms.safeWords)
            guard let plain = variants.first else { continue }
            for label in candidates where !labels.contains(label.id) && (main || label.scope != .post) {
                if label.phrases.contains(where: { TermMatcher.contains(plain, $0) }) { labels.append(label.id) }
            }
            for w in scorer.strongMatches(variants: variants) where !strong.contains(w) { strong.append(w) }
        }
        return PageSignals(labels: labels, strongWords: strong).capped()
    }

    /// The same for text with one element per line.
    public static func find(host: String, text: String) -> PageSignals {
        find(host: host, parts: text.split(whereSeparator: \.isNewline).map(String.init))
    }
}

/// A marking a site puts on adult content itself, found by its wording.
/// Wording changes when sites redesign, so this table needs updating now and then.
public struct SiteLabel: Sendable {
    public enum Scope: Sendable {
        /// The whole page is adult content (an 18+ gate): flags the visit.
        case page
        /// One post is marked: flags a single-post page, and on a feed only
        /// adds to the title score.
        case post
        /// Common wording that may as well come from a comment or a
        /// recommended link ("NSFW", "mature content"): only ever adds to
        /// the title score.
        case hint
    }

    /// Shown in flags and reports.
    public var id: String
    public var scope: Scope
    /// Sites it applies to (with subdomains); nil for every mixed site.
    public var domains: [String]?
    /// Whole phrases, matched ignoring case, accents and punctuation.
    public var phrases: [[String]]
    /// An age gate (18+ community, age-restricted video) rather than a
    /// marking of explicit content: reports say so.
    public var isAgeGate: Bool

    init(_ id: String, _ scope: Scope, _ domains: [String]?, _ phrases: [String], ageGate: Bool = false) {
        self.id = id
        self.scope = scope
        self.isAgeGate = ageGate
        self.domains = domains
        self.phrases = phrases.map(TermMatcher.words)
    }

    func applies(to host: String) -> Bool {
        guard let domains else { return true }
        let h = Rule.normalizeHost(host)
        return domains.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    private static let reddit = ["reddit.com", "redd.it", "safereddit.com", "teddit.net", "redlib.catsarch.com",
                                 "libreddit.kavin.rocks", "l.opnxng.com"]
    private static let x = ["x.com", "twitter.com", "xcancel.com", "nitter.net", "nitter.poast.org",
                            "nitter.privacydev.net"]
    private static let youtube = ["youtube.com", "youtu.be", "yewtu.be", "inv.nadeko.net", "invidious.nerdvpn.de",
                                  "piped.video", "piped.kavin.rocks"]

    public static let all: [SiteLabel] = [
        SiteLabel("18+ community gate", .page, reddit, [
            "you must be 18 to view this community",
            "you must be at least eighteen years old to view this content",
        ], ageGate: true),
        SiteLabel("age-restricted video", .page, youtube, [
            "sign in to confirm your age",
            "this video may be inappropriate for some users",
        ], ageGate: true),
        SiteLabel("sensitive profile warning", .page, x, ["may include potentially sensitive content"]),
        SiteLabel("sensitive blog warning", .page, ["tumblr.com"], ["may contain sensitive media"]),
        SiteLabel("sensitive media warning", .post, x, ["potentially sensitive content"]),
        SiteLabel("mature post warning", .post, ["tumblr.com"], [
            "this post contains mature content", "this post may contain mature content",
        ]),
        SiteLabel("adult content label", .post, ["bsky.app"], [
            "adult content", "sexually suggestive", "non sexual nudity",
        ]),
        SiteLabel("R-18 tag", .post, ["pixiv.net"], ["r 18", "r 18g"]),
        SiteLabel("NSFW tag", .hint, nil, ["nsfw"]),
        SiteLabel("mature content warning", .hint, nil, ["mature content"]),
    ]

    /// The label with `id`, or nil (an id from a newer build).
    public static func named(_ id: String) -> SiteLabel? { all.first { $0.id == id } }
}

/// Read bookkeeping for the pages a reader has in front: when each was
/// last read, and which pieces of its text were already checked, so a page
/// read again (a feed loading more as you scroll) only has its new text
/// classified. Returns only what the new text holds: `VisitTracker` merges
/// findings within a visit.
///
/// Forget a page (`keep(only:)`, `reset()`) whenever its visit may end (the
/// page leaves the front, the user goes away), so a new visit gets its text
/// checked afresh. Not locked: use it from one serial queue.
public final class PageReadState {
    private struct Entry {
        var lastRead: Date
        var parts: Set<Int> = []
    }
    private var pages: [String: Entry] = [:]
    /// How often one page is read again while it stays in front.
    public let interval: TimeInterval
    /// Checked pieces remembered per page; past this they're forgotten and
    /// checked again, which repeats findings the visit already has.
    public static let maxParts = 20_000
    public static let maxPages = 50

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Whether `key` is due a read; if so, counts it as read now. A page
    /// not seen before is due straight away.
    public func take(_ key: String, now: Date = Date()) -> Bool {
        if let e = pages[key], now.timeIntervalSince(e.lastRead) < interval { return false }
        pages[key, default: Entry(lastRead: now)].lastRead = now
        if pages.count > Self.maxPages, let oldest = pages.min(by: { $0.value.lastRead < $1.value.lastRead }) {
            pages[oldest.key] = nil
        }
        return true
    }

    /// Takes back a read that found nothing, so the page is tried again on the next check.
    public func giveBack(_ key: String) { pages[key]?.lastRead = .distantPast }

    /// What the text of `key` (on `host`) read just now holds that earlier
    /// reads didn't (see `PageSignals.find(host:parts:others:)`).
    public func findings(_ key: String, host: String, parts: [String], others: [String] = []) -> PageSignals {
        var entry = pages[key] ?? Entry(lastRead: Date())
        if entry.parts.count > Self.maxParts { entry.parts.removeAll() }
        // Where a piece is (main post or not) counts: a post label counts
        // differently in each.
        func fresh(_ texts: [String], main: Bool) -> [String] {
            texts.filter { t in
                var h = Hasher()
                h.combine(main)
                h.combine(t)
                return entry.parts.insert(h.finalize()).inserted
            }
        }
        let newMain = fresh(parts, main: true)
        let newOthers = fresh(others, main: false)
        pages[key] = entry
        guard !newMain.isEmpty || !newOthers.isEmpty else { return PageSignals() }
        return PageSignals.find(host: host, parts: newMain, others: newOthers)
    }

    /// Forgets every page but `keys`.
    public func keep(only keys: Set<String>) {
        pages = pages.filter { keys.contains($0.key) }
    }

    /// Forgets every page.
    public func reset() { pages.removeAll() }
}
