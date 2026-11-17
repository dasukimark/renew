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
  renew schedules                                      show scheduled block sessions (set them up in the app)
  renew lists                                          show all blocklists
  renew lists add <NAME> <SITE>...                     add sites to a list (creates it)
  renew lists remove <NAME> [SITE]...                  remove sites, or reset/delete the list
  renew check <URL> [--list NAME]... [SITE]...         test whether a URL would be blocked
  renew alerts                                         show where tamper alerts go
  renew alerts set <URL>                               send tamper alerts to a URL (e.g. https://ntfy.sh/<topic>)
  renew alerts off                                     turn alerts off (between sessions only)
  renew alerts test                                    send a test alert
  renew protections                                    show which hardening protections are on
  renew protections on|off <NAME>...                   turn protections on, or off (between sessions only)
  renew monitor                                        show activity monitoring settings
  renew monitor on|off                                 turn activity monitoring on or off
  renew monitor watch <LIST>...                        flag visits to these lists' sites ("explicit" = preset)
  renew monitor sites add|remove <SITE>...             flag visits to other sites
  renew monitor words add|remove <WORD>...             flag page titles containing a word or phrase
  renew monitor words preset on|off                    flag page titles containing common explicit words
  renew activity [--date YYYY-MM-DD] [--flagged]       show the pages you visited (default: today)
  sudo renew uninstall                                 uninstall Renew (only between sessions)
  renew uninstall                                      with the cooling-off on: request uninstall (unlocks after 24 hours)
  renew uninstall --cancel                             cancel an uninstall request

Protections (all off unless you turn them on):
  keep-running     during sessions, Renew's services restart each other and restore deleted files
  lock-settings    during sessions, System Settings switches for Renew and permissions turn on, not off
  close-browsers   during sessions, browsers Renew can't watch are closed
  cooling-off      uninstalling needs a request and a 24-hour wait (turning this off takes 24 hours too)
  all              every one of the above

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
        print("No block session running.")
        printAgents(s)
        return
    }
    let left = Int(session.endsAt.timeIntervalSince(s.serverTime))
    print("● Block session active: \(DurationText.format(left)) left (ends \(clock(session.endsAt)))")
    print("  Blocking: \(session.rules.joined(separator: ", "))")
    printAgents(s)
}

func printExtras(_ s: Status) {
    print("  Alerts: \(s.alertURL ?? "off")")
    if let p = s.protections {
        print("  Protections: \(p.onNames.isEmpty ? "none" : p.onNames.joined(separator: ", "))")
    }
    if let when = s.coolingOffRemovalAt { print("  Cooling-off: turns off \(clock(when))") }
    if let u = s.uninstall {
        print(u.unlocked ? "  Uninstall: unlocked until \(clock(u.expiresAt)) (sudo renew uninstall)"
                         : "  Uninstall: requested, unlocks \(clock(u.unlocksAt))")
    }
}

