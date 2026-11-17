import Foundation

/// Newline-delimited JSON over the daemon's Unix socket.
///
/// The daemon only accepts commands that make things stricter: nothing here
/// can shorten, stop or loosen a running session. Alerts can only be changed
/// between sessions (or turned on during one), and an uninstall request only
/// unlocks `sudo renew uninstall` after a cooling-off period. Each user has
/// their own activity monitoring settings and log, and only ever reads and
/// changes their own.
public enum Command: String, Codable, Sendable {
    case status, start, extend, add, report
    case setAlerts, testAlert
    case requestUninstall, cancelUninstall
    /// Replaces the recurring block sessions the daemon starts on its own.
    case setSchedules
    /// Changes the optional hardening features (see `Protections`).
    case setProtections
    /// Changes what activity monitoring watches (see `MonitoringSettings`).
    case setMonitoring
    /// Stores finished page visits in the caller's activity log.
    case recordActivity
    /// Reads the caller's activity log (see `ActivityQuery`).
    case activity
    /// Reads the caller's per-site daily totals (see `ActivityStatsQuery`).
    case activityStats
}

public struct AgentReport: Codable, Sendable {
    public var permissionsOK: Bool
    public var problem: String?
    public init(permissionsOK: Bool, problem: String?) {
        self.permissionsOK = permissionsOK
        self.problem = problem
    }
}

public struct Request: Codable, Sendable {
    public var cmd: Command
    public var durationSeconds: Int?
    public var rules: [String]?
    public var report: AgentReport?
    /// For `setAlerts`: the new destination, or nil to turn alerts off.
    public var alertURL: String?
    /// For `setSchedules`: the full new set.
    public var schedules: [Schedule]?
    /// For `setProtections`: the full new set.
    public var protections: Protections?
    /// For `setMonitoring`: the full new settings.
    public var monitoring: MonitoringSettings?
    /// For `recordActivity`: finished visits.
    public var events: [ActivityEvent]?
    /// For `activity`: which part of the log to read.
    public var activityQuery: ActivityQuery?
    /// For `activityStats`: which days to sum.
    public var statsQuery: ActivityStatsQuery?

    public init(cmd: Command, durationSeconds: Int? = nil, rules: [String]? = nil, report: AgentReport? = nil,
                alertURL: String? = nil, schedules: [Schedule]? = nil, protections: Protections? = nil,
                monitoring: MonitoringSettings? = nil, events: [ActivityEvent]? = nil, activityQuery: ActivityQuery? = nil,
                statsQuery: ActivityStatsQuery? = nil) {
        self.cmd = cmd
        self.durationSeconds = durationSeconds
        self.rules = rules
        self.report = report
        self.alertURL = alertURL
        self.schedules = schedules
        self.protections = protections
        self.monitoring = monitoring
        self.events = events
        self.activityQuery = activityQuery
        self.statsQuery = statsQuery
    }
}

public struct SessionInfo: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var endsAt: Date
    public var rules: [String]

    public init(startedAt: Date, endsAt: Date, rules: [String]) {
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.rules = rules
    }

    public func isActive(at now: Date = Date()) -> Bool { endsAt > now }
}

public struct AgentStatus: Codable, Sendable {
    public var uid: UInt32
    public var lastSeen: Date
    public var permissionsOK: Bool
    public var problem: String?

    public init(uid: UInt32, lastSeen: Date, permissionsOK: Bool, problem: String?) {
        self.uid = uid
        self.lastSeen = lastSeen
        self.permissionsOK = permissionsOK
        self.problem = problem
    }
}

/// Uninstalling takes two steps: a request, then `sudo renew uninstall`
/// once the cooling-off period has passed. An unused request expires.
public enum UninstallPolicy {
    public static let delay: TimeInterval = 24 * 3_600
    /// How long the uninstall stays available after it unlocks.
    public static let window: TimeInterval = 48 * 3_600
}

public struct UninstallRequest: Codable, Equatable, Sendable {
    public var requestedAt: Date
    /// Counts down to when the request expires (delay + window).
    public var countdown: Countdown

    public init(requestedAt: Date, countdown: Countdown) {
        self.requestedAt = requestedAt
        self.countdown = countdown
    }
}

public struct UninstallStatus: Codable, Equatable, Sendable {
    public var requestedAt: Date
    public var unlocksAt: Date
    public var expiresAt: Date
    public var unlocked: Bool

    public init(requestedAt: Date, unlocksAt: Date, expiresAt: Date, unlocked: Bool) {
        self.requestedAt = requestedAt
        self.unlocksAt = unlocksAt
        self.expiresAt = expiresAt
        self.unlocked = unlocked
    }
}

public struct Status: Codable, Sendable {
    public var session: SessionInfo?
    public var serverTime: Date
    public var agents: [AgentStatus]
    public var alertURL: String?
    public var uninstall: UninstallStatus?
    /// The schedules the daemon enforces. nil from daemons that predate them.
    public var schedules: [Schedule]?
    /// The hardening features in force. nil from daemons that predate them.
    public var protections: Protections?
    /// When the uninstall cooling-off turns off, if someone asked for that.
    public var coolingOffRemovalAt: Date?
    /// What activity monitoring watches for the user asking (each user has
    /// their own). nil from daemons that predate it.
    public var monitoring: MonitoringSettings?

    /// The protections as the user wants them: like `protections`, but with
    /// the cooling-off off once its removal has been asked for. Clients build
    /// changes on this, so changing another protection doesn't cancel the
    /// removal. nil from daemons that predate protections.
    public var requestedProtections: Protections? {
        guard var p = protections else { return nil }
        if coolingOffRemovalAt != nil { p.uninstallCoolingOff = false }
        return p
    }

    /// Whether uninstalling needs a request and a wait. A daemon that
    /// predates protections always had the cooling-off.
    public var enforcesCoolingOff: Bool { protections?.uninstallCoolingOff ?? true }

    public init(session: SessionInfo?, serverTime: Date, agents: [AgentStatus],
                alertURL: String? = nil, uninstall: UninstallStatus? = nil, schedules: [Schedule]? = nil,
                protections: Protections? = nil, coolingOffRemovalAt: Date? = nil, monitoring: MonitoringSettings? = nil) {
        self.session = session
        self.serverTime = serverTime
        self.agents = agents
        self.alertURL = alertURL
        self.uninstall = uninstall
        self.schedules = schedules
        self.protections = protections
        self.coolingOffRemovalAt = coolingOffRemovalAt
        self.monitoring = monitoring
    }
}

public struct Response: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var status: Status?
    /// For `activity`: the visits found.
    public var activity: [ActivityEvent]?
    /// For `activity`: pass as `ActivityQuery.fromOffset` to get only newer visits.
    public var activityOffset: Int?
    /// For `activity`: whether `activity` only holds visits added since the
    /// query's `fromOffset` (false: it's the whole day).
    public var activityIncremental: Bool?
    /// For `activityStats`: the days in the range that have totals.
    public var stats: [DaySummary]?

    public init(ok: Bool, error: String? = nil, status: Status? = nil, activity: ActivityPage? = nil,
                stats: [DaySummary]? = nil) {
        self.ok = ok
        self.error = error
        self.status = status
        self.activity = activity?.events
        self.activityOffset = activity?.offset
        self.activityIncremental = activity?.isIncremental
        self.stats = stats
    }
}

public enum Wire {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
