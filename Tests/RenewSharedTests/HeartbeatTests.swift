import Foundation
import Testing
@testable import RenewShared

// Made-up domains only; never the real explicit list.

func tempPath(_ name: String) -> String {
    let dir = NSTemporaryDirectory() + "renew-tests-\(UUID().uuidString)"
    return dir + "/" + name
}

private let target = ReportTarget(partnerEmails: ["partner@test.invalid"],
                                  server: ReportServer(url: "https://reports.test.invalid", token: "t"))

@Suite("Heartbeats")
struct HeartbeatTests {
    @Test func encodesWhatTheServerExpects() throws {
        let install = UUID()
        let beat = Heartbeat(install: install, to: Recipients(["partner@test.invalid"]), mac: "Test Mac", user: "tester",
                             timeZone: "UTC", sentAt: Date(timeIntervalSince1970: 1_794_931_200), state: .sleeping,
                             boot: Date(timeIntervalSince1970: 1_794_902_400), lastAccepted: nil)
        let json = try JSONSerialization.jsonObject(with: Report.encoder.encode(beat)) as! [String: Any]
        #expect(json["kind"] as? String == "heartbeat")
        #expect(json["state"] as? String == "sleeping")
        #expect(json["install"] as? String == install.uuidString)
        #expect(json["boot"] as? String == "2026-11-17T08:00:00Z")
        #expect(json["sentAt"] as? String == "2026-11-17T16:00:00Z")
        #expect(json["interval"] as? Int == 900)
        #expect(json["to"] as? String == "partner@test.invalid")
        #expect(json["lastAccepted"] == nil)
        #expect(json["bootID"] as? String == ClockReading.bootID)
        let back = try Report.decoder.decode(Heartbeat.self, from: Report.encoder.encode(beat))
        #expect(back == beat)

        var several = beat
        several.to = Recipients(["a@test.invalid", "b@test.invalid"])
        let list = try JSONSerialization.jsonObject(with: Report.encoder.encode(several)) as! [String: Any]
        #expect(list["to"] as? [String] == ["a@test.invalid", "b@test.invalid"])
    }

    @Test func detailsOnlyWhenGiven() throws {
        let details = Heartbeat.Details(to: target.partnerEmails, mac: "Test Mac", user: "tester", timeZone: "UTC")
        let full = Heartbeat.make(.awake, install: UUID(), details: details, lastAccepted: nil)
        #expect(full.to == Recipients(["partner@test.invalid"]) && full.mac == "Test Mac")
        #expect(full.boot.timeIntervalSince1970 > 0 && full.boot <= Date())
        let slim = Heartbeat.make(.awake, install: UUID(), details: nil, lastAccepted: nil, gaps: [])
        let json = try JSONSerialization.jsonObject(with: Report.encoder.encode(slim)) as! [String: Any]
        for key in ["to", "mac", "user", "timeZone", "gaps"] { #expect(json[key] == nil) }
    }

    @Test func gapsAndCoverageAreSent() throws {
        let gap = DowntimeGap(from: Date(timeIntervalSince1970: 1_794_931_000), to: Date(timeIntervalSince1970: 1_794_931_240),
                              awakeSeconds: 240, restarted: false)
        let beat = Heartbeat.make(.awake, install: UUID(), details: nil, lastAccepted: nil, gaps: [gap],
                                  coveredSince: Date(timeIntervalSince1970: 1_794_902_400))
        let json = try JSONSerialization.jsonObject(with: Report.encoder.encode(beat)) as! [String: Any]
        let gaps = json["gaps"] as! [[String: Any]]
        #expect(gaps.count == 1)
        #expect(gaps[0]["awakeSeconds"] as? Int == 240)
        #expect(gaps[0]["restarted"] as? Bool == false)
        #expect(json["coveredSince"] as? String == "2026-11-17T08:00:00Z")
    }

    @Test func delayIsFifteenMinutesGiveOrTakeTwo() {
        #expect(Heartbeat.nextDelay(random: 0) == 780)
        #expect(Heartbeat.nextDelay(random: 0.5) == 900)
        #expect(Heartbeat.nextDelay(random: 1) == 1_020)
        #expect(Heartbeat.nextDelay(random: 7) == 1_020)
        for _ in 0..<200 {
            let d = Heartbeat.nextDelay()
            #expect(d >= 780 && d <= 1_020)
        }
    }

    @Test func exitIsShutdownOnlyRightAfterPowerOffNotice() {
        #expect(Heartbeat.terminationState(poweringOffAt: nil, now: 1_000) == .stopping)
        #expect(Heartbeat.terminationState(poweringOffAt: 990, now: 1_000) == .shutdown)
        #expect(Heartbeat.terminationState(poweringOffAt: 910, now: 1_000) == .shutdown)
        #expect(Heartbeat.terminationState(poweringOffAt: 900, now: 1_000) == .stopping)
        // A notice from "the future" (another boot's uptime) doesn't count.
        #expect(Heartbeat.terminationState(poweringOffAt: 2_000, now: 1_000) == .stopping)
        // A shutdown from the login window has no app to say so.
        #expect(Heartbeat.terminationState(poweringOffAt: nil, now: 1_000, nobodyLoggedIn: true) == .shutdown)
    }

    @Test func decodesServerReplyWithOrWithoutFractions() {
        let json = #"{"notices":[{"title":"Renew stopped checking in","lines":["a","b"],"at":"2026-11-17T16:00:00Z"},{"title":"x","lines":[],"at":"2026-11-17T16:00:00.250Z"}]}"#
        let reply = HeartbeatReply.decode(Data(json.utf8))
        #expect(reply?.notices.count == 2)
        #expect(reply?.notices[0].lines == ["a", "b"])
        #expect(reply?.notices[0].at == Date(timeIntervalSince1970: 1_794_931_200))
        #expect(HeartbeatReply.decode(Data("nope".utf8)) == nil)
    }
}

@Suite("Internal heartbeat")
struct AliveRecordTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    func record(boot: String = "boot-1", awake: TimeInterval = 5_000, wallOffset: TimeInterval = 0,
                exit: AliveRecord.Exit? = nil) -> AliveRecord {
        AliveRecord(bootID: boot, awake: awake, wall: start.addingTimeInterval(wallOffset),
                    coveredSince: start.addingTimeInterval(-3_600), exit: exit)
    }

