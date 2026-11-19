import Foundation

/// The words the Monitor looks for in page titles when
/// `MonitorSettings.flagExplicit` is on, grouped by how strongly they
/// suggest an explicit page. Everything is matched as whole words, so
/// "Essex", "analysis", "Java" or "BJJ" never match.
///
/// In the weighted lists, `|` joins forms of one word ("fuck|fucking"): a
/// title gets that word's weight once, however many of its forms appear.
public enum ExplicitTerms {
    /// Strong: any one of these flags a title on its own.
    public static let preset: [String] = [
        "porn", "porno", "pornography", "pornographic", "xxx", "nsfw", "nude", "nudes", "nudity", "naked",
        "topless", "sex", "sexting", "sex tape", "sex cam", "live sex", "hentai", "milf", "milfs", "onlyfans",
        "fansly", "camgirl", "camgirls", "erotic", "erotica", "fetish", "bdsm", "bondage", "orgasm",
        "masturbate", "masturbation", "blowjob", "blow job", "handjob", "creampie", "gangbang", "threesome",
        "striptease", "boobs", "tits", "pussy", "dildo", "anal", "hardcore", "horny", "r34", "rule34",
        "rule 34", "xvideos", "xhamster", "pornhub", "redtube", "youporn", "brazzers", "chaturbate",
        "stripchat", "leaked nudes",
        "jav", "japanese av", "koreanbj", "korean bj", "kbj",
        "massage", "massages", "bikini", "bikinis", "body paint", "bodypaint", "body painting", "bodypainting",
    ]

    /// Medium: sexual slang. Two of these, or one with suggestive context,
    /// flag a title; one alone doesn't, except on mixed sites
    /// (`ExplicitScorer.Policy.mixed`).
    public static let medium: [String] = [
        "slut|sluts|slutty", "whore|whores", "sexy", "kinky", "lewd", "busty", "lingerie", "thot",
        "twerk|twerking",
    ]

    /// Ambiguous medium: slang with common innocent meanings ("kick-ass",
    /// "Ford Escort", "summa cum laude", "paint stripper", a family post about
    /// a stepmom). Counts like medium, but always needs a second signal,
    /// mixed sites included.
    public static let ambiguous: [String] = [
        "ass", "escort|escorts", "uncensored", "booty", "stripper|strippers", "bj", "cum|cumming|cumshot",
        "dick|dicks", "cock|cocks", "stepmom", "stepsister|stepsis", "stepbro", "stepdaughter",
    ]

    /// Profanity: sexual swearing. Counts like medium, but swearing in total
    /// is capped below the threshold (`ExplicitScorer.maxSwearingTotal`), so
    /// it never flags a title without other signals.
    public static let profanity: [String] = [
        "fuck|fucks|fucking|fucked|fucker|fuckers|fuk|motherfucker|motherfucking",
    ]

    /// Suggestive context: ordinary words that only count next to stronger ones.
    public static let suggestive: [String] = [
        "hot|hottest", "teen|teens", "girl|girls", "babe|babes", "amateur", "homemade", "leaked|leak",
        "petite", "mature", "wet", "naughty",
    ]

    /// Media words: count for very little, so "… video clip" can't push an
    /// ordinary title over the threshold.
    public static let media: [String] = [
        "video|videos", "clip|clips", "cam|webcam", "live",
    ]

    /// Mild: everyday swearing, which counts for a little (capped with profanity).
    public static let mild: [String] = [
        "shit|shitty|bullshit", "bitch|bitches", "damn", "asshole", "bastard", "crap", "piss|pissed",
    ]

    /// Words the title normalizer never rewrites, so a shortened or joined
    /// form of them can't turn into a match ("bjjj" stays "bjj", not "bj").
    public static let safeWords: Set<String> = [
        "java", "javas", "javascript", "javadoc", "javac", "javafx", "javanese", "bjj", "jiujitsu", "jujitsu",
    ]
}

/// How much a word counts toward a title's score.
public enum ExplicitTier: Int, Sendable, Comparable {
    case mild, media, suggestive, profanity, medium, strong

