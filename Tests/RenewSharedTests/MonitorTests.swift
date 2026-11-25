import Foundation
import Testing
@testable import RenewShared

// Made-up domains only; never the real explicit list.

private func tempDir() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("renew-monitor-\(UUID().uuidString)").path
}

private func visit(_ url: String, ago: TimeInterval, now: Date, title: String = "T") -> ActivityEvent {
    ActivityEvent(start: now.addingTimeInterval(-ago), end: now.addingTimeInterval(-ago + 5), browser: "Safari",
                  url: url, host: NormalizedURL(url)?.host ?? "x.test", title: title)
}

@Suite("Monitor rules")
struct MonitorRulesTests {
    @Test func listSwitchOffStopsListAndOtherSiteFlagsButKeepsWords() {
        var settings = MonitorSettings(enabled: true, lists: ["games": ["play.example"]],
                                       customDomains: ["extra.example"], customTerms: ["casino"])
        #expect(!ActivityMatcher(settings: settings, explicitDomains: nil).flags(url: "https://play.example/", title: "T").isEmpty)
        settings.flagLists = false
        let m = ActivityMatcher(settings: settings, explicitDomains: nil)
        #expect(m.flags(url: "https://play.example/", title: "T").isEmpty)
        #expect(m.flags(url: "https://extra.example/", title: "T").isEmpty)
        #expect(!m.flags(url: "https://other.example/", title: "Casino night").isEmpty)
    }

