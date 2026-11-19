import Foundation

public struct MonitoringRemovalRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let target: ReportTarget

    public init(target: ReportTarget) {
        id = UUID()
        self.target = target
    }
}

/// What the daemon persists in the root-only state.json.
public struct PersistedState: Codable, Equatable, Sendable {
    public var session: SessionInfo?
    /// Clock-proof countdown for `session`. `session.endsAt` is only the
    /// wall-clock rendering of it, refreshed at every checkpoint. Older state
    /// files don't have it; their `endsAt` is used until the next checkpoint.
    public var sessionClock: Countdown?
    /// Where email reports go (see `Report`). nil means off. The token is
    /// safe here: the state file is readable only by root.
    public var reports: ReportDestination?
    /// Removed locally, still monitored by one of these report servers.
    public var pendingPartnerRemovals: [ReportTarget]?
    public var monitoringRemovalRequests: [MonitoringRemovalRequest]?
    /// Partners who declined removal. Their servers still receive check-ins.
    public var retainedMonitoring: [ReportTarget]?
    public var seenMonitoringRejections: [String: UUID]?
    /// By report server, partners the server was seen asking to approve
    /// their removal. Only these count as approved once the server stops
    /// monitoring them: a partner it never enrolled never approved anything.
    public var removalsSeenAsked: [String: [String]]?
    /// This install's id, sent with check-ins (see `Heartbeat`). Made by
    /// renewd the first time it starts.
    public var installID: UUID?
    /// While email reports are on, when renewd last noted that it was
    /// running (every few minutes). If its internal heartbeat's record is
    /// then missing, or older than this, the record was deleted or put back
    /// from an old copy (see `AliveRecord.isConsistent`).
    public var aliveMarker: AliveMarker?
    public var uninstall: UninstallRequest?
    /// Recurring block sessions renewd starts on its own (see `Schedule`).
    public var schedules: [Schedule]?
    /// Monotonic-anchored wall time for the current boot (see `WallAnchor`).
    public var wallAnchor: WallAnchor?
    /// The optional hardening features. nil (older files, fresh installs) means all off.
    public var protections: Protections?
    /// Counts down to when the uninstall cooling-off turns off, once someone
    /// has asked. Turning it back on cancels this.
    public var coolingOffRemoval: Countdown?
    /// Whether Activity records visits, per user (keyed by uid). Users
    /// missing here (and older files) have it off.
    public var activityByUser: [String: ActivitySettings]?
    /// What the Monitor flags, per user (keyed by uid). Users missing here
    /// have it off.
    public var monitorByUser: [String: MonitorSettings]?
    /// The combined per-user settings kept before Activity and the Monitor
    /// were split. Read once and split (see `migrateMonitoring`).
    public var monitoringByUser: [String: LegacyMonitoringSettings]?
    /// The single combined setting kept before settings were per user. Read
    /// once and moved to the console user (see `migrateMonitoring`).
    public var monitoring: LegacyMonitoringSettings?

    /// Whether anyone is holding this Mac accountable: partners getting
    /// email reports (including ones waiting to approve their removal), or
    /// partners who declined their removal and are still monitored. While
    /// there is one, the Monitor can't be turned off or watch less.
    public var hasAccountabilityPartner: Bool {
        !(reports?.partnerEmails.isEmpty ?? true)
            || (retainedMonitoring ?? []).contains { !$0.partnerEmails.isEmpty }
    }

    /// Whether `uid`'s Monitor is locked: on, with a partner relying on it.
    /// Partners are the Mac's, like email reports, which carry every user's
    /// flags, so they lock every user's Monitor.
    public func monitoringLocked(for uid: uid_t) -> Bool {
        hasAccountabilityPartner && monitor(for: uid).enabled
    }

    public func activity(for uid: uid_t) -> ActivitySettings {
        activityByUser?[String(uid)] ?? .off
    }

    public func monitor(for uid: uid_t) -> MonitorSettings {
        monitorByUser?[String(uid)] ?? .off
    }

    /// Stores `uid`'s Activity setting; the default is dropped.
    public mutating func setActivity(_ a: ActivitySettings, for uid: uid_t) {
        var all = activityByUser ?? [:]
        all[String(uid)] = a == .off ? nil : a
        activityByUser = all.isEmpty ? nil : all
    }

    /// Stores `uid`'s Monitor settings; the default is dropped.
    public mutating func setMonitor(_ m: MonitorSettings, for uid: uid_t) {
        var all = monitorByUser ?? [:]
        all[String(uid)] = m == .off ? nil : m
        monitorByUser = all.isEmpty ? nil : all
    }

