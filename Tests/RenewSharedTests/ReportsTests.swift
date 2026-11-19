import Foundation
import Testing
@testable import RenewShared

// Made-up domains only; never the real explicit list.

private func flag(_ host: String, start: TimeInterval, length: TimeInterval = 42, _ flags: [ActivityFlag]) -> MonitorFlag {
    let s = Date(timeIntervalSince1970: start)
    let event = ActivityEvent(start: s, end: s.addingTimeInterval(length), browser: "Safari",
                              url: "https://\(host)/secret/path?q=private", host: host, title: "Private page title")
    return MonitorFlag(event: event, flags: flags, flaggedAt: s)
}

@Suite("Email reports")
struct ReportsTests {
    @Test func flagReportKeepsHostTitleReasonsAndTiming() {
        let flags = [
            flag("b.example", start: 2_000, [ActivityFlag(kind: .term, match: "casino")]),
            flag("a.example", start: 1_000, length: 9.6, [
                ActivityFlag(kind: .domain, list: "explicit", match: "a.example"),
                ActivityFlag(kind: .domain, list: "explicit", match: "a.example"),
                ActivityFlag(kind: .domain, list: "custom", match: "a.example"),
                ActivityFlag(kind: .domain, list: "games", match: "a.example"),
            ]),
        ]
        let report = Report.flags(from: flags, mac: "Test Mac", user: "tester", at: Date(timeIntervalSince1970: 3_000))
        #expect(report.kind == .flags)
        #expect(report.omitted == 0)
        #expect(report.flags == [
            Report.Flag(host: "a.example", title: "Private page title", reasons: ["explicit site", "watched site", "on list 'games'"],
                        start: Date(timeIntervalSince1970: 1_000), seconds: 10),
            Report.Flag(host: "b.example", title: "Private page title", reasons: ["word: casino"],
                        start: Date(timeIntervalSince1970: 2_000), seconds: 42),
        ])
        // The full address (path and query) never leaves the Mac.
        let json = String(decoding: try! Report.encoder.encode(report), as: UTF8.self)
        #expect(!json.contains("secret"))
        #expect(!json.contains("q=private"))
    }

    @Test func longTitlesAreShortened() {
        #expect(Report.shortened("  Short  ") == "Short")
        let long = String(repeating: "x", count: 500)
        let short = Report.shortened(long)
        #expect(short.count == Report.Flag.maxTitleLength)
        #expect(short.hasSuffix("…"))
    }

    @Test func flagReportIsCapped() {
        let many = (0..<(Report.maxFlags + 5)).map { flag("x\($0).example", start: TimeInterval($0), [ActivityFlag(kind: .term, match: "w")]) }
        let report = Report.flags(from: many, mac: "M", user: "u", at: Date())
        #expect(report.flags.count == Report.maxFlags)
        #expect(report.omitted == 5)
        #expect(report.flags.first?.host == "x0.example")
    }

    @Test func encodesTheServerFormat() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let report = Report(id: id, mac: "Test Mac", user: "tester", kind: .change,
                            sentAt: Date(timeIntervalSince1970: 0), changes: ["The Monitor was turned off."])
        let object = try JSONSerialization.jsonObject(with: Report.encoder.encode(report)) as! [String: Any]
        #expect(object["id"] as? String == id.uuidString)
        #expect(object["kind"] as? String == "change")
        #expect(object["sentAt"] as? String == "1970-01-01T00:00:00Z")
        #expect(object["changes"] as? [String] == ["The Monitor was turned off."])
        #expect((object["flags"] as? [Any])?.isEmpty == true)
        #expect(object["omitted"] as? Int == 0)
    }

    @Test func destinationNeedsHTTPSAndAToken() {
        let p = "partner@test.invalid"
        #expect(ReportDestination.normalize(partnerEmails: [" Partner@Test.Invalid "]) == ReportDestination(partnerEmails: [p]))
        #expect(ReportDestination.normalize(partnerEmails: [p], url: "  ", token: nil) == ReportDestination(partnerEmails: [p]))
        #expect(ReportDestination.normalize(partnerEmails: [p], url: " https://reports.test.invalid/ ", token: " abc123 ")
                == ReportDestination(partnerEmails: [p], url: "https://reports.test.invalid/", token: "abc123"))
        #expect(ReportDestination.normalize(partnerEmails: [p], url: "http://reports.test.invalid/", token: "abc") == nil)
        #expect(ReportDestination.normalize(partnerEmails: [p], url: "http://127.0.0.1:8080/", token: "abc") != nil)
        #expect(ReportDestination.normalize(partnerEmails: [p], url: "https://reports.test.invalid/", token: "") == nil)
        #expect(ReportDestination.normalize(partnerEmails: [p], url: "https://reports.test.invalid/", token: "has space") == nil)
        #expect(ReportDestination.normalize(partnerEmails: [p], url: "not a url", token: "abc") == nil)
        #expect(ReportDestination.normalize(partnerEmails: [""], url: "https://reports.test.invalid/", token: "abc") == nil)
    }

    @Test func builtInServerIsUsedWithoutAURL() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("renew-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("report-server.json").path
        #expect(ReportServer.builtIn(path: file) == nil)
        FileManager.default.createFile(atPath: file, contents: Data(#"{"url":"https://reports.test.invalid/","token":"t0k"}"#.utf8))
        let builtIn = try #require(ReportServer.builtIn(path: file))
        #expect(ReportDestination(partnerEmails: ["p@test.invalid"]).server(builtIn: builtIn) == builtIn)
        let own = ReportDestination(partnerEmails: ["p@test.invalid"], url: "https://other.test.invalid/", token: "x")
        #expect(own.server(builtIn: builtIn) == ReportServer(url: "https://other.test.invalid/", token: "x"))
        #expect(ReportDestination(partnerEmails: ["p@test.invalid"]).server(builtIn: nil) == nil)
        FileManager.default.createFile(atPath: file, contents: Data(#"{"url":"http://reports.test.invalid/","token":"t0k"}"#.utf8))
        #expect(ReportServer.builtIn(path: file) == nil)
    }

    @Test func severalPartners() throws {
        #expect(ReportDestination.normalizeEmails([" A@Test.Invalid ", "", "b@test.invalid", "a@test.invalid"])
                == ["a@test.invalid", "b@test.invalid"])
        #expect(ReportDestination.normalizeEmails(["a@test.invalid", "nobody"]) == nil)
        #expect(ReportDestination.normalizeEmails(["", " "]) == nil)
        #expect(ReportDestination.normalizeEmails((0...ReportDestination.maxPartners).map { "p\($0)@test.invalid" }) == nil)

        // State files and outboxes from before several partners still load.
        let oldDest = try Wire.decoder.decode(ReportDestination.self, from: Data(#"{"partnerEmail":"p@test.invalid"}"#.utf8))
        #expect(oldDest == ReportDestination(partnerEmails: ["p@test.invalid"]))
        let oldTarget = try Report.decoder.decode(ReportTarget.self,
            from: Data(#"{"partnerEmail":"p@test.invalid","server":{"url":"https://a.test.invalid/","token":"t"}}"#.utf8))
        #expect(oldTarget.partnerEmails == ["p@test.invalid"])
        let dest = ReportDestination(partnerEmails: ["a@test.invalid", "b@test.invalid"], url: "https://a.test.invalid/", token: "t")
        #expect(try Wire.decoder.decode(ReportDestination.self, from: Wire.encoder.encode(dest)) == dest)
    }

    @Test func recipientsAreAStringForOneAndAListForMore() throws {
        let server = ReportServer(url: "https://a.test.invalid/", token: "t")
        let report = Report(mac: "M", user: "u", kind: .test, sentAt: Date(timeIntervalSince1970: 0))
        func to(_ emails: [String]) throws -> Any? {
            let body = try #require(ReportClient.body(report, to: ReportTarget(partnerEmails: emails, server: server)))
            return (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["to"]
        }
        #expect(try to(["a@test.invalid"]) as? String == "a@test.invalid")
        #expect(try to(["a@test.invalid", "b@test.invalid"]) as? [String] == ["a@test.invalid", "b@test.invalid"])
    }

    @Test func partnerEmailIsChecked() {
        #expect(ReportDestination.normalizeEmail("a.b+c@mail.test.invalid") == "a.b+c@mail.test.invalid")
        for bad in ["", "nobody", "a@b", "a@@b.test", "@b.test", "a@.test", "a b@c.test", "a@b.test\nBcc: x@y.test",
                    "a@b.test, c@d.test", "<a@b.test>", "a@b.test."] {
            #expect(ReportDestination.normalizeEmail(bad) == nil, "\(bad)")
        }
    }

    private func tempOutboxPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("renew-reports-\(UUID().uuidString)/outbox.json").path
    }

    private func change(_ n: Int) -> Report {
        Report(mac: "M", user: "u", kind: .change, sentAt: Date(timeIntervalSince1970: TimeInterval(n)), changes: ["\(n)"])
    }

    @Test func outboxPersistsCapsAndRemoves() {
        let path = tempOutboxPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let outbox = ReportOutbox(path: path, maxReports: 3)
        #expect(outbox.load().isEmpty)
        let reports = (0..<4).map(change)
        for r in reports.prefix(3) { #expect(outbox.append(r) == 0) }
        #expect(outbox.append(reports[3]) == 1)
        // A fresh instance reads the same file.
        #expect(ReportOutbox(path: path).load().map(\.report.id) == reports.dropFirst().map(\.id))
        outbox.remove(reports[2].id)
        #expect(outbox.load().map(\.report.id) == [reports[1].id, reports[3].id])
        outbox.remove(UUID())
        #expect(outbox.load().count == 2)
        outbox.removeAll()
        #expect(outbox.load().isEmpty)
    }

    @Test func handOffRetargetsOnlyCurrentReports() {
        let path = tempOutboxPath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let outbox = ReportOutbox(path: path)
        let older = ReportTarget(partnerEmails: ["older@test.invalid"], server: ReportServer(url: "https://a.test.invalid/", token: "a"))
        let old = ReportTarget(partnerEmails: ["old@test.invalid", "second@test.invalid"], server: ReportServer(url: "https://b.test.invalid/", token: "b"))
        outbox.append(change(0), target: older)
        outbox.append(change(1))
        outbox.append(change(2))
        #expect(outbox.retargetCurrent(to: old) == 2)
        #expect(outbox.load().map(\.target) == [older, old, old])
        outbox.append(change(3))
        #expect(outbox.retargetCurrent(to: nil) == 1)
        #expect(outbox.load().count == 3)
    }

    @Test func unreadableOutboxIsKeptAside() throws {
        let path = tempOutboxPath()
        let dir = (path as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data("[{\"half written".utf8))
        let outbox = ReportOutbox(path: path)
        #expect(outbox.load().isEmpty)
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.contains("unreadable") }
        #expect(kept.count == 1)
        outbox.append(change(1))
        #expect(outbox.load().count == 1)
        #expect(!FileManager.default.fileExists(atPath: path + ".tmp"))
    }

    @Test func serverAnswersAreClassified() {
        #expect(ReportClient.outcome(status: 200) == .delivered)
        #expect(ReportClient.outcome(status: 401) == .refused(401))
        #expect(ReportClient.outcome(status: 403) == .refused(403))
        #expect(ReportClient.outcome(status: 400) == .rejected(400))
        #expect(ReportClient.outcome(status: 413) == .rejected(413))
        #expect(ReportClient.outcome(status: 429) == .retry)
        #expect(ReportClient.outcome(status: 502) == .retry)
        #expect(ReportClient.outcome(status: 0) == .retry)
    }

    @Test func bigReportsAreTrimmedToFit() throws {
        let title = String(repeating: "\u{1F600}字", count: 100)
        let many = (0..<Report.maxFlags).map {
            flag("x\($0).example", start: TimeInterval($0), [ActivityFlag(kind: .term, match: "w")])
        }.map { f -> MonitorFlag in var f = f; f.title = title; return f }
        // Even the worst case fits the real limit untrimmed…
        let full = Report.flags(from: many, mac: "M", user: "u", at: Date())
        #expect(try Report.encoder.encode(full).count <= Report.maxBytes)
        // …and a smaller limit trims visits from the end, counting them.
        let report = Report.flags(from: many, mac: "M", user: "u", at: Date(), maxBytes: 20_000)
        #expect(try Report.encoder.encode(report).count <= 20_000)
        #expect(report.flags.count + report.omitted == Report.maxFlags)
        #expect(report.omitted > 0)
        #expect(report.flags.first?.host == "x0.example")
    }

    @Test func longRemovalListsAreShortened() {
        let old = MonitorSettings(enabled: true, customDomains: (0..<40).map { "s\($0).example" })
        var new = old
        new.customDomains = []
        let sentence = old.loosenings(to: new).first ?? ""
        #expect(sentence.hasPrefix("Watched sites removed: s0.example, s1.example"))
        #expect(sentence.hasSuffix("and 25 more."))
    }

    @Test func loosenedMonitorRulesAreReported() {
        let old = MonitorSettings(enabled: true, watchLists: ["explicit", "games"], listRules: ["games": ["play.example"]],
                                  customDomains: ["a.example", "b.example"], flagExplicitTerms: true, customTerms: ["casino", "poker"])
        #expect(old.loosenings(to: old).isEmpty)

        var off = old
        off.enabled = false
        #expect(old.loosenings(to: off) == ["The Monitor was turned off."])

        var fewer = old
        fewer.watchLists = ["games"]
        fewer.flagExplicitTerms = false
        fewer.customDomains = ["b.example"]
        fewer.customTerms = ["poker"]
        #expect(old.loosenings(to: fewer) == [
            "Explicit sites are no longer watched.",
            "Explicit content is no longer flagged.",
            "Watched sites removed: a.example.",
            "Watched words removed: casino.",
        ])

        var noGames = old
        noGames.watchLists = ["explicit"]
        #expect(old.loosenings(to: noGames) == ["The list 'games' is no longer watched."])
    }

    @Test func tighterOrBlocklistEditsAreNotReported() {
        let old = MonitorSettings(enabled: false, watchLists: ["games"], listRules: ["games": ["play.example", "more.example"]])
        var more = old
        more.enabled = true
        more.watchLists = ["games", "explicit"]
        more.customDomains = ["c.example"]
        more.customTerms = ["dice"]
        more.flagExplicitTerms = true
        #expect(old.loosenings(to: more).isEmpty)

        var edited = old
        edited.listRules = ["games": ["play.example"]]
        #expect(old.loosenings(to: edited).isEmpty)
    }

    @Test func partnerLocksMonitoringButAllowsAdding() {
        let old = MonitorSettings(enabled: true, watchLists: ["explicit", "games"], listRules: ["games": ["play.example"]],
                                  customDomains: ["a.example"], flagExplicitTerms: true, customTerms: ["casino"])
        var off = old
        off.enabled = false
        var unwatched = old
        unwatched.watchLists = ["games"]
        var noExplicit = old
        noExplicit.flagExplicitTerms = false
        var noSite = old
        noSite.customDomains = []
        var noWord = old
        noWord.customTerms = []
        for loosened in [off, unwatched, noExplicit, noSite, noWord] {
            #expect(old.refusal(changingTo: loosened, hasPartner: true) == MonitorSettings.lockedMessage)
        }

        var more = old
        more.watchLists.append("video")
        more.customDomains.append("b.example")
        more.customTerms.append("dice")
        #expect(old.refusal(changingTo: more, hasPartner: true) == nil)

        var edited = old
        edited.listRules = ["games": []]
        #expect(old.refusal(changingTo: edited, hasPartner: true) == nil)

        // While the Monitor is off it watches nothing, so its rules can be edited.
        var paused = old
        paused.enabled = false
        var pausedFewer = paused
        pausedFewer.customTerms = []
        #expect(paused.refusal(changingTo: pausedFewer, hasPartner: true) == nil)
    }

    @Test func monitorNeedsPartnerToTurnOn() {
        let off = MonitorSettings(watchLists: ["explicit"])
        var on = off
        on.enabled = true
        #expect(off.refusal(changingTo: on, hasPartner: false) == MonitorSettings.needsPartnerMessage)
        #expect(off.refusal(changingTo: on, hasPartner: true) == nil)
        // Settings left on from before a partner was required stay editable.
        var fewer = on
        fewer.watchLists = []
        #expect(on.refusal(changingTo: off, hasPartner: false) == nil)
        #expect(on.refusal(changingTo: fewer, hasPartner: false) == nil)
    }

    @Test func activityStaysOnWhilePartnerReliesOnMonitor() {
        let on = ActivitySettings(enabled: true)
        let off = ActivitySettings.off
        let monitorOn = MonitorSettings(enabled: true)
        #expect(on.refusal(changingTo: off, monitor: monitorOn, hasPartner: true) == ActivitySettings.lockedMessage)
        #expect(on.refusal(changingTo: off, monitor: .off, hasPartner: true) == nil)
        #expect(on.refusal(changingTo: off, monitor: monitorOn, hasPartner: false) == nil)
        #expect(off.refusal(changingTo: on, monitor: monitorOn, hasPartner: true) == nil)
    }

    @Test func accountabilityPartnerIncludesRetained() {
        var state = PersistedState()
        #expect(!state.hasAccountabilityPartner)
        state.reports = ReportDestination(partnerEmails: ["a@example.com"], url: nil, token: nil)
        #expect(state.hasAccountabilityPartner)
        state.reports = nil
        state.retainedMonitoring = [ReportTarget(partnerEmails: ["b@example.com"],
                                                 server: ReportServer(url: "https://reports.example", token: "t"))]
        #expect(state.hasAccountabilityPartner)
    }

    @Test func lockedMonitorKeepsWatchedBlocklistSites() {
        let old = MonitorSettings(enabled: true, watchLists: ["games"], listRules: ["games": ["a.example", "b.example"]])
        var shrunk = old
        shrunk.listRules = ["games": ["b.example", "c.example"]]
        #expect(shrunk.keepingListRules(from: old).listRules == ["games": ["a.example", "b.example", "c.example"]])
        var deleted = old
        deleted.listRules = [:]
        #expect(deleted.keepingListRules(from: old).listRules == old.listRules)

        // While locked only added sites need sending; otherwise any change does.
        #expect(!old.listRulesNeedSync(to: deleted, locked: true))
        #expect(old.listRulesNeedSync(to: deleted, locked: false))
        #expect(old.listRulesNeedSync(to: shrunk, locked: true))
        #expect(!old.listRulesNeedSync(to: old, locked: false))
    }

    @Test func lockIsPerUsersMonitorButPartnersAreTheMacs() {
        var state = PersistedState()
        state.setMonitor(MonitorSettings(enabled: true), for: 501)
        #expect(!state.monitoringLocked(for: 501))
        state.reports = ReportDestination(partnerEmails: ["a@example.com"])
        #expect(state.monitoringLocked(for: 501))
        #expect(!state.monitoringLocked(for: 502))
    }
}
