import CryptoKit
import Foundation

/// renewd's internal heartbeat: every few seconds it writes an `AliveRecord`
/// to its root-only folder. When it starts, the last record shows how long it
/// was gone and whether the Mac was awake for any of that time, so stopping
/// Renew and starting it again is reported however short the gap (see
/// `DowntimeGap`, sent with the next check-in).
///
/// Two clocks tell sleep apart from downtime: the awake clock
/// (`CLOCK_UPTIME_RAW`) pauses while the Mac sleeps; the wall clock doesn't.
public struct AliveRecord: Codable, Equatable, Sendable {
    public enum Exit: String, Codable, Sendable {
        /// The Mac was logging out, restarting or shutting down.
        case shutdown
        /// renewd was stopped without a shutdown.
        case stopping
    }

    /// `kern.bootsessionuuid`, so a restart is told apart.
    public var bootID: String
    /// Awake-clock seconds (pauses during sleep).
    public var awake: TimeInterval
    public var wall: Date
    /// Since when every awake moment had renewd running (small restarts
    /// aside). Sent with check-ins so a "stopped checking in" email that
    /// turns out to be a lost connection can say so.
    public var coveredSince: Date
    /// Set when renewd exits cleanly; nil while running (or if it was killed).
    public var exit: Exit?
    /// Runs from before the Mac restarted, while they're still being
    /// checked against the power log (see `assessRestart`). Kept here so
    /// renewd restarting (or the Mac restarting again) mid-check doesn't
    /// drop them. Oldest first, at most `maxUnchecked`.
    public var unchecked: [UncheckedRestart]?

    public static let maxUnchecked = 10

    public init(bootID: String, awake: TimeInterval, wall: Date, coveredSince: Date, exit: Exit? = nil,
                unchecked: [UncheckedRestart]? = nil) {
        self.bootID = bootID
        self.awake = awake
        self.wall = wall
        self.coveredSince = coveredSince
        self.exit = exit
        self.unchecked = unchecked
    }

    /// How often renewd writes its record.
    public static let interval: TimeInterval = 10
    /// Awake time without renewd shorter than this is a restart (an update,
    /// launchd starting it again), not worth reporting.
    public static let tolerance: TimeInterval = 60

    /// Awake-clock seconds now.
    public static func awakeNow() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    /// What the last record says about the time renewd wasn't running.
    /// Returns the gap to report (if any) and the new `coveredSince`.
    ///
    /// - Same boot: the awake time since the last record, if over `tolerance`.
    /// - New boot after a clean shutdown: nothing (the Mac was off).
    /// - New boot otherwise (renewd was stopped, killed, or the Mac lost
    ///   power): see `assessRestart`. Reading the power log is slow, so
    ///   renewd does that part later, off its state queue.
    public static func assess(previous: AliveRecord?, bootID: String, awake: TimeInterval,
                              wall: Date, bootedAt: Date? = nil,
                              history: PowerHistory = PowerHistory()) -> (gap: DowntimeGap?, coveredSince: Date) {
        guard let p = previous else { return (nil, wall) }
        if p.bootID == bootID {
            let awakeGap = awake - p.awake
            guard awakeGap > tolerance else { return (nil, p.coveredSince) }
            return (DowntimeGap(after: p, to: wall, awakeSeconds: awakeGap, restarted: false), wall)
        }
        if p.exit == .shutdown { return (nil, p.coveredSince) }
        switch assessRestart(UncheckedRestart(p, restartedAt: wall, bootedAt: bootedAt), history: history) {
        case .gap(let gap): return (gap, wall)
        case .fine: return (nil, p.coveredSince)
        case .unknown: return (nil, wall)
        }
    }

    public enum RestartOutcome: Equatable, Sendable {
        /// The Mac was in use without renewd before it went down.
        case gap(DowntimeGap)
        /// renewd was running until the Mac went down (or nearly).
        case fine
        /// No way to tell: most likely a crash or power loss.
        case unknown
    }

