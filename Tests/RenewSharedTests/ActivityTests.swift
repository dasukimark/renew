import Foundation
import Testing
@testable import RenewShared

private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

private func page(_ url: String, _ title: String = "", source: String = "com.apple.Safari",
                  flags: [ActivityFlag] = [], blocked: Bool = false) -> PageObservation {
    PageObservation(source: source, browser: "Safari", url: url, title: title, flags: flags, blocked: blocked)
}

@Suite("Activity matching")
struct ActivityMatchingTests {
    @Test func domainSetMatchesSubdomainsOnly() {
        let set = DomainSet(fileContents: "# comment\n\nexample.com\nwww.adult.test\n  spaced.org  \n")
        #expect(set.count == 3)
        #expect(set.match(host: "example.com") == "example.com")
        #expect(set.match(host: "a.b.example.com") == "example.com")
        #expect(set.match(host: "WWW.Example.COM.") == "example.com")
        #expect(set.match(host: "adult.test") == "adult.test") // "www." stripped on load
        #expect(set.match(host: "spaced.org") == "spaced.org")
        #expect(set.match(host: "notexample.com") == nil)
        #expect(set.match(host: "example.com.evil.net") == nil)
        #expect(set.match(host: "com") == nil)
    }

    @Test func termsMatchWholeWords() {
        let m = TermMatcher(["sex", "blow job", "porn"])
        #expect(m.matches(in: "Essex county news").isEmpty)
        #expect(m.matches(in: "Scunthorpe United").isEmpty)
        #expect(m.matches(in: "Sex Education - Netflix") == ["sex"])
        #expect(m.matches(in: "SEX!") == ["sex"])
        #expect(m.matches(in: "best blow-job ever") == ["blow job"])
        #expect(m.matches(in: "blow your job").isEmpty)
        #expect(m.matches(in: "Pörn and sex") == ["sex", "porn"])
        #expect(m.matches(in: "pornography").isEmpty)
        #expect(TermMatcher([]).matches(in: "anything").isEmpty)
        #expect(TermMatcher(["  ", "!!"]).isEmpty)
    }

    @Test func presetTermsDontFlagOrdinaryTitles() {
        let m = TermMatcher(ExplicitTerms.preset)
        for title in ["Analysis of Essex middlesex data", "Cockpit checklist", "Sussex University", "Matsexpress",
                      "Swift Concurrency – Apple Developer", "Pornic, France travel guide"] {
            #expect(m.matches(in: title).isEmpty, "\(title)")
        }
        #expect(!m.matches(in: "Free porn videos").isEmpty)
    }

    @Test func matcherCombinesListsSitesAndWords() {
        let lists = ["social": ["reddit.com", "!old.reddit.com"], "video": ["youtube.com/shorts"]]
        let settings = MonitoringSettings(enabled: true, watchLists: ["explicit", "social", "video", "missing"],
                                          customDomains: ["Example.org"], flagExplicitTerms: true, customTerms: ["Gambling"])
        let m = ActivityMatcher(settings: settings, lists: lists, explicitDomains: DomainSet(["adult.test"]))

        #expect(m.flags(url: "https://cdn.adult.test/x", title: "Home") == [.domain("explicit", "adult.test")])
        #expect(m.flags(url: "https://www.reddit.com/r/swift", title: "Swift") == [.domain("social", "reddit.com")])
        #expect(m.flags(url: "https://old.reddit.com/r/swift", title: "Swift").isEmpty) // allow rule wins
        #expect(m.flags(url: "https://youtube.com/shorts/abc", title: "") == [.domain("video", "youtube.com/shorts")])
        #expect(m.flags(url: "https://youtube.com/watch?v=1", title: "").isEmpty)
        #expect(m.flags(url: "https://sub.example.org/", title: "") == [.domain("custom", "example.org")])
        #expect(m.flags(url: "https://news.test/", title: "Online gambling tips") == [.term("gambling")])
        #expect(m.flags(url: "https://adult.test/", title: "Free porn") == [.domain("explicit", "adult.test"), .term("porn")])
        // Non-web pages are never matched by site, only by title.
        #expect(m.flags(url: "about:blank", title: "").isEmpty)
    }

