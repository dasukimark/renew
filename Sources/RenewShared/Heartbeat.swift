import Foundation

/// A check-in with the report server. While email reports are on, renewd
/// sends one about every `interval` (± `jitter`), and also when the Mac goes
/// to sleep, wakes, or renewd stops. The server emails the partner when
/// check-ins stop without warning (see `server/reports/`):
///
/// - `awake` and then silence for 2 hours: Renew was removed, or the Mac
///   has been awake but offline (or lost power). Time renewd wasn't running
///   is reported by the internal heartbeat once it runs again, so this is
///   only the dead man's switch.
/// - `stopping` and then silence for 3 minutes.
/// - `sleeping` or `shutdown` and then silence for 7 days.
/// - `shutdown`, then back without the Mac having restarted: the service
///   was stopped, not the Mac.
///
/// Each check-in also carries the downtime renewd's internal heartbeat
/// found (`gaps`, see `AliveRecord`), which the server emails right away.
///
/// `removed` asks the server to end monitoring (reports turned off, moved,
/// or Renew uninstalled). `witness` carries gaps independently of renewd.
public struct Heartbeat: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case awake, sleeping, shutdown, stopping, removed, witness, monitoringStatus, requestRemoval
    }

    public var kind: String = "heartbeat"
    public var id: UUID
    /// This Mac's Renew install (`PersistedState.installID`), so the server
    /// tracks it across restarts and partner changes.
    public var install: UUID
    /// The partners, the Mac's name, the user and the time zone: sent only
    /// when renewd starts, when one of them changes, or when the server asks
    /// (`HeartbeatReply.needDetails`). The server keeps them in between.
    public var to: Recipients?
    public var mac: String?
    public var user: String?
    public var timeZone: String?
    public var sentAt: Date
    public var state: State
    /// When the Mac last booted. Shown in emails; moves if the clock is set.
    public var boot: Date
    /// `kern.bootsessionuuid`: changes on every boot and only then, so the
    /// server can tell a restart from the service being stopped.
    public var bootID: String?
    /// This renewd process's lifetime, independent of the Mac's boot.
    public var runID: UUID?
    /// Keep an existing enrollment alive without creating or changing one.
    public var monitoringOnly: Bool?
    /// This client submits recipient removals separately from check-ins.
    public var explicitPartnerRemovals: Bool?
    public var removingPartners: [String]?
    /// Seconds until the next check-in, roughly.
    public var interval: Int
    /// When the server last accepted a check-in from this Mac.
    public var lastAccepted: Date?
    /// Time the Mac was awake without renewd running, not yet taken by the server.
    public var gaps: [DowntimeGap]?
    /// Since when renewd has been running whenever the Mac was awake.
    public var coveredSince: Date?

    /// Check-ins only need to show the server Renew is still there (its
    /// silence wait is 2 hours); downtime goes out as soon as it's found
    /// (see `Heartbeater`), not on this schedule.
    public static let interval: TimeInterval = 900
    public static let jitter: TimeInterval = 120
    /// The wait before trying again after a check-in fails.
    public static let retryDelay: TimeInterval = 60
    /// How recently the app must have said the Mac is powering off for a
    /// SIGTERM to count as a shutdown.
    public static let poweringOffWindow: TimeInterval = 90
    /// A restart that follows renewd stopping this closely counts as the
    /// Mac restarting, even without a shutdown notice (see `AliveRecord.assess`).
    public static let restartWindow: TimeInterval = 180

    public init(id: UUID = UUID(), install: UUID, to: Recipients?, mac: String?, user: String?,
                timeZone: String? = TimeZone.current.identifier, sentAt: Date, state: State,
                boot: Date, interval: Int = Int(Heartbeat.interval), lastAccepted: Date? = nil,
                gaps: [DowntimeGap]? = nil, coveredSince: Date? = nil, runID: UUID? = nil) {
        self.gaps = gaps
        self.coveredSince = coveredSince
        self.bootID = ClockReading.bootID
        self.runID = runID
        self.id = id
        self.install = install
        self.to = to
        self.mac = mac
        self.user = user
        self.timeZone = timeZone
        self.sentAt = sentAt
        self.state = state
        self.boot = boot
        self.interval = interval
        self.lastAccepted = lastAccepted
    }

    /// The wait until the next check-in: `interval` ± `jitter`, for
    /// `random` in 0...1.
    public static func nextDelay(random: Double = Double.random(in: 0...1)) -> TimeInterval {
        interval + (min(max(random, 0), 1) * 2 - 1) * jitter
    }

    /// What to tell the server when renewd is stopped: `shutdown` if the app
    /// said the Mac is powering off within `poweringOffWindow` (uptime
    /// seconds), or no one is logged in (a shutdown from the login window,
    /// where there's no app to say so), otherwise `stopping`.
    public static func terminationState(poweringOffAt: TimeInterval?, now: TimeInterval,
                                        nobodyLoggedIn: Bool = false) -> State {
        if nobodyLoggedIn { return .shutdown }
        guard let p = poweringOffAt, now >= p, now - p <= poweringOffWindow else { return .stopping }
        return .shutdown
    }

    /// Whether the keyboard or mouse was used after the Mac went to sleep,
    /// so it's in use even if macOS never said it woke. Dark wakes have no
    /// input. `idle` is the time since the last input; it must be under
    /// `inputWindow`, and the input must have come more than `inputWindow`
    /// (awake-clock) seconds after the sleep itself, which follows "will
    /// sleep" within `sleepWait`.
    public static func inUseSinceSleep(awakeSinceSleep: TimeInterval, sleepWait: TimeInterval, idle: TimeInterval?) -> Bool {
        guard let idle else { return false }
        return awakeSinceSleep > sleepWait + inputWindow && idle < inputWindow
    }

    public static let inputWindow: TimeInterval = 10

    /// When the Mac booted, to the second.
    public static func bootTime() -> Date {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return Date(timeIntervalSince1970: 0) }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    /// Who and what a check-in is about. Sent only when it changes.
    public struct Details: Equatable, Sendable {
        public var to: [String]
        public var mac: String
        public var user: String
        public var timeZone: String

        public init(to: [String], mac: String, user: String, timeZone: String = TimeZone.current.identifier) {
            self.to = to
            self.mac = mac
            self.user = user
            self.timeZone = timeZone
        }
    }

    /// A check-in. With `details`, it names the partner, Mac and user.
    public static func make(_ state: State, install: UUID, details: Details?,
                            lastAccepted: Date?, now: Date = Date(), interval: TimeInterval = Heartbeat.interval,
                            gaps: [DowntimeGap]? = nil, coveredSince: Date? = nil, runID: UUID? = nil) -> Heartbeat {
        Heartbeat(install: install, to: details.map { Recipients($0.to) }, mac: details?.mac, user: details?.user,
                  timeZone: details?.timeZone, sentAt: now,
                  state: state, boot: bootTime(), interval: Int(interval.rounded()), lastAccepted: lastAccepted,
                  gaps: gaps.flatMap { $0.isEmpty ? nil : $0 }, coveredSince: coveredSince, runID: runID)
    }
}

