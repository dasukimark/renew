import ApplicationServices
import Foundation

/// Accessibility attribute reads shared by the readers and System Settings code.
///
/// Every read sets `timeout` on the element it reads, so no caller depends on
/// the app-wide default (which a timeout on the system-wide element would
/// change for everyone). With a `deadline`, reads stop once it passes, and
/// `timedOut` records whether the target failed to answer in time.
struct AXReader {
    var timeout: Float
    var deadline: Date?
    private(set) var timedOut = false

    init(timeout: Float, deadline: Date? = nil) {
        self.timeout = timeout
        self.deadline = deadline
    }

    mutating func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        if let deadline, Date() >= deadline { timedOut = true; return nil }
        AXUIElementSetMessagingTimeout(el, timeout)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, attr as CFString, &value)
        if err == .cannotComplete { timedOut = true }
        return err == .success ? value : nil
    }

    mutating func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        Self.asElement(copy(el, attr))
    }

    mutating func string(_ el: AXUIElement, _ attr: String) -> String? {
        copy(el, attr) as? String
    }

    mutating func number(_ el: AXUIElement, _ attr: String) -> NSNumber? {
        copy(el, attr) as? NSNumber
    }

    mutating func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        number(el, attr)?.boolValue
    }

    mutating func children(_ el: AXUIElement) -> [AXUIElement]? {
        copy(el, kAXChildrenAttribute) as? [AXUIElement]
    }

    mutating func url(_ el: AXUIElement) -> String? {
        guard let v = copy(el, "AXURL") else { return nil }
        if let u = v as? URL { return u.absoluteString }
        return v as? String
    }

    /// Records a timeout from a call made outside the reader.
    mutating func note(_ err: AXError) {
        if err == .cannotComplete { timedOut = true }
    }

    var expired: Bool {
        mutating get {
            guard let deadline, Date() >= deadline else { return false }
            timedOut = true
            return true
        }
    }

    static func asElement(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
}
