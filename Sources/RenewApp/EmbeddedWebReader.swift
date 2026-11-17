import ApplicationServices
import Foundation

/// Reads the pages shown by web views inside ordinary apps (the built-in
/// browsers of T3 Code, Claude, Codex and other Electron apps, and apps using
/// WKWebView) through the Accessibility tree. Chromium and WebKit expose each
/// loaded page as an AXWebArea with an AXURL.
///
/// Chromium-based apps only build that tree when asked, and take a few
/// seconds to do so, so `prime` is called as early as possible (session
/// start, app launch):
/// - Electron apps (T3 Code, Claude) accept AXManualAccessibility.
/// - Other Chromium apps (ChatGPT/Codex) reject it but respond to
///   AXEnhancedUserInterface, the switch screen readers use. That one can
///   make the app's window moves animate oddly, so it's only used for apps
///   that reject the first, and `release` turns it off after the session.
///
/// Only call from one serial queue: `enhanced` isn't locked.
enum EmbeddedWebReader {
    private static let maxNodes = 6_000
    private static let maxDepth = 80
    /// Apps Renew switched AXEnhancedUserInterface on for.
    private static var enhanced: Set<pid_t> = []

    /// Asks the app to expose its Accessibility tree. Repeated on every scan
    /// because Electron forgets it when a renderer restarts.
    static func prime(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard manual == .attributeUnsupported, !enhanced.contains(pid) else { return }
        // Chromium reports an error here but still turns its tree on.
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        enhanced.insert(pid)
    }

    /// Turns AXEnhancedUserInterface back off wherever Renew turned it on,
    /// except for `keep`.
    static func release(except keep: pid_t? = nil) {
        for pid in enhanced where pid != keep { release(pid: pid) }
    }

    /// Turns AXEnhancedUserInterface back off for one app, if Renew turned it on.
    static func release(pid: pid_t) {
        guard enhanced.remove(pid) != nil else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
    }

    struct Page: Equatable {
        let url: String
        let title: String
        var isWebsite: Bool { url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://") }
    }

    /// Every distinct page URL in the app's windows, main UI included.
    static func pageURLs(pid: pid_t) -> [String] { pages(pid: pid).map(\.url) }

    /// Every distinct page in the app's windows, main UI included, with its
    /// document title ("" if the page doesn't expose one).
    ///
    /// An app's own UI is often a web page with the built-in browser nested
    /// inside it, so the walk enters web areas, except real websites (http,
    /// https): their content is large and never contains another page that
    /// matters.
    static func pages(pid: pid_t) -> [Page] {
        prime(pid: pid)
        let app = AXUIElementCreateApplication(pid)
        var ax = AXReader(timeout: 0.5)

        let windows = ax.copy(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var queue: [(el: AXUIElement, depth: Int)] = windows.map { ($0, 0) }
        var head = 0
        var pages: [Page] = []
        while head < queue.count && head < maxNodes {
            let (el, depth) = queue[head]
            head += 1
            if ax.string(el, kAXRoleAttribute) == "AXWebArea", let u = ax.url(el) {
                if !pages.contains(where: { $0.url == u }) {
                    // Chromium puts the document title in AXTitle or AXDescription.
                    var title = ""
                    for attr in [kAXTitleAttribute, kAXDescriptionAttribute] where title.isEmpty {
                        title = ax.string(el, attr)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    }
                    pages.append(Page(url: u, title: title))
                }
                if u.lowercased().hasPrefix("http") { continue }
            }
            if depth < maxDepth, let kids = ax.children(el) {
                for k in kids { queue.append((k, depth + 1)) }
            }
        }
        return pages
    }
}