    @Test func matcherRespectsSwitches() {
        let off = MonitoringSettings(enabled: true, watchLists: [], customDomains: [], flagExplicitTerms: false)
        let m = ActivityMatcher(settings: off, lists: [:], explicitDomains: DomainSet(["adult.test"]))
        #expect(m.flags(url: "https://adult.test/", title: "porn").isEmpty)
    }

    @Test func flagLabels() {
        #expect(ActivityFlag.domain("explicit", "x.test").label == "Explicit site")
        #expect(ActivityFlag.domain("social", "x.test").label == "Social list")
        #expect(ActivityFlag.domain("custom", "x.test").label == "Watched site")
        #expect(ActivityFlag.term("porn").label == "Word: porn")
    }
}

@Suite("Activity settings")
struct MonitoringSettingsTests {
    @Test func offByDefaultAndOldStateDecodes() throws {
        #expect(PersistedState().monitoring(for: 501) == .off)
        #expect(!MonitoringSettings.off.enabled)
        let old = try Wire.decoder.decode(PersistedState.self, from: Data(#"{"alertURL":"https://ntfy.sh/x"}"#.utf8))
        #expect(old.monitoring == nil)
        #expect(old.monitoring(for: 501) == .off)
        let partial = try Wire.decoder.decode(MonitoringSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(partial.enabled)
        // Nothing is watched unless chosen.
        #expect(partial.watchLists.isEmpty)
        #expect(partial.customDomains.isEmpty)
        #expect(!partial.flagExplicitTerms)
        #expect(partial.customTerms.isEmpty)
    }

    @Test func roundTrips() throws {
        let m = MonitoringSettings(enabled: true, watchLists: ["social"], customDomains: ["a.test"],
                                   flagExplicitTerms: false, customTerms: ["x y"])
        #expect(try Wire.decoder.decode(MonitoringSettings.self, from: Wire.encoder.encode(m)) == m)
        let e = ActivityEvent(start: at(0), end: at(30), browser: "Safari", url: "https://a.test/", host: "a.test",
                              title: "A", flags: [.term("x")], blocked: true)
        #expect(try Wire.decoder.decode(ActivityEvent.self, from: Wire.encoder.encode(e)) == e)
    }

    @Test func normalizes() {
        let m = MonitoringSettings(enabled: true, watchLists: [" Social", "social", "", "EXPLICIT"],
                                   customDomains: ["https://www.Example.com/", "not a site", "example.com"],
                                   customTerms: ["  Two   Words ", "two words", "", String(repeating: "a", count: 65)])
            .normalized()
        #expect(m.watchLists == ["social", "explicit"])
        #expect(m.customDomains == ["example.com"])
        #expect(m.customTerms == ["two words"])
    }
}

@Suite("Visit tracking")
struct VisitTrackerTests {
    @Test func urlChangeSplitsVisits() {
        var t = VisitTracker()
        #expect(t.observe([page("https://a.test/", "A")], channel: "browser", at: at(0)).isEmpty)
        #expect(t.observe([page("https://a.test/", "A")], channel: "browser", at: at(5)).isEmpty)
        let done = t.observe([page("https://b.test/", "B")], channel: "browser", at: at(10))
        #expect(done.count == 1)
        #expect(done[0].url == "https://a.test/")
        #expect(done[0].host == "a.test")
        #expect(done[0].duration == 10)
        let rest = t.observe([], channel: "browser", at: at(25))
        #expect(rest.map(\.url) == ["https://b.test/"])
        #expect(rest[0].duration == 15)
        #expect(t.openCount == 0)
    }

    @Test func titleChangeMergesAndAddsFlags() {
        var t = VisitTracker()
        _ = t.observe([page("https://v.test/watch", "Loading…")], channel: "browser", at: at(0))
        _ = t.observe([page("https://v.test/watch", "Some video", flags: [.term("porn")])], channel: "browser", at: at(3))
        _ = t.observe([page("https://v.test/watch", "", flags: [.term("porn")], blocked: true)], channel: "browser", at: at(4))
        let done = t.closeAll(at: at(8))
        #expect(done.count == 1)
        #expect(done[0].title == "Some video") // an empty title doesn't replace a real one
        #expect(done[0].flags == [.term("porn")])
        #expect(done[0].blocked)
        #expect(done[0].duration == 8)
    }

    @Test func shortUnflaggedVisitsAreDropped() {
        var t = VisitTracker(minDuration: 1)
        _ = t.observe([page("https://redirect.test/")], channel: "browser", at: at(0))
        #expect(t.observe([page("https://final.test/")], channel: "browser", at: at(0.4)).isEmpty)
        let finalDone = t.observe([page("https://flagged.test/", flags: [.term("x")])], channel: "browser", at: at(2))
        #expect(finalDone.map(\.url) == ["https://final.test/"])
        // Flagged visits are kept however short.
        let done = t.observe([], channel: "browser", at: at(2.2))
        #expect(done.map(\.url) == ["https://flagged.test/"])
    }

    @Test func channelsAreIndependent() {
        var t = VisitTracker()
        _ = t.observe([page("https://tab.test/")], channel: "browser", at: at(0))
        _ = t.observe([page("https://one.test/", source: "app:t3"), page("https://two.test/", source: "app:t3")],
                      channel: "embedded", at: at(0))
        // The embedded channel reporting nothing doesn't end the browser visit.
        let embeddedDone = t.observe([], channel: "embedded", at: at(10))
        #expect(Set(embeddedDone.map(\.url)) == ["https://one.test/", "https://two.test/"])
        #expect(t.openCount == 1)
        #expect(t.closeAll(at: at(20)).map(\.url) == ["https://tab.test/"])
    }

    @Test func nonWebPagesAreIgnored() {
        var t = VisitTracker()
        _ = t.observe([page("about:blank"), page("http://127.0.0.1:47501/blocked"), page("file:///x.html")],
                      channel: "browser", at: at(0))
        #expect(t.openCount == 0)
    }

    @Test func emptyTitleFallsBackToHost() {
        var t = VisitTracker()
        _ = t.observe([page("https://www.notitle.test/x")], channel: "browser", at: at(0))
        #expect(t.closeAll(at: at(5)).first?.title == "notitle.test")
    }
}

@Suite("Activity log")
struct ActivityLogTests {
    private func tempDir() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("renew-activity-\(UUID().uuidString)").path
        return dir
    }

    @Test func dayKeys() {
        let utc = TimeZone(identifier: "UTC")!
        #expect(ActivityLogStore.dayKey(Date(timeIntervalSince1970: 0), timeZone: utc) == "1970-01-01")
        #expect(ActivityLogStore.date(ofDay: "2026-11-16", timeZone: utc) == Date(timeIntervalSince1970: 1_794_787_200))
        #expect(ActivityLogStore.date(ofDay: "2026-02-30") == nil)
        #expect(ActivityLogStore.date(ofDay: "../../etc") == nil)
        #expect(ActivityLogStore.date(ofDay: "2026-1-1") == nil)
    }

    @Test func expiry() {
        let utc = TimeZone(identifier: "UTC")!
        let now = ActivityLogStore.date(ofDay: "2026-11-16", timeZone: utc)!.addingTimeInterval(3_600)
        #expect(!ActivityLogStore.isExpired(day: "2026-10-17", now: now, timeZone: utc))
        #expect(ActivityLogStore.isExpired(day: "2026-10-16", now: now, timeZone: utc))
        #expect(!ActivityLogStore.isExpired(day: "nonsense", now: now, timeZone: utc))
    }

    @Test func sanitizes() {
        let now = at(0)
        let ok = ActivityEvent(start: at(-10), end: at(-5), browser: String(repeating: "b", count: 500),
                               url: "https://a.test/" + String(repeating: "x", count: 5_000), host: "a.test",
                               title: String(repeating: "t", count: 1_000))
        let s = ok.sanitized(now: now)
        #expect(s?.url.count == ActivityEvent.maxURLLength)
        #expect(s?.title.count == ActivityEvent.maxTitleLength)
        #expect(s?.browser.count == ActivityEvent.maxNameLength)
        var backwards = ok; backwards.end = at(-20)
        #expect(backwards.sanitized(now: now) == nil)
        var future = ok; future.start = at(3_600); future.end = at(3_700)
        #expect(future.sanitized(now: now) == nil)
        var noHost = ok; noHost.host = ""
        #expect(noHost.sanitized(now: now) == nil)
        var long = ok; long.start = at(-2 * 86_400); long.end = long.start.addingTimeInterval(3 * 86_400)
        #expect(long.sanitized(now: now)?.duration == ActivityEvent.maxDuration)
        var ancient = ok; ancient.start = at(-40 * 86_400); ancient.end = ancient.start.addingTimeInterval(5)
        #expect(ancient.sanitized(now: now) == nil)
    }

    @Test func appendReadAndPrune() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = ActivityLogStore(directory: dir)
        let now = Date()
        let a = ActivityEvent(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(-30), browser: "Safari",
                              url: "https://a.test/", host: "a.test", title: "A")
        let b = ActivityEvent(start: now.addingTimeInterval(-20), end: now.addingTimeInterval(-10), browser: "Chrome",
                              url: "https://b.test/", host: "b.test", title: "B", flags: [.term("porn")])
        var bad = a; bad.end = bad.start.addingTimeInterval(-1)
        #expect(store.append([b, a, bad], uid: 501, now: now) == 2)

        let today = ActivityQuery(date: a.start)
        // Same day for both unless the test runs right at midnight.
        if ActivityLogStore.dayKey(a.start) == ActivityLogStore.dayKey(b.start) {
            #expect(store.read(today, uid: 501).events.map(\.url) == ["https://a.test/", "https://b.test/"])
            #expect(store.read(ActivityQuery(date: a.start, flaggedOnly: true), uid: 501).events.map(\.url) == ["https://b.test/"])
        }
        // Other users see nothing.
        #expect(store.read(today, uid: 502).events.isEmpty)

        // The files are private.
        let attrs = try FileManager.default.attributesOfItem(atPath: dir + "/501")
        #expect((attrs[.posixPermissions] as? Int) == 0o700)
        let file = dir + "/501/\(ActivityLogStore.dayKey(a.start)).jsonl"
        #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int) == 0o600)

        // An old day file goes; today's stays.
        let old = dir + "/501/2000-01-01.jsonl"
        FileManager.default.createFile(atPath: old, contents: Data("{}\n".utf8))
        FileManager.default.createFile(atPath: dir + "/501/notes.txt", contents: Data())
        #expect(store.prune(now: now) == 1)
        #expect(!FileManager.default.fileExists(atPath: old))
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(FileManager.default.fileExists(atPath: dir + "/501/notes.txt"))
    }

    @Test func capsEventsPerRequest() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = ActivityLogStore(directory: dir)
        let now = Date()
        let events = (0..<150).map { _ in
            ActivityEvent(start: now.addingTimeInterval(-2), end: now.addingTimeInterval(-1), browser: "Safari",
                          url: "https://a.test/", host: "a.test", title: "A")
        }
        #expect(store.append(events, uid: 501, now: now) == ActivityLogStore.maxEventsPerRequest)
    }