    /// The Mac restarted after renewd stopped without a clean shutdown
    /// (it was stopped, killed, or the Mac crashed or lost power). The
    /// power log (`history`) says how long the Mac was awake between
    /// renewd's last record and the Mac going down:
    ///
    /// - Over `tolerance`: a gap, however the Mac went down. So stopping
    ///   renewd, using the Mac and restarting it is reported.
    /// - Under: fine. A crash or power loss ends both at once.
    /// - The log doesn't reach back that far: if a clean shutdown came
    ///   well after the last record, renewd was stopped before it (a gap of
    ///   unknown length). If renewd said it was stopping, the Mac booting
    ///   within `Heartbeat.restartWindow` counts as a restart Renew wasn't
    ///   told about (the app wasn't running). Otherwise unknown.
    public static func assessRestart(_ u: UncheckedRestart, history: PowerHistory) -> RestartOutcome {
        let bootedAt = u.bootedAt ?? u.restartedAt
        let down = history.awake(after: u.wall, before: bootedAt)
        if let seconds = down.awakeSeconds, seconds > tolerance {
            return .gap(DowntimeGap(after: u, awakeSeconds: seconds))
        }
        if let shutdown = down.shutdownAt {
            // A clean shutdown: the log (if any) covers up to it exactly.
            if down.awakeSeconds != nil { return .fine }
            return shutdown.timeIntervalSince(u.wall) > tolerance ? .gap(DowntimeGap(after: u, awakeSeconds: nil)) : .fine
        }
        // No clean shutdown, so the Mac went down abruptly. The power log
        // only has lines when something happens, so the time after its last
        // line is unknown: an hour of use with nothing logged looks short.
        if u.exit == .stopping {
            // renewd was stopped on purpose (a crash can't say that), so
            // this isn't a crash: as before, only a quick restart is fine.
            return bootedAt.timeIntervalSince(u.wall) > Heartbeat.restartWindow ? .gap(DowntimeGap(after: u, awakeSeconds: nil)) : .fine
        }
        // Killed, or a crash or power loss: a crash looks the same, so only
        // what the log shows counts.
        return down.awakeSeconds == nil ? .unknown : .fine
    }

    /// Whether this record can be trusted against `marker`, the last time
    /// renewd noted in state.json that it was running (see
    /// `PersistedState.aliveMarker`). renewd writes its record far more
    /// often than the marker, so a record older than the marker was put
    /// back from an old copy. Within a boot the awake clock decides, so
    /// setting the date back doesn't look like that.
    public static func isConsistent(_ record: AliveRecord?, marker: AliveMarker?) -> Bool {
        guard let marker else { return true }
        guard let record else { return false }
        if record.bootID == marker.bootID { return record.awake >= marker.awake - tolerance }
        return record.wall >= marker.wall.addingTimeInterval(-tolerance)
    }
}

/// renewd noting that it's running, kept in state.json (see
/// `PersistedState.aliveMarker`).
public struct AliveMarker: Codable, Equatable, Sendable {
    public var bootID: String
    public var awake: TimeInterval
    public var wall: Date

    public init(bootID: String, awake: TimeInterval, wall: Date) {
        self.bootID = bootID
        self.awake = awake
        self.wall = wall
    }
}

/// renewd's last record from before the Mac restarted, waiting to be
/// checked against the power log.
public struct UncheckedRestart: Codable, Equatable, Sendable {
    public var bootID: String
    public var awake: TimeInterval
    /// When renewd was last known to be running.
    public var wall: Date
    public var exit: AliveRecord.Exit?
    /// When renewd was running again after the restart.
    public var restartedAt: Date
    /// When the Mac booted after it (it may have restarted again since).
    public var bootedAt: Date?
    /// The old run's `coveredSince`, kept if renewd turns out to have run
    /// until the Mac went down.
    public var coveredSince: Date?

