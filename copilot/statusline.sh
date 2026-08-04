#!/usr/bin/env bash
# Copilot CLI status line. Example output:
#   🤖 sonnet-5/med 55K/264K (21%) | 74%↗ (257/345 AIC) left today | +3% = 95% (6646 AIC) left / 20wd7h
#
#   • model: display_name with the "claude-" prefix stripped, the reasoning
#     effort abbreviated after a "/" (medium→med, xhigh, max…) and the
#     " · N context" tail replaced by "<used>/<limit>" context tokens (used
#     count coloured yellow ≥65% / red ≥95%; % hidden when the window is 1M).
#   • today: share of today's budget already burned + (burned/budget AIC), where
#     the budget is simply "credits left at the start of today ÷ working days
#     left until the reset". Because it is recomputed from the CURRENT balance
#     every day, overshooting or undershooting today never carries a debt —
#     tomorrow just gets a smaller or larger slice, and the plan still lands on
#     0 exactly at the reset. The arrow compares the share of the budget spent
#     against the share of the WORKING DAY (09:00–18:00 local) elapsed, so it
#     says "am I burning faster than the clock" (↑↗ green ahead / none on-track
#     / ↘ yellow / ↓ red too fast).
#   • AI Credits: a signed RESERVE in percentage points ("how much of the month's
#     entitlement I still have beyond what I should have left by now", i.e.
#     working-time elapsed − credits burned), then the remaining % and credits,
#     then the WORKING days + hours until the monthly quota resets. Signed number
#     rather than an arrow so it reads in the same unit as the "% left" beside it
#     — mirrors the weekly segment of victor-claude-statusline.md.
#
# Copilot CLI pipes the session status as JSON on stdin; we print one line to
# stdout. The monthly AI-Credit balance and reset date are NOT in that payload,
# so they come from a small cache refreshed in the background by quota-refresh.sh
# from `gh api copilot_internal/user`. See victor-copilot-statusline.md.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
CACHE="$HOME/.copilot/quota-cache.json"
TTL=60    # refresh the quota cache at most once per minute (keeps AIC current)

INPUT="$(cat 2>/dev/null)"

# --- refresh the monthly-quota cache in the background when stale (non-blocking) --
now=$(date +%s 2>/dev/null || echo 0)
file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
cmtime=0; [ -f "$CACHE" ] && cmtime=$(file_mtime "$CACHE")
lock="$CACHE.lock"; lmtime=0; [ -f "$lock" ] && lmtime=$(file_mtime "$lock")
if [ "$(( now - cmtime ))" -ge "$TTL" ] && [ "$(( now - lmtime ))" -ge "$TTL" ]; then
  : > "$lock" 2>/dev/null || true           # stampede guard: one refresh per TTL
  [ -f "$DIR/quota-refresh.sh" ] && nohup bash "$DIR/quota-refresh.sh" "$CACHE" >/dev/null 2>&1 &
fi

python3 - "$INPUT" "$CACHE" <<'PY'
import sys, json

raw   = sys.argv[1] if len(sys.argv) > 1 else ""
cache = sys.argv[2] if len(sys.argv) > 2 else ""
try:
    d = json.loads(raw) if raw.strip() else {}
except Exception:
    print("🤖 copilot"); sys.exit(0)

def find(obj, *names):
    """First value (by NAME priority) for any of `names`, searched recursively."""
    for name in names:
        stack = [obj]
        while stack:
            cur = stack.pop()
            if isinstance(cur, dict):
                if name in cur and not isinstance(cur[name], (dict, list)):
                    return cur[name]
                stack.extend(cur.values())
            elif isinstance(cur, list):
                stack.extend(cur)
    return None

def human(n):
    try: n = float(n)
    except (TypeError, ValueError): return None
    if n >= 1_000_000: return f"{n/1_000_000:.0f}M" if n % 1_000_000 == 0 else f"{n/1_000_000:.1f}M"
    if n >= 1_000:     return f"{n/1_000:.0f}K"
    return f"{n:.0f}"

# ANSI colours (used-token count, pace arrow, reserve) — mirrors victor-claude-statusline.md
CLR_RESET = "\033[0m"
CLR_RED   = "\033[31m"
CLR_YEL   = "\033[38;5;208m"
CLR_GRN   = "\033[38;5;78m"

parts = []

