# Renew

A FocusMe-style website blocker for macOS. It watches your browsers, and when the
current tab is on a blocked site, it swaps the page for a block page. Sessions can't
be shortened or stopped once started, and Renew is deliberately hard (not
impossible) to kill or uninstall while one is running.

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

- **Focus**: pick a duration (25 min to 4 hours, or custom), tick blocklists, add
  extra sites and start. During a session it shows a countdown ring and the blocked
  sites, and lets you add time or block another site. There's no stop button.
- **Blocklists**: edit the built-in lists (social, video, news, test) or make your own.
- **Setup**: service status, permissions, the lock-down profile, and uninstall
  (between sessions only, after typing a confirmation phrase).

Closing the window or pressing ⌘Q leaves Renew running in the menu bar.

Rule syntax:

| Rule | Blocks |
|---|---|
| `reddit.com` | the domain and every subdomain |
| `youtube.com/shorts` | that path (and below) only; the rest of YouTube still works |
| `keyword:casino` | any URL containing the word |
| `!music.youtube.com` | an allow exception (always wins) |

A command-line tool is also installed for scripting (`renew start 2h --list social`,
`renew status`, `renew extend 30m`, `renew add x.com`, `sudo renew uninstall`).

## How it works

```
/Applications/Renew.app  (menu bar + window; LaunchAgent in your login session)
  ├─ every 0.5 s: frontmost browser's active tab URL
  │    Safari/Chrome/Edge/Brave/Arc/Vivaldi → AppleScript
  │    Firefox → Accessibility API (AXURL of the web area / address bar)
  ├─ blocked? → redirect tab to http://127.0.0.1:<port>/blocked
  │            (Firefox, or if the redirect fails → full-screen overlay + Cmd-W)
  ├─ unsupported browsers (Opera, Orion, Zen, Tor, DuckDuckGo…) and web apps
  │    (Safari "Add to Dock", Chrome/Edge installed apps) → quit + overlay
  ├─ supported browser it can't watch (permission off, or unreadable for ~10 s)
  │    → quit + overlay, again on every relaunch
  └─ every 2 s: heartbeat + permission report → renewd
        │
renewd  (LaunchDaemon, root)  ── /var/run/renew.sock (start/extend/add/status/report only)
  ├─ owns /var/db/com.renew/state.json (root-only; edits to it can only lengthen a session)
  ├─ re-loads the agent if it's unloaded, restarts it if silent
  ├─ restores its files from /var/db/com.renew/backup if deleted or altered
  └─ keeps the guard loaded
renewd --guard  (second LaunchDaemon) ── keeps renewd loaded, repairs files, restores state.json
```

**Turning off a permission doesn't get you past it.** If you switch off Renew's
Automation permission for a browser during a session, Renew closes that browser
and closes it again whenever it's reopened, until the session ends or you turn the
permission back on. Turning off Accessibility does the same to Firefox. Other browsers
keep working with blocking as normal.

Renew never changes your network settings, `/etc/hosts` or the firewall.

## What's left for someone determined to escape

Renew is friction, not a vault. An admin who goes through all of this can
still get out:

- remove the configuration profile (needs its password)
- `sudo launchctl bootout` the guard, the daemon *and* the app's LaunchAgent fast
  enough, then delete `/var/db/com.renew/backup` and the installed files
- boot into Safe Mode or Recovery and delete things

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
```

Logs: `/var/log/renew.log`, `/var/log/renew-guard.log`, `~/Library/Logs/Renew/app.log`,
and `/Library/Logs/Renew/` for install and uninstall.

Blocklists are stored in `~/.config/renew/lists.json`.

Only the copy in `/Applications` watches browsers. Any other copy, such as a fresh
build, acts as the installer and updater.