    @Test func listSwitchDefaultsOnAndRoundTrips() throws {
        let old = try JSONDecoder().decode(MonitorSettings.self, from: Data(#"{"enabled":true,"lists":{"games":["play.example"]}}"#.utf8))
        #expect(old.flagLists)
        var off = old
        off.flagLists = false
        let data = try JSONEncoder().encode(off)
        let back = try JSONDecoder().decode(MonitorSettings.self, from: data)
        #expect(!back.flagLists)
        #expect(back == off)
        // An older renewd reading the old keys watches no lists either.
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((json?["watchLists"] as? [String]) == [])
    }

    @Test func turningListsOffIsALooseningAndRefusedWhileLocked() {
        let on = MonitorSettings(enabled: true, lists: ["games": ["play.example"]])
        var off = on
        off.flagLists = false
        #expect(on.loosenings(to: off) == ["Sites on monitoring lists are no longer flagged."])
        #expect(on.refusal(changingTo: off, hasPartner: true) == MonitorSettings.lockedMessage)
        #expect(off.refusal(changingTo: on, hasPartner: true) == nil)
        // Lists that watch nothing aren't looser for being off.
        var empty = MonitorSettings(enabled: true, lists: ["games": []])
        let before = empty
        empty.flagLists = false
        #expect(before.loosenings(to: empty).isEmpty)
    }

    @Test func removingSitesWhileListsAreOffIsntALoosening() {
        var off = MonitorSettings(enabled: true, lists: ["games": ["play.example", "fun.example"]],
                                  customDomains: ["other.example"])
        off.flagLists = false
        var removed = off
        removed.lists["games"] = ["fun.example"]
        removed.customDomains = []
        #expect(off.loosenings(to: removed).isEmpty)
        #expect(off.refusal(changingTo: removed, hasPartner: true) == nil)
        var deleted = off
        deleted.lists["games"] = nil
        #expect(off.loosenings(to: deleted).isEmpty)
        // Watched words still count with lists off.
        var words = off
        words.customTerms = ["casino"]
        var noWords = words
        noWords.customTerms = []
        #expect(words.loosenings(to: noWords) == ["Watched words removed: casino."])
    }

    @Test func settingsWithoutTheListSwitchSayTheyOmitIt() throws {
        let old = try Wire.decoder.decode(MonitorSettings.self, from: Data(#"{"enabled":true,"lists":{"games":["play.example"]}}"#.utf8))
        #expect(old.omitsFlagLists)
        #expect(old.flagLists)
        var off = MonitorSettings(enabled: true)
        off.flagLists = false
        let back = try Wire.decoder.decode(MonitorSettings.self, from: Wire.encoder.encode(off))
        #expect(!back.omitsFlagLists)
        #expect(!back.flagLists)
    }

    @Test func matcherFlagsMonitoringListsByName() {
        let settings = MonitorSettings(enabled: true, lists: ["games": ["play.example"], "empty": []])
        let m = ActivityMatcher(settings: settings, explicitDomains: nil)
        #expect(m.flags(url: "https://www.play.example/x", title: "") == [.domain("games", "play.example")])
        #expect(m.flags(url: "https://work.example/", title: "").isEmpty)
        // An empty list flags nothing.
        let bare = ActivityMatcher(settings: MonitorSettings(enabled: true, lists: ["games": []]), explicitDomains: nil)
        #expect(bare.isEmpty)
    }

    @Test func explicitPresetFollowsFlagExplicit() {
        let on = MonitorSettings(enabled: true, flagExplicit: true)
        let m = ActivityMatcher(settings: on, explicitDomains: DomainSet(["adult.example"]))
        #expect(m.flags(url: "https://cdn.adult.example/", title: "") == [.domain("explicit", "adult.example")])
        let off = ActivityMatcher(settings: MonitorSettings(enabled: true), explicitDomains: DomainSet(["adult.example"]))
        #expect(off.isEmpty)
        #expect(off.flags(url: "https://cdn.adult.example/", title: "").isEmpty)
    }

    @Test func normalizeCleansNamesKeepsEmptyListsAndCaps() {
        let many = (0..<(MonitorSettings.maxListRules + 10)).map { "s\($0).example" }
        let m = MonitorSettings(enabled: true,
                                lists: ["a-big": many, "b-small": ["a.example"], " New ": [], "explicit": ["x.example"],
                                        "custom": ["y.example"], "": ["z.example"]])
            .normalized()
        #expect(Set(m.lists.keys) == ["a-big", "b-small", "new"])
        #expect(m.lists["new"] == [])
        #expect(m.lists["a-big"]?.count == MonitorSettings.maxListRules)
        // The cap is across all lists, so a later one gets nothing left.
        #expect(m.lists["b-small"] == [])
        let small = MonitorSettings(lists: ["Small": ["a.example", " A.example ", "", "not valid"]]).normalized()
        #expect(small.lists == ["small": ["a.example"]])
    }

    @Test func listNames() {
        #expect(MonitorSettings.cleanListName("  Reddit ") == "reddit")
        #expect(MonitorSettings.cleanListName("Explicit") == nil)
        #expect(MonitorSettings.cleanListName("custom") == nil)
        #expect(MonitorSettings.cleanListName(" ") == nil)
        #expect(MonitorSettings.cleanListName(String(repeating: "a", count: MonitorSettings.maxListNameLength + 1)) == nil)
    }

    @Test func startersComeFromBuiltInLists() {
        #expect(MonitorSettings.starter("Social") == ListStore.builtIn["social"])
        #expect(MonitorSettings.starter("test") == nil)
    }

    @Test func watchedBlocklistsBecomeMonitoringLists() throws {
        let json = #"{"enabled":true,"watchLists":["explicit","Games","gone","custom"],"listRules":{"games":["play.example"],"custom":["c.example"]},"customDomains":["a.example"]}"#
        let m = try Wire.decoder.decode(MonitorSettings.self, from: Data(json.utf8))
        #expect(m.lists == ["games": ["play.example"], "gone": []])
        #expect(m.flagExplicit)
        #expect(m.customDomains == ["a.example", "c.example"])
        // Once lists exist, the old keys are ignored.
        let both = #"{"lists":{"news":[]},"watchLists":["games"],"listRules":{"games":["play.example"]}}"#
        #expect(try Wire.decoder.decode(MonitorSettings.self, from: Data(both.utf8)).lists == ["news": []])
    }

    @Test func encodesTheOldFormatTooForDowngrades() throws {
        let m = MonitorSettings(enabled: true, lists: ["games": ["play.example"], "news": []], customDomains: ["a.example"],
                                flagExplicit: true, customTerms: ["word"])
        let data = try Wire.encoder.encode(m)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // An older renewd reads watchLists/listRules: the same lists, and the explicit preset.
        #expect(obj["watchLists"] as? [String] == ["explicit", "games", "news"])
        #expect(obj["listRules"] as? [String: [String]] == ["games": ["play.example"], "news": []])
        let back = try Wire.decoder.decode(MonitorSettings.self, from: data)
        #expect(back == m)
        #expect(!back.isLegacyFormat)
    }

    @Test func oldClientsAreSpotted() throws {
        // What an app from before monitoring lists sends: renewd refuses it.
        let old = #"{"enabled":true,"watchLists":[],"listRules":{},"customDomains":[],"flagExplicitTerms":true,"customTerms":[]}"#
        #expect(try Wire.decoder.decode(MonitorSettings.self, from: Data(old.utf8)).isLegacyFormat)
        #expect(!(try Wire.decoder.decode(MonitorSettings.self, from: Data(#"{"enabled":true}"#.utf8))).isLegacyFormat)
    }

    @Test func longOldListNamesAreShortenedNotDropped() throws {
        let long = String(repeating: "g", count: 70)
        let json = #"{"watchLists":["\#(long)"],"listRules":{"\#(long)":["play.example"]}}"#
        let m = try Wire.decoder.decode(MonitorSettings.self, from: Data(json.utf8)).normalized()
        #expect(m.lists == [String(repeating: "g", count: MonitorSettings.maxListNameLength): ["play.example"]])
    }

    @Test func limitsAreErrorsNotSilentCuts() {
        #expect(MonitorSettings(lists: ["a": ["a.example"]]).limitError == nil)
        let tooMany = Dictionary(uniqueKeysWithValues: (0...MonitorSettings.maxLists).map { ("l\($0)", [String]()) })
        #expect(MonitorSettings(lists: tooMany).limitError != nil)
        let many = (0..<MonitorSettings.maxListRules).map { "s\($0).example" }
        #expect(MonitorSettings(lists: ["z": many]).limitError == nil)
        #expect(MonitorSettings(lists: ["a": ["extra.example"], "z": many]).limitError != nil)
    }

    @Test func addSitesSkipsDuplicates() {
        var m = MonitorSettings(lists: ["games": ["a.example"]])
        m.addSites(["a.example", "b.example"], to: "games")
        m.addSites(["c.example"], to: "new")
        #expect(m.lists == ["games": ["a.example", "b.example"], "new": ["c.example"]])
    }
}

@Suite("Activity setting")
struct ActivitySettingTests {
    @Test func takesVisitsFromBeforeItWentOff() {
        let off = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ActivitySettings(enabled: true).accepts(visitStartingAt: off))
        #expect(!ActivitySettings.off.accepts(visitStartingAt: off))
        let wentOff = ActivitySettings(enabled: false, offSince: off)
        #expect(wentOff.accepts(visitStartingAt: off.addingTimeInterval(-30)))
        #expect(!wentOff.accepts(visitStartingAt: off.addingTimeInterval(30)))
    }

    @Test func olderDaemonsCombinedSettingStillWorks() throws {
        let json = #"{"serverTime":1800000000,"agents":[],"monitoring":{"enabled":true,"watchLists":["explicit"]}}"#
        let status = try Wire.decoder.decode(Status.self, from: Data(json.utf8))
        #expect(status.activity == nil)
        #expect(status.effectiveActivity.enabled)
        let current = Status(session: nil, serverTime: Date(), agents: [], activity: ActivitySettings(enabled: false))
        #expect(!current.effectiveActivity.enabled)
    }
}

@Suite("Monitor migration")
struct MonitorMigrationTests {
    @Test func perUserCombinedSettingsSplit() throws {
        let json = #"{"monitoringByUser":{"501":{"enabled":true,"watchLists":["explicit"],"customTerms":["gambling"]},"502":{"enabled":false,"customDomains":["a.example"]}}}"#
        var state = try Wire.decoder.decode(PersistedState.self, from: Data(json.utf8))
        // Per-user entries don't need anyone logged in.
        let migrated = state.migrateMonitoring(to: nil)
        #expect(migrated)
        #expect(state.monitoringByUser == nil)

        #expect(state.activity(for: 501).enabled)
        let m501 = state.monitor(for: 501)
        #expect(m501.enabled)
        #expect(m501.flagExplicit)
        #expect(m501.lists.isEmpty)
        #expect(m501.customTerms == ["gambling"])

        // Recording was off, so both stay off; the rules are kept.
        #expect(!state.activity(for: 502).enabled)
        #expect(!state.monitor(for: 502).enabled)
        #expect(state.monitor(for: 502).customDomains == ["a.example"])

        let again = state.migrateMonitoring(to: 501)
        #expect(!again)
    }

    @Test func newSettingsWinOverOldOnes() throws {
        let json = #"{"monitoringByUser":{"501":{"enabled":true}},"activityByUser":{"501":{"enabled":false}},"monitorByUser":{"501":{"enabled":false,"customTerms":["x"]}}}"#
        var state = try Wire.decoder.decode(PersistedState.self, from: Data(json.utf8))
        let migrated = state.migrateMonitoring(to: nil)
        #expect(migrated)
        #expect(!state.activity(for: 501).enabled)
        #expect(state.monitor(for: 501).customTerms == ["x"])
    }

    @Test func migratedStateRoundTrips() throws {
        var state = PersistedState()
        state.setActivity(ActivitySettings(enabled: true), for: 501)
        state.setMonitor(MonitorSettings(enabled: true, lists: ["games": ["play.example"]]), for: 501)
        let back = try Wire.decoder.decode(PersistedState.self, from: Wire.encoder.encode(state))
        #expect(back == state)
    }
}

@Suite("Monitor log")
struct MonitorLogTests {
    private func flag(_ e: ActivityEvent, now: Date) -> MonitorFlag {
        MonitorFlag(event: e, flags: [.domain("custom", "watched.example")], flaggedAt: now)
    }

    @Test func rangeReadPagesNewestFirstAcrossDays() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = MonitorLogStore(directory: dir)
        let now = Date()
        let day: TimeInterval = 86_400
        // Three today-ish, two four days back, one forty days back.
        let ages: [TimeInterval] = [60, 120, 180, 4 * day, 4 * day + 60, 40 * day]
        for (i, age) in ages.enumerated() {
            store.append([flag(visit("https://watched.example/\(i)", ago: age, now: now), now: now)], uid: 501, now: now)
        }
        let through = ActivityLogStore.dayKey(now)
        let all = store.read(MonitorRangeQuery(sinceDay: nil, throughDay: through, limit: 50), uid: 501)
        #expect(all.total == 6)
        #expect(all.flags.map(\.url) == (0..<6).map { "https://watched.example/\($0)" })

        // Pages stitch together with nothing lost or repeated.
        var paged: [String] = []
        for skip in stride(from: 0, to: 6, by: 4) {
            let p = store.read(MonitorRangeQuery(sinceDay: nil, throughDay: through, skip: skip, limit: 4), uid: 501)
            #expect(p.total == 6)
            paged += p.flags.map(\.url)
        }
        #expect(paged == all.flags.map(\.url))
        #expect(store.read(MonitorRangeQuery(sinceDay: nil, throughDay: through, skip: 6, limit: 4), uid: 501).flags.isEmpty)

        // A week leaves out the forty-day-old one.
        let week = store.read(MonitorRangeQuery(since: now.addingTimeInterval(-6 * day), through: now), uid: 501)
        #expect(week.total == 5)
        #expect(!week.flags.contains { $0.url.hasSuffix("/5") })

        // Other users and bad queries see nothing.
        #expect(store.read(MonitorRangeQuery(sinceDay: nil, throughDay: through), uid: 502).total == 0)
        #expect(!MonitorRangeQuery(sinceDay: "nope", throughDay: through).isValid)
        #expect(!MonitorRangeQuery(sinceDay: nil, throughDay: through, limit: MonitorRangeQuery.maxLimit + 1).isValid)
    }

    @Test func rangeTotalSkipsCorruptLinesAndFollowsAppends() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = MonitorLogStore(directory: dir)
        let now = Date()
        let a = visit("https://watched.example/a", ago: 60, now: now)
        guard ActivityLogStore.dayKey(a.start) == ActivityLogStore.dayKey(now) else { return } // midnight
        store.append([flag(a, now: now)], uid: 501, now: now)
        // A garbled line and a half-written one, as after a crash.
        let path = dir + "/501/\(ActivityLogStore.dayKey(now)).jsonl"
        let h = try #require(FileHandle(forWritingAtPath: path))
        h.seekToEndOfFile()
        h.write(Data("not json\n{\"start\":".utf8))
        try h.close()
        let q = MonitorRangeQuery(sinceDay: nil, throughDay: ActivityLogStore.dayKey(now), limit: 1)
        let first = store.read(q, uid: 501)
        #expect(first.total == 1)
        #expect(first.flags.map(\.url) == ["https://watched.example/a"])

        // Finish the half line so the next append starts clean, then add one.
        let h2 = try #require(FileHandle(forWritingAtPath: path))
        h2.seekToEndOfFile()
        h2.write(Data("\n".utf8))
        try h2.close()
        store.append([flag(visit("https://watched.example/b", ago: 30, now: now), now: now)], uid: 501, now: now)
        let second = store.read(q, uid: 501)
        #expect(second.total == 2)
        #expect(second.flags.map(\.url) == ["https://watched.example/b"])
        var older = q
        older.skip = 1
        #expect(store.read(older, uid: 501).flags.map(\.url) == ["https://watched.example/a"])
    }

    @Test func appendReadIncrementalAndPrune() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = MonitorLogStore(directory: dir)
        let now = Date()
        let a = visit("https://watched.example/a", ago: 60, now: now)
        guard ActivityLogStore.dayKey(a.start) == ActivityLogStore.dayKey(now) else { return } // midnight
        #expect(store.append([flag(a, now: now)], uid: 501, now: now) == 1)

        let page1 = store.read(MonitorQuery(date: now), uid: 501)
        #expect(page1.flags.map(\.url) == ["https://watched.example/a"])
        #expect(page1.flags.first?.eventID == a.id)
        #expect(page1.flags.first?.flags == [.domain("custom", "watched.example")])
        #expect(!page1.isIncremental)
        // Other users see nothing.
        #expect(store.read(MonitorQuery(date: now), uid: 502).flags.isEmpty)

        let b = visit("https://watched.example/b", ago: 30, now: now)
        store.append([flag(b, now: now)], uid: 501, now: now)
        let page2 = store.read(MonitorQuery(date: now, fromOffset: page1.offset), uid: 501)
        #expect(page2.isIncremental)
        #expect(page2.flags.map(\.url) == ["https://watched.example/b"])

        // Private files.
        #expect((try FileManager.default.attributesOfItem(atPath: dir + "/501")[.posixPermissions] as? Int) == 0o700)
        let file = dir + "/501/\(ActivityLogStore.dayKey(now)).jsonl"
        #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int) == 0o600)

        // Kept for a year: a 40-day-old file stays, a two-year-old one goes.
        let utc = ActivityLogStore.systemTimeZone
        let recent = dir + "/501/\(ActivityLogStore.dayKey(now.addingTimeInterval(-40 * 86_400), timeZone: utc)).jsonl"
        let old = dir + "/501/2000-01-01.jsonl"
        FileManager.default.createFile(atPath: recent, contents: Data())
        FileManager.default.createFile(atPath: old, contents: Data())
        #expect(store.prune(now: now) == 1)
        #expect(FileManager.default.fileExists(atPath: recent))
        #expect(!FileManager.default.fileExists(atPath: old))
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func enforcesQuota() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let now = Date()
        let one = flag(visit("https://watched.example/", ago: 10, now: now), now: now)
        let line = (try? Wire.encoder.encode(one).count) ?? 300
        let store = MonitorLogStore(directory: dir, maxBytesPerDay: line * 2 + 20, maxBytesPerUser: 1 << 20)
        #expect(store.append([one, one], uid: 501, now: now) == 2)
        #expect(store.append([one], uid: 501, now: now) == 0)
    }