    @Test func skipsCorruptLines() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = ActivityLogStore(directory: dir)
        let now = Date()
        let e = ActivityEvent(start: now.addingTimeInterval(-2), end: now.addingTimeInterval(-1), browser: "Safari",
                              url: "https://a.test/", host: "a.test", title: "A")
        store.append([e], uid: 501, now: now)
        let file = dir + "/501/\(ActivityLogStore.dayKey(e.start)).jsonl"
        let h = try #require(FileHandle(forWritingAtPath: file))
        h.seekToEndOfFile()
        h.write(Data("not json\n".utf8))
        h.closeFile()
        #expect(store.read(ActivityQuery(date: e.start), uid: 501).events.count == 1)
    }

    private func event(_ url: String, ago: TimeInterval, now: Date, title: String = "T") -> ActivityEvent {
        ActivityEvent(start: now.addingTimeInterval(-ago), end: now.addingTimeInterval(-ago + 1), browser: "Safari",
                      url: url, host: NormalizedURL(url)?.host ?? "x.test", title: title)
    }

    @Test func dropsResentVisits() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let now = Date()
        let a = event("https://a.test/", ago: 30, now: now)
        let b = event("https://b.test/", ago: 20, now: now)
        let store = ActivityLogStore(directory: dir)
        #expect(store.append([a], uid: 501, now: now) == 1)
        // The app quit mid-upload and sends the batch again, with one new visit.
        #expect(store.append([a, b], uid: 501, now: now) == 1)
        // A restarted renewd still knows today's ids.
        let restarted = ActivityLogStore(directory: dir)
        #expect(restarted.append([a, b], uid: 501, now: now) == 0)
        if ActivityLogStore.dayKey(a.start) == ActivityLogStore.dayKey(b.start) {
            #expect(restarted.read(ActivityQuery(date: a.start), uid: 501).events.count == 2)
        }
    }

    @Test func enforcesQuotas() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let now = Date()
        let line = (try? Wire.encoder.encode(event("https://a.test/", ago: 10, now: now)).count) ?? 200
        let store = ActivityLogStore(directory: dir, maxBytesPerDay: line * 3 + 40, maxBytesPerUser: 1 << 20)
        let batch = (0..<2).map { _ in event("https://a.test/", ago: 10, now: now) }
        #expect(store.append(batch, uid: 501, now: now) == 2)
        // The next batch would take the day over its limit, so it's dropped.
        #expect(store.append(batch, uid: 501, now: now) == 0)
        // Another user has their own allowance.
        #expect(store.append(batch, uid: 502, now: now) == 2)

        let tight = ActivityLogStore(directory: tempDir(), maxBytesPerDay: 1 << 20, maxBytesPerUser: line + 40)
        defer { try? FileManager.default.removeItem(atPath: tight.directory) }
        #expect(tight.append([event("https://a.test/", ago: 10, now: now)], uid: 501, now: now) == 1)
        #expect(tight.append([event("https://a.test/", ago: 10, now: now)], uid: 501, now: now) == 0)
    }

    @Test func incrementalReads() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let now = Date()
        let store = ActivityLogStore(directory: dir)
        let first = event("https://a.test/", ago: 30, now: now)
        guard ActivityLogStore.dayKey(first.start) == ActivityLogStore.dayKey(now) else { return } // midnight
        store.append([first], uid: 501, now: now)
        let page1 = store.read(ActivityQuery(date: now), uid: 501)
        #expect(page1.events.map(\.url) == ["https://a.test/"])
        #expect(!page1.isIncremental)

        let nothingNew = store.read(ActivityQuery(date: now, fromOffset: page1.offset), uid: 501)
        #expect(nothingNew.events.isEmpty)
        #expect(nothingNew.isIncremental)
        #expect(nothingNew.offset == page1.offset)

        store.append([event("https://b.test/", ago: 10, now: now, title: "porn")], uid: 501, now: now)
        // A half-written line isn't returned until it's complete.
        let file = dir + "/501/\(ActivityLogStore.dayKey(now)).jsonl"
        let h = try #require(FileHandle(forWritingAtPath: file))
        h.seekToEndOfFile()
        h.write(Data(#"{"partial":"#.utf8))
        h.closeFile()
        let page2 = store.read(ActivityQuery(date: now, fromOffset: page1.offset), uid: 501)
        #expect(page2.events.map(\.url) == ["https://b.test/"])
        #expect(page2.isIncremental)

        // An offset past the end (the file was replaced) reads the whole day.
        let reset = store.read(ActivityQuery(date: now, fromOffset: 1 << 30), uid: 501)
        #expect(!reset.isIncremental)
        #expect(reset.events.count == 2)
    }
}

@Suite("Per-user monitoring settings")
struct PerUserMonitoringTests {
    @Test func eachUserHasTheirOwn() {
        var state = PersistedState()
        var mine = MonitoringSettings.off
        mine.enabled = true
        state.setMonitoring(mine, for: 501)
        #expect(state.monitoring(for: 501).enabled)
        #expect(!state.monitoring(for: 502).enabled)
        // Back to the default: the entry goes.
        state.setMonitoring(.off, for: 501)
        #expect(state.monitoringByUser == nil)
    }

    @Test func oldSingleSettingMovesToTheConsoleUser() throws {
        var state = try Wire.decoder.decode(PersistedState.self, from: Data(#"{"monitoring":{"enabled":true,"watchLists":["test"]}}"#.utf8))
        let early = state.migrateMonitoring(to: nil) // nobody logged in yet: wait
        #expect(!early)
        #expect(state.monitoring != nil)
        let moved = state.migrateMonitoring(to: 501)
        #expect(moved)
        #expect(state.monitoring == nil)
        #expect(state.monitoring(for: 501).watchLists == ["test"])
        #expect(!state.monitoring(for: 502).enabled)
        let again = state.migrateMonitoring(to: 501)
        #expect(!again)
    }
}
