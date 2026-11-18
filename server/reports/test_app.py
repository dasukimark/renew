import json
import smtplib
import uuid

import pytest

import app
import render

TOKEN = "test-token-123"


@pytest.fixture(autouse=True)
def env(monkeypatch):
    monkeypatch.setenv("GMAIL_ADDRESS", "sender@test.invalid")
    monkeypatch.setenv("TIME_ZONE", "UTC")
    monkeypatch.delenv("ALLOWED_RECIPIENTS", raising=False)
    monkeypatch.setattr(app, "_secrets", (TOKEN, "app-password"))
    monkeypatch.setattr(app, "_recently_sent", {})


class FakeSMTP:
    instances = []
    fail_login = False
    fail_send = False

    def __init__(self, host, port, timeout=None):
        self.host, self.port = host, port
        self.logins, self.sent = [], []
        FakeSMTP.instances.append(self)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def login(self, user, password):
        if FakeSMTP.fail_login:
            raise smtplib.SMTPAuthenticationError(535, b"bad credentials")
        self.logins.append((user, password))

    def send_message(self, msg):
        if FakeSMTP.fail_send:
            raise smtplib.SMTPServerDisconnected("gone")
        self.sent.append(msg)


@pytest.fixture
def smtp(monkeypatch):
    FakeSMTP.instances = []
    FakeSMTP.fail_login = False
    FakeSMTP.fail_send = False
    monkeypatch.setattr(app.smtplib, "SMTP_SSL", FakeSMTP)
    return FakeSMTP


def report(**overrides):
    body = {
        "id": str(uuid.uuid4()),
        "mac": "Test Mac",
        "user": "tester",
        "kind": "flags",
        "sentAt": "2026-11-17T12:00:00Z",
        "flags": [
            {"host": "a.example", "title": "A page title", "reasons": ["explicit site"], "start": "2026-11-17T11:58:00Z", "seconds": 42},
            {"host": "<b>evil.example</b>", "title": "<img src=x onerror=alert(1)>", "reasons": ["word: <script>"],
             "start": "2026-11-17T11:59:00Z", "seconds": 125},
        ],
        "omitted": 0,
        "changes": [],
        "to": "partner@test.invalid",
        "timeZone": "UTC",
    }
    body.update(overrides)
    return body


def event(body, method="POST", token=TOKEN):
    headers = {"content-type": "application/json"}
    if token is not None:
        headers["authorization"] = f"Bearer {token}"
    return {
        "requestContext": {"http": {"method": method}},
        "headers": headers,
        "body": body if isinstance(body, str) else json.dumps(body),
        "isBase64Encoded": False,
    }


def test_wrong_method(smtp):
    assert app.handler(event(report(), method="GET"), None)["statusCode"] == 405
    assert not smtp.instances


@pytest.mark.parametrize("token", [None, "", "wrong", TOKEN + "x"])
def test_bad_token(smtp, token):
    assert app.handler(event(report(), token=token), None)["statusCode"] == 401
    assert not smtp.instances


def test_oversized(smtp):
    assert app.handler(event("x" * (app.MAX_BODY + 1)), None)["statusCode"] == 413
    assert not smtp.instances


@pytest.mark.parametrize("body", [
    "not json",
    report(kind="other"),
    report(to=None),
    report(to="nobody"),
    report(to="a@test.invalid\nBcc: x@test.invalid"),
    report(to="a@test.invalid, b@test.invalid"),
    report(to=[]),
    report(to=["a@test.invalid", "nobody"]),
    report(to=[f"p{i}@test.invalid" for i in range(render.MAX_RECIPIENTS + 1)]),
    report(id="nope"),
    report(flags=[{"host": "a.example", "reasons": [], "start": "yesterday", "seconds": 1}]),
    report(flags=[{"host": "a.example", "reasons": [], "start": "2026-11-17T11:58:00Z", "seconds": -1}]),
    report(flags=[{"host": "a.example", "reasons": [], "start": "2026-11-17T11:58:00Z", "seconds": 1}] * (app.MAX_FLAGS + 1)),
])
def test_bad_report(smtp, body):
    assert app.handler(event(body), None)["statusCode"] == 400
    assert not smtp.instances


def test_flags_report_is_emailed(smtp):
    r = app.handler(event(report()), None)
    assert r["statusCode"] == 200
    [conn] = smtp.instances
    assert (conn.host, conn.port) == ("smtp.gmail.com", 465)
    assert conn.logins == [("sender@test.invalid", "app-password")]
    [msg] = conn.sent
    assert msg["To"] == "partner@test.invalid"
    assert "sender@test.invalid" in msg["From"]
    assert msg["Subject"] == "Renew report: 2 flagged visits on Test Mac"
    text = msg.get_body(("plain",)).get_content()
    assert "a\u2024example" in text and "42s" in text and "2m 5s" in text
    assert '"A page title"' in text
    page = msg.get_body(("html",)).get_content()
    assert "&lt;b&gt;evil\u2024example&lt;/b&gt;" in page
    assert "&lt;script&gt;" in page
    assert "<script>" not in page
    assert "A page title" in page
    assert "&lt;img src=x onerror=alert(1)&gt;" in page and "<img" not in page


