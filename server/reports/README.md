# Renew report server

A small AWS Lambda that turns Renew's flag reports into emails for your
accountability partner. renewd POSTs each report here; the Lambda emails it
from a Gmail account you create just for this. Your partner doesn't need an
account, they only get emails.

Your partner's address is set in the Renew app and sent with each report. It
can only be changed between block sessions, and the previous partner gets a
last email when it is. The token is what stops strangers using the server; to
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

   Answer `GmailAddress`. Leave `AllowedRecipients` empty, or list your
   partner's address to make the server refuse anyone else. `TimeZone` is only
   a fallback: reports carry the Mac's time zone. Say yes when SAM asks whether it's OK that the
   function URL has no authentication: the Lambda checks the token itself.
   The function is named `renew-report-server`; its URL stays the same across
   redeploys (renaming or deleting the function would change it).

5. **Save the server for Renew:** `server/reports/configure-mac.sh` writes the
   URL and token to `~/.config/renew/report-server.json` (readable only by
   you). Reinstall Renew (`sudo scripts/install.sh`); the installer copies it
   into renewd's root-only folder.
6. **Turn reports on:** in **Setup → Email reports**, enter your partner's
   email and click **Turn on reports** (or `renew reports set <partner-email>`). Your partner gets a "reports are on" email. **Send
   test** sends another.

## Check it

```sh
URL=<ReportURL>
curl -i -X POST "$URL" -H "Authorization: Bearer wrong" -d '{}'          # 401
curl -i -X POST "$URL" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"id":"00000000-0000-0000-0000-000000000001","kind":"test","mac":"curl","user":"","sentAt":"2026-01-01T00:00:00Z","flags":[],"changes":["Test from curl"],"to":"you@example.com"}'   # 200, email arrives
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
- **Cost.** Well inside the AWS free tier at this volume. Gmail is free.
- **A 403 from the URL** (rather than 401) means AWS isn't letting the public
  call the function URL; check the function's resource-based policy allows
  `lambda:InvokeFunctionUrl` (and, on newer accounts, `lambda:InvokeFunction`)
  for principal `*` with function URL auth type `NONE`.
- **Changing the partner:** in Renew, between block sessions. If you set
  `AllowedRecipients`, add the new address there first (`sam deploy`).
  **Changing the token:** update the SSM parameter, then redeploy so the
  Lambda reads it again (it caches secrets while it stays warm), and set the
  new token in Renew: rerun `configure-mac.sh` and reinstall Renew.

## Tests

```sh
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest
```
