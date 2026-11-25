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
  renew reports                                        show where email reports go
  renew reports set <EMAIL>...                         email flag reports to your accountability partners
  renew reports set <EMAIL>... --server <URL> [TOKEN]  ...through a different report server (asks for the token)
  renew reports off                                    ask partners to approve turning reports off (between sessions)
  renew reports test                                   send a test report
  renew protections                                    show which hardening protections are on
  renew protections on|off <NAME>...                   turn protections on, or off (between sessions only)
  renew activity on|off                                record the pages you visit, or stop (can't stop while
                                                       the Monitor is on and you have a partner)
  renew activity [--date YYYY-MM-DD]                   show the pages you visited (default: today)
  renew stats [--days N] [--from D] [--to D] [--site S]  time per site: totals and daily averages (default: 7 days)
  renew monitor                                        show what the Monitor flags
  renew monitor on|off                                 turn the Monitor on (needs a partner and Activity on)
                                                       or off; with a partner it can't be turned off or
                                                       watch less, only add (remove partners first)
  renew monitor list add <NAME> <SITE>...              add sites to a monitoring list (created if new)
  renew monitor list remove <NAME> <SITE>...           remove sites from a monitoring list
  renew monitor list delete <NAME>                     delete a monitoring list
  renew monitor list starter social|video|news         add a starter monitoring list
  renew monitor sites add|remove <SITE>...             flag visits to other sites
  renew monitor words add|remove <WORD>...             flag page titles containing a word or phrase
  renew monitor explicit on|off                        flag explicit content (adult sites, titles, pages on mixed sites)
  renew flags [--date YYYY-MM-DD]                      show the visits the Monitor flagged (default: today)
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

/// Partners whose removal waits for approval (they still get reports).
func pendingNote(_ s: Status) -> String {
    guard let p = s.pendingReportPartners, !p.isEmpty else { return "" }
    return " (\(p.joined(separator: ", ")): removal waiting for a partner's approval)"
}

func printExtras(_ s: Status) {
    print("  Email reports: \(s.reportsPartners.map { "to \($0.joined(separator: ", "))" } ?? "off")\(pendingNote(s))")
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

/// The day a `--date YYYY-MM-DD` option names (default: today); dies on anything else.
func parseDayOption(_ args: [String], usage: String) -> String {
    var day = ActivityLogStore.dayKey(Date())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--date", "-d":
            guard i + 1 < args.count else { die("--date needs YYYY-MM-DD") }
            day = args[i + 1]
            i += 1
        default:
            if args[i].hasPrefix("--date=") { day = String(args[i].dropFirst("--date=".count)) }
            else { die(usage) }
        }
        i += 1
    }
    guard ActivityLogStore.date(ofDay: day) != nil else { die("not a date: \(day) (use YYYY-MM-DD)") }
    return day
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

