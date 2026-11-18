"""Check-ins (heartbeats) from renewd, and emails when they stop.

While email reports are on, renewd checks in about every 15 minutes (each
check-in says how often), at once when it has downtime to report, and
also says when the Mac is going to sleep (`sleeping`), shutting down
(`shutdown`), or when its service stops without a shutdown (`stopping`).
Each Mac's latest check-in is one item in a DynamoDB table, keyed by its
install id. The partner, Mac name and user come only in some check-ins
(when they change); the item keeps them. A scheduled run every minute
(`check_all`) emails the partner when:

- `awake`, then nothing for SILENCE_MINUTES (120): "silent". renewd's
  internal heartbeat reports time it wasn't running (`gaps`) by itself, so
  this is only the dead man's switch for Renew never coming back.
- `stopping`, then nothing for STOPPING_MINUTES (3): "silent".
- `sleeping` or `shutdown`, then nothing for QUIET_CAP_HOURS (168): "quiet".

When a check-in arrives (`record_beat`) it may email too (one email at most):

- "back" after a silent or quiet email: whether the Mac restarted, whether
  Renew was running the whole time (it lost its connection), and any
  downtime renewd's internal heartbeat found.
- "stopped" when the Mac said it was shutting down but comes back without
  having restarted, so the service was stopped rather than the Mac.
- "gap" when renewd's internal heartbeat found time the Mac was awake
  without Renew running (it was stopped and started again).

`removed` (reports turned off or moved, or Renew uninstalled through
`renew uninstall`) deletes the item, so no email follows.
"""

import json
import os
import time
import uuid
from datetime import datetime, timezone

from render import CHECKIN, recipients, when, zone_for

STATES = {"awake", "sleeping", "shutdown", "stopping", "removed"}
GAP_KINDS = {"recordsMissing"}
MAX_TEXT = 300
# Pending notices kept per Mac until it next checks in.
MAX_NOTICES = 20
MAX_GAPS = 50
# Gap ids already emailed, so a check-in sent twice doesn't email twice.
MAX_REPORTED_GAPS = 200
# A different boot time by more than this means the Mac restarted.
BOOT_TOLERANCE = 5


class Invalid(ValueError):
    pass


class SendFailed(Exception):
    pass


def now():
    return int(time.time())


def silence_seconds():
    return int(float(os.environ.get("SILENCE_MINUTES", "120")) * 60)


def stopping_seconds():
    return int(float(os.environ.get("STOPPING_MINUTES", "3")) * 60)


def cap_seconds():
    return int(float(os.environ.get("QUIET_CAP_HOURS", "168")) * 3600)


# MARK: parsing

def _text(value, field, limit=MAX_TEXT):
    if not isinstance(value, str):
        raise Invalid(f"{field} must be a string")
    text = value.strip()
    return text if len(text) <= limit else text[:limit - 1] + "…"


def _epoch(value, field):
    text = _text(value, field)
    try:
        dt = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        raise Invalid(f"{field} must be an ISO 8601 date") from None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


def _uuid(value, field):
    try:
        return str(uuid.UUID(str(value)))
    except ValueError:
        raise Invalid(f"{field} must be a UUID") from None


def parse_heartbeat(body):
    """Checks a check-in's shape and returns a cleaned copy. Raises Invalid."""
    try:
        data = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        raise Invalid("body is not JSON") from None
    if not isinstance(data, dict) or data.get("kind") != "heartbeat":
        raise Invalid("not a heartbeat")
    state = data.get("state")
    if state not in STATES:
        raise Invalid("unknown state")
    to = data.get("to")
    if to is not None:
        to = recipients(to)
        if to is None:
            raise Invalid("to must be an email address or a short list of them")
    interval = data.get("interval", 240)
    if not isinstance(interval, int) or isinstance(interval, bool) or not 60 <= interval <= 86400:
        raise Invalid("interval must be a whole number of seconds")
    zone = data.get("timeZone")
    if zone is not None and not isinstance(zone, str):
        raise Invalid("timeZone must be a string")
    gaps_in = data.get("gaps") or []
    if not isinstance(gaps_in, list) or len(gaps_in) > MAX_GAPS:
        raise Invalid("gaps must be a short list")
    gaps = []
    for i, g in enumerate(gaps_in):
        if not isinstance(g, dict):
            raise Invalid(f"gaps[{i}] must be an object")
        awake = g.get("awakeSeconds")
        if awake is not None and (not isinstance(awake, int) or isinstance(awake, bool) or awake < 0):
            raise Invalid(f"gaps[{i}].awakeSeconds must be a whole number")
        kind = g.get("kind")
        if kind is not None and kind not in GAP_KINDS:
            # A kind from a newer Renew: still a gap, worded as an ordinary one.
            kind = None
        gaps.append({"id": _uuid(g.get("id"), f"gaps[{i}].id"), "from": _epoch(g.get("from"), f"gaps[{i}].from"),
                     "to": _epoch(g.get("to"), f"gaps[{i}].to"), "awakeSeconds": awake,
                     "restarted": g.get("restarted") is True, "kind": kind})
    last = data.get("lastAccepted")
    covered = data.get("coveredSince")
    details = to is not None
    return {
        "id": _uuid(data.get("id"), "id"),
        "install": _uuid(data.get("install"), "install"),
        "details": details,
        "to": to if details else None,
        "mac": (_text(data.get("mac") or "a Mac", "mac") or "a Mac") if details else None,
        "user": _text(data.get("user") or "", "user") if details else None,
        "timeZone": (zone or "")[:64] if details else None,
        "state": state,
        "sentAt": _epoch(data.get("sentAt"), "sentAt"),
        "boot": _epoch(data.get("boot"), "boot"),
        "bootID": _text(data["bootID"], "bootID", 64) if data.get("bootID") is not None else None,
        "interval": interval,
        "lastAccepted": _epoch(last, "lastAccepted") if last is not None else None,
        "coveredSince": _epoch(covered, "coveredSince") if covered is not None else None,
        "gaps": gaps,
    }


