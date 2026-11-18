import Foundation
import RenewShared

/// Second LaunchDaemon (`renewd --guard`), loaded by renewd only while the
/// "keep Renew running" protection is on. During a session it keeps the main
/// daemon loaded, repairs files, and remembers the session so deleting
/// state.json doesn't end it. Whenever email reports are on, it's also the
/// second witness to renewd's internal heartbeat (see `WitnessRecord`).
final class Guard {
    private let queue = DispatchQueue(label: "renewd.guard")
    private var cached: PersistedState?
    private let witnessFile = WitnessFile()
    private let gaps = DowntimeGapStore()
    private var witness: WitnessRecord?
    /// Awake-clock seconds when the witness file was last written.
    private var witnessSaved: TimeInterval = -.infinity
    private var lastDeepCheck = Date.distantPast
    private var timer: DispatchSourceTimer?
    private var termSource: DispatchSourceSignal?

    func run() {
        log("guard started")
        witness = witnessFile.load()
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Offset from the daemon's 2 s cadence so they rarely repair at once.
        t.schedule(deadline: .now() + 1, repeating: 3.0)
        t.setEventHandler { [unowned self] in self.tick() }
        t.resume()
        timer = t

        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        term.setEventHandler { [unowned self] in self.terminate() }
        term.resume()
        termSource = term
    }

    private func tick() {
        if let s = StateStore.load() {
            cached = s
        } else if let c = cached, c.activeSession != nil, c.effectiveProtections.keepRunning {
            log("state file missing during a session; restoring it")
            StateStore.save(c)
        }
        watch()
        guard let state = cached, state.activeSession != nil, state.effectiveProtections.keepRunning else { return }

        let now = Date()
        let deep = now.timeIntervalSince(lastDeepCheck) >= 15
        if deep { lastDeepCheck = now }
        let restored = SelfRepair.repair(deep: deep)
        if !restored.isEmpty { log("restored during a session: \(restored.joined(separator: ", "))") }
        SelfRepair.ensureLoaded(label: Paths.daemonLabel, plist: Paths.daemonPlist)
    }

    /// One look at renewd's internal heartbeat. A gap goes straight into the
    /// gaps renewd sends with its next check-in.
    private func watch() {
        let awake = AliveRecord.awakeNow()
        let (record, gap) = WitnessRecord.observe(witness, daemon: AliveRecordFile().load(), reporting: cached?.reports != nil,
                                                  bootID: ClockReading.bootID, awake: awake, wall: Date())
        if let gap {
            let length = gap.awakeSeconds.map { DurationText.format($0) } ?? "an unknown time"
            log("witness: renewd's internal heartbeat stood still for \(length) of awake time (\(gap.from) to \(gap.to)\(gap.restarted ? ", then the Mac restarted" : ""))")
            gaps.append(gap)
        }
        let changed = record.seen != witness?.seen || record.bootID != witness?.bootID
        witness = record
        if changed || awake - witnessSaved >= AliveRecord.interval {
            witnessFile.save(record)
            witnessSaved = awake
        }
    }

    /// `launchctl bootout`: log it if a session is running.
    private func terminate() {
        if (StateStore.load() ?? cached)?.activeSession != nil { log("SIGTERM during a session") }
        log("guard exiting")
        exit(0)
    }
}
