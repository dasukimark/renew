import Foundation
import RenewShared

/// The enforcer. Owns session state and answers the control socket. With the
/// "keep Renew running" protection on, it also runs the guard, keeps the Renew
/// app alive and repairs tampering during sessions. If the app loses
/// permission to watch a browser, the app itself closes that browser for the
/// rest of the session. The only network traffic is the optional email
/// reports and check-ins (see `Reporter`, `Heartbeater`).
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
    private var lastGuardCheck = Date.distantPast
    /// Whether the countdown to turning off the cooling-off is in step with
    /// the file, give or take checkpoint rounding.
    private func sameCoolingOffRemoval(_ file: PersistedState, _ r: ClockReading) -> Bool {
        switch (file.coolingOffRemoval, state.coolingOffRemoval) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.remaining(at: r) - b.remaining(at: r)) < 2
        default: return false
        }
    }
    /// Monotonic time of the last state.json checkpoint.
    private var lastCheckpointSave: UInt64 = 0
    /// Wall clock minus the anchored clock at the last tick (see `runSchedules`).
    private var lastClockDivergence: TimeInterval = 0
    private var server: SocketServer!
    private var timer: DispatchSourceTimer?
    private var termSource: DispatchSourceSignal?
    /// The per-user activity log (see `ActivityLogStore`).
    private let activityLog = ActivityLogStore(directory: Paths.activityDir)
    /// The Monitor's flags, per user (see `MonitorLogStore`).
    private let monitorLog = MonitorLogStore(directory: Paths.monitorDir)
    private lazy var monitorEngine: MonitorEngine = {
        let engine = MonitorEngine(dev: dev, queue: queue)
        engine.deliver = { [weak self] uid, flags in
            guard let self else { return }
            self.monitorLog.append(flags, uid: uid)
            self.reporter.add(flags: flags, uid: uid)
        }
        return engine
    }()
    private lazy var reporter = Reporter(queue: queue, dev: dev) { [unowned self] in self.target(self.state.reports) }
    private lazy var heartbeater: Heartbeater = {
        let h = Heartbeater(queue: queue, dev: dev,
                            destination: { [unowned self] in self.target(self.state.reports) },
                            installID: { [unowned self] in self.ensureInstallID() },
                            userName: { consoleUser()?.name ?? "" })
        h.coveredSince = { [unowned self] in self.alive.coveredSince }
        h.onNotices = { [unowned self] notices in
            self.reporter.partnerLog.append(notices.map {
                PartnerLogEntry(date: $0.at, channel: .checkin, status: .sent, title: $0.title, lines: $0.lines)
            })
        }
        return h
    }()

    /// The internal heartbeat (see `AliveRecord`).
    private lazy var alive = AliveTracker(
        gaps: heartbeater.gaps,
        reporting: { [unowned self] in self.state.reports != nil },
        marker: { [unowned self] in self.state.aliveMarker },
        setMarker: { [unowned self] date in
            guard self.state.aliveMarker != date else { return }
            self.state.aliveMarker = date
            StateStore.save(self.state)
        })

    /// This install's id, made and saved the first time it's needed.
    private func ensureInstallID() -> UUID {
        if let id = state.installID { return id }
        let id = UUID()
        state.installID = id
        StateStore.save(state)
        return id
    }
    /// The built-in report server, read again only when its file changes
    /// (it's replaced at install).
    private var builtInServerCache: (stamp: [Int], server: ReportServer?)?

    /// `d` with its server resolved: its own, or the built-in one.
    private func target(_ d: ReportDestination?) -> ReportTarget? {
        guard let d, let server = d.server(builtIn: builtInServer()) else { return nil }
        return ReportTarget(partnerEmails: d.partnerEmails, server: server)
    }

    private func builtInServer() -> ReportServer? {
        var st = stat()
        let stamp = stat(Paths.reportServerFile, &st) == 0
            ? [Int(st.st_mtimespec.tv_sec), Int(st.st_mtimespec.tv_nsec), Int(st.st_size), Int(st.st_ino)] : []
        if let c = builtInServerCache, c.stamp == stamp { return c.server }
        let server = stamp.isEmpty ? nil : ReportServer.builtIn()
        builtInServerCache = (stamp, server)
        return server
    }
    private var lastActivityPrune = Date.distantPast
    /// The uid of the request being handled, so replies carry that user's
    /// Activity and Monitor settings.
    private var requestUID: uid_t?

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
            if state.applyDueCoolingOffRemoval(at: r) {
                log("uninstall cooling-off turned off (its wait ended while renewd was not running)")
                notify("Renew's uninstall cooling-off is now off. Renew can be uninstalled without waiting, between block sessions.")
            }
            state.checkpoint(at: r)
            if state.migrateMonitoring(to: consoleUser()?.uid) {
                log("split the activity monitoring settings into Activity and Monitor settings")
            }
            monitorEngine.prepare(watchingExplicit: (state.monitorByUser ?? [:]).values.contains {
                $0.enabled && $0.watchLists.contains(MonitorSettings.explicitListName)
            })
            importLegacyFlags()
            // Keep this boot's anchor across renewd restarts, so restarting
            // renewd after changing the date doesn't launder the change.
            if state.wallAnchor?.trustedWall(at: r) == nil { state.wallAnchor = WallAnchor(at: r) }
            lastClockDivergence = clockDivergence(r)
            _ = ensureInstallID()
            StateStore.save(state)
            lastCheckpointSave = r.mono
            log("renewd started\(dev ? " (dev mode)" : ""); session: \(describe(state.activeSession(at: r)))")
            syncGuard()
            alive.start()
            heartbeater.startPowerNotifications()
            if rebooted, state.activeSession(at: r) != nil {
                log("the Mac restarted during a block session")
            }
        }

        // launchd sends SIGTERM on `launchctl bootout` (and at shutdown).
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        term.setEventHandler { [unowned self] in self.terminate() }
        term.resume()
        termSource = term

        server = SocketServer(path: Paths.socketPath) { [unowned self] request, uid, token in
            self.queue.sync { self.handle(request, from: uid, token: token) }
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

    private func handle(_ req: Request, from uid: uid_t, token: Data? = nil) -> Response {
        let r = ClockReading.now()
        let now = r.wall
        requestUID = uid
        defer { requestUID = nil }
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

        case .setReports:
            if let error = setReports(req.reports, by: uid, at: r) { return fail(error) }

        case .testReport:
            guard state.reports != nil else { return fail("Email reports are off. Set them up first.") }
            guard reporter.sendTest(uid: uid) else {
                return fail("No report server is set up on this Mac, so nothing was sent. Run server/reports/configure-mac.sh and reinstall Renew.")
            }

        case .requestUninstall:
            if let u = state.uninstallStatus(at: r) {
                log("uninstall already requested; unlocks \(u.unlocksAt)")
            } else if !state.effectiveProtections.uninstallCoolingOff {
                // No cooling-off: nothing to request. `renew uninstall` goes ahead.
                log("uninstall request by uid \(uid) ignored: the cooling-off is off")
            } else {
                let total = UninstallPolicy.delay + UninstallPolicy.window
                // Whole seconds, so the date survives the JSON round trip unchanged.
                let requestedAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded())
                state.uninstall = UninstallRequest(requestedAt: requestedAt, countdown: Countdown(remaining: total, at: r))
                StateStore.save(state)
                let unlocks = now.addingTimeInterval(UninstallPolicy.delay)
                log("uninstall requested by uid \(uid); unlocks \(unlocks)")
                reporter.add(changes: ["Someone asked to uninstall Renew. It can be removed after \(Self.dateText(unlocks)), if no block session is running then."], uid: uid)
            }

        case .setSchedules:
            if let error = setSchedules(req.schedules ?? [], by: uid) { return fail(error) }

        case .setProtections:
            guard let p = req.protections else { return fail("Missing protections.") }
            if let error = setProtections(p, by: uid, at: r) { return fail(error) }

        case .setActivity:
            guard let a = req.activity else { return fail("Missing Activity setting.") }
            setActivity(a, by: uid)

        case .setMonitor:
            guard let m = req.monitor else { return fail("Missing Monitor settings.") }
            setMonitor(m, by: uid)

        case .setMonitorListRules:
            guard let rules = req.monitor?.listRules else { return fail("Missing list rules.") }
            var m = state.monitor(for: uid)
            m.listRules = rules
            setMonitor(m, by: uid)

        case .recordActivity:
            let events = req.events ?? []
            guard events.count <= ActivityLogStore.maxEventsPerRequest else {
                return fail("At most \(ActivityLogStore.maxEventsPerRequest) visits per request.")
            }
            // Visits that started before Activity was turned off still count:
            // the app hears about the change a moment later, and may hold
            // visits from while renewd was unreachable.
            let activity = state.activity(for: uid)
            let accepted = events.filter { activity.accepts(visitStartingAt: $0.start) }
            let result = activityLog.store(accepted, uid: uid, now: now)
            // The Monitor checks each new visit once (even ones too short to
            // log, or over the log's quota); flags are never rewritten when
            // its rules change.
            let flags = monitorEngine.evaluate(result.new, settings: state.monitor(for: uid), uid: uid, now: now)
            if !flags.isEmpty {
                monitorLog.append(flags, uid: uid, now: now)
                reporter.add(flags: flags, uid: uid)
            }

        case .activity:
            guard let q = req.activityQuery, ActivityLogStore.date(ofDay: q.day) != nil else {
                return fail("Give a day as YYYY-MM-DD.")
            }
            return Response(ok: true, status: makeStatus(now, r), activity: activityLog.read(q, uid: uid))

        case .activityStats:
            guard let q = req.statsQuery, let stats = activityLog.summaries(q, uid: uid) else {
                return fail("Give a range of at most \(ActivityStatsQuery.maxDays) days, YYYY-MM-DD to YYYY-MM-DD.")
            }
            return Response(ok: true, status: makeStatus(now, r), stats: stats)

        case .monitorFlags:
            guard let q = req.monitorQuery, ActivityLogStore.date(ofDay: q.day) != nil else {
                return fail("Give a day as YYYY-MM-DD.")
            }
            return Response(ok: true, status: makeStatus(now, r), flags: monitorLog.read(q, uid: uid))


        case .poweringOff:
            // Only the Renew app may say this, or a script could make
            // stopping renewd look like a shutdown.
            guard dev || PeerCheck.isRenewApp(token, appPath: Paths.agentApp) else {
                log("ignored a 'powering off' notice from uid \(uid): not from the Renew app")
                return fail("Only the Renew app can send this.")
            }
            heartbeater.notePoweringOff()

        case .partnerHistory:
            // Each user sees only emails about themselves (and the Mac-wide
            // check-ins), like their own Monitor flags.
            let history = PartnerLogEntry.history(log: reporter.partnerLog.load(), waiting: reporter.waiting(),
                                                  viewer: uid == 0 ? nil : Reporter.userName(uid))
            return Response(ok: true, status: makeStatus(now, r), partnerHistory: history)

        case .cancelUninstall:
            if state.uninstall != nil {
                state.uninstall = nil
                StateStore.save(state)
                log("uninstall request cancelled by uid \(uid)")
                reporter.add(changes: ["The request to uninstall Renew was cancelled."], uid: uid)
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
            log("clock moved \(Int(jump))s with schedules set; schedules follow the real time")
            notify("The Mac's clock was set \(jump > 0 ? "forward" : "back") by \(DurationText.format(Int(abs(jump)))). Scheduled block sessions still start at the real time.",
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

    /// Protections can be turned on at any time, but off only between
    /// sessions; the cooling-off turns off a day after it's asked to.
    private func setProtections(_ requested: Protections, by uid: uid_t, at r: ClockReading) -> String? {
        let change: ProtectionChange
        switch state.setProtections(requested, sessionActive: state.activeSession(at: r) != nil, at: r) {
        case .failure(let refusal): return refusal.message
        case .success(let c): change = c
        }
        guard !change.isEmpty else { return nil }
        StateStore.save(state)
        syncGuard()
        if !change.turnedOn.isEmpty { log("protections turned on by uid \(uid): \(change.turnedOn.joined(separator: ", "))") }
        if !change.turnedOff.isEmpty {
            log("protections turned off by uid \(uid): \(change.turnedOff.joined(separator: ", "))")
            reporter.add(changes: ["Renew protections were turned off: \(change.turnedOff.joined(separator: ", "))."], uid: uid)
        }
        if change.coolingOffRemovalRequested, let when = state.coolingOffRemovalDate(at: r) {
            log("uid \(uid) asked to turn off the uninstall cooling-off; it turns off \(when)")
            reporter.add(changes: ["Someone asked to turn off Renew's uninstall cooling-off. It turns off after \(Self.dateText(when)); after that Renew can be uninstalled without waiting."], uid: uid)
        }
        if change.coolingOffRemovalCancelled {
            log("uid \(uid) cancelled turning off the uninstall cooling-off")
            reporter.add(changes: ["The request to turn off Renew's uninstall cooling-off was cancelled."], uid: uid)
        }
        return nil
    }

    /// Each user changes only their own settings, at any time.
    private func setActivity(_ requested: ActivitySettings, by uid: uid_t) {
        let old = state.activity(for: uid)
        guard requested.enabled != old.enabled else { return }
        // renewd keeps the time it went off itself; a client's value is ignored.
        let new = ActivitySettings(enabled: requested.enabled, offSince: requested.enabled ? nil : Date())
        state.setActivity(new, for: uid)
        StateStore.save(state)
        log("Activity recording turned \(new.enabled ? "on" : "off") by uid \(uid)")
        if !new.enabled { reporter.add(changes: ["Activity recording was turned off, so nothing is checked by the Monitor."], uid: uid) }
    }

    /// Copies flags the app saved inside visits before the Monitor had its
    /// own log into the Monitor's log, once. The reading happens off the
    /// state queue.
    private func importLegacyFlags() {
        guard !monitorLog.legacyFlagsImported else { return }
        let activityDir = activityLog.directory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = MonitorLogStore.legacyFlags(inActivityDir: activityDir)
            self?.queue.async {
                guard let self else { return }
                let n = self.monitorLog.importLegacyFlags(found)
                log("monitor: carried over \(n) flagged visit(s) from the activity log")
            }
        }
    }

    /// Each user changes only their own settings, at any time. With email
    /// reports on, the partner is told when the Monitor is turned off or
    /// watches less (see `MonitorSettings.loosenings`).
    private func setMonitor(_ requested: MonitorSettings, by uid: uid_t) {
        let new = requested.normalized()
        let old = state.monitor(for: uid)
        guard new != old else { return }
        state.setMonitor(new, for: uid)
        monitorEngine.invalidate(uid)
        StateStore.save(state)
        if old.enabled != new.enabled {
            log("Monitor turned \(new.enabled ? "on" : "off") by uid \(uid)")
        }
        if old.watchLists != new.watchLists || old.listRules != new.listRules || old.customDomains != new.customDomains
            || old.flagExplicitTerms != new.flagExplicitTerms || old.customTerms != new.customTerms {
            let rules = new.listRules.values.reduce(0) { $0 + $1.count }
            log("Monitor rules changed by uid \(uid): lists \(new.watchLists) (\(rules) rules), \(new.customDomains.count) sites, explicit words \(new.flagExplicitTerms ? "on" : "off"), \(new.customTerms.count) words")
        }
        reporter.add(changes: old.loosenings(to: new), uid: uid)
    }

    /// Turned on, or partners added, at any time; partners removed, the
    /// server changed or reports turned off only between sessions. Partners
    /// who stop getting reports are told, and get what was still waiting.
    /// The same custom `url` without a token keeps the current token.
    private func setReports(_ raw: ReportDestination?, by uid: uid_t, at r: ClockReading) -> String? {
        let new: ReportDestination?
        let given = raw?.partnerEmails.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? []
        if let raw, !given.isEmpty {
            if let bad = given.first(where: { ReportDestination.normalizeEmail($0) == nil }) {
                return "\"\(bad)\" doesn't look like an email address."
            }
            guard ReportDestination.normalizeEmails(given) != nil else {
                return "Email reports can go to at most \(ReportDestination.maxPartners) people."
            }
            let current = state.reports
            let token = raw.token ?? (raw.url != nil && raw.url == current?.url ? current?.token : nil)
            guard let d = ReportDestination.normalize(partnerEmails: given, url: raw.url, token: token) else {
                return "Give the report server's https URL and its token (no spaces)."
            }
            if d.usesBuiltInServer, builtInServer() == nil {
                return "No report server is set up on this Mac. Run server/reports/configure-mac.sh and reinstall Renew (see server/reports/README.md)."
            }
            new = d
        } else {
            new = nil
        }
        let old = state.reports
        guard new != old else { return nil }
        if let old, state.activeSession(at: r) != nil {
            // Adding partners only makes things stricter.
            let onlyAdds = new.map { $0.url == old.url && $0.token == old.token && Set(old.partnerEmails).isSubset(of: $0.partnerEmails) } ?? false
            if !onlyAdds {
                return "Partners can be added during a block session, but not removed, and reports can't be turned off."
            }
        }
        let oldTarget = target(old)
        let partnersChanged = old != nil && new != nil && Set(old!.partnerEmails) != Set(new!.partnerEmails)
        if let old {
            if new == nil {
                reporter.handOff(from: oldTarget, farewell: "Email reports from Renew were turned off. This is the last report you'll get from this Mac.", uid: uid)
            } else if new!.url != old.url || new!.token != old.token {
                reporter.handOff(from: oldTarget, farewell: "Email reports from Renew were moved to a different report server. This is the last report you'll get through this one.", uid: uid)
            } else if partnersChanged {
                // What's waiting stays with the partners it was meant for:
                // new partners don't get visits from before they were added.
                let removed = old.partnerEmails.filter { !new!.partnerEmails.contains($0) }
                reporter.handOff(from: oldTarget,
                                 farewell: removed.isEmpty ? nil : "Email reports from Renew no longer go to you. This is the last report you'll get from this Mac.",
                                 to: oldTarget.map { ReportTarget(partnerEmails: removed, server: $0.server) },
                                 uid: uid)
            }
        }
        // Downtime from before reports were on isn't the new partner's business.
        if old == nil { heartbeater.gaps.removeAll() }
        state.reports = new
        if new == nil {
            state.aliveMarker = nil
            alive.reportsOff()
        }
        StateStore.save(state)
        if old == nil, new != nil { alive.resume() }
        log("email reports \(new == nil ? "turned off" : "set to \(new!.partnerEmails.joined(separator: ", ")) via \(new!.url ?? "the built-in server")") by uid \(uid)")
        if let new, partnersChanged {
            reporter.add(changes: ["Email reports from Renew now go to: \(new.partnerEmails.joined(separator: ", "))."], uid: uid)
        } else if new != nil {
            reporter.add(changes: ["Email reports from Renew are on. You'll get an email when the Monitor flags a visit, and when Activity or the Monitor is turned off or watches less. Renew also checks in with the report server regularly. If it isn't running for more than a minute while the Mac is awake, you'll be emailed when it runs again; if it stops checking in for 2 hours while the Mac is awake, you'll be emailed then."], uid: uid)
        }
        // Moving server or turning off: tell the old destination to stop
        // expecting check-ins, then check in with the new one. On the same
        // server, the next check-in just carries the new partners, so the
        // server keeps this Mac's history (an unanswered "quiet" alert,
        // reported downtime).
        let sameServer = old != nil && new != nil && old!.url == new!.url && old!.token == new!.token
        heartbeater.handOff(from: old != nil && !sameServer ? oldTarget : nil)
        return nil
    }

    /// Uptime when each kind of notice was last sent, for `notify`'s rate limit.
    private var lastNotice: [String: TimeInterval] = [:]

    /// Emails the partners about something no user asked for (tampering,
    /// a wait ending), as the console user. `kind` and `every` keep a burst
    /// of the same thing to one email.
    private func notify(_ message: String, kind: String? = nil, every: TimeInterval = 0) {
        let now = ProcessInfo.processInfo.systemUptime
        if let kind, every > 0 {
            if let last = lastNotice[kind], now - last < every { return }
            lastNotice[kind] = now
        }
        reporter.add(changes: [message], uid: consoleUID ?? consoleUser()?.uid ?? 0)
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
        reporter.flushBatches()
        let exitState = heartbeater.exitState()
        alive.exit(exitState == .shutdown ? .shutdown : .stopping)
        heartbeater.sendExit(exitState)
        if state.activeSession(at: r) != nil { log("SIGTERM during a session") }
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
            uninstall: state.uninstallStatus(at: r),
            schedules: state.schedules,
            protections: state.effectiveProtections,
            coolingOffRemovalAt: state.coolingOffRemovalDate(at: r),
            activity: requestUID.map { state.activity(for: $0) } ?? .off,
            monitor: requestUID.map { state.monitor(for: $0) } ?? .off,
            reportsURL: state.reports?.url,
            reportsPartners: state.reports?.partnerEmails,
            reportServerBuiltIn: builtInServer() != nil
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
        if state.applyDueCoolingOffRemoval(at: r) {
            StateStore.save(state)
            log("uninstall cooling-off turned off (its wait is over)")
            notify("Renew's uninstall cooling-off is now off. Renew can be uninstalled without waiting, between block sessions.")
        }
        runSchedules(r)
        reporter.tick()
        alive.tick()
        heartbeater.tick()

        checkpoint(r)

        let active = state.activeSession(at: r)
        if (active != nil || state.reports != nil || state.uninstall != nil || state.schedules != nil
            || state.protections != nil || state.coolingOffRemoval != nil
            || state.activityByUser != nil || state.monitorByUser != nil)
            && !FileManager.default.fileExists(atPath: Paths.stateFile) {
            log("state file was removed; rewriting")
            StateStore.save(state)
            if active != nil { notify("Renew's session file was deleted during a block session. Renew restored it.", kind: "state-deleted", every: 600) }
        }
        server.ensureBound()
        updateConsole(now)
        // No one was logged in at startup: move old monitoring settings once someone is.
        if state.monitoring != nil, state.migrateMonitoring(to: consoleUID) {
            StateStore.save(state)
            log("moved the old activity monitoring settings to the console user")
        }
        if now.timeIntervalSince(lastActivityPrune) >= 3_600 {
            lastActivityPrune = now
            let removed = activityLog.prune(now: now)
            if removed > 0 { log("activity log: deleted \(removed) day file(s) older than \(ActivityLogStore.retentionDays) days") }
            let flagsRemoved = monitorLog.prune(now: now)
            if flagsRemoved > 0 { log("monitor log: deleted \(flagsRemoved) day file(s) older than \(MonitorLogStore.retentionDays) days") }
        }

        // The rest is the optional "keep Renew running" protection.
        if active != nil, !dev, state.effectiveProtections.keepRunning {
            let deep = now.timeIntervalSince(lastDeepCheck) >= 10
            if deep { lastDeepCheck = now }
            let restored = SelfRepair.repair(deep: deep)
            if !restored.isEmpty {
                log("restored during a session: \(restored.joined(separator: ", "))")
                notify("Renew's files were deleted or changed during a block session. Renew put them back: \(restored.joined(separator: ", ")).",
                       kind: "repair", every: 600)
            }
            ensureAgent(now)
        }
        // Bring the guard back if it was stopped: quickly during a session,
        // where it also keeps renewd running; otherwise it's still the
        // second witness to renewd's internal heartbeat (see `WitnessRecord`).
        if state.effectiveProtections.keepRunning, now.timeIntervalSince(lastGuardCheck) >= (active != nil ? 10 : 60) {
            syncGuard()
        }
    }

    /// The guard runs only while "keep Renew running" is on: renewd loads it
    /// at startup and when that's turned on, and stops it when it's turned off.
    private func syncGuard() {
        guard !dev else { return }
        lastGuardCheck = Date()
        if state.effectiveProtections.keepRunning {
            SelfRepair.ensureLoaded(label: Paths.guardLabel, plist: Paths.guardPlist)
        } else if Launchctl.isLoaded("system/\(Paths.guardLabel)") {
            let r = Launchctl.bootout("system/\(Paths.guardLabel)")
            log("stopped the guard (keep Renew running is off): \(r.ok ? "ok" : r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Re-anchors the countdowns. A date change shows up here as the session's
    /// wall-clock end moving; the time left is unaffected.
    private func checkpoint(_ r: ClockReading) {
        guard state.session != nil || state.uninstall != nil || state.coolingOffRemoval != nil else { return }
        let shift = state.checkpoint(at: r)
        if abs(shift) >= Self.clockLogThreshold {
            StateStore.save(state)
            lastCheckpointSave = r.mono
            log("clock moved \(Int(shift))s during a session; session end unaffected (now \(describe(state.activeSession(at: r))))")
            if abs(shift) >= Self.clockAlertThreshold {
                notify("The Mac's clock was set \(shift > 0 ? "forward" : "back") by \(DurationText.format(Int(abs(shift)))) during a block session. The session still ends on time.",
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
    /// renewd owns the report destination, the uninstall request, the
    /// schedules and the protections: if the
    /// file disagrees (edited or deleted), renewd's copy is written back.
    private func adoptDiskState(_ r: ClockReading) {
        guard let file = StateStore.load() else { return }
        if file.reports != state.reports || file.installID != state.installID || file.aliveMarker != state.aliveMarker
            || file.uninstall?.requestedAt != state.uninstall?.requestedAt
            || file.schedules != state.schedules
            // The anchor's date may not survive the JSON round trip bit for bit.
            || file.wallAnchor?.bootID != state.wallAnchor?.bootID || file.wallAnchor?.mono != state.wallAnchor?.mono
            || file.protections != state.protections || !sameCoolingOffRemoval(file, r)
            || file.activityByUser != state.activityByUser || file.monitorByUser != state.monitorByUser
            || file.monitoringByUser != state.monitoringByUser {
            log("state file disagrees about reports/uninstall/schedules/protections/activity/monitor/alive marker; rewriting")
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
