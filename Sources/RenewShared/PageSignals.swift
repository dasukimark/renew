import Foundation

/// What Renew found in the visible text of a page on a mixed site (see
/// `SiteCategory`), with `MonitorSettings.flagExplicitTerms` on. Only these
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
            if strong.count < maxItems {
                for w in scorer.strongMatches(variants: variants) where !strong.contains(w) { strong.append(w) }
            }
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

    init(_ id: String, _ scope: Scope, _ domains: [String]?, _ phrases: [String]) {
        self.id = id
        self.scope = scope
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
        ]),
        SiteLabel("age-restricted video", .page, youtube, [
            "sign in to confirm your age",
            "this video may be inappropriate for some users",
        ]),
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
