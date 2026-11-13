import ApplicationServices
import Foundation

/// Firefox has no AppleScript dictionary, so read the current page URL through
/// the Accessibility tree: prefer the web area's AXURL, and fall back to the
/// address bar's value when the bar isn't being edited.
enum FirefoxReader {
    static func activeURL(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else {
            return nil
        }

        var queue: [(el: AXUIElement, depth: Int, inToolbar: Bool)] = [(window, 0, false)]
        var head = 0
        var addressBar: String?
        while head < queue.count && head < 2_000 {
            let (el, depth, inToolbar) = queue[head]
            head += 1
            let role = string(el, kAXRoleAttribute) ?? ""

            if role == "AXWebArea", let u = url(el), u.lowercased().hasPrefix("http") {
                return u
            }
            if addressBar == nil, role == kAXTextFieldRole || role == kAXComboBoxRole {
                let domID = string(el, "AXDOMIdentifier")
                if domID == "urlbar-input" || inToolbar, !(bool(el, kAXFocusedAttribute) ?? false) {
                    addressBar = string(el, kAXValueAttribute)
                }
            }
            // Don't walk into page content: it can be huge and never holds the URL.
            if role == "AXWebArea" && depth > 0 { continue }
            if depth < 30, let kids = children(el) {
                let childInToolbar = inToolbar || role == kAXToolbarRole
                for k in kids { queue.append((k, depth + 1, childInToolbar)) }
            }
        }
        return addressBar
    }

    private static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = copy(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        copy(el, attr) as? String
    }

    private static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        (copy(el, attr) as? NSNumber)?.boolValue
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement]? {
        copy(el, kAXChildrenAttribute) as? [AXUIElement]
    }

    private static func url(_ el: AXUIElement) -> String? {
        guard let v = copy(el, "AXURL") else { return nil }
        if let u = v as? URL { return u.absoluteString }
        return v as? String
    }
}
