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
    @Test func matcherUsesCopiedListRules() {
        let settings = MonitorSettings(enabled: true, watchLists: ["games"], listRules: ["games": ["play.example"]])
        let m = ActivityMatcher(settings: settings, explicitDomains: nil)
        #expect(m.flags(url: "https://www.play.example/x", title: "") == [.domain("games", "play.example")])
        #expect(m.flags(url: "https://work.example/", title: "").isEmpty)
        // A watched list without a copy of its rules flags nothing.
        let bare = ActivityMatcher(settings: MonitorSettings(enabled: true, watchLists: ["games"]), explicitDomains: nil)
        #expect(bare.isEmpty)
    }

    @Test func explicitPresetNeedsItsList() {
        let settings = MonitorSettings(enabled: true, watchLists: ["explicit"])
        let m = ActivityMatcher(settings: settings, explicitDomains: DomainSet(["adult.example"]))
        #expect(m.flags(url: "https://cdn.adult.example/", title: "") == [.domain("explicit", "adult.example")])
        #expect(ActivityMatcher(settings: settings, explicitDomains: nil).isEmpty)
    }

    @Test func withListRulesCopiesOnlyWatchedLists() {
        let lists = ["games": ["play.example"], "news": ["news.example"]]
        let m = MonitorSettings(enabled: true, watchLists: ["Games", "explicit", "gone"]).withListRules(from: lists)
        #expect(m.listRules == ["games": ["play.example"]])
    }

    @Test func normalizeKeepsRulesForWatchedListsAndCaps() {
        let many = (0..<(MonitorSettings.maxListRules + 10)).map { "s\($0).example" }
        let m = MonitorSettings(enabled: true, watchLists: ["big", "small"],
                                listRules: ["big": many, "small": ["a.example", " a.example ", ""], "unwatched": ["b.example"]])
            .normalized()
        #expect(m.listRules["unwatched"] == nil)
        #expect(m.listRules["big"]?.count == MonitorSettings.maxListRules)
        // The cap is across all lists, so the second one gets nothing left.
        #expect(m.listRules["small"] == nil)
        let small = MonitorSettings(watchLists: ["small"], listRules: ["small": ["a.example", " a.example ", ""]]).normalized()
        #expect(small.listRules == ["small": ["a.example"]])
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
        #expect(m501.watchLists == ["explicit"])
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
        state.setMonitor(MonitorSettings(enabled: true, watchLists: ["games"], listRules: ["games": ["play.example"]]), for: 501)
        let back = try Wire.decoder.decode(PersistedState.self, from: Wire.encoder.encode(state))
        #expect(back == state)
    }
}

@Suite("Monitor log")
struct MonitorLogTests {
    private func flag(_ e: ActivityEvent, now: Date) -> MonitorFlag {
        MonitorFlag(event: e, flags: [.domain("custom", "watched.example")], flaggedAt: now)
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
