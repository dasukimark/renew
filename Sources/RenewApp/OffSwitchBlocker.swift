import AppKit
import ApplicationServices
import RenewShared

/// During a session, switches on the locked System Settings pages (see
/// `SettingsGuard`) can be turned on but not off, and items can't be removed
/// from their lists. Renew's own switches are protected on every page. The
/// rest of System Settings works as usual.
///
/// Event taps look at clicks and key presses aimed at System Settings and
/// drop the ones that would:
/// - click a switch or checkbox that is on (including dragging it off);
/// - click a remove (−) button;
/// - press Space on a focused switch that is on, or a remove button;
/// - press Delete in a list.
///
/// The taps are kept as narrow as they can be, so Renew doesn't look like a
/// keylogger to security software:
/// - they exist only while System Settings is running during a session, and
///   are removed (not just disabled) as soon as it quits or the session ends;
/// - the tap on all apps sees mouse clicks only, since a click on a System
///   Settings window can arrive while another app is frontmost;
/// - key presses are tapped per System Settings process
///   (`CGEvent.tapCreateForPid`), so typing in other apps never reaches Renew.
///
/// A tap holds up the input it sees while its callback runs, so events aimed
/// elsewhere pass after a cheap check, and Accessibility reads get a short
/// timeout each and a total budget well under the point where macOS disables
/// a slow tap. When System Settings doesn't answer within that budget on a
/// page that is (or may be) locked, the click is dropped rather than let
/// through, and the user can click again. Each tap runs on its own thread, so
/// a busy main thread never delays input.
final class OffSwitchBlocker {
    /// Called on the main thread with what was blocked.
    var onBlocked: ((String) -> Void)?

    private struct Tap {
        let port: CFMachPort
        let runLoop: CFRunLoop
    }

    /// What a tap's callback gets: the key taps know their process, so they
    /// never have to guess an event's target. Kept alive by the tap's thread.
    private final class TapContext {
        unowned let blocker: OffSwitchBlocker
        let pid: pid_t?
        init(_ blocker: OffSwitchBlocker, pid: pid_t?) {
            self.blocker = blocker
            self.pid = pid
        }
    }

    private let lock = NSLock()
    /// Guarded by `lock`. The taps are created and removed on the main thread
    /// only.
    private var mouseTap: Tap?
    private var keyTaps: [pid_t: Tap] = [:]
    private var settingsPIDs: Set<pid_t> = []
    private var loggedKeySeen = false

    /// Main thread only.
    private var lastFailure = Date.distantPast
    private var loggedFailure = false
    /// When a live System Settings process last refused a key tap.
    private var keyTapFailures: [pid_t: Date] = [:]
    /// The rest of a click whose mouse-down was dropped (mouse tap thread only).
    private var droppingClick = false

    static let callTimeout: Float = 0.1
    static let budget: TimeInterval = 0.4

    /// The running System Settings processes, kept by the monitor.
    func setSettingsPIDs(_ pids: Set<pid_t>) {
        lock.withLock { settingsPIDs = pids }
    }

    func addSettingsPID(_ pid: pid_t) {
        lock.withLock { _ = settingsPIDs.insert(pid) }
    }

    /// Creates the taps (`on`) or removes them. Returns false if the filter
    /// should be running but isn't fully (Accessibility off, or macOS refused
    /// the mouse tap or a key tap; that's retried once a minute), so the
    /// caller can fall back to closing the locked pages.
    @discardableResult
    func setActive(_ on: Bool) -> Bool {
        guard on else { removeTaps(); return true }
        if lock.withLock({ mouseTap == nil }) {
            guard AXIsProcessTrusted(), Date().timeIntervalSince(lastFailure) >= 60 else { return false }
            guard let tap = makeTap(pid: nil) else {
                lastFailure = Date()
                if !loggedFailure { log("couldn't start the System Settings switch filter; retrying every minute") }
                loggedFailure = true
                return false
            }
            lock.withLock { mouseTap = tap }
            log("System Settings switch filter started")
        }
        return syncKeyTaps()
    }

    /// Removes the taps as soon as Renew loses Accessibility. An active tap
    /// left in place after its app loses the permission can stall input
    /// (System Settings froze when Renew was switched off there). Called on
    /// the main thread every half second; the taps are recreated once the
    /// permission is back.
    func stopIfUntrusted() {
        guard lock.withLock({ mouseTap != nil || !keyTaps.isEmpty }), !AXIsProcessTrusted() else { return }
        removeTaps()
        lastFailure = .distantPast
        log("Accessibility is off for Renew; stopped the System Settings switch filter")
    }

