import AppKit
import Combine
import RenewShared

/// Everything the UI shows, kept on the main thread.
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case sessions = "Block Sessions"
        case quick = "Quick Block"
        case lists = "Blocklists"
        case setup = "Setup"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .sessions: return "calendar.badge.clock"
            case .quick: return "bolt"
            case .lists: return "list.bullet.rectangle"
            case .setup: return "gearshape"
            }
        }
    }

    @Published var section: Section = .sessions
    @Published private(set) var status: Status?
    @Published private(set) var daemonReachable = false
    @Published private(set) var now = Date()
    @Published private(set) var lists: [String: [String]] = ListStore.all() {
        didSet { recomputeDerived() }
    }
    @Published private(set) var accessibilityGranted = Permissions.accessibilityGranted
    @Published private(set) var browsers: [BrowserPermission] = []
    @Published private(set) var savedSessions: [BlockSession] = BlockSessionStore.all() {
        didSet { recomputeDerived() }
    }
    /// Each saved session's sites, resolved against `lists`. Cached because
    /// the views redraw every second.
    private(set) var sessionRules: [UUID: [String]] = [:]
    /// The schedules the daemon should enforce, from the saved sessions.
    private(set) var desiredSchedules: [Schedule] = []
    @Published var busy = false
    @Published var errorMessage: String?

    /// Lists ticked for a quick start, remembered between launches.
    @Published var selectedLists: Set<String> {
        didSet { UserDefaults.standard.set(Array(selectedLists), forKey: "selectedLists") }
    }
    @Published var durationMinutes: Int {
        didSet { UserDefaults.standard.set(durationMinutes, forKey: "durationMinutes") }
    }

    let isLocalTest: Bool
    private let queue = DispatchQueue(label: "app.model")
    private var clock: Timer?
    private var scheduleSyncInFlight = false
    /// The last schedules that failed to sync, and when. Retried after
    /// `syncRetryInterval` (or sooner if they change or the service
    /// reconnects), so a fixed service still gets them.
    private var failedSync: (schedules: [Schedule], at: Date)?
    /// The schedules an error was last shown for, so retries don't nag.
    private var reportedSyncError: [Schedule]?
    private let syncRetryInterval: TimeInterval = 30
    /// Modification dates of lists.json and sessions.json, to pick up edits
    /// made elsewhere (e.g. `renew lists add`).
    private var listsFileDate: Date?
    private var sessionsFileDate: Date?

    init(isLocalTest: Bool) {
        self.isLocalTest = isLocalTest
        let saved = UserDefaults.standard.stringArray(forKey: "selectedLists") ?? ["social"]
        selectedLists = Set(saved)
        let minutes = UserDefaults.standard.integer(forKey: "durationMinutes")
        durationMinutes = minutes > 0 ? minutes : 60
        listsFileDate = Self.modificationDate(ListStore.fileURL)
        sessionsFileDate = Self.modificationDate(BlockSessionStore.fileURL)
        recomputeDerived()
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
        return canonicalRules(picked + parseSites(extra)).valid
    }

    // MARK: updates from the monitor

    func update(status: Status?) {
        if let status {
            self.status = status
            if !daemonReachable { failedSync = nil } // reconnected: retry right away
            daemonReachable = true
            reloadIfFilesChanged()
            syncSchedules()
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

    func reloadLists() {
        listsFileDate = Self.modificationDate(ListStore.fileURL)
        let fresh = ListStore.all()
        if fresh != lists { lists = fresh }
        syncSchedules()
    }

    private func reloadIfFilesChanged() {
        if Self.modificationDate(ListStore.fileURL) != listsFileDate { reloadLists() }
        if Self.modificationDate(BlockSessionStore.fileURL) != sessionsFileDate { reloadSessions() }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func recomputeDerived() {
        var rules: [UUID: [String]] = [:]
        for s in savedSessions { rules[s.id] = s.rules(in: lists) }
        sessionRules = rules
        desiredSchedules = savedSessions.compactMap { $0.schedule(in: lists) }
    }

    // MARK: saved block sessions

    func reloadSessions() {
        sessionsFileDate = Self.modificationDate(BlockSessionStore.fileURL)
        let fresh = BlockSessionStore.all()
        if fresh != savedSessions { savedSessions = fresh }
        syncSchedules()
    }

    /// A saved session's sites, given the current blocklists.
    func rules(for session: BlockSession) -> [String] {
        sessionRules[session.id] ?? session.rules(in: lists)
    }

    /// Enabled schedules that can't run because they have nothing to block
    /// (e.g. their blocklist was deleted or emptied).
    var schedulesWithNothingToBlock: [BlockSession] {
        savedSessions.filter { $0.isScheduled && $0.enabled && rules(for: $0).isEmpty }
    }

    func saveSession(_ session: BlockSession) {
        var s = session
        s.name = String(s.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Schedule.maxNameLength))
        do {
            savedSessions = try BlockSessionStore.upsert(s)
            sessionsFileDate = Self.modificationDate(BlockSessionStore.fileURL)
        } catch {
            errorMessage = "Couldn't save the block session: \(error.localizedDescription)"
        }
        syncSchedules()
    }

    func deleteSession(_ id: UUID) {
        do {
            savedSessions = try BlockSessionStore.delete(id)
            sessionsFileDate = Self.modificationDate(BlockSessionStore.fileURL)
        } catch {
            errorMessage = "Couldn't delete the block session: \(error.localizedDescription)"
        }
        syncSchedules()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard var s = savedSessions.first(where: { $0.id == id }) else { return }
        s.enabled = enabled
        saveSession(s)
    }

    /// Starts a length-based saved session now.
    func start(_ session: BlockSession, completion: ((Bool) -> Void)? = nil) {
        guard case let .length(minutes) = session.timing else { return }
        start(minutes: minutes, rules: rules(for: session), completion: completion)
    }

    /// Whether `session` is a schedule whose window is open right now, so
    /// turning it on (or saving it) starts blocking at once.
    func opensNow(_ session: BlockSession) -> Bool {
        guard case let .schedule(window, days) = session.timing else { return false }
        return Schedule(name: session.name, window: window, days: days, rules: []).activeWindowEnd(at: Date()) != nil
    }

    /// The daemon's copy of a saved schedule, if it's enforcing it.
    func enforcedSchedule(_ id: UUID) -> Schedule? { status?.schedules?.first { $0.id == id } }

    /// Sends the saved schedules to the daemon if its copy differs.
    func syncSchedules() {
        guard !isLocalTest, daemonReachable, let status, !scheduleSyncInFlight else { return }
        let desired = desiredSchedules
        guard desired != (status.schedules ?? []) else { return }
        if let f = failedSync, f.schedules == desired, Date().timeIntervalSince(f.at) < syncRetryInterval { return }
        scheduleSyncInFlight = true
        queue.async { [weak self] in
            let result = Result { try DaemonClient.send(Request(cmd: .setSchedules, schedules: desired)) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.scheduleSyncInFlight = false
                switch result {
                case .success(let r):
                    if let s = r.status { self.status = s }
                    if r.ok && (r.status?.schedules ?? []) == desired {
                        self.failedSync = nil
                        self.reportedSyncError = nil
                    } else {
                        self.failedSync = (desired, Date())
                        let why = r.ok ? "it stored them differently" : (r.error ?? "unknown error")
                        self.reportSyncError(desired, "The Renew service didn't accept your scheduled block sessions: \(why). If Renew was just updated, reinstall it from Setup.")
                    }
                case .failure(let e):
                    self.failedSync = (desired, Date())
                    self.reportSyncError(desired, "Couldn't send your scheduled block sessions to the Renew service: \(e)")
                }
                // Something may have changed while the request was out.
                if self.desiredSchedules != desired { self.syncSchedules() }
            }
        }
    }

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

    // MARK: protections

    /// The hardening features in force (all off unless turned on).
    var protections: Protections { status?.protections ?? .off }

    /// What the user wants: the cooling-off reads as off once its removal has
    /// been asked for. Changes are built on this, so they don't cancel that.
    var requestedProtections: Protections { status?.requestedProtections ?? .off }

    /// False if the running service predates protections.
    var protectionsSupported: Bool { status?.protections != nil }

    /// When the uninstall cooling-off turns off, if someone asked for that.
    var coolingOffRemovalAt: Date? { status?.coolingOffRemovalAt }

    func setProtections(_ p: Protections, completion: ((Bool) -> Void)? = nil) {
        send(Request(cmd: .setProtections, protections: p), completion: completion)
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

    private func reportSyncError(_ schedules: [Schedule], _ message: String) {
        guard reportedSyncError != schedules else { return }
        reportedSyncError = schedules
        errorMessage = message
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
