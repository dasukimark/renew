import json
import uuid
from urllib.parse import urlencode

import pytest

import app
import heartbeat
import render
from test_app import TOKEN, FakeSMTP, env, event, smtp  # noqa: F401 (fixtures)

INSTALL = "11111111-2222-3333-4444-555555555555"
BOOT = "2026-11-17T08:00:00Z"
BOOT_EPOCH = 1794902400  # 2026-11-17T08:00:00Z
T0 = 1794931200  # 2026-11-17T16:00:00Z


class FakeStore:
    def __init__(self):
        self.items = {}
        # Runs once just before the next put lands (a racing scheduled check).
        self.before_put = None

    def get(self, install):
        item = self.items.get(install)
        return json.loads(json.dumps(item)) if item else None

    def put(self, item, expect=None):
        current = self.items.get(item["install"])
        if expect is None and current is not None:
            return False
        if expect is not None and (current is None or current["lastSeen"] != expect["lastSeen"]
                                   or current.get("revision") != expect.get("revision")
                                   or bool(current.get("alerted")) != bool(expect.get("alerted"))):
            return False
        if self.before_put:
            hook, self.before_put = self.before_put, None
            hook(self)
            return self.put(item, expect)
        self.items[item["install"]] = dict(item)
        return True

    def approve_removal(self, install, token, expect):
        item = self.items.get(install) or {}
        if item.get("removal", {}).get("token") != token or item.get("revision") != expect.get("revision"):
            return False
        del self.items[install]
        return True

    def scan(self):
        return [json.loads(json.dumps(i)) for i in self.items.values()]

@pytest.fixture
def store(monkeypatch):
    s = FakeStore()
    monkeypatch.setattr(heartbeat, "_store", s)
    return s


@pytest.fixture
def clock(monkeypatch):
    t = {"now": T0}
    monkeypatch.setattr(heartbeat, "now", lambda: t["now"])
    return t


def beat(**overrides):
    body = {
        "kind": "heartbeat",
        "id": str(uuid.uuid4()),
        "install": INSTALL,
        "to": "partner@test.invalid",
        "mac": "Test Mac",
        "user": "tester",
        "timeZone": "UTC",
        "sentAt": "2026-11-17T16:00:00Z",
        "state": "awake",
        "boot": BOOT,
        "interval": 600,
    }
    body.update(overrides)
    return body


def stored(state="awake", last_seen=T0, **extra):
    item = {"install": INSTALL, "to": "partner@test.invalid", "mac": "Test Mac", "user": "tester",
            "timeZone": "UTC", "state": state, "boot": BOOT_EPOCH, "interval": 600, "lastSeen": last_seen,
            "lastAccepted": None, "alerted": False, "notices": []}
    item.update(extra)
    return item


def sent(smtp, invites=False):
    """Emails sent, without partner confirmation emails unless `invites`."""
    return [m for i in smtp.instances for m in i.sent
            if invites or not m["Subject"].startswith("Confirm you're")]


def invites(smtp):
    return [m for m in sent(smtp, invites=True) if m["Subject"].startswith("Confirm you're")]


def confirm_all(store):
    """Every enrolled partner confirmed, as if they'd clicked their links."""
    item = store.items[INSTALL]
    item["confirmedPartners"] = heartbeat.as_list(item["to"])


# MARK: decide

SILENCE, CAP = 1800, 72 * 3600


@pytest.mark.parametrize("state,age,expected", [
    ("awake", 60, None),
    ("awake", 1800, None),
    ("awake", 1801, "silent"),
    ("stopping", 1801, "silent"),
    ("sleeping", 1801, None),
    ("shutdown", 2 * 86400, None),
    ("sleeping", CAP + 1, "quiet"),
    ("shutdown", CAP + 1, "quiet"),
])
def test_decide(state, age, expected):
    assert heartbeat.decide(stored(state, last_seen=T0), T0 + age, SILENCE, CAP) == expected


def test_decide_skips_alerted():
    assert heartbeat.decide(stored(last_seen=T0, alerted=True), T0 + 99999, SILENCE, CAP) is None


def test_decide_waits_for_long_intervals():
    item = stored(last_seen=T0, interval=3600)
    assert heartbeat.decide(item, T0 + 2000, SILENCE, CAP) is None
    assert heartbeat.decide(item, T0 + 9001, SILENCE, CAP) == "silent"


# MARK: check-ins through the handler

def test_beat_is_recorded(smtp, store, clock):
    r = app.handler(event(beat()), None)
    assert r["statusCode"] == 200
    reply = json.loads(r["body"])
    assert [n["title"] for n in reply["notices"]] == ["Confirm you're a partner"]
    assert reply["partners"] == {"unconfirmed": ["partner@test.invalid"]}
    item = store.items[INSTALL]
    assert item["state"] == "awake" and item["lastSeen"] == T0 and item["boot"] == BOOT_EPOCH
    assert not sent(smtp) and len(invites(smtp)) == 1


@pytest.mark.parametrize("token", [None, "wrong"])
def test_beat_needs_token(smtp, store, clock, token):
    assert app.handler(event(beat(), token=token), None)["statusCode"] == 401
    assert not store.items


@pytest.mark.parametrize("body", [
    beat(state="dancing"),
    beat(install="nope"),
    beat(to="nobody"),
    beat(boot="yesterday"),
    beat(interval=5),
])
def test_bad_beat(smtp, store, clock, body):
    assert app.handler(event(body), None)["statusCode"] == 400
    assert not store.items


def test_beat_allowed_recipients(smtp, store, clock, monkeypatch):
    monkeypatch.setenv("ALLOWED_RECIPIENTS", "someone@test.invalid")
    assert app.handler(event(beat()), None)["statusCode"] == 403
    assert not store.items


