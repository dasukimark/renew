import Foundation

/// Newline-delimited JSON over the daemon's Unix socket.
///
/// The daemon only accepts commands that make things stricter: nothing here
/// can shorten, stop or loosen a running session. Email reports can only be
/// changed between sessions (or turned on during one), and an uninstall request only
/// unlocks `sudo renew uninstall` after a cooling-off period. Each user has
/// their own Activity and Monitor settings and logs, and only ever reads and
/// changes their own.
public enum Command: String, Codable, Sendable {
    case status, start, extend, add, report
    /// Sets where email reports go (see `Report`), or turns them off. Only
    /// changed or turned off between sessions.
    case setReports, testReport, requestMonitoringRemoval
    case requestUninstall, cancelUninstall
    /// Replaces the recurring block sessions the daemon starts on its own.
    case setSchedules
    /// Changes the optional hardening features (see `Protections`).
    case setProtections
    /// Turns Activity's recording on or off (see `ActivitySettings`).
    case setActivity
    /// Changes what the Monitor flags (see `MonitorSettings`).
    case setMonitor
    /// Stores finished page visits in the caller's activity log, where the
    /// Monitor checks them.
    case recordActivity
    /// Reads the caller's activity log (see `ActivityQuery`).
    case activity
    /// Reads the caller's per-site daily totals (see `ActivityStatsQuery`).
    case activityStats
    /// Reads the Monitor's flags for the caller (see `MonitorQuery`).
    case monitorFlags
    /// Replaces only the Monitor's copy of the watched blocklists' rules
    /// (`monitor.listRules`), leaving the rest of its settings as they are.
    case setMonitorListRules
    /// The app heard that the Mac is about to log out, restart or shut
    /// down, so renewd's exit counts as a shutdown (see `Heartbeat`).
    case poweringOff
    /// What the accountability partner was told (see `PartnerLogEntry`).
    case partnerHistory
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
    /// For `setSchedules`: the full new set.
    public var schedules: [Schedule]?
    /// For `setReports`: the report server's URL and token, or nil to turn reports off.
    public var reports: ReportDestination?
    /// For a new removal request after a partner declined.
    public var partnerEmail: String?
    /// For `setProtections`: the full new set.
    public var protections: Protections?
    /// For `setActivity`: the new setting.
    public var activity: ActivitySettings?
    /// For `setMonitor`: the full new settings.
    public var monitor: MonitorSettings?
    /// For `recordActivity`: finished visits.
    public var events: [ActivityEvent]?
    /// For `activity`: which part of the log to read.
    public var activityQuery: ActivityQuery?
    /// For `activityStats`: which days to sum.
    public var statsQuery: ActivityStatsQuery?
    /// For `monitorFlags`: which day to read.
    public var monitorQuery: MonitorQuery?

    public init(cmd: Command, durationSeconds: Int? = nil, rules: [String]? = nil, report: AgentReport? = nil,
                schedules: [Schedule]? = nil, protections: Protections? = nil,
                activity: ActivitySettings? = nil, monitor: MonitorSettings? = nil, events: [ActivityEvent]? = nil,
                activityQuery: ActivityQuery? = nil, statsQuery: ActivityStatsQuery? = nil, monitorQuery: MonitorQuery? = nil,
                reports: ReportDestination? = nil, partnerEmail: String? = nil) {
        self.cmd = cmd
        self.reports = reports
        self.partnerEmail = partnerEmail
        self.durationSeconds = durationSeconds
        self.rules = rules
        self.report = report
        self.schedules = schedules
        self.protections = protections
        self.activity = activity
        self.monitor = monitor
        self.events = events
        self.activityQuery = activityQuery
        self.statsQuery = statsQuery
        self.monitorQuery = monitorQuery
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
    /// The report server, when reports use one other than the built-in
    /// server (never the token).
    public var reportsURL: String?
    /// Who email reports go to. nil when off, or from daemons that predate
    /// reports or more than one partner.
    public var reportsPartners: [String]?
    /// Removed locally and awaiting confirmation from the report server.
    public var pendingReportPartners: [String]?
    public var retainedReportPartners: [String]?
    /// Whether a built-in report server is installed, so only the partners'
    /// addresses are needed.
    public var reportServerBuiltIn: Bool?
    public var uninstall: UninstallStatus?
    /// The schedules the daemon enforces. nil from daemons that predate them.
    public var schedules: [Schedule]?
    /// The hardening features in force. nil from daemons that predate them.
    public var protections: Protections?
    /// When the uninstall cooling-off turns off, if someone asked for that.
    public var coolingOffRemovalAt: Date?
    /// Whether Activity records visits for the user asking (each user has
    /// their own). nil from daemons that predate the split from the Monitor.
    public var activity: ActivitySettings?
    /// What the Monitor flags for the user asking. nil from daemons that
    /// predate it.
    public var monitor: MonitorSettings?
    /// The combined settings daemons sent before the split. Only read.
    public var monitoring: LegacyMonitoringSettings?

    /// Whether Activity is on, falling back to an older daemon's combined
    /// setting, so recording carries on until renewd is updated too.
    public var effectiveActivity: ActivitySettings { activity ?? monitoring?.activity ?? .off }

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
                uninstall: UninstallStatus? = nil, schedules: [Schedule]? = nil,
                protections: Protections? = nil, coolingOffRemovalAt: Date? = nil,
                activity: ActivitySettings? = nil, monitor: MonitorSettings? = nil, reportsURL: String? = nil,
                reportsPartners: [String]? = nil, pendingReportPartners: [String]? = nil,
                retainedReportPartners: [String]? = nil, reportServerBuiltIn: Bool? = nil) {
        self.session = session
        self.reportServerBuiltIn = reportServerBuiltIn
        self.reportsURL = reportsURL
        self.reportsPartners = reportsPartners
        self.pendingReportPartners = pendingReportPartners
        self.retainedReportPartners = retainedReportPartners
        self.serverTime = serverTime
        self.agents = agents
        self.uninstall = uninstall
        self.schedules = schedules
        self.protections = protections
        self.coolingOffRemovalAt = coolingOffRemovalAt
        self.activity = activity
        self.monitor = monitor
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
    /// For `monitorFlags`: the flags found.
    public var flags: [MonitorFlag]?
    /// For `monitorFlags`: pass as `MonitorQuery.fromOffset` to get only newer flags.
    public var flagsOffset: Int?
    /// For `monitorFlags`: whether `flags` only holds flags added since the
    /// query's `fromOffset`.
    public var flagsIncremental: Bool?
    /// For `partnerHistory`: newest first.
    public var partnerHistory: [PartnerLogEntry]?

    public init(ok: Bool, error: String? = nil, status: Status? = nil, activity: ActivityPage? = nil,
                stats: [DaySummary]? = nil, flags: MonitorPage? = nil, partnerHistory: [PartnerLogEntry]? = nil) {
        self.ok = ok
        self.partnerHistory = partnerHistory
        self.error = error
        self.status = status
        self.activity = activity?.events
        self.activityOffset = activity?.offset
        self.activityIncremental = activity?.isIncremental
        self.stats = stats
        self.flags = flags?.flags
        self.flagsOffset = flags?.offset
        self.flagsIncremental = flags?.isIncremental
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
