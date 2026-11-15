import AppKit
import Combine
import RenewShared

/// Everything the UI shows, kept on the main thread.
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case focus = "Focus"
        case lists = "Blocklists"
        case setup = "Setup"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .focus: return "timer"
            case .lists: return "list.bullet.rectangle"
            case .setup: return "gearshape"
            }
        }
    }

    @Published var section: Section = .focus
    @Published private(set) var status: Status?
    @Published private(set) var daemonReachable = false
    @Published private(set) var now = Date()
    @Published private(set) var lists: [String: [String]] = ListStore.all()
    @Published private(set) var accessibilityGranted = Permissions.accessibilityGranted
    @Published private(set) var browsers: [BrowserPermission] = []
    @Published var busy = false
    @Published var errorMessage: String?

    /// Lists ticked on the Focus screen, remembered between launches.
    @Published var selectedLists: Set<String> {
        didSet { UserDefaults.standard.set(Array(selectedLists), forKey: "selectedLists") }
    }
    @Published var durationMinutes: Int {
        didSet { UserDefaults.standard.set(durationMinutes, forKey: "durationMinutes") }
    }

    let isLocalTest: Bool
    private let queue = DispatchQueue(label: "app.model")
    private var clock: Timer?

    init(isLocalTest: Bool) {
        self.isLocalTest = isLocalTest
        let saved = UserDefaults.standard.stringArray(forKey: "selectedLists") ?? ["social"]
        selectedLists = Set(saved)
        let minutes = UserDefaults.standard.integer(forKey: "durationMinutes")
        durationMinutes = minutes > 0 ? minutes : 60
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.now = Date()
        }
        refreshPermissions()
    }

    // MARK: derived state

    var isInstalled: Bool { FileManager.default.fileExists(atPath: Paths.daemonPlist) }

    var isRunningInstalledCopy: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path == Paths.agentApp
    }

    var session: SessionInfo? {
        guard let s = status?.session, s.endsAt > now else { return nil }
        return s
    }

    var secondsLeft: Int { session.map { max(0, Int($0.endsAt.timeIntervalSince(now))) } ?? 0 }

    var progress: Double {
        guard let s = session else { return 0 }
        let total = s.endsAt.timeIntervalSince(s.startedAt)
        return total > 0 ? min(1, max(0, now.timeIntervalSince(s.startedAt) / total)) : 0
    }

    /// Missing permissions. A browser Renew can't watch is closed during sessions.
    var permissionWarnings: [String] {
        var out: [String] = []
        let hasFirefox = browsers.contains { $0.kind == .firefox }
        if !accessibilityGranted {
            out.append(hasFirefox ? "Accessibility is off (needed for Firefox)" : "Accessibility is off")
        }
        for b in browsers where b.kind != .firefox && b.state == .denied {
            out.append("Renew isn't allowed to control \(b.name)")
        }
        return out
    }

    var sortedListNames: [String] { lists.keys.sorted() }

    func rules(forSelection names: Set<String>, extra: String) -> [String] {
        let picked = names.sorted().flatMap { lists[$0] ?? [] }
        let typed = extra.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
        return canonicalRules(picked + typed).valid
    }

    // MARK: updates from the monitor

    func update(status: Status?) {
        if let status {
            self.status = status
            daemonReachable = true
        } else {
            daemonReachable = false
        }
        let ax = Permissions.accessibilityGranted
        if ax != accessibilityGranted { accessibilityGranted = ax }
    }

    func refreshPermissions() {
        accessibilityGranted = Permissions.accessibilityGranted
        let installed = Permissions.installedBrowsers()
        queue.async { [weak self] in
            let checked = installed.map {
                BrowserPermission(bundleID: $0.bundleID, name: $0.name, icon: $0.icon, kind: $0.kind,
                                  state: $0.kind == .firefox ? .allowed : Permissions.automationState(bundleID: $0.bundleID, ask: false))
            }
            DispatchQueue.main.async { self?.browsers = checked }
        }
    }

    func askAutomation(_ bundleID: String) {
        queue.async { [weak self] in
            _ = Permissions.automationState(bundleID: bundleID, ask: true)
            DispatchQueue.main.async { self?.refreshPermissions() }
        }
    }

    func reloadLists() { lists = ListStore.all() }

    // MARK: daemon commands

    func start(minutes: Int, rules: [String], completion: ((Bool) -> Void)? = nil) {
        send(Request(cmd: .start, durationSeconds: minutes * 60, rules: rules), completion: completion)
    }

    func extend(minutes: Int) {
        send(Request(cmd: .extend, durationSeconds: minutes * 60))
    }

    func add(rules: [String], completion: ((Bool) -> Void)? = nil) {
        send(Request(cmd: .add, rules: rules), completion: completion)
    }

    // MARK: alerts and uninstall request

    var alertURL: String? { status?.alertURL }

    /// The pending uninstall request, if it hasn't expired.
    var uninstallRequest: UninstallStatus? {
        guard let u = status?.uninstall, u.expiresAt > now else { return nil }
        return u
    }

    var uninstallUnlocked: Bool {
        guard let u = uninstallRequest else { return false }
        return u.unlocksAt <= now
    }

    func setAlerts(_ url: String?, completion: ((Bool) -> Void)? = nil) {
        send(Request(cmd: .setAlerts, alertURL: url), completion: completion)
    }

    func testAlert() {
        send(Request(cmd: .testAlert))
    }

    func requestUninstall() {
        send(Request(cmd: .requestUninstall))
    }

    func cancelUninstall() {
        send(Request(cmd: .cancelUninstall))
    }

    /// Sync status right away (used after the window opens).
    var requestSync: (() -> Void)?

    private func send(_ request: Request, completion: ((Bool) -> Void)? = nil) {
        if isLocalTest {
            errorMessage = "This is a local test run without the Renew service, so sessions can't be changed."
            completion?(false)
            return
        }
        busy = true
        queue.async { [weak self] in
            let result = Result { try DaemonClient.send(request) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let r):
                    if let s = r.status { self.status = s; self.daemonReachable = true }
                    if !r.ok { self.errorMessage = r.error ?? "Renew refused the request." }
                    completion?(r.ok)
                case .failure(let e):
                    self.errorMessage = String(describing: e)
                    completion?(false)
                }
            }
        }
    }

    // MARK: install / uninstall

    func install() {
        busy = true
        queue.async { [weak self] in
            let result = Privileged.install()
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch result {
                case .success:
                    // launchd has started the installed copy; hand over to it.
                    relaunchInstalledCopyAndQuit()
                case .failure(.cancelled):
                    break
                case .failure(let e):
                    self.errorMessage = "Install failed: \(e.localizedDescription)"
                }
            }
        }
    }

    func uninstall() {
        busy = true
        queue.async { [weak self] in
            let result = Privileged.uninstall()
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    // On success the uninstaller stops this app. If we're still alive
                    // after a few seconds, something went wrong.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        self.busy = false
                        let log = (try? String(contentsOfFile: Paths.uninstallLog, encoding: .utf8)) ?? ""
                        if !self.isInstalled {
                            NSApp.terminate(nil)
                        } else {
                            self.errorMessage = "Uninstall didn't finish.\n\(log.suffix(400))"
                        }
                    }
                case .failure(.cancelled):
                    self.busy = false
                case .failure(let e):
                    self.busy = false
                    self.errorMessage = "Uninstall failed: \(e.localizedDescription)"
                }
            }
        }
    }
}

func relaunchInstalledCopyAndQuit() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "sleep 1.5; /usr/bin/open \(Privileged.shellQuote(Paths.agentApp))"]
    try? p.run()
    NSApp.terminate(nil)
}
