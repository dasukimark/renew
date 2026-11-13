import Foundation
import Testing
@testable import RenewShared

@Suite("Rule parsing")
struct RuleParsingTests {
    @Test func plainDomain() {
        #expect(Rule.parse("Reddit.com")?.description == "reddit.com")
        #expect(Rule.parse("https://www.reddit.com/")?.description == "reddit.com")
        #expect(Rule.parse("*.reddit.com")?.description == "reddit.com")
        #expect(Rule.parse("reddit.com:443")?.description == "reddit.com")
    }

    @Test func pathRule() {
        let r = Rule.parse("youtube.com/shorts/")
        #expect(r?.host == "youtube.com")
        #expect(r?.path == "/shorts")
        #expect(r?.description == "youtube.com/shorts")
        #expect(Rule.parse("https://youtube.com/shorts?x=1#y")?.description == "youtube.com/shorts")
    }

    @Test func keywordAndAllow() {
        #expect(Rule.parse("keyword:Casino")?.description == "keyword:casino")
        #expect(Rule.parse("!music.youtube.com")?.kind == .allow)
        #expect(Rule.parse("allow:music.youtube.com")?.description == "!music.youtube.com")
    }

    @Test func rejectsGarbage() {
        #expect(Rule.parse("") == nil)
        #expect(Rule.parse("localhost") == nil)
        #expect(Rule.parse("not a domain") == nil)
        #expect(Rule.parse("keyword:") == nil)
        #expect(Rule.parse("bad_host.com") == nil)
    }

    @Test func canonicalDedupes() {
        let (valid, rejected) = canonicalRules(["reddit.com", "www.reddit.com", "https://reddit.com/", "??"])
        #expect(valid == ["reddit.com"])
        #expect(rejected == ["??"])
    }
}

@Suite("URL matching")
struct MatchingTests {
    let rules = RuleSet(strings: ["reddit.com", "youtube.com/shorts", "keyword:casino", "!old.reddit.com"])

    @Test func domainsAndSubdomains() {
        #expect(rules.match("https://reddit.com/")?.description == "reddit.com")
        #expect(rules.match("https://www.reddit.com/r/swift")?.description == "reddit.com")
        #expect(rules.match("https://np.reddit.com/r/swift") != nil)
        #expect(rules.match("reddit.com/r/swift") != nil) // Firefox address bar drops the scheme
        #expect(rules.match("https://notreddit.com/") == nil)
        #expect(rules.match("https://reddit.com.evil.org/") == nil)
    }

    @Test func pathPrefixes() {
        #expect(rules.match("https://www.youtube.com/shorts/abc123")?.description == "youtube.com/shorts")
        #expect(rules.match("https://m.youtube.com/shorts") != nil)
        #expect(rules.match("https://www.youtube.com/SHORTS/abc") != nil)
        #expect(rules.match("https://www.youtube.com/watch?v=abc") == nil)
        #expect(rules.match("https://www.youtube.com/shortsfeed") == nil)
        #expect(rules.match("https://www.youtube.com/") == nil)
    }

    @Test func keywords() {
        #expect(rules.match("https://example.com/best-casino-games")?.description == "keyword:casino")
        #expect(rules.match("https://example.com/search?q=CASINO") != nil)
        #expect(rules.match("https://example.com/search?q=%63asino") != nil)
        #expect(rules.match("https://example.com/") == nil)
    }

    @Test func allowWins() {
        #expect(rules.match("https://old.reddit.com/r/swift") == nil)
        #expect(rules.match("https://www.reddit.com/r/swift") != nil)
    }

    @Test func ignoresNonWebAndBlockPage() {
        #expect(rules.match("about:blank") == nil)
        #expect(rules.match("chrome://newtab/") == nil)
        #expect(rules.match("file:///Users/me/reddit.com.html") == nil)
        #expect(rules.match("http://127.0.0.1:47501/blocked?u=https%3A%2F%2Freddit.com&r=casino") == nil)
        #expect(rules.match("reddit casino") == nil) // search terms typed in the bar
        #expect(rules.match("") == nil)
    }
}

@Suite("Durations")
struct DurationTests {
    @Test func parsing() {
        #expect(DurationText.parse("25") == 1500)
        #expect(DurationText.parse("90m") == 5400)
        #expect(DurationText.parse("2h") == 7200)
        #expect(DurationText.parse("1h30m") == 5400)
        #expect(DurationText.parse("1d") == 86400)
        #expect(DurationText.parse("45s") == 45)
        #expect(DurationText.parse("") == nil)
        #expect(DurationText.parse("abc") == nil)
        #expect(DurationText.parse("10x") == nil)
        #expect(DurationText.parse("1h30") == nil)
        #expect(DurationText.parse("0m") == nil)
    }

    @Test func rejectsHugeValuesInsteadOfCrashing() {
        #expect(DurationText.parse("999999999999999999") == nil)
        #expect(DurationText.parse("200000000000000d") == nil)
        #expect(DurationText.parse("9223372036854775807s") == nil)
        #expect(DurationText.parse("99999999999999999999999") == nil) // doesn't fit in Int
        #expect(DurationText.parse("366d") == nil)                    // past the 1-year cap
        #expect(DurationText.parse("365d") == 365 * 86_400)
    }

    @Test func formatting() {
        #expect(DurationText.format(45) == "45s")
        #expect(DurationText.format(605) == "10m 05s")
        #expect(DurationText.format(7500) == "2h 05m")
        #expect(DurationText.format(-5) == "0s")
    }
}

@Suite("Wire protocol")
struct WireTests {
    @Test func roundTrip() throws {
        let req = Request(cmd: .start, durationSeconds: 600, rules: ["reddit.com"])
        let data = try Wire.encoder.encode(req)
        let back = try Wire.decoder.decode(Request.self, from: data)
        #expect(back.cmd == .start)
        #expect(back.durationSeconds == 600)
        #expect(back.rules == ["reddit.com"])
    }
}

@Suite("Browser detection")
struct BrowserTests {
    @Test func knownBrowsers() {
        #expect(BrowserCatalog.kind(of: "com.apple.Safari") == .safari)
        #expect(BrowserCatalog.kind(of: "com.google.Chrome") == .chromium)
        #expect(BrowserCatalog.kind(of: "org.mozilla.firefox") == .firefox)
        #expect(BrowserCatalog.kind(of: "com.operasoftware.Opera") == .unsupported)
    }

    @Test func webAppsAreUnsupported() {
        #expect(BrowserCatalog.kind(of: "com.apple.Safari.WebApp.1A2B3C4D-0000-1111-2222-333344445555") == .unsupported)
        #expect(BrowserCatalog.kind(of: "com.google.Chrome.app.agimnkijcaahngcdmfeangaknmldooml") == .unsupported)
        #expect(BrowserCatalog.kind(of: "com.microsoft.edgemac.app.abcdef") == .unsupported)
    }

    @Test func helperProcessesAreLeftAlone() {
        #expect(BrowserCatalog.kind(of: "com.google.Chrome.helper") == nil)
        #expect(BrowserCatalog.kind(of: "com.google.Chrome.helper.renderer") == nil)
        #expect(BrowserCatalog.kind(of: "com.google.Chrome.framework.AlertNotificationService") == nil)
        #expect(BrowserCatalog.kind(of: "com.apple.Safari.SafeBrowsing") == nil)
        #expect(BrowserCatalog.kind(of: "com.apple.dt.Xcode") == nil)
        #expect(BrowserCatalog.kind(of: nil) == nil)
    }
}
