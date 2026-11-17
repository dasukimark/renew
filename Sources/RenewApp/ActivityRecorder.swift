import Foundation
import RenewShared

/// Turns what the browser watcher sees into visits and hands finished visits
/// to renewd in batches. It doesn't judge them: renewd's Monitor does that
/// as they arrive. Main thread only.
final class ActivityRecorder {
    enum Channel: String {
        /// The active tab of the frontmost browser.
        case browser
        /// Websites in the built-in browser of the frontmost app.
        case embedded
    }

    /// A page as a reader saw it.
    struct Seen {
        var source: String
        var browser: String
        var url: String
        var title: String
        var blocked = false
    }

    var settings: ActivitySettings = .off {
        didSet {
            guard settings != oldValue else { return }
            if !settings.enabled { finish(tracker.closeAll(at: Date())) }
        }
    }

    /// Without renewd (local test runs): log visits instead of sending them.
    private let localOnly: Bool
    private let link: DaemonLink
    /// Short visits are sent too: the Monitor checks them (a quick look at a
    /// watched site still counts), and renewd leaves them out of the log.
    private var tracker = VisitTracker(minDuration: 0)
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
        pending = Self.loadPending()
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.send() }
    }

    var enabled: Bool { settings.enabled }

    /// Everything `channel` shows right now (empty if nothing).
    func observe(_ channel: Channel, _ pages: [Seen]) {
        guard settings.enabled else { return }
        let observations = pages.map {
            PageObservation(source: $0.source, browser: $0.browser, url: $0.url, title: $0.title, blocked: $0.blocked)
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

    // MARK: sending

    private func finish(_ finished: [ActivityEvent]) {
        // Capped here as renewd would, so batches stay small enough to send.
        let events = finished.compactMap { $0.sanitized() }
        guard !events.isEmpty else { return }
        if localOnly {
            for e in events {
                log("visit: \(Int(e.duration))s \(e.browser) \(e.url) “\(e.title)”\(e.blocked ? " [Blocked]" : "")")
            }
            return
        }
        pending.append(contentsOf: events)
        if pending.count > Self.maxPending {
            // Keep blocked visits over ordinary ones when there's too much to hold.
            let overflow = pending.count - Self.maxPending
            var dropped = 0
            pending.removeAll { e in
                guard dropped < overflow, !e.blocked else { return false }
                dropped += 1
                return true
            }
            if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
        }
        if events.contains(where: \.blocked) { send() }
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
