import CryptoKit
import Foundation
import RenewShared

/// Keeps root-only backup copies of every installed Renew file and puts
/// them back if they are deleted or altered during a session.
enum SelfRepair {
    struct Item {
        let installed: String
        let backupName: String
        let isBundle: Bool
        var backup: String { Paths.backupDir + "/" + backupName }
    }

    static let items: [Item] = [
        Item(installed: Paths.daemonBinary, backupName: "renewd", isBundle: false),
        Item(installed: Paths.cliBinary, backupName: "renew", isBundle: false),
        Item(installed: Paths.agentApp, backupName: "Renew.app", isBundle: true),
        Item(installed: Paths.daemonPlist, backupName: "com.renew.daemon.plist", isBundle: false),
        Item(installed: Paths.guardPlist, backupName: "com.renew.guard.plist", isBundle: false),
        Item(installed: Paths.agentPlist, backupName: "com.renew.agent.plist", isBundle: false),
    ]

    private static let fm = FileManager.default

    /// Overwrites every backup with the currently installed file.
    static func refreshBackups() {
        ensureBackupDir()
        for item in items where fm.fileExists(atPath: item.installed) {
            copy(item.installed, to: item.backup)
        }
    }

    /// Restores missing or modified files. `deep` also compares contents.
    /// Returns the installed paths that were restored.
    @discardableResult
    static func repair(deep: Bool) -> [String] {
        ensureBackupDir()
        // The daemon and guard both repair; serialise them with a file lock.
        let lockFD = open(Paths.dataDir + "/repair.lock", O_CREAT | O_RDWR, 0o600)
        if lockFD >= 0 { flock(lockFD, LOCK_EX) }
        defer { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
        var restored: [String] = []
        for item in items {
            let haveInstalled = fm.fileExists(atPath: item.installed)
            let haveBackup = fm.fileExists(atPath: item.backup)
            switch (haveInstalled, haveBackup) {
            case (false, true):
                restore(item)
                restored.append(item.installed)
            case (true, false):
                copy(item.installed, to: item.backup)
            case (true, true) where deep:
                if fingerprint(item.installed, bundle: item.isBundle) != fingerprint(item.backup, bundle: item.isBundle) {
                    restore(item)
                    restored.append(item.installed)
                }
            default:
                break
            }
        }
        if !restored.isEmpty { log("self-repair restored: \(restored.joined(separator: ", "))") }
        return restored
    }

    static func ensureLoaded(label: String, plist: String) {
        guard !Launchctl.isLoaded("system/\(label)") else { return }
        guard fm.fileExists(atPath: plist) else { return }
        let r = Launchctl.bootstrap(domain: "system", plist: plist)
        log("re-loaded \(label): \(r.ok ? "ok" : r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    // MARK: helpers

    private static func ensureBackupDir() {
        try? fm.createDirectory(atPath: Paths.backupDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    }

    private static func restore(_ item: Item) {
        let parent = (item.installed as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o755])
        copy(item.backup, to: item.installed)
    }

    private static func copy(_ src: String, to dst: String) {
        if fm.fileExists(atPath: dst) { try? fm.removeItem(atPath: dst) }
        let r = shell("/usr/bin/ditto", [src, dst])
        if !r.ok { log("copy \(src) -> \(dst) failed: \(r.err)") }
    }

    private static func fingerprint(_ path: String, bundle: Bool) -> String {
        if bundle {
            return hash(path + "/Contents/MacOS/" + Paths.agentExecutableName) + hash(path + "/Contents/Info.plist")
        }
        return hash(path)
    }

    private static func hash(_ path: String) -> String {
        guard let data = fm.contents(atPath: path) else { return "missing" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