def test_removed_requires_explicit_partner_approval(smtp, store, clock):
    store.items[INSTALL] = (stored())
    assert app.handler(event(beat(state="removed", to="stranger@test.invalid")), None)["statusCode"] == 200
    assert app.handler(event(beat(state="removed")), None)["statusCode"] == 200
    assert store.items[INSTALL]["lastSeen"] == T0
    message, = sent(smtp)
    assert message["To"] == "partner@test.invalid"
    token = store.items[INSTALL]["removal"]["token"]
    query = urlencode({"install": INSTALL, "token": token})
    assert f"https://reports.test.invalid/monitoring/approve?{query}" in message.get_body(("plain",)).get_content()
    get = dict(event("", method="GET", token=None), rawPath="/monitoring/approve", rawQueryString=query)
    assert app.handler(get, None)["statusCode"] == 200
    assert INSTALL in store.items

    post = dict(event(urlencode({"install": INSTALL, "token": str(uuid.uuid4()), "decision": "approve"})),
                rawPath="/monitoring/approve")
    assert app.handler(post, None)["statusCode"] == 404
    assert INSTALL in store.items
    post = dict(event(query, token=None), rawPath="/monitoring/approve")
    assert app.handler(post, None)["statusCode"] == 400
    assert INSTALL in store.items
    post = dict(event(query + "&decision=approve", token=None), rawPath="/monitoring/approve")
    assert app.handler(post, None)["statusCode"] == 200
    assert INSTALL not in store.items
    assert app.handler(post, None)["statusCode"] == 404


def test_only_original_partners_receive_approval_link(smtp, store, clock):
    app.handler(event(beat()), None)
    confirm_all(store)
    app.handler(event(beat(to=["partner@test.invalid", "new@test.invalid"])), None)
    app.handler(event(beat(to="new@test.invalid")), None)
    assert store.items[INSTALL]["to"] == ["partner@test.invalid", "new@test.invalid"]
    assert sent(smtp)[0]["To"] == "partner@test.invalid"


def test_monitoring_status_tracks_pending_approval_without_checking_in(smtp, store, clock):
    app.handler(event(beat()), None)
    confirm_all(store)
    app.handler(event(slim(state="removed")), None)
    token = store.items[INSTALL]["removal"]["token"]
    before = store.get(INSTALL)
    clock["now"] += 600
    lookup = event(slim(state="monitoringStatus"))
    assert app.handler(event(slim(state="monitoringStatus"), token=None), None)["statusCode"] == 401
    reply = app.handler(lookup, None)
    assert json.loads(reply["body"])["monitoring"] == {
        "partners": ["partner@test.invalid"], "removalPending": True, "pendingPartners": ["partner@test.invalid"],
    }
    assert store.get(INSTALL) == before
    approve = dict(event(urlencode({"install": INSTALL, "token": token, "decision": "approve"}), token=None),
                   rawPath="/monitoring/approve")
    assert app.handler(approve, None)["statusCode"] == 200
    reply = app.handler(lookup, None)
    assert json.loads(reply["body"])["monitoring"] == {"partners": [], "removalPending": False}
    assert INSTALL not in store.items
    assert len(sent(smtp)) == 1


def test_monitoring_only_beats_keep_pending_enrollment_alive_and_cannot_recreate_it(smtp, store, clock):
    app.handler(event(beat()), None)
    confirm_all(store)
    app.handler(event(slim(state="removed")), None)
    token = store.items[INSTALL]["removal"]["token"]
    for _ in range(13):
        clock["now"] += 600
        assert app.handler(event(slim(monitoringOnly=True)), None)["statusCode"] == 200
    assert store.items[INSTALL]["lastSeen"] == clock["now"]
    assert app.handler(SCHEDULED, None) == {"alerted": 0}
    assert len(sent(smtp)) == 1
    payload = urlencode({"install": INSTALL, "token": token, "decision": "approve"})
    assert app.handler(dict(event(payload, token=None), rawPath="/monitoring/approve"), None)["statusCode"] == 200
    assert app.handler(event(beat(monitoringOnly=True)), None)["statusCode"] == 200
    assert INSTALL not in store.items


def test_partner_can_reject_and_monitoring_survives_without_reopening_request(smtp, store, clock):
    app.handler(event(beat(to=["partner@test.invalid", "other@test.invalid"])), None)
    confirm_all(store)
    app.handler(event(beat(to="other@test.invalid")), None)
    token = store.items[INSTALL]["removal"]["token"]
    query = urlencode({"install": INSTALL, "token": token})
    page = app.handler(dict(event("", method="GET", token=None), rawPath="/monitoring/approve", rawQueryString=query), None)
    assert "Keep monitoring" in page["body"] and "Approve partner removal" in page["body"]
    assert "removal" in store.items[INSTALL]
    post = dict(event(query + "&decision=reject", token=None), rawPath="/monitoring/approve")
    assert app.handler(post, None)["statusCode"] == 200
    assert app.handler(post, None)["statusCode"] == 404
    app.handler(event(beat(to=["other@test.invalid", "added@test.invalid"])), None)
    clock["now"] += 600
    app.handler(event(slim(monitoringOnly=True)), None)
    reply = app.handler(event(slim(state="monitoringStatus")), None)
    monitoring = json.loads(reply["body"])["monitoring"]
    assert monitoring["partners"] == ["partner@test.invalid", "other@test.invalid", "added@test.invalid"]
    assert monitoring["removalPending"] is False and monitoring["rejectedDecision"]
    assert store.items[INSTALL]["lastSeen"] == clock["now"]
    # The one request went to both original partners, one email each.
    assert "removal" not in store.items[INSTALL] and len(sent(smtp)) == 2


def test_partial_approval_preserves_remaining_partners_without_another_checkin(smtp, store, clock):
    removed = "partner@test.invalid"
    remaining = "other@test.invalid"
    app.handler(event(beat(to=[removed, remaining])), None)
    confirm_all(store)
    request = slim(state="requestRemoval", removingPartners=[removed])
    assert app.handler(event(request), None)["statusCode"] == 200
    token = store.items[INSTALL]["removal"]["token"]
    form = urlencode({"install": INSTALL, "token": token, "decision": "approve"})
    reply = app.handler(dict(event(form, token=None), rawPath="/monitoring/approve"), None)
    assert reply["statusCode"] == 200
    assert "Partner removal approved" in reply["body"]
    assert store.items[INSTALL]["to"] == [remaining]
    assert store.items[INSTALL]["lastSeen"] == T0
    clock["now"] += 7201
    assert app.handler(SCHEDULED, None) == {"alerted": 1}
    assert sent(smtp)[-1]["To"] == remaining