    @Test func firstRunHasNoGap() {
        let (gap, covered) = AliveRecord.assess(previous: nil, bootID: "boot-1", awake: 10, wall: start)
        #expect(gap == nil)
        #expect(covered == start)
    }

    @Test func shortRestartIsNotAGap() {
        let (gap, covered) = AliveRecord.assess(previous: record(), bootID: "boot-1", awake: 5_040,
                                                wall: start.addingTimeInterval(40))
        #expect(gap == nil)
        #expect(covered == start.addingTimeInterval(-3_600))
    }

    @Test func awakeTimeWithoutRenewIsAGap() {
        let now = start.addingTimeInterval(240)
        let (gap, covered) = AliveRecord.assess(previous: record(exit: .stopping), bootID: "boot-1", awake: 5_240, wall: now)
        #expect(gap?.awakeSeconds == 240)
        #expect(gap?.from == start && gap?.to == now)
        #expect(gap?.restarted == false)
        #expect(covered == now)
    }

    @Test func sleepIsNotAGap() {
        // Eight hours on the wall clock, but the awake clock barely moved.
        let (gap, _) = AliveRecord.assess(previous: record(), bootID: "boot-1", awake: 5_030,
                                          wall: start.addingTimeInterval(8 * 3_600))
        #expect(gap == nil)
    }

    @Test func awakeTimeIsCountedEvenAcrossSleep() {
        // Stopped, slept a night, then used for 10 minutes before Renew came back.
        let (gap, _) = AliveRecord.assess(previous: record(exit: .stopping), bootID: "boot-1", awake: 5_600,
                                          wall: start.addingTimeInterval(9 * 3_600))
        #expect(gap?.awakeSeconds == 600)
    }

    @Test func cleanShutdownThenRestartIsFine() {
        let (gap, covered) = AliveRecord.assess(previous: record(exit: .shutdown), bootID: "boot-2", awake: 30,
                                                wall: start.addingTimeInterval(3_600))
        #expect(gap == nil)
        #expect(covered == start.addingTimeInterval(-3_600))
    }

    @Test func stoppedThenRestartedIsAGapOfUnknownLength() {
        let now = start.addingTimeInterval(3_600)
        let (gap, covered) = AliveRecord.assess(previous: record(exit: .stopping), bootID: "boot-2", awake: 30, wall: now)
        #expect(gap?.restarted == true)
        #expect(gap?.awakeSeconds == nil)
        #expect(covered == now)
    }

    @Test func stoppedRightBeforeARestartIsARestart() {
        // renewd stopped (no shutdown notice: the app wasn't running), and the Mac booted a minute later.
        let (gap, covered) = AliveRecord.assess(previous: record(exit: .stopping), bootID: "boot-2", awake: 30,
                                                wall: start.addingTimeInterval(120), bootedAt: start.addingTimeInterval(60))
        #expect(gap == nil)
        #expect(covered == start.addingTimeInterval(-3_600))
        // Booted long after: a gap.
        let (late, _) = AliveRecord.assess(previous: record(exit: .stopping), bootID: "boot-2", awake: 30,
                                           wall: start.addingTimeInterval(3_700), bootedAt: start.addingTimeInterval(3_600))
        #expect(late?.restarted == true)
    }

    @Test func crashThenRestartStartsCoverageAgain() {
        let now = start.addingTimeInterval(3_600)
        let (gap, covered) = AliveRecord.assess(previous: record(exit: nil), bootID: "boot-2", awake: 30, wall: now)
        #expect(gap == nil)
        #expect(covered == now)
    }

    @Test func gapStoreKeepsUntilRemoved() {
        let store = DowntimeGapStore(path: tempPath("gaps.json"))
        let a = DowntimeGap(from: start, to: start, awakeSeconds: 90, restarted: false)
        let b = DowntimeGap(from: start, to: start, awakeSeconds: nil, restarted: true)
        store.append(a)
        store.append(b)
        #expect(store.load() == [a, b])
        store.remove([a.id])
        #expect(store.load() == [b])
    }