# MARK: wording

def gap(seconds):
    """A rough, readable length of time: "35 minutes", "2 days 4 hours"."""
    seconds = max(0, int(seconds))
    minutes = seconds // 60
    if minutes < 1:
        return "under a minute"
    if minutes < 60:
        return f"{minutes} minute{'s' if minutes != 1 else ''}"
    hours, m = divmod(minutes, 60)
    if hours < 24:
        out = f"{hours} hour{'s' if hours != 1 else ''}"
        return out + (f" {m} minute{'s' if m != 1 else ''}" if m else "")
    days, h = divmod(hours, 24)
    out = f"{days} day{'s' if days != 1 else ''}"
    return out + (f" {h} hour{'s' if h != 1 else ''}" if h else "")


def _dt(epoch):
    return datetime.fromtimestamp(int(epoch), tz=timezone.utc)


def _who(item):
    return item["mac"] + (f" ({item['user']})" if item.get("user") else "")


AGAIN = "You'll get another email when it checks in again."


def lines_for(kind, item, at, beat=None):
    """The sentences of a check-in email about `item` (the stored check-in)."""
    zone = zone_for(item.get("timeZone"))
    who = _who(item)
    last = when(_dt(item["lastSeen"]), zone)
    age = gap(at - item["lastSeen"])
    if kind == "silent" and item["state"] == "stopping":
        return [f"Renew's background service on {who} stopped at {last} without the Mac shutting down normally, "
                f"and it hasn't checked in since.",
                "It may have been stopped or removed, or the Mac shut down in a way Renew couldn't see.",
                AGAIN]
    if kind == "silent":
        return [f"Renew on {who} last checked in at {last}, {age} ago. While the Mac is awake it checks in "
                f"about every {gap(item.get('interval', 240))}.",
                "That can mean Renew was removed, or the Mac has been awake but offline (or lost power). "
                "If Renew was only stopped, it says so, with how long, once it runs again.",
                AGAIN]
    if kind == "quiet":
        doing = "going to sleep" if item["state"] == "sleeping" else "shutting down"
        return [f"Renew on {who} said the Mac was {doing} at {last}, and it hasn't checked in for {age} since.",
                "That's fine if the Mac has been put away. It can also mean Renew was removed while the Mac was off.",
                AGAIN]
    gaps = (beat or {}).get("newGaps") or []
    if kind == "back":
        out = [f"Renew on {who} is checking in again, {age} after it last did."]
        if gaps:
            out += [gap_line(g, who, zone) for g in gaps]
        elif _covered(item, beat):
            out.append("False alarm: Renew was running whenever the Mac was awake. The Mac was asleep, or "
                       "couldn't reach the report server (it was offline, or the network blocked it).")
        elif _restarted(item, beat):
            out.append(f"The Mac restarted in that time (at {when(_dt(beat['boot']), zone)}).")
        else:
            out.append("The Mac didn't restart in that time, so Renew's background service was stopped, "
                       "or the Mac was awake but offline.")
        return out
    if kind == "stopped":
        return [f"Renew on {who} said the Mac was shutting down at {last}, but the Mac didn't restart: "
                f"Renew's background service was stopped for {age}."] + [gap_line(g, who, zone) for g in gaps]
    if kind == "gap":
        return [gap_line(g, who, zone) for g in gaps]
    raise ValueError(kind)


