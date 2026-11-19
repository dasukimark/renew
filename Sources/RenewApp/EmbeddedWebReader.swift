import ApplicationServices
import Foundation
import RenewShared

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
    /// Browsers whose tree Renew switched on to read a mixed site's page,
    /// by switch, kept apart so `release(except:)` (for embedded apps) leaves
    /// them alone.
    private static var browsersManual: Set<pid_t> = []
    private static var browsersEnhanced: Set<pid_t> = []
    /// Mixed pages in embedded apps, so each is read at most every few seconds.
    private static let textReads = PageReadThrottle()

    private struct Switched: OptionSet {
        let rawValue: Int
        static let manual = Switched(rawValue: 1)
        static let enhanced = Switched(rawValue: 2)
    }

    /// Switches on `pid`'s Accessibility tree: AXManualAccessibility, or
    /// AXEnhancedUserInterface (if `allowEnhanced`) for apps that reject it.
    /// Returns the switches Renew turned on; ones already on are left alone,
    /// so whoever turned them on keeps them.
    private static func switchOn(_ pid: pid_t, allowEnhanced: Bool) -> Switched {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        func isOn(_ attr: String) -> Bool {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(app, attr as CFString, &v) == .success && (v as? Bool) == true
        }
        if isOn("AXManualAccessibility") { return [] }
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if manual != .attributeUnsupported { return .manual }
        guard allowEnhanced, !isOn("AXEnhancedUserInterface") else { return [] }
        // Chromium reports an error here but still turns its tree on.
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return .enhanced
    }

    private static func switchOff(_ pid: pid_t, _ switches: Switched) {
        guard !switches.isEmpty else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        if switches.contains(.manual) {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse)
        }
        if switches.contains(.enhanced) {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
    }

    /// Asks the app to expose its Accessibility tree. Repeated on every scan
    /// because Electron forgets it when a renderer restarts.
    static func prime(pid: pid_t) {
        if switchOn(pid, allowEnhanced: !enhanced.contains(pid)).contains(.enhanced) { enhanced.insert(pid) }
    }

    /// Turns AXEnhancedUserInterface back off wherever Renew turned it on,
    /// except for `keep`.
    static func release(except keep: pid_t? = nil) {
        for pid in enhanced where pid != keep { release(pid: pid) }
    }

    /// Turns AXEnhancedUserInterface back off for one app, if Renew turned it on.
    static func release(pid: pid_t) {
        guard enhanced.remove(pid) != nil else { return }
        switchOff(pid, .enhanced)
    }

    /// Asks a Chromium browser to expose its pages' content, so
    /// `PageTextReader` can read a mixed site. Undone by `releaseBrowser`
    /// as soon as no mixed site is in front.
    static func primeBrowser(pid: pid_t) {
        let on = switchOn(pid, allowEnhanced: !browsersEnhanced.contains(pid))
        if on.contains(.manual) { browsersManual.insert(pid) }
        if on.contains(.enhanced) { browsersEnhanced.insert(pid) }
    }

    /// Switches back off whatever `primeBrowser` switched on for a browser.
    static func releaseBrowser(pid: pid_t) {
        var off: Switched = []
        if browsersManual.remove(pid) != nil { off.insert(.manual) }
        if browsersEnhanced.remove(pid) != nil { off.insert(.enhanced) }
        switchOff(pid, off)
    }

    struct Page: Equatable {
        let url: String
        let title: String
        /// What reading the page found (mixed sites only, when asked).
        var signals: PageSignals? = nil
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
    /// With `readMixed`, websites on mixed sites (see `SiteCategory`) are
    /// also read for `PageSignals`, each at most every
    /// `PageTextReader.rereadAfter` seconds.
    static func pages(pid: pid_t, readMixed: Bool = false) -> [Page] {
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
                    var page = Page(url: u, title: title)
                    if readMixed, let host = NormalizedURL(u)?.host, SiteCategory.of(url: u) == .mixed,
                       textReads.take(u) {
                        var reader = AXReader(timeout: 0.5, deadline: Date().addingTimeInterval(PageTextReader.deadline))
                        let text = PageTextReader.textParts(of: el, ax: &reader)
                        if text.main.isEmpty && text.others.isEmpty { textReads.giveBack(u) }
                        page.signals = PageSignals.find(host: host, parts: text.main, others: text.others)
                    }
                    pages.append(page)
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
