import AppKit
import ApplicationServices
import RenewShared

private struct BrowserTarget {
    let bundleID: String
    let pid: pid_t
    let name: String
    let kind: BrowserKind
}

/// A page a browser showed when it was checked.
private struct SeenPage {
    let url: String
    let title: String
    /// What reading the page found (mixed sites only, see `PageTextReader`).
    var signals: PageSignals? = nil
}

private enum Inspection {
    /// `page` is what the tab showed, if it could be read.
    case clean(BrowserTarget, page: SeenPage?)
    case denied(BrowserTarget)
    case accessibilityMissing(BrowserTarget)
    /// The browser answered with an error other than a permission denial.
    case unreadable(BrowserTarget, code: Int)
    case blocked(BrowserTarget, page: SeenPage, rule: Rule, redirected: Bool)

    var target: BrowserTarget {
        switch self {
        case .clean(let t, _), .denied(let t), .accessibilityMissing(let t), .unreadable(let t, _), .blocked(let t, _, _, _):
            return t
        }
    }
}

/// The browser-watching loop: during a session, every 500 ms look at the frontmost
/// browser's active tab (and every 2 s at other running browsers) and swap
/// blocked pages for the block page. With Activity on, the front
/// browser's tab (once a second) and the websites in the front app's built-in
/// browser (every 2 s) are also recorded, session or not. Reports permission
/// health to renewd every 2 s and hands each status reply to the UI through
/// `onStatus`.
final class BrowserWatcher: NSObject {
    /// Called on the main thread after every sync. nil means renewd was unreachable.
    var onStatus: ((Status?) -> Void)?

    private let link = DaemonLink()
    private let browserQueue = DispatchQueue(label: "agent.browsers", qos: .userInitiated)
    private let overlay = OverlayController()
    private let localSession: SessionInfo?
    private var server: BlockPageServer!

    /// `CLOCK_MONOTONIC` time the session ends. Activity is judged by this,
    /// not `session.endsAt`, so changing the date between syncs with renewd
    /// doesn't pause enforcement.
    private var deadline: UInt64?

    private(set) var session: SessionInfo? {
        didSet {
            guard session != oldValue else { return }
            ruleSet = RuleSet(strings: session?.rules ?? [])
            server.update(endsAt: session?.endsAt)
            if session == nil { switchBlocker.setActive(false) }
            if let s = session { log("session: ends \(s.endsAt), rules \(s.rules)") } else { log("no session") }
        }
    }
    private var ruleSet = RuleSet([])
    /// The optional hardening features, as renewd last reported them. Kept
    /// while renewd is unreachable.
    private(set) var protections: Protections = .off {
        didSet {
            guard protections != oldValue else { return }
            log("protections: \(protections.onNames)")
            if localSession == nil { ProtectionsCache.save(protections) }
            if !protections.lockSystemSettings { switchBlocker.setActive(false) }
        }
    }
    private var automationProblems: [String: String] = [:]
    private var busy = false
    private var lastSweep = Date.distantPast
    private var lastUnsupportedOverlay = Date.distantPast
    private var closeCooldown: [pid_t: Date] = [:]
    /// Engine check results per process, so each app bundle is inspected once.
    private var engineCache: [pid_t: BrowserEngine?] = [:]
    /// Built-in browsers inside other apps (T3 Code, Claude, Codex…).
    private let embeddedQueue = DispatchQueue(label: "agent.embedded-web", qos: .userInitiated)
    private var embeddedBusy = false
    /// Apps already asked to expose their Accessibility tree this session.
    private var primed: Set<pid_t> = []
    /// Apps hidden for showing a blocked page, and the grace periods given to
    /// close it.
    private struct EmbeddedBlock {
        var hiddenAt: Date
        var graceUntil: Date?
        /// Scans in a row that read the app but didn't find the page.
        var misses = 0
    }
    private var embeddedBlocks: [pid_t: EmbeddedBlock] = [:]
    private let notice = NoticeController()
    static let embeddedGrace: TimeInterval = 15
    /// Consecutive failed reads per browser. A browser that can't be read for
    /// this many checks in a row (≈10 s in front, ≈40 s in the background)
    /// counts as unwatchable instead of silently passing.
    private var readFailures: [String: Int] = [:]
    private static let maxReadFailures = 20
    private var lastSettingsCheck = Date.distantPast
    /// System Settings page titles already logged, to confirm the names
    /// `SettingsGuard` matches on this macOS version.
    private var seenSettingsTitles: Set<String> = []
    private let switchBlocker = OffSwitchBlocker()
    /// Drawn below `notice`, so the two banners never overlap.
    private let settingsNotice = NoticeController(slot: 1)
    private let settingsQueue = DispatchQueue(label: "agent.settings", qos: .userInitiated)
    private var settingsBusy = false
    private var lastSettingsTitleRead = Date.distantPast
    /// Its own throttle, so another overlay can't hide why System Settings closed.
    private var lastSettingsOverlay = Date.distantPast
    private var settingsNoticeHide: DispatchWorkItem?

