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

`removed` requests partner approval to end monitoring. A `witness` check-in
reports a guard observation without changing the daemon's last-seen time.
"""

import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone

from render import CHECKIN, MAX_RECIPIENTS, as_list, recipients, when, zone_for

STATES = {"awake", "sleeping", "shutdown", "stopping", "removed", "witness", "monitoringStatus", "requestRemoval"}
GAP_KINDS = {"recordsMissing", "recordUnverified", "heartbeatStalled"}
MAX_TEXT = 300
# Pending notices kept per Mac until it next checks in.
MAX_NOTICES = 20
MAX_GAPS = 50
# Gap ids already queued for delivery, shared between both reporters.
MAX_REPORTED_GAPS = 200
MAX_HISTORY = 100
MAX_PENDING_EMAIL_BYTES = 210 * 1024
MAX_NOTICE_BYTES = 85 * 1024
# Longer than the Lambda timeout, so a timed-out worker's claim can be retried.
EMAIL_LEASE_SECONDS = 60
log = logging.getLogger(__name__)
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


def checkin_grace_seconds():
    return int(float(os.environ.get("CHECKIN_GRACE_MINUTES", "5")) * 60)


def restart_window_seconds():
    return int(float(os.environ.get("RESTART_WINDOW_MINUTES", "60")) * 60)


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
    removing = data.get("removingPartners")
    if removing is not None and (removing := recipients(removing)) is None:
        raise Invalid("removingPartners must contain valid email addresses")
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
        "runID": _uuid(data["runID"], "runID") if data.get("runID") is not None else None,
        "monitoringOnly": data.get("monitoringOnly") is True,
        "explicitPartnerRemovals": data.get("explicitPartnerRemovals") is True,
        "removingPartners": removing,
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
    if kind in ("gap", "unverified", "stall"):
        return [gap_line(g, who, zone) for g in gaps]
    if kind == "restart":
        return [f"Renew on {who} restarted more than once without the Mac rebooting.",
                f"Renew was back online as of {when(_dt(at), zone)}."]
    if kind == "missed":
        return [f"Renew on {who} missed an expected check-in while the Mac was expected to be awake.",
                f"The server heard from Renew again at {when(_dt(at), zone)}, {age} after the previous check-in."]
    if kind == "removal":
        return [f"The report server received a request to change monitoring for Renew on {who}.",
                "While Renew remains installed, it keeps checking in while you decide. You can approve the request or choose to keep monitoring."]
    raise ValueError(kind)


def gap_line(g, who, zone):
    span = f"{when(_dt(g['from']), zone)} to {when(_dt(g['to']), zone)}"
    if g.get("kind") == "recordUnverified":
        return f"Renew's heartbeat record on {who} couldn't be verified ({span})."
    if g.get("kind") == "heartbeatStalled" and g.get("awakeSeconds") is not None:
        return (f"Renew's guard on {who} saw the daemon heartbeat stand still for at least "
                f"{gap(g['awakeSeconds'])} while the Mac was awake ({span}).")
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


def record_beat(beat, at, store, send, attempts=3, approval_origin=None):
    """Commit the evidence and its email together before attempting delivery."""
    install = beat["install"]
    if beat["state"] == "monitoringStatus":
        item = store.get(install) or {}
        monitoring = {"partners": as_list(item["to"]) if item else [], "removalPending": bool(item.get("removal"))}
        if item.get("removal"):
            monitoring["pendingPartners"] = _removing_partners(item)
        if item.get("rejectedRemoval"):
            monitoring["rejectedDecision"] = item["rejectedRemoval"]["id"]
        return {"notices": [], "monitoring": monitoring}
    for _ in range(attempts):
        result = _record_beat_once(beat, at, store, approval_origin)
        if result is not None:
            if result.pop("deliver", False):
                _deliver_email(install, at, store, send)
            if result.pop("takeNotices", False):
                result["notices"] = _take_notices(install, store)
            return result
    raise SendFailed("the check-in kept changing underneath; try again")


def _put(store, item, prev):
    return store.put(dict(item, revision=str(uuid.uuid4())), expect=prev)


def _request_removal(at, origin, removing):
    if origin is None:
        raise SendFailed("no report server origin for the approval link")
    return {"token": str(uuid.uuid4()), "at": at, "origin": origin, "notified": False,
            "removingPartners": sorted(removing)}


def _removing_partners(item):
    request = item["removal"]
    current = as_list(item["to"])
    if "removingPartners" in request:
        return [email for email in current if email in request["removingPartners"]]
    desired = set(request.get("proposedPartners") or [])
    return [email for email in current if email not in desired]


def approve_removal(install, token, store):
    for _ in range(5):
        current = store.get(install) or {}
        if (current.get("removal") or {}).get("token") != token:
            return None
        removing = set(_removing_partners(current))
        remaining = [email for email in as_list(current["to"]) if email not in removing]
        if not remaining:
            if store.approve_removal(install, token, expect=current):
                return "ended"
            continue
        updated = _resolve_removal(current)
        updated["to"] = remaining
        queued = []
        for entry in updated["pendingEmails"]:
            recipients = [email for email in as_list(entry["report"]["to"]) if email in remaining]
            if recipients:
                queued.append(dict(entry, report=dict(entry["report"], to=recipients)))
        updated["pendingEmails"] = queued
        original = as_list(current.get("approvalRecipients") or current["to"])
        updated["approvalRecipients"] = [email for email in original if email in remaining] or remaining
        if _put(store, updated, current):
            return "updated"
    raise SendFailed("the monitoring request kept changing")


def _resolve_removal(item):
    updated = dict(item)
    message_id = _removal_email(item)["id"]
    updated["pendingEmails"] = [entry for entry in item.get("pendingEmails", [])
                                if entry["report"]["id"] != message_id]
    updated.pop("removal")
    return updated


def reject_removal(install, token, store):
    for _ in range(5):
        current = store.get(install) or {}
        request = current.get("removal") or {}
        if request.get("token") != token:
            return False
        updated = _resolve_removal(current)
        updated["rejectedRemoval"] = {"id": str(uuid.uuid4()), "partners": _removing_partners(current)}
        if _put(store, updated, current):
            return True
    raise SendFailed("the monitoring request kept changing")


def _removal_email(item):
    request = item["removal"]
    approvers = item.get("approvalRecipients") or item["to"]
    report = email_for("removal", dict(item, lastSeen=request["at"], to=approvers), request["at"])
    report["id"] = str(uuid.uuid5(uuid.NAMESPACE_URL, f"renew-removal/{item['install']}/{request['token']}"))
    report["approvalURL"] = (f"{request['origin']}/monitoring/approve"
                             f"?install={item['install']}&token={request['token']}")
    return report


def _json_size(data):
    return len(json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def _queue_email(item, report):
    queued = list(item.get("pendingEmails") or [])
    queued.append({"report": dict(report, sentAt=int(report["sentAt"].timestamp()))})
    while _json_size(queued) > MAX_PENDING_EMAIL_BYTES:
        # Preserve any in-flight email and the partner's approval request.
        oldest = next((i for i, entry in enumerate(queued[:-1])
                       if "lease" not in entry and entry["report"]["kind"] != "removal"), None)
        if oldest is None:
            if len(queued[-1]["report"]["changes"]) > 1:
                queued[-1]["report"]["changes"] = [queued[-1]["report"]["changes"][0],
                                                  "This email omits some observations because the delivery queue is full."]
            if _json_size(queued) > MAX_PENDING_EMAIL_BYTES:
                log.warning("check-in email queue full for %s", item["install"])
                queued.pop()
            break
        log.warning("discarding oldest queued check-in email for %s", item["install"])
        queued.pop(oldest)
    item["pendingEmails"] = queued


def _deliver_email(install, at, store, send):
    """Claim queued delivery using the item's revision. Return the kind sent."""
    lease = str(uuid.uuid4())
    for _ in range(5):
        current = store.get(install)
        queued = (current or {}).get("pendingEmails") or []
        if not queued or queued[0].get("leaseUntil", 0) > at:
            return None
        head = dict(queued[0], lease=lease, leaseUntil=at + EMAIL_LEASE_SECONDS)
        if _put(store, dict(current, pendingEmails=[head] + queued[1:]), current):
            break
    else:
        return None

    report = dict(head["report"], sentAt=_dt(head["report"]["sentAt"]))
    try:
        send(report)
        message = notice(report)
    except Exception:
        log.warning("couldn't deliver queued check-in email for %s", install, exc_info=True)
        message = None

    for _ in range(8):
        current = store.get(install)
        queued = (current or {}).get("pendingEmails") or []
        if not queued or queued[0].get("lease") != lease:
            break
        updated = dict(current)
        if message is None:
            updated["pendingEmails"] = [{"report": queued[0]["report"]}] + queued[1:]
        else:
            updated["pendingEmails"] = queued[1:]
            notices = ((current.get("notices") or []) + [message])[-MAX_NOTICES:]
            while len(notices) > 1 and _json_size(notices) > MAX_NOTICE_BYTES:
                notices.pop(0)
            if _json_size(notices) > MAX_NOTICE_BYTES:
                message["lines"] = message["lines"][:1]
            updated["notices"] = notices
            if report["kind"] == "removal" and current.get("removal"):
                updated["removal"] = dict(current["removal"], notified=True)
        if _put(store, updated, current):
            break
    return report["kind"] if message is not None else None


