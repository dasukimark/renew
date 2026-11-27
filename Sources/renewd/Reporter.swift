import Foundation
import RenewShared

/// Sends email reports (see `Report`) to the report server. Flags are
/// gathered for `batchWindow` after the first one, so a burst of browsing
/// becomes one report. Reports wait in a root-only outbox until the server
/// accepts them, so being offline or restarting delays a report but doesn't
/// lose it. They're sent one at a time, oldest first.
///
/// Called only on renewd's state queue (`queue`).
/// `@unchecked Sendable`: only used on `queue`; network callbacks hop back to it.
final class Reporter: @unchecked Sendable {
    static let batchWindow: TimeInterval = 60
    /// Waits between failed attempts; the last one repeats.
    static let backoff: [TimeInterval] = [30, 60, 300, 900]

    /// Where reports go now, or nil when reports are off or no server is set up.
    var destination: () -> ReportTarget?

    private let queue: DispatchQueue
    private let outbox: ReportOutbox
    /// What the partner was told, for the Accountability page.
    let partnerLog = PartnerLog()
    /// In `--dev` runs without `RENEW_DEV_REPORTS`, reports are only logged.
    private let logOnly: Bool
    private var batches: [uid_t: (flags: [MonitorFlag], due: TimeInterval)] = [:]
    private var sending = false
    /// False once the outbox was found empty, so idle ticks don't read it.
    private var maybePending = true
    private var failures = 0
    /// Uptime (seconds) before which no new attempt is made.
    private var nextAttempt: TimeInterval = 0

    init(queue: DispatchQueue, dev: Bool, destination: @escaping () -> ReportTarget?) {
        self.queue = queue
        self.destination = destination
        self.outbox = ReportOutbox()
        self.logOnly = dev && ProcessInfo.processInfo.environment["RENEW_DEV_REPORTS"] == nil
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: adding

    /// Gathers `flags` into `uid`'s batch, which is sent `batchWindow`
    /// after its first flag. Nothing is kept while reports are off.
    func add(flags: [MonitorFlag], uid: uid_t) {
        guard !flags.isEmpty, destination() != nil else { return }
        var batch = batches[uid] ?? ([], Self.uptime + Self.batchWindow)
        batch.flags.append(contentsOf: flags)
        batches[uid] = batch
    }

    /// Sends a `change` report for `uid` straight away.
    func add(changes: [String], uid: uid_t) {
        guard !changes.isEmpty, destination() != nil else { return }
        enqueue(change(changes, uid: uid))
    }

    /// Sends a test report straight away (not through the outbox). Returns
    /// false when there's nowhere to send it.
    func sendTest(uid: uid_t) -> Bool {
        guard let target = destination() else { return false }
        let report = Report(mac: Report.macName, user: Self.userName(uid), kind: .test, sentAt: Date(),
                            changes: ["Email reports work."])
        if logOnly { logDev(report); return true }
        let partnerLog = partnerLog
        ReportClient.post(report, to: target) { outcome in
            switch outcome {
            case .delivered: partnerLog.append(.email(report, status: .sent, date: Date()))
            case .rejected, .refused: partnerLog.append(.email(report, status: .failed, date: Date()))
            case .retry: break
            }
        }
        return true
    }

    /// Reports waiting to be sent, oldest first.
    func waiting() -> [OutboxEntry] { outbox.load() }

    /// Called on every tick: turns due batches into reports and sends
    /// waiting ones.
    func tick() {
        let now = Self.uptime
        for (uid, batch) in batches where batch.due <= now {
            batches[uid] = nil
            enqueue(Report.flags(from: batch.flags, mac: Report.macName, user: Self.userName(uid), at: Date()))
        }
        sendNext()
    }

    /// Moves unfinished batches into the outbox, before renewd exits.
    func flushBatches() {
        for (uid, batch) in batches {
            enqueue(Report.flags(from: batch.flags, mac: Report.macName, user: Self.userName(uid), at: Date()), send: false)
        }
        batches.removeAll()
    }

    /// Reports are about to be moved, turned off, or go to different
    /// partners. What's waiting for the current destination stays owed to it
    /// (`old`), and `farewell`, if any, goes to `farewellTarget` (default
    /// `old`), all through the outbox like any report, one at a time with retries.
    func handOff(from old: ReportTarget?, farewell: String?, to farewellTarget: ReportTarget? = nil, uid: uid_t) {
        flushBatches()
        if logOnly { return farewell.map { logDev(change([$0], uid: uid)) } ?? () }
        let moved = outbox.retargetCurrent(to: old)
        guard let old else {
            if moved > 0 { log("reports: no report server to send \(moved) waiting report(s) to; dropped them") }
            return
        }
        if let farewell { outbox.append(change([farewell], uid: uid), target: farewellTarget ?? old) }
        maybePending = true
        failures = 0
        nextAttempt = 0
        sendNext()
    }

    // MARK: sending

    private func change(_ changes: [String], uid: uid_t) -> Report {
        Report(mac: Report.macName, user: Self.userName(uid), kind: .change, sentAt: Date(), changes: changes)
    }

    private func enqueue(_ report: Report, send: Bool = true) {
        if logOnly { return logDev(report) }
        maybePending = true
        let dropped = outbox.append(report)
        if dropped > 0 { log("reports: outbox full; dropped the \(dropped) oldest") }
        log("reports: queued a '\(report.kind.rawValue)' report (\(report.flags.count + report.omitted) flags, \(report.changes.count) changes)")
        if send {
            // A new report is worth trying now, even while backing off.
            nextAttempt = 0
            sendNext()
        }
    }

    /// Sends the oldest waiting report; when it's settled, the next.
    private func sendNext() {
        guard maybePending, !sending, Self.uptime >= nextAttempt else { return }
        guard let entry = outbox.load().first else {
            maybePending = false
            return
        }
        // Reports for the current destination wait while reports are off.
        guard let target = entry.target ?? destination() else { return }
        sending = true
        ReportClient.post(entry.report, to: target) { [weak self] outcome in
            self?.queue.async { self?.settle(entry, outcome) }
        }
    }

    private func settle(_ entry: OutboxEntry, _ outcome: ReportClient.Outcome) {
        sending = false
        let settled: Bool
        switch outcome {
        case .delivered:
            settled = true
            partnerLog.append(.email(entry.report, status: .sent, date: Date()))
        case .rejected:
            settled = true
            partnerLog.append(.email(entry.report, status: .failed, date: Date()))
        case .refused:
            // A previous destination that no longer takes reports won't
            // start again; don't let it hold up the current one.
            settled = entry.target != nil
            if settled {
                log("reports: dropped report \(entry.report.id) owed to a previous report server that refused it")
                partnerLog.append(.email(entry.report, status: .failed, date: Date()))
            }
        case .retry:
            settled = false
        }
        if settled {
            outbox.remove(entry.report.id)
            failures = 0
            nextAttempt = 0
            sendNext()
        } else {
            let wait = Self.backoff[min(failures, Self.backoff.count - 1)]
            failures += 1
            nextAttempt = Self.uptime + wait
            log("reports: will try again in \(Int(wait))s")
        }
    }

    private func logDev(_ report: Report) {
        let json = (try? Report.encoder.encode(report)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
        log("(dev) report: \(json)")
    }

    static func userName(_ uid: uid_t) -> String {
        guard let pw = getpwuid(uid), let name = pw.pointee.pw_name else { return "uid \(uid)" }
        return String(cString: name)
    }
}