def test_partial_approval_retargets_a_queued_silence_email(smtp, store, clock):
    removed = "partner@test.invalid"
    remaining = "other@test.invalid"
    app.handler(event(beat(to=[removed, remaining])), None)
    confirm_all(store)
    app.handler(event(slim(state="requestRemoval", removingPartners=[removed])), None)
    token = store.items[INSTALL]["removal"]["token"]
    smtp.fail_send = True
    clock["now"] += 7201
    assert app.handler(SCHEDULED, None) == {"alerted": 0}
    form = urlencode({"install": INSTALL, "token": token, "decision": "approve"})
    assert app.handler(dict(event(form, token=None), rawPath="/monitoring/approve"), None)["statusCode"] == 200
    smtp.fail_send = False
    assert app.handler(SCHEDULED, None) == {"alerted": 1}
    assert sent(smtp)[-1]["To"] == remaining


def test_rejection_deduplicates_retries_and_allows_a_fresh_request(smtp, store, clock):
    removed = "partner@test.invalid"
    app.handler(event(beat(to=[removed, "other@test.invalid"])), None)
    confirm_all(store)
    request = slim(state="requestRemoval", removingPartners=[removed])
    assert app.handler(event(request), None)["statusCode"] == 200
    assert app.handler(event(request), None)["statusCode"] == 200
    token = store.items[INSTALL]["removal"]["token"]
    form = urlencode({"install": INSTALL, "token": token, "decision": "reject"})
    assert app.handler(dict(event(form, token=None), rawPath="/monitoring/approve"), None)["statusCode"] == 200
    assert app.handler(event(request), None)["statusCode"] == 200
    assert "removal" not in store.items[INSTALL]
    assert len(sent(smtp)) == 2  # one request, to both partners
    new_request = dict(request, id=str(uuid.uuid4()))
    assert app.handler(event(new_request), None)["statusCode"] == 200
    assert len(sent(smtp)) == 4
    assert store.items[INSTALL]["removal"]["token"] != token


def test_explicit_removal_can_be_delivered_after_the_new_partner_list(smtp, store, clock):
    app.handler(event(beat(to=["partner@test.invalid", "other@test.invalid"])), None)
    confirm_all(store)
    app.handler(event(beat(to="other@test.invalid", explicitPartnerRemovals=True)), None)
    assert "removal" not in store.items[INSTALL]
    assert len(store.items[INSTALL]["to"]) == 2
    assert not sent(smtp)
    assert app.handler(event(slim(state="requestRemoval", removingPartners=["partner@test.invalid"])), None)["statusCode"] == 200
    assert store.items[INSTALL]["removal"]["removingPartners"] == ["partner@test.invalid"]


def test_removal_email_uses_branded_origin_when_configured(smtp, store, clock, monkeypatch):
    monkeypatch.setenv("APPROVAL_BASE_URL", "https://reports.renew.test/")
    app.handler(event(beat()), None)
    confirm_all(store)
    app.handler(event(slim(state="removed")), None)
    message, = sent(smtp)
    assert "https://reports.renew.test/monitoring/approve?" in message.get_body(("html",)).get_content()
    assert "Review in Renew" in message.get_body(("html",)).get_content()


def test_pending_removal_retries_email_and_preserves_silence_alerts(smtp, store, clock):
    app.handler(event(beat()), None)
    confirm_all(store)
    smtp.fail_send = True
    assert app.handler(event(slim(state="removed")), None)["statusCode"] == 200
    assert store.items[INSTALL]["removal"]["notified"] is False
    smtp.fail_send = False
    clock["now"] += 7201
    assert app.handler(SCHEDULED, None) == {"alerted": 1}
    assert store.items[INSTALL]["removal"]["notified"] is True
    assert len(sent(smtp)) == 2


def test_back_after_silent(smtp, store, clock):
    store.items[INSTALL] = (stored(last_seen=T0 - 7200, alerted=True,
                     notices=[{"title": "Renew stopped checking in", "lines": ["x"], "at": "2026-11-17T15:00:00Z"}]))
    r = app.handler(event(beat()), None)
    assert r["statusCode"] == 200
    msgs = sent(smtp)
    assert len(msgs) == 1
    assert msgs[0]["Subject"] == "Renew on Test Mac is checking in again"
    assert "didn't restart" in msgs[0].get_body(("plain",)).get_content()
    notices = json.loads(r["body"])["notices"]
    assert [n["title"] for n in notices] == ["Renew stopped checking in", "Checking in again"]
    assert store.items[INSTALL]["alerted"] is False
    assert store.items[INSTALL]["notices"] == []


def test_back_after_restart(smtp, store, clock):
    store.items[INSTALL] = (stored(last_seen=T0 - 7200, alerted=True))
    app.handler(event(beat(boot="2026-11-17T15:55:00Z")), None)
    assert "The Mac restarted" in sent(smtp)[0].get_body(("plain",)).get_content()


def test_shutdown_without_restart_is_stopped(smtp, store, clock):
    store.items[INSTALL] = (stored("shutdown", last_seen=T0 - 600))
    r = app.handler(event(beat()), None)
    assert r["statusCode"] == 200
    msgs = sent(smtp)
    assert len(msgs) == 1 and msgs[0]["Subject"] == "Renew on Test Mac was stopped"
    assert "10 minutes" in msgs[0].get_body(("plain",)).get_content()


def test_real_shutdown_is_quiet(smtp, store, clock):
    store.items[INSTALL] = (stored("shutdown", last_seen=T0 - 36000))
    assert app.handler(event(beat(boot="2026-11-17T15:58:00Z")), None)["statusCode"] == 200
    assert not sent(smtp)


def test_sleep_and_wake_is_quiet(smtp, store, clock):
    store.items[INSTALL] = (stored("sleeping", last_seen=T0 - 36000))
    assert app.handler(event(beat()), None)["statusCode"] == 200
    assert not sent(smtp)


