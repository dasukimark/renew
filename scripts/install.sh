#!/bin/bash
# Command-line alternative to clicking "Install" in the app:
#   sudo scripts/install.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $EUID -ne 0 || -z "${SUDO_USER:-}" || "$SUDO_USER" == "root" ]]; then
  echo "Run with sudo from your normal account: sudo $0" >&2
  exit 1
fi

sudo -u "$SUDO_USER" "$ROOT/scripts/build.sh"
/bin/bash "$ROOT/Resources/install-helper.sh" "$ROOT/build/Renew.app" "$(id -u "$SUDO_USER")"
launchctl asuser "$(id -u "$SUDO_USER")" sudo -u "$SUDO_USER" /usr/bin/open /Applications/Renew.app || true
echo "Done. Renew is in your menu bar; the window walks you through permissions."
