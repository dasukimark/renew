import AppKit
import RenewShared

/// The active tab of a browser window, plus enough to address that exact tab later.
struct TabRef {
    let url: String
    /// The page title, or "" if the browser didn't give one.
    let title: String
    /// AppleScript window id, or "" if the browser doesn't expose one.
    let windowID: String
    /// Chromium: tab id. Safari: tab index. "" if unavailable.
    let tabID: String
}

enum ScriptResult {
    case tab(TabRef)
    /// The browser is running but has no browser window/tab to check.
    case noPage
    /// errAEEventNotPermitted (-1743): Automation permission denied.
    case denied
    case failed(Int)
}

enum RedirectResult {
    case redirected
    /// The tab no longer shows the blocked URL (user switched/navigated): do nothing.
    case tabChanged
    case failed
}

/// Reads and sets the active tab URL of scriptable browsers.
/// Only ever called from the Monitor's single serial browser queue.
enum BrowserBridge {
    private static var getScripts: [String: NSAppleScript] = [:]

    private static func tabRef(_ kind: BrowserKind) -> String {
        kind == .safari ? "current tab" : "active tab"
    }

    /// Tab title property: Safari calls it `name`, Chromium browsers `title`.
    private static func titleKey(_ kind: BrowserKind) -> String {
        kind == .safari ? "name of t" : "title of t"
    }

    /// Tab identifier expression: Chromium tabs have stable ids, Safari tabs only indexes.
    private static func tabKey(_ kind: BrowserKind) -> String {
        kind == .safari ? "index of t" : "id of t"
    }

    static func activeTab(bundleID: String, kind: BrowserKind) -> ScriptResult {
        let script: NSAppleScript
        if let cached = getScripts[bundleID] {
            script = cached
        } else {
            // Windows are ordered front to back. Skip any that have no tabs
            // (Settings, Downloads, …) instead of failing on them.
            let source = """
            with timeout of 3 seconds
                tell application id "\(bundleID)"
                    repeat with w in windows
                        try
                            set t to \(tabRef(kind)) of w
                            set u to URL of t
                            if u is missing value then set u to ""
                            set wid to ""
                            set tid to ""
                            try
                                set wid to (id of w) as text
                            end try
                            try
                                set tid to (\(tabKey(kind))) as text
                            end try
                            set ttl to ""
                            try
                                set ttl to (\(titleKey(kind))) as text
                            end try
                            return wid & linefeed & tid & linefeed & u & linefeed & ttl
                        on error errMsg number errNum
                            -- A window without tabs is skipped; timeouts and
                            -- permission errors must still reach the caller.
                            if errNum is -1712 or errNum is -1743 then error errMsg number errNum
                        end try
                    end repeat
                    return ""
                end tell
            end timeout
            """
            guard let s = NSAppleScript(source: source) else { return .failed(-1) }
            var compileError: NSDictionary?
            guard s.compileAndReturnError(&compileError) else {
                return .failed(compileError?[NSAppleScript.errorNumber] as? Int ?? -1)
            }
            getScripts[bundleID] = s
            script = s
        }

        switch run(script) {
        case .success(let text):
            let parts = text.components(separatedBy: "\n")
            guard parts.count >= 3 else { return .noPage }
            // A URL never contains a line break; a title might.
            let url = parts[2]
            if url.isEmpty { return .noPage }
            let title = parts.count > 3 ? parts[3...].joined(separator: " ").trimmingCharacters(in: .whitespaces) : ""
            return .tab(TabRef(url: url, title: title, windowID: parts[0], tabID: parts[1]))
        case .failure(let code):
            return code == -1743 ? .denied : .failed(code)
        }
    }

    /// Replaces `tab` with `newURL`, but only if that same tab still shows the
    /// URL we checked. Otherwise the user moved on and we leave it alone.
    static func redirect(bundleID: String, kind: BrowserKind, tab: TabRef, to newURL: String) -> RedirectResult {
        let target: String
        if !tab.windowID.isEmpty && !tab.tabID.isEmpty {
            let tabExpr = kind == .safari ? "tab \(tab.tabID)" : "tab id \(tab.tabID)"
            target = "\(tabExpr) of window id \(tab.windowID)"
        } else {
            target = "\(tabRef(kind)) of front window"
        }
        let source = """
        with timeout of 3 seconds
            tell application id "\(bundleID)"
                set t to \(target)
                if (URL of t) is "\(escape(tab.url))" then
                    set URL of t to "\(escape(newURL))"
                    return "ok"
                end if
                return "moved"
            end tell
        end timeout
        """
        guard let script = NSAppleScript(source: source) else { return .failed }
        switch run(script) {
        case .success(let r): return r == "ok" ? .redirected : .tabChanged
        case .failure(let code): return code == -1728 ? .tabChanged : .failed // -1728: tab/window gone
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private enum Outcome { case success(String), failure(Int) }

    private static func run(_ script: NSAppleScript) -> Outcome {
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            return .failure(error[NSAppleScript.errorNumber] as? Int ?? 0)
        }
        return .success(descriptor.stringValue ?? "")
    }
}