def test_failed_back_email_is_retried_after_recording_the_checkin(smtp, store, clock):
    store.items[INSTALL] = (stored(last_seen=T0 - 7200, alerted=True))
    smtp.fail_send = True
    assert app.handler(event(beat()), None)["statusCode"] == 200
    assert store.items[INSTALL]["alerted"] is False
    assert store.items[INSTALL]["lastSeen"] == T0
    assert store.items[INSTALL]["pendingEmails"][0]["report"]["kind"] == "back"
    smtp.fail_send = False
    app.handler(SCHEDULED, None)
    assert len(sent(smtp)) == 1
    assert store.items[INSTALL]["pendingEmails"] == []


# MARK: the scheduled check

SCHEDULED = {"source": "aws.events", "detail-type": "Scheduled Event", "detail": {}}


def test_scheduled_check_emails_silent_mac(smtp, store, clock):
    store.items[INSTALL] = (stored(last_seen=T0 - 3 * 3600))
    assert app.handler(SCHEDULED, None) == {"alerted": 1}
    msgs = sent(smtp)
    assert len(msgs) == 1 and msgs[0]["Subject"] == "Renew on Test Mac stopped checking in"
    assert msgs[0]["To"] == "partner@test.invalid"
    item = store.items[INSTALL]
    assert item["alerted"] is True and len(item["notices"]) == 1
    # Once is enough.
    assert app.handler(SCHEDULED, None) == {"alerted": 0}
    assert len(sent(smtp)) == 1


def test_scheduled_check_leaves_recent_and_sleeping(smtp, store, clock):
    store.items[INSTALL] = (stored(last_seen=T0 - 600))
    store.items["22222222-2222-3333-4444-555555555555"] = stored("sleeping", last_seen=T0 - 86400, install="22222222-2222-3333-4444-555555555555")
    assert app.handler(SCHEDULED, None) == {"alerted": 0}
    assert not sent(smtp)


def test_scheduled_check_quiet_too_long(smtp, store, clock):
    store.items[INSTALL] = (stored("sleeping", last_seen=T0 - 6 * 86400))
    assert app.handler(SCHEDULED, None) == {"alerted": 0}
    store.items[INSTALL] = (stored("sleeping", last_seen=T0 - 8 * 86400))
    assert app.handler(SCHEDULED, None) == {"alerted": 1}
    assert sent(smtp)[0]["Subject"] == "Renew on Test Mac has been away for a while"


def test_scheduled_check_retries_failed_send(smtp, store, clock):
    store.items[INSTALL] = (stored(last_seen=T0 - 3 * 3600))
    smtp.fail_send = True
    assert app.handler(SCHEDULED, None) == {"alerted": 0}
    assert store.items[INSTALL]["pendingEmails"][0]["report"]["kind"] == "silent"
    smtp.fail_send = False
    assert app.handler(SCHEDULED, None) == {"alerted": 1}


def test_scheduled_check_respects_allowed_recipients(smtp, store, clock, monkeypatch):
    monkeypatch.setenv("ALLOWED_RECIPIENTS", "someone@test.invalid")
    store.items[INSTALL] = (stored(last_seen=T0 - 3600))
    assert app.handler(SCHEDULED, None) == {"alerted": 0}
    assert not sent(smtp)


def test_same_email_same_message_id():
    item = stored(last_seen=T0)
    a = heartbeat.email_for("silent", item, T0 + 3600)
    b = heartbeat.email_for("silent", item, T0 + 3900)
    assert a["id"] == b["id"]
    assert heartbeat.email_for("silent", stored(last_seen=T0 + 1), T0 + 3600)["id"] != a["id"]


def test_gap_wording():
    assert heartbeat.gap(30) == "under a minute"
    assert heartbeat.gap(35 * 60) == "35 minutes"
    assert heartbeat.gap(3600 + 600) == "1 hour 10 minutes"
    assert heartbeat.gap(2 * 86400 + 4 * 3600) == "2 days 4 hours"


# MARK: limits, slim check-ins and downtime gaps

def test_default_limits(monkeypatch):
    for name in ("SILENCE_MINUTES", "STOPPING_MINUTES", "QUIET_CAP_HOURS"):
        monkeypatch.delenv(name, raising=False)
    assert heartbeat.silence_seconds() == 7200
    assert heartbeat.stopping_seconds() == 180
    assert heartbeat.cap_seconds() == 7 * 86400


@pytest.mark.parametrize("state,age,expected", [
    ("awake", 599, None),
    ("awake", 601, "silent"),
    ("stopping", 179, None),
    ("stopping", 181, "silent"),
    ("sleeping", 6 * 86400, None),
    ("shutdown", 7 * 86400 + 1, "quiet"),
])
def test_decide_new_defaults(state, age, expected):
    item = stored(state, last_seen=T0, interval=240)
    assert heartbeat.decide(item, T0 + age, 600, 7 * 86400, 180) == expected


def slim(**overrides):
    body = beat(**overrides)
    for k in ("to", "mac", "user", "timeZone"):
        body.pop(k)
    return body


def test_slim_beat_from_unknown_mac_asks_for_details(smtp, store, clock):
    r = app.handler(event(slim()), None)
    assert r["statusCode"] == 200
    assert json.loads(r["body"]) == {"notices": [], "needDetails": True}
    assert not store.items


def test_slim_beat_keeps_stored_details(smtp, store, clock):
    app.handler(event(beat()), None)
    clock["now"] += 240
    assert app.handler(event(slim()), None)["statusCode"] == 200
    item = store.items[INSTALL]
    assert item["to"] == ["partner@test.invalid"] and item["mac"] == "Test Mac" and item["lastSeen"] == T0 + 240


def test_several_partners_get_checkin_emails(smtp, store, clock):
    app.handler(event(beat(to=["Partner@Test.Invalid", "other@test.invalid"])), None)
    assert store.items[INSTALL]["to"] == ["partner@test.invalid", "other@test.invalid"]
    store.items[INSTALL]["lastSeen"] = T0 - 3 * 3600
    assert app.handler(SCHEDULED, None) == {"alerted": 1}
    # One email each, so a bad address can't hurt the others' delivery.
    assert [m["To"] for m in sent(smtp)] == ["partner@test.invalid", "other@test.invalid"]