case "reports":
    switch args.first ?? "show" {
    case "show":
        let st = send(Request(cmd: .status))
        if let to = st.reportsPartners {
            print("Email reports: to \(to.joined(separator: ", "))\(st.reportsURL.map { ", through \($0)" } ?? "")\(pendingNote(st))")
        } else {
            print("Email reports: off\(st.reportServerBuiltIn == false ? " (no report server set up on this Mac)" : "")")
        }
    case "set":
        // renew reports set <EMAIL>... [--server URL [TOKEN]]
        var rest = Array(args.dropFirst())
        var url: String?
        var token: String?
        if let i = rest.firstIndex(of: "--server") {
            guard i + 1 < rest.count else { die("--server needs a URL") }
            url = rest[i + 1]
            if i + 2 < rest.count { token = rest[i + 2] }
            rest.removeSubrange(i..<min(rest.count, i + 3))
            if token == nil {
                // Kept out of the shell history.
                guard let p = getpass("Report token: ") else { die("No token given.") }
                token = String(cString: p)
            }
        }
        guard !rest.isEmpty else { die("usage: renew reports set <EMAIL>... [--server URL [TOKEN]]") }
        let st = send(Request(cmd: .setReports, reports: ReportDestination(partnerEmails: rest, url: url, token: token)))
        print("Email reports go to \(st.reportsPartners?.joined(separator: ", ") ?? "?")\(pendingNote(st)). A confirmation email is on its way.")
    case "off":
        let st = send(Request(cmd: .setReports, reports: nil))
        print(pendingNote(st).isEmpty ? "Email reports are off."
              : "Asked your partners to approve turning email reports off. Reports keep going to them until one approves.")
    case "test":
        _ = send(Request(cmd: .testReport))
        print("Test report sent. Check renewd's log if no email arrives.")
    default:
        die("usage: renew reports [show | set EMAIL... [--server URL [TOKEN]] | off | test]")
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
        guard let m = st.monitor else { die("This Renew service predates the Monitor. Reinstall Renew.") }
        print("Monitor: \(m.enabled ? "on" : "off")\(m.enabled && st.activity?.enabled == false ? " (but Activity is off, so nothing is checked: `renew activity on`)" : "")")
        print("  Explicit content: \(m.flagExplicit ? "on (adult sites, titles, and pages on mixed sites)" : "off")")
        let lists = m.sortedListNames.map { name -> String in
            let n = m.lists[name]?.count ?? 0
            return "\(name) (\(n == 1 ? "1 site" : "\(n) sites"))"
        }
        let off = m.flagLists ? "" : " (off, not flagged)"
        print("  Lists:         \(lists.isEmpty ? (m.flagLists ? "none" : "off") : lists.joined(separator: ", ") + off)")
        print("  Other sites:   \(m.customDomains.isEmpty ? "none" : m.customDomains.joined(separator: ", ") + off)")
        print("  Other words:   \(m.customTerms.isEmpty ? "none" : m.customTerms.joined(separator: ", "))")
    }
    func change(needsListSwitch: Bool = false, _ edit: (inout MonitorSettings) -> Void) {
        let st = send(Request(cmd: .status))
        guard var m = st.monitor else { die("This Renew service predates the Monitor. Reinstall Renew.") }
        guard st.monitorLists == true else { die("This Renew service predates monitoring lists. Reinstall Renew.") }
        if needsListSwitch && st.monitorListSwitch != true { die("This Renew service can't turn monitoring lists off. Reinstall Renew.") }
        edit(&m)
        if let error = m.limitError { die(error) }
        show(send(Request(cmd: .setMonitor, monitor: m)))
    }
    let sub = args.first ?? "show"
    let rest = Array(args.dropFirst())
    switch sub {
    case "show":
        show(send(Request(cmd: .status)))
    case "on", "off":
        change { $0.enabled = sub == "on" }
    case "watch":
        die("Monitoring lists are separate from blocklists now: use `renew monitor list add NAME SITE...`")
    case "list", "lists":
        let usage = "usage: renew monitor list on|off | list add|remove NAME SITE... | list delete NAME | list starter \(MonitorSettings.starterLists.joined(separator: "|"))"
        if rest.count == 1, ["on", "off"].contains(rest[0]) {
            change(needsListSwitch: true) { $0.flagLists = rest[0] == "on" }
            break
        }
        guard rest.count >= 2 else { die(usage) }
        guard let name = MonitorSettings.cleanListName(rest[1]) else {
            die("'\(rest[1])' can't be used as a list name (not \"explicit\" or \"custom\", at most \(MonitorSettings.maxListNameLength) characters)")
        }
        switch rest[0] {
        case "add", "remove", "rm":
            guard rest.count >= 3 else { die(usage) }
            let (valid, rejected) = canonicalRules(Array(rest.dropFirst(2)))
            if !rejected.isEmpty { die("invalid site(s): \(rejected.joined(separator: ", "))") }
            change { m in
                if rest[0] == "add" {
                    m.addSites(valid, to: name)
                } else {
                    guard m.lists[name] != nil else { die("no monitoring list named '\(name)'") }
                    m.lists[name]?.removeAll { valid.contains($0) }
                }
            }
        case "delete":
            change { m in
                guard m.lists[name] != nil else { die("no monitoring list named '\(name)'") }
                m.lists[name] = nil
            }
        case "starter":
            guard let sites = MonitorSettings.starter(name) else {
                die("no starter named '\(name)'. Available: \(MonitorSettings.starterLists.joined(separator: ", "))")
            }
            change { $0.addSites(sites, to: name) }
        default:
            die(usage)
        }
    case "sites", "domains":
        guard rest.count >= 2, ["add", "remove"].contains(rest[0]) else { die("usage: renew monitor sites add|remove <SITE>...") }
        let (valid, rejected) = canonicalRules(Array(rest.dropFirst()))
        if !rejected.isEmpty { die("invalid site(s): \(rejected.joined(separator: ", "))") }
        change { m in
            if rest[0] == "add" { m.customDomains += valid.filter { !m.customDomains.contains($0) } }
            else { m.customDomains.removeAll { valid.contains($0) } }
        }
    case "explicit":
        guard rest.count == 1, ["on", "off"].contains(rest[0]) else { die("usage: renew monitor explicit on|off") }
        change { $0.flagExplicit = rest[0] == "on" }
    case "words", "terms":
        if rest.count == 2, rest[0] == "preset", ["on", "off"].contains(rest[1]) {
            change { $0.flagExplicit = rest[1] == "on" }
        } else if rest.count >= 2, ["add", "remove"].contains(rest[0]) {
            // Each argument is one word or phrase (quote phrases).
            let words = rest.dropFirst().map(MonitorSettings.cleanTerm).filter { !$0.isEmpty }
            change { m in
                if rest[0] == "add" { m.customTerms += words.filter { !m.customTerms.contains($0) } }
                else { m.customTerms.removeAll { words.contains($0) } }
            }
        } else {
            die("usage: renew monitor words add|remove <WORD>... | renew monitor words preset on|off")
        }
    default:
        die("usage: renew monitor [show | on | off | list add|remove|delete|starter ... | sites add|remove SITE... | words add|remove WORD... | explicit on|off]")
    }

