import Foundation

/// One reading of the clocks Renew uses for countdowns.
///
/// Countdowns run on `CLOCK_MONOTONIC`, which keeps counting while the Mac
/// sleeps but ignores changes to the date and time, so setting the clock
/// forward doesn't end a session. The monotonic clock restarts at boot, so
/// each reading also carries the boot session ID.
public struct ClockReading: Sendable {
    public let bootID: String
    /// Nanoseconds of `CLOCK_MONOTONIC`.
    public let mono: UInt64
    public let wall: Date

    public init(bootID: String, mono: UInt64, wall: Date) {
        self.bootID = bootID
        self.mono = mono
        self.wall = wall
    }

    public static func now() -> ClockReading {
        ClockReading(bootID: bootID, mono: monoNow(), wall: Date())
    }

    public static func monoNow() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC)
    }

    /// `kern.bootsessionuuid`: changes on every boot.
    public static let bootID: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buf)
    }()
}

/// Time left on something (a session, the uninstall cooling-off), measured
/// from a checkpoint.
///
/// Within one boot the time left only depends on the monotonic clock. Across
/// a restart the monotonic clock starts again from zero, so the wall-clock
/// time since the last checkpoint is credited instead (the time the Mac was
/// off). The owner re-checkpoints regularly and whenever the date changes, so
/// a date change made before a restart is already part of the checkpoint and
/// gains nothing.
public struct Countdown: Codable, Equatable, Sendable {
    public var bootID: String
    public var mono: UInt64
    public var wall: Date
    public var remaining: TimeInterval

    public init(remaining: TimeInterval, at r: ClockReading = .now()) {
        bootID = r.bootID
        mono = r.mono
        wall = r.wall
        self.remaining = remaining
    }

    public func remaining(at r: ClockReading = .now()) -> TimeInterval {
        if r.bootID == bootID, r.mono >= mono {
            return remaining - Double(r.mono - mono) / 1e9
        }
        // Clock set backwards while the Mac was off credits nothing.
        return remaining - max(0, r.wall.timeIntervalSince(wall))
    }

    /// Same deadline, re-anchored at `r`.
    public func checkpointed(at r: ClockReading = .now()) -> Countdown {
        Countdown(remaining: remaining(at: r), at: r)
    }
}

/// Wall-clock time derived from the monotonic clock since a reading taken
/// earlier in the same boot. Moving the date doesn't move it, so the daemon
/// can still tell when a schedule's window really opens.
public struct WallAnchor: Codable, Equatable, Sendable {
    public var bootID: String
    public var mono: UInt64
    public var wall: Date

    public init(at r: ClockReading = .now()) {
        bootID = r.bootID
        mono = r.mono
        wall = r.wall
    }

    /// The trusted wall time at `r`, or nil if `r` is from another boot.
    public func trustedWall(at r: ClockReading) -> Date? {
        guard r.bootID == bootID, r.mono >= mono else { return nil }
        return wall.addingTimeInterval(Double(r.mono - mono) / 1e9)
    }
}