    public init(bootID: String, awake: TimeInterval, wall: Date, exit: AliveRecord.Exit?, restartedAt: Date,
                bootedAt: Date? = nil, coveredSince: Date? = nil) {
        self.bootID = bootID
        self.awake = awake
        self.wall = wall
        self.exit = exit
        self.restartedAt = restartedAt
        self.bootedAt = bootedAt
        self.coveredSince = coveredSince
    }

    public init(_ r: AliveRecord, restartedAt: Date, bootedAt: Date? = nil) {
        self.init(bootID: r.bootID, awake: r.awake, wall: r.wall, exit: r.exit, restartedAt: restartedAt,
                  bootedAt: bootedAt, coveredSince: r.coveredSince)
    }
}

/// Time the Mac was in use without renewd running, found by the internal
/// heartbeat and sent with the next check-in until the server takes it.
public struct DowntimeGap: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// When renewd was last known to be running.
    public var from: Date
    /// When it was running again.
    public var to: Date
    /// How long the Mac was awake in between; nil when the Mac restarted
    /// in between, so it's unknown.
    public var awakeSeconds: Int?
    public var restarted: Bool
    /// What kind of gap; nil for the usual one (renewd wasn't running).
    public var kind: Kind?

    public enum Kind: String, Codable, Sendable {
        /// renewd's records were deleted or put back from an old copy
        /// while it wasn't running, so how long it was gone is unknown.
        case recordsMissing
        /// The heartbeat failed authentication, or an expected signed record was missing.
        case recordUnverified
        /// The guard saw that the daemon heartbeat hadn't advanced while the Mac was awake.
        case heartbeatStalled
    }

    public init(id: UUID = UUID(), from: Date, to: Date, awakeSeconds: Int?, restarted: Bool, kind: Kind? = nil) {
        self.id = id
        self.from = from
        self.to = to
        self.awakeSeconds = awakeSeconds
        self.restarted = restarted
        self.kind = kind
    }

    /// The gap after renewd's record `last` (same boot).
    public init(after last: AliveRecord, to: Date, awakeSeconds: TimeInterval, restarted: Bool) {
        self.init(id: Self.id(after: last.bootID, awake: last.awake), from: last.wall, to: to,
                  awakeSeconds: Int(awakeSeconds.rounded()), restarted: restarted)
    }

    /// The gap after renewd's last record before a restart.
    public init(after u: UncheckedRestart, awakeSeconds: TimeInterval?) {
        self.init(id: Self.id(after: u.bootID, awake: u.awake), from: u.wall, to: u.restartedAt,
                  awakeSeconds: awakeSeconds.map { Int($0.rounded()) }, restarted: true)
    }

    /// The same id for the same gap, whoever finds it: renewd itself, or
    /// the guard (see `Witness`). It depends only on renewd's last record
    /// before the gap, so the server emails about it once.
    public static func id(after bootID: String, awake: TimeInterval) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("renew-gap/\(bootID)/\(awake)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // "version 5"-style: name-based
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Gaps waiting to be sent, in a root-only file so they survive restarts.
public struct DowntimeGapStore {
    public static let maxGaps = 50

    public let path: String

    public init(path: String = Paths.downtimeGapsFile) { self.path = path }

    private var file: LockedJSONFile<[DowntimeGap]> {
        LockedJSONFile(path: path, label: "downtime gaps", empty: [])
    }

    public func load() -> [DowntimeGap] { file.load() }

    /// Adds `gap`, unless one with its id is already waiting (renewd and
    /// the guard may both find it).
    @discardableResult
    public func append(_ gap: DowntimeGap) -> Bool {
        let updated = file.update { $0.contains { $0.id == gap.id } ? $0 : Array(($0 + [gap]).suffix(Self.maxGaps)) }
        return updated.contains { $0.id == gap.id }
    }

    /// Removes gaps the server has taken.
    public func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        file.update { $0.filter { !ids.contains($0.id) } }
    }

    public func removeAll() { file.update { _ in [] } }
}

