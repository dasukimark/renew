import Foundation
import Testing
@testable import RenewShared

struct ExplicitScoreTests {
    let scorer = ExplicitScorer.preset

    private func flags(_ title: String) -> Bool { scorer.evaluate(title).flagged }

    // MARK: normalizer

    @Test func normalizerUndoesDisguises() {
        func has(_ title: String, _ word: String) -> Bool {
            TitleNormalizer.variants(title).contains { $0.contains(word) }
        }
        #expect(has("s3x tonight", "sex"))
        #expect(has("P0RN clips", "porn"))
        #expect(has("$hit happens", "shit"))
        #expect(has("pooorn", "porn"))
        #expect(has("p o r n", "porn"))
        #expect(has("p.o.r.n", "porn"))
        #expect(has("k b j", "kbj"))
        #expect(TitleNormalizer.variants("2024 results") == [["2024", "results"]])
        #expect(TitleNormalizer.variants("Essex and Sussex") == [["essex", "and", "sussex"]])
        #expect(TitleNormalizer.variants("").isEmpty)
    }

    @Test func safeWordsAreNeverRewritten() {
        let all = TitleNormalizer.variants("BJJJ j a v a").flatMap { $0 }
        #expect(!all.contains("bj"))
        #expect(all.contains("bjj"))
        #expect(!all.contains("java")) // joined "java" is safe, so the letters stay apart
    }

    @Test func maskedWords() {
        #expect(TitleNormalizer.maskedWords("What the f*ck and f**k") == ["f*ck", "f**k"])
        #expect(TitleNormalizer.maskedWords("**bold** a*b 2*x f***") == ["a*b"]) // a*b fits nothing in the lexicon
        #expect(TitleNormalizer.fits("f*ck", "fuck"))
        #expect(!TitleNormalizer.fits("f*ck", "fucks"))
    }

    // MARK: scoring

    @Test func disguisedStrongWordsFlag() {
        for title in ["s3x tonight", "p0rn", "p.o.r.n", "pooorn", "5ex", "t1ts"] {
            #expect(scorer.evaluate(title).strong.isEmpty == false, "\(title)")
        }
    }

    @Test func maskedProfanityCountsAsMedium() {
        let r = scorer.evaluate("f*ck this")
        #expect(r.contributors == ["fuck"])
        #expect(!r.flagged)
        #expect(scorer.evaluate("f**k hot teen video").flagged)
    }

    @Test func profanityAloneDoesntFlag() {
        for title in ["Fuck You – CeeLo Green – YouTube", "This shit is hard – Reddit", "F*ck it, we ship – Blog"] {
            #expect(!flags(title), "\(title)")
        }
    }

    @Test func combinationsFlag() {
        let r = scorer.evaluate("fucking hot teen video")
        #expect(r.flagged)
        #expect(r.strong.isEmpty)
        #expect(r.contributors == ["fucking", "hot", "teen", "video"])
        #expect(abs(r.score - 1.1) < 1e-9)
        #expect(flags("sexy stepsister clip"))
    }

    @Test func weakWordsAloneNeverFlag() {
        #expect(!flags("Live: hot teen girls amateur homemade video"))
        #expect(scorer.evaluate("hot teen girls amateur video").score == ExplicitScorer.maxContextTotal)
    }

    @Test func ordinaryTitlesStayClean() {
        for title in ["Hot weather video – BBC", "Teen Titans Go", "Free live cam of Times Square", "Windows 10 update",
                      "Sussex", "2024 results", "Essex", "analysis", "Swift Concurrency – Apple Developer",
                      "Moby Dick – Wikipedia", "Ford Escort review", "Kick ass in Swift 6"] {
            #expect(!flags(title), "\(title)")
        }
    }

    @Test func triggerTermsFlag() {
        for title in ["JAV uncensored", "Japanese AV", "Korean BJ stream", "KBJ", "koreanbj", "k b j", "K.B.J"] {
            #expect(!scorer.evaluate(title).strong.isEmpty, "\(title)")
        }
    }

    @Test func javaAndBJJStayClean() {
        for title in ["Java 21 release notes", "JavaScript – MDN", "Javadoc", "javac error", "JavaFX tutorial",
                      "BJJ Fanatics", "Brazilian Jiu-Jitsu (BJJ) guard passing", "BJ Penn highlights", "BJJJ",
                      "BJ's Wholesale", "Java hot reload video", "J A V A", "Japanese audio/visual equipment (AV)"] {
            #expect(!flags(title), "\(title)")
        }
    }

