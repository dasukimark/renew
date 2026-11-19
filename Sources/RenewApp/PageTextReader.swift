import ApplicationServices
import Foundation
import RenewShared

/// Reads the visible text of a page on a mixed site (see `SiteCategory`)
/// through the Accessibility tree, the way a screen reader does, so
/// `PageSignals.find` can look for the site's own NSFW labels and strong
/// explicit words. The text is classified straight away and dropped: only
/// the findings are kept.
///
/// Chromium browsers only expose page content while their tree is switched
/// on (`EmbeddedWebReader.primeBrowser`); Safari and Firefox always do.
enum PageTextReader {
    static let maxNodes = 4_000
    static let maxCharacters = 60_000
    static let deadline: TimeInterval = 1
    /// How often one page is read again while it stays in front (feeds
    /// load more as you scroll). A newly opened page is read straight away.
    static let rereadAfter: TimeInterval = 15

    /// What the front window of `pid` shows at `url`, or nil if its page
    /// couldn't be found or has no text yet (a Chromium tree just switched on).
    /// Only what's new since `state` last read `key` is returned.
    static func signals(pid: pid_t, url: String, state: PageReadState, key: String) -> PageSignals? {
        guard let host = NormalizedURL(url)?.host else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var ax = AXReader(timeout: 0.5, deadline: Date().addingTimeInterval(deadline))
        guard let window = ax.element(app, kAXFocusedWindowAttribute) ?? ax.element(app, kAXMainWindowAttribute),
              let area = webArea(in: window, url: url, ax: &ax) else { return nil }
        let text = textParts(of: area, ax: &ax)
        guard !text.main.isEmpty || !text.others.isEmpty else { return nil }
        return state.findings(key, host: host, parts: text.main, others: text.others)
    }

    /// An address without its fragment, trailing slash and case, to compare
    /// what the Accessibility tree and the browser's scripting report.
    static func comparable(_ url: String) -> String {
        var s = url.lowercased()
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// The page's web area: the one at `url`, or the only website in the
    /// window if none matches. With several and no match, nil: reading the
    /// wrong one would credit another page's text to this visit.
    private static func webArea(in window: AXUIElement, url: String, ax: inout AXReader) -> AXUIElement? {
        let wanted = comparable(url)
        var queue: [(el: AXUIElement, depth: Int)] = [(window, 0)]
        var head = 0
        var sites: [AXUIElement] = []
        while head < queue.count && head < 2_000 && !ax.expired {
            let (el, depth) = queue[head]
            head += 1
            if ax.string(el, kAXRoleAttribute) == "AXWebArea" {
                if let u = ax.url(el), u.lowercased().hasPrefix("http") {
                    if comparable(u) == wanted { return el }
                    sites.append(el)
                }
                continue // page content never holds the page itself
            }
            if depth < 40, let kids = ax.children(el) {
                for k in kids { queue.append((k, depth + 1)) }
            }
        }
        return sites.count == 1 ? sites[0] : nil
    }

    /// Landmarks that hold no page content of their own: site navigation,
    /// headers, sidebars (recommended videos, trends) and footers.
    static let skippedSubroles: Set<String> = ["AXLandmarkNavigation", "AXLandmarkBanner",
                                               "AXLandmarkComplementary", "AXLandmarkContentInfo"]

    /// The text in `area`, one piece per element: static text, and the
    /// titles and descriptions of headings, links, buttons and images (alt
    /// text). Navigation, headers, sidebars and footers are skipped. The
    /// first article found is the page's own post; text in later articles
    /// (replies, other posts) is returned in `others`.
    static func textParts(of area: AXUIElement, ax: inout AXReader) -> (main: [String], others: [String]) {
        var main: [String] = []
        var others: [String] = []
        var total = 0
        var queue: [(el: AXUIElement, other: Bool)] = [(area, false)]
        var head = 0
        var sawArticle = false
        while head < queue.count && head < maxNodes && total < maxCharacters && !ax.expired {
            var (el, other) = queue[head]
            head += 1
            let role = ax.string(el, kAXRoleAttribute) ?? ""
            let subrole = ax.string(el, kAXSubroleAttribute) ?? ""
            if skippedSubroles.contains(subrole) { continue }
            if subrole == "AXDocumentArticle", !other {
                if sawArticle { other = true } else { sawArticle = true }
            }
            var found: [String] = []
            if role == kAXStaticTextRole {
                if let v = ax.string(el, kAXValueAttribute) { found.append(v) }
            } else if role == "AXHeading" || role == "AXLink" || role == kAXButtonRole || role == kAXImageRole {
                for attr in [kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let v = ax.string(el, attr) { found.append(v) }
                }
            }
            for v in found {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                if other { others.append(t) } else { main.append(t) }
                total += t.count + 1
            }
            if let kids = ax.children(el) { queue.append(contentsOf: kids.map { ($0, other) }) }
        }
        return (main, others)
    }
}
