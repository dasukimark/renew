import Foundation
import IOKit
import IOKit.pwr_mgt
import RenewShared

/// Sends check-ins (see `Heartbeat`) to the report server while email
/// reports are on: one at start, then about every 15 minutes, plus one when
/// the Mac sleeps, wakes or renewd stops, and one as soon as new downtime is
/// waiting (found by renewd or the guard). Check-ins skip the outbox: an old
/// one is worthless, so a failed one is just tried again a minute later.
/// Each carries the downtime the internal heartbeat found (see
/// `AliveTracker`) until the server takes it, and names the partner, Mac
/// and user only when those change.
///
/// Called only on renewd's state queue (`queue`), including the power
/// notifications.
/// `@unchecked Sendable`: only used on `queue`; network callbacks hop back to it.
final class Heartbeater: @unchecked Sendable {
    /// Where check-ins go now: the email reports' destination.
    var destination: () -> ReportTarget?
    /// Partners left out of check-in details (see `Daemon.partnersBeingAsked`).
    let leftOut: () -> Set<String>
    /// Enrollments whose partner approval is pending or was declined.
    var monitoringTargets: () -> [ReportTarget] = { [] }
    /// This install's id (made once and kept in the state file).
    var installID: () -> UUID
    /// The user named in check-ins.
    var userName: () -> String
    /// Called with what the server says it emailed the partner.
    var onNotices: ([HeartbeatReply.Notice]) -> Void = { _ in }
    /// Since when renewd has been running whenever the Mac was awake.
    var coveredSince: () -> Date? = { nil }
    /// Downtime waiting to be sent.
    let gaps = DowntimeGapStore()
    /// Previous destinations still owed a request to end monitoring,
    /// retried until they answer (a root-only file, since it holds tokens).
    private let removals = LockedJSONFile<[ReportTarget]>(path: Paths.pendingRemovalsFile, label: "pending removals", empty: [])
    private var removing = false
    private var nextRemoval: TimeInterval = 0

    private let queue: DispatchQueue
    private let runID = UUID()
    private let logOnly: Bool
    /// Uptime (seconds) at or after which the next check-in is due.
    private var nextBeat: TimeInterval = 0
    private var sending = false
    private var lastAccepted: Date?
    /// The details the server last took; nil until then, so the first
    /// check-in after starting carries them.
    private var acceptedDetails: Heartbeat.Details?
    /// The gaps file as last looked at (modification time and size), and
    /// the gap ids the last check-in carried: a gap not among them is new.
    private var gapsStamp: [Int] = []
    private var gapsTried: Set<UUID> = []
    /// Uptime when the app last said the Mac is powering off.
    private var poweringOffAt: TimeInterval?

    // Power notifications.
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    /// The sleep waiting for its check-in before it's allowed.
    private var pendingSleep: Int?
    /// Between "will sleep" and the next full wake. macOS briefly wakes a
    /// sleeping Mac for maintenance (dark wake) without telling power
    /// clients; an `awake` check-in then, right before it sleeps again
    /// unannounced, makes the server email that Renew went quiet.
    private var asleep = false
    /// Awake-clock seconds at "will sleep".
    private var sleptAt: TimeInterval = 0

