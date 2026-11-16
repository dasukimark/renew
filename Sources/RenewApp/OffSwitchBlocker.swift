import AppKit
import ApplicationServices
import RenewShared

/// During a session, switches on the locked System Settings pages (see
/// `SettingsGuard`) can be turned on but not off, and items can't be removed
/// from their lists. Renew's own switches are protected on every page. The
/// rest of System Settings works as usual.
///
/// An event tap looks at clicks and key presses aimed at System Settings and
/// drops the ones that would:
/// - click a switch or checkbox that is on (including dragging it off);
/// - click a remove (−) button;
/// - press Space on a focused switch that is on, or a remove button;
/// - press Delete in a list.
///
/// The tap holds up all input while its callback runs, so it's only enabled
/// while System Settings is running, events aimed elsewhere pass after a
/// cheap check, and Accessibility reads get a short timeout each and a total
/// budget well under the point where macOS disables a slow tap. When System
/// Settings doesn't answer within that budget on a page that is (or may be)
/// locked, the click is dropped rather than let through, and the user can
/// click again. The tap runs on its own thread, so a busy main thread never
/// delays input.
final class OffSwitchBlocker {
    /// Called on the main thread with what was blocked.
    var onBlocked: ((String) -> Void)?

    private let lock = NSLock()
    /// Guarded by `lock`. `tap` and `tapRunLoop` are written on the main
    /// thread only.
    private var tap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    private var active = false
    private var settingsPIDs: Set<pid_t> = []
    private var frontmostPID: pid_t = 0

    /// Main thread only.
    private var lastStartAttempt = Date.distantPast
    private var loggedStartFailure = false
    /// The rest of a click whose mouse-down was dropped (tap thread only).
    private var droppingClick = false

    static let callTimeout: Float = 0.1
    static let budget: TimeInterval = 0.4

    var isRunning: Bool { lock.withLock { tap != nil } }

    /// The running System Settings processes, kept by the monitor.
    func setSettingsPIDs(_ pids: Set<pid_t>) {
        lock.withLock { settingsPIDs = pids }
    }

    func addSettingsPID(_ pid: pid_t) {
        lock.withLock { _ = settingsPIDs.insert(pid) }
    }

    /// The frontmost app, kept by the monitor: key events at the session tap
    /// don't always carry their target process yet.
    func setFrontmostPID(_ pid: pid_t) {
        lock.withLock { frontmostPID = pid }
    }

    /// Ensures the tap exists, then enables or disables it. Returns false if
    /// the tap isn't running (Accessibility off, or macOS refused it; that's
    /// retried once a minute).
    @discardableResult
    func ensureStarted(enabled on: Bool) -> Bool {
        if lock.withLock({ tap == nil }), AXIsProcessTrusted(), Date().timeIntervalSince(lastStartAttempt) >= 60 {
            lastStartAttempt = Date()
            start()
        }
        guard lock.withLock({ tap != nil }) else { return false }
        setEnabled(on)
        return true
    }

    func setEnabled(_ on: Bool) {
        guard let tap = lock.withLock({ tap }) else { return }
        let changed: Bool = lock.withLock {
            defer { active = on }
            return active != on
        }
        if changed { CGEvent.tapEnable(tap: tap, enable: on) }
    }

