#!/bin/bash
# Rebuild Renew, install it over /Applications/Renew.app through the macOS
# administrator prompt (the user types the password), and leave exactly one
# copy of the app running: the newly installed one.
#
#   reinstall.sh [--no-build] [--no-open]
#
# Run as the normal user from anywhere inside the renew checkout.
set -euo pipefail

BUILD=1; OPEN=1
for a in "$@"; do
  case "$a" in
    --no-build) BUILD=0 ;;
    --no-open) OPEN=0 ;;
    *) echo "unknown option: $a" >&2; exit 64 ;;
  esac
done

[[ $EUID -ne 0 ]] || { echo "Run as your normal user, not root." >&2; exit 1; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "Not inside the renew checkout." >&2; exit 1; }
[[ -f "$ROOT/Resources/install-helper.sh" && -x "$ROOT/scripts/build.sh" ]] || { echo "$ROOT is not the renew repo." >&2; exit 1; }
cd "$ROOT"

INSTALLED="/Applications/Renew.app/Contents/MacOS/Renew"
# Copies run straight from the checkout: the build/ installer window and
# `swift run` / .build debug binaries. Only the installed copy should run.
STRAY_PATTERN="$ROOT/build/Renew\.app/Contents/MacOS/Renew|\.build/(debug|release)/RenewApp"
LOG=/tmp/renew-install.log

if [[ -x /Applications/Renew.app/Contents/Helpers/renew ]] \
   && /Applications/Renew.app/Contents/Helpers/renew status 2>/dev/null | grep -qE "(Focus|Block) session active"; then
  echo "BLOCKED: a block session is running; the installer refuses until it ends." >&2
  exit 3
fi

if [[ $BUILD -eq 1 ]]; then
  echo "==> Building"
  scripts/build.sh 2>&1 | tail -3
fi
APP="$ROOT/build/Renew.app"
[[ -d "$APP/Contents/MacOS" ]] || { echo "No build at $APP (run without --no-build)." >&2; exit 1; }

echo "==> Closing copies running from the checkout (never open build/Renew.app)"
pkill -f "$STRAY_PATTERN" 2>/dev/null || true
for _ in {1..20}; do pgrep -f "$STRAY_PATTERN" >/dev/null || break; sleep 0.25; done

echo "==> Installing (macOS will ask for the administrator password)"
if ! osascript -e "do shell script \"/bin/bash '$ROOT/Resources/install-helper.sh' '$APP' $(id -u) > $LOG 2>&1\" with prompt \"Renew needs your password to install the new build.\" with administrator privileges" >/dev/null 2>&1; then
  echo "INSTALL FAILED (or the password prompt was cancelled). Last log lines:" >&2
  tail -8 "$LOG" >&2 2>/dev/null || true
  exit 2
fi
tail -2 "$LOG"

# The installer restarts the launchd agent, which runs the installed app as
# one `--background` process (menu bar icon). `open` shows that process's
# window; it does not start a second copy.
sleep 3
pkill -f "$STRAY_PATTERN" 2>/dev/null || true
running=$(pgrep -f "^$INSTALLED" | wc -l | tr -d ' ')
if [[ $running -gt 1 ]]; then
  echo "closing $((running - 1)) older installed copy/copies, keeping the newest"
  pgrep -f "^$INSTALLED" | sort -n | sed '$d' | xargs kill 2>/dev/null || true
fi
[[ $OPEN -eq 1 ]] && open /Applications/Renew.app
sleep 2

echo "==> Verify"
if cmp -s "$APP/Contents/MacOS/Renew" "$INSTALLED"; then echo "installed app matches the new build"; else echo "WARNING: installed app differs from build/Renew.app"; fi
echo "installed copies running: $(pgrep -f "^$INSTALLED" | wc -l | tr -d ' ') (expected 1); copies from the checkout: $(pgrep -f "$STRAY_PATTERN" | wc -l | tr -d ' ') (expected 0)"
pgrep -lf renewd | head -3 || echo "WARNING: renewd is not running"
/Applications/Renew.app/Contents/Helpers/renew status 2>&1 | head -3 || true