def test_several_partners_all_need_allowing(smtp, store, clock, monkeypatch):
    monkeypatch.setenv("ALLOWED_RECIPIENTS", "partner@test.invalid")
    r = app.handler(event(beat(to=["partner@test.invalid", "stranger@test.invalid"])), None)
    assert r["statusCode"] == 403


def test_slim_beat_still_checks_allowed_recipients(smtp, store, clock, monkeypatch):
    store.items[INSTALL] = (stored(last_seen=T0 - 3600, alerted=True))
    monkeypatch.setenv("ALLOWED_RECIPIENTS", "someone@test.invalid")
    assert app.handler(event(slim()), None)["statusCode"] == 200
    assert not sent(smtp)


def gap_body(awake=240, restarted=False, gid=None):
    return {"id": gid or str(uuid.uuid4()), "from": "2026-11-17T15:50:00Z", "to": "2026-11-17T15:54:00Z",
            "awakeSeconds": None if restarted else awake, "restarted": restarted}


def test_gap_is_emailed_once(smtp, store, clock):
    store.items[INSTALL] = (stored(last_seen=T0 - 240))
    g = gap_body()
    r = app.handler(event(slim(gaps=[g])), None)
    assert r["statusCode"] == 200
    msgs = sent(smtp)
    assert len(msgs) == 1 and msgs[0]["Subject"] == "Renew on Test Mac wasn't running for a while"
    text = msgs[0].get_body(("plain",)).get_content()
    assert "for 4 minutes while the Mac was awake" in text
    assert [n["title"] for n in json.loads(r["body"])["notices"]] == ["Renew wasn't running"]
    # The same gap again (renewd didn't hear back): no second email.
    clock["now"] += 60
    app.handler(event(slim(gaps=[g])), None)
    assert len(sent(smtp)) == 1


def test_restarted_gap_wording(smtp, store, clock):
    store.items[INSTALL] = (stored(last_seen=T0 - 240))
    app.handler(event(slim(gaps=[gap_body(restarted=True)])), None)
    assert "the Mac restarted before it ran again" in sent(smtp)[0].get_body(("plain",)).get_content()


def test_restarted_gap_with_awake_time_from_the_power_log(smtp, store, clock):
    store.items[INSTALL] = (stored(last_seen=T0 - 240))
    g = dict(gap_body(), awakeSeconds=900, restarted=True)
    app.handler(event(slim(gaps=[g])), None)
    text = sent(smtp)[0].get_body(("plain",)).get_content()
    assert "for 15 minutes while the Mac was awake, and the Mac restarted before it ran again" in text


def test_records_missing_gap_wording(smtp, store, clock):
    store.items[INSTALL] = (stored(last_seen=T0 - 240))
    g = dict(gap_body(restarted=True), kind="recordsMissing")
    app.handler(event(slim(gaps=[g])), None)
    text = sent(smtp)[0].get_body(("plain",)).get_content()
    assert "records were deleted or replaced" in text


def test_unknown_gap_kind_is_an_ordinary_gap(smtp, store, clock):
    store.items[INSTALL] = (stored(last_seen=T0 - 240))
    app.handler(event(slim(gaps=[dict(gap_body(), kind="fromTheFuture")])), None)
    assert "for 4 minutes while the Mac was awake" in sent(smtp)[0].get_body(("plain",)).get_content()


def test_gap_on_first_beat(smtp, store, clock):
    assert app.handler(event(beat(gaps=[gap_body()])), None)["statusCode"] == 200
    assert len(sent(smtp)) == 1
    assert sent(smtp)[0]["To"] == "partner@test.invalid"


def test_back_lists_gaps(smtp, store, clock):
    store.items[INSTALL] = (stored(last_seen=T0 - 3600, alerted=True))
    app.handler(event(slim(gaps=[gap_body(awake=3500)])), None)
    msgs = sent(smtp)
    assert len(msgs) == 1 and msgs[0]["Subject"] == "Renew on Test Mac is checking in again"
    assert "58 minutes while the Mac was awake" in msgs[0].get_body(("plain",)).get_content()


def test_back_false_alarm_when_running_the_whole_time(smtp, store, clock):
    store.items[INSTALL] = (stored(last_seen=T0 - 3600, alerted=True))
    app.handler(event(slim(coveredSince="2026-11-17T09:00:00Z")), None)
    assert "False alarm" in sent(smtp)[0].get_body(("plain",)).get_content()


def test_back_not_false_alarm_when_coverage_started_later(smtp, store, clock):
    store.items[INSTALL] = (stored(last_seen=T0 - 3600, alerted=True))
    app.handler(event(slim(coveredSince="2026-11-17T15:59:00Z")), None)
    assert "False alarm" not in sent(smtp)[0].get_body(("plain",)).get_content()


@pytest.mark.parametrize("bad", [
    {"gaps": "nope"},
    {"gaps": [{"id": "x", "from": "2026-11-17T15:50:00Z", "to": "2026-11-17T15:54:00Z"}]},
    {"gaps": [dict(gap_body(), awakeSeconds=-1)]},
    {"coveredSince": "yesterday"},
])
def test_bad_gap_fields(smtp, store, clock, bad):
    assert app.handler(event(beat(**bad)), None)["statusCode"] == 400


# MARK: review fixes

def test_beat_racing_a_scheduled_alert_still_sends_back(smtp, store, clock):
    """A scheduled check claims and emails the Mac between record_beat's
    read and write: the write must not wipe that, and 'back' must go out."""
    store.items[INSTALL] = stored(last_seen=T0 - 1600)

    def race(s):
        clock_at = T0
        assert heartbeat.check_all(clock_at, s, lambda r: FakeSMTP("h", 1).send_message(r), 600, CAP, 180) == 1
    store.before_put = race
    r = app.handler(event(slim()), None)
    assert r["statusCode"] == 200
    titles = [n["title"] for n in json.loads(r["body"])["notices"]]
    assert titles == ["Renew stopped checking in", "Checking in again"]
    assert store.items[INSTALL]["alerted"] is False


