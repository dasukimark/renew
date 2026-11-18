import Foundation
import RenewShared

/// renewd's internal heartbeat (see `AliveRecord`): writes "still running"
/// every `AliveRecord.interval`, and at start works out whether the Mac was
/// in use while renewd wasn't running. Such downtime is kept in
/// `DowntimeGapStore` for the next check-in.
///
/// - The record is written from its own queue and timer, so slow work on
///   renewd's state queue doesn't look like downtime: the record standing
///   still means the process wasn't running (or was frozen, e.g. SIGSTOP),
///   which renewd notices itself when it runs again.
/// - After a restart renewd wasn't told about, the power log decides (see
///   `AliveRecord.assessRestart`). It's read in the background; until then
///   the old runs stay in the record (`unchecked`), so renewd or the Mac
///   restarting meanwhile doesn't lose them.
/// - Every few minutes renewd notes in state.json that it's running
///   (`marker`). A record that's missing, unreadable or older than that was
///   deleted or put back, and is reported as such.
///
/// Only runs while email reports are on; there's no one to tell otherwise,
/// so nothing is written. `start`, `resume`, `reportsOff`, `tick` and
/// `exit` are called on renewd's state queue; the rest is under `lock`.
/// `@unchecked Sendable`: shared state is behind `lock`.
final class AliveTracker: @unchecked Sendable {
    private let file = AliveRecordFile()
    private let gaps: DowntimeGapStore
    private let beatQueue = DispatchQueue(label: "renewd.alive")
    private var timer: DispatchSourceTimer?
    private let reporting: () -> Bool
    /// Reads and sets `PersistedState.aliveMarker` (saving the state).
    private let marker: () -> AliveMarker?
    private let setMarker: (AliveMarker?) -> Void
    /// Awake-clock seconds when the marker was last moved on (state queue).
    private var lastMarker: TimeInterval = -.infinity

    private let lock = NSLock()
    // Under `lock`:
    private var _coveredSince = Date()
    /// Whether records are being written (reports are on).
    private var active = false
    private var exited = false
    /// Awake-clock seconds and wall time of the last record written.
    private var lastWrite: TimeInterval = -.infinity
    private var lastWriteWall = Date()
    private var unchecked: [UncheckedRestart] = []

    /// How often the marker in state.json is moved on.
    static let markerInterval: TimeInterval = 300

    var coveredSince: Date { locked { _coveredSince } }

    init(gaps: DowntimeGapStore, reporting: @escaping () -> Bool,
         marker: @escaping () -> AliveMarker?, setMarker: @escaping (AliveMarker?) -> Void) {
        self.gaps = gaps
        self.reporting = reporting
        self.marker = marker
        self.setMarker = setMarker
    }

    /// Reads the last record and keeps any downtime it shows, then starts
    /// writing.
    func start() {
        startTimer()
        guard reporting() else { return }
        let previous = file.load()
        let currentMarker = marker()
        let now = Date()
        let bootID = ClockReading.bootID
        let toCheck: [UncheckedRestart] = locked {
            _coveredSince = now
            if let m = currentMarker, !AliveRecord.isConsistent(previous, marker: m) {
                // Nothing in the record can be trusted: report from the last
                // time renewd is known to have been running.
                keep(DowntimeGap(from: min(m.wall, previous?.wall ?? m.wall), to: now,
                                 awakeSeconds: nil, restarted: previous.map { $0.bootID != bootID } ?? false,
                                 kind: .recordsMissing),
                     why: previous == nil ? "record missing or unreadable" : "record older than state.json says")
            } else {
                // Runs still waiting from earlier restarts carry on.
                unchecked = previous?.unchecked ?? []
                if let p = previous, p.bootID != bootID, p.exit != .shutdown {
                    unchecked.append(UncheckedRestart(p, restartedAt: now, bootedAt: Heartbeat.bootTime()))
                } else {
                    let (gap, covered) = AliveRecord.assess(previous: previous, bootID: bootID,
                                                            awake: AliveRecord.awakeNow(), wall: now)
                    _coveredSince = covered
                    if let gap { keep(gap) }
                }
                unchecked = Array(unchecked.suffix(AliveRecord.maxUnchecked))
            }
            active = true
            write(exit: nil)
            return unchecked
        }
        noteRunning()
        if !toCheck.isEmpty { checkRestarts(toCheck, coverageFrom: locked { _coveredSince }) }
    }

