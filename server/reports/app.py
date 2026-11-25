"""Renew's report server: turns a report POSTed by renewd into an email.

Runs as an AWS Lambda behind a Function URL. The Gmail account is set here;
the partner's address comes in each report (`to`), set in the Renew app. Set
ALLOWED_RECIPIENTS to restrict which addresses the server will email.

Secrets (the report token and the Gmail app password) are SecureString SSM
parameters, read once per cold start.

It also keeps track of check-ins (heartbeats) from each Mac in a DynamoDB
table, and every few minutes (an EventBridge schedule) emails the partner
about Macs that went quiet without warning. See heartbeat.py.
"""

import base64
import hmac
import html
import json
import logging
import os
import re
import smtplib
import uuid
from datetime import datetime
from urllib.parse import parse_qs

import heartbeat
from render import as_list, build_emails, recipients

log = logging.getLogger()
log.setLevel(logging.INFO)

MAX_BODY = 256 * 1024
MAX_FLAGS = 200
MAX_CHANGES = 50
MAX_TEXT = 300
# Change sentences list removed sites or words (renewd keeps them short).
MAX_CHANGE_TEXT = 2000
MAX_REASONS = 50
KINDS = {"flags", "change", "test"}

_secrets = None
# Report ids this container has emailed, oldest first.
_recently_sent = {}


def _load_secrets():
    """(report token, Gmail app password), from SSM, cached for the container."""
    global _secrets
    if _secrets is None:
        import boto3  # in the Lambda runtime; imported lazily so tests don't need it

        ssm = boto3.client("ssm")

        def get(name):
            return ssm.get_parameter(Name=name, WithDecryption=True)["Parameter"]["Value"]

        _secrets = (get(os.environ["TOKEN_PARAM"]), get(os.environ["APP_PASSWORD_PARAM"]))
    return _secrets


def _response(status, message):
    return {"statusCode": status, "headers": {"Content-Type": "text/plain"}, "body": message}


class Invalid(ValueError):
    pass


def _text(value, field, limit=MAX_TEXT):
    if not isinstance(value, str):
        raise Invalid(f"{field} must be a string")
    text = value.strip()
    return text if len(text) <= limit else text[:limit - 1] + "…"


def _time(value, field):
    text = _text(value, field)
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        raise Invalid(f"{field} must be an ISO 8601 date") from None


def parse_report(body):
    """Checks a report's shape and returns a cleaned copy. Raises Invalid."""
    try:
        data = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        raise Invalid("body is not JSON") from None
    if not isinstance(data, dict):
        raise Invalid("body must be an object")
    kind = data.get("kind")
    if kind not in KINDS:
        raise Invalid("unknown kind")
    try:
        report_id = str(uuid.UUID(str(data.get("id"))))
    except ValueError:
        raise Invalid("id must be a UUID") from None

    flags_in = data.get("flags") or []
    changes_in = data.get("changes") or []
    if not isinstance(flags_in, list) or not isinstance(changes_in, list):
        raise Invalid("flags and changes must be lists")
    if len(flags_in) > MAX_FLAGS or len(changes_in) > MAX_CHANGES:
        raise Invalid("too many items")

    flags = []
    for i, f in enumerate(flags_in):
        if not isinstance(f, dict):
            raise Invalid(f"flags[{i}] must be an object")
        reasons = f.get("reasons") or []
        if not isinstance(reasons, list) or len(reasons) > MAX_REASONS:
            raise Invalid(f"flags[{i}].reasons must be a short list")
        seconds = f.get("seconds", 0)
        if not isinstance(seconds, int) or isinstance(seconds, bool) or seconds < 0:
            raise Invalid(f"flags[{i}].seconds must be a whole number")
        flags.append({
            "host": _text(f.get("host"), f"flags[{i}].host"),
            "title": _text(f.get("title", ""), f"flags[{i}].title"),
            "reasons": [_text(r, f"flags[{i}].reasons") for r in reasons],
            "start": _time(f.get("start"), f"flags[{i}].start"),
            "seconds": seconds,
        })

    omitted = data.get("omitted", 0)
    if not isinstance(omitted, int) or isinstance(omitted, bool) or omitted < 0:
        raise Invalid("omitted must be a whole number")

    to = recipients(data.get("to"))
    if to is None:
        raise Invalid("to must be an email address or a short list of them")
    zone = data.get("timeZone")
    if zone is not None and not isinstance(zone, str):
        raise Invalid("timeZone must be a string")

    return {
        "id": report_id,
        "to": to,
        "timeZone": (zone or "")[:64],
        "kind": kind,
        "mac": _text(data.get("mac", "a Mac"), "mac") or "a Mac",
        "user": _text(data.get("user", ""), "user"),
        "sentAt": _time(data.get("sentAt"), "sentAt"),
        "flags": flags,
        "omitted": omitted,
        "changes": [_text(c, "changes", MAX_CHANGE_TEXT) for c in changes_in],
    }