    /// Splits the old combined settings into Activity and Monitor ones: the
    /// per-user entries always, and the older single setting once there's a
    /// `uid` (the console user) to give it to. Recording on meant flagging
    /// on, so both start out as recording was. Users who already have new
    /// settings keep them. Returns whether anything changed.
    public mutating func migrateMonitoring(to uid: uid_t?) -> Bool {
        var changed = false
        if let old = monitoringByUser {
            monitoringByUser = nil
            for (key, legacy) in old {
                guard let u = uid_t(key) else { continue }
                adopt(legacy, for: u)
            }
            changed = true
        }
        if let old = monitoring, let uid {
            monitoring = nil
            adopt(old, for: uid)
            changed = true
        }
        return changed
    }

    private mutating func adopt(_ legacy: LegacyMonitoringSettings, for uid: uid_t) {
        let key = String(uid)
        if activityByUser?[key] == nil { setActivity(legacy.activity, for: uid) }
        if monitorByUser?[key] == nil {
            var m = legacy.monitor
            m.enabled = legacy.activity.enabled
            setMonitor(m, for: uid)
        }
    }

    public var effectiveProtections: Protections { protections ?? .off }

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
        coolingOffRemoval = coolingOffRemoval?.checkpointed(at: r)
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

    // MARK: protections

    /// When the uninstall cooling-off turns off, if that's been asked for.
    public func coolingOffRemovalDate(at r: ClockReading = .now()) -> Date? {
        coolingOffRemoval.map { r.wall.addingTimeInterval(max(0, $0.remaining(at: r))) }
    }

    /// Changes the protections to `requested`. Turning one on always works;
    /// turning one off is refused during a session. Turning off the uninstall
    /// cooling-off doesn't happen straight away: it starts a countdown of
    /// `UninstallPolicy.delay` (see `applyDueCoolingOffRemoval`), and asking
    /// for it on again cancels that.
    public mutating func setProtections(_ requested: Protections, sessionActive: Bool,
                                        at r: ClockReading = .now()) -> Result<ProtectionChange, ProtectionRefusal> {
        let current = effectiveProtections
        var target = requested
        var change = ProtectionChange()
        if current.uninstallCoolingOff && !requested.uninstallCoolingOff {
            target.uninstallCoolingOff = true // stays on until the wait is over
            change.coolingOffRemovalRequested = coolingOffRemoval == nil
        } else if requested.uninstallCoolingOff && coolingOffRemoval != nil {
            change.coolingOffRemovalCancelled = true
        }
        change.turnedOff = current.turnedOff(in: target)
        change.turnedOn = current.turnedOn(in: target)
        if sessionActive && !change.turnedOff.isEmpty {
            return .failure(ProtectionRefusal(message: "Protections can be turned off only between block sessions (\(change.turnedOff.joined(separator: ", ")))."))
        }
        protections = target.anyOn ? target : nil
        if change.coolingOffRemovalRequested { coolingOffRemoval = Countdown(remaining: UninstallPolicy.delay, at: r) }
        if change.coolingOffRemovalCancelled { coolingOffRemoval = nil }
        return .success(change)
    }

    /// Applies a pending cooling-off removal whose wait is over. Like any
    /// protection, it only turns off between sessions, so during one it waits
    /// for the session to end. Returns whether anything changed.
    @discardableResult
    public mutating func applyDueCoolingOffRemoval(at r: ClockReading = .now()) -> Bool {
        guard let c = coolingOffRemoval, c.remaining(at: r) <= 0, activeSession(at: r) == nil else { return false }
        coolingOffRemoval = nil
        var p = effectiveProtections
        p.uninstallCoolingOff = false
        protections = p.anyOn ? p : nil
        return true
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

/// What `PersistedState.setProtections` changed.
public struct ProtectionChange: Equatable, Sendable {
    public var turnedOn: [String] = []
    public var turnedOff: [String] = []
    /// The uninstall cooling-off was asked to turn off; it does after the wait.
    public var coolingOffRemovalRequested = false
    public var coolingOffRemovalCancelled = false

    public init() {}

    public var isEmpty: Bool {
        turnedOn.isEmpty && turnedOff.isEmpty && !coolingOffRemovalRequested && !coolingOffRemovalCancelled
    }
}

public struct ProtectionRefusal: Error, Equatable, Sendable {
    public var message: String
}

public enum StateStore {
    public static func load() -> PersistedState? {
        guard let data = FileManager.default.contents(atPath: Paths.stateFile) else { return nil }
        return try? Wire.decoder.decode(PersistedState.self, from: data)
    }

    @discardableResult
    public static func save(_ state: PersistedState) -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: Paths.dataDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try Wire.encoder.encode(state)
            let tmp = Paths.stateFile + ".tmp"
            guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]),
                  rename(tmp, Paths.stateFile) == 0 else {
                log("state rename failed: \(String(cString: strerror(errno)))")
                return false
            }
            return true
        } catch {
            log("state save failed: \(error)")
            return false
        }
    }
}