def gap_line(g, who, zone):
    span = f"{when(_dt(g['from']), zone)} to {when(_dt(g['to']), zone)}"
    if g.get("kind") == "recordsMissing":
        return (f"Renew's records on {who} were deleted or replaced with an old copy while it wasn't running "
                f"({span}), so it can't tell whether Renew was stopped while the Mac was awake.")
    if g.get("awakeSeconds") is not None and g.get("restarted"):
        return (f"Renew wasn't running on {who} for {gap(g['awakeSeconds'])} while the Mac was awake, "
                f"and the Mac restarted before it ran again ({span}).")
    if g.get("awakeSeconds") is not None:
        return f"Renew wasn't running on {who} for {gap(g['awakeSeconds'])} while the Mac was awake ({span})."
    return (f"Renew's background service on {who} was stopped, and the Mac restarted before it ran again "
            f"({span}).")


def _covered(item, beat):
    """Whether renewd says it was running whenever the Mac was awake since
    the last check-in the server got."""
    covered = (beat or {}).get("coveredSince")
    return covered is not None and covered <= int(item["lastSeen"]) and not _restarted(item, beat)


def _restarted(item, beat):
    """Whether the Mac booted between the stored check-in and `beat`: by
    boot session id when both have one (boot times move when the clock is
    set), else by boot time."""
    if item.get("bootID") and (beat or {}).get("bootID"):
        return item["bootID"] != beat["bootID"]
    return abs(int(item.get("boot", 0)) - int(beat["boot"])) > BOOT_TOLERANCE


def email_for(kind, item, at, beat=None):
    """A cleaned report (see app.parse_report) for render.build_email. Its id
    depends only on the Mac, the kind, the check-in it's about and the gaps
    it lists, so a repeat is the same email (Gmail drops repeats of a
    Message-ID). `item` may be a stored check-in without an install (for
    gap emails, the new identity is used)."""
    target = beat if beat and beat.get("to") else item
    gap_ids = ",".join(sorted(g["id"] for g in (beat or {}).get("newGaps") or []))
    return {
        "id": str(uuid.uuid5(uuid.NAMESPACE_URL,
                             f"renew-checkin/{item['install']}/{kind}/{item['lastSeen']}/{gap_ids}")),
        "to": target["to"],
        "timeZone": target.get("timeZone") or "",
        "kind": kind,
        "mac": target["mac"],
        "user": target.get("user", ""),
        "sentAt": _dt(at),
        "flags": [],
        "omitted": 0,
        "changes": lines_for(kind, item, at, beat),
    }


def notice(report):
    """What renewd shows in its history for an email that was sent."""
    return {"title": CHECKIN[report["kind"]][1], "lines": report["changes"],
            "at": report["sentAt"].strftime("%Y-%m-%dT%H:%M:%SZ")}


# MARK: deciding