    @Test func customLexiconsWork() {
        let s = ExplicitScorer(strong: ["apple pie"], medium: ["banana|bananas"], profanity: ["darn|darned"],
                               suggestive: ["cherry", "grape"], media: ["melon"], mild: ["kiwi", "lime"])
        #expect(s.evaluate("Grandma's apple pie").strong == ["apple pie"])
        #expect(!s.evaluate("banana kiwi").flagged)
        #expect(s.evaluate("banana cherry grape").flagged)
        #expect(!s.evaluate("banana bananas").flagged) // one word, counted once
        #expect(s.evaluate("b4nana b*nana").contributors == ["banana"])
        #expect(!s.evaluate("darn darned kiwi lime").flagged) // swearing is capped
        #expect(!s.evaluate("banana melon melon").flagged)
    }

    // MARK: matcher and reports

    @Test func matcherAddsScoreFlag() {
        let on = ActivityMatcher(settings: MonitorSettings(enabled: true, flagExplicitTerms: true), explicitDomains: nil)
        #expect(on.flags(url: "https://video.test/", title: "fucking hot teen video")
                == [.score("fucking, hot, teen, video")])
        #expect(on.flags(url: "https://video.test/", title: "p0rn") == [.term("porn")])
        #expect(on.flags(url: "https://swift.org/", title: "Java hot reload video").isEmpty)

        let off = ActivityMatcher(settings: MonitorSettings(enabled: true, customTerms: ["banana"]), explicitDomains: nil)
        #expect(off.flags(url: "https://video.test/", title: "fucking hot teen video").isEmpty)
        #expect(off.flags(url: "https://shop.test/", title: "B4nana bread") == [.term("banana")])
    }

    @Test func customTermDuplicatingPresetFlagsOnce() {
        let m = ActivityMatcher(settings: MonitorSettings(enabled: true, flagExplicitTerms: true, customTerms: ["blow-job"]),
                                explicitDomains: nil)
        #expect(m.flags(url: "https://a.test/", title: "blow job") == [.term("blow job")])
    }

    @Test func scoreFlagText() {
        let f = ActivityFlag.score("fucking, hot")
        #expect(f.label == "Likely explicit: fucking, hot")
        #expect(Report.reasons(for: [f, .term("porn")]) == ["likely explicit (fucking, hot)", "word: porn"])
    }

    // MARK: review regressions

    @Test func modelNumbersArentReadAsWords() {
        for title in ["Boeing 717s at SFO", "Galaxy A55 review video clip", "53x zoom camera", "Windows 10 update",
                      "MP3 player"] {
            #expect(!flags(title), "\(title)")
        }
    }

    @Test func swearingAloneNeverFlags() {
        for title in ["Fuck this fucking bug – Stack Overflow", "Fuck this shit, damn bitch",
                      "Damn this shit is crap, bullshit, pissed", "Motherfucker – song – YouTube"] {
            #expect(!flags(title), "\(title)")
        }
    }

    @Test func everydayMediumWordsWithMediaWordsDontFlag() {
        for title in ["Ford Escort review video clip", "Moby Dick video clip", "Kick ass hot video",
                      "BJ's Wholesale hot deals video", "Pirate booty video clip", "Magna cum laude video"] {
            #expect(!flags(title), "\(title)")
        }
    }

    @Test func maskedWordsAreNeverStrong() {
        for title in ["s*x", "Get this p***y started", "t**s", "p*rn"] {
            let r = scorer.evaluate(title)
            #expect(r.strong.isEmpty, "\(title)")
            #expect(!r.flagged, "\(title)")
        }
    }

    @Test func shortCustomTermsMatchOnlyAsWritten() {
        let m = TermMatcher(["ed", "abc", "ex", "banana"])
        #expect(m.matches(in: "3D printing").isEmpty)
        #expect(m.matches(in: "A B C").isEmpty)
        #expect(m.matches(in: "3x faster").isEmpty)
        #expect(m.matches(in: "Ed Sheeran") == ["ed"])
        #expect(m.matches(in: "b a n a n a") == ["banana"])
    }

    @Test func scoreFlagsReadAsTermsInOlderBuilds() throws {
        let data = try JSONEncoder().encode(ActivityFlag.score("a, b"))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""kind":"term""#))
        #expect(try JSONDecoder().decode(ActivityFlag.self, from: data).isScore)
        #expect(!ActivityFlag.term("porn").isScore)
    }

    @Test func softcoreWordsFlagOnTheirOwn() {
        for title in ["Massage", "Bikini haul", "bikinis 2026", "Body paint festival", "bodypaint art",
                      "Body painting tutorial", "b1kini", "m a s s a g e"] {
            #expect(!scorer.evaluate(title).strong.isEmpty, "\(title)")
        }
        #expect(!flags("Somebody painted the fence"))
    }
}