# --- model/effort context-usage ------------------------------------------
# display_name looks like "claude-sonnet-5 · medium · 264K context"; we strip
# the "claude-" prefix, abbreviate the effort onto the name with a "/", and
# replace the " · <N> context" tail with used/limit tokens. The whole segment
# is one glance's worth of "which brain, how hard, how full".
EFFORT_SHORT = {"minimal": "min", "min": "min", "low": "low",
                "medium": "med", "med": "med", "high": "high",
                "xhigh": "xhigh", "x-high": "xhigh", "extra high": "xhigh",
                "very high": "xhigh", "max": "max", "maximum": "max"}

model = find(d, "display_name", "displayName") or find(d, "id", "model") or "copilot"
if isinstance(model, str):
    if model.lower().startswith("claude-"):
        model = model[len("claude-"):]
    bits = [p.strip() for p in model.split(" · ") if "context" not in p.lower()]
    label = bits[0] if bits else "copilot"
    if len(bits) > 1 and bits[1]:
        label += "/" + EFFORT_SHORT.get(bits[1].lower(), bits[1])
    used  = find(d, "current_context_tokens", "currentContextTokens")
    limit = find(d, "displayed_context_limit", "displayedContextLimit",
                 "context_window_size", "contextWindowSize")
    if used is not None and limit is not None:
        try: upct = 100.0 * float(used) / float(limit)
        except (TypeError, ValueError, ZeroDivisionError): upct = None
        used_lbl = human(used)
        if upct is not None:            # colour the used-token count as the window fills
            if   upct >= 95: used_lbl = f"{CLR_RED}{used_lbl}{CLR_RESET}"
            elif upct >= 65: used_lbl = f"{CLR_YEL}{used_lbl}{CLR_RESET}"
        ctx = f"{used_lbl}/{human(limit)}"
        if human(limit) != "1M" and upct is not None:  # show % only when window isn't the full 1M
            ctx += f" ({upct:.0f}%)"
        label = f"{label} {ctx}"
    model = label
parts.append(f"🤖 {model}")

# --- AI Credits remaining, reserve, working-days to reset ------------------
q = {}
try:
    with open(cache) as f:
        q = json.load(f)
except Exception:
    q = {}

from datetime import datetime, timezone, timedelta

reset = q.get("reset_utc") or q.get("reset_date")
reset_dt = None
if reset:
    try:
        reset_dt = datetime.fromisoformat(str(reset).replace("Z", "+00:00"))
        if reset_dt.tzinfo is None:
            reset_dt = reset_dt.replace(tzinfo=timezone.utc)
    except Exception:
        reset_dt = None

def working_seconds(a, b):
    """Seconds in [a, b) that fall on weekdays (Sat/Sun excluded)."""
    total, cur = 0.0, a
    while cur < b:
        nxt = datetime(cur.year, cur.month, cur.day, tzinfo=timezone.utc) + timedelta(days=1)
        seg = min(nxt, b)
        if cur.weekday() < 5:
            total += (seg - cur).total_seconds()
        cur = seg
    return total

def working_days_left(now_local, reset_local_date):
    """Weekdays from today (inclusive) up to the reset date (exclusive)."""
    day, n = now_local.date(), 0
    while day < reset_local_date:
        if day.weekday() < 5:
            n += 1
        day += timedelta(days=1)
    return n

def pace_arrow(ratio):
    """Arrow for 'budget share left' ÷ 'time share left' — >1 means ahead."""
    if   ratio >= 1.5:  return f"{CLR_GRN}↑{CLR_RESET}"
    elif ratio >= 1.15: return f"{CLR_GRN}↗{CLR_RESET}"
    elif ratio >= 0.87: return ""
    elif ratio >= 0.67: return f"{CLR_YEL}↘{CLR_RESET}"
    return f"{CLR_RED}↓{CLR_RESET}"

snaps = q.get("quota_snapshots") or {}
snap = snaps.get("premium_interactions")
if not snap:
    for s in snaps.values():
        if isinstance(s, dict) and s.get("has_quota") and not s.get("unlimited") \
           and (s.get("entitlement") or 0) > 0:
            snap = s
            break

# --- credits burned today vs today's slice of what's left -----------------
# Today's usage comes from the per-day billing endpoint (cached by
# quota-refresh.sh); if that endpoint is unavailable we fall back to the
# month-to-date delta since the first refresh of the day.
WORK_START, WORK_END = 9, 18          # local working hours driving the pace arrow

