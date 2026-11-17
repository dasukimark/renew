import Foundation
import RenewShared

/// The bundled explicit-site list (`Resources/explicit-domains.txt`). Loaded
/// once, off the main thread, the first time something needs it.
enum ExplicitDomains {
    private static let queue = DispatchQueue(label: "agent.explicit-domains", qos: .utility)
    private static var loaded: DomainSet?
    private static var waiting: [(DomainSet) -> Void] = []
    private static var loading = false

    /// The set, if it's been loaded. Main thread only.
    static var current: DomainSet? { loaded }

    /// Calls `completion` on the main thread with the set, loading it if needed.
    static func load(_ completion: @escaping (DomainSet) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let loaded { completion(loaded); return }
        waiting.append(completion)
        guard !loading else { return }
        loading = true
        queue.async {
            let set = DomainSet(fileContents: readFile() ?? "")
            DispatchQueue.main.async {
                loaded = set
                loading = false
                log("explicit-site list: \(set.count) domains")
                let callbacks = waiting
                waiting.removeAll()
                callbacks.forEach { $0(set) }
            }
        }
    }

    /// The app bundle's copy, or the repository's for `swift run` dev runs.
    private static func readFile() -> String? {
        var candidates: [URL] = []
        if let u = Bundle.main.url(forResource: "explicit-domains", withExtension: "txt") { candidates.append(u) }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Resources/explicit-domains.txt"))
        // .build/<config>/RenewApp → repository root.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(exe.deletingLastPathComponent().appendingPathComponent("../../../Resources/explicit-domains.txt").standardized)
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        }
        log("explicit-site list not found; the explicit preset flags nothing")
        return nil
    }
}

/// Turns what the monitor sees into visits, flags them, and hands finished
/// visits to renewd in batches. Main thread only.
final class ActivityRecorder {
    enum Channel: String {
        /// The active tab of the frontmost browser.
        case browser
        /// Websites in the built-in browser of the frontmost app.
        case embedded
    }

    /// A page as a reader saw it, before matching.
    struct Seen {
        var source: String
        var browser: String
        var url: String
        var title: String
        var blocked = false
    }

    var settings: MonitoringSettings = .off {
        didSet {
            guard settings != oldValue else { return }
            if !settings.enabled { finish(tracker.closeAll(at: Date())) }
            rebuildMatcher()
        }
    }

    /// Without renewd (local test runs): log visits instead of sending them.
    private let localOnly: Bool
    private let link: DaemonLink
    private var tracker = VisitTracker()
    private var matcher: ActivityMatcher?
    private var lists: [String: [String]] = ListStore.all()
    private var listsFileDate: Date?
    private var pending: [ActivityEvent] = []
    private var sending = false
    private var timer: Timer?

