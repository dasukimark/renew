import Foundation
import RenewShared

/// Second LaunchDaemon (`renewd --guard`), loaded by renewd only while the
/// "keep Renew running" protection is on. During a session it keeps the main
/// daemon loaded, repairs files, and remembers the session so deleting
/// state.json doesn't end it. Whenever email reports are on, it's also the
/// second witness to renewd's internal heartbeat (see `WitnessRecord`).
// State and network completions run on queue.
final class Guard: @unchecked Sendable {
    private let queue = DispatchQueue(label: "renewd.guard")
    private let logOnly: Bool
    private var cached: PersistedState?
    private let witnessFile = WitnessFile()
    private let gaps = DowntimeGapStore()
    private struct WitnessDestination: Equatable {
        let install: UUID
        let target: ReportTarget
    }
    private var witnessDestination: WitnessDestination?
    private var hasLoadedDestination = false
    private var observedGaps: [DowntimeGap] = []
    private var sendingWitness = false
    private var retryWitnessAt: TimeInterval = 0
    private var witness: WitnessRecord?
    /// Awake-clock seconds when the witness file was last written.
    private var witnessSaved: TimeInterval = -.infinity
    private var lastDeepCheck = Date.distantPast
    private var timer: DispatchSourceTimer?
    private var termSource: DispatchSourceSignal?

    init(dev: Bool) {
        logOnly = dev && ProcessInfo.processInfo.environment["RENEW_DEV_REPORTS"] == nil
    }

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
        let destination = currentWitnessDestination()
        if destination != witnessDestination {
            if hasLoadedDestination { witness = nil }
            observedGaps.removeAll()
            retryWitnessAt = 0
            witnessDestination = destination
        }
        hasLoadedDestination = true
        watch()
        sendWitnessIfDue()
        guard let state = cached, state.activeSession != nil, state.effectiveProtections.keepRunning else { return }

        let now = Date()
        let deep = now.timeIntervalSince(lastDeepCheck) >= 15
        if deep { lastDeepCheck = now }
        let restored = SelfRepair.repair(deep: deep)
        if !restored.isEmpty { log("restored during a session: \(restored.joined(separator: ", "))") }
        SelfRepair.ensureLoaded(label: Paths.daemonLabel, plist: Paths.daemonPlist)
    }

    /// Save the gap before trying the network, so renewd can still send it.
    private func watch() {
        let awake = AliveRecord.awakeNow()
        var (record, gap) = WitnessRecord.observe(witness, daemon: AliveRecordFile().load(), reporting: cached?.reports != nil,
                                                  bootID: ClockReading.bootID, awake: awake, wall: Date())
        if let gap {
            let length = gap.awakeSeconds.map { DurationText.format($0) } ?? "an unknown time"
            log("witness: renewd's internal heartbeat stood still for \(length) of awake time (\(gap.from) to \(gap.to)\(gap.restarted ? ", then the Mac restarted" : ""))")
            let queued = gaps.append(gap)
            if !queued, gap.kind == .heartbeatStalled { record.reportedStall = nil }
            if queued, witnessDestination != nil, !observedGaps.contains(where: { $0.id == gap.id }) {
                observedGaps = Array((observedGaps + [gap]).suffix(DowntimeGapStore.maxGaps))
            }
        }
        let changed = record.seen != witness?.seen || record.bootID != witness?.bootID
            || record.reportedStall != witness?.reportedStall
        witness = record
        if changed || awake - witnessSaved >= AliveRecord.interval {
            witnessFile.save(record)
            witnessSaved = awake
        }
    }

    private func currentWitnessDestination() -> WitnessDestination? {
        guard !logOnly, let state = cached, let install = state.installID, let reports = state.reports,
              let server = reports.server(builtIn: ReportServer.builtIn()) else { return nil }
        return WitnessDestination(install: install, target: ReportTarget(partnerEmails: reports.partnerEmails, server: server))
    }

    private func sendWitnessIfDue() {
        guard !observedGaps.isEmpty, !sendingWitness, AliveRecord.awakeNow() >= retryWitnessAt,
              let destination = witnessDestination else { return }
        // A disable/re-enable may happen between guard ticks. Honor the
        // daemon's reset of the shared queue before retrying any observation.
        let queuedIDs = Set(gaps.load().map(\.id))
        observedGaps.removeAll { !queuedIDs.contains($0.id) }
        let pending = observedGaps
        guard !pending.isEmpty else { return }
        sendingWitness = true
        let beat = Heartbeat.make(.witness, install: destination.install, details: nil, lastAccepted: nil, gaps: pending)
        HeartbeatClient.post(beat, to: destination.target.server) { [weak self] outcome, reply in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.sendingWitness = false
                guard self.witnessDestination == destination else { return }
                if outcome == .delivered, reply?.needDetails != true, reply != nil {
                    let ids = Set(pending.map(\.id))
                    self.gaps.remove(ids)
                    self.observedGaps.removeAll { ids.contains($0.id) }
                } else {
                    self.retryWitnessAt = AliveRecord.awakeNow() + Heartbeat.retryDelay
                }
            }
        }
    }

    /// `launchctl bootout`: log it if a session is running.
    private func terminate() {
        if (StateStore.load() ?? cached)?.activeSession != nil { log("SIGTERM during a session") }
        log("guard exiting")
        exit(0)
    }
}