    /// Whether Activity records visits, as renewd last reported it. Kept
    /// while renewd is unreachable.
    private(set) var activity: ActivitySettings = .off {
        didSet {
            guard activity != oldValue else { return }
            log("Activity recording \(activity.enabled ? "on" : "off")")
            if localSession == nil { ActivityCache.save(activity) }
            recorder.settings = activity
        }
    }
    private lazy var recorder = ActivityRecorder(link: link, localOnly: localSession != nil)
    /// Outside sessions the front browser is read at most this often.
    private static let monitorInterval: TimeInterval = 1
    private static let embeddedMonitorInterval: TimeInterval = 2
    private var lastMonitorRead = Date.distantPast
    private var lastEmbeddedMonitorRead = Date.distantPast
    /// No input for this long counts as away: open visits end.
    private static let idleAfter: TimeInterval = 5 * 60
    /// Only the copy that watches browsers records (see `AppDelegate`).
    private var started = false
    /// Whether the Monitor wants mixed sites read (`MonitorSettings.flagExplicitTerms`),
    /// as renewd last reported it.
    private var checkMixed = false
    /// The mixed page in the front browser: when it was read and what of
    /// its text was checked. Only used on `browserQueue`.
    private let pageReads = PageReadState(interval: PageTextReader.rereadAfter)
    /// Browsers whose tree was switched on to read a mixed page, and the one
    /// showing a mixed page now.
    private var pagePrimed: Set<pid_t> = []
    private var mixedFront: pid_t? {
        didSet {
            // Its visit ends: the next one has the page checked afresh.
            if mixedFront == nil, oldValue != nil {
                let reads = pageReads
                browserQueue.async { reads.reset() }
            }
        }
    }

    init(localSession: SessionInfo?) {
        self.localSession = localSession
        super.init()
        switchBlocker.onBlocked = { [weak self] what in self?.showSwitchNotice(what) }
    }