/// The internal heartbeat's record on disk, written atomically.
public struct AliveRecordFile {
    public let path: String

    public init(path: String = Paths.aliveFile) { self.path = path }

    public enum ReadResult {
        case record(AliveRecord)
        case legacy(AliveRecord)
        case missing
        case unverified
    }

    private struct SignedRecord: Codable {
        let payload: String
        let tag: Data
    }

    private struct SigningKey: Codable, Equatable {
        let bytes: Data
        /// Only this exact legacy record may be used if migration is interrupted.
        let legacyDigest: Data?
    }

    private var keyFile: LockedJSONFile<SigningKey?> {
        LockedJSONFile(path: path + ".key", label: "alive record key", empty: nil)
    }

    private var signingMarker: String { path + ".signing-required" }

    public func load() -> AliveRecord? {
        switch read() {
        case .record(let record), .legacy(let record): return record
        case .missing, .unverified: return nil
        }
    }

    public func read() -> ReadResult {
        let key = keyFile.load()
        let fm = FileManager.default
        if key == nil, fm.fileExists(atPath: signingMarker) || fm.fileExists(atPath: keyFile.path) {
            return .unverified
        }
        guard let data = fm.contents(atPath: path) else {
            return key == nil ? .missing : .unverified
        }
        if let signed = try? Report.decoder.decode(SignedRecord.self, from: data) {
            let payload = Data(signed.payload.utf8)
            guard let key, key.bytes.count == 32,
                  HMAC<SHA256>.isValidAuthenticationCode(signed.tag, authenticating: payload,
                                                         using: SymmetricKey(data: key.bytes)),
                  let record = try? Report.decoder.decode(AliveRecord.self, from: payload) else {
                return .unverified
            }
            return .record(record)
        }
        if key == nil || key?.legacyDigest == Data(SHA256.hash(data: data)),
           let record = try? Report.decoder.decode(AliveRecord.self, from: data) {
            return .legacy(record)
        }
        return .unverified
    }

    @discardableResult
    public func save(_ record: AliveRecord) -> Bool {
        let existing = keyFile.load()
        let key = existing?.bytes.count == 32 ? existing : keyFile.update { existing in
            if let existing, existing.bytes.count == 32 { return existing }
            let fm = FileManager.default
            let legacyBytes = fm.fileExists(atPath: signingMarker) ? nil : fm.contents(atPath: path)
            let legacy = legacyBytes.flatMap { data in
                (try? Report.decoder.decode(AliveRecord.self, from: data)).map { _ in Data(SHA256.hash(data: data)) }
            }
            return SigningKey(bytes: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, legacyDigest: legacy)
        }
        guard let key, key.bytes.count == 32, let payload = try? Report.encoder.encode(record) else {
            log("alive record: couldn't load or create the signing key")
            return false
        }
        let tag = HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: key.bytes))
        let signed = SignedRecord(payload: String(decoding: payload, as: UTF8.self), tag: Data(tag))
        guard let data = try? Report.encoder.encode(signed) else { return false }
        // Persist the signing requirement before replacing the legacy record.
        // If interrupted, the key still identifies the one accepted legacy payload.
        let marker = open(signingMarker, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if marker >= 0 {
            close(marker)
        } else if errno != EEXIST {
            log("alive record: couldn't persist the signing requirement: \(String(cString: strerror(errno)))")
            return false
        }
        let tmp = path + ".tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(tmp, path) == 0 else {
            log("alive record: couldn't save \(path): \(String(cString: strerror(errno)))")
            return false
        }
        if key.legacyDigest != nil {
            keyFile.update { _ in SigningKey(bytes: key.bytes, legacyDigest: nil) }
        }
        return true
    }
}
