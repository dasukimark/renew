import Foundation

/// The guard's second witness to renewd's internal heartbeat. While email
/// reports are on and the guard runs ("keep Renew running"), it reads
/// renewd's `AliveRecord` every few seconds and keeps its own copy of the
/// latest one it saw. When renewd's record moves on after standing still
/// for longer than `AliveRecord.tolerance` of awake time, the guard reports
/// the gap itself, so editing renewd's record isn't enough to hide one: the
/// guard (and its file) would have to be stopped and edited too.
///
/// Gaps get the same id whoever finds them (see `DowntimeGap.id`), so a gap
/// renewd also found is emailed once.
public struct WitnessRecord: Codable, Equatable, Sendable {
    /// The guard's own clocks at its last look.
    public var bootID: String
    public var awake: TimeInterval
    public var wall: Date
    /// renewd's latest record the guard has seen this boot.
    public var seen: AliveRecord?

    public init(bootID: String, awake: TimeInterval, wall: Date, seen: AliveRecord?) {
        self.bootID = bootID
        self.awake = awake
        self.wall = wall
        self.seen = seen
    }

    /// One look at renewd's record (`daemon`). Returns the guard's new
    /// record and any gap it witnessed.
    ///
    /// - Reports off: nothing is watched.
    /// - The guard wasn't looking for longer than `lookWindow` itself
    ///   (stopped, held up, or the witness file is from long ago): it starts
    ///   watching afresh, since it can't say what happened meanwhile (reports
    ///   may have been off and on).
    /// - renewd's record moved on, more than `tolerance` of awake time after
    ///   the one seen before: renewd wasn't running (or was frozen) in
    ///   between.
    /// - A new boot: if the guard had watched renewd's record stand still
    ///   for longer than `tolerance` before the Mac went down, that's a gap,
    ///   unless renewd's record said the Mac was shutting down.
    /// The guard looks every 3 seconds; a longer pause than this means it
    /// wasn't looking. Short enough that reports can't have been off and
    /// on again unseen for long enough to look like a gap.
    public static let lookWindow: TimeInterval = 15

    public static func observe(_ previous: WitnessRecord?, daemon: AliveRecord?, reporting: Bool,
                               bootID: String, awake: TimeInterval, wall: Date) -> (record: WitnessRecord, gap: DowntimeGap?) {
        let tolerance = AliveRecord.tolerance
        let current = daemon?.bootID == bootID ? daemon : nil
        // Watching starts from a record renewd wrote just now, not one left
        // from before reports were last off.
        let fresh = current.flatMap { awake - $0.awake <= tolerance ? $0 : nil }
        guard reporting else { return (WitnessRecord(bootID: bootID, awake: awake, wall: wall, seen: nil), nil) }
        guard let p = previous, let seen = p.seen, seen.bootID == p.bootID else {
            return (WitnessRecord(bootID: bootID, awake: awake, wall: wall, seen: fresh), nil)
        }
        if p.bootID != bootID {
            let watched = p.awake - seen.awake
            let gap = watched > tolerance && seen.exit != .shutdown
                ? DowntimeGap(id: DowntimeGap.id(after: seen.bootID, awake: seen.awake), from: seen.wall, to: p.wall,
                              awakeSeconds: Int(watched.rounded()), restarted: true)
                : nil
            return (WitnessRecord(bootID: bootID, awake: awake, wall: wall, seen: fresh), gap)
        }
        // The guard itself wasn't looking: start again.
        if awake - p.awake > lookWindow {
            return (WitnessRecord(bootID: bootID, awake: awake, wall: wall, seen: fresh), nil)
        }
        guard let d = current, d.awake > seen.awake else {
            // Standing still (or gone): keep the last one seen.
            return (WitnessRecord(bootID: bootID, awake: awake, wall: wall, seen: seen), nil)
        }
        let missing = d.awake - seen.awake
        let gap = missing > tolerance ? DowntimeGap(after: seen, to: d.wall, awakeSeconds: missing, restarted: false) : nil
        return (WitnessRecord(bootID: bootID, awake: awake, wall: wall, seen: d), gap)
    }
}

/// The guard's `WitnessRecord` on disk, root-only.
public struct WitnessFile {
    public let path: String

    public init(path: String = Paths.witnessFile) { self.path = path }

    public func load() -> WitnessRecord? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? Report.decoder.decode(WitnessRecord.self, from: data)
    }

    public func save(_ record: WitnessRecord) {
        guard let data = try? Report.encoder.encode(record) else { return }
        let tmp = path + ".tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(tmp, path) == 0 else {
            log("witness: couldn't save \(path): \(String(cString: strerror(errno)))")
            return
        }
    }
}
