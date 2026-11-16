import Foundation
import RenewShared

/// The enforcer. Owns session state, answers the control socket, keeps the
/// guard and the Renew app alive, and repairs tampering. If the app loses
/// permission to watch a browser, the app itself closes that browser for the
/// rest of the session. The only network traffic is the optional tamper
/// alert (see `Alerts`).
///
/// Sessions count down on the monotonic clock (see `Countdown`), so changing
/// the date doesn't end one; a large date change is reported as tampering.
final class Daemon {
    static let minSession = 60
    static let maxSession = 7 * 86_400
    static let maxRules = Schedule.maxRules

    private let dev: Bool
    private let queue = DispatchQueue(label: "renewd.state")
    private var state = PersistedState()
    private var agents: [uid_t: AgentStatus] = [:]
    private var consoleUID: uid_t?
    private var lastDeepCheck = Date.distantPast
    private var lastAgentCheck = Date.distantPast
    private var lastKick = Date.distantPast
    /// Monotonic time of the last state.json checkpoint.
    private var lastCheckpointSave: UInt64 = 0
    /// Wall clock minus the anchored clock at the last tick (see `runSchedules`).
    private var lastClockDivergence: TimeInterval = 0
    private var server: SocketServer!
    private var timer: DispatchSourceTimer?
    private var termSource: DispatchSourceSignal?

    /// Date changes smaller than this are ordinary clock corrections.
    static let clockLogThreshold: TimeInterval = 5
    static let clockAlertThreshold: TimeInterval = 120
    static let checkpointInterval: UInt64 = 30 * 1_000_000_000

    init(dev: Bool) { self.dev = dev }

