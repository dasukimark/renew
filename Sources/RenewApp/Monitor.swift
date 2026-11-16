import AppKit
import ApplicationServices
import RenewShared

private struct BrowserTarget {
    let bundleID: String
    let pid: pid_t
    let name: String
    let kind: BrowserKind
}

private enum Inspection {
    case clean(BrowserTarget)
    case denied(BrowserTarget)
    case accessibilityMissing(BrowserTarget)
    /// The browser answered with an error other than a permission denial.
    case unreadable(BrowserTarget, code: Int)
    case blocked(BrowserTarget, url: String, rule: Rule, redirected: Bool)
}

/// The monitoring loop: every 500 ms look at the frontmost browser's active
/// tab (and every 2 s at other running browsers) and swap blocked pages for
/// the block page. Reports permission health to renewd every 2 s and hands
/// each status reply to the UI through `onStatus`.
final class Monitor: NSObject {
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

    init(localSession: SessionInfo?) {
        self.localSession = localSession
        super.init()
        switchBlocker.onBlocked = { [weak self] what in self?.showSwitchNotice(what) }
    }

    func start() {
        let env = ProcessInfo.processInfo.environment
        let port = env["RENEW_PORT"].flatMap(UInt16.init) ?? Paths.blockPagePort(uid: getuid())
        server = BlockPageServer(port: port)
        server.start()
        log("Renew monitor started; block page on 127.0.0.1:\(port)\(localSession != nil ? " (local test session)" : "")")

        setSession(localSession ?? SessionCache.load())

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.sync() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.check() }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.checkEmbeddedWeb() }
        sync()
    }

    // MARK: daemon sync

    private func currentReport() -> AgentReport {
        // Forget permission problems for browsers that are no longer running, or
        // once the session is over. They're re-detected if the browser comes back.
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let inSession = sessionLive
        automationProblems = automationProblems.filter { inSession && runningIDs.contains($0.key) }
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
                self.setSession(status.session, serverTime: status.serverTime)
                SessionCache.save(status.session)
            } else if self.session != nil, !self.sessionLive {
                // renewd unreachable: keep enforcing the last known session until it ends.
                self.setSession(nil)
            }
            self.onStatus?(status)
        }
    }

    // MARK: monitoring

    private func check() {
        switchBlocker.stopIfUntrusted()
        guard session != nil else { return }
        guard sessionLive else { setSession(nil); return }
        checkSettings()
        guard !busy else { return }

        let ws = NSWorkspace.shared
        let running = ws.runningApplications
        if engineCache.count > 64 {
            let alive = Set(running.map(\.processIdentifier))
            engineCache = engineCache.filter { alive.contains($0.key) }
        }
        for app in running where isUnsupportedBrowserApp(app) {
            quitUnsupported(app)
        }

        let now = Date()
        var targets: [BrowserTarget] = []
        let front = ws.frontmostApplication
        if let f = front, let t = target(for: f) { targets.append(t) }
        if now.timeIntervalSince(lastSweep) >= 2 {
            lastSweep = now
            for app in running where app.processIdentifier != front?.processIdentifier && !app.isTerminated {
                if let t = target(for: app) { targets.append(t) }
            }
        }
        guard !targets.isEmpty else { return }

        busy = true
        let rules = ruleSet
        let server = self.server!
        browserQueue.async { [weak self] in
            let results = targets.map { Self.inspect($0, rules: rules, server: server) }
            DispatchQueue.main.async {
                self?.busy = false
                self?.apply(results)
            }
        }
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
                guard let rule = rules.match(tab.url) else { return .clean(t) }
                switch BrowserBridge.redirect(bundleID: t.bundleID, kind: t.kind, tab: tab,
                                              to: server.blockURL(for: tab.url, rule: rule)) {
                case .redirected:
                    return .blocked(t, url: tab.url, rule: rule, redirected: true)
                case .tabChanged:
                    return .clean(t) // user moved on; the next pass checks the new tab
                case .failed:
                    return .blocked(t, url: tab.url, rule: rule, redirected: false)
                }
            case .denied:
                return .denied(t)
            case .noPage:
                return .clean(t)
            case .failed(let code):
                // -600: the app is quitting or just launched; not a read failure.
                return code == -600 ? .clean(t) : .unreadable(t, code: code)
            }
        case .firefox:
            guard AXIsProcessTrusted() else { return .accessibilityMissing(t) }
            if let url = FirefoxReader.activeURL(pid: t.pid), let rule = rules.match(url) {
                return .blocked(t, url: url, rule: rule, redirected: false)
            }
            return .clean(t)
        case .unsupported:
            return .clean(t)
        }
    }

    private func apply(_ results: [Inspection]) {
        var permissionChanged = false
        for r in results {
            switch r {
            case .clean(let t):
                readFailures[t.bundleID] = 0
                if t.kind != .firefox, automationProblems.removeValue(forKey: t.bundleID) != nil { permissionChanged = true }
            case .unreadable(let t, let code):
                let n = (readFailures[t.bundleID] ?? 0) + 1
                readFailures[t.bundleID] = n
                if n == 1 || n % 5 == 0 { log("couldn't read \(t.bundleID) (error \(code)), \(n) in a row") }
                if n >= Self.maxReadFailures {
                    readFailures[t.bundleID] = 0
                    quitUnwatchable(t, why: "Renew couldn't check which site \(t.name) was showing for a while (error \(code)).",
                                    fix: "You can reopen it. If this keeps happening, check Renew's Setup page.")
                }
            case .denied(let t):
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
            case .blocked(let t, let url, let rule, let redirected):
                log("blocked \(url) in \(t.name) (rule \(rule))\(redirected ? "" : "; closing tab")")
                if !redirected { popUpAndCloseTab(t, url: url, rule: rule) }
            }
        }
        if permissionChanged { sync() }
    }

    private func popUpAndCloseTab(_ t: BrowserTarget, url: String, rule: Rule) {
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
    /// the permission comes back (the next check then succeeds).
    private func quitUnwatchable(_ t: BrowserTarget, why: String, fix: String) {
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
    private func checkEmbeddedWeb() {
        guard sessionLive else {
            if !primed.isEmpty { embeddedQueue.async { EmbeddedWebReader.release() } }
            primed.removeAll()
            embeddedBlocks.removeAll()
            notice.hide()
            return
        }
        guard AXIsProcessTrusted() else { return }
        primeEmbeddedWeb()
        let front = NSWorkspace.shared.frontmostApplication
        // The grace banner belongs to the app in grace; drop it if the user moved on.
        let frontInGrace = front.map { embeddedBlocks[$0.processIdentifier]?.graceUntil != nil } ?? false
        if !frontInGrace { notice.hide() }
        guard !embeddedBusy, let app = front, hasEmbeddedWeb(app) else { return }
        let pid = app.processIdentifier
        let rules = ruleSet
        embeddedBusy = true
        embeddedQueue.async { [weak self] in
            let urls = EmbeddedWebReader.pageURLs(pid: pid)
            let hit = urls.lazy.compactMap { url in rules.match(url).map { (url, $0) } }.first
            DispatchQueue.main.async {
                guard let self else { return }
                self.embeddedBusy = false
                guard self.sessionLive, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
                guard let (url, rule) = hit else {
                    self.embeddedMiss(app, pageCount: urls.count)
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
            // Before the next settings check, so a quick click is still filtered.
            switchBlocker.addSettingsPID(app.processIdentifier)
            switchBlocker.setActive(true)
        } else if isUnsupportedBrowserApp(app) {
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
