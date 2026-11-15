import Foundation

/// What the daemon persists in the root-only state.json.
public struct PersistedState: Codable, Equatable, Sendable {
    public var session: SessionInfo?
    /// Clock-proof countdown for `session`. `session.endsAt` is only the
    /// wall-clock rendering of it, refreshed at every checkpoint. Older state
    /// files don't have it; their `endsAt` is used until the next checkpoint.
    public var sessionClock: Countdown?
    /// Where tamper alerts go (see `Alerts`). nil means off.
    public var alertURL: String?
    public var uninstall: UninstallRequest?

    public init(session: SessionInfo? = nil) {
        self.session = session
    }

    // MARK: session

    public func sessionRemaining(at r: ClockReading = .now()) -> TimeInterval {
        guard let s = session else { return 0 }
        if let c = sessionClock { return c.remaining(at: r) }
        return s.endsAt.timeIntervalSince(r.wall)
    }

    /// The running session with `endsAt` (and `startedAt`, so progress stays
    /// right) expressed in the current wall clock, or nil if it's over.
    public func activeSession(at r: ClockReading = .now()) -> SessionInfo? {
        guard var s = session else { return nil }
        let left = sessionRemaining(at: r)
        guard left > 0 else { return nil }
        Self.shift(&s, toEndIn: left, at: r)
        return s
    }

    public var activeSession: SessionInfo? { activeSession(at: .now()) }

    /// Replaces the session; its countdown starts from `s.endsAt` as of `r`.
    public mutating func setSession(_ s: SessionInfo?, at r: ClockReading = .now()) {
        session = s
        sessionClock = s.map { Countdown(remaining: $0.endsAt.timeIntervalSince(r.wall), at: r) }
    }

    /// Re-anchors every countdown at `r`. Returns how far the wall clock moved
    /// against the session countdown since the last checkpoint: about zero,
    /// unless someone changed the date.
    @discardableResult
    public mutating func checkpoint(at r: ClockReading = .now()) -> TimeInterval {
        if var u = uninstall {
            u.countdown = u.countdown.checkpointed(at: r)
            uninstall = u
        }
        guard var s = session else { return 0 }
        let left = sessionRemaining(at: r)
        guard left > 0 else { return 0 }
        let shift = Self.shift(&s, toEndIn: left, at: r)
        session = s
        sessionClock = Countdown(remaining: left, at: r)
        return shift
    }

    /// Moves `s` so it ends `left` seconds after `r.wall`. Sub-second drift is
    /// ignored, so an untouched clock leaves the dates exactly as they were.
    @discardableResult
    private static func shift(_ s: inout SessionInfo, toEndIn left: TimeInterval, at r: ClockReading) -> TimeInterval {
        let shift = r.wall.addingTimeInterval(left).timeIntervalSince(s.endsAt)
        if abs(shift) >= 1 {
            s.endsAt = s.endsAt.addingTimeInterval(shift)
            s.startedAt = s.startedAt.addingTimeInterval(shift)
        }
        return shift
    }

    // MARK: uninstall

    /// The pending uninstall request as seen at `r`, or nil if there's none or
    /// it has expired.
    public func uninstallStatus(at r: ClockReading = .now()) -> UninstallStatus? {
        guard let u = uninstall else { return nil }
        let toExpiry = u.countdown.remaining(at: r)
        guard toExpiry > 0 else { return nil }
        let toUnlock = toExpiry - UninstallPolicy.window
        return UninstallStatus(requestedAt: u.requestedAt,
                               unlocksAt: r.wall.addingTimeInterval(max(0, toUnlock)),
                               expiresAt: r.wall.addingTimeInterval(toExpiry),
                               unlocked: toUnlock <= 0)
    }
}

public enum StateStore {
    public static func load() -> PersistedState? {
        guard let data = FileManager.default.contents(atPath: Paths.stateFile) else { return nil }
        return try? Wire.decoder.decode(PersistedState.self, from: data)
    }

    public static func save(_ state: PersistedState) {
        do {
            try FileManager.default.createDirectory(atPath: Paths.dataDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try Wire.encoder.encode(state)
            let tmp = Paths.stateFile + ".tmp"
            FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600])
            if rename(tmp, Paths.stateFile) != 0 {
                log("state rename failed: \(String(cString: strerror(errno)))")
            }
        } catch {
            log("state save failed: \(error)")
        }
    }
}