/// What the server says back to a check-in: the emails it sent the partner
/// about this Mac since the last check-in it accepted.
public struct HeartbeatReply: Codable, Equatable, Sendable {
    public struct Monitoring: Codable, Equatable, Sendable {
        public var partners: [String]
        public var removalPending: Bool
        public var rejectedDecision: UUID?
        public var pendingPartners: [String]?
        /// Enrolled partners who haven't confirmed by email yet.
        public var unconfirmed: [String]?
        /// Partners the server dropped without approval: they never
        /// confirmed (or declined), so renewd drops them too.
        public var released: [String]?
    }
    /// The server's view of partner confirmations; nil from servers that
    /// predate them, or when every partner has confirmed and none was released.
    public struct PartnerStatus: Codable, Equatable, Sendable {
        public var unconfirmed: [String]?
        public var released: [String]?

        public init(unconfirmed: [String]? = nil, released: [String]? = nil) {
            self.unconfirmed = unconfirmed
            self.released = released
        }
    }
    public struct Notice: Codable, Equatable, Sendable {
        public var title: String
        public var lines: [String]
        public var at: Date

        public init(title: String, lines: [String], at: Date) {
            self.title = title
            self.lines = lines
            self.at = at
        }
    }

    public var notices: [Notice]
    /// The server doesn't know this Mac (yet): send the details next time.
    public var needDetails: Bool?
    /// Read-only server monitoring state, independent of daemon liveness.
    public var monitoring: Monitoring?
    /// Partner confirmations, on replies to ordinary check-ins.
    public var partners: PartnerStatus?

    public init(notices: [Notice], needDetails: Bool? = nil) {
        self.notices = notices
        self.needDetails = needDetails
    }

    /// Server dates may carry fractional seconds, which the plain ISO 8601
    /// decoder refuses.
    public static func decode(_ data: Data) -> HeartbeatReply? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            if let date = f.date(from: text) { return date }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
        }
        return try? d.decode(HeartbeatReply.self, from: data)
    }
}

public enum HeartbeatClient {
    /// Sends `beat` to `server`. `done` gets the outcome and, when
    /// delivered, the server's reply (nil if it didn't send one).
    public static func post(_ beat: Heartbeat, to server: ReportServer, timeout: TimeInterval = 20,
                            done: @escaping @Sendable (ReportClient.Outcome, HeartbeatReply?) -> Void) {
        guard let body = try? Report.encoder.encode(beat) else { return done(.rejected(0), nil) }
        let state = beat.state.rawValue
        ReportClient.post(json: body, to: server, timeout: timeout) { outcome, code, data, error in
            if let error {
                log("heartbeat: sending '\(state)' failed: \(error.localizedDescription)")
            } else if outcome != .delivered {
                log("heartbeat: sending '\(state)' failed: HTTP \(code)")
            }
            done(outcome, data.flatMap(HeartbeatReply.decode))
        }
    }

    /// Sends `beat` and waits up to `timeout` seconds. Returns whether the
    /// server took it. For use right before exiting.
    @discardableResult
    public static func sendAndWait(_ beat: Heartbeat, to server: ReportServer, timeout: TimeInterval = 5) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        let box = Box()
        post(beat, to: server, timeout: timeout) { outcome, _ in
            box.set(outcome == .delivered)
            sem.signal()
        }
        guard sem.wait(timeout: .now() + timeout) == .success else { return false }
        return box.get()
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}
