import Foundation
import RenewShared

func die(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("renew: \(message)\n".utf8))
    exit(code)
}

func clock(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
    f.timeStyle = .short
    return f.string(from: date)
}

func send(_ request: Request) -> Status {
    let response: Response
    do {
        response = try DaemonClient.send(request)
    } catch {
        die(String(describing: error))
    }
    guard response.ok, let status = response.status else {
        die(response.error ?? "renewd refused the request")
    }
    return status
}

let usage = """
Renew command line (the Renew app does all of this too): watches your browsers and replaces blocked pages with a block page.

Usage:
  renew start <duration> [--list NAME]... [SITE]...   start (or lengthen) a session
  renew extend <duration>                              add time to the running session
  renew add <SITE>...                                  block more sites in the running session
  renew status                                         show the session and agent health
  renew lists                                          show all blocklists
  renew lists add <NAME> <SITE>...                     add sites to a list (creates it)
  renew lists remove <NAME> [SITE]...                  remove sites, or reset/delete the list
  renew check <URL> [--list NAME]... [SITE]...         test whether a URL would be blocked
  renew alerts                                         show where tamper alerts go
  renew alerts set <URL>                               send tamper alerts to a URL (e.g. https://ntfy.sh/<topic>)
  renew alerts off                                     turn alerts off (between sessions only)
  renew alerts test                                    send a test alert
  renew uninstall                                      request uninstall (unlocks after 24 hours)
  sudo renew uninstall                                 finish an unlocked uninstall (only between sessions)
  renew uninstall --cancel                             cancel an uninstall request

Durations: 25m, 2h, 1h30m, 1d (a bare number means minutes)
Sites:     reddit.com          domain and subdomains
           youtube.com/shorts  a path on a domain
           keyword:casino      any URL containing the word
           !music.youtube.com  allow exception

Sessions can't be shortened or stopped once started.
"""

/// Splits `--list NAME` / `-l NAME` flags from positional site rules.
func collectRules(_ args: [String]) -> [String] {
    var rules: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "--list" || a == "-l" {
            guard i + 1 < args.count else { die("--list needs a name") }
            let name = args[i + 1]
            guard let list = ListStore.get(name) else {
                die("no list named '\(name)'. Available: \(ListStore.all().keys.sorted().joined(separator: ", "))")
            }
            rules += list
            i += 2
        } else if a.hasPrefix("--list=") {
            let name = String(a.dropFirst("--list=".count))
            guard let list = ListStore.get(name) else { die("no list named '\(name)'") }
            rules += list
            i += 1
        } else {
            rules.append(a)
            i += 1
        }
    }
    let (valid, rejected) = canonicalRules(rules)
    if !rejected.isEmpty { die("invalid site rule(s): \(rejected.joined(separator: ", "))") }
    return valid
}

func printStatus(_ s: Status) {
    guard let session = s.session else {
        print("No focus session running.")
        printAgents(s)
        return
    }
    let left = Int(session.endsAt.timeIntervalSince(s.serverTime))
    print("● Focus session active: \(DurationText.format(left)) left (ends \(clock(session.endsAt)))")
    print("  Blocking: \(session.rules.joined(separator: ", "))")
    printAgents(s)
}

func printExtras(_ s: Status) {
    print("  Alerts: \(s.alertURL ?? "off")")
    if let u = s.uninstall {
        print(u.unlocked ? "  Uninstall: unlocked until \(clock(u.expiresAt)) (sudo renew uninstall)"
                         : "  Uninstall: requested, unlocks \(clock(u.unlocksAt))")
    }
}

func printAgents(_ s: Status) {
    if s.agents.isEmpty {
        print("  Agent: not reporting yet")
        return
    }
    for a in s.agents {
        let ago = Int(s.serverTime.timeIntervalSince(a.lastSeen))
        let health = a.permissionsOK ? "monitoring OK" : "PROBLEM: \(a.problem ?? "permissions missing")"
        print("  Agent (uid \(a.uid)): \(health), last seen \(ago)s ago")
    }
}

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()

