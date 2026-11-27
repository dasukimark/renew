# Renew: notes for coding agents

## Writing partner emails

Partner emails are read on a phone, often in a hurry. Keep every email, and
any new one, as short as the ones in `server/reports/heartbeat.py`
(`lines_for`, `gap_line`) and the `reporter.add(changes:)` / `notify(...)`
messages in `Sources/renewd`.

- **Say what happened, then what it might mean. Stop there.** One or two short
  sentences each; at most three lines per email body.
- **Don't repeat the Mac's name.** The line under the heading already says
  "on <Mac> (<user>)". Write "Renew stopped…", not "Renew on <Mac> stopped…".
- **Short times.** Use `render.between` for ranges ("Tue 17 Nov, 14:02–14:09
  EST"), not two full dates.
- **Plain words.** "Renew was stopped", not "Renew's background service was
  stopped"; "heartbeat", not "the guard saw the daemon heartbeat".
- **No restating what partners already know**: how check-ins work in general,
  what every email type means, or what the buttons do. A fact needed to read
  this email (like the usual check-in interval) is fine.
- **Keep these**: the anti-phishing line on approval buttons ("Renew will not
  ask for a password.") and the footer's "Sites are shown without links."
- **No links to sites** (see `render.py`'s docstring) and no explicit words in
  examples or manual checks.

`test_heartbeat.py::test_checkin_emails_stay_short` fails when a check-in
email gets long (new kinds in `render.CHECKIN` are covered automatically).
The Mac-side messages in `Sources/renewd` have no such test: keep them to one
or two short sentences by hand.
