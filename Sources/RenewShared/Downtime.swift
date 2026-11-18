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

    public init(bootID: String, awake: TimeInterval, wall: Date, coveredSince: Date, exit: Exit? = nil) {
        self.bootID = bootID
        self.awake = awake
        self.wall = wall
        self.coveredSince = coveredSince
        self.exit = exit
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
    /// - New boot after renewd was stopped without a shutdown: a gap from
    ///   then until the restart (how long the Mac was awake is unknown),
    ///   unless the Mac booted within `Heartbeat.restartWindow` of it: that
    ///   was a restart Renew wasn't told about (the app wasn't running).
    /// - New boot after renewd didn't exit cleanly: a crash or power loss;
    ///   nothing is reported, but coverage starts again.
    public static func assess(previous: AliveRecord?, bootID: String, awake: TimeInterval,
                              wall: Date, bootedAt: Date? = nil) -> (gap: DowntimeGap?, coveredSince: Date) {
        guard let p = previous else { return (nil, wall) }
        if p.bootID == bootID {
            let awakeGap = awake - p.awake
            guard awakeGap > tolerance else { return (nil, p.coveredSince) }
            return (DowntimeGap(from: p.wall, to: wall, awakeSeconds: Int(awakeGap.rounded()), restarted: false), wall)
        }
        switch p.exit {
        case .shutdown: return (nil, p.coveredSince)
        case .stopping:
            if let b = bootedAt, b.timeIntervalSince(p.wall) <= Heartbeat.restartWindow { return (nil, p.coveredSince) }
            return (DowntimeGap(from: p.wall, to: wall, awakeSeconds: nil, restarted: true), wall)
        case nil: return (nil, wall)
        }
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

    public init(id: UUID = UUID(), from: Date, to: Date, awakeSeconds: Int?, restarted: Bool) {
        self.id = id
        self.from = from
        self.to = to
        self.awakeSeconds = awakeSeconds
        self.restarted = restarted
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

    public func append(_ gap: DowntimeGap) {
        file.update { Array(($0 + [gap]).suffix(Self.maxGaps)) }
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

    public func load() -> AliveRecord? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? Report.decoder.decode(AliveRecord.self, from: data)
    }

    public func save(_ record: AliveRecord) {
        guard let data = try? Report.encoder.encode(record) else { return }
        let tmp = path + ".tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(tmp, path) == 0 else {
            log("alive record: couldn't save \(path): \(String(cString: strerror(errno)))")
            return
        }
    }
}