def test_boot_id_beats_clock_changes(smtp, store, clock):
    # Same boot session, but the boot time moved (the clock was set): still stopped.
    store.items[INSTALL] = stored("shutdown", last_seen=T0 - 600, bootID="boot-a")
    app.handler(event(beat(boot="2026-11-17T09:00:00Z", bootID="boot-a")), None)
    assert sent(smtp)[0]["Subject"] == "Renew on Test Mac was stopped"


def test_new_boot_id_is_a_restart(smtp, store, clock):
    store.items[INSTALL] = stored("shutdown", last_seen=T0 - 600, bootID="boot-a")
    app.handler(event(beat(bootID="boot-b")), None)
    assert not sent(smtp)


def test_stopped_email_lists_gaps(smtp, store, clock):
    store.items[INSTALL] = stored("shutdown", last_seen=T0 - 600)
    app.handler(event(slim(gaps=[gap_body(awake=300)])), None)
    text = sent(smtp)[0].get_body(("plain",)).get_content()
    assert "was stopped for" in text and "5 minutes while the Mac was awake" in text


def test_silent_email_names_the_macs_own_interval(smtp, store, clock):
    store.items[INSTALL] = stored(last_seen=T0 - 3 * 3600, interval=900)
    app.handler(SCHEDULED, None)
    assert "checks in about every 15 minutes" in sent(smtp)[0].get_body(("plain",)).get_content()


def test_first_same_boot_restart_is_logged_second_is_emailed(smtp, store, clock):
    first, second, third = (str(uuid.uuid4()) for _ in range(3))
    app.handler(event(beat(bootID="boot-a")), None)  # Older senders have no run ID.
    app.handler(event(slim(bootID="boot-a", runID=first)), None)
    assert store.items[INSTALL]["history"] == []
    clock["now"] += 60
    app.handler(event(slim(bootID="boot-a", runID=second)), None)
    assert not sent(smtp)
    assert store.items[INSTALL]["history"][0] == {
        "kind": "restart", "at": T0 + 60, "previousRunID": first, "runID": second,
        "boot": BOOT_EPOCH, "bootID": "boot-a", "alertQueued": False,
    }
    app.handler(event(slim(state="stopping", bootID="boot-a", runID=first)), None)
    assert store.items[INSTALL]["state"] == "awake"
    clock["now"] += 60
    app.handler(event(slim(bootID="boot-a", runID=third)), None)
    message, = sent(smtp)
    assert message["Subject"] == "Renew restarted more than once on Test Mac"
    assert "back online" in message.get_body(("plain",)).get_content()
    app.handler(event(slim(bootID="boot-b", runID=str(uuid.uuid4()))), None)
    assert len(store.items[INSTALL]["history"]) == 2
    app.handler(event(slim(bootID="boot-b", runID=str(uuid.uuid4()))), None)
    assert store.items[INSTALL]["history"][-1]["alertQueued"] is False
    assert len(sent(smtp)) == 1
    clock["now"] += 1
    app.handler(event(slim(bootID="boot-b", runID=str(uuid.uuid4()))), None)
    assert store.items[INSTALL]["history"][-1]["alertQueued"] is True
    assert len(sent(smtp)) == 2


def test_missed_checkin_is_reported_on_return_before_silence_alarm(smtp, store, clock):
    run = str(uuid.uuid4())
    app.handler(event(beat(bootID="boot-a", runID=run)), None)
    clock["now"] += 901
    assert app.handler(SCHEDULED, None) == {"alerted": 0}
    app.handler(event(slim(bootID="boot-a", runID=run)), None)
    message, = sent(smtp)
    assert message["Subject"] == "Renew on Test Mac missed a check-in"
    assert store.items[INSTALL]["history"][-1] == {"kind": "missed", "at": T0 + 901, "previousCheckin": T0}
    app.handler(event(slim(bootID="boot-a", runID=run)), None)
    assert len(sent(smtp)) == 1


def test_smtp_outage_still_records_late_and_subsequent_checkins(smtp, store, clock):
    app.handler(event(beat()), None)
    smtp.fail_send = True
    clock["now"] += 901
    first_recovery = clock["now"]
    assert app.handler(event(slim()), None)["statusCode"] == 200
    assert store.items[INSTALL]["lastSeen"] == first_recovery
    clock["now"] += 600
    assert app.handler(event(slim()), None)["statusCode"] == 200
    item = store.items[INSTALL]
    assert item["lastSeen"] == clock["now"]
    assert [e["kind"] for e in item["history"]] == ["missed"]
    assert [e["report"]["kind"] for e in item["pendingEmails"]] == ["missed"]
    smtp.fail_send = False
    assert app.handler(SCHEDULED, None) == {"alerted": 0}
    assert len(sent(smtp)) == 1
    assert store.items[INSTALL]["pendingEmails"] == []


def test_witness_reports_without_updating_daemon_last_seen(smtp, store, clock):
    app.handler(event(beat()), None)
    clock["now"] += 300
    gap = dict(gap_body(), kind="heartbeatStalled")
    assert app.handler(event(slim(state="witness", gaps=[gap])), None)["statusCode"] == 200
    item = store.items[INSTALL]
    assert item["lastSeen"] == T0 and item["state"] == "awake"
    app.handler(event(slim(gaps=[dict(gap, kind=None)])), None)
    message, = sent(smtp)
    assert "heartbeat stood still for at least" in message.get_body(("plain",)).get_content()
    assert store.items[INSTALL]["lastSeen"] == T0 + 300


def test_racing_witness_and_daemon_only_email_the_gap_once(store):
    store.items[INSTALL] = stored(last_seen=T0 - 120, alerted=True)
    gap = gap_body()
    witness = heartbeat.parse_heartbeat(json.dumps(slim(state="witness", gaps=[gap])))
    awake = heartbeat.parse_heartbeat(json.dumps(slim(gaps=[gap])))
    messages = []

    def send(report):
        messages.append(report)
        # A scheduled retry while SMTP is in progress must respect the claim.
        heartbeat.check_all(T0, store, messages.append, SILENCE, CAP)

    store.before_put = lambda s: heartbeat.record_beat(witness, T0, s, send)
    heartbeat.record_beat(awake, T0, store, send)
    assert [m["kind"] for m in messages] == ["gap", "back"]
    assert sum("Renew wasn't running for" in line for m in messages for line in m["changes"]) == 1
    assert store.items[INSTALL]["pendingEmails"] == []