    @Test func resentVisitsAreCheckedOnce() {
        // renewd checks only what the activity log actually stored, so a
        // batch the app sends twice is flagged once.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let activity = ActivityLogStore(directory: dir)
        let now = Date()
        let batch = [visit("https://watched.example/", ago: 20, now: now), visit("https://plain.example/", ago: 10, now: now)]
        let matcher = ActivityMatcher(settings: MonitorSettings(enabled: true, customDomains: ["watched.example"]),
                                      explicitDomains: nil)
        func flagsFor(_ events: [ActivityEvent]) -> [ActivityFlag] {
            events.flatMap { matcher.flags(url: $0.url, title: $0.title) }
        }
        let first = activity.store(batch, uid: 501, now: now).new
        #expect(first.count == 2)
        #expect(flagsFor(first) == [.domain("custom", "watched.example")])
        let again = activity.store(batch, uid: 501, now: now).new
        #expect(again.isEmpty)
        #expect(flagsFor(again).isEmpty)
    }

    @Test func shortVisitsAreCheckedButNotLogged() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = ActivityLogStore(directory: dir)
        let now = Date()
        var quick = visit("https://watched.example/", ago: 10, now: now)
        quick.end = quick.start.addingTimeInterval(0.4)
        var quickBlocked = visit("https://blocked.example/", ago: 8, now: now)
        quickBlocked.end = quickBlocked.start.addingTimeInterval(0.2)
        quickBlocked.blocked = true
        let r = store.store([quick, quickBlocked], uid: 501, now: now)
        #expect(r.new.map(\.url) == ["https://watched.example/", "https://blocked.example/"])
        #expect(r.written.map(\.url) == ["https://blocked.example/"])
        // Sent again: neither is new.
        #expect(store.store([quick], uid: 501, now: now).new.isEmpty)
    }

    @Test func visitsOverTheLogQuotaAreStillChecked() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let now = Date()
        let store = ActivityLogStore(directory: dir, maxBytesPerDay: 10, maxBytesPerUser: 1 << 20)
        let r = store.store([visit("https://watched.example/", ago: 10, now: now)], uid: 501, now: now)
        #expect(r.written.isEmpty)
        #expect(r.new.count == 1)
    }

    @Test func oldFlagsCarryOverOnce() throws {
        let activityDir = tempDir(), monitorDir = tempDir()
        defer {
            try? FileManager.default.removeItem(atPath: activityDir)
            try? FileManager.default.removeItem(atPath: monitorDir)
        }
        let now = Date()
        let start = now.addingTimeInterval(-60).timeIntervalSince1970
        let flagged = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","start":\#(start),"end":\#(start + 20),"browser":"Safari","url":"https://watched.example/","host":"watched.example","title":"W","flags":[{"kind":"domain","list":"custom","match":"watched.example"}],"blocked":false}"#
        let plain = #"{"start":\#(start),"end":\#(start + 20),"browser":"Safari","url":"https://plain.example/","host":"plain.example","title":"P","flags":[],"blocked":false}"#
        let day = ActivityLogStore.dayKey(Date(timeIntervalSince1970: start))
        try FileManager.default.createDirectory(atPath: activityDir + "/501", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: activityDir + "/501/\(day).jsonl", contents: Data((flagged + "\n" + plain + "\n").utf8))

        let store = MonitorLogStore(directory: monitorDir)
        #expect(!store.legacyFlagsImported)
        let found = MonitorLogStore.legacyFlags(inActivityDir: activityDir)
        #expect(found[501]?.map(\.url) == ["https://watched.example/"])
        #expect(store.importLegacyFlags(found, now: now) == 1)
        #expect(store.legacyFlagsImported)
        // Importing again (say it was interrupted) doesn't duplicate.
        #expect(store.importLegacyFlags(found, now: now) == 0)
        let read = store.read(MonitorQuery(day: day), uid: 501).flags
        #expect(read.map(\.flags) == [[.domain("custom", "watched.example")]])
        // The marker isn't mistaken for a user by pruning.
        #expect(store.prune(now: now) == 0)
    }
}
