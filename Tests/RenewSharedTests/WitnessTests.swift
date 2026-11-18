import Foundation
import Testing
@testable import RenewShared

/// 2026-11-18 03:00:00 UTC.
private let t0 = Date(timeIntervalSince1970: 1_795_489_200)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

@Suite("Power log")
struct PowerHistoryTests {
    @Test func parsesTimeStampsAndSleepWake() {
        let log = """
        PM ASL data store: /var/log/powermanagement
        Time stamp                Domain              \tMessage
        2026-11-18 07:16:35 -0500 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to rtc 22 secs
        2026-11-18 07:16:57 -0500 Sleep               \tEntering Sleep state due to 'Sleep Service Back to Sleep'
        2026-11-18 07:16:59 -0500 Wake Requests       \t[*process=dasd request=SleepService]
        2026-11-18 07:31:43 -0500 Wake                \tWake from Deep Idle [CDNVA] : due to lid
        2026-11-18 07:31:44 +0000 Assertions          \tPID 1(launchd) Created
        garbage line
        """
        let entries = PowerHistory.parse(pmsetLog: log)
        #expect(entries.map(\.event) == [.wake, .sleep, nil, .wake, nil])
        // 07:16:35 -0500 is 12:16:35 UTC.
        #expect(entries[0].date == ISO8601DateFormatter().date(from: "2026-11-18T12:16:35Z"))
        #expect(entries[4].date.timeIntervalSince(entries[3].date) == -5 * 3_600 + 1)
    }

    @Test func awakeTimeSkipsSleepAndEndsAtTheShutdown() {
        let h = PowerHistory(entries: [
            .init(date: at(-600), event: nil),
            .init(date: at(300), event: .sleep),
            .init(date: at(3_600), event: .wake), // dark wake, 20 s
            .init(date: at(3_620), event: .sleep),
            .init(date: at(7_200), event: .wake),
            .init(date: at(7_500), event: nil),
        ], shutdowns: [at(-90_000), at(8_000)])
        let r = h.awake(after: t0, before: at(9_000))
        #expect(r.shutdownAt == at(8_000))
        let seconds = r.awakeSeconds ?? -1
        #expect(abs(seconds - 1_120) < 0.001, "\(seconds)")
    }

    @Test func withoutAShutdownTheLogsLastLineIsTheEnd() {
        // Power loss: nothing after the last line.
        let h = PowerHistory(entries: [.init(date: at(-60), event: nil), .init(date: at(5), event: nil)])
        #expect(h.awake(after: t0, before: at(3_600)).awakeSeconds == 5)
        #expect(h.awake(after: t0, before: at(3_600)).shutdownAt == nil)
    }

    @Test func aLogThatDoesntReachBackSaysNothing() {
        let h = PowerHistory(entries: [.init(date: at(10), event: nil)], shutdowns: [at(900)])
        let r = h.awake(after: t0, before: at(1_000))
        #expect(r.awakeSeconds == nil)
        #expect(r.shutdownAt == at(900))
    }
}

@Suite("Restarts and the power log")
struct RestartTests {
    func unchecked(exit: AliveRecord.Exit? = nil, bootedAt: Date? = nil) -> UncheckedRestart {
        UncheckedRestart(bootID: "boot-1", awake: 5_000, wall: t0, exit: exit, restartedAt: at(7_200), bootedAt: bootedAt)
    }

    /// Covers renewd's last record and shows the Mac awake for `awake`
    /// seconds after it, then a clean shutdown (or not).
    func history(awake: TimeInterval, cleanShutdown: Bool) -> PowerHistory {
        PowerHistory(entries: [.init(date: at(-30), event: nil), .init(date: at(awake), event: nil)],
                     shutdowns: cleanShutdown ? [at(awake)] : [])
    }

    @Test func killedThenUsedThenRestartedIsAGap() {
        let outcome = AliveRecord.assessRestart(unchecked(bootedAt: at(1_900)), history: history(awake: 1_800, cleanShutdown: true))
        guard case .gap(let gap) = outcome else { Issue.record("expected a gap, got \(outcome)"); return }
        #expect(gap.awakeSeconds == 1_800)
        #expect(gap.restarted)
        #expect(gap.from == t0 && gap.to == at(7_200))
        #expect(gap.id == DowntimeGap.id(after: "boot-1", awake: 5_000))
    }

    @Test func crashOrPowerLossIsFine() {
        #expect(AliveRecord.assessRestart(unchecked(bootedAt: at(600)), history: history(awake: 8, cleanShutdown: false)) == .fine)
        // Killed at shutdown (it took too long to exit): fine too.
        #expect(AliveRecord.assessRestart(unchecked(bootedAt: at(60)), history: history(awake: 25, cleanShutdown: true)) == .fine)
    }