    public var weight: Double {
        switch self {
        case .strong: return 1.0
        case .medium, .profanity: return 0.5
        case .suggestive: return 0.25
        case .mild: return 0.2
        case .media: return 0.1
        }
    }

    public static func < (a: ExplicitTier, b: ExplicitTier) -> Bool { a.rawValue < b.rawValue }
}

/// Undoes common ways of disguising a word in a title.
public enum TitleNormalizer {
    private static let leet: [Character: Character] = [
        "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s",
    ]

    /// The title's words (split as `TermMatcher.words` does) first, then
    /// each rewritten form that differs:
    /// - digits and symbols read as letters ("s3x", "$hit")
    /// - runs of 3+ repeated letters shortened to 1 and to 2 ("pooorn")
    /// - 3+ spaced-out single letters joined ("p o r n", "p.o.r.n")
    ///
    /// Words in `safeWords` are never rewritten. Empty if the title has no words.
    public static func variants(_ text: String, safeWords: Set<String> = ExplicitTerms.safeWords) -> [[String]] {
        let folded = fold(text)
        let plain = split(folded) { !$0.isLetter && !$0.isNumber }
        guard !plain.isEmpty else { return [] }
        var out = [plain]
        func add(_ v: [String]) { if !v.isEmpty && !out.contains(v) { out.append(v) } }

        let deleeted = split(folded) { !$0.isLetter && !$0.isNumber && leet[$0] == nil }.flatMap { token in
            deleet(token, safeWords).map { [$0] } ?? split(token) { !$0.isLetter && !$0.isNumber }
        }
        add(deleeted)
        add(deleeted.map { collapse($0, keep: 1, safeWords) })
        add(deleeted.map { collapse($0, keep: 2, safeWords) })
        add(joinSingles(plain, safeWords).map { deleet($0, safeWords) ?? $0 })
        return out
    }

    /// Words partly hidden with `*` ("f*ck", "f**k"): starting with a letter,
    /// with at least two characters showing.
    public static func maskedWords(_ text: String) -> [String] {
        split(fold(text)) { !$0.isLetter && !$0.isNumber && $0 != "*" }.filter { w in
            w.contains("*") && w.first?.isLetter == true && w.filter { $0 != "*" }.count >= 2
        }
    }

    /// Whether `word` fits `masked`, with each `*` standing for one character.
    static func fits(_ masked: String, _ word: String) -> Bool {
        masked.count == word.count && zip(masked, word).allSatisfy { $0 == "*" || $0 == $1 }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    private static func split(_ s: String, by isSeparator: (Character) -> Bool) -> [String] {
        s.split(whereSeparator: isSeparator).map(String.init)
    }

    /// `token` with digits and symbols read as letters, or nil unless it's
    /// mostly letters (at least two, and more letters than stand-ins) and
    /// reading the stand-ins leaves only letters. So "s3x" and "$hit" are
    /// read, but model numbers like "717s", "A55" or "53x" aren't.
    private static func deleet(_ token: String, _ safe: Set<String>) -> String? {
        guard !safe.contains(token) else { return nil }
        let letters = token.filter(\.isLetter).count
        let standIns = token.filter { leet[$0] != nil }.count
        guard standIns > 0, letters >= 2, standIns < letters else { return nil }
        let read = String(token.map { leet[$0] ?? $0 })
        return read.allSatisfy(\.isLetter) ? read : nil
    }

    /// `word` with every run of 3+ identical letters cut to `keep`. If the
    /// two-letter form is a safe word, that's used instead.
    private static func collapse(_ word: String, keep: Int, _ safe: Set<String>) -> String {
        guard !safe.contains(word) else { return word }
        var out = ""
        var i = word.startIndex
        while i < word.endIndex {
            let c = word[i]
            var j = word.index(after: i)
            while j < word.endIndex && word[j] == c { j = word.index(after: j) }
            let run = word.distance(from: i, to: j)
            out += String(repeating: c, count: run >= 3 && c.isLetter ? keep : run)
            i = j
        }
        if keep < 2 {
            let two = collapse(word, keep: 2, safe)
            if safe.contains(two) { return two }
        }
        return out
    }

    /// Runs of 3+ one-character words joined into one word.
    private static func joinSingles(_ words: [String], _ safe: Set<String>) -> [String] {
        var out: [String] = []
        var run: [String] = []
        func flush() {
            let joined = run.joined()
            if run.count >= 3 && !safe.contains(joined) { out.append(joined) } else { out += run }
            run.removeAll()
        }
        for w in words {
            if w.count == 1 { run.append(w) } else { flush(); out.append(w) }
        }
        flush()
        return out
    }
}

/// Scores a page title for how explicit it looks. Strong words flag it
/// outright. Otherwise the weights of the distinct words found are added
/// up, with swearing and context words each capped, and the title is
/// flagged once the total reaches `threshold`.
public struct ExplicitScorer: Sendable {
    public struct Result: Equatable, Sendable {
        /// Strong words found. Any one of them flags the title.
        public var strong: [String]
        /// The other words found, strongest first.
        public var contributors: [String]
        public var score: Double
        public var flagged: Bool
    }