def _take_notices(install, store):
    for _ in range(5):
        current = store.get(install)
        notices = (current or {}).get("notices") or []
        if not notices or _put(store, dict(current, notices=[]), current):
            return notices
    return []


def _new_gaps(beat, prev):
    reported = list((prev or {}).get("reportedGaps") or [])
    new = []
    seen = set(reported)
    for g in beat["gaps"]:
        if g["id"] not in seen:
            new.append(g)
            seen.add(g["id"])
    return new, (reported + [g["id"] for g in new])[-MAX_REPORTED_GAPS:]


def _gap_email_kind(gaps):
    if any(g["kind"] == "recordUnverified" for g in gaps):
        return "unverified"
    if any(g["kind"] == "heartbeatStalled" for g in gaps):
        return "stall"
    return "gap"


def _witness(beat, prev, at, store):
    if not prev:
        return {"notices": [], "needDetails": True}
    new, reported = _new_gaps(beat, prev)
    if not new:
        return {"notices": []}
    updated = dict(prev, reportedGaps=reported)
    _queue_email(updated, email_for(_gap_email_kind(new), prev, at, {"newGaps": new}))
    if _put(store, updated, prev):
        return {"notices": [], "deliver": True}
    return None


def _restart_event(prev, beat, at, history):
    if not prev or not prev.get("runID") or not beat["runID"] or prev["runID"] == beat["runID"]:
        return None
    if _restarted(prev, beat):
        return None
    since = at - restart_window_seconds()
    recent = [entry for entry in history if entry["kind"] == "restart" and entry["at"] >= since
              and not _restarted(entry, beat)]
    return {"kind": "restart", "at": at, "previousRunID": prev["runID"], "runID": beat["runID"],
            "boot": beat["boot"], "bootID": beat["bootID"],
            "alertQueued": bool(recent) and not any(entry.get("alertQueued", entry.get("emailed")) for entry in recent)}


