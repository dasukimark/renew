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
3. Optionally **create the lock-down profile.** The app shows a removal password to
   hand to someone else, saves the profile and opens it for installation.

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
- **Activity**: a dashboard of time per site with daily totals and averages, the
  log of pages you've visited, and what gets flagged (see
  [Activity monitoring](#activity-monitoring)). Off until you turn it on.
- **Setup**: service status, permissions, protections, the lock-down profile,
  accountability alerts, and uninstall (see below).

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
`renew alerts set <url>`, `renew protections on all`, `renew monitor on`,
`renew activity --flagged`, `renew stats --site youtube.com`, `renew uninstall`).

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
| Keep Renew running | `keep-running` | Runs a second root service, the guard (otherwise only renewd runs). During a session, renewd and the guard bring each other and the app back if they're stopped, undo `launchctl disable`, and put Renew's files back if they're deleted or changed. |
| Lock System Settings switches | `lock-settings` | During a session, switches for background items and permissions only turn on, not off (see [below](#turning-renew-off-in-system-settings)). |
| Close browsers Renew can't watch | `close-browsers` | During a session, closes browsers Renew has lost permission to watch, unsupported browsers and unknown apps built on Chrome's or Firefox's engine. With it off, those browsers just aren't blocked. |
| Uninstall cooling-off | `cooling-off` | Uninstalling needs a request and a 24-hour wait (see [Uninstalling](#uninstalling)). |

A protection can be turned on at any time, but turned off only between block
sessions, and with alerts on, your partner is told when it is. Turning off the
uninstall cooling-off doesn't happen straight away: it stays on for 24 more
hours, and until the end of any session running then (switch it back on to
cancel), or it would be a way around the wait.

Installs from before protections existed start with all of them off after
updating. Turn on the ones you want again.

### Accountability alerts

Renew can message someone you trust when it's stopped, its files are deleted or
changed, or the Mac's clock is changed during a block session, and when an
uninstall is requested, cancelled or done. Your partner installs the free
[ntfy](https://ntfy.sh) app and subscribes to a hard-to-guess topic, and you enter
`https://ntfy.sh/<topic>` in **Setup → Accountability alerts** (or
`renew alerts set https://ntfy.sh/<topic>`). Discord and Slack webhook URLs work too.

Alerts can be turned on at any time, but changed or turned off only between
sessions, and the old destination is told when that happens. This is the only
thing Renew sends off the Mac.

### Activity monitoring

Off until you turn it on in **Activity → Settings** (or `renew monitor on`). With it
on, Renew records each page you look at, session or not:

- **What:** the address, the page title, which browser or app showed it, and how
  long it was in front. It reads the active tab of the frontmost browser (Safari,
  Chrome, Edge, Brave, Arc, Vivaldi, Firefox) once a second, and the websites in the
  built-in browser of the frontmost app (T3 Code, Claude, Codex and other Electron
  or web-view apps) every 2 seconds. Background tabs and other apps aren't read.
  Time away doesn't count: after 5 minutes without input, or with the screen
  locked, the current visit ends.
- **Flags:** a visit is flagged when its site is on a watched list or its title
  contains a watched word. Nothing is watched until you choose it: **Explicit
  sites** (a preset bundled with Renew, see below), any of your blocklists, sites
  you add, the preset of explicit words, and words you add. Words are matched as
  whole words, ignoring case and accents, so "sex" doesn't match "Essex". Pages a block
  session replaced with the block page are logged as blocked.
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
- **Nothing leaves the Mac.** Sending reports to an accountability partner comes later.

Each user on the Mac has their own monitoring settings and only changes their own.
For now they can be turned off or changed at any time.

The explicit-site preset is a snapshot of the
[StevenBlack/hosts](https://github.com/StevenBlack/hosts) porn-only list (MIT
license; tens of thousands of domains), in `Resources/explicit-domains.txt`. Its
header names the commit it came from. Renew never downloads it; refresh it with
`scripts/update-explicit-list.sh` and rebuild.

Apps like Codex/ChatGPT only expose their built-in browser with macOS's
screen-reader mode on, which can make their windows animate oddly. Outside block
sessions Renew turns that on only while the app is in front, and back off as soon
as it isn't.

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
  ├─ [activity monitoring] front browser's tab (1 s) and front app's built-in browser (2 s),
  │    session or not → visits with URL, title, time and flags → renewd every 5 s
  └─ every 2 s: heartbeat + permission report → renewd
        │
renewd  (LaunchDaemon, root)  ── /var/run/renew.sock (start/extend/add/status/report only)
  ├─ owns /var/db/com.renew/state.json (root-only; edits to it can only lengthen a session)
  ├─ counts sessions down on the monotonic clock, so changing the date does nothing
  │    (time the Mac is switched off still counts)
  ├─ sends tamper alerts, if set up
  ├─ keeps the activity log in /var/db/com.renew/activity/<uid>/ (30 days),
  │    and per-site daily totals in .../summary/ (1 year)
  ├─ [keep-running] re-loads the agent if it's unloaded, restarts it if silent
  ├─ [keep-running] restores its files from /var/db/com.renew/backup if deleted or altered
  └─ [keep-running] keeps the guard loaded
renewd --guard  (second LaunchDaemon, loaded by renewd only with keep-running on)
                ── keeps renewd loaded, repairs files, restores state.json

[name]: only with that protection on (see Protections), or with activity monitoring on.

Stopping renewd or the guard during a session sends an alert.
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

- remove the configuration profile (needs its password)
- use Terminal and `sudo` to stop every part of Renew (both daemons and the app)
  in an order that stops each part from putting the others back (with alerts on,
  this tells your partner)
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
- `com.apple.servicemanagement` (locking the background-items toggles) may only take
  effect when the profile is delivered by MDM on some macOS versions. The removal
  password and browser policies work when installed by hand.
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
# Add RENEW_MONITORING=on to record visits; they're written to the app's log.
```

Logs: `/var/log/renew.log`, `/var/log/renew-guard.log`, `~/Library/Logs/Renew/app.log`,
and `/Library/Logs/Renew/` for install and uninstall.

Blocklists are stored in `~/.config/renew/lists.json`.

Only the copy in `/Applications` watches browsers. Any other copy, such as a fresh
build, acts as the installer and updater.
