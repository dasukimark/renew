import Foundation
import RenewShared

enum Uninstall {
    static let words = [
        "anchor", "harbor", "lantern", "meadow", "quiet", "river", "summit", "willow", "ember", "falcon",
        "granite", "horizon", "island", "juniper", "kettle", "linen", "marble", "nectar", "orchard", "pebble",
        "quartz", "saddle", "timber", "velvet", "walnut", "yonder", "zephyr", "beacon", "cobalt", "drift",
    ]

    /// `confirmed` skips the typed phrase. The app passes it after running
    /// its own typing challenge. The session check still applies.
    static func run(confirmed: Bool) -> Never {
        guard getuid() == 0 else { die("uninstall must be run with sudo: sudo renew uninstall") }

        // Ask the daemon first; fall back to the state file if it isn't running.
        var session: SessionInfo?
        if let r = try? DaemonClient.send(Request(cmd: .status)) {
            session = r.status?.session
        } else {
            session = StateStore.load()?.activeSession
        }
        if let s = session, s.isActive() {
            let left = Int(s.endsAt.timeIntervalSinceNow)
            die("A focus session is running (\(DurationText.format(left)) left, ends \(clock(s.endsAt))). Uninstall is allowed after it ends.")
        }

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

        let fm = FileManager.default
        for path in [Paths.daemonPlist, Paths.guardPlist, Paths.cliSymlink, Paths.socketPath,
                     Paths.installDir, Paths.dataDir, Paths.agentApp,
                     "/var/log/renew.log", "/var/log/renew-guard.log"] {
            if fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil {
                do { try fm.removeItem(atPath: path) } catch { print("  could not remove \(path): \(error)") }
            }
        }

        print("""
        Renew is uninstalled.

        If you installed the Renew configuration profile, remove it in
        System Settings → General → Device Management (it needs its removal password).
        """)

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
}