def test_sites_are_never_linkable(smtp):
    flags = [
        {"host": "www.explicit.example", "title": "See https://other.example/x or mirror.example now",
         "reasons": ["explicit site"], "start": "2026-11-17T11:58:00Z", "seconds": 42},
    ]
    body = report(flags=flags, kind="flags")
    assert app.handler(event(body), None)["statusCode"] == 200
    msg = smtp.instances[0].sent[0]
    for part in (msg.get_body(("plain",)).get_content(), msg.get_body(("html",)).get_content()):
        for domain in ("explicit.example", "other.example", "mirror.example", "https://"):
            assert domain not in part
        assert "<a " not in part
        assert "www\u2024explicit\u2024example" in part


def test_unlinkable_keeps_sentences():
    import render
    assert render.unlinkable("The Monitor was turned off.") == "The Monitor was turned off."
    assert render.unlinkable("Watched sites removed: a.example, b.example.") == \
        "Watched sites removed: a\u2024example, b\u2024example."


def test_flags_grouped_by_site(smtp):
    flags = [
        {"host": "a.example", "title": "One", "reasons": ["explicit site"], "start": "2026-11-17T11:58:00Z", "seconds": 60},
        {"host": "b.example", "title": "Two", "reasons": ["word: dice"], "start": "2026-11-17T11:59:00Z", "seconds": 30},
        {"host": "a.example", "title": "Three", "reasons": ["explicit site"], "start": "2026-11-17T12:00:00Z", "seconds": 60},
    ]
    assert app.handler(event(report(flags=flags)), None)["statusCode"] == 200
    text = smtp.instances[0].sent[0].get_body(("plain",)).get_content()
    assert "a\u2024example  (2 visits, 2m)" in text
    assert text.index("a\u2024example") < text.index("b\u2024example")


def test_times_use_the_macs_time_zone(smtp):
    assert app.handler(event(report(timeZone="America/New_York")), None)["statusCode"] == 200
    text = smtp.instances[0].sent[0].get_body(("plain",)).get_content()
    assert "06:58" in text and "EST" in text


def test_unknown_time_zone_falls_back(smtp):
    assert app.handler(event(report(timeZone="Not/AZone")), None)["statusCode"] == 200
    text = smtp.instances[0].sent[0].get_body(("plain",)).get_content()
    assert "11:58" in text and "UTC" in text


def test_allowed_recipients(smtp, monkeypatch):
    monkeypatch.setenv("ALLOWED_RECIPIENTS", "Partner@Test.Invalid, other@test.invalid")
    assert app.handler(event(report()), None)["statusCode"] == 200
    assert app.handler(event(report(to="stranger@test.invalid")), None)["statusCode"] == 403
    assert app.handler(event(report(to=["partner@test.invalid", "stranger@test.invalid"])), None)["statusCode"] == 403
    assert len(smtp.instances) == 1


def test_repeats_dont_count_toward_the_limit(smtp):
    to = [f"p{i}@test.invalid" for i in range(render.MAX_RECIPIENTS)] + ["P0@test.invalid"]
    assert app.handler(event(report(to=to)), None)["statusCode"] == 200


def test_several_partners(smtp):
    body = report(to=["Partner@Test.Invalid", "other@test.invalid", "partner@test.invalid"])
    assert app.handler(event(body), None)["statusCode"] == 200
    [msg] = smtp.instances[0].sent
    assert msg["To"] == "partner@test.invalid, other@test.invalid"


def test_same_report_is_sent_once(smtp):
    body = report()
    assert app.handler(event(body), None)["statusCode"] == 200
    assert app.handler(event(body), None)["statusCode"] == 200
    sent = [m for c in smtp.instances for m in c.sent]
    assert len(sent) == 1
    assert sent[0]["Message-ID"] == f"<{body['id']}@renew.reports>"


def test_failed_send_can_be_retried(smtp):
    body = report()
    smtp.fail_send = True
    assert app.handler(event(body), None)["statusCode"] == 502
    smtp.fail_send = False
    assert app.handler(event(body), None)["statusCode"] == 200


def test_long_change_lists_are_kept(smtp):
    sites = ", ".join(f"site{i}.example" for i in range(15)) + " and 25 more"
    body = report(kind="change", flags=[], changes=[f"Watched sites removed: {sites}."])
    assert app.handler(event(body), None)["statusCode"] == 200
    text = smtp.instances[0].sent[0].get_body(("plain",)).get_content()
    assert "and 25 more" in text


def test_change_report(smtp):
    r = app.handler(event(report(kind="change", flags=[], changes=["The Monitor was turned off."])), None)
    assert r["statusCode"] == 200
    [msg] = smtp.instances[0].sent
    assert msg["Subject"] == "Renew: monitoring changed on Test Mac"
    assert "The Monitor was turned off." in msg.get_body(("plain",)).get_content()


def test_base64_body(smtp):
    import base64
    e = event(report())
    e["body"] = base64.b64encode(e["body"].encode()).decode()
    e["isBase64Encoded"] = True
    assert app.handler(e, None)["statusCode"] == 200


def test_login_failure_is_5xx(smtp):
    smtp.fail_login = True
    assert app.handler(event(report()), None)["statusCode"] == 502


def test_send_failure_is_5xx(smtp):
    smtp.fail_send = True
    assert app.handler(event(report()), None)["statusCode"] == 502


def test_secrets_failure_is_5xx(smtp, monkeypatch):
    monkeypatch.setattr(app, "_secrets", None)
    monkeypatch.setattr(app, "_load_secrets", lambda: (_ for _ in ()).throw(RuntimeError("no ssm")))
    assert app.handler(event(report()), None)["statusCode"] == 500
