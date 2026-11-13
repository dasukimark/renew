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

    private(set) var session: SessionInfo? {
        didSet {
            guard session != oldValue else { return }
            ruleSet = RuleSet(strings: session?.rules ?? [])
            server.update(endsAt: session?.endsAt)
            if let s = session { log("session: ends \(s.endsAt), rules \(s.rules)") } else { log("no session") }
        }
    }
    private var ruleSet = RuleSet([])
    private var automationProblems: [String: String] = [:]
    private var busy = false
    private var lastSweep = Date.distantPast
    private var lastUnsupportedOverlay = Date.distantPast
    private var closeCooldown: [pid_t: Date] = [:]
    /// Consecutive failed reads per browser. A browser that can't be read for
    /// this many checks in a row (≈10 s in front, ≈40 s in the background)
    /// counts as unwatchable instead of silently passing.
    private var readFailures: [String: Int] = [:]
    private static let maxReadFailures = 20

    init(localSession: SessionInfo?) {
        self.localSession = localSession
        super.init()
    }

    func start() {
        let env = ProcessInfo.processInfo.environment
        let port = env["RENEW_PORT"].flatMap(UInt16.init) ?? Paths.blockPagePort(uid: getuid())
        server = BlockPageServer(port: port)
        server.start()
        log("Renew monitor started; block page on 127.0.0.1:\(port)\(localSession != nil ? " (local test session)" : "")")

        session = localSession ?? SessionCache.load()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.sync() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.check() }
        sync()
    }

    // MARK: daemon sync

    private func currentReport() -> AgentReport {
        // Forget permission problems for browsers that are no longer running, or
        // once the session is over. They're re-detected if the browser comes back.
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let inSession = session?.isActive() == true
        automationProblems = automationProblems.filter { inSession && runningIDs.contains($0.key) }
        if !inSession { readFailures.removeAll() }

        var problems: [String] = []
        if !AXIsProcessTrusted() { problems.append("Accessibility permission is off for Renew") }
        problems += automationProblems.values.sorted()
        return AgentReport(permissionsOK: problems.isEmpty, problem: problems.isEmpty ? nil : problems.joined(separator: "; "))
    }

    func sync() {
        guard localSession == nil else {
            if let s = session, !s.isActive() { session = nil }
            let local = Status(session: session, serverTime: Date(), agents: [])
            onStatus?(local)
            return
        }
        link.report(currentReport()) { [weak self] status in
            guard let self else { return }
            if let status {
                self.session = status.session
                SessionCache.save(status.session)
            } else if let s = self.session, !s.isActive() {
                // renewd unreachable: keep enforcing the last known session until it ends.
                self.session = nil
            }
            self.onStatus?(status)
        }
    }

    // MARK: monitoring

    private func check() {
        guard let s = session else { return }
        guard s.isActive() else { session = nil; return }
        guard !busy else { return }

        let ws = NSWorkspace.shared
        let running = ws.runningApplications
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
        log("quitting unsupported browser \(app.bundleIdentifier ?? "?")")
        app.forceTerminate()
        let now = Date()
        guard now.timeIntervalSince(lastUnsupportedOverlay) > 3 else { return }
        lastUnsupportedOverlay = now
        overlay.show(title: "\(name) isn't allowed during a focus session",
                     detail: "Renew can only watch Safari, Chrome, Edge, Brave, Arc, Vivaldi and Firefox, so other browsers are closed until the session ends.",
                     endsAt: session?.endsAt)
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let s = session, s.isActive(),
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              isUnsupportedBrowserApp(app) else { return }
        quitUnsupported(app)
    }

    /// Only ever close real, user-facing apps (with a Dock icon), never helpers
    /// or background processes that happen to share a bundle-ID prefix.
    private func isUnsupportedBrowserApp(_ app: NSRunningApplication) -> Bool {
        !app.isTerminated
            && app.activationPolicy == .regular
            && BrowserCatalog.kind(of: app.bundleIdentifier) == .unsupported
    }
}