/// After a blocklist edit, hands the renewd the schedules re-resolved
/// against the new lists, so they don't wait for the app to notice.
func syncSchedules() {
    guard let status = (try? DaemonClient.send(Request(cmd: .status)))?.status else { return }
    let desired = BlockSessionStore.schedules()
    guard desired != (status.schedules ?? []) else { return }
    do {
        let r = try DaemonClient.send(Request(cmd: .setSchedules, schedules: desired))
        if r.ok {
            print("Updated the scheduled block sessions that use this list.")
        } else {
            print("⚠︎ Couldn't update scheduled block sessions: \(r.error ?? "refused")")
        }
    } catch {
        print("⚠︎ Couldn't update scheduled block sessions: \(error)")
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

case "schedules":
    let st = send(Request(cmd: .status))
    guard let schedules = st.schedules, !schedules.isEmpty else {
        print("No scheduled block sessions. Create them in the Renew app under Block Sessions.")
        exit(0)
    }
    for sc in schedules {
        let state: String
        if let end = sc.activeWindowEnd(at: st.serverTime) {
            state = "active until \(clock(end))"
        } else if let next = sc.nextStart(after: st.serverTime) {
            state = "next \(clock(next))"
        } else {
            state = "no upcoming start"
        }
        print("\(sc.name.isEmpty ? "(untitled)" : sc.name): \(sc.summary()) (\(state))")
        print("  Blocking: \(sc.rules.joined(separator: ", "))")
    }

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

case "protections":
    let sub = args.first ?? "show"
    func show(_ st: Status) {
        guard let p = st.protections else { die("This Renew service predates protections. Reinstall Renew.") }
        for item in Protections.catalog {
            var line = "  \(p[keyPath: item.key] ? "on " : "off") \(item.name.padding(toLength: 16, withPad: " ", startingAt: 0))\(item.label)"
            if item.key == \Protections.uninstallCoolingOff, let when = st.coolingOffRemovalAt {
                line += " (turns off \(clock(when)); `renew protections on cooling-off` cancels)"
            }
            print(line)
        }
    }
    switch sub {
    case "show":
        show(send(Request(cmd: .status)))
    case "on", "off":
        let names = Array(args.dropFirst())
        let known = Protections.allNames.joined(separator: ", ")
        guard !names.isEmpty else { die("usage: renew protections \(sub) <NAME>... (\(known))") }
        let current = send(Request(cmd: .status))
        // Built on the requested set, so a pending cooling-off removal isn't cancelled.
        guard var p = current.requestedProtections else { die("This Renew service predates protections. Reinstall Renew.") }
        for name in names {
            guard let keys = Protections.keys(named: name) else { die("unknown protection '\(name)'. Use: \(known)") }
            for k in keys { p[keyPath: k] = sub == "on" }
        }
        let st = send(Request(cmd: .setProtections, protections: p))
        show(st)
    default:
        die("usage: renew protections [show | on NAME... | off NAME...]")
    }

case "monitor":
    func show(_ st: Status) {
        guard let m = st.monitoring else { die("This Renew service predates activity monitoring. Reinstall Renew.") }
        print("Activity monitoring: \(m.enabled ? "on" : "off")")
        print("  Flagged lists: \(m.watchLists.isEmpty ? "none" : m.watchLists.joined(separator: ", "))")
        print("  Other sites:   \(m.customDomains.isEmpty ? "none" : m.customDomains.joined(separator: ", "))")
        print("  Explicit words in titles: \(m.flagExplicitTerms ? "on" : "off")")
        print("  Other words:   \(m.customTerms.isEmpty ? "none" : m.customTerms.joined(separator: ", "))")
    }
    func change(_ edit: (inout MonitoringSettings) -> Void) {
        guard var m = send(Request(cmd: .status)).monitoring else { die("This Renew service predates activity monitoring. Reinstall Renew.") }
        edit(&m)
        show(send(Request(cmd: .setMonitoring, monitoring: m)))
    }
    let sub = args.first ?? "show"
    let rest = Array(args.dropFirst())
    switch sub {
    case "show":
        show(send(Request(cmd: .status)))
    case "on", "off":
        change { $0.enabled = sub == "on" }
    case "watch":
        let known = Set(ListStore.all().keys).union([MonitoringSettings.explicitListName])
        let names = rest.map { $0.lowercased() }
        for n in names where !known.contains(n) {
            die("no list named '\(n)'. Available: \(known.sorted().joined(separator: ", "))")
        }
        change { $0.watchLists = names }
    case "sites", "domains":
        guard rest.count >= 2, ["add", "remove"].contains(rest[0]) else { die("usage: renew monitor sites add|remove <SITE>...") }
        let (valid, rejected) = canonicalRules(Array(rest.dropFirst()))
        if !rejected.isEmpty { die("invalid site(s): \(rejected.joined(separator: ", "))") }
        change { m in
            if rest[0] == "add" { m.customDomains += valid.filter { !m.customDomains.contains($0) } }
            else { m.customDomains.removeAll { valid.contains($0) } }
        }
    case "words", "terms":
        if rest.count == 2, rest[0] == "preset", ["on", "off"].contains(rest[1]) {
            change { $0.flagExplicitTerms = rest[1] == "on" }
        } else if rest.count >= 2, ["add", "remove"].contains(rest[0]) {
            // Each argument is one word or phrase (quote phrases).
            let words = rest.dropFirst().map(MonitoringSettings.cleanTerm).filter { !$0.isEmpty }
            change { m in
                if rest[0] == "add" { m.customTerms += words.filter { !m.customTerms.contains($0) } }
                else { m.customTerms.removeAll { words.contains($0) } }
            }
        } else {
            die("usage: renew monitor words add|remove <WORD>... | renew monitor words preset on|off")
        }
    default:
        die("usage: renew monitor [show | on | off | watch LIST... | sites add|remove SITE... | words add|remove WORD... | words preset on|off]")
    }

case "activity":
    var day = ActivityLogStore.dayKey(Date())
    var flagged = false
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--flagged", "-f": flagged = true
        case "--date", "-d":
            guard i + 1 < args.count else { die("--date needs YYYY-MM-DD") }
            day = args[i + 1]
            i += 1
        default:
            if args[i].hasPrefix("--date=") { day = String(args[i].dropFirst("--date=".count)) }
            else { die("usage: renew activity [--date YYYY-MM-DD] [--flagged]") }
        }
        i += 1
    }
    guard ActivityLogStore.date(ofDay: day) != nil else { die("not a date: \(day) (use YYYY-MM-DD)") }
    let response: Response
    do {
        response = try DaemonClient.send(Request(cmd: .activity, activityQuery: ActivityQuery(day: day, flaggedOnly: flagged)), timeout: 10)
    } catch {
        die(String(describing: error))
    }
    guard response.ok else { die(response.error ?? "renewd refused the request") }
    let events = response.activity ?? []
    if response.status?.monitoring?.enabled == false { print("(Activity monitoring is off. Turn it on with `renew monitor on`.)") }
    guard !events.isEmpty else {
        print(flagged ? "No flagged visits on \(day)." : "No visits recorded on \(day).")
        exit(0)
    }
    let time = DateFormatter()
    time.dateFormat = "HH:mm:ss"
    for e in events {
        let marks = (e.blocked ? ["Blocked"] : []) + e.flags.map(\.label)
        let flag = marks.isEmpty ? "" : "  [\(marks.joined(separator: ", "))]"
        print("\(time.string(from: e.start))  \(DurationText.format(Int(e.duration.rounded())).padding(toLength: 8, withPad: " ", startingAt: 0))  \(e.browser): \(e.title)\(flag)")
        print("          \(e.url)")
    }
    let count = events.filter(\.isFlagged).count
    print("\n\(events.count) visit(s)\(flagged ? "" : ", \(count) flagged") on \(day).")

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
        syncSchedules()
    case "remove", "rm":
        guard args.count >= 2 else { die("usage: renew lists remove <NAME> [SITE]...") }
        do {
            let remaining = try ListStore.remove(args[1], Array(args.dropFirst(2)))
            print("\(args[1].lowercased()): \(remaining?.joined(separator: ", ") ?? "(deleted)")")
        } catch { die("couldn't save lists: \(error)") }
        syncSchedules()
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