def send_email(msgs, sender, app_password):
    """Sends each of `msgs` (one per recipient) over one connection. An
    address Gmail refuses is skipped, so it can't hold back (or, on a retry,
    duplicate) the others' copies; raises only if every one is refused."""
    # Short enough that connect, sign-in and send finish well inside the
    # Lambda's timeout and renewd's (75 s).
    with smtplib.SMTP_SSL("smtp.gmail.com", 465, timeout=12) as smtp:
        smtp.login(sender, app_password)
        refused = []
        for msg in msgs:
            try:
                smtp.send_message(msg)
            except smtplib.SMTPRecipientsRefused as e:
                log.warning("Gmail refused %s; sending to the other partners", msg["To"])
                refused.append(e)
        if refused and len(refused) == len(msgs):
            raise refused[0]


def _json_response(status, data):
    return {"statusCode": status, "headers": {"Content-Type": "application/json"}, "body": json.dumps(data)}


def _allowed_recipients():
    return {a.strip().lower() for a in os.environ.get("ALLOWED_RECIPIENTS", "").split(",") if a.strip()}


def _is_heartbeat(body):
    try:
        data = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        return False
    return isinstance(data, dict) and data.get("kind") == "heartbeat"


def _send_built(report, app_password):
    """Emails a cleaned report; raises on failure."""
    sender = os.environ["GMAIL_ADDRESS"]
    send_email(build_emails(report, sender), sender, app_password)


def _checkin_sender(app_password):
    """Sends check-in emails, only to ALLOWED_RECIPIENTS when that's set."""
    allowed = _allowed_recipients()

    def send(report):
        if allowed and not set(as_list(report["to"])) <= allowed:
            raise heartbeat.SendFailed("recipient not allowed")
        _send_built(report, app_password)
    return send


def handler(event, context):
    if event.get("source") == "aws.events" or event.get("detail-type") == "Scheduled Event":
        return _scheduled_check()

    http = (event.get("requestContext") or {}).get("http") or {}
    method = http.get("method", "").upper()
    approval = event.get("rawPath") == "/monitoring/approve"
    confirmation = event.get("rawPath") == "/partners/confirm"
    if method not in ({"GET", "POST"} if approval or confirmation else {"POST"}):
        return _response(405, "method not allowed")

    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        try:
            body = base64.b64decode(body).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            return _response(400, "bad body")
    if len(body.encode("utf-8")) > MAX_BODY:
        return _response(413, "too large")
    if approval:
        return _monitoring_approval(method, event, body)
    if confirmation:
        return _partner_confirmation(method, event, body)

    try:
        token, app_password = _load_secrets()
    except Exception:
        log.exception("couldn't read secrets from SSM")
        return _response(500, "server misconfigured")

    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    auth = headers.get("authorization", "")
    given = auth[7:] if auth.lower().startswith("bearer ") else ""
    if not given or not hmac.compare_digest(given.encode(), token.encode()):
        return _response(401, "unauthorized")

    if _is_heartbeat(body):
        domain = (event.get("requestContext") or {}).get("domainName", "")
        branded_origin = os.environ.get("APPROVAL_BASE_URL", "").rstrip("/")
        origin = branded_origin if re.fullmatch(r"https://[a-zA-Z0-9.-]+", branded_origin) else (
            f"https://{domain}" if re.fullmatch(r"[a-zA-Z0-9.-]+", domain) else None)
        return _heartbeat(body, app_password, origin)

    try:
        report = parse_report(body)
    except Invalid as e:
        return _response(400, f"bad report: {e}")

    allowed = _allowed_recipients()
    if allowed and not set(report["to"]) <= allowed:
        log.warning("refused report %s to an address not in ALLOWED_RECIPIENTS", report["id"])
        return _response(403, "recipient not allowed")

    # renewd may send a report again if it didn't hear back in time. Skip
    # ones this container already sent; across containers, Gmail drops
    # repeats of the same Message-ID.
    if report["id"] in _recently_sent:
        log.info("report %s was already sent", report["id"])
        return _response(200, "already sent")

    sender = os.environ["GMAIL_ADDRESS"]
    try:
        send_email(build_emails(report, sender), sender, app_password)
    except smtplib.SMTPAuthenticationError:
        log.exception("Gmail refused the sign-in; check the app password, or sign in to the account to confirm it's you")
        return _response(502, "couldn't send")
    except (smtplib.SMTPException, OSError):
        log.exception("sending report %s failed", report["id"])
        return _response(502, "couldn't send")

    _recently_sent[report["id"]] = True
    while len(_recently_sent) > 1000:
        _recently_sent.pop(next(iter(_recently_sent)))
    log.info("sent %s report %s (%d flags)", report["kind"], report["id"], len(report["flags"]))
    return _response(200, "sent")


