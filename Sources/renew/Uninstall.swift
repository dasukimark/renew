import Foundation
import RenewShared

enum Uninstall {
    static let words = [
        "anchor", "harbor", "lantern", "meadow", "quiet", "river", "summit", "willow", "ember", "falcon",
        "granite", "horizon", "island", "juniper", "kettle", "linen", "marble", "nectar", "orchard", "pebble",
        "quartz", "saddle", "timber", "velvet", "walnut", "yonder", "zephyr", "beacon", "cobalt", "drift",
    ]

    /// With the uninstall cooling-off on, uninstalling takes two steps. The
    /// first call files a request with renewd (no sudo needed). After
    /// `UninstallPolicy.delay`, and while no session is running,
    /// `sudo renew uninstall` removes Renew. An unused request expires after
    /// `UninstallPolicy.window`. With it off (the default), `sudo renew
    /// uninstall` works straight away between sessions.
    ///
    /// `confirmed` skips the typed phrase. The app passes it after running
    /// its own typing challenge. The cooling-off and session checks still apply.
    static func run(confirmed: Bool) -> Never {
        // Ask the daemon first; fall back to the state file if it isn't running.
        let daemon = try? DaemonClient.send(Request(cmd: .status))
        let session: SessionInfo?
        let request: UninstallStatus?
        let coolingOff: Bool
        if let status = daemon?.status {
            (session, request) = (status.session, status.uninstall)
            coolingOff = status.enforcesCoolingOff
        } else {
            let file = StateStore.load()
            (session, request) = (file?.activeSession, file?.uninstallStatus())
            // No daemon and no state file: assume the cooling-off is on, so
            // stopping renewd and deleting its state isn't a way around it.
            coolingOff = file?.effectiveProtections.uninstallCoolingOff ?? true
        }

        if coolingOff {
            guard let request else {
                guard !confirmed else { die("Uninstall hasn't been requested yet. Request it first; it unlocks after a day.") }
                fileRequest(reachable: daemon != nil)
            }
            guard request.unlocked else {
                die("""
                Uninstall was requested \(clock(request.requestedAt)). It unlocks \(clock(request.unlocksAt)) \
                (in \(DurationText.format(Int(request.unlocksAt.timeIntervalSinceNow)))).
                Cancel the request with: renew uninstall --cancel
                """)
            }
        }
        if let s = session, s.isActive() {
            let left = Int(s.endsAt.timeIntervalSinceNow)
            die("A block session is running (\(DurationText.format(left)) left, ends \(clock(s.endsAt))). Uninstall is allowed after it ends.")
        }
        guard getuid() == 0 else { die("Uninstall is unlocked. Finish it with sudo: sudo renew uninstall") }

        if !confirmed {
            let phrase = (0..<8).map { _ in words.randomElement()! }.joined(separator: " ")
            print("""
            This removes Renew completely.
            To confirm, type this phrase exactly:

                \(phrase)

            """)
            print("> ", terminator: "")
            guard let typed = Swift.readLine(), typed.trimmingCharacters(in: .whitespaces) == phrase else {
                die("Phrase didn't match. Nothing was removed.")
            }
        }

        print("Removing Renew…")
        // Guard first, so it can't bring the daemon back.
        Launchctl.bootout("system/\(Paths.guardLabel)")
        Launchctl.bootout("system/\(Paths.daemonLabel)")
        sendFinalReports()

        let fm = FileManager.default
        for path in [Paths.daemonPlist, Paths.guardPlist, Paths.legacyGuardPlist, Paths.cliSymlink, Paths.socketPath,
                     Paths.installDir, Paths.dataDir, Paths.agentApp,
                     "/var/log/renew.log", "/var/log/renew-guard.log"] {
            if fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil {
                do { try fm.removeItem(atPath: path) } catch { print("  could not remove \(path): \(error)") }
            }
        }

        print("Renew is uninstalled.")

        // Stop the app last: when the app itself runs this uninstall, stopping
        // it earlier could take this process down with it.
        var uids = Set<String>()
        let ps = shell("/bin/ps", ["-axo", "uid=,comm="])
        for line in ps.out.split(separator: "\n") where line.hasSuffix("/" + Paths.agentExecutableName) {
            if let uid = line.split(separator: " ").first { uids.insert(String(uid)) }
        }
        let console = shell("/usr/bin/stat", ["-f", "%u", "/dev/console"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        if !console.isEmpty && console != "0" { uids.insert(console) }
        try? fm.removeItem(atPath: Paths.agentPlist)
        for uid in uids { Launchctl.bootout("gui/\(uid)/\(Paths.agentLabel)") }
        shell("/usr/bin/pkill", ["-f", Paths.agentExecutable])
        exit(0)
    }

    /// Sends the outbox, tells monitored partners about uninstall and asks
    /// each report server to end its enrollment before local files are deleted.
    private static func sendFinalReports() {
        guard let state = StateStore.load() else { return }
        let current = state.reports.flatMap { dest in
            dest.server(builtIn: ReportServer.builtIn()).map { ReportTarget(partnerEmails: dest.partnerEmails, server: $0) }
        }
        var targets = (state.pendingPartnerRemovals ?? []) + (state.retainedMonitoring ?? [])
        if let current { targets.append(current) }
        var byURL: [String: ReportTarget] = [:]
        for target in targets {
            let former = byURL[target.server.url]?.partnerEmails ?? []
            byURL[target.server.url] = ReportTarget(partnerEmails: Array(Set(former + target.partnerEmails)).sorted(),
                                                    server: target.server)
        }
        let monitored = byURL.values.sorted { $0.server.url < $1.server.url }
        let console = shell("/usr/bin/stat", ["-f", "%Su", "/dev/console"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = ProcessInfo.processInfo.environment["SUDO_USER"] ?? (console.isEmpty || console == "root" ? NSUserName() : console)
        var groups: [(ReportTarget, [Report])] = []
        func append(_ report: Report, to target: ReportTarget) {
            if let i = groups.firstIndex(where: { $0.0 == target }) {
                groups[i].1.append(report)
            } else {
                groups.append((target, [report]))
            }
        }
        for entry in ReportOutbox().load() {
            if let target = entry.target ?? current { append(entry.report, to: target) }
        }
        for target in monitored {
            let last = Report(mac: Report.macName, user: user, kind: .change, sentAt: Date(),
                              changes: ["Renew was uninstalled from this Mac. Check-ins have stopped. Server monitoring needs a partner's approval to end."])
            append(last, to: target)
        }
        if !groups.isEmpty { print("Emailing your accountability partners…") }
        for (target, reports) in groups {
            let sent = ReportClient.sendAndWait(reports, to: target)
            if sent < reports.count { print("  couldn't send \(reports.count - sent) report(s) to \(target.partnerEmails.joined(separator: ", "))") }
        }
        if let install = state.installID {
            for target in monitored {
                let beat = Heartbeat.make(.requestRemoval, install: install, details: nil, lastAccepted: nil)
                if !HeartbeatClient.sendAndWait(beat, to: target.server, timeout: 15) {
                    print("  couldn't confirm the monitoring change with a report server; your partner may get a \"stopped checking in\" email")
                }
            }
        }
    }

    private static func fileRequest(reachable: Bool) -> Never {
        guard reachable else {
            die("renewd isn't running, so the uninstall request can't be filed. Restart Renew's service and try again.")
        }
        guard let r = try? DaemonClient.send(Request(cmd: .requestUninstall)), r.ok, let u = r.status?.uninstall else {
            die("renewd refused the uninstall request.")
        }
        print("""
        Uninstall requested. Renew keeps working until then.

        You can finish it from \(clock(u.unlocksAt)) until \(clock(u.expiresAt)), between block sessions:
            sudo renew uninstall

        Changed your mind? renew uninstall --cancel
        """)
        exit(0)
    }

    static func cancel() -> Never {
        guard let r = try? DaemonClient.send(Request(cmd: .cancelUninstall)), r.ok else {
            die("Couldn't reach renewd to cancel the request.")
        }
        print("Uninstall request cancelled.")
        exit(0)
    }
}
