# Renew

A FocusMe-style website blocker for macOS. It watches your browsers, and when the
current tab is on a blocked site, it swaps the page for a block page. Sessions can't
be shortened or stopped once started.

Out of the box Renew is an ordinary blocker, fine to use on a work Mac. The
features that make it hard to stop or remove are **protections** you turn on
yourself in **Setup → Protections** (see [Protections](#protections)).

## Install

Requirements: macOS 13+, Xcode Command Line Tools, and ideally a free **Apple
Development** signing certificate (Xcode → Settings → Accounts → your Apple ID →
Manage Certificates → +). The certificate gives the app a stable identity, so
macOS remembers its permissions across rebuilds.

```sh
scripts/build.sh        # builds and signs build/Renew.app
open build/Renew.app    # click "Install Renew…" and enter your password
```

The installer copies the app to `/Applications/Renew.app` and starts its
background services. The installed app then opens on **Setup**, where you:

1. **Allow Accessibility.** Needed for Firefox and for closing tabs.
2. **Allow each browser.** Click **Allow…** next to it, and open the browser first if
   it isn't running.

`sudo scripts/install.sh` does the same install from the terminal.

## Use

Renew lives in the **menu bar**: a lock icon, with a countdown during a session.
Click it to start a quick session or add time, or choose **Open Renew…** for
the window:

- **Block Sessions**: your saved block sessions. Each has a name, its own
  blocklists and sites, and either a length (start it with one click) or **set
  times on chosen days** (e.g. weekdays 9:00–17:00, or 22:00–06:00 overnight).
  Scheduled block sessions start on their own, even with the window closed, and
  can't be stopped once they start; you can edit, pause or delete them any time
  before then. They live in `~/.config/renew/sessions.json`, and the app hands the
  schedules (with their sites resolved) to the background service, which starts
  them. A running block session shows below the list.
- **Quick Block**: a one-off block. Pick a length (25 min to 4 hours, or type a
  custom one), tick blocklists, add extra sites and start. During a block session
  it shows a countdown ring and the blocked sites, and lets you add time or block
  another site. There's no stop button.
- **Blocklists**: edit the built-in lists (social, video, news, test) or make your own.
- **Activity**: records the pages you visit. A dashboard of time per site with
  daily totals and averages, and the log of pages you've visited (see
  [Activity](#activity)). Off until you turn it on.
- **Monitor**: reads that activity and flags visits to explicit or watched sites,
  or with watched words in their titles (see [Monitor](#monitor)). Off until you
  turn it on, and needs Activity on.
- **Accountability**: your partners' emails (reports and check-ins) and a
  history of what they've been sent (see
  [Accountability](#accountability)).
- **Setup**: service status, permissions, protections,
  and uninstall (see below).

Closing the window or pressing ⌘Q leaves Renew running in the menu bar.

Rule syntax:

| Rule | Blocks |
|---|---|
| `reddit.com` | the domain and every subdomain |
| `youtube.com/shorts` | that path (and below) only; the rest of YouTube still works |
| `keyword:casino` | any URL containing the word |
| `!music.youtube.com` | an allow exception (always wins) |

A command-line tool is also installed for scripting (`renew start 2h --list social`,
`renew status`, `renew extend 30m`, `renew add x.com`, `renew schedules`,
`renew reports set <email>...`, `renew protections on all`, `renew activity on`,
`renew stats --site youtube.com`, `renew monitor on`, `renew flags`, `renew uninstall`).

Schedules can't be skipped by changing the Mac's clock: renewd also keeps
time on a clock that ignores date changes (since the Mac last started), and a
window opens if either clock says so. Changing the date is reported as tampering
whenever schedules are set. Once a block session is running, it counts down on
the same date-proof clock.

### Protections

All four are off until you turn them on, in **Setup → Protections** or with
`renew protections on <name>` (`renew protections` lists them). Blocking works
either way, and a running session can't be shortened or stopped either way.

| Protection | CLI name | What it does |
|---|---|---|
| Keep Renew running | `keep-running` | Runs a second root service, the guard (otherwise only renewd runs). During a session, renewd and the guard bring each other and the app back if they're stopped, undo `launchctl disable`, and put Renew's files back if they're deleted or changed. With email reports on, the guard also watches renewd's internal heartbeat (see [Check-ins](#check-ins)). |
| Lock System Settings switches | `lock-settings` | During a session, switches for background items and permissions only turn on, not off (see [below](#turning-renew-off-in-system-settings)). |
| Close browsers Renew can't watch | `close-browsers` | During a session, closes browsers Renew has lost permission to watch, unsupported browsers and unknown apps built on Chrome's or Firefox's engine. With it off, those browsers just aren't blocked. |
| Uninstall cooling-off | `cooling-off` | Uninstalling needs a request and a 24-hour wait (see [Uninstalling](#uninstalling)). |

A protection can be turned on at any time, but turned off only between block
sessions. Turning off the
uninstall cooling-off doesn't happen straight away: it stays on for 24 more
hours, and until the end of any session running then (switch it back on to
cancel), or it would be a way around the wait.

Installs from before protections existed start with all of them off after
updating. Turn on the ones you want again.

### Accountability

The **Accountability** page brings together everything your partners hear
about: email reports and check-ins (**Partners**), and **Sent to your
partners**, a list of the last 200 emails and check-in emails, so you can see
what they see. Reports still waiting to go out show as *Waiting*.
The history is kept by renewd in `/var/db/com.renew/partner-log.json`
(root-only).

### Activity

Off until you turn on **Record browsing** at the top right of the Activity page (or `renew activity on`). With it
on, Renew records each page you look at, session or not. Activity is only the
record; it doesn't judge anything (that's the [Monitor](#monitor)).

- **What:** the address, the page title, which browser or app showed it, and how
  long it was in front. It reads the active tab of the frontmost browser (Safari,
  Chrome, Edge, Brave, Arc, Vivaldi, Firefox) once a second, and the websites in the
  built-in browser of the frontmost app (T3 Code, Claude, Codex and other Electron
  or web-view apps) every 2 seconds. Background tabs and other apps aren't read.
  Time away doesn't count: after 5 minutes without input, or with the screen
  locked, the current visit ends.
- **Blocked pages:** pages a block session replaced with the block page are
  logged as blocked.
- **Where:** renewd keeps the log in `/var/db/com.renew/activity/<uid>/`, one file
  per day, readable and writable only by root, so it can't be edited from your
  account. Each user only sees their own log. Days older than 30 days are deleted,
  and a user's log stops growing past 16 MB a day or 256 MB in all, so it can't
  fill the disk.
  If renewd can't be reached, the app holds visits in
  `~/Library/Application Support/Renew/activity-pending.json` until it can.
- **Time per site:** **Activity → Dashboard** (or `renew stats`) adds up the
  time on each site for today, the last 7 or 30 days, or the last year: a daily
  total, a daily average, and a bar chart per day. Subdomains count as their
  main site (`m.youtube.com` and `music.youtube.com` are `youtube.com`), and
  time a site was on screen twice at once (two windows) counts once. Click a
  site to chart only that site, with its average. Averages count every day
  from the first one with any activity in the range, including today. renewd
  keeps these per-site daily totals in `.../activity/<uid>/summary/` for a
  year, after the visits themselves are deleted. `renew stats --days 30`,
  `renew stats --from 2026-11-01 --to 2026-11-15` and
  `renew stats --site youtube.com` (that site per day) print the same numbers.
- **Nothing leaves the Mac**, except what [email reports](#email-reports) send
  about flagged visits.

### Monitor

Off until you turn it on in **Monitor → Settings** (or `renew monitor on`). The
Monitor reads the visits Activity records, so it needs Activity on.

- **Flags:** a visit is flagged when its site is on a watched list or its title
  contains a watched word. Nothing is watched until you choose it: **Explicit
  sites** (a preset bundled with Renew, see below), any of your blocklists, sites
  you add, the preset of explicit words, and words you add. Words are matched as
  whole words, ignoring case and accents, so "sex" doesn't match "Essex".
- **renewd does the checking**, not the app: each visit is checked once, as it
  reaches renewd, so what gets flagged doesn't depend on the app. renewd can't
  read your blocklists (they're in your home folder), so the app and `renew`
  give it a copy of the watched ones, and update it when you edit them.
- **Flags are never rewritten.** Changing a rule only affects visits from then on.
- **Where:** renewd keeps flags apart from the activity log, in
  `/var/db/com.renew/monitor/<uid>/`, one root-only file per day, for a year
  (longer than the visits). See them in **Monitor → Flags** or with
  `renew flags [--date YYYY-MM-DD]`.
- **Reports:** with [email reports](#email-reports) on, your accountability
  partners are emailed about flags.

Each user on the Mac has their own Activity and Monitor settings and only changes
their own. For now they can be turned off or changed at any time. Settings from
before Activity and the Monitor were split carry over: if monitoring was on, both
start out on, with the same rules.

The explicit-site preset is a snapshot of the
[StevenBlack/hosts](https://github.com/StevenBlack/hosts) porn-only list (MIT
license; tens of thousands of domains), in `Resources/explicit-domains.txt`. Its
header names the commit it came from. The installer copies it next to renewd
(`/Library/Application Support/Renew/explicit-domains.txt`). Renew never downloads
it; refresh it with `scripts/update-explicit-list.sh` and rebuild.

Apps like Codex/ChatGPT only expose their built-in browser with macOS's
screen-reader mode on, which can make their windows animate oddly. Outside block
sessions Renew turns that on only while the app is in front, and back off as soon
as it isn't.

### Email reports

Renew can email one or more accountability partners (up to 10) when the Monitor
flags a visit. Partners don't need an account or an app; they just get emails. The
emails come from your own small report server: an AWS Lambda that sends from a
Gmail account you create for it. Setting it up takes about 15 minutes; see
[server/reports/README.md](server/reports/README.md). Its URL and token are
saved by `server/reports/configure-mac.sh` and copied in when you install
Renew, so in **Accountability → Partners** you only enter your partners' email
addresses (or `renew reports set <email> [<email>...]`). Each email goes to all
partners at once, so they can see each other's addresses. Before adding a
second partner, redeploy a report server set up before then (`sam deploy`); an
older one refuses reports sent to more than one address. Email reports and
check-ins are the only things Renew sends off the Mac.

- **What's sent:** the site (e.g. `example.com`), the page title, why it was
  flagged (explicit site, a watched list, a watched word), when, and for how
  long. Never the full address. Times are in the Mac's time zone.
- **Grouped:** flags within a minute of the first one go in one email, so a
  burst of browsing sends one email, not fifty.
- **Not lost:** renewd keeps unsent reports in
  `/var/db/com.renew/reports-outbox.json` (root-only) and retries (after 30 s,
  1 min, 5 min, then every 15 min) until the server accepts them, so turning
  off Wi-Fi only delays a report.
- **Changes are reported too:** turning Activity or the Monitor off, no longer
  watching a list or explicit words, and removing watched sites or words each
  send an email. Adding rules, and editing a blocklist's sites, don't.
- **Locked during sessions:** reports can be turned on and partners added at
  any time, but partners removed or reports turned off only between block
  sessions. Saved partners can't be edited, only removed. A removed partner gets
  a change notice, and reports still waiting to be sent go to the old list of
  partners. `renew reports test` (or **Send test**) sends a test
  email.

#### Check-ins

While email reports are on, Renew keeps two heartbeats:

- **Internal:** every 10 seconds renewd writes "still running" to
  `/var/db/com.renew/alive.json` (root-only). When it starts, it works out
  how long the Mac was awake while it wasn't running (macOS's awake clock
  pauses during sleep, so sleep doesn't count). Anything over a minute is
  sent with the next check-in and emailed right away: "Renew wasn't running
  for 4 minutes while the Mac was awake (8:18 PM to 8:22 PM)". Being offline
  delays the email until Renew can reach the server.
  - If the Mac restarted after renewd stopped without a clean exit (it was
    force-quit, or the Mac crashed or lost power), renewd reads macOS's
    power log (`pmset -g log`) and shutdown records to see how long the Mac
    was awake before it went down. A crash or power loss ends both at once,
    so it's not reported; force-quitting Renew, using the Mac and then
    restarting it is.
  - Renew authenticates `alive.json` with an HMAC. If an expected record is
    missing or fails verification, Renew reports it. Every 5 minutes renewd
    also notes in `state.json` that it's running, which can catch a record
    replaced with an older copy.
  - With **Keep Renew running** on, the guard is a second witness: it
    watches `alive.json` and can report a gap directly to the server.
    renewd brings the guard back within a minute if it's stopped, even between
    sessions.
- **Server:** renewd checks in with the report server about every 15 minutes
  (give or take 2), when the Mac sleeps, wakes or renewd stops, and right
  away when there's downtime to report.
  The server checks every minute and emails your partner when:
  - the Mac is awake and Renew hasn't checked in for **2 hours** (the internal
    heartbeat reports time Renew wasn't running, so this only catches Renew
    never coming back: removed, or the Mac wiped);
  - Renew said its service was stopping (not a shutdown) and hasn't checked
    in for **3 minutes**;
  - Renew said the Mac was going to sleep or shutting down and nothing has
    been heard for **7 days**;
  - Renew said the Mac was shutting down, but it comes back without the Mac
    having restarted (the service was stopped, not the Mac);
  - and, after one of those, when Renew checks in again. That email says
    whether the Mac restarted, lists any downtime, or says it was a false
    alarm when Renew was running the whole time but couldn't reach the server.
  - Renew checks in awake after missing its expected check-in by more than
    5 minutes on the same boot. An outage can cause this.
  - Renew restarts more than once within an hour without the Mac rebooting.
    A single restart is recorded in the server's history.

Closing the lid, shutting down or restarting don't send anything: renewd
checks in one last time before the Mac sleeps, and the Renew app tells renewd
when the Mac is about to shut down. renewd only accepts that notice from the
Renew app itself (checked by its code signature), so a script can't make
stopping renewd look like a shutdown. Turning reports off, removing a partner,
moving servers, or running `renew uninstall` asks the server to end monitoring
for that enrollment. The server emails an approval link to the original
partners and keeps monitoring until one of them approves. Local changes
and uninstall can take effect immediately.

Check-ins name your partners, the Mac and the user only when renewd starts or
those change; the rest of the time they carry just this install's id, the
state, the boot and process run IDs, and any downtime.

Good to know:

- Being offline (or on a network that blocks the server) for more than 2
  hours while the Mac is awake (a flight without Wi-Fi) looks the same as
  Renew being removed. Your partner gets a "stopped checking in" email, then
  a "false alarm" one once the Mac is back online. If Renew is removed
  completely, your partner hears about it within about 2 hours.
- renewd sends no check-ins between "will sleep" and the next full wake
  (macOS briefly wakes a sleeping Mac for maintenance). If macOS ever misses
  telling it the Mac woke, keyboard or mouse use counts as a wake.
- Renew learns that the Mac is shutting down from the Renew app (or from no
  one being logged in). If the app isn't running, a restart still looks fine
  as long as the Mac comes back within 3 minutes, but a longer shutdown is
  reported as Renew being stopped.
- Each user only sees emails about themselves under **Sent to your
  partners**, plus the Mac-wide check-in emails.
- Someone with admin access who obtains the local HMAC key or report token
  can forge records or check-ins. Treat each alert as evidence of the event
  it describes.

### Uninstalling

With the cooling-off off (the default), click **Uninstall…** in Setup and type the
confirmation phrase, or run `sudo renew uninstall`, any time between sessions.

With the cooling-off on, uninstalling takes 24 hours. Click **Request uninstall…** in
Setup (or run `renew uninstall`). Renew keeps working as normal. After 24 hours the
uninstall unlocks for 2 days: click **Uninstall…** and type the confirmation phrase,
or run `sudo renew uninstall`, between sessions. An unused request expires;
`renew uninstall --cancel` cancels one.

## How it works

```
/Applications/Renew.app  (menu bar + window; LaunchAgent in your login session)
  ├─ every 0.5 s: frontmost browser's active tab URL
  │    Safari/Chrome/Edge/Brave/Arc/Vivaldi → AppleScript
  │    Firefox → Accessibility API (AXURL of the web area / address bar)
  ├─ blocked? → redirect tab to http://127.0.0.1:<port>/blocked
  │            (Firefox, or if the redirect fails → full-screen overlay + Cmd-W)
  ├─ [close-browsers] unsupported browsers (Opera, Orion, Zen, Tor, DuckDuckGo…) and web apps
  │    (Safari "Add to Dock", Chrome/Edge installed apps) → quit + overlay
  ├─ [close-browsers] unknown apps built on Chromium or Firefox's engine (a renamed copy of
  │    Chrome, Chrome for Testing, a Firefox fork) → quit + overlay.
  │    Electron and CEF apps (Slack, Claude, Spotify…) are left alone
  ├─ built-in browsers inside other apps (T3 Code, Claude, Codex…), read through
  │    Accessibility → overlay + hide the app; bringing it back gives 15 s to close the page
  ├─ [close-browsers] supported browser it can't watch (permission off, or unreadable for ~10 s)
  │    → quit + overlay, again on every relaunch
  ├─ [lock-settings] System Settings showing Login Items & Extensions or Privacy & Security
  │    (including its Accessibility and Automation pages) → switches turn on, not off
  ├─ [activity] front browser's tab (1 s) and front app's built-in browser (2 s),
  │    session or not → visits with URL, title and time → renewd every 5 s
  └─ every 2 s: heartbeat + permission report → renewd
        │
renewd  (LaunchDaemon, root)  ── /var/run/renew.sock (start/extend/add/status/report only)
  ├─ owns /var/db/com.renew/state.json (root-only; edits to it can only lengthen a session)
  ├─ counts sessions down on the monotonic clock, so changing the date does nothing
  │    (time the Mac is switched off still counts)
  ├─ sends email reports of flags and Monitor changes to your report server, if set up,
  │    keeping unsent ones in /var/db/com.renew/reports-outbox.json
  ├─ writes an internal heartbeat (alive.json) every 10 s, and checks in with the
  │    report server every ~4 min and on sleep, wake and exit (if reports are on);
  │    logs what your partners were sent in partner-log.json
  ├─ keeps the activity log in /var/db/com.renew/activity/<uid>/ (30 days),
  │    and per-site daily totals in .../summary/ (1 year)
  ├─ [monitor] checks each new visit against the user's Monitor rules and keeps
  │    flags in /var/db/com.renew/monitor/<uid>/ (1 year)
  ├─ [keep-running] re-loads the agent if it's unloaded, restarts it if silent
  ├─ [keep-running] restores its files from /var/db/com.renew/backup if deleted or altered
  └─ [keep-running] keeps the guard loaded
renewd --guard  (second LaunchDaemon, loaded by renewd only with keep-running on)
                ── keeps renewd loaded, repairs files, restores state.json (during sessions)
                ── watches alive.json and reports time renewd wasn't running (witness.json)

[name]: only with that protection on (see Protections), or with Activity or the Monitor on.
```

**With `close-browsers` on, turning off a permission doesn't get you past it.** If you switch off Renew's
Automation permission for a browser during a session, Renew closes that browser
and closes it again whenever it's reopened, until the session ends or you turn the
permission back on. Turning off Accessibility does the same to Firefox. Other browsers
keep working with blocking as normal.

### Turning Renew off in System Settings

This is the `lock-settings` protection; without it, System Settings is left alone.

macOS lists Renew's launchd services under one **Renew** switch in
**System Settings → General → Login Items & Extensions → Allow in the Background**.
Turning it off stops all of them at once, and no app can turn it back on. So during
a session, switches on that page can only be turned on:

- On Login Items & Extensions and Privacy & Security (including its Accessibility
  and Automation pages), clicks that would turn a switch off or remove an item from
  a list are blocked, and so are Space on a switch that's on and Delete in a list.
  Renew's own switches can't be turned off on any page, whatever macOS calls it.
  Turning things on, and the rest of System Settings, work as usual. If System
  Settings is too slow to answer, the click is dropped rather than let through;
  click again.
- This needs Accessibility. If that's off, Renew leaves System Settings alone so you
  can turn it back on, and it removes the filter the moment the permission goes, so
  input isn't held up. If the filter can't start, Renew closes those pages instead.
- The filter is kept narrow so it doesn't look like a keylogger to security
  software. It only exists while System Settings is open during a session. Across
  apps it sees mouse clicks only, and it sees key presses only when they go to
  System Settings, so typing in other apps never reaches Renew.

Renew never changes your network settings, `/etc/hosts` or the firewall.

Unknown Chromium apps are closed only when they have a Dock icon, so headless
browsers used by tests and AI tools keep working. A Playwright run with a visible
Chrome for Testing window (`--headed`) is closed mid-session.

## What's left for someone determined to escape

Renew is friction, not a vault. With every protection on, an admin who goes
through all of this can still get out (and with them off, far less is needed):

- use Terminal and `sudo` to stop every part of Renew (both daemons and the app)
  in an order that stops each part from putting the others back (with email
  reports on, your partners get a "stopped checking in" email)
- boot into Safe Mode or Recovery and delete things, or change the clock while
  the Mac is off
- turn off Accessibility before a session, which stops Renew seeing built-in
  browsers inside apps and System Settings' pages, so the Renew switch can then be
  turned off mid-session (Firefox is closed in that case, but apps like T3 Code are
  left running)
- reach the web without a browser window: `curl`, a terminal browser, a small
  WKWebView app, or an AI agent fetching pages

For a real lock, use a **standard (non-admin) account** day to day and let someone
else hold the admin password.

## Known limitations

- Only the front window's active tab is checked in each browser (every 0.5 s for the
  frontmost browser, every 2 s for the others). A redirect only lands on the exact
  tab that was checked, and only if it still shows the blocked page.
- Firefox support depends on its accessibility tree. Firefox wasn't installed on
  the machine this was built on, so verify it on yours.
- The block page runs on plain `http://127.0.0.1`; that's expected.
- Locking System Settings pages relies on their window titles, which are English
  names (macOS 13 and later; macOS 27 moved the Accessibility list to "Device Control
  and Data Access"). Renew's own switches are recognised by the "Renew" label in
  their row instead, so they're protected on any page. The top-level Accessibility page (Zoom, display
  options) shares its name, so its switches also only turn on during a session.
  Changes made by a script or VoiceOver rather than a click or key press aren't
  caught. Other languages, or a renamed page in
  a future macOS, aren't caught (the app logs every page title it sees during a
  session, to make this easy to update).

## Development

```sh
swift test                                  # rule matching, durations, wire format
scripts/build.sh                            # release build + signed Renew.app in ./build

# Unprivileged daemon + CLI against a temp socket. These overrides are ignored
# when running as root or from the installed locations:
mkdir -p /tmp/renew-dev
export RENEW_DATA_DIR=/tmp/renew-dev RENEW_SOCKET=/tmp/renew-dev/s.sock
.build/release/renewd --dev &
.build/release/renew start 10m reddit.com

# The app with a throwaway session, no background service needed
# (watches your browsers for real; macOS will ask for permissions):
RENEW_PORT=48000 build/Renew.app/Contents/MacOS/Renew --local-session 5m reddit.com
# Add RENEW_PROTECTIONS=all (or e.g. lock-settings,close-browsers) to try those too.
# Add RENEW_ACTIVITY=on to record visits; they're written to the app's log
# (nothing is flagged: that needs renewd).
```

Logs: `/var/log/renew.log`, `/var/log/renew-guard.log`, `~/Library/Logs/Renew/app.log`,
and `/Library/Logs/Renew/` for install and uninstall.

Blocklists are stored in `~/.config/renew/lists.json`.

Only the copy in `/Applications` watches browsers. Any other copy, such as a fresh
build, acts as the installer and updater.
