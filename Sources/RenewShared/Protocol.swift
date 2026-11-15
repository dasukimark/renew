import Foundation

/// Newline-delimited JSON over the daemon's Unix socket.
///
/// The daemon only accepts commands that make things stricter: nothing here
/// can shorten, stop or loosen a running session. Alerts can only be changed
/// between sessions (or turned on during one), and an uninstall request only
/// unlocks `sudo renew uninstall` after a cooling-off period.
public enum Command: String, Codable, Sendable {
    case status, start, extend, add, report
    case setAlerts, testAlert
    case requestUninstall, cancelUninstall
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

    public init(cmd: Command, durationSeconds: Int? = nil, rules: [String]? = nil, report: AgentReport? = nil,
                alertURL: String? = nil) {
        self.cmd = cmd
        self.durationSeconds = durationSeconds
        self.rules = rules
        self.report = report
        self.alertURL = alertURL
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

    public init(session: SessionInfo?, serverTime: Date, agents: [AgentStatus],
                alertURL: String? = nil, uninstall: UninstallStatus? = nil) {
        self.session = session
        self.serverTime = serverTime
        self.agents = agents
        self.alertURL = alertURL
        self.uninstall = uninstall
    }
}

public struct Response: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var status: Status?

    public init(ok: Bool, error: String? = nil, status: Status? = nil) {
        self.ok = ok
        self.error = error
        self.status = status
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