case "activity":
    if let sub = args.first, ["on", "off"].contains(sub) {
        let st = send(Request(cmd: .setActivity, activity: ActivitySettings(enabled: sub == "on")))
        guard let a = st.activity else { die("This Renew service predates `renew activity on|off`. Reinstall Renew.") }
        print("Activity: \(a.enabled ? "on" : "off")")
        if !a.enabled, st.monitor?.enabled == true { print("(The Monitor stays on but has nothing to check until Activity is back on.)") }
        exit(0)
    }
    let day = parseDayOption(args, usage: "usage: renew activity [on | off | --date YYYY-MM-DD]")
    let response: Response
    do {
        response = try DaemonClient.send(Request(cmd: .activity, activityQuery: ActivityQuery(day: day)), timeout: 10)
    } catch {
        die(String(describing: error))
    }
    guard response.ok else { die(response.error ?? "renewd refused the request") }
    let events = response.activity ?? []
    if response.status?.activity?.enabled == false { print("(Activity is off. Turn it on with `renew activity on`.)") }
    guard !events.isEmpty else {
        print("No visits recorded on \(day).")
        exit(0)
    }
    let time = DateFormatter()
    time.dateFormat = "HH:mm:ss"
    for e in events {
        let flag = e.blocked ? "  [Blocked]" : ""
        print("\(time.string(from: e.start))  \(DurationText.format(Int(e.duration.rounded())).padding(toLength: 8, withPad: " ", startingAt: 0))  \(e.browser): \(e.title)\(flag)")
        print("          \(e.url)")
    }
    print("\n\(events.count) visit(s) on \(day).")

case "flags":
    let day = parseDayOption(args, usage: "usage: renew flags [--date YYYY-MM-DD]")
    let response: Response
    do {
        response = try DaemonClient.send(Request(cmd: .monitorFlags, monitorQuery: MonitorQuery(day: day)), timeout: 10)
    } catch {
        die(String(describing: error))
    }
    guard response.ok else {
        if (response.error ?? "").hasPrefix("bad request") { die("This Renew service predates `renew flags`. Reinstall Renew.") }
        die(response.error ?? "renewd refused the request")
    }
    if response.status?.monitor?.enabled == false {
        print("(The Monitor is off. Turn it on with `renew monitor on`.)")
    } else if response.status?.activity?.enabled == false {
        print("(Activity is off, so the Monitor has nothing to check. Turn it on with `renew activity on`.)")
    }
    let flags = response.flags ?? []
    guard !flags.isEmpty else {
        print("Nothing flagged on \(day).")
        exit(0)
    }
    let time = DateFormatter()
    time.dateFormat = "HH:mm:ss"
    for f in flags {
        print("\(time.string(from: f.start))  \(DurationText.format(Int(f.duration.rounded())).padding(toLength: 8, withPad: " ", startingAt: 0))  \(f.browser): \(f.title)  [\(f.flags.map(\.label).joined(separator: ", "))]")
        print("          \(f.url)")
    }
    print("\n\(flags.count) flagged visit(s) on \(day).")