    func start() {
        let env = ProcessInfo.processInfo.environment
        let port = env["RENEW_PORT"].flatMap(UInt16.init) ?? Paths.blockPagePort(uid: getuid())
        started = true
        server = BlockPageServer(port: port)
        server.start()
        log("Renew browser watcher started; block page on 127.0.0.1:\(port)\(localSession != nil ? " (local test session)" : "")")

        // Until renewd answers, enforce what it last said, alongside the cached session.
        protections = localSession != nil ? Self.localProtections() : ProtectionsCache.load()
        activity = localSession != nil ? Self.localActivity() : ActivityCache.load()
        if localSession != nil {
            checkMixed = ["on", "1", "true"].contains((ProcessInfo.processInfo.environment["RENEW_MIXED"] ?? "").lowercased())
        }
        recorder.settings = activity
        recorder.start()
        setSession(localSession ?? SessionCache.load())

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.sync() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.check() }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.checkEmbeddedWeb() }
        sync()
    }

    /// For `--local-session` runs: `RENEW_PROTECTIONS=all` or a comma list
    /// of names (lock-settings, close-browsers). Off by default, like an install.
    private static func localProtections() -> Protections {
        let raw = ProcessInfo.processInfo.environment["RENEW_PROTECTIONS"] ?? ""
        var p = Protections.off
        for name in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            guard let keys = Protections.keys(named: name) else {
                log("RENEW_PROTECTIONS: unknown protection '\(name)' (known: \(Protections.allNames.joined(separator: ", ")))")
                continue
            }
            for k in keys { p[keyPath: k] = true }
        }
        return p
    }

    /// For `--local-session` runs: `RENEW_ACTIVITY=on` (or the older
    /// `RENEW_MONITORING=on`) records visits to the log (stdout).
    private static func localActivity() -> ActivitySettings {
        let env = ProcessInfo.processInfo.environment
        let raw = (env["RENEW_ACTIVITY"] ?? env["RENEW_MONITORING"] ?? "").lowercased()
        return ActivitySettings(enabled: ["on", "1", "true"].contains(raw))
    }

    /// Renew is quitting: save visits that haven't reached renewd yet.
    func shutdown() {
        guard started else { return }
        recorder.shutdown()
        let primed = pagePrimed
        pagePrimed.removeAll()
        if !primed.isEmpty { embeddedQueue.sync { for pid in primed { EmbeddedWebReader.releaseBrowser(pid: pid) } } }
    }

    // MARK: daemon sync

    private func currentReport() -> AgentReport {
        // Forget permission problems for browsers that are no longer running, or
        // once the session is over. They're re-detected if the browser comes back.
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let inSession = sessionLive
        // Recording needs the permissions too, session or not.
        let watching = inSession || recorder.enabled
        automationProblems = automationProblems.filter { watching && runningIDs.contains($0.key) }
        if !inSession { readFailures.removeAll() }

        var problems: [String] = []
        if !AXIsProcessTrusted() { problems.append("Accessibility permission is off for Renew") }
        problems += automationProblems.values.sorted()
        return AgentReport(permissionsOK: problems.isEmpty, problem: problems.isEmpty ? nil : problems.joined(separator: "; "))
    }

    /// Sets the session; it ends `endsAt - serverTime` from now on the
    /// monotonic clock.
    private func setSession(_ s: SessionInfo?, serverTime: Date = Date()) {
        session = s
        deadline = s.map {
            ClockReading.monoNow() + UInt64(max(0, $0.endsAt.timeIntervalSince(serverTime)) * 1e9)
        }
    }

    private var sessionLive: Bool {
        guard session != nil, let d = deadline else { return false }
        return ClockReading.monoNow() < d
    }

    func sync() {
        guard localSession == nil else {
            if session != nil, !sessionLive { setSession(nil) }
            let local = Status(session: session, serverTime: Date(), agents: [])
            onStatus?(local)
            return
        }
        link.report(currentReport()) { [weak self] status in
            guard let self else { return }
            if let status {
                self.protections = status.protections ?? .off
                self.activity = status.effectiveActivity
                self.checkMixed = status.monitor.map { $0.enabled && $0.flagExplicitTerms } ?? false
                self.setSession(status.session, serverTime: status.serverTime)
                SessionCache.save(status.session)
            } else if self.session != nil, !self.sessionLive {
                // renewd unreachable: keep enforcing the last known session until it ends.
                self.setSession(nil)
            }
            self.onStatus?(status)
        }
    }

    // MARK: watching

    private func check() {
        switchBlocker.stopIfUntrusted()
        if session != nil, !sessionLive { setSession(nil) }
        let live = session != nil
        let recording = recorder.enabled
        // Stop exposing a browser's pages as soon as no mixed site is in front.
        if mixedFront != nil, !recording || !checkMixed
            || NSWorkspace.shared.frontmostApplication?.processIdentifier != mixedFront {
            mixedFront = nil
        }
        releasePagePriming()
        guard live || recording else { return }
        if live && protections.lockSystemSettings { checkSettings() }

        let now = Date()
        let leftAt = recording ? Self.userLeftAt() : nil
        let away = leftAt != nil
        if mixedFront != nil, away { mixedFront = nil }
        releasePagePriming()
        if let leftAt { recorder.away(since: leftAt) }
        // Outside sessions only recording needs the browser, and less often.
        if !live && (away || now.timeIntervalSince(lastMonitorRead) < Self.monitorInterval) { return }
        guard !busy else { return }

        let ws = NSWorkspace.shared
        let running = ws.runningApplications
        if live {
            if engineCache.count > 64 {
                let alive = Set(running.map(\.processIdentifier))
                engineCache = engineCache.filter { alive.contains($0.key) }
            }
            if protections.closeUnwatchedBrowsers {
                for app in running where isUnsupportedBrowserApp(app) {
                    quitUnsupported(app)
                }
            }
        }

        var targets: [BrowserTarget] = []
        let front = ws.frontmostApplication
        let frontTarget = front.flatMap(target(for:))
        if let t = frontTarget { targets.append(t) }
        if live && now.timeIntervalSince(lastSweep) >= 2 {
            lastSweep = now
            for app in running where app.processIdentifier != front?.processIdentifier && !app.isTerminated {
                if let t = target(for: app) { targets.append(t) }
            }
        }
        if recording && !away && frontTarget == nil { recorder.observe(.browser, []) }
        guard !targets.isEmpty else { return }

        lastMonitorRead = now
        busy = true
        let rules = live ? ruleSet : RuleSet([])
        let server = self.server!
        let record = recording && !away
        let readMixed = record && checkMixed ? frontTarget : nil
        let pageReads = self.pageReads
        let embeddedQueue = self.embeddedQueue
        browserQueue.async { [weak self] in
            var results = targets.map { Self.inspect($0, rules: rules, server: server) }
            if let t = readMixed, let i = results.firstIndex(where: { $0.target.pid == t.pid }),
               case .clean(_, var page?) = results[i], SiteCategory.of(url: page.url) == .mixed {
                // Only the page in front is remembered: another one there ended its visit.
                let key = "\(t.pid)|\(page.url)"
                pageReads.keep(only: [key])
                if pageReads.take(key, now: now) {
                    if t.kind == .chromium { embeddedQueue.sync { EmbeddedWebReader.primeBrowser(pid: t.pid) } }
                    // Chromium builds its tree a moment after it's switched on:
                    // with nothing found yet, try again on the next check.
                    if let found = PageTextReader.signals(pid: t.pid, url: page.url, state: pageReads, key: key) {
                        page.signals = found
                    } else {
                        pageReads.giveBack(key)
                        page.signals = PageSignals()
                    }
                    results[i] = .clean(t, page: page)
                }
            }
            DispatchQueue.main.async {
                self?.busy = false
                self?.apply(results, front: record ? frontTarget : nil)
            }
        }
    }

    /// When the user left, if they're away: the last keyboard or mouse input
    /// once there's been none for `idleAfter`, or now if the screen is locked.
    private static func userLeftAt() -> Date? {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false { return Date() }
        if let anyInput = CGEventType(rawValue: ~0) {
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
            if idle >= idleAfter { return Date().addingTimeInterval(-idle) }
        }
        return nil
    }

    private func target(for app: NSRunningApplication) -> BrowserTarget? {
        guard let id = app.bundleIdentifier, let kind = BrowserCatalog.kind(of: id), kind != .unsupported else { return nil }
        return BrowserTarget(bundleID: id, pid: app.processIdentifier, name: app.localizedName ?? id, kind: kind)
    }

    /// Runs on `browserQueue`.
    private static func inspect(_ t: BrowserTarget, rules: RuleSet, server: BlockPageServer) -> Inspection {
        switch t.kind {
        case .safari, .chromium:
            switch BrowserBridge.activeTab(bundleID: t.bundleID, kind: t.kind) {
            case .tab(let tab):
                let page = SeenPage(url: tab.url, title: tab.title)
                guard let rule = rules.match(tab.url) else { return .clean(t, page: page) }
                switch BrowserBridge.redirect(bundleID: t.bundleID, kind: t.kind, tab: tab,
                                              to: server.blockURL(for: tab.url, rule: rule)) {
                case .redirected:
                    return .blocked(t, page: page, rule: rule, redirected: true)
                case .tabChanged:
                    return .clean(t, page: nil) // user moved on; the next pass checks the new tab
                case .failed:
                    return .blocked(t, page: page, rule: rule, redirected: false)
                }
            case .denied:
                return .denied(t)
            case .noPage:
                return .clean(t, page: nil)
            case .failed(let code):
                // -600: the app is quitting or just launched; not a read failure.
                return code == -600 ? .clean(t, page: nil) : .unreadable(t, code: code)
            }
        case .firefox:
            guard AXIsProcessTrusted() else { return .accessibilityMissing(t) }
            guard let p = FirefoxReader.activePage(pid: t.pid) else { return .clean(t, page: nil) }
            let page = SeenPage(url: p.url, title: p.title)
            if let rule = rules.match(p.url) {
                return .blocked(t, page: page, rule: rule, redirected: false)
            }
            return .clean(t, page: page)
        case .unsupported:
            return .clean(t, page: nil)
        }
    }

    /// Acts on what the browsers showed. `front` is the frontmost browser
    /// when its page should be recorded. Everything that closes or covers
    /// something only happens during a session.
    private func apply(_ results: [Inspection], front: BrowserTarget?) {
        // Chromium browsers whose page was read had their tree switched on.
        for case .clean(let t, let page?) in results where page.signals != nil && t.kind == .chromium {
            pagePrimed.insert(t.pid)
        }
        // The user may have switched apps while the browser was being read.
        if let front, NSWorkspace.shared.frontmostApplication?.processIdentifier == front.pid {
            var seen: [ActivityRecorder.Seen] = []
            for r in results where r.target.pid == front.pid {
                switch r {
                case .clean(_, let page?):
                    seen.append(.init(source: front.bundleID, browser: front.name, url: page.url, title: page.title,
                                      signals: page.signals))
                    if checkMixed, SiteCategory.of(url: page.url) == .mixed {
                        mixedFront = front.pid
                    } else if mixedFront == front.pid {
                        mixedFront = nil
                    }
                case .blocked(_, let page, _, _):
                    seen.append(.init(source: front.bundleID, browser: front.name, url: page.url, title: page.title, blocked: true))
                default:
                    break
                }
            }
            recorder.observe(.browser, seen)
        } else {
            mixedFront = nil
        }
        releasePagePriming()

        let live = sessionLive
        var permissionChanged = false
        for r in results {
            switch r {
            case .clean(let t, _):
                readFailures[t.bundleID] = 0
                if t.kind != .firefox, automationProblems.removeValue(forKey: t.bundleID) != nil { permissionChanged = true }
            case .unreadable(let t, let code):
                guard live else { break }
                let n = (readFailures[t.bundleID] ?? 0) + 1
                readFailures[t.bundleID] = n
                if n == 1 || n % 5 == 0 { log("couldn't read \(t.bundleID) (error \(code)), \(n) in a row") }
                if n >= Self.maxReadFailures {
                    readFailures[t.bundleID] = 0
                    quitUnwatchable(t, why: "Renew couldn't check which site \(t.name) was showing for a while (error \(code)).",
                                    fix: "You can reopen it. If this keeps happening, check Renew's Setup page.")
                }
            case .denied(let t):
                // Reported while recording too, so a lost permission doesn't
                // silently stop the activity log.
                guard live || recorder.enabled else { break }
                if automationProblems[t.bundleID] == nil {
                    automationProblems[t.bundleID] = "Automation permission for \(t.name) is off"
                    permissionChanged = true
                    log("automation denied for \(t.bundleID)")
                }
                quitUnwatchable(t, why: "Renew isn't allowed to control \(t.name), so it can't check which sites are open.",
                                fix: "Turn it back on in System Settings → Privacy & Security → Automation → Renew.")
            case .accessibilityMissing(let t):
                quitUnwatchable(t, why: "Accessibility is turned off for Renew, so it can't check which sites are open in \(t.name).",
                                fix: "Turn it back on in System Settings → Privacy & Security → Accessibility.")
            case .blocked(let t, let page, let rule, let redirected):
                guard live else { break }
                log("blocked \(page.url) in \(t.name) (rule \(rule))\(redirected ? "" : "; closing tab")")
                if !redirected { popUpAndCloseTab(t, url: page.url, rule: rule) }
            }
        }
        if permissionChanged { sync() }
    }

    /// Switches off the trees of browsers primed for page reading, except
    /// the one showing a mixed site now.
    private func releasePagePriming() {
        let release = pagePrimed.filter { $0 != mixedFront }
        guard !release.isEmpty else { return }
        pagePrimed.subtract(release)
        embeddedQueue.async { for pid in release { EmbeddedWebReader.releaseBrowser(pid: pid) } }
    }

    private func popUpAndCloseTab(_ t: BrowserTarget, url: String, rule: Rule) {
        guard sessionLive else { return }
        let now = Date()
        if let until = closeCooldown[t.pid], until > now { return }
        closeCooldown[t.pid] = now.addingTimeInterval(1.5)

        let host = NormalizedURL(url)?.host ?? url
        overlay.show(title: "\(host) is blocked",
                     detail: "Renew closed the tab. Matched rule: \(rule)",
                     endsAt: session?.endsAt)
        // Cmd-W to the browser closes the offending tab.
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 0x0D, keyDown: down)
            e?.flags = .maskCommand
            e?.postToPid(t.pid)
        }
    }

    /// A supported browser Renew has lost permission to watch: close it,
    /// and it gets closed again on every relaunch until the session ends or
    /// the permission comes back (the next check then succeeds). Only with
    /// the "close browsers Renew can't watch" protection on.
    private func quitUnwatchable(_ t: BrowserTarget, why: String, fix: String) {
        guard protections.closeUnwatchedBrowsers, sessionLive else { return }
        guard let app = NSRunningApplication(processIdentifier: t.pid), !app.isTerminated else { return }
        log("closing \(t.bundleID): can't watch it (\(why))")
        app.forceTerminate()
        let now = Date()
        guard now.timeIntervalSince(lastUnsupportedOverlay) > 3 else { return }
        lastUnsupportedOverlay = now
        overlay.show(title: "\(t.name) is closed until your session ends",
                     detail: "\(why) \(fix)",
                     endsAt: session?.endsAt)
    }

    private func quitUnsupported(_ app: NSRunningApplication) {
        guard sessionLive else { return }
        let name = app.localizedName ?? app.bundleIdentifier ?? "That browser"
        let engine = engineCache[app.processIdentifier] ?? nil
        log("quitting unsupported browser \(app.bundleIdentifier ?? "?")\(engine.map { " (built on \($0.rawValue))" } ?? "")")
        app.forceTerminate()
        let now = Date()
        guard now.timeIntervalSince(lastUnsupportedOverlay) > 3 else { return }
        lastUnsupportedOverlay = now
        let why = engine.map { "\(name) looks like a browser built on \($0.rawValue). " } ?? ""
        overlay.show(title: "\(name) isn't allowed during a block session",
                     detail: why + "Renew can only watch Safari, Chrome, Edge, Brave, Arc, Vivaldi and Firefox, so other browsers are closed until the session ends.",
                     endsAt: session?.endsAt)
    }

    // MARK: System Settings

    /// On the pages locked during sessions (see `SettingsGuard`), switches can
    /// be turned on but not off (`OffSwitchBlocker`). If that filter can't run,
    /// System Settings is closed while it shows one of those pages instead.
    ///
    /// The filter only exists while System Settings is running, since it
    /// holds up every click while it looks. Window titles are read on
    /// `settingsQueue`, so an unresponsive System Settings never holds up the
    /// browser checks: every second when they decide whether to close it,
    /// every 10 seconds (to log new page names) while the filter handles it.
    private func checkSettings() {
        let now = Date()
        guard now.timeIntervalSince(lastSettingsCheck) >= 1 else { return }
        lastSettingsCheck = now
        let apps = SettingsGuard.runningApps
        switchBlocker.setSettingsPIDs(Set(apps.map(\.processIdentifier)))
        let filtering = switchBlocker.setActive(!apps.isEmpty)
        guard let app = apps.first, !settingsBusy,
              !filtering || now.timeIntervalSince(lastSettingsTitleRead) >= 10 else { return }
        lastSettingsTitleRead = now
        settingsBusy = true
        settingsQueue.async { [weak self] in
            let titles = SettingsGuard.windowTitles(of: app)
            DispatchQueue.main.async {
                guard let self else { return }
                self.settingsBusy = false
                for t in titles where !self.seenSettingsTitles.contains(t) {
                    self.seenSettingsTitles.insert(t)
                    log("System Settings page open during a session: \(t)")
                }
                guard !filtering, self.sessionLive, let locked = titles.first(where: SettingsGuard.isLocked) else { return }
                self.closeSettings(app, locked: locked)
            }
        }
    }

    /// Fallback when the switch filter can't run.
    private func closeSettings(_ app: NSRunningApplication, locked: String) {
        log("closing System Settings: \(locked) is locked during a block session")
        app.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if !app.isTerminated { app.forceTerminate() }
        }
        let now = Date()
        guard now.timeIntervalSince(lastSettingsOverlay) > 3 else { return }
        lastSettingsOverlay = now
        overlay.show(title: "\(locked) is locked during your session",
                     detail: "Renew closes this page in System Settings until the block session ends, so its background services and permissions can't be turned off. The rest of System Settings works as usual.",
                     endsAt: session?.endsAt)
    }

    private func showSwitchNotice(_ what: String) {
        settingsNotice.show("Blocked \(what): switches here can be turned on but not off until your session ends")
        settingsNoticeHide?.cancel()
        let hide = DispatchWorkItem { [weak self] in self?.settingsNotice.hide() }
        settingsNoticeHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: hide)
    }

    // MARK: built-in browsers in other apps

    /// Apps whose built-in browser Renew checks: everything with a Dock icon
    /// except browsers it already handles (and itself).
    private func hasEmbeddedWeb(_ app: NSRunningApplication) -> Bool {
        !app.isTerminated && app.processIdentifier != getpid() && app.activationPolicy == .regular
            && BrowserCatalog.kind(of: app.bundleIdentifier) == nil
    }

    /// Electron needs a few seconds to build its Accessibility tree, so ask
    /// every candidate app up front rather than when it comes to the front.
    private func primeEmbeddedWeb() {
        guard AXIsProcessTrusted() else { return }
        for app in NSWorkspace.shared.runningApplications where hasEmbeddedWeb(app) && !primed.contains(app.processIdentifier) {
            primed.insert(app.processIdentifier)
            let pid = app.processIdentifier
            embeddedQueue.async { EmbeddedWebReader.prime(pid: pid) }
        }
    }

    /// During a session, checks the pages shown inside the frontmost app. If
    /// one is blocked, Renew covers the screen and hides the app (it can't
    /// redirect a page inside another app). Every time the app is brought
    /// back, a banner gives `embeddedGrace` seconds to close the page; after
    /// that the app is hidden again (without the overlay, which only shows the
    /// first time).
    ///
    /// With Activity on, the websites in the front app's built-in
    /// browser are also recorded, session or not. Outside sessions only the
    /// front app is asked to expose its tree, and Renew switches
    /// AXEnhancedUserInterface (see `EmbeddedWebReader`) back off for an app
    /// as soon as it leaves the front.
    private func checkEmbeddedWeb() {
        let live = sessionLive
        if !live && (!primed.isEmpty || !embeddedBlocks.isEmpty) {
            primed.removeAll()
            embeddedBlocks.removeAll()
            notice.hide()
        }
        let front = NSWorkspace.shared.frontmostApplication
        let recording = recorder.enabled
        guard (live || recording), AXIsProcessTrusted() else {
            embeddedQueue.async { EmbeddedWebReader.release() }
            return
        }
        let candidate = front.flatMap { hasEmbeddedWeb($0) ? $0 : nil }
        if live {
            primeEmbeddedWeb()
            // The grace banner belongs to the app in grace; drop it if the user moved on.
            let frontInGrace = front.map { embeddedBlocks[$0.processIdentifier]?.graceUntil != nil } ?? false
            if !frontInGrace { notice.hide() }
        } else {
            let keep = candidate?.processIdentifier
            embeddedQueue.async { EmbeddedWebReader.release(except: keep) }
        }
        let away = recording && Self.userLeftAt() != nil
        let record = recording && !away
        if recording && (away || candidate == nil) {
            recorder.observe(.embedded, [])
            embeddedQueue.async { EmbeddedWebReader.forgetPageText() }
        }
        let now = Date()
        if !live && (!record || now.timeIntervalSince(lastEmbeddedMonitorRead) < Self.embeddedMonitorInterval) { return }
        guard !embeddedBusy, let app = candidate else { return }
        lastEmbeddedMonitorRead = now
        let pid = app.processIdentifier
        let rules = live ? ruleSet : RuleSet([])
        let readMixed = record && checkMixed
        embeddedBusy = true
        embeddedQueue.async { [weak self] in
            let pages = EmbeddedWebReader.pages(pid: pid, readMixed: readMixed)
            let hit = pages.lazy.compactMap { p in rules.match(p.url).map { (p.url, $0) } }.first
            DispatchQueue.main.async {
                guard let self else { return }
                self.embeddedBusy = false
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
                if record, self.recorder.enabled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                    let name = app.localizedName ?? app.bundleIdentifier ?? "An app"
                    let source = "app:" + (app.bundleIdentifier ?? "\(pid)")
                    self.recorder.observe(.embedded, pages.filter(\.isWebsite).map {
                        ActivityRecorder.Seen(source: source, browser: name, url: $0.url, title: $0.title, blocked: $0.url == hit?.0,
                                              signals: $0.signals)
                    })
                }
                guard live, self.sessionLive else { return }
                guard let (url, rule) = hit else {
                    self.embeddedMiss(app, pageCount: pages.count)
                    return
                }
                self.handleEmbeddedHit(app, url: url, rule: rule)
            }
        }
    }

    /// A scan found no blocked page. It only counts as closed after two such
    /// scans that could actually read the app: an empty result (not even the
    /// app's own UI) is a failed read.
    private func embeddedMiss(_ app: NSRunningApplication, pageCount: Int) {
        let pid = app.processIdentifier
        guard var block = embeddedBlocks[pid], pageCount > 0 else { return }
        block.misses += 1
        guard block.misses >= 2 else { embeddedBlocks[pid] = block; return }
        embeddedBlocks[pid] = nil
        log("blocked page closed in \(app.bundleIdentifier ?? "pid \(pid)")")
        notice.hide()
    }

    private func handleEmbeddedHit(_ app: NSRunningApplication, url: String, rule: Rule) {
        let pid = app.processIdentifier
        let name = app.localizedName ?? app.bundleIdentifier ?? "This app"
        let host = NormalizedURL(url)?.host ?? url
        let now = Date()

        guard var block = embeddedBlocks[pid] else {
            hideEmbedded(app, host: host, rule: rule, name: name, firstTime: true)
            return
        }
        block.misses = 0
        embeddedBlocks[pid] = block
        if let until = block.graceUntil {
            if until > now {
                notice.show("Close \(host) in \(name) within \(Int(until.timeIntervalSince(now).rounded(.up)))s, or Renew hides \(name) again")
            } else {
                hideEmbedded(app, host: host, rule: rule, name: name, firstTime: false)
            }
            return
        }
        // Still in front right after hiding: hiding takes a moment.
        guard now.timeIntervalSince(block.hiddenAt) > 2 else { app.hide(); return }
        // The user brought the app back: let them close the page.
        block.graceUntil = now.addingTimeInterval(Self.embeddedGrace)
        embeddedBlocks[pid] = block
        log("grace period for \(app.bundleIdentifier ?? name) to close \(host)")
        notice.show("Close \(host) in \(name) within \(Int(Self.embeddedGrace))s, or Renew hides \(name) again")
    }

    private func hideEmbedded(_ app: NSRunningApplication, host: String, rule: Rule, name: String, firstTime: Bool) {
        log("blocked \(host) in the built-in browser of \(app.bundleIdentifier ?? name) (rule \(rule)); hiding it")
        embeddedBlocks[app.processIdentifier] = EmbeddedBlock(hiddenAt: Date(), graceUntil: nil)
        notice.hide()
        app.hide()
        // The overlay explains it once; after that the banner says enough.
        guard firstTime else { return }
        let now = Date()
        guard now.timeIntervalSince(lastUnsupportedOverlay) > 3 else { return }
        lastUnsupportedOverlay = now
        overlay.show(title: "\(host) is blocked",
                     detail: "\(name)'s built-in browser was showing it, so Renew hid \(name). Open \(name) again and you'll have \(Int(Self.embeddedGrace)) seconds to go back or close that page. Matched rule: \(rule)",
                     endsAt: session?.endsAt)
    }

    @objc private func appLaunched(_ note: Notification) {
        guard session != nil, sessionLive,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier == SettingsGuard.bundleID {
            guard protections.lockSystemSettings else { return }
            // Before the next settings check, so a quick click is still filtered.
            switchBlocker.addSettingsPID(app.processIdentifier)
            switchBlocker.setActive(true)
        } else if protections.closeUnwatchedBrowsers, isUnsupportedBrowserApp(app) {
            quitUnsupported(app)
        } else if hasEmbeddedWeb(app), AXIsProcessTrusted() {
            primed.insert(app.processIdentifier)
            let pid = app.processIdentifier
            embeddedQueue.async { EmbeddedWebReader.prime(pid: pid) }
        }
    }

    /// Only ever close real, user-facing apps (with a Dock icon), never helpers
    /// or background processes that happen to share a bundle-ID prefix.
    ///
    /// Apps Renew has no entry for are inspected once per process: anything
    /// built on Chromium or Gecko that isn't an Electron/CEF app counts as an
    /// unsupported browser (a renamed copy of Chrome, Chrome for Testing, a
    /// Firefox fork).
    private func isUnsupportedBrowserApp(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated, app.activationPolicy == .regular else { return false }
        switch BrowserCatalog.kind(of: app.bundleIdentifier) {
        case .unsupported: return true
        case .some: return false
        case nil: return engine(of: app) != nil
        }
    }

    private func engine(of app: NSRunningApplication) -> BrowserEngine? {
        let pid = app.processIdentifier
        if let cached = engineCache[pid] { return cached }
        guard pid != getpid(), let path = app.bundleURL?.path else { return nil }
        let engine = EngineDetector.browserEngine(bundleAt: path, bundleID: app.bundleIdentifier)
        engineCache[pid] = engine
        if let engine { log("\(app.bundleIdentifier ?? path) looks like a \(engine.rawValue) browser") }
        return engine
    }
}
