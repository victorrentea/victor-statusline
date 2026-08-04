#!/usr/bin/env bash
# Fetch the user's Copilot quota snapshot into a small cache file that
# statusline.sh reads. Called detached (in the background) by statusline.sh, but
# safe to run standalone:  bash quota-refresh.sh [cache-path]
#
# Two sources are merged into the cache:
#   • `copilot_internal/user` — the undocumented endpoint the Copilot CLI itself
#     uses for its footer budget: monthly entitlement, remaining, reset date.
#   • `/users/{login}/settings/billing/premium_request/usage?year&month&day` —
#     the only endpoint with a per-DAY breakdown, used for "burned today".
#     Needs the `user` OAuth scope (gh auth refresh -h github.com -s user); when
#     it is missing we fall back to a locally tracked day baseline (see below).
#
# Field names of the internal endpoint are undocumented and may change.
# We store only quota-relevant fields (no account identifiers).
set -u
CACHE="${1:-$HOME/.copilot/quota-cache.json}"
command -v gh >/dev/null 2>&1 || exit 0

tmp="$CACHE.$$.tmp"
gh api copilot_internal/user \
  --jq '{plan: .copilot_plan, reset_utc: .quota_reset_date_utc, reset_date: .quota_reset_date, quota_snapshots: .quota_snapshots}' \
  >"$tmp" 2>/dev/null
[ -s "$tmp" ] || { rm -f "$tmp" 2>/dev/null; exit 0; }

# --- credits burned today (local calendar day) ----------------------------
login=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["lastLoggedInUser"]["login"])' \
          "$HOME/.copilot/config.json" 2>/dev/null)
[ -n "$login" ] || login=$(gh api user --jq .login 2>/dev/null)

today=$(date +%Y-%m-%d)
today_credits=""
if [ -n "$login" ]; then
  # grossAmount is in dollars at $0.01/credit, so ×100 gives credits.
  today_credits=$(gh api -X GET "/users/$login/settings/billing/premium_request/usage" \
      -f "year=$(date +%Y)" -f "month=$(date +%-m)" -f "day=$(date +%-d)" \
      --jq '[.usageItems[]? | select(.product == "Copilot") | .grossAmount] | add // 0 | . * 100' \
      2>/dev/null)
fi

# Merge: add today's burn plus a day baseline (month-to-date credits at the first
# refresh of the day) so the statusline can still derive "burned today" by
# subtraction when the billing endpoint is unavailable.
python3 - "$CACHE" "$tmp" "$today" "$today_credits" <<'PY'
import json, os, sys

cache_path, tmp_path, today, today_credits = sys.argv[1:5]

with open(tmp_path) as f:
    fresh = json.load(f)

prev = {}
if os.path.exists(cache_path):
    try:
        with open(cache_path) as f:
            prev = json.load(f)
    except Exception:
        prev = {}

snap = (fresh.get("quota_snapshots") or {}).get("premium_interactions") or {}
month_used = snap.get("credits_used")

# The baseline is captured once per day and then frozen, so the fallback
# ("month-to-date now" minus "month-to-date at day start") resets every midnight.
base = prev.get("day_baseline") or {}
if base.get("date") != today or month_used is None:
    base = {"date": today, "month_used_at_start": month_used}
fresh["day_baseline"] = base

if today_credits.strip():
    try:
        fresh["today_credits"] = round(float(today_credits), 1)
        fresh["today_credits_date"] = today
    except ValueError:
        pass

with open(tmp_path, "w") as f:
    json.dump(fresh, f)
PY

mv "$tmp" "$CACHE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
