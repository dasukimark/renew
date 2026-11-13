import AppKit
import RenewShared

// Renew [--background] [--local-session <duration> <SITE>...]
//
// --background       launched by launchd at login: stay in the menu bar, no window.
// --local-session    a throwaway session without the background service, for trying blocking out.
let args = CommandLine.arguments
var localSession: SessionInfo?
if let i = args.firstIndex(of: "--local-session") {
    guard i + 1 < args.count, let seconds = DurationText.parse(args[i + 1]) else {
        FileHandle.standardError.write(Data("usage: Renew --local-session <duration> <SITE>...\n".utf8))
        exit(64)
    }
    let rules = canonicalRules(Array(args.dropFirst(i + 2))).valid
    localSession = SessionInfo(startedAt: Date(), endsAt: Date().addingTimeInterval(TimeInterval(seconds)), rules: rules)
}

// Log to ~/Library/Logs/Renew/app.log (not a shared /tmp path).
if args.contains("--background") {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Renew")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("app.log").path
    freopen(path, "a", stdout)
    freopen(path, "a", stderr)
    setvbuf(stdout, nil, _IOLBF, 0)
}

let app = NSApplication.shared
let delegate = AppDelegate(localSession: localSession, launchedInBackground: args.contains("--background"))
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