lnow = datetime.now().astimezone()
today_str = lnow.strftime("%Y-%m-%d")
today_used = None
if isinstance(snap, dict) and not snap.get("unlimited"):
    if q.get("today_credits") is not None and q.get("today_credits_date") == today_str:
        today_used = float(q["today_credits"])
    else:
        base = q.get("day_baseline") or {}
        if base.get("date") == today_str and base.get("month_used_at_start") is not None \
           and snap.get("credits_used") is not None:
            today_used = max(0.0, float(snap["credits_used"]) - float(base["month_used_at_start"]))

if today_used is not None:
    seg = f"{today_used:.0f} AIC today"
    rem = snap.get("remaining")
    wdl = working_days_left(lnow, reset_dt.astimezone().date()) if reset_dt else 0
    # On a weekend there is no daily budget to measure against — just the raw burn.
    if wdl > 0 and rem is not None and lnow.weekday() < 5:
        budget = (float(rem) + today_used) / wdl
        if budget > 0:
            frac = today_used / budget
            pct = f"{frac * 100:.0f}%"
            if   frac >= 1.0:  pct = f"{CLR_RED}{pct}{CLR_RESET}"
            elif frac >= 0.85: pct = f"{CLR_YEL}{pct}{CLR_RESET}"
            start = lnow.replace(hour=WORK_START, minute=0, second=0, microsecond=0)
            end   = lnow.replace(hour=WORK_END,   minute=0, second=0, microsecond=0)
            elapsed = (lnow - start).total_seconds() / max(1.0, (end - start).total_seconds())
            elapsed = min(1.0, max(0.0, elapsed))
            # Ahead of the clock => spent a smaller share of the budget than of the day.
            arrow = pace_arrow(99.0 if frac <= 0 else elapsed / frac)
            # Percentage first, absolutes in parentheses: the share is the glance,
            # the raw credits are the detail you read second.
            seg = f"{pct}{arrow} ({today_used:.0f}/{budget:.0f} AIC) left today"
    parts.append(seg)

# --- working days + hours until the reset (weekends excluded) -------------
time_left = ""
if reset_dt:
    now  = datetime.now(timezone.utc)
    secs = int((reset_dt - now).total_seconds())
    if secs > 0:
        hh = (secs % 86400) // 3600
        wd = working_days_left(lnow, reset_dt.astimezone().date())
        time_left = f"{wd}wd{hh}h" if wd else f"{hh}h"

if isinstance(snap, dict):
    if snap.get("unlimited"):
        seg = "∞ AIC left"
    else:
        rem = snap.get("remaining")
        pr  = snap.get("percent_remaining")
        seg = f"{pr:.0f}% " if pr is not None else ""
        seg += f"({int(rem)} AIC) left" if rem is not None else "AIC left"
        # RESERVE, in percentage points: working time already elapsed in the
        # billing period minus credits already burned. "+3%" = I am three points
        # of the monthly entitlement richer than the calendar says I should be.
        # A point-difference (not a ratio) because it stays readable at both ends
        # of the month, and because it compares directly with the "% left" next to it.
        now = datetime.now(timezone.utc)
        if pr is not None and reset_dt and reset_dt > now:
            ps = datetime(reset_dt.year if reset_dt.month > 1 else reset_dt.year - 1,
                          reset_dt.month - 1 if reset_dt.month > 1 else 12, 1,
                          tzinfo=timezone.utc)
            total_w, left_w = working_seconds(ps, reset_dt), working_seconds(now, reset_dt)
            if total_w > 0:
                delta = round(100.0 * (total_w - left_w) / total_w - (100.0 - pr))
                if   delta > 0: res = f"{CLR_GRN}+{delta:.0f}%{CLR_RESET}"
                elif delta == 0: res = "0%"
                elif delta > -10: res = f"{CLR_YEL}{delta:.0f}%{CLR_RESET}"
                else: res = f"{CLR_RED}{delta:.0f}%{CLR_RESET}"
                seg = f"{res} = {seg}"
    if time_left:
        seg = f"{seg} / {time_left}"
    parts.append(seg)
elif time_left:
    parts.append(f"resets in {time_left}")

print(" | ".join(parts))
PY
