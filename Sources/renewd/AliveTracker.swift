import Foundation
import RenewShared

/// renewd's internal heartbeat (see `AliveRecord`): writes "still running"
/// every `AliveRecord.interval`, and at start works out whether the Mac was
/// in use while renewd wasn't running. Such downtime is kept in
/// `DowntimeGapStore` for the next check-in.
///
/// Only runs while email reports are on (`reporting`); there's no one to
/// tell otherwise, so nothing is written.
///
/// Called only on renewd's state queue.
final class AliveTracker {
    private let file = AliveRecordFile()
    private let gaps: DowntimeGapStore
    private let reporting: () -> Bool
    private(set) var coveredSince = Date()
    private var lastWrite: TimeInterval = -.infinity

    init(gaps: DowntimeGapStore, reporting: @escaping () -> Bool) {
        self.gaps = gaps
        self.reporting = reporting
    }

    /// Reads the last record and keeps any downtime it shows.
    func start() {
        coveredSince = Date()
        guard reporting() else { return }
        let previous = file.load()
        let now = Date()
        let (gap, covered) = AliveRecord.assess(previous: previous, bootID: ClockReading.bootID,
                                                awake: AliveRecord.awakeNow(), wall: now, bootedAt: Heartbeat.bootTime())
        coveredSince = covered
        if let gap {
            let awake = gap.awakeSeconds.map { DurationText.format($0) } ?? "unknown"
            log("internal heartbeat: renewd wasn't running from \(gap.from) to \(gap.to) (Mac awake for \(awake)\(gap.restarted ? ", restarted in between" : ""))")
            gaps.append(gap)
        }
        write(exit: nil)
    }

    /// Reports were just turned on: coverage starts now.
    func resume() {
        coveredSince = Date()
        write(exit: nil)
    }

    func tick() {
        guard reporting() else { return }
        if AliveRecord.awakeNow() - lastWrite >= AliveRecord.interval { write(exit: nil) }
    }

    /// renewd is exiting cleanly.
    func exit(_ how: AliveRecord.Exit) {
        guard reporting() else { return }
        write(exit: how)
    }

    private func write(exit: AliveRecord.Exit?) {
        let awake = AliveRecord.awakeNow()
        lastWrite = awake
        file.save(AliveRecord(bootID: ClockReading.bootID, awake: awake, wall: Date(), coveredSince: coveredSince, exit: exit))
    }
}