    init(queue: DispatchQueue, dev: Bool, destination: @escaping () -> ReportTarget?,
         leftOut: @escaping () -> Set<String> = { [] }, installID: @escaping () -> UUID, userName: @escaping () -> String) {
        self.queue = queue
        self.destination = destination
        self.leftOut = leftOut
        self.installID = installID
        self.userName = userName
        self.logOnly = dev && ProcessInfo.processInfo.environment["RENEW_DEV_REPORTS"] == nil
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: schedule

    /// Called on every tick: sends `awake` when it's due, and retries
    /// asking previous destinations to end monitoring.
    func tick() {
        retryRemovals()
        if asleep, Heartbeat.inUseSinceSleep(awakeSinceSleep: AliveRecord.awakeNow() - sleptAt, sleepWait: Self.sleepWait,
                                             idle: Self.hidIdleSeconds()) {
            // macOS didn't say the Mac woke (or it missed telling us), but
            // someone is using it: dark wakes have no keyboard or mouse.
            asleep = false
            log("heartbeat: the Mac is in use without a wake notice; checking in again")
            nextBeat = 0
        }
        // Not while a check-in is on its way: its reply sets the next one,
        // and the file is looked at again afterwards.
        if !sending, newGapsWaiting() { nextBeat = 0 }
        guard !sending, !asleep, Self.uptime >= nextBeat, let target = checkInTarget else { return }
        send(.awake, to: target)
    }

    /// Sends `awake` now (reports just turned on, or the Mac woke).
    func beatNow() {
        nextBeat = 0
        tick()
    }

    func notePoweringOff() {
        poweringOffAt = Self.uptime
        log("heartbeat: the Mac is about to log out, restart or shut down")
    }

    func configurationChanged() {
        lastAccepted = nil
        acceptedDetails = nil
        beatNow()
    }

    private func retryRemovals() {
        guard !removing, !logOnly, Self.uptime >= nextRemoval else { return }
        let pending = removals.load()
        guard let old = pending.first else { return }
        // A late request to end monitoring would apply to the current destination.
        if let current = destination(), current.server.url == old.server.url {
            removals.update { $0.filter { $0 != old } }
            return
        }
        removing = true
        let beat = Heartbeat.make(.removed, install: installID(), details: nil, lastAccepted: nil)
        HeartbeatClient.post(beat, to: old.server) { [weak self] outcome, _ in
            self?.queue.async {
                guard let self else { return }
                self.removing = false
                if outcome == .retry {
                    self.nextRemoval = Self.uptime + Heartbeat.retryDelay * 5
                } else {
                    // Taken, or refused for good (that server won't email anyone).
                    self.removals.update { $0.filter { $0 != old } }
                    log("heartbeat: finished retrying a previous monitoring request")
                }
            }
        }
    }

    /// What renewd's exit looks like now: a shutdown or the service being stopped.
    func exitState() -> Heartbeat.State {
        Heartbeat.terminationState(poweringOffAt: poweringOffAt, now: Self.uptime, nobodyLoggedIn: consoleUser() == nil)
    }

    /// renewd is exiting: tells the server `state`. Waits up to `timeout`.
    func sendExit(_ state: Heartbeat.State, timeout: TimeInterval = 5) {
        guard let target = checkInTarget else { return }
        if logOnly { return logDev(state, to: target) }
        let deadline = DispatchTime.now() + timeout
        let finished = DispatchGroup()
        for extra in otherMonitoringTargets(than: target) {
            finished.enter()
            HeartbeatClient.post(make(state, for: extra), to: extra.server, timeout: timeout) { _, _ in finished.leave() }
        }
        let ok = HeartbeatClient.sendAndWait(make(state, for: target), to: target.server, timeout: timeout)
        _ = finished.wait(timeout: deadline)
        log("heartbeat: told the report server '\(state.rawValue)'\(ok ? "" : " (not confirmed)")")
    }

    // MARK: sending

    /// Nil when every partner is being asked about their removal: the
    /// server then keeps the details it has.
    private func details(for target: ReportTarget) -> Heartbeat.Details? {
        let skip = leftOut()
        let to = target.partnerEmails.filter { !skip.contains($0) }
        return to.isEmpty ? nil : Heartbeat.Details(to: to, mac: Report.macName, user: userName())
    }

    private var checkInTarget: ReportTarget? { destination() ?? monitoringTargets().first }

    private func otherMonitoringTargets(than target: ReportTarget) -> [ReportTarget] {
        monitoringTargets().filter { $0.server.url != target.server.url }
    }

    private func make(_ state: Heartbeat.State, for target: ReportTarget) -> Heartbeat {
        if destination()?.server.url != target.server.url {
            var beat = Heartbeat.make(state, install: installID(), details: nil, lastAccepted: nil, runID: runID)
            beat.monitoringOnly = true
            return beat
        }
        let d = details(for: target)
        var beat = Heartbeat.make(state, install: installID(), details: d == nil || d == acceptedDetails ? nil : d,
                                  lastAccepted: lastAccepted, gaps: gaps.load(), coveredSince: coveredSince(), runID: runID)
        beat.explicitPartnerRemovals = true
        return beat
    }

    private func send(_ state: Heartbeat.State, to target: ReportTarget, then: (() -> Void)? = nil) {
        let delay = Heartbeat.nextDelay()
        if logOnly {
            gapsTried = Set(gaps.load().map(\.id))
            logDev(state, to: target)
            nextBeat = Self.uptime + delay
            then?()
            return
        }
        sending = true
        let beat = make(state, for: target)
        if beat.monitoringOnly != true { gapsTried = Set((beat.gaps ?? []).map(\.id)) }
        let finished = DispatchGroup()
        for extra in otherMonitoringTargets(than: target) {
            finished.enter()
            HeartbeatClient.post(make(state, for: extra), to: extra.server) { _, _ in finished.leave() }
        }
        finished.enter()
        HeartbeatClient.post(beat, to: target.server) { [weak self] outcome, reply in
            guard let self else { finished.leave(); return }
            self.queue.async {
                defer { finished.leave() }
                self.sending = false
                if outcome == .delivered, reply?.needDetails == true {
                    // The server doesn't know this Mac: send everything, soon.
                    self.acceptedDetails = nil
                    self.nextBeat = Self.uptime + 5
                    if let notices = reply?.notices, !notices.isEmpty { self.onNotices(notices) }
                } else if outcome == .delivered {
                    if beat.monitoringOnly != true { self.lastAccepted = beat.sentAt }
                    self.nextBeat = Self.uptime + delay
                    if let to = beat.to, let mac = beat.mac, let user = beat.user, let zone = beat.timeZone {
                        self.acceptedDetails = Heartbeat.Details(to: to.emails, mac: mac, user: user, timeZone: zone)
                    }
                    if let sent = beat.gaps, !sent.isEmpty {
                        self.gaps.remove(Set(sent.map(\.id)))
                        log("heartbeat: reported \(sent.count) time(s) Renew wasn't running")
                    }
                    if let notices = reply?.notices, !notices.isEmpty { self.onNotices(notices) }
                } else {
                    self.nextBeat = Self.uptime + Heartbeat.retryDelay
                }
            }
        }
        if let then { finished.notify(queue: queue, execute: then) }
    }

    /// Whether the gaps file holds a gap no check-in has tried to send yet.
    /// Reads the file only when it changed.
    private func newGapsWaiting() -> Bool {
        var st = stat()
        let stamp = stat(gaps.path, &st) == 0
            ? [Int(st.st_mtimespec.tv_sec), Int(st.st_mtimespec.tv_nsec), Int(st.st_size)] : []
        guard stamp != gapsStamp else { return false }
        gapsStamp = stamp
        return !Set(gaps.load().map(\.id)).subtracting(gapsTried).isEmpty
    }

    private func logDev(_ state: Heartbeat.State, to target: ReportTarget) {
        log("(dev) heartbeat '\(state.rawValue)' to \(target.partnerEmails.joined(separator: ", "))")
    }

    // MARK: power

    /// The longest a sleep waits for its check-in.
    static let sleepWait: TimeInterval = 10

    /// Listens for sleep and wake. Without it, check-ins still go out on
    /// schedule, but sleeping looks like silence to the server.
    func startPowerNotifications() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, message, argument in
            guard let refcon else { return }
            let me = Unmanaged<Heartbeater>.fromOpaque(refcon).takeUnretainedValue()
            me.power(message, Int(bitPattern: argument))
        }, &notifier)
        guard rootPort != 0, let notifyPort else {
            log("heartbeat: couldn't listen for sleep and wake")
            return
        }
        IONotificationPortSetDispatchQueue(notifyPort, queue)
    }

    // From IOKit/IOMessage.h (macros Swift doesn't import).
    private static func iokitMessage(_ m: UInt32) -> UInt32 { 0xE000_0000 | m }
    static let canSystemSleep = iokitMessage(0x270)
    static let systemWillSleep = iokitMessage(0x280)
    static let systemHasPoweredOn = iokitMessage(0x300)
    static let systemWillPowerOff = iokitMessage(0x250)
    static let systemWillRestart = iokitMessage(0x310)

    private func power(_ message: UInt32, _ argument: Int) {
        switch message {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, argument)
        case Self.systemWillSleep:
            asleep = true
            sleptAt = AliveRecord.awakeNow()
            pendingSleep = argument
            guard let target = checkInTarget else { return allowSleep(argument) }
            // Even if a check-in is on its way, the server must hear this one.
            sending = false
            send(.sleeping, to: target) { [weak self] in self?.allowSleep(argument) }
            queue.asyncAfter(deadline: .now() + Self.sleepWait) { [weak self] in self?.allowSleep(argument) }
        case Self.systemHasPoweredOn:
            // Only full wakes get here, not maintenance wakes.
            asleep = false
            log("heartbeat: the Mac woke")
            beatNow()
        case Self.systemWillPowerOff, Self.systemWillRestart:
            notePoweringOff()
        default:
            break
        }
    }

    /// Seconds since the last keyboard, mouse or trackpad input.
    static func hidIdleSeconds() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return value.doubleValue / 1_000_000_000
    }

    private func allowSleep(_ argument: Int) {
        guard pendingSleep == argument else { return }
        pendingSleep = nil
        IOAllowPowerChange(rootPort, argument)
    }
}