    public static let threshold = 1.0
    /// The most swearing (profanity and mild) can add up to: never enough
    /// to flag a title alone.
    public static let maxSwearingTotal = 0.5
    /// The most suggestive and media words can add up to: never enough to
    /// flag a title alone.
    public static let maxContextTotal = 0.75

    private struct Group: Sendable {
        var forms: [(text: String, words: [String])]
        var tier: ExplicitTier
        /// An ambiguous medium word: never counts for more than `tier.weight`.
        var ambiguous = false
    }
    private let groups: [Group]
    /// Single-word forms, for a hash lookup per title word.
    private let single: [String: (group: Int, form: Int)]
    /// Multi-word forms, checked phrase by phrase.
    private let phrases: [(group: Int, form: Int, words: [String])]
    private let strongPhrases: [(group: Int, form: Int, words: [String])]
    private let safeWords: Set<String>

    /// Each list item is one word, its forms joined by `|`. The first list a
    /// form appears in wins.
    public init(strong: [String], medium: [String] = [], ambiguous: [String] = [], profanity: [String] = [],
                suggestive: [String] = [], media: [String] = [], mild: [String] = [], safeWords: Set<String> = []) {
        var seen = Set<String>()
        var groups: [Group] = []
        var single: [String: (Int, Int)] = [:]
        var phrases: [(Int, Int, [String])] = []
        let tiers: [([String], ExplicitTier, Bool)] = [
            (strong, .strong, false), (medium, .medium, false), (ambiguous, .medium, true),
            (profanity, .profanity, false), (suggestive, .suggestive, false), (media, .media, false), (mild, .mild, false),
        ]
        for (items, tier, isAmbiguous) in tiers {
            for item in items {
                var forms: [(String, [String])] = []
                for text in item.split(separator: "|").map(String.init) {
                    let words = TermMatcher.words(text)
                    guard !words.isEmpty, seen.insert(words.joined(separator: " ")).inserted else { continue }
                    if words.count == 1 { single[words[0]] = (groups.count, forms.count) }
                    else { phrases.append((groups.count, forms.count, words)) }
                    forms.append((text, words))
                }
                if !forms.isEmpty { groups.append(Group(forms: forms, tier: tier, ambiguous: isAmbiguous)) }
            }
        }
        self.groups = groups
        self.single = single
        self.phrases = phrases
        strongPhrases = phrases.filter { groups[$0.0].tier == .strong }
        self.safeWords = safeWords
    }

    /// The built-in word lists.
    public static let preset = ExplicitScorer(
        strong: ExplicitTerms.preset, medium: ExplicitTerms.medium, ambiguous: ExplicitTerms.ambiguous,
        profanity: ExplicitTerms.profanity,
        suggestive: ExplicitTerms.suggestive, media: ExplicitTerms.media, mild: ExplicitTerms.mild,
        safeWords: ExplicitTerms.safeWords)

    /// How strictly a title is scored.
    public struct Policy: Equatable, Sendable {
        /// What one medium word counts for.
        public var mediumWeight: Double
        /// The most suggestive and media words can add up to.
        public var maxContextTotal: Double

