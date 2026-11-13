import Foundation
import RenewShared

/// The enforcer. Owns session state, answers the control socket, keeps the
/// guard and the Renew app alive, and repairs tampering. It never touches
/// the network: if the app loses permission to watch a browser, the app itself
/// closes that browser for the rest of the session.
final class Daemon {
    static let minSession = 60
    static let maxSession = 7 * 86_400
    static let maxRules = 2_000

    private let dev: Bool
    private let queue = DispatchQueue(label: "renewd.state")
    private var state = PersistedState()
    private var agents: [uid_t: AgentStatus] = [:]
    private var consoleUID: uid_t?
    private var lastDeepCheck = Date.distantPast
    private var lastAgentCheck = Date.distantPast
    private var lastKick = Date.distantPast
    private var server: SocketServer!
    private var timer: DispatchSourceTimer?

    init(dev: Bool) { self.dev = dev }

    func run() {
        queue.sync {
            state = StateStore.load() ?? PersistedState()
            if state.session != nil && state.activeSession == nil {
                endSession("expired while renewd was not running")
            }
            log("renewd started\(dev ? " (dev mode)" : ""); session: \(describe(state.activeSession))")
        }

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
        let now = Date()
        adoptDiskState()
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

            if var s = state.activeSession {
                // Starting during a session can only lengthen it and add rules.
                s.endsAt = max(s.endsAt, now.addingTimeInterval(duration))
                s.rules = merge(s.rules, valid)
                state.session = s
                log("start merged into running session by uid \(uid): ends \(s.endsAt), \(s.rules.count) rules")
            } else {
                guard !valid.isEmpty else { return fail("Nothing to block. Pass sites or --list.") }
                state.session = SessionInfo(startedAt: now, endsAt: now.addingTimeInterval(duration), rules: valid)
                if !dev { SelfRepair.refreshBackups() }
                log("session started by uid \(uid): \(Int(duration))s, rules \(valid)")
            }
            StateStore.save(state)

        case .extend:
            guard var s = state.activeSession else { return fail("No focus session is running.") }
            guard let d = req.durationSeconds, d > 0 else { return fail("Give a positive duration.") }
            let capped = min(s.endsAt.addingTimeInterval(TimeInterval(d)),
                             now.addingTimeInterval(TimeInterval(Self.maxSession)))
            s.endsAt = max(s.endsAt, capped)
            state.session = s
            StateStore.save(state)
            log("session extended by uid \(uid) to \(s.endsAt)")

        case .add:
            guard var s = state.activeSession else { return fail("No focus session is running.") }
            let (valid, rejected) = canonicalRules(req.rules ?? [])
            if !rejected.isEmpty { return fail("Invalid rule(s): \(rejected.joined(separator: ", "))") }
            s.rules = merge(s.rules, valid)
            state.session = s
            StateStore.save(state)
            log("rules added by uid \(uid): \(valid)")

        case .report:
            guard let r = req.report else { return fail("Missing report.") }
            let previous = agents[uid]
            agents[uid] = AgentStatus(uid: uid, lastSeen: now, permissionsOK: r.permissionsOK, problem: r.problem)
            if previous?.permissionsOK != r.permissionsOK || previous?.problem != r.problem {
                log("agent uid \(uid): permissionsOK=\(r.permissionsOK) \(r.problem ?? "")")
            }
        }
        return Response(ok: true, status: makeStatus(now))
    }

    private func fail(_ message: String) -> Response {
        Response(ok: false, error: message, status: makeStatus(Date()))
    }

    private func merge(_ a: [String], _ b: [String]) -> [String] {
        var out = a
        for r in b where !out.contains(r) { out.append(r) }
        return Array(out.prefix(Self.maxRules))
    }

    private func makeStatus(_ now: Date) -> Status {
        let active = state.activeSession
        return Status(
            session: active,
            serverTime: now,
            agents: agents.values.sorted { $0.uid < $1.uid }
        )
    }

    // MARK: periodic work

    private func tick() {
        let now = Date()
        adoptDiskState()
        if state.session != nil && state.activeSession == nil { endSession("session finished") }

        let active = state.activeSession
        if active != nil && !FileManager.default.fileExists(atPath: Paths.stateFile) {
            log("state file was removed; rewriting")
            StateStore.save(state)
        }
        server.ensureBound()
        updateConsole(now)

        if active != nil, !dev {
            let deep = now.timeIntervalSince(lastDeepCheck) >= 10
            if deep { lastDeepCheck = now }
            SelfRepair.repair(deep: deep)
            SelfRepair.ensureLoaded(label: Paths.guardLabel, plist: Paths.guardPlist)
            ensureAgent(now)
        }
    }

    /// Picks up a session restored on disk (e.g. by the guard after renewd was
    /// restarted with an empty state). Merging can only make things stricter:
    /// the later end time and the union of rules win, so editing the file
    /// can't shorten or loosen a running session.
    private func adoptDiskState() {
        guard var disk = StateStore.load()?.activeSession else { return }
        // Never accept more than the normal maximum from a hand-edited file.
        let cap = Date().addingTimeInterval(TimeInterval(Self.maxSession))
        if disk.endsAt > cap { disk.endsAt = cap }
        guard var mine = state.activeSession else {
            state.session = disk
            log("adopted session from state file: ends \(disk.endsAt), \(disk.rules.count) rules")
            return
        }
        let merged = merge(mine.rules, disk.rules)
        let ends = max(mine.endsAt, disk.endsAt)  // never shorter than what we already enforce
        guard merged != mine.rules || ends != mine.endsAt else { return }
        mine.rules = merged
        mine.endsAt = ends
        mine.startedAt = min(mine.startedAt, disk.startedAt)
        state.session = mine
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
        state.session = nil
        StateStore.save(state)
    }

    private func describe(_ s: SessionInfo?) -> String {
        guard let s else { return "none" }
        return "ends \(s.endsAt), \(s.rules.count) rules"
    }
}
