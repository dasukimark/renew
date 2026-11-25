---
name: renew-reinstall
description: Rebuild Renew and install it over /Applications/Renew.app so exactly one copy runs, and redeploy the report server (AWS Lambda in server/reports) when asked or when it changed. Use for "reinstall", "reinstall for me, I'll type the password", "install updates", "redeploy and reinstall", "deploy and install", "did you reinstall?", or "I have 2 copies open".
---

# Renew reinstall / redeploy

The user tests every Renew change by reinstalling it. Do the whole thing yourself; the only manual step is the user typing their password into the macOS dialog.

Resolve `<skill-dir>` to the directory containing this SKILL.md (follow symlinks).

## Reinstall the app

Run from the renew checkout:

```sh
"<skill-dir>/scripts/reinstall.sh"
```

Before running it, tell the user in one line to watch for the macOS password prompt. The script:

1. Refuses while a block session is running (the installer would refuse anyway). Report that and stop.
2. Builds with `scripts/build.sh` (`--no-build` reuses the existing `build/Renew.app`).
3. Closes copies running from the checkout (`build/Renew.app`, `.build/*/RenewApp`).
4. Runs `Resources/install-helper.sh` as root through `osascript … with administrator privileges`, logging to `/tmp/renew-install.log`.
5. Leaves a single installed copy running, opens its window (`--no-open` skips this) and checks that the installed binary matches the build and that `renewd` is running.

How the app runs, which explains the "2 copies" problem: the installed app runs as **one** `--background` process started by the launchd agent (menu bar icon), and `open /Applications/Renew.app` only shows that process's window. **Never `open build/Renew.app`.** It starts a separate installer window, which the user sees as a second copy. Don't ask the user to run `sudo scripts/install.sh` or click "Update the installed Renew…" either. This skill does the install for them.

If the script exits 2, the password prompt was cancelled or the install failed. Show the log tail it printed. Don't retry in a loop. Ask the user, once, whether to try again.

## Redeploy the report server

Redeploy when the user says "redeploy" or "deploy", or when `server/reports/` changed since the last deploy and the app change depends on it (new request fields, new endpoints, more than one partner). Plain "reinstall" doesn't include a redeploy when `server/` hasn't changed.

```sh
cd server/reports && sam build 2>&1 | tail -2 && \
sam deploy --stack-name renew-reports --region us-east-2 --resolve-s3 \
  --capabilities CAPABILITY_IAM --no-confirm-changeset --no-fail-on-empty-changeset 2>&1 | tail -15
```

- Leave out `--parameter-overrides`: a redeploy keeps the values the stack already has (Gmail address, token parameters, `SilenceMinutes`, …). Pass overrides only when the user asked to change a value. In that case pass **every** parameter you change, quoted as a single string, and read the current values first with `aws cloudformation describe-stacks --stack-name renew-reports --region us-east-2 --query "Stacks[0].Parameters"`.
- Never delete or rename the stack or the `renew-report-server` function, because the function URL baked into installs would change.
- Run the server tests first if `server/reports` changed: `python3 -m venv /tmp/renew-venv && /tmp/renew-venv/bin/pip install -q -r server/reports/requirements-dev.txt && (cd server/reports && /tmp/renew-venv/bin/python -m pytest -q)`.
- Verify: `aws lambda get-function-configuration --function-name renew-report-server --region us-east-2 --query LastModified`.

For "redeploy and reinstall", deploy the server first, then reinstall the app.

## Report

Keep the report to two or three lines: built and installed (or why not), whether exactly one copy is running, and the deploy result if one ran. Don't explain the install mechanism unless something failed.

## Testing rules the user set

- Manual tests of explicit-content flagging never use real explicit words. Use neutral stand-in words, or unit tests.
- Don't visit or test the explicit site list yourself.