    @Test func stoppingIsMeasuredByThePowerLogToo() {
        #expect(AliveRecord.assessRestart(unchecked(exit: .stopping, bootedAt: at(3_600)), history: history(awake: 20, cleanShutdown: true)) == .fine)
        guard case .gap(let gap) = AliveRecord.assessRestart(unchecked(exit: .stopping, bootedAt: at(700)), history: history(awake: 600, cleanShutdown: true)) else { Issue.record("expected a gap"); return }
        #expect(gap.awakeSeconds == 600)
    }

    @Test func stoppedThenPoweredOffIsNotTakenOnTheLogsWord() {
        // renewd said it was stopping; the Mac was later forced off. The log
        // has nothing after renewd stopped, but that doesn't mean the Mac
        // wasn't used: as before, only a quick restart is fine.
        if case .gap = AliveRecord.assessRestart(unchecked(exit: .stopping, bootedAt: at(3_600)),
                                                 history: history(awake: 5, cleanShutdown: false)) {} else {
            Issue.record("expected a gap")
        }
        #expect(AliveRecord.assessRestart(unchecked(exit: .stopping, bootedAt: at(90)),
                                          history: history(awake: 5, cleanShutdown: false)) == .fine)
        // Killed with no word (a crash looks the same): what the log shows counts.
        guard case .gap(let gap) = AliveRecord.assessRestart(unchecked(bootedAt: at(3_600)),
                                                             history: history(awake: 600, cleanShutdown: false)) else {
            Issue.record("expected a gap"); return
        }
        #expect(gap.awakeSeconds == 600)
    }

    @Test func uncheckedRestartsKeepTheirOwnBootTime() {
        // Restarted again before this run was checked: the log lines from
        // the later boot's start must not count as the Mac being up.
        let u = UncheckedRestart(bootID: "boot-1", awake: 5_000, wall: t0, exit: nil, restartedAt: at(30_000), bootedAt: at(100))
        let h = PowerHistory(entries: [.init(date: at(-30), event: nil), .init(date: at(4), event: nil),
                                       .init(date: at(29_990), event: nil)])
        #expect(AliveRecord.assessRestart(u, history: h) == .fine)
    }

    @Test func withoutThePowerLog() {
        let none = PowerHistory()
        // A clean shutdown long after renewd's last record: stopped before it.
        guard case .gap(let gap) = AliveRecord.assessRestart(unchecked(bootedAt: at(1_000)), history: PowerHistory(shutdowns: [at(900)])) else { Issue.record("expected a gap"); return }
        #expect(gap.awakeSeconds == nil)
        // Nothing at all: a crash looks like this.
        #expect(AliveRecord.assessRestart(unchecked(bootedAt: at(1_000)), history: none) == .unknown)
        // Said it was stopping: the restart window decides, as before.
        #expect(AliveRecord.assessRestart(unchecked(exit: .stopping, bootedAt: at(60)), history: none) == .fine)
        if case .gap = AliveRecord.assessRestart(unchecked(exit: .stopping, bootedAt: at(3_600)), history: none) {} else {
            Issue.record("expected a gap")
        }
    }

    @Test func assessUsesThePowerLogAfterACrash() {
        let previous = AliveRecord(bootID: "boot-1", awake: 5_000, wall: t0, coveredSince: at(-3_600))
        let (gap, covered) = AliveRecord.assess(previous: previous, bootID: "boot-2", awake: 30, wall: at(7_200), bootedAt: at(7_100),
                                                history: history(awake: 1_200, cleanShutdown: true))
        #expect(gap?.awakeSeconds == 1_200)
        #expect(covered == at(7_200))
        let (none, kept) = AliveRecord.assess(previous: previous, bootID: "boot-2", awake: 30, wall: at(7_200), bootedAt: at(7_100),
                                              history: history(awake: 4, cleanShutdown: false))
        #expect(none == nil)
        #expect(kept == at(-3_600))
    }

    @Test func recordAndMarkerMustAgree() {
        let r = AliveRecord(bootID: "b", awake: 1_000, wall: t0, coveredSince: t0)
        func marker(_ awake: TimeInterval, wall: TimeInterval, boot: String = "b") -> AliveMarker {
            AliveMarker(bootID: boot, awake: awake, wall: at(wall))
        }
        #expect(AliveRecord.isConsistent(r, marker: nil))
        #expect(AliveRecord.isConsistent(nil, marker: nil))
        #expect(AliveRecord.isConsistent(r, marker: marker(700, wall: -300)))
        #expect(AliveRecord.isConsistent(r, marker: marker(1_030, wall: 30))) // written moments apart
        #expect(!AliveRecord.isConsistent(r, marker: marker(4_600, wall: 3_600))) // an old copy put back
        #expect(!AliveRecord.isConsistent(nil, marker: marker(1_000, wall: 0))) // deleted
        // The date was set back an hour after the marker: the awake clock decides.
        #expect(AliveRecord.isConsistent(r, marker: marker(990, wall: 3_590)))
        // A record from an earlier boot than the marker's.
        #expect(!AliveRecord.isConsistent(r, marker: marker(10, wall: 3_600, boot: "c")))
        #expect(AliveRecord.isConsistent(r, marker: marker(10, wall: -3_600, boot: "c")))
    }

    @Test func gapIdsDependOnlyOnTheLastRecord() {
        #expect(DowntimeGap.id(after: "b", awake: 12.5) == DowntimeGap.id(after: "b", awake: 12.5))
        #expect(DowntimeGap.id(after: "b", awake: 12.5) != DowntimeGap.id(after: "b", awake: 12.6))
        #expect(DowntimeGap.id(after: "b", awake: 12.5) != DowntimeGap.id(after: "c", awake: 12.5))
    }

    @Test func storeKeepsOneGapPerId() {
        let store = DowntimeGapStore(path: tempPath("gaps.json"))
        let id = DowntimeGap.id(after: "b", awake: 1)
        store.append(DowntimeGap(id: id, from: t0, to: at(60), awakeSeconds: 90, restarted: false))
        store.append(DowntimeGap(id: id, from: t0, to: at(62), awakeSeconds: 92, restarted: false))
        #expect(store.load().count == 1)
        #expect(store.load()[0].awakeSeconds == 90)
    }

    @Test func uncheckedRestartSurvivesTheFile() {
        let file = AliveRecordFile(path: tempPath("alive.json"))
        try? FileManager.default.createDirectory(atPath: (file.path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let r = AliveRecord(bootID: "b2", awake: 12, wall: Date(timeIntervalSince1970: 1_000), coveredSince: Date(timeIntervalSince1970: 1_000),
                            unchecked: [UncheckedRestart(bootID: "b1", awake: 99.25, wall: Date(timeIntervalSince1970: 500), exit: nil,
                                                         restartedAt: Date(timeIntervalSince1970: 1_000),
                                                         bootedAt: Date(timeIntervalSince1970: 990),
                                                         coveredSince: Date(timeIntervalSince1970: 100))])
        file.save(r)
        #expect(file.load() == r)
    }
}

@Suite("Guard as a second witness")
struct WitnessTests {
    func daemon(_ awake: TimeInterval, boot: String = "boot-1") -> AliveRecord {
        AliveRecord(bootID: boot, awake: awake, wall: at(awake), coveredSince: t0)
    }

    /// Runs the guard over renewd's records, one look per `(guardAwake, record)`.
    func watch(_ looks: [(TimeInterval, AliveRecord?)], from start: WitnessRecord? = nil, reporting: Bool = true,
               boot: String = "boot-1") -> (WitnessRecord?, [DowntimeGap]) {
        var w = start
        var gaps: [DowntimeGap] = []
        for (awake, record) in looks {
            let (next, gap) = WitnessRecord.observe(w, daemon: record, reporting: reporting, bootID: boot, awake: awake, wall: at(awake))
            w = next
            if let gap { gaps.append(gap) }
        }
        return (w, gaps)
    }

    @Test func steadyRecordsAreNoGap() {
        let looks = stride(from: 100.0, to: 400, by: 3).map { ($0, daemon(($0 / 10).rounded(.down) * 10)) }
        #expect(watch(looks).1.isEmpty)
    }

    @Test func aStandstillIsReportedWithRenewdsOwnGapId() {
        let last = daemon(100)
        let looks: [(TimeInterval, AliveRecord?)] = stride(from: 101.0, to: 500, by: 3).map { ($0, $0 == 200 ? nil : last) }
            + [(500, daemon(500))]
        let gaps = watch(looks).1
        #expect(gaps.count == 1)
        #expect(gaps[0].awakeSeconds == 400)
        #expect(gaps[0].from == last.wall && gaps[0].to == at(500))
        // renewd finds the same gap from its own record: same id, emailed once.
        let (own, _) = AliveRecord.assess(previous: last, bootID: "boot-1", awake: 500, wall: at(500))
        #expect(own?.id == gaps[0].id)
    }

    @Test func aRecordEditedToHideTheGapIsStillCaught() {
        // renewd stopped at 100; before starting it again someone wrote a
        // record that makes renewd itself see no gap.
        let forged = daemon(995)
        let looks: [(TimeInterval, AliveRecord?)] = stride(from: 101.0, to: 996, by: 3).map { ($0, daemon(100)) }
            + [(996, forged), (1_000, daemon(1_000))]
        let gaps = watch(looks).1
        #expect(gaps.count == 1 && gaps[0].awakeSeconds == 895)
        #expect(AliveRecord.assess(previous: forged, bootID: "boot-1", awake: 1_000, wall: at(1_000)).gap == nil)
    }

    @Test func nothingIsWatchedWithReportsOff() {
        let (w, gaps) = watch([(101, daemon(100)), (900, daemon(900))], reporting: false)
        #expect(gaps.isEmpty)
        #expect(w?.seen == nil)
    }

    @Test func turningReportsBackOnStartsFromAFreshRecord() {
        // Reports off from 100 to 900: renewd's record stood still, but on purpose.
        var (w, gaps) = watch([(101, daemon(100))])
        (w, gaps) = watch(stride(from: 104.0, to: 900, by: 3).map { ($0, daemon(100)) }, from: w, reporting: false)
        (w, gaps) = watch([(900, daemon(100)), (903, daemon(902)), (910, daemon(910))], from: w)
        #expect(gaps.isEmpty)
        #expect(w?.seen == daemon(910))
    }

    @Test func aMissedLookOfMoreThanTheWindowStartsAfresh() {
        // The guard was held up for 20 s while reports went off and on; renewd's
        // record jumped. That's not something the guard saw.
        let (w, _) = watch([(101, daemon(100))])
        #expect(watch([(121, daemon(115))], from: w).1.isEmpty)
        // Within the window, renewd's record standing still is still noticed.
        let looks: [(TimeInterval, AliveRecord?)] = stride(from: 104.0, to: 300, by: 12).map { ($0, daemon(100)) }
            + [(300, daemon(300))]
        #expect(watch(looks, from: w).1.count == 1)
    }

    @Test func theGuardBeingAwayIsNotRenewdsGap() {
        let (w, _) = watch([(101, daemon(100))])
        // The guard was stopped from 101 to 2 000; renewd ran fine.
        #expect(watch([(2_000, daemon(1_995)), (2_003, daemon(2_000))], from: w).1.isEmpty)
    }

    @Test func aStandstillBeforeARestartIsReportedAtTheNextBoot() {
        let (w, _) = watch(stride(from: 101.0, through: 700, by: 3).map { ($0, daemon(100)) })
        let (after, gaps) = watch([(20, daemon(15, boot: "boot-2"))], from: w, boot: "boot-2")
        #expect(gaps.count == 1)
        #expect(gaps[0].awakeSeconds == 598 && gaps[0].restarted)
        #expect(gaps[0].id == DowntimeGap.id(after: "boot-1", awake: 100))
        #expect(after?.seen == daemon(15, boot: "boot-2"))
        // renewd said the Mac was shutting down, and the guard lingered: not a gap.
        let shuttingDown = AliveRecord(bootID: "boot-1", awake: 100, wall: at(100), coveredSince: t0, exit: .shutdown)
        let (w3, _) = watch(stride(from: 101.0, through: 300, by: 3).map { ($0, shuttingDown) })
        #expect(watch([(20, nil)], from: w3, boot: "boot-2").1.isEmpty)
        // A normal shutdown: the guard and renewd stop together.
        let (w2, _) = watch([(101, daemon(100)), (104, daemon(100))])
        #expect(watch([(20, nil)], from: w2, boot: "boot-2").1.isEmpty)
    }

    @Test func witnessRoundTrips() {
        let file = WitnessFile(path: tempPath("witness.json"))
        try? FileManager.default.createDirectory(atPath: (file.path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let r = WitnessRecord(bootID: "b", awake: 3.5, wall: Date(timeIntervalSince1970: 100), seen: daemon(1.25))
        file.save(r)
        #expect(file.load()?.seen?.awake == 1.25)
        #expect(file.load()?.awake == 3.5)
    }
}

@Suite("Missed wakes")
struct MissedWakeTests {
    @Test func inputAfterTheSleepCountsAsAWake() {
        #expect(Heartbeat.inUseSinceSleep(awakeSinceSleep: 60, sleepWait: 10, idle: 2))
        // Input right before the sleep, seen during a dark wake: not a wake.
        #expect(!Heartbeat.inUseSinceSleep(awakeSinceSleep: 25, sleepWait: 10, idle: 22))
        // Still within the sleep's own wait.
        #expect(!Heartbeat.inUseSinceSleep(awakeSinceSleep: 8, sleepWait: 10, idle: 1))
        #expect(!Heartbeat.inUseSinceSleep(awakeSinceSleep: 60, sleepWait: 10, idle: nil))
    }
}
