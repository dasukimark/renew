#!/bin/bash
# Saves the deployed report server's URL and token where Renew's installer
# looks for them (~/.config/renew/report-server.json, readable only by you).
# The installer copies it into renewd's root-only folder, so the Renew app
# only needs your partner's email address.
#
#   server/reports/configure-mac.sh [stack-name] [token-file]
set -euo pipefail
STACK="${1:-renew-reports}"
TOKEN_FILE="${2:-$HOME/.config/renew/report-token}"
OUT="$HOME/.config/renew/report-server.json"

URL="$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ReportURL'].OutputValue" --output text)"
[[ "$URL" == https://* ]] || { echo "couldn't read ReportURL from stack $STACK" >&2; exit 1; }
[[ -s "$TOKEN_FILE" ]] || { echo "no token in $TOKEN_FILE" >&2; exit 1; }

umask 077
mkdir -p "$(dirname "$OUT")"
python3 -c 'import json,sys; print(json.dumps({"url": sys.argv[1], "token": open(sys.argv[2]).read().strip()}))' \
  "$URL" "$TOKEN_FILE" > "$OUT"
echo "Saved $URL to $OUT. Reinstall Renew (sudo scripts/install.sh) to use it."
