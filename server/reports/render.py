"""Turns a cleaned report into the email: a plain-text part and an HTML part.

Sites and page titles are shown without links, on purpose: the partner
shouldn't be one tap from an explicit site. Email apps turn anything that
looks like a domain into a link, even in plain text, so every dot inside a
word is replaced with a look-alike (U+2024 ONE DOT LEADER) that no app
treats as a domain.
"""

import html
import os
import re
from datetime import timedelta, timezone
from email.message import EmailMessage
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

DOT = "․"
_INNER_DOT = re.compile(r"(?<=\w)\.(?=\w)")
_SCHEME = re.compile(r"(?i)\b(https?|ftp)://")

# Palette (inline styles only; email apps ignore most CSS).
INK = "#18181b"
MUTED = "#71717a"
FAINT = "#a1a1aa"
LINE = "#e4e4e7"
PAGE = "#f4f4f5"
CARD = "#ffffff"
ACCENT = "#0f766e"
FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif"

PILLS = {
    "explicit": ("#fef2f2", "#b91c1c"),
    "word": ("#eef2ff", "#4338ca"),
    "other": ("#fffbeb", "#b45309"),
}


def unlinkable(text):
    """`text` with dots inside words (and URL schemes) disarmed, so no email
    app turns it into a link."""
    return _INNER_DOT.sub(DOT, _SCHEME.sub(lambda m: m.group(1) + ":/⁠/", text))


def esc(text):
    return html.escape(unlinkable(text))


def duration(seconds):
    if seconds < 60:
        return f"{seconds}s"
    minutes, s = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes}m {s}s" if s else f"{minutes}m"
    hours, m = divmod(minutes, 60)
    return f"{hours}h {m}m" if m else f"{hours}h"


def zone_for(name):
    """The Mac's time zone from the report, else TIME_ZONE, else UTC."""
    for candidate in (name, os.environ.get("TIME_ZONE")):
        if candidate:
            try:
                return ZoneInfo(candidate)
            except (ZoneInfoNotFoundError, ValueError):
                pass
    return timezone.utc


def local(dt, zone):
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(zone)


def when(dt, zone):
    return local(dt, zone).strftime("%a %d %b %Y, %H:%M %Z")


def clock(dt, zone):
    return local(dt, zone).strftime("%H:%M")


def plural(n, word):
    return f"{n} {word}{'' if n == 1 else 's'}"


def group_by_site(flags):
    """[(host, [flags…])], in order of each site's first visit."""
    groups = {}
    for f in sorted(flags, key=lambda f: f["start"]):
        groups.setdefault(f["host"], []).append(f)
    return list(groups.items())


def span(flags, zone):
    """'Tue 17 Nov, 14:02–14:09 EST' for the visits' time range."""
    first = local(min(f["start"] for f in flags), zone)
    last = local(max(f["start"] + timedelta(seconds=f["seconds"]) for f in flags), zone)
    day = first.strftime("%a %d %b")
    if first.date() == last.date():
        return f"{day}, {first:%H:%M}–{last:%H:%M %Z}"
    return f"{day} {first:%H:%M} – {last:%a %d %b %H:%M %Z}"


def pill(reason):
    kind = "explicit" if reason.startswith("explicit") else "word" if reason.startswith("word:") else "other"
    bg, fg = PILLS[kind]
    return (f"<span style='display:inline-block;margin:0 6px 4px 0;padding:2px 9px;border-radius:999px;"
            f"background:{bg};color:{fg};font-size:12px;font-weight:600;line-height:18px'>{esc(reason)}</span>")


def stat(value, label):
    return (f"<td width='33%' style='padding:14px 8px;text-align:center;background:{PAGE};border-radius:10px'>"
            f"<div style='font-size:22px;font-weight:700;color:{INK};line-height:26px'>{html.escape(value)}</div>"
            f"<div style='font-size:12px;color:{MUTED};margin-top:2px'>{html.escape(label)}</div></td>")


def site_block(host, visits, zone):
    total = sum(v["seconds"] for v in visits)
    reasons = []
    for v in visits:
        for r in v["reasons"]:
            if r not in reasons:
                reasons.append(r)
    no_title = f"<span style='color:{FAINT}'>No title</span>"
    rows = "".join(
        f"<tr><td valign='top' width='52' style='width:52px;padding:6px 0;color:{MUTED};font-size:13px;white-space:nowrap;"
        f"font-variant-numeric:tabular-nums'>{clock(v['start'], zone)}</td>"
        f"<td valign='top' width='68' style='width:68px;padding:6px 0;color:{MUTED};font-size:13px;white-space:nowrap'>"
        f"{duration(v['seconds'])}</td>"
        f"<td valign='top' style='padding:6px 0;color:{INK};font-size:13px'>"
        f"{esc(v['title']) if v['title'] else no_title}</td></tr>"
        for v in visits
    )
    return (
        f"<tr><td style='padding:18px 0 4px;border-top:1px solid {LINE}'>"
        f"<table role='presentation' width='100%' cellpadding='0' cellspacing='0'><tr>"
        f"<td style='font-size:16px;font-weight:700;color:{INK}'>{esc(host)}</td>"
        f"<td align='right' style='font-size:13px;color:{MUTED};white-space:nowrap'>"
        f"{plural(len(visits), 'visit')} · {duration(total)}</td></tr></table>"
        f"<div style='margin-top:8px'>{''.join(pill(r) for r in reasons) or pill('flagged')}</div>"
        f"<table role='presentation' width='100%' cellpadding='0' cellspacing='0' style='margin-top:4px;table-layout:fixed'>{rows}</table>"
        f"</td></tr>"
    )