    func run() {
        queue.sync {
            state = StateStore.load() ?? PersistedState()
            let r = ClockReading.now()
            let rebooted = state.sessionClock.map { $0.bootID != r.bootID } ?? false
            if state.session != nil && state.activeSession(at: r) == nil {
                endSession("expired while renewd was not running")
            }
            if state.uninstall != nil && state.uninstallStatus(at: r) == nil {
                state.uninstall = nil
                log("uninstall request expired while renewd was not running")
            }
            state.checkpoint(at: r)
            // Keep this boot's anchor across renewd restarts, so restarting
            // renewd after changing the date doesn't launder the change.
            if state.wallAnchor?.trustedWall(at: r) == nil { state.wallAnchor = WallAnchor(at: r) }
            lastClockDivergence = clockDivergence(r)
            StateStore.save(state)
            lastCheckpointSave = r.mono
            log("renewd started\(dev ? " (dev mode)" : ""); session: \(describe(state.activeSession(at: r)))")
            if rebooted, let s = state.activeSession(at: r) {
                alert("The Mac restarted during a block session. Renew is running again (\(DurationText.format(Int(s.endsAt.timeIntervalSince(r.wall)))) left).",
                      kind: "rebooted", every: 300)
            }
        }

        // launchd sends SIGTERM on `launchctl bootout` (and at shutdown).
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        term.setEventHandler { [unowned self] in self.terminate() }
        term.resume()
        termSource = term

        server = SocketServer(path: Paths.socketPath) { [unowned self] request, uid in
            self.queue.sync { self.handle(request, from: uid) }
        }
        do {
            try server.start()
        } catch {
            log("fatal: \(error)")
            exit(1) // launchd restarts us
        }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2.0)
        t.setEventHandler { [unowned self] in self.tick() }
        t.resume()
        timer = t
    }

    // MARK: requests

    private func handle(_ req: Request, from uid: uid_t) -> Response {
        let r = ClockReading.now()
        let now = r.wall
        adoptDiskState(r)
        switch req.cmd {
        case .status:
            break

        case .start:
            guard let d = req.durationSeconds, d >= Self.minSession else {
                return fail("Duration must be at least 1 minute.")
            }
            let duration = TimeInterval(min(d, Self.maxSession))
            let (valid, rejected) = canonicalRules(req.rules ?? [])
            if !rejected.isEmpty { return fail("Invalid rule(s): \(rejected.joined(separator: ", "))") }

            if state.activeSession(at: r) == nil, valid.isEmpty {
                return fail("Nothing to block. Pass sites or --list.")
            }
            startOrMerge(until: now.addingTimeInterval(duration), rules: valid, at: r, by: "uid \(uid)")

        case .extend:
            guard var s = state.activeSession(at: r) else { return fail("No block session is running.") }
            guard let d = req.durationSeconds, d > 0 else { return fail("Give a positive duration.") }
            let capped = min(s.endsAt.addingTimeInterval(TimeInterval(d)),
                             now.addingTimeInterval(TimeInterval(Self.maxSession)))
            s.endsAt = max(s.endsAt, capped)
            state.setSession(s, at: r)
            StateStore.save(state)
            log("session extended by uid \(uid) to \(s.endsAt)")

        case .add:
            guard var s = state.activeSession(at: r) else { return fail("No block session is running.") }
            let (valid, rejected) = canonicalRules(req.rules ?? [])
            if !rejected.isEmpty { return fail("Invalid rule(s): \(rejected.joined(separator: ", "))") }
            s.rules = merge(s.rules, valid)
            state.setSession(s, at: r)
            StateStore.save(state)
            log("rules added by uid \(uid): \(valid)")

        case .report:
            guard let r = req.report else { return fail("Missing report.") }
            let previous = agents[uid]
            agents[uid] = AgentStatus(uid: uid, lastSeen: now, permissionsOK: r.permissionsOK, problem: r.problem)
            if previous?.permissionsOK != r.permissionsOK || previous?.problem != r.problem {
                log("agent uid \(uid): permissionsOK=\(r.permissionsOK) \(r.problem ?? "")")
            }

        case .setAlerts:
            if let error = setAlerts(req.alertURL, by: uid, at: r) { return fail(error) }

        case .testAlert:
            guard let url = state.alertURL else { return fail("Alerts are off. Set a destination first.") }
            Alerts.send(to: url, "Test alert from Renew. If you're reading this, alerts work.")

        case .requestUninstall:
            if let u = state.uninstallStatus(at: r) {
                log("uninstall already requested; unlocks \(u.unlocksAt)")
            } else {
                let total = UninstallPolicy.delay + UninstallPolicy.window
                // Whole seconds, so the date survives the JSON round trip unchanged.
                let requestedAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded())
                state.uninstall = UninstallRequest(requestedAt: requestedAt, countdown: Countdown(remaining: total, at: r))
                StateStore.save(state)
                let unlocks = now.addingTimeInterval(UninstallPolicy.delay)
                log("uninstall requested by uid \(uid); unlocks \(unlocks)")
                alert("Someone asked to uninstall Renew. It can be removed after \(Self.dateText(unlocks)), if no block session is running then.")
            }

        case .setSchedules:
            if let error = setSchedules(req.schedules ?? [], by: uid) { return fail(error) }

        case .cancelUninstall:
            if state.uninstall != nil {
                state.uninstall = nil
                StateStore.save(state)
                log("uninstall request cancelled by uid \(uid)")
                alert("The request to uninstall Renew was cancelled.")
            }
        }
        return Response(ok: true, status: makeStatus(now, r))
    }

    /// Starts a session that ends at `end`, or folds into the running one.
    /// Only ever makes things stricter: the later end and the union of rules
    /// win. Returns whether anything changed.
    @discardableResult
    private func startOrMerge(until end: Date, rules: [String], at r: ClockReading, by who: String) -> Bool {
        let now = r.wall
        let end = min(end, now.addingTimeInterval(TimeInterval(Self.maxSession)))
        if var s = state.activeSession(at: r) {
            let merged = merge(s.rules, rules)
            // Under a second of difference is rounding, not a longer session.
            let ends = end.timeIntervalSince(s.endsAt) >= 1 ? end : s.endsAt
            guard merged != s.rules || ends != s.endsAt else { return false }
            s.rules = merged
            s.endsAt = ends
            state.setSession(s, at: r)
            log("start merged into running session by \(who): ends \(s.endsAt), \(s.rules.count) rules")
        } else {
            guard !rules.isEmpty, end > now else { return false }
            state.setSession(SessionInfo(startedAt: now, endsAt: end, rules: Array(rules.prefix(Self.maxRules))), at: r)
            if !dev { SelfRepair.refreshBackups() }
            log("session started by \(who): \(Int(end.timeIntervalSince(now)))s, rules \(rules)")
        }
        StateStore.save(state)
        return true
    }

    static let maxSchedules = 50

    /// Replaces the schedules. Allowed at any time: a schedule only starts
    /// sessions, so removing one never ends or loosens a running session.
    private func setSchedules(_ raw: [Schedule], by uid: uid_t) -> String? {
        guard raw.count <= Self.maxSchedules else { return "At most \(Self.maxSchedules) scheduled block sessions." }
        var clean: [Schedule] = []
        var ids = Set<UUID>()
        for raw in raw {
            let s = raw.normalized()
            let label = s.name.isEmpty ? "A scheduled block session" : "“\(s.name)”"
            guard ids.insert(s.id).inserted else { return "\(label) is listed twice." }
            guard s.days.isValid else { return "\(label) needs at least one day." }
            guard s.window.isValid else { return "\(label) needs different start and end times." }
            let rejected = canonicalRules(raw.rules).rejected
            if !rejected.isEmpty { return "Invalid rule(s) in \(label): \(rejected.joined(separator: ", "))" }
            guard !s.rules.isEmpty else { return "\(label) has nothing to block." }
            clean.append(s)
        }
        let new: [Schedule]? = clean.isEmpty ? nil : clean
        guard new != state.schedules else { return nil }
        state.schedules = new
        StateStore.save(state)
        log("schedules set by uid \(uid): \(clean.map { "\($0.name) [\($0.summary())]" })")
        return nil
    }

    /// Starts (or lengthens) a session for every schedule whose window is
    /// open now. Idempotent, so it runs on every tick.
    ///
    /// Windows are checked against both the wall clock and the anchored
    /// clock (wall time carried forward on the monotonic clock since boot),
    /// so moving the date before a window opens doesn't skip it: whichever
    /// says a window is open wins.
    private func runSchedules(_ r: ClockReading) {
        let divergence = clockDivergence(r)
        defer { lastClockDivergence = divergence }
        guard let schedules = state.schedules else { return }

        let jump = divergence - lastClockDivergence
        if abs(jump) >= Self.clockAlertThreshold, state.activeSession(at: r) == nil {
            // During a session `checkpoint` already reports this.
            let direction = jump > 0 ? "forward" : "back"
            log("clock moved \(Int(jump))s with schedules set; schedules follow the real time")
            alert("The Mac's clock was set \(direction) by \(DurationText.format(Int(abs(jump)))). Scheduled block sessions still start at the real time.",
                  kind: "clock", every: 600)
        }

        var times = [r.wall]
        // Small differences are ordinary clock drift and corrections.
        if abs(divergence) >= Self.clockAlertThreshold / 2 { times.append(r.wall.addingTimeInterval(-divergence)) }
        for s in schedules {
            for t in times {
                // A few seconds of slack keeps a just-finished session (monotonic
                // clock) from restarting for the last instant of the window.
                guard let end = s.activeWindowEnd(at: t) else { continue }
                let left = end.timeIntervalSince(t)
                guard left > 5 else { continue }
                startOrMerge(until: r.wall.addingTimeInterval(left), rules: s.rules, at: r, by: "schedule “\(s.name)”")
            }
        }
    }

    /// How far the wall clock is from the anchored clock (0 if unknown).
    private func clockDivergence(_ r: ClockReading) -> TimeInterval {
        if state.wallAnchor?.trustedWall(at: r) == nil {
            state.wallAnchor = WallAnchor(at: r)
            StateStore.save(state)
        }
        guard let trusted = state.wallAnchor?.trustedWall(at: r) else { return 0 }
        return r.wall.timeIntervalSince(trusted)
    }

    /// Alerts can be turned on at any time, but changed or turned off only
    /// between sessions, and the old destination hears about it.
    private func setAlerts(_ raw: String?, by uid: uid_t, at r: ClockReading) -> String? {
        let new: String?
        if let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let url = Alerts.normalize(raw) else { return "That isn't a valid http(s) URL." }
            new = url
        } else {
            new = nil
        }
        let old = state.alertURL
        guard new != old else { return nil }
        if old != nil, state.activeSession(at: r) != nil {
            return "Alerts can't be changed or turned off during a block session."
        }
        if let old {
            alert(new == nil ? "Alerts from Renew were turned off. This is the last message you'll get here."
                             : "Alerts from Renew were moved to a different destination. This is the last message you'll get here.",
                  to: old)
        }
        state.alertURL = new
        StateStore.save(state)
        log("alerts \(new == nil ? "turned off" : "set to \(new!)") by uid \(uid)")
        if new != nil {
            alert("Renew alerts are on. You'll hear here if Renew is stopped, its files are tampered with, or the clock is changed during a block session, and before it can be uninstalled.")
        }
        return nil
    }

    private func alert(_ message: String, to url: String? = nil, kind: String? = nil, every: TimeInterval = 0, wait: Bool = false) {
        guard !dev || ProcessInfo.processInfo.environment["RENEW_DEV_ALERTS"] != nil else {
            log("(dev) alert: \(message)")
            return
        }
        Alerts.send(to: url ?? state.alertURL, message, kind: kind, minInterval: every, wait: wait)
    }

    static func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    /// `launchctl bootout` (or shutdown): save the countdown and report it if
    /// a session is running, then exit.
    private func terminate() {
        let r = ClockReading.now()
        state.checkpoint(at: r)
        StateStore.save(state)
        if let s = state.activeSession(at: r) {
            log("SIGTERM during a session")
            alert("Renew's background service was stopped during a block session (\(DurationText.format(Int(s.endsAt.timeIntervalSince(r.wall)))) left). That's expected if the Mac is restarting or shutting down; otherwise someone stopped it.",
                  kind: "stopped", every: 60, wait: true)
        }
        log("renewd exiting")
        exit(0)
    }

    private func fail(_ message: String) -> Response {
        Response(ok: false, error: message, status: makeStatus(Date()))
    }


    private func merge(_ a: [String], _ b: [String]) -> [String] {
        var out = a
        for r in b where !out.contains(r) { out.append(r) }
        return Array(out.prefix(Self.maxRules))
    }

    private func makeStatus(_ now: Date, _ r: ClockReading = .now()) -> Status {
        Status(
            session: state.activeSession(at: r),
            serverTime: now,
            agents: agents.values.sorted { $0.uid < $1.uid },
            alertURL: state.alertURL,
            uninstall: state.uninstallStatus(at: r),
            schedules: state.schedules
        )
    }

    // MARK: periodic work

    private func tick() {
        let r = ClockReading.now()
        let now = r.wall
        adoptDiskState(r)
        if state.session != nil && state.activeSession(at: r) == nil { endSession("session finished") }
        if state.uninstall != nil && state.uninstallStatus(at: r) == nil {
            state.uninstall = nil
            StateStore.save(state)
            log("uninstall request expired")
        }
        runSchedules(r)

        checkpoint(r)

        let active = state.activeSession(at: r)
        if (active != nil || state.alertURL != nil || state.uninstall != nil || state.schedules != nil)
            && !FileManager.default.fileExists(atPath: Paths.stateFile) {
            log("state file was removed; rewriting")
            StateStore.save(state)
            if active != nil { alert("Renew's session file was deleted during a block session. Renew restored it.", kind: "state-deleted", every: 600) }
        }
        server.ensureBound()
        updateConsole(now)

        if active != nil, !dev {
            let deep = now.timeIntervalSince(lastDeepCheck) >= 10
            if deep { lastDeepCheck = now }
            let restored = SelfRepair.repair(deep: deep)
            if !restored.isEmpty {
                alert("Renew's files were deleted or changed during a block session. Renew put them back: \(restored.joined(separator: ", ")).",
                      kind: "repair", every: 600)
            }
            SelfRepair.ensureLoaded(label: Paths.guardLabel, plist: Paths.guardPlist)
            ensureAgent(now)
        }
    }

    /// Re-anchors the countdowns. A date change shows up here as the session's
    /// wall-clock end moving; the time left is unaffected.
    private func checkpoint(_ r: ClockReading) {
        guard state.session != nil || state.uninstall != nil else { return }
        let shift = state.checkpoint(at: r)
        if abs(shift) >= Self.clockLogThreshold {
            StateStore.save(state)
            lastCheckpointSave = r.mono
            log("clock moved \(Int(shift))s during a session; session end unaffected (now \(describe(state.activeSession(at: r))))")
            if abs(shift) >= Self.clockAlertThreshold {
                let direction = shift > 0 ? "forward" : "back"
                alert("The Mac's clock was set \(direction) by \(DurationText.format(Int(abs(shift)))) during a block session. The session still ends on time.",
                      kind: "clock", every: 600)
            }
        } else if r.mono &- lastCheckpointSave >= Self.checkpointInterval {
            StateStore.save(state)
            lastCheckpointSave = r.mono
        }
    }

    /// Picks up a session restored on disk (e.g. by the guard after renewd was
    /// restarted with an empty state). Merging can only make things stricter:
    /// the later end time and the union of rules win, so editing the file
    /// can't shorten or loosen a running session.
    ///
    /// renewd owns the alert destination, the uninstall request and the
    /// schedules: if the
    /// file disagrees (edited or deleted), renewd's copy is written back.
    private func adoptDiskState(_ r: ClockReading) {
        guard let file = StateStore.load() else { return }
        if file.alertURL != state.alertURL || file.uninstall?.requestedAt != state.uninstall?.requestedAt
            || file.schedules != state.schedules || file.wallAnchor != state.wallAnchor {
            log("state file disagrees about alerts/uninstall/schedules; rewriting")
            StateStore.save(state)
        }
        guard var disk = file.activeSession(at: r) else { return }
        // Never accept more than the normal maximum from a hand-edited file.
        let cap = r.wall.addingTimeInterval(TimeInterval(Self.maxSession))
        if disk.endsAt > cap { disk.endsAt = cap }
        guard var mine = state.activeSession(at: r) else {
            state.setSession(disk, at: r)
            log("adopted session from state file: ends \(disk.endsAt), \(disk.rules.count) rules")
            return
        }
        let merged = merge(mine.rules, disk.rules)
        // Never shorter than what we already enforce. Under a second of
        // difference is rounding, not a longer session.
        let ends = disk.endsAt.timeIntervalSince(mine.endsAt) >= 1 ? disk.endsAt : mine.endsAt
        guard merged != mine.rules || ends != mine.endsAt else { return }
        mine.rules = merged
        mine.endsAt = ends
        mine.startedAt = min(mine.startedAt, disk.startedAt)
        state.setSession(mine, at: r)
        StateStore.save(state)
        log("merged session from state file: ends \(ends), \(merged.count) rules")
    }

    private func updateConsole(_ now: Date) {
        consoleUID = consoleUser()?.uid
    }

    private func ensureAgent(_ now: Date) {
        guard let uid = consoleUID, now.timeIntervalSince(lastAgentCheck) >= 4 else { return }
        lastAgentCheck = now
        let target = "gui/\(uid)/\(Paths.agentLabel)"
        if !Launchctl.isLoaded(target) {
            let r = Launchctl.bootstrap(domain: "gui/\(uid)", plist: Paths.agentPlist)
            log("agent for uid \(uid) was not loaded; bootstrap: \(r.ok ? "ok" : r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else if let a = agents[uid], now.timeIntervalSince(a.lastSeen) > 30, now.timeIntervalSince(lastKick) > 30 {
            lastKick = now
            log("agent for uid \(uid) silent for \(Int(now.timeIntervalSince(a.lastSeen)))s; restarting it")
            Launchctl.kickstart(target)
        }
    }

    private func endSession(_ why: String) {
        log("session ended (\(why))")
        state.setSession(nil)
        StateStore.save(state)
    }

    private func describe(_ s: SessionInfo?) -> String {
        guard let s else { return "none" }
        return "ends \(s.endsAt), \(s.rules.count) rules"
    }
}
