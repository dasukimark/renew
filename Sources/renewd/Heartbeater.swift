import Foundation
import IOKit
import IOKit.pwr_mgt
import RenewShared

/// Sends check-ins (see `Heartbeat`) to the report server while email
/// reports are on: one at start, then about every 4 minutes, plus one when
/// the Mac sleeps, wakes or renewd stops. Check-ins skip the outbox: an old
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
    /// Previous destinations still to be told to stop expecting check-ins,
    /// retried until they answer (a root-only file, since it holds tokens).
    private let removals = LockedJSONFile<[ReportTarget]>(path: Paths.pendingRemovalsFile, label: "pending removals", empty: [])
    private var removing = false
    private var nextRemoval: TimeInterval = 0

    private let queue: DispatchQueue
    private let logOnly: Bool
    /// Uptime (seconds) at or after which the next check-in is due.
    private var nextBeat: TimeInterval = 0
    private var sending = false
    private var lastAccepted: Date?
    /// The details the server last took; nil until then, so the first
    /// check-in after starting carries them.
    private var acceptedDetails: Heartbeat.Details?
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

    init(queue: DispatchQueue, dev: Bool, destination: @escaping () -> ReportTarget?,
         installID: @escaping () -> UUID, userName: @escaping () -> String) {
        self.queue = queue
        self.destination = destination
        self.installID = installID
        self.userName = userName
        self.logOnly = dev && ProcessInfo.processInfo.environment["RENEW_DEV_REPORTS"] == nil
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: schedule

    /// Called on every tick: sends `awake` when it's due, and retries
    /// telling previous destinations to stop expecting check-ins.
    func tick() {
        retryRemovals()
        guard !sending, !asleep, Self.uptime >= nextBeat, let target = destination() else { return }
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

    /// Reports are moving or being turned off: tells the old destination to
    /// stop expecting check-ins, then checks in with the new one (if any).
    /// The order matters when both use the same server.
    func handOff(from old: ReportTarget?) {
        guard let old else { return beatNow() }
        if logOnly {
            logDev(.removed, to: old)
            return beatNow()
        }
        sending = true
        let beat = Heartbeat.make(.removed, install: installID(), details: nil, lastAccepted: lastAccepted)
        HeartbeatClient.post(beat, to: old.server) { [weak self] outcome, _ in
            self?.queue.async {
                guard let self else { return }
                self.sending = false
                if outcome == .retry {
                    // Keep trying, or the old server emails the previous
                    // partner that Renew went quiet.
                    log("heartbeat: couldn't tell the previous report server to stop expecting check-ins; will retry")
                    self.removals.update { $0.contains(old) ? $0 : $0 + [old] }
                    self.nextRemoval = Self.uptime + Heartbeat.retryDelay
                }
                self.lastAccepted = nil
                self.acceptedDetails = nil
                self.beatNow()
            }
        }
    }

    private func retryRemovals() {
        guard !removing, !logOnly, Self.uptime >= nextRemoval else { return }
        let pending = removals.load()
        guard let old = pending.first else { return }
        // The current destination on the same server replaces the old entry
        // with its own check-ins; a late "removed" would delete it.
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
                    log("heartbeat: told a previous report server to stop expecting check-ins")
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
        guard let target = destination() else { return }
        if logOnly { return logDev(state, to: target) }
        let ok = HeartbeatClient.sendAndWait(make(state, for: target), to: target.server, timeout: timeout)
        log("heartbeat: told the report server '\(state.rawValue)'\(ok ? "" : " (not confirmed)")")
    }

    // MARK: sending

    private func details(for target: ReportTarget) -> Heartbeat.Details {
        Heartbeat.Details(to: target.partnerEmails, mac: Report.macName, user: userName())
    }

    private func make(_ state: Heartbeat.State, for target: ReportTarget) -> Heartbeat {
        let d = details(for: target)
        return Heartbeat.make(state, install: installID(), details: d == acceptedDetails ? nil : d,
                              lastAccepted: lastAccepted, gaps: gaps.load(), coveredSince: coveredSince())
    }

    private func send(_ state: Heartbeat.State, to target: ReportTarget, then: (() -> Void)? = nil) {
        let delay = Heartbeat.nextDelay()
        if logOnly {
            logDev(state, to: target)
            nextBeat = Self.uptime + delay
            then?()
            return
        }
        sending = true
        let beat = make(state, for: target)
        HeartbeatClient.post(beat, to: target.server) { [weak self] outcome, reply in
            self?.queue.async {
                guard let self else { return }
                self.sending = false
                if outcome == .delivered, reply?.needDetails == true {
                    // The server doesn't know this Mac: send everything, soon.
                    self.acceptedDetails = nil
                    self.nextBeat = Self.uptime + 5
                    if let notices = reply?.notices, !notices.isEmpty { self.onNotices(notices) }
                } else if outcome == .delivered {
                    self.lastAccepted = beat.sentAt
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
                then?()
            }
        }
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
            pendingSleep = argument
            guard let target = destination() else { return allowSleep(argument) }
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

    private func allowSleep(_ argument: Int) {
        guard pendingSleep == argument else { return }
        pendingSleep = nil
        IOAllowPowerChange(rootPort, argument)
    }
}
