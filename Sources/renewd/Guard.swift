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
        } else if let c = cached, c.activeSession != nil {
            log("state file missing during a session; restoring it")
            StateStore.save(c)
        }
        guard let state = cached, state.activeSession != nil else { return }

        let now = Date()
        let deep = now.timeIntervalSince(lastDeepCheck) >= 15
        if deep { lastDeepCheck = now }
        let restored = SelfRepair.repair(deep: deep)
        if !restored.isEmpty {
            Alerts.send(to: state.alertURL,
                        "Renew's files were deleted or changed during a focus session. Renew put them back: \(restored.joined(separator: ", ")).",
                        kind: "repair", minInterval: 600)
        }
        SelfRepair.ensureLoaded(label: Paths.daemonLabel, plist: Paths.daemonPlist)
    }

    /// `launchctl bootout`: report it if a session is running. Shares the
    /// "stopped" rate limit with renewd, so stopping both sends one alert.
    private func terminate() {
        let state = StateStore.load() ?? cached
        if let state, let s = state.activeSession {
            log("SIGTERM during a session")
            Alerts.send(to: state.alertURL,
                        "Renew's background service was stopped during a focus session (\(DurationText.format(Int(s.endsAt.timeIntervalSinceNow))) left). That's expected if the Mac is restarting or shutting down; otherwise someone stopped it.",
                        kind: "stopped", minInterval: 60, wait: true)
        }
        log("guard exiting")
        exit(0)
    }
}
