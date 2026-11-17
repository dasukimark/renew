#!/bin/bash
# Regenerates Resources/explicit-domains.txt, the bundled "explicit" watch list
# for activity monitoring, from StevenBlack/hosts' porn-only list (MIT).
#
# Developer-only: Renew never downloads lists at runtime. Pass a commit to pin
# a specific version (default: the newest commit on master).
#
#   scripts/update-explicit-list.sh [COMMIT]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Resources/explicit-domains.txt"
COMMIT="${1:-}"
if [[ -z "$COMMIT" ]]; then
  COMMIT="$(curl -fsSL "https://api.github.com/repos/StevenBlack/hosts/commits/master" \
    | sed -n 's/^  "sha": "\([0-9a-f]\{40\}\)".*/\1/p' | head -1)"
fi
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "update-explicit-list: couldn't resolve a commit" >&2; exit 1; }

TMP="$(mktemp -d /tmp/renew-explicit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/hosts" "https://raw.githubusercontent.com/StevenBlack/hosts/$COMMIT/alternates/porn-only/hosts"

# "0.0.0.0 www.example.com" -> "example.com"; lowercase, de-duplicated, sorted.
awk '$1 == "0.0.0.0" && $2 != "0.0.0.0" { print tolower($2) }' "$TMP/hosts" \
  | sed -e 's/^www\.//' -e 's/\.$//' \
  | grep -E '^[a-z0-9.-]+\.[a-z0-9-]+$' \
  | LC_ALL=C sort -u > "$TMP/domains"

{
  echo "# Explicit sites watched by Renew's activity monitoring."
  echo "# Source: https://github.com/StevenBlack/hosts alternates/porn-only/hosts"
  echo "# Commit: $COMMIT"
  echo "# License: MIT (https://github.com/StevenBlack/hosts/blob/master/license.txt)"
  echo "# Regenerate with scripts/update-explicit-list.sh"
  cat "$TMP/domains"
} > "$OUT"
echo "Wrote $(wc -l < "$TMP/domains" | tr -d ' ') domains to $OUT"
