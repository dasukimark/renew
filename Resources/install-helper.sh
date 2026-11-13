#!/bin/bash
# Installs Renew system-wide from a built Renew.app. Runs as root.
#
#   install-helper.sh <path/to/Renew.app> <console-uid>
#
# Called by the app (through the admin password prompt) and by scripts/install.sh.
set -euo pipefail

SRC_APP="${1:?usage: install-helper.sh <Renew.app> <uid>}"
USER_UID="${2:?usage: install-helper.sh <Renew.app> <uid>}"

APP="/Applications/Renew.app"
INSTALL_DIR="/Library/Application Support/Renew"
DATA_DIR="/var/db/com.renew"
DAEMON_PLIST="/Library/LaunchDaemons/com.renew.daemon.plist"
GUARD_PLIST="/Library/LaunchDaemons/com.renew.guard.plist"
AGENT_PLIST="/Library/LaunchAgents/com.renew.agent.plist"

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
[[ -d "$SRC_APP/Contents/MacOS" ]] || { echo "not an app bundle: $SRC_APP" >&2; exit 1; }

# Installing over a running session would be an easy way around the lock.
if [[ -S /var/run/renew.sock && -x "$INSTALL_DIR/bin/renew" ]]; then
  if "$INSTALL_DIR/bin/renew" status 2>/dev/null | grep -q "Focus session active"; then
    echo "A focus session is running. Install/update is allowed after it ends." >&2
    exit 1
  fi
fi

echo "==> Stopping any previous install"
launchctl bootout "gui/$USER_UID/com.renew.agent" 2>/dev/null || true
launchctl bootout system/com.renew.guard 2>/dev/null || true
launchctl bootout system/com.renew.daemon 2>/dev/null || true

echo "==> Installing $APP"
SRC_REAL="$(cd "$SRC_APP" && pwd -P)"
if [[ "$SRC_REAL" != "$APP" ]]; then
  STAGE="$(mktemp -d /tmp/renew-install.XXXXXX)"
  ditto "$SRC_APP" "$STAGE/Renew.app"
  rm -rf "$APP"
  mv "$STAGE/Renew.app" "$APP"
  rm -rf "$STAGE"
fi
chown -R root:wheel "$APP"
chmod -R go-w "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "==> Installing background service"
mkdir -p "$INSTALL_DIR/bin" "$DATA_DIR/backup"
install -m 755 "$APP/Contents/Helpers/renewd" "$INSTALL_DIR/bin/renewd"
install -m 755 "$APP/Contents/Helpers/renew" "$INSTALL_DIR/bin/renew"
install -m 644 "$APP/Contents/Resources/com.renew.daemon.plist" "$DAEMON_PLIST"
install -m 644 "$APP/Contents/Resources/com.renew.guard.plist" "$GUARD_PLIST"
install -m 644 "$APP/Contents/Resources/com.renew.agent.plist" "$AGENT_PLIST"
chown -R root:wheel "$INSTALL_DIR" "$DATA_DIR" "$DAEMON_PLIST" "$GUARD_PLIST" "$AGENT_PLIST"
chmod -R go-w "$INSTALL_DIR"
chmod 700 "$DATA_DIR" "$DATA_DIR/backup"
mkdir -p /usr/local/bin
ln -sf "$INSTALL_DIR/bin/renew" /usr/local/bin/renew

# Seed the backups that self-repair restores from.
for f in renewd renew; do ditto "$INSTALL_DIR/bin/$f" "$DATA_DIR/backup/$f"; done
rm -rf "$DATA_DIR/backup/Renew.app"
ditto "$APP" "$DATA_DIR/backup/Renew.app"
for p in "$DAEMON_PLIST" "$GUARD_PLIST" "$AGENT_PLIST"; do ditto "$p" "$DATA_DIR/backup/$(basename "$p")"; done

echo "==> Starting services"
launchctl bootstrap system "$DAEMON_PLIST"
launchctl bootstrap system "$GUARD_PLIST"
if [[ "$USER_UID" != "0" ]]; then
  launchctl bootstrap "gui/$USER_UID" "$AGENT_PLIST" || launchctl kickstart -k "gui/$USER_UID/com.renew.agent" || true
fi
echo "==> Renew installed"