    /// One key tap per running System Settings process. Returns false while
    /// a live process has none, since Space and Delete wouldn't be checked.
    private func syncKeyTaps() -> Bool {
        let (pids, existing): (Set<pid_t>, Set<pid_t>) = lock.withLock { (settingsPIDs, Set(keyTaps.keys)) }
        for pid in existing.subtracting(pids) {
            if let tap = lock.withLock({ keyTaps.removeValue(forKey: pid) }) { Self.remove(tap) }
        }
        keyTapFailures = keyTapFailures.filter { pids.contains($0.key) }
        var covered = true
        for pid in pids.subtracting(existing) {
            if let failed = keyTapFailures[pid], Date().timeIntervalSince(failed) < 60 {
                covered = false
                continue
            }
            if let tap = makeTap(pid: pid) {
                lock.withLock { keyTaps[pid] = tap }
                keyTapFailures[pid] = nil
                continue
            }
            // A System Settings that is still quitting also refuses a tap, so
            // only a live process counts as a failure.
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, kill(pid, 0) == 0 else { continue }
            if keyTapFailures[pid] == nil {
                log("couldn't start the System Settings key filter for pid \(pid); closing locked pages instead, retrying every minute")
            }
            keyTapFailures[pid] = Date()
            covered = false
        }
        return covered
    }

    private func removeTaps() {
        keyTapFailures = [:]
        let taps: [Tap] = lock.withLock {
            defer { mouseTap = nil; keyTaps = [:] }
            return (mouseTap.map { [$0] } ?? []) + Array(keyTaps.values)
        }
        guard !taps.isEmpty else { return }
        taps.forEach(Self.remove)
        log("System Settings switch filter removed")
    }

    private static func remove(_ tap: Tap) {
        CGEvent.tapEnable(tap: tap.port, enable: false)
        CFMachPortInvalidate(tap.port)
        CFRunLoopStop(tap.runLoop)
    }

    /// The mouse tap on all apps (`pid` nil), or the key tap for one process.
    private func makeTap(pid: pid_t?) -> Tap? {
        let types: [CGEventType] = pid == nil ? [.leftMouseDown, .leftMouseUp, .leftMouseDragged] : [.keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let context = Unmanaged<TapContext>.fromOpaque(refcon!).takeUnretainedValue()
            return context.blocker.handle(type, event, keyPID: context.pid)
        }
        let context = TapContext(self, pid: pid)
        let me = Unmanaged.passUnretained(context).toOpaque()
        let port: CFMachPort?
        if let pid {
            port = CGEvent.tapCreateForPid(pid: pid, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback, userInfo: me)
        } else {
            port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: mask, callback: callback, userInfo: me)
        }
        guard let port else { return nil }
        var runLoop: CFRunLoop?
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            withExtendedLifetime(context) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
                runLoop = CFRunLoopGetCurrent()
                ready.signal()
                CFRunLoopRun()
            }
        }
        thread.name = pid == nil ? "renew.settings-clicks" : "renew.settings-keys.\(pid!)"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return Tap(port: port, runLoop: runLoop!)
    }

    // MARK: tap threads

    /// `keyPID` is the process a key tap belongs to (nil for the mouse tap).
    private func handle(_ type: CGEventType, _ event: CGEvent, keyPID: pid_t?) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            let ports: [CFMachPort] = lock.withLock { (mouseTap.map { [$0.port] } ?? []) + keyTaps.values.map(\.port) }
            for port in ports where !CGEvent.tapIsEnabled(tap: port) { CGEvent.tapEnable(tap: port, enable: true) }
            return pass
        case .leftMouseDragged, .leftMouseUp:
            guard droppingClick else { return pass }
            if type == .leftMouseUp { droppingClick = false }
            return nil
        case .leftMouseDown:
            droppingClick = false
            let pids = lock.withLock { settingsPIDs }
            guard !pids.isEmpty else { return pass }
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
            guard let pid = keyPID else { return pass }
            let first: Bool = lock.withLock {
                defer { loggedKeySeen = true }
                return !loggedKeySeen
            }
            if first { DispatchQueue.main.async { log("System Settings key filter is receiving key presses") } }
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
            log("blocked \(what) on \(page) during a block session")
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