def test_record_authentication_email_describes_evidence(smtp, store, clock):
    app.handler(event(beat(gaps=[dict(gap_body(), kind="recordUnverified")])), None)
    message, = sent(smtp)
    assert message["Subject"] == "Renew's heartbeat record on Test Mac couldn't be verified"
    assert "couldn't be verified" in message.get_body(("plain",)).get_content()


# MARK: partner confirmation

def confirm_link(message):
    text = message.get_body(("plain",)).get_content()
    url = next(line for line in text.splitlines() if "/partners/confirm?" in line).split(": ", 1)[1]
    return url.split("?", 1)[1]


def confirmation(query, decision=None):
    if decision is None:
        return app.handler(dict(event("", method="GET", token=None), rawPath="/partners/confirm",
                                rawQueryString=query), None)
    return app.handler(dict(event(f"{query}&decision={decision}", token=None), rawPath="/partners/confirm"), None)


def status():
    return json.loads(app.handler(event(slim(state="monitoringStatus")), None)["body"])["monitoring"]


def test_new_partner_confirms_by_email(smtp, store, clock):
    app.handler(event(beat()), None)
    invite, = invites(smtp)
    assert invite["To"] == "partner@test.invalid"
    query = confirm_link(invite)
    assert "https://reports.test.invalid/partners/confirm?" in invite.get_body(("plain",)).get_content()
    page = confirmation(query)
    assert page["statusCode"] == 200 and "Confirm" in page["body"] and "Decline" in page["body"]
    # Opening the link (or a mail scanner following it) decides nothing.
    assert status()["unconfirmed"] == ["partner@test.invalid"]
    assert confirmation(query, "confirm")["statusCode"] == 200
    assert "unconfirmed" not in status()
    assert "already confirmed" in confirmation(query)["body"]
    reply = json.loads(app.handler(event(slim()), None)["body"])
    assert "partners" not in reply


def test_unconfirmed_partner_is_removed_without_approval(smtp, store, clock):
    app.handler(event(beat(to=["partner@test.invalid", "typo@test.invalid"])), None)
    confirm_all(store)
    store.items[INSTALL]["confirmedPartners"] = ["partner@test.invalid"]
    app.handler(event(slim(state="requestRemoval", removingPartners=["typo@test.invalid"])), None)
    item = store.items[INSTALL]
    assert item["to"] == ["partner@test.invalid"] and "removal" not in item
    assert not sent(smtp)
    assert status() == {"partners": ["partner@test.invalid"], "removalPending": False,
                        "released": ["typo@test.invalid"]}
    reply = json.loads(app.handler(event(slim()), None)["body"])
    assert reply["partners"] == {"released": ["typo@test.invalid"]}


def test_mixed_removal_releases_unconfirmed_and_asks_about_the_rest(smtp, store, clock):
    app.handler(event(beat(to=["partner@test.invalid", "typo@test.invalid"])), None)
    store.items[INSTALL]["confirmedPartners"] = ["partner@test.invalid"]
    app.handler(event(slim(state="removed")), None)
    item = store.items[INSTALL]
    assert item["to"] == ["partner@test.invalid"]
    assert item["removal"]["removingPartners"] == ["partner@test.invalid"]
    message, = sent(smtp)
    assert message["To"] == "partner@test.invalid"


def test_mistyped_first_partner_cant_hold_monitoring_hostage(smtp, store, clock):
    # The address typed first never confirms; a partner added later does.
    app.handler(event(beat(to="typo@test.invalid")), None)
    app.handler(event(beat(to=["typo@test.invalid", "real@test.invalid"])), None)
    store.items[INSTALL]["confirmedPartners"] = ["real@test.invalid"]
    # Asking to remove the real partner goes to them, not the dead address.
    app.handler(event(slim(state="requestRemoval", removingPartners=["real@test.invalid"])), None)
    message, = sent(smtp)
    assert message["To"] == "real@test.invalid"
    # The typo goes at once, while the real partner's removal still waits.
    app.handler(event(slim(state="requestRemoval", removingPartners=["typo@test.invalid"])), None)
    item = store.items[INSTALL]
    assert item["to"] == ["real@test.invalid"] and item["removal"]["removingPartners"] == ["real@test.invalid"]


def test_partner_added_later_cant_approve_removing_a_confirmed_original(smtp, store, clock):
    app.handler(event(beat()), None)
    confirm_all(store)
    app.handler(event(beat(to=["partner@test.invalid", "friend@test.invalid"])), None)
    store.items[INSTALL]["confirmedPartners"].append("friend@test.invalid")
    app.handler(event(slim(state="requestRemoval", removingPartners=["partner@test.invalid"])), None)
    assert [m["To"] for m in sent(smtp)] == ["partner@test.invalid"]


def test_partner_can_decline(smtp, store, clock):
    app.handler(event(beat(to=["partner@test.invalid", "stranger@test.invalid"])), None)
    store.items[INSTALL]["confirmedPartners"] = ["partner@test.invalid"]
    stranger = next(m for m in invites(smtp) if m["To"] == "stranger@test.invalid")
    query = confirm_link(stranger)
    assert confirmation(query, "decline")["statusCode"] == 200
    assert store.items[INSTALL]["to"] == ["partner@test.invalid"]
    assert status()["released"] == ["stranger@test.invalid"]
    assert confirmation(query)["statusCode"] == 404
    # A confirmed partner can't decline their way out.
    partner = next(m for m in invites(smtp) if m["To"] == "partner@test.invalid")
    assert confirmation(confirm_link(partner), "decline")["statusCode"] == 409
    assert store.items[INSTALL]["to"] == ["partner@test.invalid"]


