import Foundation
import RenewShared

/// Second LaunchDaemon (`renewd --guard`), loaded by renewd only while the
/// "keep Renew running" protection is on. During a session it keeps the main
/// daemon loaded, repairs files, and remembers the session so deleting
/// state.json doesn't end it.
final class Guard {
    private let queue = DispatchQueue(label: "renewd.guard")
    private var cached: PersistedState?
    private var lastDeepCheck = Date.distantPast
    private var timer: DispatchSourceTimer?
    private var termSource: DispatchSourceSignal?

    func run() {
        log("guard started")
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
        guard let state = cached, state.activeSession != nil, state.effectiveProtections.keepRunning else { return }

        let now = Date()
        let deep = now.timeIntervalSince(lastDeepCheck) >= 15
        if deep { lastDeepCheck = now }
        let restored = SelfRepair.repair(deep: deep)
        if !restored.isEmpty { log("restored during a session: \(restored.joined(separator: ", "))") }
        SelfRepair.ensureLoaded(label: Paths.daemonLabel, plist: Paths.daemonPlist)
    }

    /// `launchctl bootout`: log it if a session is running.
    private func terminate() {
        if (StateStore.load() ?? cached)?.activeSession != nil { log("SIGTERM during a session") }
        log("guard exiting")
        exit(0)
    }
}
