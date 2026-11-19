import Foundation
import Testing
@testable import RenewShared

// Explicit words are fine here; explicit domains are made up.

@Suite("Site categories")
struct SiteCategoryTests {
    @Test func workSites() {
        for host in ["myteam.atlassian.net", "github.com", "www.github.com", "app.slack.com", "acme.sharepoint.com",
                     "docs.google.com", "mail.google.com", "teams.microsoft.com"] {
            #expect(SiteCategory.of(host: host) == .work, "\(host)")
        }
        for host in ["github.com.evil.example", "notgithub.com", "raw.githubusercontent.com", "google.com", "www.google.com", "images.google.com",
                     "drive.google.com", "microsoft.com"] {
            #expect(SiteCategory.of(host: host) != .work, "\(host)")
        }
        // Personal and public file hosts under work domains.
        #expect(SiteCategory.of(host: "gist.github.com") == .other)
        #expect(SiteCategory.of(host: "acme-my.sharepoint.com") == .other)
        #expect(SiteCategory.of(url: "https://www.figma.com/community/file/1") == .other)
        #expect(SiteCategory.of(url: "https://www.figma.com/design/abc") == .work)
    }

    @Test func recoverySites() {
        for host in ["www.covenanteyes.com", "covenanteyes.com", "nofap.com", "fightthenewdrug.org", "sa.org"] {
            #expect(SiteCategory.of(host: host) == .recovery, "\(host)")
        }
        for host in ["covenanteyes.com.example", "notnofap.com", "visa.org"] {
            #expect(SiteCategory.of(host: host) != .recovery, "\(host)")
        }
    }

    @Test func mixedSites() {
        for host in ["old.reddit.com", "reddit.com", "m.youtube.com", "x.com", "bsky.app", "www.pixiv.net",
                     "xcancel.com", "redlib.example.org", "nitter-1.example.net", "yewtu.be"] {
            #expect(SiteCategory.of(host: host) == .mixed, "\(host)")
        }
        for host in ["swift.org", "news.example", "piper.example.com", "reddit.com.example"] {
            #expect(SiteCategory.of(host: host) == .other, "\(host)")
        }
        #expect(SiteCategory.of(url: "https://www.youtube.com/watch?v=abc") == .mixed)
        #expect(SiteCategory.of(url: "about:blank") == .other)
    }

    @Test func singlePosts() {
        #expect(PostURL.isSinglePost("https://www.reddit.com/r/swift/comments/abc/title/"))
        #expect(PostURL.isSinglePost("https://x.com/someone/status/123"))
        #expect(PostURL.isSinglePost("https://bsky.app/profile/a.bsky.social/post/xyz"))
        #expect(PostURL.isSinglePost("https://www.youtube.com/watch?v=abc"))
        #expect(PostURL.isSinglePost("https://youtu.be/abc"))
        #expect(PostURL.isSinglePost("https://redd.it/abc"))
        #expect(PostURL.isSinglePost("https://www.instagram.com/p/abc/"))
        #expect(PostURL.isSinglePost("https://vimeo.com/123456"))
        #expect(!PostURL.isSinglePost("https://www.reddit.com/r/swift/"))
        #expect(!PostURL.isSinglePost("https://www.reddit.com/r/watchmaking/"))
        #expect(!PostURL.isSinglePost("https://www.deviantart.com/artists"))
        #expect(!PostURL.isSinglePost("https://x.com/home"))
        #expect(!PostURL.isSinglePost("https://youtu.be/"))
        // Feeds named like a marker: subreddits, channel tabs, post lists.
        #expect(!PostURL.isSinglePost("https://www.reddit.com/r/videos/"))
        #expect(!PostURL.isSinglePost("https://www.reddit.com/r/art/top/"))
        #expect(!PostURL.isSinglePost("https://www.reddit.com/r/photo/"))
        #expect(!PostURL.isSinglePost("https://www.youtube.com/@someone/videos"))
        #expect(!PostURL.isSinglePost("https://www.youtube.com/@someone/shorts"))
        #expect(!PostURL.isSinglePost("https://www.patreon.com/someone/posts"))
        #expect(!PostURL.isSinglePost("https://www.instagram.com/reels/"))
        #expect(!PostURL.isSinglePost("https://www.twitch.tv/someone/videos"))
        #expect(PostURL.isSinglePost("https://www.reddit.com/r/videos/comments/abc/title/"))
        #expect(PostURL.isSinglePost("https://www.youtube.com/shorts/abc"))
        #expect(PostURL.isSinglePost("https://www.patreon.com/posts/title-123"))
        #expect(PostURL.isSinglePost("https://www.pixiv.net/en/artworks/123"))
        #expect(PostURL.isSinglePost("https://www.tiktok.com/@someone/video/123"))
        #expect(PostURL.isSinglePost("https://www.deviantart.com/someone/art/title-123"))
    }
}