def test_releasing_every_partner_leaves_a_tombstone(smtp, store, clock):
    app.handler(event(beat(to="typo@test.invalid")), None)
    app.handler(event(slim(state="removed")), None)
    assert not sent(smtp)
    assert status() == {"partners": [], "removalPending": False, "released": ["typo@test.invalid"]}
    clock["now"] += 3 * 86400
    assert app.handler(SCHEDULED, None) == {"alerted": 0}
    assert not sent(smtp)
    # A check-in without details can't bring it back.
    assert json.loads(app.handler(event(slim()), None)["body"])["needDetails"] is True
    # Adding a partner again starts over.
    app.handler(event(beat(to="real@test.invalid")), None)
    item = store.items[INSTALL]
    assert item["to"] == ["real@test.invalid"] and not item.get("ended")
    assert [m["To"] for m in invites(smtp)] == ["typo@test.invalid", "real@test.invalid"]


def test_readding_a_partner_doesnt_resend_their_invite_the_same_day(smtp, store, clock):
    app.handler(event(beat(to=["partner@test.invalid", "typo@test.invalid"])), None)
    store.items[INSTALL]["confirmedPartners"] = ["partner@test.invalid"]
    app.handler(event(slim(state="requestRemoval", removingPartners=["typo@test.invalid"])), None)
    clock["now"] += 60
    app.handler(event(beat(to=["partner@test.invalid", "typo@test.invalid"])), None)
    assert store.items[INSTALL]["to"] == ["partner@test.invalid", "typo@test.invalid"]
    assert "released" not in store.items[INSTALL]
    assert len([m for m in invites(smtp) if m["To"] == "typo@test.invalid"]) == 1
    clock["now"] += 86400
    app.handler(event(slim(state="requestRemoval", removingPartners=["typo@test.invalid"])), None)
    app.handler(event(beat(to=["partner@test.invalid", "typo@test.invalid"])), None)
    assert len([m for m in invites(smtp) if m["To"] == "typo@test.invalid"]) == 2


def test_removing_a_partner_the_server_never_enrolled_is_released(smtp, store, clock):
    app.handler(event(beat()), None)
    confirm_all(store)
    app.handler(event(slim(state="requestRemoval", removingPartners=["never@test.invalid"])), None)
    assert status()["released"] == ["never@test.invalid"]
    assert "removal" not in store.items[INSTALL] and not sent(smtp)


def test_partners_stored_before_confirmation_count_as_confirmed(smtp, store, clock):
    store.items[INSTALL] = stored(to=["partner@test.invalid", "other@test.invalid"])
    assert "unconfirmed" not in status()
    app.handler(event(slim(state="requestRemoval", removingPartners=["other@test.invalid"])), None)
    assert store.items[INSTALL]["removal"]["removingPartners"] == ["other@test.invalid"]
    # A partner added afterwards still has to confirm.
    app.handler(event(beat(to=["partner@test.invalid", "other@test.invalid", "new@test.invalid"])), None)
    assert status()["unconfirmed"] == ["new@test.invalid"]
    assert [m["To"] for m in invites(smtp)] == ["new@test.invalid"]


def test_older_clients_leaving_out_an_unconfirmed_partner_release_them(smtp, store, clock):
    app.handler(event(beat(to="typo@test.invalid")), None)
    app.handler(event(beat(to="real@test.invalid")), None)
    item = store.items[INSTALL]
    assert item["to"] == ["real@test.invalid"] and "removal" not in item
    assert item["released"] == ["typo@test.invalid"] and not sent(smtp)


def test_releasing_a_partner_doesnt_resend_an_open_removal_request(smtp, store, clock):
    app.handler(event(beat(to=["partner@test.invalid", "other@test.invalid", "typo@test.invalid"])), None)
    store.items[INSTALL]["confirmedPartners"] = ["partner@test.invalid", "other@test.invalid"]
    app.handler(event(slim(state="requestRemoval", removingPartners=["other@test.invalid"])), None)
    assert len(sent(smtp)) == 2  # both confirmed originals
    token = store.items[INSTALL]["removal"]["token"]
    app.handler(event(slim(state="requestRemoval", removingPartners=["typo@test.invalid"])), None)
    item = store.items[INSTALL]
    assert item["removal"]["token"] == token and item["removal"]["removingPartners"] == ["other@test.invalid"]
    assert len(sent(smtp)) == 2


def _every_checkin_body():
    """kind -> body lines, for every check-in email kind and its variants."""
    item = stored(last_seen=T0 - 3 * 3600)
    g = {"from": T0 - 1200, "to": T0 - 900}
    variants = {
        "silent": [dict(item, state="stopping"), item],
        "quiet": [dict(item, state="sleeping"), dict(item, state="shutdown")],
    }
    gaps = [dict(g, awakeSeconds=240), dict(g, awakeSeconds=900, restarted=True), dict(g, restarted=True),
            dict(g, kind="recordsMissing"), dict(g, kind="heartbeatStalled", awakeSeconds=120),
            dict(g, kind="recordUnverified")]
    out = []
    for kind in render.CHECKIN:
        for it in variants.get(kind, [item]):
            if kind == "back":
                beats = [{"boot": BOOT_EPOCH, "coveredSince": T0 - 4 * 3600}, {"boot": BOOT_EPOCH + 600},
                         {"boot": BOOT_EPOCH}, {"boot": BOOT_EPOCH, "newGaps": gaps[:1]}]
            else:
                beats = [{"boot": BOOT_EPOCH, "newGaps": [x]} for x in gaps]
            for b in beats:
                out.append((kind, heartbeat.lines_for(kind, it, T0, b)))
    return out


def test_checkin_emails_stay_short():
    """Partner emails should stay brief (see AGENTS.md, "Writing partner emails")."""
    for kind, lines in _every_checkin_body():
        assert 1 <= len(lines) <= 3, (kind, lines)
        for line in lines:
            assert len(line) <= 170, (kind, line)
            if kind != "invite":
                assert "Test Mac" not in line and "tester" not in line, ("the heading already names the Mac", kind, line)
        assert sum(len(line.split()) for line in lines) <= 50, (kind, lines)
