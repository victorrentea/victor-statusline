#!/bin/sh
# Renders the three sample status lines used by the README screenshots, as raw
# ANSI, into docs/screenshots/lines/*.ansi.
#
# Everything is synthetic on purpose: the payloads are hand-written, $HOME is a
# throwaway directory and the "repo" the location segment reports is a temp
# git init. So the published pictures leak no real quota, spend or paths, and
# the same figures come out every time -- which is what makes them safe to
# document field by field in render.py.
#
#   ./docs/screenshots/make-lines.sh   &&   python3 docs/screenshots/render.py
set -e
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$REPO/docs/screenshots/lines"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"; rm -f /tmp/claude-statusline-*shot-*.txt /tmp/claude-turn-shot-*.state' EXIT INT TERM
mkdir -p "$OUT" "$SB/home/.claude" "$SB/home/.copilot"
export HOME="$SB/home"

S="$REPO/claude/statusline-command.sh"

# A repo off the trunk, so the location segment shows "<folder>@<branch>".
DEMO="$SB/demo/victor-statusline"
mkdir -p "$DEMO"
git -C "$DEMO" init -q -b fix-cache
git -C "$DEMO" -c user.email=x@y -c user.name=x commit -q --allow-empty -m init

now=$(date +%s); rs=$((now + 12000)); wr=$((now + 220000))

# Same session in both cases; the only difference is that a subscription payload
# carries `rate_limits` and an API-key one does not -- which is exactly the
# difference the two pictures are there to show.
sub() { printf '{"session_id":"shot-sub","model":{"display_name":"Opus 5 (1M context)"},"effort":{"level":"xhigh"},"context_window":{"used_percentage":5,"context_window_size":1000000},"cost":{"total_cost_usd":%s},"workspace":{"current_dir":"'"$DEMO"'"},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":'"$rs"'},"seven_day":{"used_percentage":30,"resets_at":'"$wr"'}}}' "$1"; }
api() { printf '{"session_id":"shot-api","model":{"display_name":"Opus 5 (1M context)"},"effort":{"level":"xhigh"},"context_window":{"used_percentage":5,"context_window_size":1000000},"cost":{"total_cost_usd":%s},"workspace":{"current_dir":"'"$DEMO"'"}}' "$1"; }

# Two renders, not one: the turn price is a DELTA between consecutive renders of
# `.cost.total_cost_usd`, so a single render can only ever show $0.00 for the turn.
# The flower is animated off the wall clock, so retry until the full-bloom frame.
shoot() {
  i=0
  while [ $i -lt 20 ]; do
    rm -f /tmp/claude-statusline-*shot-$2*.txt /tmp/claude-turn-shot-$2*.state
    $1 24.9 | sh "$S" >/dev/null 2>&1
    out=$($1 25.4 | sh "$S")
    case "$out" in *✻*) printf '%s' "$out" > "$OUT/$3.ansi"; return 0 ;; esac
    i=$((i + 1)); sleep 1
  done
  printf '%s' "$out" > "$OUT/$3.ansi"
  echo "warning: $3 did not catch the full-bloom flower frame" >&2
}
shoot sub sub claude-subscription
shoot api api claude-apikey

# Copilot reads its credit figures from a cache that quota-refresh.sh normally
# fills from `gh api copilot_internal/user`; we write a synthetic one instead.
python3 - "$HOME/.copilot/quota-cache.json" <<'PY'
import json, sys, datetime
reset = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=9)
         ).replace(hour=0, minute=0, second=0, microsecond=0)
json.dump({
    "quota_snapshots": {"premium_interactions": {
        "entitlement": 20000, "remaining": 6759.0, "credits_used": 13241.0,
        "percent_remaining": 33.8, "unlimited": False, "has_quota": True}},
    "reset_utc": reset.isoformat().replace("+00:00", "Z"),
    "today_credits": 257.0,
    "today_credits_date": datetime.datetime.now().strftime("%Y-%m-%d"),
}, open(sys.argv[1], "w"))
PY
printf '{"display_name":"claude-sonnet-5 · medium · 264K context","current_context_tokens":55000,"displayed_context_limit":264000}' \
  | bash "$REPO/copilot/statusline.sh" | tr -d '\n' > "$OUT/copilot.ansi"

for f in "$OUT"/*.ansi; do
  printf '%-28s %s\n' "$(basename "$f")" "$(sed 's/\x1b\[[0-9;]*m//g' "$f")"
done