def _approval_page(status, content):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store",
                    "Referrer-Policy": "no-referrer",
                    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'"},
        "body": ("<!doctype html><html lang='en'><meta charset='utf-8'>"
                 "<meta name='viewport' content='width=device-width, initial-scale=1'>"
                 "<title>Renew partner request</title>"
                 "<style>body{font:17px system-ui;margin:0;background:#f4f7f6;color:#172b26}"
                 "main{max-width:36rem;margin:8vh auto;padding:clamp(1.25rem,5vw,3rem);background:white;border:1px solid #d8e4df;border-radius:16px}"
                 "header{font-weight:700;color:#0f6b57}h1{font-size:1.65rem}p{line-height:1.55}"
                 "form{display:flex;flex-wrap:wrap;gap:.75rem;margin:1.5rem 0 0}"
                 "button{font:inherit;font-weight:600;cursor:pointer;border:1px solid #bccdc5;border-radius:8px;padding:.65rem 1rem;background:white;color:#172b26}"
                 "button[value=reject],button[value=confirm]{background:#0f6b57;color:white;border-color:#0f6b57}</style>"
                 "<main><header>Renew</header>" + content + "</main></html>"),
    }


def _monitoring_approval(method, event, body):
    # An email scanner following the link can only load the confirmation.
    try:
        fields = parse_qs(event.get("rawQueryString", "") if method == "GET" else body, max_num_fields=4)
        install = str(uuid.UUID(fields["install"][0]))
        token = str(uuid.UUID(fields["token"][0]))
    except (KeyError, ValueError):
        return _approval_page(400, "<h1>Invalid approval link</h1>")
    store = heartbeat.store()
    try:
        if method == "POST":
            decision = fields.get("decision")
            if decision not in (["approve"], ["reject"]):
                return _approval_page(400, "<h1>Choose a monitoring decision</h1>")
            decision = decision[0]
            if decision == "reject" and heartbeat.reject_removal(install, token, store):
                return _approval_page(200, "<h1>Monitoring will continue</h1><p>You declined the request to end Renew monitoring.</p>")
            if decision == "approve":
                result = heartbeat.approve_removal(install, token, store)
                if result == "ended":
                    return _approval_page(200, "<h1>Renew monitoring ended</h1><p>The server will stop expecting check-ins for this enrollment.</p>")
                if result == "updated":
                    return _approval_page(200, "<h1>Partner removal approved</h1><p>Renew continues monitoring for the remaining partners.</p>")
        else:
            item = store.get(install) or {}
            request = item.get("removal") or {}
            if hmac.compare_digest(request.get("token", ""), token):
                affected = heartbeat._removing_partners(item)
                partners = "".join(f"<li>{html.escape(address)}</li>" for address in affected)
                full = len(affected) == len(as_list(item["to"]))
                action = "Approve ending monitoring" if full else "Approve partner removal"
                return _approval_page(200,
                    f"<h1>Monitoring request for {html.escape(item['mac'])}</h1>"
                    f"<p>This request removes check-in monitoring for:</p><ul>{partners}</ul>"
                    "<p>Renew requires no sign-in or password to respond.</p>"
                    "<form method='post' action='/monitoring/approve'>"
                    f"<input type='hidden' name='install' value='{install}'>"
                    f"<input type='hidden' name='token' value='{token}'>"
                    "<button name='decision' value='reject'>Keep monitoring</button>"
                    f"<button name='decision' value='approve'>{action}</button></form>")
    except Exception:
        log.exception("couldn't process monitoring approval")
        return _approval_page(500, "<h1>Couldn’t process the request</h1><p>Try the link again later.</p>")
    return _approval_page(404, "<h1>This approval link is no longer active</h1>")


