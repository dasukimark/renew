#!/bin/bash
# Builds Renew.app into ./build (release, signed).
#
# The app bundle contains everything: the UI/monitor (Renew), the root
# daemon (renewd) and CLI (renew) in Contents/Helpers, and the launchd plists +
# install helper.
#
# Signing identity: $RENEW_SIGN_IDENTITY, else the first "Apple Development"
# certificate in your keychain, else ad-hoc. A stable identity (not ad-hoc) is
# what lets macOS keep the Accessibility/Automation grants across rebuilds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ $EUID -eq 0 ]]; then
  echo "build.sh: run as your normal user." >&2
  exit 1
fi

echo "==> Building (release)"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

OUT="$ROOT/build"
APP="$OUT/Renew.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/RenewApp" "$APP/Contents/MacOS/Renew"
cp "$BIN/renewd" "$BIN/renew" "$APP/Contents/Helpers/"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/blocked.html" \
   "$ROOT/Resources/explicit-domains.txt" \
   "$ROOT/Resources/install-helper.sh" \
   "$ROOT/Resources/com.renew.daemon.plist" \
   "$ROOT/Resources/com.renew.guard.plist" \
   "$ROOT/Resources/com.renew.agent.plist" \
   "$APP/Contents/Resources/"

echo "==> Rendering icon"
ICONSET="$(mktemp -d /tmp/renew-icon.XXXXXX)/AppIcon.iconset"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

IDENTITY="${RENEW_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  echo "!!  No 'Apple Development' certificate found; signing ad-hoc."
  echo "    macOS will forget the Accessibility/Automation grants after every rebuild."
  echo "    Fix: Xcode > Settings > Accounts > add your Apple ID > Manage Certificates > +"
fi

echo "==> Signing with: $IDENTITY"
codesign --force --sign "$IDENTITY" --timestamp=none --identifier com.renew.renewd "$APP/Contents/Helpers/renewd"
codesign --force --sign "$IDENTITY" --timestamp=none --identifier com.renew.cli "$APP/Contents/Helpers/renew"
codesign --force --sign "$IDENTITY" --timestamp=none --identifier com.renew.app "$APP"
codesign --verify --strict "$APP"

echo "==> Built $APP"
echo "    Open it to install:  open \"$APP\""
