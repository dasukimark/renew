import AppKit
import ApplicationServices
import RenewShared

enum AutomationState: Equatable {
    case allowed
    case denied
    case notAsked
    case notRunning
    case unknown(Int32)

    var label: String {
        switch self {
        case .allowed: return "Allowed"
        case .denied: return "Not allowed"
        case .notAsked: return "Not asked yet"
        case .notRunning: return "Open the browser to check"
        case .unknown(let code): return "Unknown (\(code))"
        }
    }
}

struct BrowserPermission: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let icon: NSImage?
    let kind: BrowserKind
    var state: AutomationState
    var id: String { bundleID }

    static func == (a: BrowserPermission, b: BrowserPermission) -> Bool {
        a.bundleID == b.bundleID && a.state == b.state
    }
}

enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt and adds Renew to the Accessibility list.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openAutomationSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    static func openLoginItemsSettings() {
        open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    /// Supported browsers that are installed on this Mac.
    static func installedBrowsers() -> [(bundleID: String, name: String, icon: NSImage?, kind: BrowserKind)] {
        let ids = BrowserCatalog.safari.union(BrowserCatalog.chromium).union(BrowserCatalog.firefox)
        var out: [(String, String, NSImage?, BrowserKind)] = []
        for id in ids {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
                  let kind = BrowserCatalog.kind(of: id) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 20, height: 20)
            out.append((id, name, icon, kind))
        }
        return out.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    /// Checks (or with `ask`, requests) permission to send Apple Events to a browser.
    /// Can block while the system prompt is up, so call it off the main thread.
    static func automationState(bundleID: String, ask: Bool) -> AutomationState {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else {
            return .notRunning
        }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard var desc = target.aeDesc?.pointee else { return .unknown(-1) }
        let status = AEDeterminePermissionToAutomateTarget(&desc, typeWildCard, typeWildCard, ask)
        switch Int(status) {
        case Int(noErr): return .allowed
        case -1743: return .denied        // errAEEventNotPermitted
        case -1744: return .notAsked      // errAEEventWouldRequireUserConsent
        case -600: return .notRunning     // procNotFound
        default: return .unknown(status)
        }
    }
}