def _partner_confirmation(method, event, body):
    # Like approvals: opening the link only shows the choice, so an email
    # scanner following it can't decide.
    try:
        fields = parse_qs(event.get("rawQueryString", "") if method == "GET" else body, max_num_fields=4)
        install = str(uuid.UUID(fields["install"][0]))
        token = str(uuid.UUID(fields["token"][0]))
    except (KeyError, ValueError):
        return _approval_page(400, "<h1>Invalid confirmation link</h1>")
    store = heartbeat.store()
    try:
        item = store.get(install)
        email = heartbeat.invite_for(item, token)
        if email is None:
            return _approval_page(404, "<h1>This confirmation link is no longer active</h1>"
                                       "<p>You aren't a partner for this Mac any more, so you won't get its emails.</p>")
        mac = html.escape(item["mac"])
        if method == "POST":
            decision = fields.get("decision")
            if decision == ["confirm"] and heartbeat.confirm_partner(install, token, store):
                return _approval_page(200, f"<h1>Thanks, you're confirmed</h1><p>You're an accountability partner "
                                           f"for Renew on {mac}. Removing you now needs a partner's approval.</p>")
            if decision == ["decline"]:
                if heartbeat.decline_partner(install, token, store):
                    return _approval_page(200, "<h1>You won't get any more emails</h1>"
                                               f"<p>You were removed as a partner for Renew on {mac}.</p>")
                return _approval_page(409, "<h1>You already confirmed</h1><p>To stop being a partner, ask them "
                                           "to remove you; you'll get an email to approve it.</p>")
            return _approval_page(400, "<h1>Choose confirm or decline</h1>")
        if email in heartbeat._confirmed(item):
            return _approval_page(200, f"<h1>You're already confirmed</h1><p>You're an accountability partner for Renew on {mac}.</p>")
        return _approval_page(200,
            f"<h1>Be an accountability partner for {mac}?</h1>"
            f"<p>{html.escape(email)} was added as a partner. Renew emails its partners when it flags a visit, "
            "when monitoring is loosened, and if Renew stops running. Once you confirm, removing you needs "
            "a partner's approval.</p><p>If you don't know this person, choose Decline.</p>"
            "<form method='post' action='/partners/confirm'>"
            f"<input type='hidden' name='install' value='{install}'>"
            f"<input type='hidden' name='token' value='{token}'>"
            "<button name='decision' value='decline'>Decline</button>"
            "<button name='decision' value='confirm'>Confirm</button></form>")
    except Exception:
        log.exception("couldn't process partner confirmation")
        return _approval_page(500, "<h1>Couldn’t process the request</h1><p>Try the link again later.</p>")


def _heartbeat(body, app_password, approval_origin):
    try:
        beat = heartbeat.parse_heartbeat(body)
    except heartbeat.Invalid as e:
        return _response(400, f"bad heartbeat: {e}")
    allowed = _allowed_recipients()
    if allowed and beat["to"] is not None and not set(beat["to"]) <= allowed:
        log.warning("refused heartbeat from %s to an address not in ALLOWED_RECIPIENTS", beat["install"])
        return _response(403, "recipient not allowed")
    try:
        reply = heartbeat.record_beat(beat, heartbeat.now(), heartbeat.store(), _checkin_sender(app_password),
                                      approval_origin=approval_origin)
    except heartbeat.SendFailed:
        log.exception("couldn't accept heartbeat from %s", beat["install"])
        return _response(502, "couldn't accept heartbeat")
    except Exception:
        log.exception("couldn't record heartbeat from %s", beat["install"])
        return _response(500, "couldn't record")
    return _json_response(200, reply)


def _scheduled_check():
    try:
        _, app_password = _load_secrets()
    except Exception:
        log.exception("couldn't read secrets from SSM")
        return {"checked": 0, "error": "secrets"}
    sent = heartbeat.check_all(heartbeat.now(), heartbeat.store(), _checkin_sender(app_password),
                               silence=heartbeat.silence_seconds(), cap=heartbeat.cap_seconds(),
                               stopping=heartbeat.stopping_seconds())
    return {"alerted": sent}