        /// Everywhere but mixed sites.
        public static let standard = Policy(mediumWeight: ExplicitTier.medium.weight,
                                            maxContextTotal: ExplicitScorer.maxContextTotal)
        /// Mixed sites (`SiteCategory.mixed`): one medium word (not an
        /// ambiguous one) flags, and
        /// suggestive words can add up to a flag. Swearing stays capped below
        /// the threshold.
        public static let mixed = Policy(mediumWeight: 1.0, maxContextTotal: 1.0)
    }

    public func evaluate(_ title: String, policy: Policy = .standard) -> Result {
        evaluate(variants: TitleNormalizer.variants(title, safeWords: safeWords),
                 masked: TitleNormalizer.maskedWords(title), policy: policy)
    }

    /// The distinct strong words in `text` (a whole page's text, say), as
    /// listed, disguised spellings included.
    public func strongMatches(in text: String) -> [String] {
        strongMatches(variants: TitleNormalizer.variants(text, safeWords: safeWords))
    }

    /// The same, for words already normalized with this scorer's safe words.
    /// Only looks up strong words, so it stays cheap over thousands of page parts.
    func strongMatches(variants: [[String]]) -> [String] {
        var found: [Int: String] = [:]
        for v in variants {
            for w in v {
                if let e = single[w], groups[e.group].tier == .strong, found[e.group] == nil {
                    found[e.group] = groups[e.group].forms[e.form].text
                }
            }
            for (g, f, words) in strongPhrases where found[g] == nil && TermMatcher.contains(v, words) {
                found[g] = groups[g].forms[f].text
            }
        }
        return found.sorted { $0.key < $1.key }.map(\.value)
    }

    /// Scores already-normalized words, so a caller that also needs them
    /// (`ActivityMatcher`) normalizes the title once. `variants` must use
    /// this scorer's safe words. `extra` adds other findings (a site's label
    /// on a feed) to the score, each with its weight.
    func evaluate(variants: [[String]], masked: [String], policy: Policy = .standard,
                  extra: [(text: String, weight: Double)] = []) -> Result {
        var hits: [Int: (tier: ExplicitTier, text: String, masked: Bool)] = [:]
        func hit(_ group: Int, _ form: Int, as tier: ExplicitTier, masked: Bool = false) {
            if let old = hits[group], old.tier > tier || (old.tier == tier && (masked || !old.masked)) { return }
            hits[group] = (tier, groups[group].forms[form].text, masked)
        }
        for v in variants {
            for w in v { if let e = single[w] { hit(e.group, e.form, as: groups[e.group].tier) } }
            for (g, f, words) in phrases where TermMatcher.contains(v, words) { hit(g, f, as: groups[g].tier) }
        }
        // A masked word counts as the weakest word it could be, and never
        // as strong: "p***y" could as well be "party".
        for m in masked {
            let fitting = single.filter { TitleNormalizer.fits(m, $0.key) }.map(\.value)
            if let e = fitting.min(by: { groups[$0.group].tier < groups[$1.group].tier }) {
                hit(e.group, e.form, as: min(groups[e.group].tier, .medium), masked: true)
            }
        }

        var strong: [String] = []
        var contributors: [String] = []
        var other = 0.0, swearing = 0.0, context = 0.0
        // Strongest first; within a tier, in list order. A masked word is
        // never trusted beyond `tier.weight`, like an ambiguous one.
        let found = hits.sorted { a, b in a.value.tier != b.value.tier ? a.value.tier > b.value.tier : a.key < b.key }
        for (group, hit) in found {
            let (tier, text) = (hit.tier, hit.text)
            switch tier {
            case .strong: strong.append(text)
            case .medium: other += groups[group].ambiguous || hit.masked ? tier.weight : policy.mediumWeight
            case .profanity, .mild: swearing += tier.weight
            case .suggestive, .media: context += tier.weight
            }
            if tier != .strong { contributors.append(text) }
        }
        for e in extra {
            other += e.weight
            contributors.append(e.text)
        }
        let score = Double(strong.count) + other + min(swearing, Self.maxSwearingTotal)
            + min(context, policy.maxContextTotal)
        return Result(strong: strong, contributors: contributors, score: score,
                      flagged: !strong.isEmpty || score + 1e-9 >= Self.threshold)
    }
}