    /// Removes the tap as soon as Renew loses Accessibility. An active tap
    /// left in place after its app loses the permission can stall input
    /// (System Settings froze when Renew was switched off there). Called on
    /// the main thread every half second; the tap is recreated once the
    /// permission is back.
    func stopIfUntrusted() {
        guard let tap = lock.withLock({ tap }), !AXIsProcessTrusted() else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        let runLoop: CFRunLoop? = lock.withLock {
            defer { self.tap = nil; tapRunLoop = nil; active = false }
            return tapRunLoop
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        lastStartAttempt = .distantPast
        log("Accessibility is off for Renew; stopped the System Settings switch filter")
    }

    private func start() {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                Unmanaged<OffSwitchBlocker>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            if !loggedStartFailure { log("couldn't start the System Settings switch filter; retrying every minute") }
            loggedStartFailure = true
            return
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        lock.withLock { self.tap = tap }
        let thread = Thread { [weak self] in
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            self?.lock.withLock { self?.tapRunLoop = CFRunLoopGetCurrent() }
            CFRunLoopRun()
        }
        thread.name = "renew.settings-switches"
        thread.qualityOfService = .userInteractive
        thread.start()
        log("System Settings switch filter started")
    }

    // MARK: tap thread

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let (on, pids, front, tap): (Bool, Set<pid_t>, pid_t, CFMachPort?) =
            lock.withLock { (self.active, self.settingsPIDs, self.frontmostPID, self.tap) }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if on, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .leftMouseDragged, .leftMouseUp:
            guard droppingClick else { return pass }
            if type == .leftMouseUp { droppingClick = false }
            return nil
        case .leftMouseDown:
            droppingClick = false
            guard on, !pids.isEmpty else { return pass }
            // The window under the pointer, not the event's target app: a
            // click on a background window goes to that window's app.
            let owner = Self.windowOwner(at: event.location)
            guard let pid = owner, pids.contains(pid) else {
                let target = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
                if pids.contains(target) {
                    DispatchQueue.main.async {
                        log("System Settings click let through during a session: window under the pointer belongs to pid \(owner.map(String.init) ?? "none")")
                    }
                }
                return pass
            }
            var check = SettingsCheck(pid: pid)
            guard let what = check.click(at: event.location) else {
                letThrough(check)
                return pass
            }
            droppingClick = true
            report(what, page: check.page)
            return nil
        case .keyDown:
            let space: Bool
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 49: space = true
            case 51, 117: space = false
            default: return pass
            }
            guard on else { return pass }
            let target = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
            let pid = pids.contains(target) ? target : front
            guard pids.contains(pid) else { return pass }
            var check = SettingsCheck(pid: pid)
            guard let what = check.key(space: space) else {
                letThrough(check)
                return pass
            }
            report(what, page: check.page)
            return nil
        default:
            return pass
        }
    }

    /// The process owning the frontmost on-screen window under `point`
    /// (global coordinates, top-left origin, as in events), skipping Renew's
    /// own click-through banners.
    private static func windowOwner(at point: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let me = getpid()
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b), rect.contains(point) else { continue }
            return pid
        }
        return nil
    }

    /// Logs what was under the pointer for an event that was let through, so
    /// a page whose controls aren't recognised shows up in the log.
    private func letThrough(_ check: SettingsCheck) {
        let trail = check.trail.joined(separator: " < ")
        DispatchQueue.main.async {
            log("System Settings click let through during a session: \(trail.isEmpty ? "nothing readable under the pointer" : trail)")
        }
    }

    private func report(_ what: String, page: String) {
        DispatchQueue.main.async { [weak self] in
            log("blocked \(what) on \(page) during a focus session")
            self?.onBlocked?(what)
        }
    }
}

/// One event's Accessibility reads against System Settings, within the
/// blocker's per-call timeout and total budget.
private struct SettingsCheck {
    let app: AXUIElement
    var ax = AXReader(timeout: OffSwitchBlocker.callTimeout, deadline: Date().addingTimeInterval(OffSwitchBlocker.budget))
    var page = "System Settings"
    /// Whether the page is locked: nil if its titles couldn't be read in time.
    private var locked: Bool?
    /// Roles read on the way up from the hit element, for the log.
    var trail: [String] = []

    static let noAnswer = "a click System Settings didn't answer in time (try again)"

    init(pid: pid_t) {
        app = AXUIElementCreateApplication(pid)
    }

    /// What clicking at `point` would turn off, or nil to let it through.
    mutating func click(at point: CGPoint) -> String? {
        readPage()
        guard let hit = systemWide({ sw, out in AXUIElementCopyElementAtPosition(sw, Float(point.x), Float(point.y), &out) }),
              let action = offAction(hit, depth: 3) else { return unanswered() }
        return verdict(action)
    }

    /// What Space (or Delete) on the focused control would turn off.
    mutating func key(space: Bool) -> String? {
        readPage()
        guard let focused = systemWide({ sw, out in
            var v: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(sw, kAXFocusedUIElementAttribute as CFString, &v)
            out = AXReader.asElement(v)
            return err
        }) else { return unanswered() }
        if space {
            guard let action = offAction(focused, depth: 0) else { return unanswered() }
            return verdict(action)
        }
        guard inList(focused) else { return unanswered() }
        return locked == true ? "Delete in a list" : unanswered()
    }

    private enum OffAction {
        case switchOff(AXUIElement)
        case remove
    }