def _missed_checkin(prev, beat, at):
    return (prev and prev["state"] == "awake" and beat["state"] == "awake"
            and not _restarted(prev, beat)
            and at - prev["lastSeen"] > prev["interval"] + checkin_grace_seconds())


def _submit_removal(beat, prev, at, store, origin):
    if not prev:
        return {"notices": []}
    request_ids = prev.get("removalRequestIDs") or []
    request_id = beat["id"] if beat["state"] == "requestRemoval" else None
    if request_id in request_ids:
        return {"notices": []}
    current = set(as_list(prev["to"]))
    requested = beat["removingPartners"]
    removing = current if requested is None else current.intersection(requested)
    if not removing:
        return {"notices": []}
    prior = set(_removing_partners(prev)) if prev.get("removal") else set()
    updated = dict(prev)
    if removing - prior:
        if prior:
            updated = _resolve_removal(prev)
        updated["removal"] = _request_removal(at, origin, removing | prior)
        _queue_email(updated, _removal_email(updated))
    if request_id is not None:
        updated["removalRequestIDs"] = (request_ids + [request_id])[-100:]
    if updated == prev:
        return {"notices": [], "deliver": bool(prev.get("pendingEmails"))}
    if _put(store, updated, prev):
        return {"notices": [], "deliver": bool(updated.get("pendingEmails"))}
    return None