    @Test func recordRoundTrips() {
        let file = AliveRecordFile(path: tempPath("alive.json"))
        try? FileManager.default.createDirectory(atPath: (file.path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let r = AliveRecord(bootID: "b", awake: 12, wall: Date(timeIntervalSince1970: 1_000), coveredSince: Date(timeIntervalSince1970: 900), exit: .stopping)
        file.save(r)
        #expect(file.load() == r)
    }
}

@Suite("Partner history")
struct PartnerLogTests {
    @Test func usersOnlySeeTheirOwnEmails() {
        let mine = Report(mac: "Mac", user: "alice", kind: .flags, sentAt: Date(timeIntervalSince1970: 10),
                          flags: [Report.Flag(host: "a.example", reasons: ["watched site"], start: Date(), seconds: 1)])
        let theirs = Report(mac: "Mac", user: "bob", kind: .flags, sentAt: Date(timeIntervalSince1970: 20),
                            flags: [Report.Flag(host: "b.example", reasons: ["watched site"], start: Date(), seconds: 1)])
        let waitingTheirs = Report(mac: "Mac", user: "bob", kind: .change, sentAt: Date(timeIntervalSince1970: 40), changes: ["Bob's change."])
        let alert = PartnerLogEntry(date: Date(timeIntervalSince1970: 30), channel: .alert, status: .sent, title: "Alert")
        let log: [PartnerLogEntry] = [.email(mine, status: .sent), .email(theirs, status: .sent), alert]
        let waiting = [OutboxEntry(report: waitingTheirs)]
        #expect(PartnerLogEntry.history(log: log, waiting: waiting, viewer: "alice").map(\.title) == ["Alert", "1 flagged visit"])
        #expect(PartnerLogEntry.history(log: log, waiting: waiting, viewer: "bob").map(\.title)
                == ["Bob's change.", "Alert", "1 flagged visit"])
        #expect(PartnerLogEntry.history(log: log, waiting: waiting, viewer: nil).count == 4)
    }

    @Test func loadingDoesNotCreateFiles() {
        let path = tempPath("partner-log.json")
        #expect(PartnerLog(path: path).load().isEmpty)
        let dir = (path as NSString).deletingLastPathComponent
        #expect(!FileManager.default.fileExists(atPath: dir))
    }

    @Test func keepsTheNewestEntries() {
        let log = PartnerLog(path: tempPath("partner-log.json"), maxEntries: 3)
        for i in 0..<5 {
            log.append(PartnerLogEntry(date: Date(timeIntervalSince1970: TimeInterval(i)), channel: .alert, status: .sent, title: "alert \(i)"))
        }
        #expect(log.load().map(\.title) == ["alert 2", "alert 3", "alert 4"])
        #expect(PartnerLog(path: log.path, maxEntries: 3).load().count == 3)
    }

    @Test func flagReportsListSitesNotAddresses() {
        let flags = (0..<30).map {
            Report.Flag(host: "site\($0).example", title: "Title", reasons: ["watched site"],
                        start: Date(timeIntervalSince1970: TimeInterval($0)), seconds: 5)
        }
        let report = Report(mac: "Mac", user: "u", kind: .flags, sentAt: Date(timeIntervalSince1970: 100),
                            flags: flags, omitted: 2)
        let entry = PartnerLogEntry.email(report, status: .sent)
        #expect(entry.id == report.id)
        #expect(entry.title == "32 flagged visits")
        #expect(entry.lines.first == "site0.example: watched site")
        #expect(entry.lines.count == PartnerLogEntry.maxLines + 1)
        #expect(entry.lines.last == "…and 7 more")
    }

    @Test func changeReportsUseTheirSentences() {
        let one = Report(mac: "Mac", user: "u", kind: .change, sentAt: Date(), changes: ["The Monitor was turned off."])
        #expect(PartnerLogEntry.email(one, status: .sent).title == "The Monitor was turned off.")
        #expect(PartnerLogEntry.email(one, status: .sent).lines.isEmpty)
        let two = Report(mac: "Mac", user: "u", kind: .change, sentAt: Date(), changes: ["A.", "B."])
        #expect(PartnerLogEntry.email(two, status: .sent).lines == ["A.", "B."])
    }

    @Test func historyMergesWaitingReportsNewestFirst() {
        let sent = Report(mac: "Mac", user: "u", kind: .test, sentAt: Date(timeIntervalSince1970: 10))
        let waiting = Report(mac: "Mac", user: "u", kind: .change, sentAt: Date(timeIntervalSince1970: 30), changes: ["Waiting."])
        let alert = PartnerLogEntry(date: Date(timeIntervalSince1970: 20), channel: .alert, status: .sent, title: "Alert")
        let history = PartnerLogEntry.history(
            log: [.email(sent, status: .sent), alert],
            waiting: [OutboxEntry(report: waiting), OutboxEntry(report: sent)], viewer: nil)
        #expect(history.map(\.title) == ["Waiting.", "Alert", "Test email"])
        #expect(history.map(\.status) == [.waiting, .sent, .sent])
    }
}
