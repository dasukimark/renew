import ApplicationServices
import Foundation

/// Firefox has no AppleScript dictionary, so read the current page URL through
/// the Accessibility tree: prefer the web area's AXURL, and fall back to the
/// address bar's value when the bar isn't being edited.
enum FirefoxReader {
    static func activeURL(pid: pid_t) -> String? { activePage(pid: pid)?.url }

    /// The current page's URL and title (the window title without Firefox's name).
    static func activePage(pid: pid_t) -> (url: String, title: String)? {
        let app = AXUIElementCreateApplication(pid)
        var ax = AXReader(timeout: 1.0)
        guard let window = ax.element(app, kAXFocusedWindowAttribute) ?? ax.element(app, kAXMainWindowAttribute) else {
            return nil
        }
        let title = pageTitle(fromWindowTitle: ax.string(window, kAXTitleAttribute) ?? "")
        return activeURL(window: window, ax: &ax).map { ($0, title) }
    }

    /// "Page — Mozilla Firefox" → "Page". Also handles Developer Edition,
    /// Nightly and private windows ("… — Mozilla Firefox Private Browsing").
    static func pageTitle(fromWindowTitle raw: String) -> String {
        for sep in [" — ", " – ", " - "] {
            if let r = raw.range(of: sep, options: .backwards), raw[r.upperBound...].contains("Firefox") {
                return String(raw[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        return raw.hasPrefix("Mozilla Firefox") || raw == "Firefox" ? "" : raw
    }

    private static func activeURL(window: AXUIElement, ax: inout AXReader) -> String? {

        var queue: [(el: AXUIElement, depth: Int, inToolbar: Bool)] = [(window, 0, false)]
        var head = 0
        var addressBar: String?
        while head < queue.count && head < 2_000 {
            let (el, depth, inToolbar) = queue[head]
            head += 1
            let role = ax.string(el, kAXRoleAttribute) ?? ""

            if role == "AXWebArea", let u = ax.url(el), u.lowercased().hasPrefix("http") {
                return u
            }
            if addressBar == nil, role == kAXTextFieldRole || role == kAXComboBoxRole {
                let domID = ax.string(el, "AXDOMIdentifier")
                if domID == "urlbar-input" || inToolbar, !(ax.bool(el, kAXFocusedAttribute) ?? false) {
                    addressBar = ax.string(el, kAXValueAttribute)
                }
            }
            // Don't walk into page content: it can be huge and never holds the URL.
            if role == "AXWebArea" && depth > 0 { continue }
            if depth < 30, let kids = ax.children(el) {
                let childInToolbar = inToolbar || role == kAXToolbarRole
                for k in kids { queue.append((k, depth + 1, childInToolbar)) }
            }
        }
        return addressBar
    }
}