@Suite("Page signals")
struct PageSignalsTests {
    @Test func findsSiteLabelsOnTheirSites() {
        let gate = PageSignals.find(host: "www.reddit.com", text: "Hello\nYou must be 18+ to view this community\nYes")
        #expect(gate.labels.contains("18+ community gate"))
        // The same wording elsewhere isn't Reddit's gate.
        #expect(PageSignals.find(host: "x.com", text: "You must be 18+ to view this community").labels.isEmpty)
        #expect(PageSignals.find(host: "x.com", text: "The following media includes potentially sensitive content.")
            .labels == ["sensitive media warning"])
        #expect(PageSignals.find(host: "www.youtube.com", text: "Sign in to confirm your age").labels
            == ["age-restricted video"])
        #expect(PageSignals.find(host: "pixiv.net", text: "R-18").labels == ["R-18 tag"])
    }

    @Test func postLabelsInRepliesAreNotThePagesOwn() {
        let reply = PageSignals.find(host: "x.com", parts: ["A clean post"],
                                     others: ["potentially sensitive content", "NSFW"])
        #expect(reply.labels == ["NSFW tag"])
        let words = PageSignals.find(host: "x.com", parts: [], others: ["porn"])
        #expect(words.strongWords == ["porn"])
    }

    @Test func readStateReportsOnlyNewText() {
        let state = PageReadState(interval: 15)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let key = "1|https://x.com/home"
        #expect(state.take(key, now: t0))
        #expect(!state.take(key, now: t0 + 5))
        #expect(state.findings(key, host: "x.com", parts: ["NSFW", "hello"]).labels == ["NSFW tag"])
        #expect(state.take(key, now: t0 + 15))
        // Read again with more loaded: only the new text's findings.
        #expect(state.findings(key, host: "x.com", parts: ["NSFW", "hello", "porn"])
                == PageSignals(strongWords: ["porn"]))
        // Nothing new: nothing found.
        #expect(state.findings(key, host: "x.com", parts: ["NSFW", "porn"]).isEmpty)
        // A post label first seen in a reply, then on the post itself, counts.
        let post = "1|https://x.com/a/status/1"
        #expect(state.findings(post, host: "x.com", parts: [], others: ["potentially sensitive content"]).labels.isEmpty)
        #expect(state.findings(post, host: "x.com", parts: ["potentially sensitive content"]).labels
                == ["sensitive media warning"])
    }

    @Test func forgottenPagesAreCheckedAfresh() {
        let state = PageReadState(interval: 15)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let a = "1|https://x.com/home", b = "2|https://x.com/home"
        _ = state.take(a, now: t0)
        #expect(state.findings(a, host: "x.com", parts: ["NSFW"]).labels == ["NSFW tag"])
        // Another browser showing the same page has its own record.
        #expect(state.findings(b, host: "x.com", parts: ["NSFW"]).labels == ["NSFW tag"])
        state.keep(only: [b])
        #expect(state.take(a, now: t0 + 1))
        #expect(state.findings(a, host: "x.com", parts: ["NSFW"]).labels == ["NSFW tag"])
        state.reset()
        #expect(state.findings(b, host: "x.com", parts: ["NSFW"]).labels == ["NSFW tag"])
        // A read that found nothing is retried straight away.
        _ = state.take(b, now: t0)
        state.giveBack(b)
        #expect(state.take(b, now: t0 + 1))
    }

    @Test func manyStrongPartsAreAllChecked() {
        let parts = (0..<30).map { "part \($0) porn" } + ["hentai"]
        #expect(PageSignals.find(host: "x.com", parts: parts).strongWords.contains("hentai"))
    }

    @Test func strongOnlyLookupMatchesFullScoring() {
        let s = ExplicitScorer.preset
        for text in ["free porn xxx videos", "hot sexy girls", "big ass", "hentai and porn", "the weather"] {
            #expect(s.strongMatches(in: text) == s.evaluate(text).strong, "\(text)")
        }
    }

    @Test func wholePhrasesOnly() {
        #expect(PageSignals.find(host: "reddit.com", text: "nsfwish content").labels.isEmpty)
        #expect(PageSignals.find(host: "reddit.com", text: "a post [NSFW]").labels == ["NSFW tag"])
        #expect(PageSignals.find(host: "bsky.app", text: "adult contentment").labels.isEmpty)
    }

    @Test func strongWords() {
        let s = PageSignals.find(host: "reddit.com", text: "porn here, and hentai, and p0rn again, xxx")
        #expect(s.strongWords == ["porn", "xxx", "hentai"] || Set(s.strongWords) == ["porn", "xxx", "hentai"])
        #expect(PageSignals.find(host: "reddit.com", text: "Essex analysis in Java").strongWords.isEmpty)
        // Single letters from separate elements never join into a word.
        #expect(PageSignals.find(host: "reddit.com", parts: ["S", "E", "X", "Home"]).strongWords.isEmpty)
        #expect(PageSignals.find(host: "reddit.com", parts: ["s e x"]).strongWords == ["sex"])
    }

    @Test func capsAndMerges() {
        let many = PageSignals(labels: (0..<30).map { "l\($0)" }, strongWords: [String(repeating: "a", count: 100)])
        let c = many.capped()
        #expect(c.labels.count == PageSignals.maxItems)
        #expect(c.strongWords.first?.count == PageSignals.maxItemLength)
        let m = PageSignals(labels: ["a"], strongWords: ["x"]).merged(with: PageSignals(labels: ["a", "b"], strongWords: ["y"]))
        #expect(m == PageSignals(labels: ["a", "b"], strongWords: ["x", "y"]))
    }

    @Test func eventRoundTripsSignals() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let e = ActivityEvent(start: now, end: now, browser: "Safari", url: "https://reddit.com/", host: "reddit.com",
                              title: "T", signals: PageSignals(labels: ["NSFW tag"]))
        let back = try Wire.decoder.decode(ActivityEvent.self, from: Wire.encoder.encode(e))
        #expect(back == e)
        let plain = ActivityEvent(start: now, end: now, browser: "Safari", url: "https://a.test/", host: "a.test", title: "T",
                                  signals: PageSignals())
        #expect(plain.signals == nil)
        let json = String(decoding: try Wire.encoder.encode(plain), as: UTF8.self)
        #expect(!json.contains("signals"))
        #expect(try Wire.decoder.decode(ActivityEvent.self, from: Wire.encoder.encode(plain)).signals == nil)
    }

    @Test func visitTrackerMergesSignals() {
        var t = VisitTracker(minDuration: 0)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let url = "https://www.reddit.com/r/a/"
        _ = t.observe([PageObservation(source: "s", browser: "B", url: url, title: "A",
                                       signals: PageSignals(labels: ["NSFW tag"]))], channel: "c", at: t0)
        _ = t.observe([PageObservation(source: "s", browser: "B", url: url, title: "A")], channel: "c", at: t0 + 1)
        _ = t.observe([PageObservation(source: "s", browser: "B", url: url, title: "A",
                                       signals: PageSignals(strongWords: ["porn"]))], channel: "c", at: t0 + 2)
        let done = t.closeAll(at: t0 + 3)
        #expect(done.first?.signals == PageSignals(labels: ["NSFW tag"], strongWords: ["porn"]))
    }
}