def _record_beat_once(beat, at, store, approval_origin):
    prev = store.get(beat["install"])
    if beat["monitoringOnly"] and not prev:
        return {"notices": []}
    if beat["state"] == "witness":
        return _witness(beat, prev, at, store)
    if beat["state"] in ("removed", "requestRemoval"):
        return _submit_removal(beat, prev, at, store, approval_origin)
    if not beat["details"] and not prev:
        return {"notices": [], "needDetails": True}
    history = list((prev or {}).get("history") or [])
    if (prev and beat["runID"] and beat["runID"] != prev.get("runID") and not _restarted(prev, beat)
            and any(entry.get("previousRunID") == beat["runID"] for entry in history)):
        # A final check-in from the old process may arrive after the new one.
        return {"notices": []}

    rejected = (prev or {}).get("rejectedRemoval")
    # A rejected edit should never turn the next ordinary beat into a new request.
    previous_partners = as_list(prev["to"]) if prev else []
    reported_partners = as_list(beat["to"])
    removed = set(previous_partners) - set(reported_partners) if beat["details"] and not beat["monitoringOnly"] else set()
    rejected_partners = set()
    if rejected:
        rejected_partners = set(rejected["partners"]) if "partners" in rejected else (
            set(previous_partners) - set(rejected.get("proposedPartners") or []))
    removal = (prev or {}).get("removal")
    if removal and "removingPartners" not in removal:
        removal = dict(removal, removingPartners=_removing_partners(prev))
    if removed - rejected_partners and removal is None and not beat["explicitPartnerRemovals"]:
        removal = _request_removal(at, approval_origin, removed - rejected_partners)
    use_details = beat["details"] and not beat["monitoringOnly"]
    ident = {k: (beat if use_details else prev)[k] for k in ("to", "mac", "user", "timeZone")}
    if removed or removal:
        # Existing partners stay enrolled unless a partner approves their removal.
        ident["to"] = list(dict.fromkeys(previous_partners + reported_partners))[:MAX_RECIPIENTS]
    new_gaps, reported = _new_gaps(beat, prev)
    context = dict(beat, **ident, newGaps=new_gaps)

    restart = _restart_event(prev, beat, at, history)
    if restart:
        history.append(restart)
    missed = _missed_checkin(prev, beat, at)
    if missed:
        history.append({"kind": "missed", "at": at, "previousCheckin": prev["lastSeen"]})

    kinds = []
    if prev and prev.get("alerted"):
        kinds.append("back")
    elif prev and prev["state"] == "shutdown" and not _restarted(prev, beat):
        kinds.append("stopped")
    elif new_gaps:
        kinds.append(_gap_email_kind(new_gaps))
    if missed:
        kinds.append("missed")
    if restart and restart["alertQueued"]:
        kinds.append("restart")
    item = {
        "install": beat["install"],
        **ident,
        "state": beat["state"],
        "boot": beat["boot"],
        "interval": beat["interval"],
        "lastSeen": at,
        "lastAccepted": beat["lastAccepted"],
        "coveredSince": beat["coveredSince"],
        "alerted": False,
        "notices": (prev or {}).get("notices") or [],
        "pendingEmails": (prev or {}).get("pendingEmails") or [],
        "bootID": beat["bootID"],
        "runID": beat["runID"],
        "reportedGaps": reported,
        "history": history[-MAX_HISTORY:],
        "approvalRecipients": (prev.get("approvalRecipients") or prev["to"]) if prev else ident["to"],
        "removalRequestIDs": (prev or {}).get("removalRequestIDs") or [],
    }
    if removal:
        item["removal"] = removal
        if not prev.get("removal"):
            _queue_email(item, _removal_email(item))
    if rejected:
        if use_details and not removal:
            rejected = dict(rejected, partners=sorted(rejected_partners - set(reported_partners)))
        item["rejectedRemoval"] = rejected
    if kinds:
        about = prev or {"install": beat["install"], "lastSeen": at, **ident}
        report = email_for(kinds[0], about, at, context)
        for kind in kinds[1:]:
            report["changes"].extend(lines_for(kind, about, at, context))
        _queue_email(item, report)
    if not _put(store, item, prev):
        return None
    return {"notices": [], "deliver": bool(item["pendingEmails"]), "takeNotices": True}