    /// Reports were just turned on: coverage starts now.
    func resume() {
        locked {
            _coveredSince = Date()
            unchecked = []
            active = true
            write(exit: nil)
        }
        noteRunning()
    }

    /// Reports were turned off: stop writing.
    func reportsOff() {
        locked { active = false }
    }

    /// renewd's regular tick (state queue): moves the marker on.
    func tick() {
        guard reporting(), locked({ active }) else { return }
        if AliveRecord.awakeNow() - lastMarker >= Self.markerInterval { noteRunning() }
    }

    /// renewd is exiting cleanly.
    func exit(_ how: AliveRecord.Exit) {
        locked {
            guard active else { return }
            exited = true
            write(exit: how)
        }
    }

    // MARK: -

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: beatQueue)
        t.schedule(deadline: .now() + 2, repeating: 2.0, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.beat() }
        t.resume()
        timer = t
    }

    /// Writes the record when due (`beatQueue`). This timer runs whenever
    /// the process does, so the last write being far behind means renewd
    /// was frozen.
    private func beat() {
        locked {
            guard active, !exited else { return }
            let now = AliveRecord.awakeNow()
            if lastWrite.isFinite, now - lastWrite > AliveRecord.tolerance {
                let last = AliveRecord(bootID: ClockReading.bootID, awake: lastWrite, wall: lastWriteWall, coveredSince: _coveredSince)
                _coveredSince = Date()
                keep(DowntimeGap(after: last, to: _coveredSince, awakeSeconds: now - lastWrite, restarted: false), why: "renewd was frozen")
            }
            if now - lastWrite >= AliveRecord.interval { write(exit: nil) }
        }
    }

    private func keep(_ gap: DowntimeGap, why: String? = nil) {
        let awake = gap.awakeSeconds.map { DurationText.format($0) } ?? "unknown"
        log("internal heartbeat: renewd wasn't running from \(gap.from) to \(gap.to) (Mac awake for \(awake)\(gap.restarted ? ", restarted in between" : "")\(why.map { "; \($0)" } ?? ""))")
        gaps.append(gap)
    }

    /// Reads the power log in the background, then decides about each run
    /// from before a restart. If renewd turns out to have run until every
    /// one of those restarts, the old coverage is kept (unless something
    /// since started it again).
    private func checkRestarts(_ list: [UncheckedRestart], coverageFrom started: Date) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let history = PowerHistory.read()
            let outcomes = list.map { ($0, AliveRecord.assessRestart($0, history: history)) }
            guard let self else { return }
            self.locked {
                self.unchecked.removeAll { list.contains($0) }
                // Reports were turned off meanwhile: no one to tell.
                guard self.active else { return }
                for (u, outcome) in outcomes {
                    switch outcome {
                    case .gap(let gap): self.keep(gap, why: "from the power log")
                    case .fine: log("internal heartbeat: renewd ran until the Mac went down before \(u.restartedAt) (power log)")
                    case .unknown: log("internal heartbeat: renewd stopped before a restart without a clean exit; the power log doesn't say more (a crash or power loss)")
                    }
                }
                if outcomes.allSatisfy({ $0.1 == .fine }), let oldest = list.first?.coveredSince, self._coveredSince == started {
                    self._coveredSince = oldest
                }
                if !self.exited { self.write(exit: nil) }
            }
        }
    }

    /// State queue only.
    private func noteRunning() {
        lastMarker = AliveRecord.awakeNow()
        // Whole seconds, so it survives the JSON round trip unchanged (or
        // renewd would think state.json was edited).
        setMarker(AliveMarker(bootID: ClockReading.bootID, awake: lastMarker.rounded(.down),
                              wall: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))))
    }

    /// Under `lock`.
    private func write(exit: AliveRecord.Exit?) {
        let awake = AliveRecord.awakeNow()
        lastWrite = awake
        lastWriteWall = Date()
        file.save(AliveRecord(bootID: ClockReading.bootID, awake: awake, wall: lastWriteWall, coveredSince: _coveredSince,
                              exit: exit, unchecked: unchecked.isEmpty ? nil : unchecked))
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
