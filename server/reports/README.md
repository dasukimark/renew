# Renew report server

A small AWS Lambda that turns Renew's flag reports into emails for your
accountability partners. renewd POSTs each report here; the Lambda emails it
from a Gmail account you create just for this. Partners don't need an
account, they only get emails.

It also keeps track of renewd's **check-ins** (about every 15 minutes while
reports are on, plus one before the Mac sleeps or renewd exits) in a small
DynamoDB table, and every minute emails the partners about any Mac that went
quiet without warning. See [Check-ins](#check-ins).

Your partners' addresses (up to 10) are set in the Renew app and sent with
each report, as one address or a list; each email goes to all of them. They
can only be changed between block sessions, and a removed partner gets a last
email. The token is what stops strangers using the server; to
also limit which addresses it will email, set `AllowedRecipients`.

Reports name the site, the page title, why it was flagged, when and for how
long. They never contain full addresses.

## One-time setup

You need an AWS account, the [AWS CLI](https://aws.amazon.com/cli/) and the
[SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html).

1. **Create a Gmail account** used only for this, e.g. `renew.reports.yourname@gmail.com`.
2. **Turn on 2-Step Verification** for it (Google Account → Security), then
   create an **app password** (Google Account → Security → App passwords).
   Copy the 16-character password.
3. **Store the secrets in SSM Parameter Store** (pick your region and keep it
   for the deploy):

   ```sh
   # A long random token that renewd sends with each report.
   TOKEN=$(openssl rand -hex 32); echo "$TOKEN"   # keep this for step 5
   aws ssm put-parameter --name /renew/report-token --type SecureString --value "$TOKEN"
   aws ssm put-parameter --name /renew/gmail-app-password --type SecureString --value 'abcd efgh ijkl mnop'
   ```

4. **Deploy:**

   ```sh
   cd server/reports
   sam build && sam deploy --guided
   ```

   Answer `GmailAddress`. `SilenceMinutes` (120), `StoppingMinutes` (3) and
   `QuietCapHours` (168) set when check-in emails go out (see
   [Check-ins](#check-ins)); the defaults are fine.

   Redeploying keeps the values the stack already has, not the template's
   defaults. To change them later, pass them explicitly:
   `sam deploy --parameter-overrides GmailAddress=<address> SilenceMinutes=120 StoppingMinutes=3 QuietCapHours=168`. Leave `AllowedRecipients` empty, or list your
   partners' addresses to make the server refuse anyone else. `TimeZone` is only
   a fallback: reports carry the Mac's time zone. Say yes when SAM asks whether it's OK that the
   function URL has no authentication: the Lambda checks the token itself.
   The function is named `renew-report-server`; its URL stays the same across
   redeploys (renaming or deleting the function would change it).

5. **Save the server for Renew:** `server/reports/configure-mac.sh` writes the
   URL and token to `~/.config/renew/report-server.json` (readable only by
   you). Reinstall Renew (`sudo scripts/install.sh`); the installer copies it
   into renewd's root-only folder.
6. **Turn reports on:** in **Accountability → Partners**, enter your partners'
   emails and click **Turn on reports** (or `renew reports set <email> [<email>...]`). Your partners get a "reports are on" email. **Send
   test** sends another.

## Check-ins

Each check-in says whether the Mac is `awake`, going to sleep (`sleeping`),
shutting down (`shutdown`), or that renewd stopped without a shutdown
(`stopping`), along with when the Mac booted. It names the partners, Mac and
user only when renewd starts or those change; the table keeps them. A
check-in without them from a Mac the server doesn't know gets
`{"needDetails": true}`, and renewd sends them next time. `removed` (reports
turned off or moved, or `renew uninstall`) deletes the Mac's entry. The table
(`renew-heartbeats`) is created by `sam deploy`; no new secrets are needed.

Every minute the Lambda emails the partners about a Mac that:

- was `awake` and hasn't checked in for `SilenceMinutes` (120). renewd
  reports time it wasn't running itself (`gaps`), so this only catches Renew
  never coming back. Use 10 with Renew versions from before the power-log
  check: on those, force-quitting renewd and restarting the Mac within the
  wait goes unreported;
- was `stopping` and hasn't checked in for `StoppingMinutes` (3);
- was `sleeping` or `shutdown` and hasn't checked in for `QuietCapHours` (168, 7 days).

When a check-in arrives it may also send one email:

- "checking in again" after one of those, saying whether the Mac restarted,
  listing downtime, or calling it a false alarm when renewd says it was
  running the whole time (`coveredSince`);
- "Renew was stopped" when the Mac said it was shutting down but comes back
  without having restarted;
- "Renew wasn't running" for downtime renewd's internal heartbeat found
  (`gaps`: time the Mac was awake while renewd wasn't running, measured from
  macOS's power log when the Mac restarted in between; `kind:
  "recordsMissing"` when renewd's records were deleted or replaced, so the
  length is unknown).

Each silence and each gap is emailed once; email ids depend on what they're
about, so a retry is never a second email. The reply to a check-in lists what
the partners were emailed, which the Renew app shows under **Accountability →
Sent to your partners**.

## Check it

```sh
URL=<ReportURL>
curl -i -X POST "$URL" -H "Authorization: Bearer wrong" -d '{}'          # 401
curl -i -X POST "$URL" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"id":"00000000-0000-0000-0000-000000000001","kind":"test","mac":"curl","user":"","sentAt":"2026-01-01T00:00:00Z","flags":[],"changes":["Test from curl"],"to":"you@example.com"}'   # 200, email arrives
```

A check-in (stored, no email; delete it again with `"state":"removed"`):

```sh
curl -i -X POST "$URL" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"kind":"heartbeat","id":"00000000-0000-0000-0000-000000000002","install":"00000000-0000-0000-0000-0000000000aa","to":"you@example.com","mac":"curl","user":"","timeZone":"UTC","sentAt":"2026-01-01T00:00:00Z","state":"awake","boot":"2026-01-01T00:00:00Z","interval":240}'   # 200 {"notices": []}
```

Logs are in CloudWatch under `/aws/lambda/<function name>` (kept 30 days).

## Good to know

- **Gmail may ask you to confirm it's you.** Now and then Google pauses
  automated sign-ins to a new account. Sending then fails (the logs say Gmail
  refused the sign-in) until you sign in to the account in a browser. Renew
  keeps unsent reports on the Mac and sends them once it works again.
- **Limits.** Gmail sends about 500 emails a day; Renew groups flags into one
  report a minute at most, so you won't come near it. The Lambda runs at most
  two at once.
- **Cost.** Well inside the AWS free tier at this volume (a check-in every 15
  minutes and a check every minute is about 46,000 requests a month, against
  a million free; the table holds one small item per Mac). Gmail is free.
- **A 403 from the URL** (rather than 401) means AWS isn't letting the public
  call the function URL; check the function's resource-based policy allows
  `lambda:InvokeFunctionUrl` (and, on newer accounts, `lambda:InvokeFunction`)
  for principal `*` with function URL auth type `NONE`.
- **Changing partners:** add partners any time, remove them between block
  sessions. If you set `AllowedRecipients`, add any new address there first
  (`sam deploy`). **More than one partner needs a server deployed after
  several partners were added:** an older one refuses every report and
  check-in sent to a list (HTTP 400), so redeploy before adding a second
  partner.
  **Changing the token:** update the SSM parameter, then redeploy so the
  Lambda reads it again (it caches secrets while it stays warm), and set the
  new token in Renew: rerun `configure-mac.sh` and reinstall Renew.

## Tests

```sh
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest
```