@Suite("Mixed and work sites in the Monitor")
struct MixedSiteMatchingTests {
    private func matcher(explicitContent: Bool = true, custom: [String] = [], sites: [String] = []) -> ActivityMatcher {
        ActivityMatcher(settings: MonitorSettings(enabled: true, customDomains: sites, flagExplicit: explicitContent,
                                                  customTerms: custom),
                        explicitDomains: DomainSet(["github.com", "adult.example"]))
    }

    @Test func workSitesAreNeverFlagged() {
        let m = matcher(custom: ["roadmap"], sites: ["slack.com"])
        #expect(m.flags(url: "https://github.com/a/b", title: "porn").isEmpty)
        #expect(m.flags(url: "https://app.slack.com/client", title: "Roadmap").isEmpty)
        #expect(m.flags(url: "https://docs.google.com/document/d/1", title: "nude",
                        signals: PageSignals(labels: ["NSFW tag"], strongWords: ["porn", "xxx", "hentai"])).isEmpty)
        // Even with mixed checks off.
        #expect(matcher(explicitContent: false, sites: ["github.com"]).flags(url: "https://github.com/", title: "porn").isEmpty)
        // Other sites still are.
        #expect(m.flags(url: "https://adult.example/", title: "") == [.domain("explicit", "adult.example")])
    }

    @Test func recoverySitesAreNotFlaggedByBuiltInWords() {
        let m = matcher()
        #expect(m.flags(url: "https://www.covenanteyes.com/a/", title: "Overcome Porn. Restore What Matters.").isEmpty)
        #expect(m.flags(url: "https://www.covenanteyes.com/b/", title: "The Most Up-to-Date Pornography Statistics").isEmpty)
        // Elsewhere the same title flags.
        #expect(!m.flags(url: "https://news.example/a", title: "Overcome Porn. Restore What Matters.").isEmpty)
        // Your own words still count there.
        #expect(matcher(custom: ["statistics"]).flags(url: "https://www.covenanteyes.com/b/", title: "Pornography Statistics") == [.term("statistics")])
    }

    @Test func mixedTitlePolicyIsStricter() {
        let m = matcher()
        #expect(m.flags(url: "https://www.reddit.com/r/a/", title: "sexy outfit") == [.score("sexy")])
        #expect(m.flags(url: "https://news.example/", title: "sexy outfit").isEmpty)
        #expect(m.flags(url: "https://x.com/home", title: "hot teen girls amateur") == [.score("hot, teen, girls, amateur")])
        #expect(m.flags(url: "https://x.com/home", title: "damn shit crap").isEmpty) // swearing stays capped
        #expect(matcher(explicitContent: false).flags(url: "https://www.reddit.com/r/a/", title: "sexy outfit").isEmpty)
    }

    @Test func ambiguousWordsNeedASecondSignalEvenOnMixedSites() {
        let m = matcher()
        for title in ["Kick-ass workout routine", "Restoring my old Ford Escort", "Uncensored director's cut trailer",
                      "Summa cum laude", "Paint stripper review", "AITA for upsetting my stepmom"] {
            #expect(m.flags(url: "https://www.reddit.com/r/a/", title: title).isEmpty, "\(title)")
        }
        // With a second signal they still add up.
        #expect(m.flags(url: "https://www.reddit.com/r/a/", title: "uncensored sexy") == [.score("sexy, uncensored")])
        #expect(m.flags(url: "https://www.reddit.com/r/a/", title: "escort hot girls") == [.score("escort, hot, girls")])
        #expect(m.flags(url: "https://news.example/", title: "escort hot girls") == [.score("escort, hot, girls")])
    }

    @Test func maskedWordsNeverFlagAloneOnMixedSites() {
        let m = matcher()
        #expect(m.flags(url: "https://www.reddit.com/r/a/", title: "my p***y garden").isEmpty)
        #expect(m.flags(url: "https://www.reddit.com/r/a/", title: "s*xy").isEmpty)
        #expect(m.flags(url: "https://www.reddit.com/r/a/", title: "sexy").count == 1)
    }

    @Test func siteLabels() {
        let m = matcher()
        let gate = PageSignals(labels: ["18+ community gate"])
        #expect(m.flags(url: "https://www.reddit.com/r/a/", title: "Community", signals: gate)
                == [.siteLabel("18+ community gate")])
        let cover = PageSignals(labels: ["sensitive media warning"])
        #expect(m.flags(url: "https://x.com/a/status/1", title: "Post", signals: cover)
                == [.siteLabel("sensitive media warning")])
        // On a feed a post label only adds to the score.
        #expect(m.flags(url: "https://x.com/home", title: "Feed", signals: cover).isEmpty)
        // Hints (wording a comment or recommended link could have) never flag
        // alone, single post or not.
        let tag = PageSignals(labels: ["NSFW tag"])
        #expect(m.flags(url: "https://www.youtube.com/watch?v=abc", title: "Video", signals: tag).isEmpty)
        #expect(m.flags(url: "https://www.reddit.com/r/a/", title: "Feed", signals: tag).isEmpty)
        #expect(m.flags(url: "https://www.reddit.com/r/a/", title: "hot girls", signals: tag)
                == [.score("hot, girls, site label: NSFW tag")])
        // Labels count only on mixed sites, with the setting on.
        #expect(m.flags(url: "https://news.example/", title: "Community", signals: gate).isEmpty)
        #expect(matcher(explicitContent: false).flags(url: "https://www.reddit.com/r/a/", title: "C", signals: gate).isEmpty)
        // Labels on a feed never add up to a flag on their own.
        let two = PageSignals(labels: ["sensitive media warning", "NSFW tag"])
        #expect(m.flags(url: "https://x.com/home", title: "Home", signals: two).isEmpty)
        #expect(m.flags(url: "https://x.com/home", title: "hot girls", signals: two)
                == [.score("hot, girls, site label: sensitive media warning, site label: NSFW tag")])
    }

    @Test func pageWordsNeedThree() {
        let m = matcher()
        #expect(m.flags(url: "https://x.com/home", title: "Home",
                        signals: PageSignals(strongWords: ["porn", "xxx", "hentai"])) == [.pageWords("porn, xxx, hentai")])
        #expect(m.flags(url: "https://x.com/home", title: "Home", signals: PageSignals(strongWords: ["porn", "xxx"])).isEmpty)
    }

    @Test func flagLabelsAndReasons() {
        #expect(ActivityFlag.siteLabel("NSFW tag").label == "Site label: NSFW tag")
        #expect(ActivityFlag.pageWords("a, b, c").label == "Page words: a, b, c")
        #expect(Report.reasons(for: [.siteLabel("NSFW tag"), .pageWords("a, b, c")])
                == ["site's own label: NSFW tag", "explicit words on the page (a, b, c)"])
    }

    @Test func turningExplicitContentOffIsALoosening() {
        let on = MonitorSettings(enabled: true, flagExplicit: true)
        var off = on
        off.flagExplicit = false
        #expect(on.loosenings(to: off) == ["Explicit content is no longer flagged."])
        #expect(off.loosenings(to: on).isEmpty)
    }

    @Test func settingsFromTheTwoToggleBuildStillDecode() throws {
        let json = #"{"enabled":true,"flagExplicitTerms":true,"checkMixedSites":false}"#
        let s = try JSONDecoder().decode(MonitorSettings.self, from: Data(json.utf8))
        #expect(s.flagExplicit)
    }
}
