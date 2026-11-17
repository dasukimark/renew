"""Renew's report server: turns a report POSTed by renewd into an email.

Runs as an AWS Lambda behind a Function URL. The Gmail account is set here;
the partner's address comes in each report (`to`), set in the Renew app. Set
ALLOWED_RECIPIENTS to restrict which addresses the server will email.

Secrets (the report token and the Gmail app password) are SecureString SSM
parameters, read once per cold start.
"""

import base64
import hmac
import json
import logging
import os
import re
import smtplib
import uuid
from datetime import datetime

from render import build_email

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
EMAIL = re.compile(r"[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9-]+(\.[a-z0-9-]+)+")

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

    to = data.get("to")
    if not isinstance(to, str) or len(to) > 254 or not EMAIL.fullmatch(to.strip().lower()):
        raise Invalid("to must be one email address")
    zone = data.get("timeZone")
    if zone is not None and not isinstance(zone, str):
        raise Invalid("timeZone must be a string")

    return {
        "id": report_id,
        "to": to.strip().lower(),
        "timeZone": (zone or "")[:64],
        "kind": kind,
        "mac": _text(data.get("mac", "a Mac"), "mac") or "a Mac",
        "user": _text(data.get("user", ""), "user"),
        "sentAt": _time(data.get("sentAt"), "sentAt"),
        "flags": flags,
        "omitted": omitted,
        "changes": [_text(c, "changes", MAX_CHANGE_TEXT) for c in changes_in],
    }


def send_email(msg, sender, app_password):
    # Short enough that connect, sign-in and send finish well inside the
    # Lambda's timeout and renewd's (75 s).
    with smtplib.SMTP_SSL("smtp.gmail.com", 465, timeout=12) as smtp:
        smtp.login(sender, app_password)
        smtp.send_message(msg)


def handler(event, context):
    http = (event.get("requestContext") or {}).get("http") or {}
    if http.get("method", "").upper() != "POST":
        return _response(405, "method not allowed")

    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        try:
            body = base64.b64decode(body).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            return _response(400, "bad body")
    if len(body.encode("utf-8")) > MAX_BODY:
        return _response(413, "too large")

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

    try:
        report = parse_report(body)
    except Invalid as e:
        return _response(400, f"bad report: {e}")

    allowed = {a.strip().lower() for a in os.environ.get("ALLOWED_RECIPIENTS", "").split(",") if a.strip()}
    if allowed and report["to"] not in allowed:
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
        send_email(build_email(report, sender), sender, app_password)
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
