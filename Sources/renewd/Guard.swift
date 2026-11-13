import Foundation
import RenewShared

/// Second LaunchDaemon (`renewd --guard`). During a session it keeps the main
/// daemon loaded, repairs files, and remembers the session so deleting
/// state.json doesn't end it.
final class Guard {
    private let queue = DispatchQueue(label: "renewd.guard")
    private var cached: PersistedState?
    private var lastDeepCheck = Date.distantPast
    private var timer: DispatchSourceTimer?

    func run() {
        log("guard started")
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Offset from the daemon's 2 s cadence so they rarely repair at once.
        t.schedule(deadline: .now() + 1, repeating: 3.0)
        t.setEventHandler { [unowned self] in self.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        if let s = StateStore.load() {
            cached = s
        } else if let c = cached, c.activeSession != nil {
            log("state file missing during a session; restoring it")
            StateStore.save(c)
        }
        guard cached?.activeSession != nil else { return }

        let now = Date()
        let deep = now.timeIntervalSince(lastDeepCheck) >= 15
        if deep { lastDeepCheck = now }
        SelfRepair.repair(deep: deep)
        SelfRepair.ensureLoaded(label: Paths.daemonLabel, plist: Paths.daemonPlist)
    }
}