switch command {
case "start":
    guard let first = args.first, let seconds = DurationText.parse(first) else {
        die("usage: renew start <duration> [--list NAME]... [SITE]...")
    }
    let rules = collectRules(Array(args.dropFirst()))
    let before = try? DaemonClient.send(Request(cmd: .status))
    let status = send(Request(cmd: .start, durationSeconds: seconds, rules: rules))
    if before?.status?.session != nil { print("A session was already running; it was lengthened and the new sites were added.") }
    printStatus(status)
    if let me = status.agents.first(where: { $0.uid == getuid() }), !me.permissionsOK {
        print("\n⚠︎ Renew is missing permissions (\(me.problem ?? "")). Browsers it can't watch are closed during the session.")
    } else if !status.agents.contains(where: { $0.uid == getuid() }) {
        print("\n⚠︎ No agent has reported for your user yet. Is the Renew app running?")
    }

case "extend":
    guard let first = args.first, let seconds = DurationText.parse(first) else { die("usage: renew extend <duration>") }
    printStatus(send(Request(cmd: .extend, durationSeconds: seconds)))

case "add":
    let rules = collectRules(args)
    guard !rules.isEmpty else { die("usage: renew add <SITE>...") }
    printStatus(send(Request(cmd: .add, rules: rules)))

case "status":
    let st = send(Request(cmd: .status))
    printStatus(st)
    printExtras(st)

case "alerts":
    switch args.first ?? "show" {
    case "show":
        print("Alerts: \(send(Request(cmd: .status)).alertURL ?? "off")")
    case "set":
        guard args.count == 2 else { die("usage: renew alerts set <URL>") }
        let st = send(Request(cmd: .setAlerts, alertURL: args[1]))
        print("Alerts go to \(st.alertURL ?? "?"). A confirmation was sent there.")
    case "off":
        _ = send(Request(cmd: .setAlerts, alertURL: nil))
        print("Alerts are off.")
    case "test":
        _ = send(Request(cmd: .testAlert))
        print("Test alert sent.")
    default:
        die("usage: renew alerts [show | set URL | off | test]")
    }

case "lists":
    let sub = args.first ?? "show"
    switch sub {
    case "show", "ls":
        let all = ListStore.all()
        let only = args.count > 1 ? [args[1].lowercased()] : all.keys.sorted()
        for name in only {
            guard let rules = all[name] else { die("no list named '\(name)'") }
            print("\(name):")
            for r in rules { print("  \(r)") }
        }
        print("\n(edit with `renew lists add/remove`; stored in \(ListStore.fileURL.path))")
    case "add":
        guard args.count >= 3 else { die("usage: renew lists add <NAME> <SITE>...") }
        let extra = Array(args.dropFirst(2))
        let rejected = canonicalRules(extra).rejected
        if !rejected.isEmpty { die("invalid site rule(s): \(rejected.joined(separator: ", "))") }
        do {
            let list = try ListStore.add(args[1], extra)
            print("\(args[1].lowercased()): \(list.joined(separator: ", "))")
        } catch { die("couldn't save lists: \(error)") }
    case "remove", "rm":
        guard args.count >= 2 else { die("usage: renew lists remove <NAME> [SITE]...") }
        do {
            let remaining = try ListStore.remove(args[1], Array(args.dropFirst(2)))
            print("\(args[1].lowercased()): \(remaining?.joined(separator: ", ") ?? "(deleted)")")
        } catch { die("couldn't save lists: \(error)") }
    default:
        die("usage: renew lists [show [NAME] | add NAME SITE... | remove NAME [SITE...]]")
    }

case "check":
    guard let url = args.first else { die("usage: renew check <URL> [--list NAME]... [SITE]...") }
    var rules = collectRules(Array(args.dropFirst()))
    if rules.isEmpty, let r = try? DaemonClient.send(Request(cmd: .status)), let s = r.status?.session {
        rules = s.rules
    }
    guard !rules.isEmpty else { die("no rules: pass sites/--list, or run during a session") }
    if let hit = RuleSet(strings: rules).match(url) {
        print("BLOCKED by \(hit)")
    } else {
        print("allowed")
        exit(2)
    }

case "uninstall":
    if args.contains("--cancel") { Uninstall.cancel() }
    Uninstall.run(confirmed: args.contains("--confirmed"))

case "help", "-h", "--help":
    print(usage)

default:
    die("unknown command '\(command)'. Run `renew help`.")
}