def notice(lines, color, bg):
    items = "".join(f"<li style='margin:0 0 6px'>{esc(c)}</li>" for c in lines)
    return (f"<tr><td style='padding:16px 18px;background:{bg};border-left:4px solid {color};border-radius:8px'>"
            f"<ul style='margin:0;padding-left:18px;color:{INK};font-size:14px;line-height:21px'>{items}</ul></td></tr>")


def build_email(report, sender):
    """The email for a cleaned report (see app.parse_report)."""
    zone = zone_for(report["timeZone"])
    flags = report["flags"]
    who = report["mac"] + (f" ({report['user']})" if report["user"] else "")
    n = len(flags) + report["omitted"]
    sites = group_by_site(flags)

    if report["kind"] == "flags":
        subject = f"Renew report: {plural(n, 'flagged visit')} on {report['mac']}"
        heading = plural(n, "flagged visit")
        sub = f"on {who}" + (f" · {span(flags, zone)}" if flags else "")
        preheader = f"{plural(n, 'flagged visit')} on {plural(len(sites), 'site')}"
    elif report["kind"] == "change":
        subject = f"Renew: monitoring changed on {report['mac']}"
        heading = "Monitoring changed"
        sub = f"on {who} · {when(report['sentAt'], zone)}"
        preheader = report["changes"][0] if report["changes"] else heading
    else:
        subject = f"Renew: test report from {report['mac']}"
        heading = "Test report"
        sub = f"from {who} · {when(report['sentAt'], zone)}"
        preheader = "Email reports from Renew work."

    # Plain text.
    text = [heading, sub, ""]
    for host, visits in sites:
        text.append(f"{unlinkable(host)}  ({plural(len(visits), 'visit')}, {duration(sum(v['seconds'] for v in visits))})")
        for v in visits:
            reasons = ", ".join(v["reasons"]) or "flagged"
            title = f"  \"{unlinkable(v['title'])}\"" if v["title"] else ""
            text.append(f"  {clock(v['start'], zone)}  {duration(v['seconds']):>7}  {unlinkable(reasons)}{title}")
        text.append("")
    if report["omitted"]:
        text += [f"...and {report['omitted']} more flagged visits not listed.", ""]
    for c in report["changes"]:
        text.append(f"- {unlinkable(c)}")
    text += ["", f"Sent by Renew at {when(report['sentAt'], zone)}. Sites are shown without links.",
             f"Report {report['id']}"]

    # HTML.
    body = []
    if flags:
        total = sum(f["seconds"] for f in flags)
        body.append(
            f"<tr><td style='padding:0 0 8px'><table role='presentation' width='100%' cellpadding='0' cellspacing='6'>"
            f"<tr>{stat(str(n), 'flagged visits' if n != 1 else 'flagged visit')}"
            f"{stat(str(len(sites)), 'sites' if len(sites) != 1 else 'site')}"
            f"{stat(duration(total), 'time on pages')}</tr></table></td></tr>"
        )
        body += [site_block(host, visits, zone) for host, visits in sites]
        if report["omitted"]:
            body.append(f"<tr><td style='padding:14px 0 0;border-top:1px solid {LINE};color:{MUTED};font-size:13px'>"
                        f"…and {report['omitted']} more flagged visits not listed.</td></tr>")
    if report["changes"]:
        color, bg = (("#15803d", "#f0fdf4") if report["kind"] == "test" else ("#b45309", "#fffbeb"))
        body.append(notice(report["changes"], color, bg))

    page = f"""<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light"><meta name="supported-color-schemes" content="light">
<title>{html.escape(subject)}</title></head>
<body style="margin:0;padding:0;background:{PAGE};font-family:{FONT}">
<div style="display:none;max-height:0;overflow:hidden;opacity:0">{esc(preheader)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:{PAGE}">
<tr><td align="center" style="padding:28px 12px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:{CARD};border-radius:14px;border:1px solid {LINE}">
<tr><td style="padding:26px 28px 10px">
<div style="font-size:12px;font-weight:700;letter-spacing:2px;color:{ACCENT};text-transform:uppercase">Renew</div>
<div style="font-size:24px;font-weight:700;color:{INK};margin-top:8px;line-height:30px">{html.escape(heading)}</div>
<div style="font-size:14px;color:{MUTED};margin-top:4px;line-height:20px">{esc(sub)}</div>
</td></tr>
<tr><td style="padding:12px 28px 24px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0">{''.join(body)}</table>
</td></tr>
<tr><td style="padding:16px 28px 22px;border-top:1px solid {LINE};font-size:12px;line-height:18px;color:{FAINT}">
Sent automatically by Renew at {html.escape(when(report['sentAt'], zone))}. Sites are shown without links, and full
addresses are never included.<br>Report {html.escape(report['id'])}
</td></tr>
</table>
</td></tr></table>
</body></html>"""

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = f"Renew <{sender}>"
    msg["To"] = report["to"]
    # One Message-ID per report, so a report sent twice is one email.
    msg["Message-ID"] = f"<{report['id']}@renew.reports>"
    msg.set_content("\n".join(text))
    msg.add_alternative(page, subtype="html")
    return msg
