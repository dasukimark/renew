import AppKit
import RenewShared

/// Runs install/uninstall steps as root via the standard macOS admin-password prompt.
enum Privileged {
    enum Failure: Error, LocalizedError {
        case cancelled
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return "Cancelled."
            case .failed(let s): return s
            }
        }
    }

    /// Runs a shell command with administrator privileges. Blocks; call off the main thread.
    static func run(_ command: String, prompt: String) -> Result<String, Failure> {
        func q(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let source = "do shell script \"\(q(command))\" with prompt \"\(q(prompt))\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { return .failure(.failed("Couldn't build the script.")) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 { return .failure(.cancelled) }
            return .failure(.failed(error[NSAppleScript.errorMessage] as? String ?? "Error \(code)"))
        }
        return .success(result.stringValue ?? "")
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Shell prefix that (re)creates the root-owned log folder, refusing to
    /// follow a symlink someone may have planted in its place.
    private static var prepareLogDir: String {
        let dir = shellQuote(Paths.adminLogDir)
        return "if [ -L \(dir) ]; then rm -f \(dir); fi; /usr/bin/install -d -o root -g wheel -m 755 \(dir)"
    }

    /// Installs (or updates) Renew from the running app bundle.
    static func install() -> Result<String, Failure> {
        let bundle = Bundle.main.bundlePath
        guard let helper = Bundle.main.path(forResource: "install-helper", ofType: "sh") else {
            return .failure(.failed("install-helper.sh is missing from the app bundle."))
        }
        let log = shellQuote(Paths.installLog)
        let cmd = "\(prepareLogDir) && rm -f \(log) && /bin/bash \(shellQuote(helper)) \(shellQuote(bundle)) \(getuid()) > \(log) 2>&1 || { tail -5 \(log); exit 1; }"
        return run(cmd, prompt: "Renew needs your password to install its background service.")
    }

    /// Runs the uninstall detached, because it ends by stopping this app.
    static func uninstall() -> Result<String, Failure> {
        let cli = shellQuote(Paths.cliBinary)
        let log = shellQuote(Paths.uninstallLog)
        let cmd = "\(prepareLogDir) && rm -f \(log) && /usr/bin/nohup \(cli) uninstall --confirmed > \(log) 2>&1 &"
        return run(cmd, prompt: "Renew needs your password to uninstall.")
    }
}