    static let maxPending = 5_000
    private static var pendingURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Renew/activity-pending.json")
    }

    init(link: DaemonLink, localOnly: Bool) {
        self.link = link
        self.localOnly = localOnly
        listsFileDate = Self.modificationDate(ListStore.fileURL)
        pending = Self.loadPending()
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
    }

    var enabled: Bool { settings.enabled }

    /// Everything `channel` shows right now (empty if nothing).
    func observe(_ channel: Channel, _ pages: [Seen]) {
        guard settings.enabled else { return }
        let matcher = self.matcher ?? rebuildMatcher()
        let observations = pages.map {
            PageObservation(source: $0.source, browser: $0.browser, url: $0.url, title: $0.title,
                            flags: matcher.flags(url: $0.url, title: $0.title), blocked: $0.blocked)
        }
        finish(tracker.observe(observations, channel: channel.rawValue, at: Date()))
    }

    /// The user went idle or locked the screen at `leftAt`: open visits end
    /// then, so the idle minutes before Renew noticed don't count.
    func away(since leftAt: Date) {
        guard tracker.openCount > 0 else { return }
        finish(tracker.closeAll(at: leftAt))
    }

    /// Renew is quitting: end open visits and keep unsent ones for next time.
    func shutdown() {
        finish(tracker.closeAll(at: Date()))
        if !localOnly { Self.savePending(pending) }
    }

    // MARK: matching

    @discardableResult
    private func rebuildMatcher() -> ActivityMatcher {
        let wantsExplicit = settings.watchLists.contains(MonitoringSettings.explicitListName)
        let m = ActivityMatcher(settings: settings, lists: lists, explicitDomains: wantsExplicit ? ExplicitDomains.current : nil)
        matcher = m
        if settings.enabled && wantsExplicit && ExplicitDomains.current == nil {
            ExplicitDomains.load { [weak self] _ in self?.rebuildMatcher() }
        }
        return m
    }

    private func reloadListsIfChanged() {
        let date = Self.modificationDate(ListStore.fileURL)
        guard date != listsFileDate else { return }
        listsFileDate = date
        lists = ListStore.all()
        rebuildMatcher()
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: sending

    private func finish(_ finished: [ActivityEvent]) {
        // Capped here as renewd would, so batches stay small enough to send.
        let events = finished.compactMap { $0.sanitized() }
        guard !events.isEmpty else { return }
        if localOnly {
            for e in events {
                let flags = e.flags.map(\.label) + (e.blocked ? ["Blocked"] : [])
                log("visit: \(Int(e.duration))s \(e.browser) \(e.url) “\(e.title)”\(flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]")")
            }
            return
        }
        pending.append(contentsOf: events)
        if pending.count > Self.maxPending {
            // Keep flagged visits over ordinary ones when there's too much to hold.
            let overflow = pending.count - Self.maxPending
            var dropped = 0
            pending.removeAll { e in
                guard dropped < overflow, !e.isFlagged else { return false }
                dropped += 1
                return true
            }
            if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
        }
        if events.contains(where: \.isFlagged) { send() }
    }

    private func tick() {
        reloadListsIfChanged()
        send()
    }

    /// Keeps each request well under renewd's 1 MB limit.
    static let maxBatchBytes = 256 << 10

    private func nextBatch() -> [ActivityEvent] {
        var batch: [ActivityEvent] = []
        var bytes = 0
        let encoder = Wire.encoder
        for e in pending.prefix(ActivityLogStore.maxEventsPerRequest) {
            let size = (try? encoder.encode(e).count) ?? 0
            if !batch.isEmpty && bytes + size > Self.maxBatchBytes { break }
            batch.append(e)
            bytes += size
        }
        return batch
    }

    private func send() {
        guard !localOnly, !sending, !pending.isEmpty else { return }
        let batch = nextBatch()
        sending = true
        link.record(batch) { [weak self] result in
            guard let self else { return }
            self.sending = false
            var done = false
            switch result {
            case .stored:
                done = true
            case .rejected(let why):
                // Retrying the same batch would block every visit behind it.
                log("activity: renewd refused \(batch.count) visit(s) (\(why)); dropping them")
                done = true
            case .unreachable:
                break
            }
            if done {
                // Trimming an overflow while the batch was out may have moved it.
                if self.pending.starts(with: batch) {
                    self.pending.removeFirst(batch.count)
                } else {
                    self.pending.removeAll { batch.contains($0) }
                }
                Self.savePending(self.pending)
                if !self.pending.isEmpty { self.send() }
            } else {
                Self.savePending(self.pending)
            }
        }
    }

    private static func loadPending() -> [ActivityEvent] {
        guard let data = try? Data(contentsOf: pendingURL),
              let events = try? Wire.decoder.decode([ActivityEvent].self, from: data) else { return [] }
        return Array(events.suffix(maxPending))
    }

    private static func savePending(_ events: [ActivityEvent]) {
        if events.isEmpty {
            try? FileManager.default.removeItem(at: pendingURL)
            return
        }
        guard let data = try? Wire.encoder.encode(events) else { return }
        try? FileManager.default.createDirectory(at: pendingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: pendingURL, options: .atomic)
    }
}