def check_all(at, store, send, silence, cap, stopping=180):
    """Queue silence alerts and retry earlier mail that could not be sent."""
    sent = 0
    for item in store.scan():
        install = item["install"]
        kind = decide(item, at, silence, cap, stopping)
        if kind:
            updated = dict(item, alerted=True)
            _queue_email(updated, email_for(kind, item, at))
            _put(store, updated, item)
        # Give queued removal and silence notifications a chance in the same tick.
        if kind or item.get("pendingEmails"):
            for _ in range(2):
                delivered = _deliver_email(install, at, store, send)
                if delivered is None:
                    break
                if delivered in ("silent", "quiet"):
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
        """Writes `item` if the stored one still matches `expect`, or
        doesn't exist when `expect` is None.
        Returns whether it was written."""
        from botocore.exceptions import ClientError
        if expect is None:
            cond = {"ConditionExpression": "attribute_not_exists(install)"}
        else:
            alerted = "alerted = :al" if expect.get("alerted") else "(attribute_not_exists(alerted) OR alerted = :al)"
            cond = {"ConditionExpression": f"lastSeen = :ls AND {alerted}",
                    "ExpressionAttributeValues": {":ls": expect["lastSeen"], ":al": bool(expect.get("alerted"))}}
            if "revision" in expect:
                cond["ConditionExpression"] += " AND revision = :rev"
                cond["ExpressionAttributeValues"][":rev"] = expect["revision"]
            else:
                cond["ConditionExpression"] += " AND attribute_not_exists(revision)"
        try:
            self.table.put_item(Item=item, **cond)
            return True
        except ClientError as e:
            if e.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
                return False
            raise

    def approve_removal(self, install, token, expect):
        from botocore.exceptions import ClientError
        condition = "removal.#token = :token"
        values = {":token": token}
        if "revision" in expect:
            condition += " AND revision = :rev"
            values[":rev"] = expect["revision"]
        else:
            condition += " AND attribute_not_exists(revision)"
        try:
            self.table.delete_item(
                Key={"install": install},
                ConditionExpression=condition,
                ExpressionAttributeNames={"#token": "token"},
                ExpressionAttributeValues=values,
            )
            return True
        except ClientError as e:
            if e.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
                return False
            raise

    def scan(self):
        items, kwargs = [], {}
        while True:
            page = self.table.scan(**kwargs)
            items += [self._plain(i) for i in page.get("Items", [])]
            if "LastEvaluatedKey" not in page:
                return items
            kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


_store = None


def store():
    global _store
    if _store is None:
        import boto3  # in the Lambda runtime; imported lazily so tests don't need it
        _store = DynamoStore(boto3.resource("dynamodb").Table(os.environ["HEARTBEAT_TABLE"]))
    return _store