def decide(item, at, silence, cap, stopping=180):
    """None, "silent" or "quiet" for a stored check-in at time `at`."""
    if item.get("alerted"):
        return None
    age = at - int(item["lastSeen"])
    if item["state"] == "stopping":
        return "silent" if age > stopping else None
    if item["state"] == "awake":
        # Never sooner than two and a half missed check-ins.
        limit = max(silence, int(item.get("interval", 240)) * 5 // 2)
        return "silent" if age > limit else None
    if item["state"] in ("sleeping", "shutdown"):
        return "quiet" if age > cap else None
    return None


def record_beat(beat, at, store, send, attempts=3):
    """Stores `beat` and sends any back/stopped/gap email (one at most).
    Returns the reply for renewd: the notices (what the partner was emailed
    since its last check-in) and `needDetails` when the server doesn't know
    the Mac and the check-in didn't say who it's about. Raises SendFailed
    (and stores nothing) if an email couldn't be sent, so renewd's retry
    sends it then.

    The write only lands if the item hasn't changed since it was read (a
    scheduled check may have just emailed about it); otherwise it starts
    over with the new item."""
    for _ in range(attempts):
        result = _record_beat_once(beat, at, store, send)
        if result is not None:
            return result
    raise SendFailed("the check-in kept changing underneath; try again")


def _record_beat_once(beat, at, store, send):
    prev = store.get(beat["install"])
    if beat["state"] == "removed":
        store.delete(beat["install"])
        return {"notices": list(prev.get("notices") or []) if prev else []}
    if not beat["details"] and not prev:
        return {"notices": [], "needDetails": True}

    # Who and what this is about: from the check-in, or as stored.
    ident = {k: beat[k] if beat["details"] else prev[k] for k in ("to", "mac", "user", "timeZone")}
    reported = list(prev.get("reportedGaps") or []) if prev else []
    new_gaps = [g for g in beat["gaps"] if g["id"] not in reported]
    context = dict(beat, **ident, newGaps=new_gaps)

    pending = list(prev.get("notices") or []) if prev else []
    kind = None
    if prev and prev.get("alerted"):
        kind = "back"
    elif prev and prev["state"] == "shutdown" and not _restarted(prev, beat):
        kind = "stopped"
    elif new_gaps:
        kind = "gap"
    if kind:
        about = prev or {"install": beat["install"], "lastSeen": at, **ident}
        report = email_for(kind, about, at, context)
        try:
            send(report)
        except Exception as e:
            raise SendFailed(str(e)) from e
        pending.append(notice(report))

    stored = store.put({
        "install": beat["install"],
        **ident,
        "state": beat["state"],
        "boot": beat["boot"],
        "interval": beat["interval"],
        "lastSeen": at,
        "lastAccepted": beat["lastAccepted"],
        "coveredSince": beat["coveredSince"],
        "alerted": False,
        "notices": [],
        "bootID": beat["bootID"],
        "reportedGaps": (reported + [g["id"] for g in new_gaps])[-MAX_REPORTED_GAPS:],
    }, expect=prev)
    if not stored:
        return None
    return {"notices": pending}


def check_all(at, store, send, silence, cap, stopping=180):
    """Emails about every Mac that went quiet. Returns how many emails were
    sent. An item is marked `alerted` before its email goes out, so two runs
    at once can't both send it; a failed send clears the mark for the next
    run."""
    sent = 0
    for item in store.scan():
        kind = decide(item, at, silence, cap, stopping)
        if not kind or not store.claim(item["install"], item["lastSeen"]):
            continue
        report = email_for(kind, item, at)
        try:
            send(report)
        except Exception:
            store.release(item["install"], item["lastSeen"])
            continue
        store.add_notice(item["install"], notice(report))
        sent += 1
    return sent


# MARK: storage

class DynamoStore:
    """The check-ins table (HEARTBEAT_TABLE)."""

    def __init__(self, table):
        self.table = table

    @staticmethod
    def _plain(item):
        from decimal import Decimal

        def conv(v):
            if isinstance(v, Decimal):
                return int(v)
            if isinstance(v, list):
                return [conv(x) for x in v]
            if isinstance(v, dict):
                return {k: conv(x) for k, x in v.items()}
            return v
        return conv(item)

    def get(self, install):
        item = self.table.get_item(Key={"install": install}, ConsistentRead=True).get("Item")
        return self._plain(item) if item else None

    def put(self, item, expect=None):
        """Writes `item` if the stored one still matches `expect` (its
        lastSeen and alerted), or doesn't exist when `expect` is None.
        Returns whether it was written."""
        from botocore.exceptions import ClientError
        if expect is None:
            cond = {"ConditionExpression": "attribute_not_exists(install)"}
        else:
            alerted = "alerted = :al" if expect.get("alerted") else "(attribute_not_exists(alerted) OR alerted = :al)"
            cond = {"ConditionExpression": f"lastSeen = :ls AND {alerted}",
                    "ExpressionAttributeValues": {":ls": expect["lastSeen"], ":al": bool(expect.get("alerted"))}}
        try:
            self.table.put_item(Item=item, **cond)
            return True
        except ClientError as e:
            if e.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
                return False
            raise

    def delete(self, install):
        self.table.delete_item(Key={"install": install})

    def scan(self):
        items, kwargs = [], {}
        while True:
            page = self.table.scan(**kwargs)
            items += [self._plain(i) for i in page.get("Items", [])]
            if "LastEvaluatedKey" not in page:
                return items
            kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]

    def _conditional(self, **kwargs):
        from botocore.exceptions import ClientError
        try:
            self.table.update_item(**kwargs)
            return True
        except ClientError as e:
            if e.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
                return False
            raise

    def claim(self, install, last_seen):
        """Marks the item alerted, if it isn't already and hasn't checked in since."""
        return self._conditional(
            Key={"install": install},
            UpdateExpression="SET alerted = :t",
            ConditionExpression="lastSeen = :ls AND (attribute_not_exists(alerted) OR alerted = :f)",
            ExpressionAttributeValues={":t": True, ":f": False, ":ls": last_seen})

    def release(self, install, last_seen):
        self._conditional(
            Key={"install": install},
            UpdateExpression="SET alerted = :f",
            ConditionExpression="lastSeen = :ls",
            ExpressionAttributeValues={":f": False, ":ls": last_seen})

    def add_notice(self, install, notice):
        item = self.get(install)
        if not item:
            return
        notices = (item.get("notices") or []) + [notice]
        self._conditional(
            Key={"install": install},
            UpdateExpression="SET notices = :n",
            ConditionExpression="attribute_exists(install)",
            ExpressionAttributeValues={":n": notices[-MAX_NOTICES:]})


_store = None


def store():
    global _store
    if _store is None:
        import boto3  # in the Lambda runtime; imported lazily so tests don't need it
        _store = DynamoStore(boto3.resource("dynamodb").Table(os.environ["HEARTBEAT_TABLE"]))
    return _store
