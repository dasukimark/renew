import json
import uuid

import pytest

import app
import heartbeat
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
                                   or bool(current.get("alerted")) != bool(expect.get("alerted"))):
            return False
        if self.before_put:
            hook, self.before_put = self.before_put, None
            hook(self)
            return self.put(item, expect)
        self.items[item["install"]] = dict(item)
        return True

    def delete(self, install):
        self.items.pop(install, None)

    def scan(self):
        return [json.loads(json.dumps(i)) for i in self.items.values()]

    def claim(self, install, last_seen):
        item = self.items.get(install)
        if not item or item["lastSeen"] != last_seen or item.get("alerted"):
            return False
        item["alerted"] = True
        return True

    def release(self, install, last_seen):
        item = self.items.get(install)
        if item and item["lastSeen"] == last_seen:
            item["alerted"] = False

    def add_notice(self, install, notice):
        if install in self.items:
            self.items[install]["notices"] = self.items[install].get("notices", []) + [notice]


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


def sent(smtp):
    return [m for i in smtp.instances for m in i.sent]


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
    assert json.loads(r["body"]) == {"notices": []}
    item = store.items[INSTALL]
    assert item["state"] == "awake" and item["lastSeen"] == T0 and item["boot"] == BOOT_EPOCH
    assert not sent(smtp)


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


def test_removed_deletes(smtp, store, clock):
    store.items[INSTALL] = (stored())
    assert app.handler(event(beat(state="removed")), None)["statusCode"] == 200
    assert INSTALL not in store.items
    assert not sent(smtp)


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


def test_failed_back_email_keeps_state(smtp, store, clock):
    store.items[INSTALL] = (stored(last_seen=T0 - 7200, alerted=True))
    smtp.fail_send = True
    assert app.handler(event(beat()), None)["statusCode"] == 502
    assert store.items[INSTALL]["alerted"] is True
    assert store.items[INSTALL]["lastSeen"] == T0 - 7200


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
    assert store.items[INSTALL]["alerted"] is False
    smtp.fail_send = False
    assert app.handler(SCHEDULED, None) == {"alerted": 1}


def test_scheduled_check_respects_allowed_recipients(smtp, store, clock, monkeypatch):
    monkeypatch.setenv("ALLOWED_RECIPIENTS", "someone@test.invalid")
    store.items[INSTALL] = (stored(last_seen=T0 - 3600))
    assert app.handler(SCHEDULED, None) == {"alerted": 0}
    assert not sent(smtp)


def test_claim_is_exclusive(store):
    store.items[INSTALL] = stored(last_seen=T0)
    assert store.claim(INSTALL, T0)
    assert not store.claim(INSTALL, T0)


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
    assert sent(smtp)[0]["To"] == "partner@test.invalid, other@test.invalid"


def test_several_partners_all_need_allowing(smtp, store, clock, monkeypatch):
    monkeypatch.setenv("ALLOWED_RECIPIENTS", "partner@test.invalid")
    r = app.handler(event(beat(to=["partner@test.invalid", "stranger@test.invalid"])), None)
    assert r["statusCode"] == 403


def test_slim_beat_still_checks_allowed_recipients(smtp, store, clock, monkeypatch):
    store.items[INSTALL] = (stored(last_seen=T0 - 3600, alerted=True))
    monkeypatch.setenv("ALLOWED_RECIPIENTS", "someone@test.invalid")
    assert app.handler(event(slim()), None)["statusCode"] == 502
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
    assert "records on Test Mac (tester) were deleted or replaced with an old copy" in text


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
