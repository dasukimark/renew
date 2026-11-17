import Foundation

/// Every filesystem location and launchd label Renew uses.
///
/// `RENEW_DATA_DIR` and `RENEW_SOCKET` relocate the daemon's state and
/// socket so `renewd --dev` can run unprivileged for local testing. They are
/// ignored when running as root or from an installed location, so nobody can
/// point the real daemon, app or `sudo renew uninstall` at a fake socket.
public enum Paths {
    private static let env: [String: String] = devOverridesAllowed ? ProcessInfo.processInfo.environment : [:]

    static var devOverridesAllowed: Bool {
        guard geteuid() != 0, getuid() != 0 else { return false }
        let exe = executableRealPath()
        let installedPrefixes = [installDir + "/", agentApp + "/"]
        return !installedPrefixes.contains { exe.hasPrefix($0) }
    }

    /// Absolute, symlink-resolved path of the running executable.
    static func executableRealPath() -> String {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return "" }
        guard let resolved = realpath(buf, nil) else { return String(cString: buf) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static let installDir = "/Library/Application Support/Renew"
    public static let binDir = installDir + "/bin"
    public static let daemonBinary = binDir + "/renewd"
    public static let cliBinary = binDir + "/renew"
    public static let agentApp = "/Applications/Renew.app"
    public static let agentExecutableName = "Renew"
    public static let agentExecutable = agentApp + "/Contents/MacOS/" + agentExecutableName

    public static let dataDir = env["RENEW_DATA_DIR"] ?? "/var/db/com.renew"
    public static var stateFile: String { dataDir + "/state.json" }
    public static var backupDir: String { dataDir + "/backup" }
    public static let socketPath = env["RENEW_SOCKET"] ?? "/var/run/renew.sock"

    public static let daemonLabel = "com.renew.daemon"
    public static let guardLabel = "com.renew.guard"
    public static let agentLabel = "com.renew.agent"
    public static let daemonPlist = "/Library/LaunchDaemons/com.renew.daemon.plist"
    /// Kept out of /Library/LaunchDaemons so launchd doesn't start the guard at
    /// boot: renewd loads it only while the "keep Renew running" protection is on.
    public static let guardPlist = installDir + "/com.renew.guard.plist"
    /// Where installs from before that kept it.
    public static let legacyGuardPlist = "/Library/LaunchDaemons/com.renew.guard.plist"
    public static let agentPlist = "/Library/LaunchAgents/com.renew.agent.plist"

    public static let cliSymlink = "/usr/local/bin/renew"
    /// Root-owned log folder for install/uninstall (never a world-writable /tmp path).
    public static let adminLogDir = "/Library/Logs/Renew"
    public static let installLog = adminLogDir + "/install.log"
    public static let uninstallLog = adminLogDir + "/uninstall.log"

    /// Each logged-in user gets their own block-page port so agents never collide.
    public static func blockPagePort(uid: uid_t) -> UInt16 {
        47000 + UInt16(uid % 1000)
    }
}
