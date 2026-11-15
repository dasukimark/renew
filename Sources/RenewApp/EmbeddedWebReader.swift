import ApplicationServices
import Foundation

/// Reads the pages shown by web views inside ordinary apps (the built-in
/// browsers of T3 Code, Claude, Codex and other Electron apps, and apps using
/// WKWebView) through the Accessibility tree. Chromium and WebKit expose each
/// loaded page as an AXWebArea with an AXURL.
///
/// Electron only builds that tree once another app sets AXManualAccessibility
/// on it, and takes a few seconds to do so, so `prime` is called as early as
/// possible (session start, app launch).
enum EmbeddedWebReader {
    private static let maxNodes = 6_000
    private static let maxDepth = 80

    /// Asks an Electron app to expose its Accessibility tree. Harmless for
    /// other apps. Repeated on every scan because Electron forgets it when a
    /// renderer restarts.
    static func prime(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Every distinct page URL in the app's windows, main UI included.
    ///
    /// An app's own UI is often a web page with the built-in browser nested
    /// inside it, so the walk enters web areas, except real websites (http,
    /// https): their content is large and never contains another page that
    /// matters.
    static func pageURLs(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let windows = copy(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var queue: [(el: AXUIElement, depth: Int)] = windows.map { ($0, 0) }
        var head = 0
        var urls: [String] = []
        while head < queue.count && head < maxNodes {
            let (el, depth) = queue[head]
            head += 1
            if (copy(el, kAXRoleAttribute) as? String) == "AXWebArea", let u = url(el) {
                if !urls.contains(u) { urls.append(u) }
                if u.lowercased().hasPrefix("http") { continue }
            }
            if depth < maxDepth, let kids = copy(el, kAXChildrenAttribute) as? [AXUIElement] {
                for k in kids { queue.append((k, depth + 1)) }
            }
        }
        return urls
    }

    private static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value
    }

    private static func url(_ el: AXUIElement) -> String? {
        guard let v = copy(el, "AXURL") else { return nil }
        if let u = v as? URL { return u.absoluteString }
        return v as? String
    }
}
