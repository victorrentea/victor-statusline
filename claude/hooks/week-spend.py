#!/usr/bin/env python3
# What this week's Claude Code usage would have cost at API prices -- the
# "$1840/6d" at the far end of the status line.
#
# The subscription hides the money: the weekly cell says how much of the
# ALLOWANCE is gone, never what that allowance is worth. This adds up every
# assistant message in ~/.claude/projects/**/*.jsonl (subagent transcripts
# included) at the per-MTok rates of the model that answered it, so the bar can
# say what the week has burned in the only unit that compares across plans,
# models and people.
#
# THE FIGURE STOPS AT LOCAL MIDNIGHT. It covers the weekly window from its start
# up to the end of YESTERDAY, never today. That makes it a once-a-day job: the
# scan reads every transcript touched this week (hundreds of MB), which is fine
# once a day in the background and absurd on every render of every terminal. A
# number that moves once a day also matches what it is for -- a rate to compare
# against the week's pace, not a meter to watch.
#
# Cached in ~/.claude/week-spend as one line:
#   "<window_start> <date> <usd> <days>"
# keyed by the window start AND today's local date: either changing (a new day,
# or the window turning over) makes the status line kick a recount; otherwise it
# reads the line and does no work at all. <days> is the span the dollars cover,
# window start -> midnight, in days rounded to one decimal.
#
#   week-spend.py <weekly_resets_at_epoch>   recount if the cache is stale
#   week-spend.py <epoch> --force            recount regardless
#
# Env: CLAUDE_WEEK_SPEND_FILE (the cache), CLAUDE_PROJECTS_DIR (the transcripts).
#
# Prices are the API list prices, $/MTok of base input, matched on the model ID
# in the same order as the status line's own table (x.5 before x, because
# "opus-5" is a prefix of "opus-5-5"). Output is 5x input, cache writes 1.25x
# (5m) / 2x (1h), cache reads the model's read multiplier. From the pricing
# page, 2026-09-30.
import datetime
import json
import os
import pathlib
import sys
import time

RATES = [  # (substring of the model id, input $/MTok, cache-read multiplier)
    ("fable-5-1", 10, 0.025), ("mythos-5-1", 10, 0.025),
    ("fable", 10, 0.1), ("mythos", 10, 0.1),
    ("opus-5-5", 4, 0.05),
    ("opus-4-1", 15, 0.1), ("opus-4-0", 15, 0.1), ("opus-4-2025", 15, 0.1),
    ("opus", 5, 0.1),
    ("sonnet-5", 2, 0.1), ("sonnet", 3, 0.1),
    ("haiku-3", 0.8, 0.1), ("haiku", 1, 0.1),
]
WEB_SEARCH_USD = 0.01  # $10 per 1000 searches


def rate(model):
    for key, inp, rd in RATES:
        if key in model:
            return inp, rd
    return 5, 0.1


def cost(model, u):
    inp, rd = rate(model)
    cc = u.get("cache_creation") or {}
    w5 = cc.get("ephemeral_5m_input_tokens")
    w1 = cc.get("ephemeral_1h_input_tokens")
    if w5 is None and w1 is None:  # older transcripts: no TTL split, assume 5m
        w5, w1 = u.get("cache_creation_input_tokens") or 0, 0
    tok = ((u.get("input_tokens") or 0) * inp
           + (w5 or 0) * inp * 1.25 + (w1 or 0) * inp * 2
           + (u.get("cache_read_input_tokens") or 0) * inp * rd
           + (u.get("output_tokens") or 0) * inp * 5)
    web = ((u.get("server_tool_use") or {}).get("web_search_requests") or 0) * WEB_SEARCH_USD
    return tok / 1e6 + web


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def main():
    if len(sys.argv) < 2 or not sys.argv[1].isdigit():
        sys.exit("usage: week-spend.py <weekly_resets_at_epoch> [--force]")
    reset = int(sys.argv[1])
    start = reset - 604800
    out = pathlib.Path(os.environ.get("CLAUDE_WEEK_SPEND_FILE", pathlib.Path.home() / ".claude/week-spend"))
    root = pathlib.Path(os.environ.get("CLAUDE_PROJECTS_DIR", pathlib.Path.home() / ".claude/projects"))
    today = datetime.date.today()
    key = f"{start} {today.isoformat()}"
    if "--force" not in sys.argv:
        try:
            if out.read_text().startswith(key + " "):
                return
        except OSError:
            pass
    # One recount at a time: every terminal notices the new day on the same
    # render, and they must not all scan the same hundreds of MB at once. A lock
    # older than 10 minutes is a crashed run, not a running one.
    lock = pathlib.Path(str(out) + ".lock")
    try:
        lock.mkdir()
    except FileExistsError:
        if time.time() - lock.stat().st_mtime < 600:
            return
    try:
        midnight = int(time.mktime(today.timetuple()))
        if midnight <= start:  # the window opened today: nothing complete yet
            usd = 0.0
        else:
            lo, hi = iso(start), iso(midnight)
            usd, seen = 0.0, set()
            for f in root.rglob("*.jsonl"):
                try:
                    if f.stat().st_mtime < start:
                        continue
                    fh = f.open(encoding="utf-8", errors="replace")
                except OSError:
                    continue
                with fh:
                    for line in fh:
                        # Cheap filters first: almost every line is a user
                        # message, a tool result or an attachment.
                        if '"usage"' not in line or '"assistant"' not in line:
                            continue
                        try:
                            d = json.loads(line)
                        except ValueError:
                            continue
                        ts = d.get("timestamp") or ""
                        if not (lo <= ts[:19] < hi):
                            continue
                        m = d.get("message") or {}
                        model = m.get("model") or ""
                        u = m.get("usage")
                        if not u or model == "<synthetic>":
                            continue
                        # Each content block of one response is its own line,
                        # carrying the same message id and the same usage.
                        mid = m.get("id") or d.get("requestId")
                        if mid in seen:
                            continue
                        seen.add(mid)
                        usd += cost(model, u)
        days = round((max(midnight, start) - start) / 86400, 1)
        tmp = out.with_name(out.name + f".tmp.{os.getpid()}")
        tmp.write_text(f"{key} {usd:.2f} {days}\n")
        tmp.replace(out)
    finally:
        try:
            lock.rmdir()
        except OSError:
            pass


if __name__ == "__main__":
    main()
