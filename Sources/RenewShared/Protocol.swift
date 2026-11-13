import Foundation

/// Newline-delimited JSON over the daemon's Unix socket.
///
/// The daemon only accepts commands that make things stricter: nothing here
/// can shorten, stop or loosen a running session.
public enum Command: String, Codable, Sendable {
    case status, start, extend, add, report
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

    public init(cmd: Command, durationSeconds: Int? = nil, rules: [String]? = nil, report: AgentReport? = nil) {
        self.cmd = cmd
        self.durationSeconds = durationSeconds
        self.rules = rules
        self.report = report
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

public struct Status: Codable, Sendable {
    public var session: SessionInfo?
    public var serverTime: Date
    public var agents: [AgentStatus]

    public init(session: SessionInfo?, serverTime: Date, agents: [AgentStatus]) {
        self.session = session
        self.serverTime = serverTime
        self.agents = agents
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
