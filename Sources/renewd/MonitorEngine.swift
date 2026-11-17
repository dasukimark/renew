import Foundation
import RenewShared

/// The Monitor: checks each user's new visits against their
/// `MonitorSettings` and hands back what to flag. Runs inside renewd, so what
/// gets flagged doesn't depend on the app.
///
/// Called only on renewd's state queue (`queue`). The explicit-site list is
/// large, so it's read on another queue; visits that need it wait (in
/// memory) until it's ready rather than going unchecked.
final class MonitorEngine {
    /// Called on `queue` with flags found later, for visits that waited for
    /// the explicit-site list.
    var deliver: ((uid_t, [MonitorFlag]) -> Void)?

    private let dev: Bool
    private let queue: DispatchQueue
    private let loadQueue = DispatchQueue(label: "renewd.explicit-list", qos: .utility)
    /// Built when first needed and dropped by `invalidate` when a user's
    /// settings change, so checking a batch never compares whole settings.
    private var matchers: [uid_t: ActivityMatcher] = [:]

    private enum ExplicitState {
        case notLoaded
        case loading
        case loaded(DomainSet)
        /// The file couldn't be read; tried again after `retryAfter`.
        case failed(at: Date)
    }
    private var explicit: ExplicitState = .notLoaded
    private static let retryAfter: TimeInterval = 60
    /// Visits waiting for the explicit-site list.
    private var waiting: [(uid: uid_t, settings: MonitorSettings, events: [ActivityEvent])] = []
    private static let maxWaiting = 5_000

    init(dev: Bool, queue: DispatchQueue) {
        self.dev = dev
        self.queue = queue
    }

    /// Starts reading the explicit-site list if anyone watches it, so the
    /// first visits after startup don't wait.
    func prepare(watchingExplicit: Bool) {
        if watchingExplicit { startLoadingExplicit(now: Date()) }
    }

    /// The flags for each of `events` that matches `settings`. Visits that
    /// need the explicit-site list while it's still loading are kept and
    /// their flags handed to `deliver` once it's ready.
    func evaluate(_ events: [ActivityEvent], settings: MonitorSettings, uid: uid_t, now: Date = Date()) -> [MonitorFlag] {
        guard settings.enabled, !events.isEmpty else { return [] }
        if settings.watchLists.contains(MonitorSettings.explicitListName) {
            startLoadingExplicit(now: now)
            if case .loading = explicit {
                let room = Self.maxWaiting - waiting.reduce(0) { $0 + $1.events.count }
                if room > 0 { waiting.append((uid, settings, Array(events.prefix(room)))) }
                if room < events.count { log("monitor: too many visits waiting for the explicit-site list; checking some without it") }
                guard room < events.count else { return [] }
                return check(Array(events.dropFirst(max(0, room))), settings: settings, uid: uid, now: now)
            }
        }
        return check(events, settings: settings, uid: uid, now: now)
    }

    /// Drops `uid`'s cached matcher (their settings changed).
    func invalidate(_ uid: uid_t) { matchers[uid] = nil }

    private func check(_ events: [ActivityEvent], settings: MonitorSettings, uid: uid_t, now: Date) -> [MonitorFlag] {
        let matcher = self.matcher(for: uid, settings: settings)
        guard !matcher.isEmpty else { return [] }
        return events.compactMap { e in
            let flags = matcher.flags(url: e.url, title: e.title)
            return flags.isEmpty ? nil : MonitorFlag(event: e, flags: flags, flaggedAt: now)
        }
    }

    private func matcher(for uid: uid_t, settings: MonitorSettings) -> ActivityMatcher {
        if let m = matchers[uid] { return m }
        var domains: DomainSet?
        if case .loaded(let set) = explicit { domains = set }
        let m = ActivityMatcher(settings: settings, explicitDomains: domains)
        // Without the list (it failed to load), don't cache, so it's used once it loads.
        if domains != nil || !settings.watchLists.contains(MonitorSettings.explicitListName) { matchers[uid] = m }
        return m
    }

    // MARK: explicit-site list

    private func startLoadingExplicit(now: Date) {
        switch explicit {
        case .loading, .loaded: return
        case .failed(let at) where now.timeIntervalSince(at) < Self.retryAfter: return
        case .notLoaded, .failed: break
        }
        explicit = .loading
        let candidates = explicitCandidates()
        loadQueue.async { [weak self] in
            var set: DomainSet?
            for path in candidates {
                if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                    set = DomainSet(fileContents: text)
                    break
                }
            }
            self?.queue.async { self?.finishedLoading(set) }
        }
    }

    private func finishedLoading(_ set: DomainSet?) {
        if let set {
            explicit = .loaded(set)
            log("monitor: explicit-site list has \(set.count) domains")
        } else {
            explicit = .failed(at: Date())
            log("monitor: explicit-site list not found at \(Paths.explicitListFile); explicit sites aren't flagged until it is (tried again every minute)")
        }
        // Matchers built while it was loading lack it.
        matchers.removeAll()
        let held = waiting
        waiting.removeAll()
        let now = Date()
        for item in held {
            let flags = check(item.events, settings: item.settings, uid: item.uid, now: now)
            if !flags.isEmpty { deliver?(item.uid, flags) }
        }
    }

    /// The install folder's copy, or for `--dev` runs the repository's.
    private func explicitCandidates() -> [String] {
        var candidates = [Paths.explicitListFile]
        if dev {
            candidates.append(FileManager.default.currentDirectoryPath + "/Resources/explicit-domains.txt")
            // .build/<config>/renewd → repository root.
            let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            candidates.append(exe.deletingLastPathComponent()
                .appendingPathComponent("../../../Resources/explicit-domains.txt").standardized.path)
        }
        return candidates
    }
}