    /// Renew's own switches are protected on every page; everything else only
    /// on the locked pages.
    private mutating func verdict(_ action: OffAction) -> String? {
        if case .switchOff(let el) = action, mentionsRenew(el) { return "turning off Renew" }
        guard locked == true else { return unanswered() }
        switch action {
        case .switchOff(let el): return "turning off \(label(of: el).map { "“\($0)”" } ?? "a switch")"
        case .remove: return "removing an item"
        }
    }

    /// For an event that wasn't matched: drop it only if a read timed out and
    /// the page is locked, or its title couldn't be read either. Slow pages
    /// that aren't locked keep working.
    private func unanswered() -> String? {
        ax.timedOut && locked != false ? Self.noAnswer : nil
    }

    /// Reads the titles of the focused and main windows first, so a later
    /// timeout can be judged. A sheet (like Login Items' info sheet) is part
    /// of its window, and a secondary window counts if either title is locked.
    private mutating func readPage() {
        var titles: [String] = []
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let w = ax.element(app, attr), let t = ax.string(w, kAXTitleAttribute) { titles.append(t) }
        }
        if let lockedTitle = titles.first(where: SettingsGuard.isLocked) {
            locked = true
            page = lockedTitle
        } else {
            locked = titles.isEmpty && ax.timedOut ? nil : false
            page = titles.first ?? page
        }
    }

    /// What activating `el` (or the control it's part of) would turn off.
    private mutating func offAction(_ el: AXUIElement, depth: Int) -> OffAction? {
        var current: AXUIElement? = el
        for _ in 0...depth {
            guard let e = current else { return nil }
            let role = ax.string(e, kAXRoleAttribute)
            trail.append(role ?? "?")
            switch role {
            case kAXCheckBoxRole?:
                let value = ax.number(e, kAXValueAttribute)
                trail[trail.count - 1] += "=\(value?.stringValue ?? "?")"
                guard let n = value, n.intValue != 0 else { return nil }
                return .switchOff(e)
            case kAXButtonRole?:
                guard let l = label(of: e)?.lowercased(), ["remove", "delete", "−", "-"].contains(l) else { return nil }
                return .remove
            default:
                current = ax.element(e, kAXParentAttribute)
            }
        }
        return nil
    }

    /// Whether the switch, or the row it sits in, is labelled exactly "Renew"
    /// (an exact match, so "Automatically renew…" doesn't count). Looks at
    /// the switch's parent and grandparent, but not a container holding many
    /// rows, so a neighbouring row can't match.
    private mutating func mentionsRenew(_ control: AXUIElement) -> Bool {
        func isRenew(_ s: String?) -> Bool { s?.trimmingCharacters(in: .whitespaces) == "Renew" }
        if isRenew(label(of: control)) { return true }
        var current = ax.element(control, kAXParentAttribute)
        for _ in 0..<2 {
            guard let e = current, let kids = ax.children(e), kids.count <= 8 else { return false }
            for k in kids {
                for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] where isRenew(ax.string(k, attr)) {
                    return true
                }
            }
            current = ax.element(e, kAXParentAttribute)
        }
        return false
    }

    private mutating func inList(_ el: AXUIElement) -> Bool {
        let lists: Set<String> = [kAXTableRole, kAXOutlineRole, kAXListRole, kAXRowRole, kAXCellRole]
        var current: AXUIElement? = el
        for _ in 0..<3 {
            guard let e = current else { return false }
            if let r = ax.string(e, kAXRoleAttribute), lists.contains(r) { return true }
            current = ax.element(e, kAXParentAttribute)
        }
        return false
    }

    private mutating func label(of el: AXUIElement) -> String? {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s = ax.string(el, attr)?.trimmingCharacters(in: .whitespaces), !s.isEmpty { return s }
        }
        return nil
    }

    /// A lookup through the system-wide element, which (unlike System
    /// Settings' own element) reaches pages drawn by its helper processes.
    /// A timeout on the system-wide element is app-wide, so it's set for this
    /// one call and reset to the default after; every other Accessibility
    /// read in Renew goes through `AXReader`, which sets its own timeout on
    /// each element and so isn't affected.
    private mutating func systemWide(_ body: (AXUIElement, inout AXUIElement?) -> AXError) -> AXUIElement? {
        guard !ax.expired else { return nil }
        let sw = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sw, OffSwitchBlocker.callTimeout)
        defer { AXUIElementSetMessagingTimeout(sw, 0) }
        var out: AXUIElement?
        ax.note(body(sw, &out))
        return out
    }
}
