import AppKit
import ApplicationServices
import RenewShared

/// The System Settings pages locked during a session, where switches can be
/// turned on but not off (see `OffSwitchBlocker`):
///
/// - Login Items & Extensions, whose "Allow in the Background" switch stops
///   Renew's background services in one click;
/// - Privacy & Security (and its Accessibility and Automation pages), where
///   the permissions Renew needs to watch browsers can be turned off.
///
/// System Settings names its window after the page shown, so the window
/// titles are read through Accessibility. Without that permission Renew
/// can't tell which page is open, and leaves System Settings alone so the
/// permission can be turned back on.
enum SettingsGuard {
    static let bundleID = "com.apple.systempreferences"

    /// Window titles of the locked pages, across macOS versions.
    static let lockedTitles: Set<String> = [
        "login items & extensions", // macOS 15+
        "login items",              // macOS 13–14
        "privacy & security",
        "security & privacy",       // older name
        "accessibility",            // Privacy & Security → Accessibility, or a deep link to it
        "automation",               // Privacy & Security → Automation
        "device control and data access", // macOS 27: holds the Accessibility list
    ]

    static func isLocked(title: String) -> Bool {
        lockedTitles.contains(title.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Titles of System Settings' windows, or [] if it isn't running or
    /// Accessibility is off.
    static func windowTitles(of app: NSRunningApplication) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        var ax = AXReader(timeout: 0.5)
        let windows = ax.copy(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.compactMap { ax.string($0, kAXTitleAttribute) }
    }

    static var runningApps: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
    }
}