case "stats":
    var days = 7
    var daysGiven = false
    var from: String?, to: String?, site: String?
    var i = 0
    func value(_ flag: String) -> String {
        guard i + 1 < args.count else { die("\(flag) needs a value") }
        i += 1
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--days", "-n":
            guard let n = Int(value("--days")), (1...ActivityStatsQuery.maxDays).contains(n) else {
                die("--days takes 1 to \(ActivityStatsQuery.maxDays)")
            }
            days = n
            daysGiven = true
        case "--from": from = value("--from")
        case "--to": to = value("--to")
        case "--site", "-s":
            let raw = value("--site")
            site = SiteKey.site(forHost: NormalizedURL(raw)?.host ?? raw)
        default: die("usage: renew stats [--days N [--to YYYY-MM-DD] | --from YYYY-MM-DD [--to YYYY-MM-DD]] [--site SITE]")
        }
        i += 1
    }
    if daysGiven && from != nil { die("use --days or --from, not both (--days N --to D is the N days ending on D)") }
    let query: ActivityStatsQuery
    if let from {
        // From a day through `--to`, or through today.
        query = ActivityStatsQuery(from: from, to: to ?? ActivityLogStore.dayKey(Date()), site: site)
    } else if let to {
        // The `--days` days (7 by default) ending on `--to`.
        guard let end = ActivityLogStore.date(ofDay: to) else { die("not a date: \(to) (use YYYY-MM-DD)") }
        query = ActivityStatsQuery(lastDays: days, endingAt: end, site: site)
    } else {
        query = ActivityStatsQuery(lastDays: days, site: site)
    }
    guard let keys = query.dayKeys() else {
        die("not a valid range: \(query.from) to \(query.to) (YYYY-MM-DD, at most \(ActivityStatsQuery.maxDays) days)")
    }
    let response: Response
    do {
        response = try DaemonClient.send(Request(cmd: .activityStats, statsQuery: query), timeout: 20)
    } catch {
        die(String(describing: error))
    }
    guard response.ok else {
        if (response.error ?? "").hasPrefix("bad request") { die("This Renew service predates `renew stats`. Reinstall Renew.") }
        die(response.error ?? "renewd refused the request")
    }
    guard let summaries = response.stats else { die("This Renew service predates `renew stats`. Reinstall Renew.") }
    if response.status?.activity?.enabled == false { print("(Activity is off. Turn it on with `renew activity on`.)") }
    let report = ActivityStatsReport(query: query, summaries: summaries)
    let span = keys.count == 1 ? query.from : "\(query.from) to \(query.to)"
    let hm = DurationText.hoursMinutes
    func pad(_ s: String, _ n: Int) -> String { String(repeating: " ", count: max(0, n - s.count)) + s }
    let name = { (s: String) in s == DaySummary.otherSite ? "(other sites)" : s }

    if let site {
        let series = report.days(for: site)
        let total = series.reduce(0) { $0 + $1.seconds }
        guard total > 0 else {
            print("No time on \(site) recorded, \(span).")
            exit(0)
        }
        print("\(site), \(span)\n")
        for d in series where report.averageDays > 0 && d.day >= keys[keys.count - report.averageDays] {
            print("  \(d.day)  \(pad(hm(d.seconds), 9))")
        }
        let avg = report.site(site)?.dailyAverage ?? 0
        print("\nTotal \(hm(total)) · average \(hm(Int(avg.rounded()))) a day over \(report.averageDays) day(s)")
        exit(0)
    }
    guard !report.isEmpty else {
        print("No time on websites recorded, \(span).")
        exit(0)
    }
    print("Time on websites, \(span): \(hm(report.totalSeconds))", terminator: "")
    print(keys.count > 1 ? " · average \(hm(Int(report.dailyAverage.rounded()))) a day over \(report.averageDays) day(s)\n" : "\n")
    let width = min(40, max(4, report.sites.prefix(25).map { name($0.site).count }.max() ?? 4))
    print("  \("SITE".padding(toLength: width, withPad: " ", startingAt: 0))  \(pad("TOTAL", 10))  \(pad("AVG/DAY", 9))  \(pad("SHARE", 5))")
    for s in report.sites.prefix(25) {
        let label = String(name(s.site).prefix(width)).padding(toLength: width, withPad: " ", startingAt: 0)
        let share = "\(Int((s.share * 100).rounded()))%"
        print("  \(label)  \(pad(hm(s.totalSeconds), 10))  \(pad(hm(Int(s.dailyAverage.rounded())), 9))  \(pad(share, 5))")
        // Its parts (Gmail, Google Docs…), when there's more than the site itself.
        guard s.hasBreakdown else { continue }
        for sec in s.sections.prefix(5) {
            let text = "  " + (SiteSection.name(sec.section) ?? sec.section)
            let label = String(text.prefix(width)).padding(toLength: width, withPad: " ", startingAt: 0)
            print("  \(label)  \(pad(hm(sec.totalSeconds), 10))  \(pad(hm(Int(sec.dailyAverage.rounded())), 9))")
        }
        if s.sections.count > 5 { print("    … and \(s.sections.count - 5) more") }
    }
    if report.sites.count > 25 { print("  … and \(report.sites.count - 25) more") }

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
