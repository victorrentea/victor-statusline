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
trap 'rm -rf "$SB" /tmp/vsl-shot-8; rm -f /tmp/claude-statusline-*shot-*.txt /tmp/claude-turn-shot-*.state' EXIT INT TERM
mkdir -p "$OUT" "$SB/home/.claude" "$SB/home/.copilot"
export HOME="$SB/home"

S="$REPO/claude/statusline-command.sh"

# A repo off the trunk, so the location segment shows "<folder>@<branch>".
# The path is FIXED rather than inside $SB: the folder chip's background colour
# is hashed from the full path, so a fresh mktemp -d every run would repaint the
# chip a different colour in every regeneration of the pictures. This particular
# path hashes to entry 8 of the palette (navy on white), which is quiet enough
# to sit next to eleven annotation colours without shouting over them.
DEMO="/tmp/vsl-shot-8/victor-statusline"
rm -rf "$DEMO"
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
# Several things on this bar are animated off the wall clock -- the flower blooms
# through five frames, and an expensive cache miss BLINKS its colour on and off
# once a second. A single render therefore catches an arbitrary frame, and half
# of them are the "off" beat where the alarm is invisible. So each shot says
# which frame it is waiting for ($4, a shell glob, default the full-bloom
# flower) and we re-render once a second until that frame lands.
shoot() {
  # $4 is a FIXED string to wait for, matched with grep -F rather than a case
  # glob: the frames worth waiting for include ANSI colour codes such as
  # "[38;5;208m", and a ";" inside a case pattern ends the pattern.
  want=${4:-✻}
  # $5/$6 are the session totals of the two renders; their difference is the
  # turn price. Worth overriding for the cache-miss shot: "(2.7⏱)" has to be
  # part of the turn it hangs off, and a $2.70 rebuild inside a $0.50 turn is a
  # contradiction on its face -- exactly what the "⊂" relation forbids.
  c1=${5:-24.9}; c2=${6:-25.4}
  i=0
  while [ $i -lt 20 ]; do
    rm -f /tmp/claude-statusline-*shot-$2*.txt /tmp/claude-turn-shot-$2*.state
    $1 "$c1" | sh "$S" >/dev/null 2>&1
    out=$($1 "$c2" | sh "$S")
    if printf '%s' "$out" | grep -qF -- "$want"; then
      printf '%s' "$out" > "$OUT/$3.ansi"; return 0
    fi
    i=$((i + 1)); sleep 1
  done
  printf '%s' "$out" > "$OUT/$3.ansi"
  echo "warning: $3 never rendered a frame containing '$want'" >&2
}
shoot sub sub claude-subscription
shoot api api claude-apikey

# --- the same bar with a fan-out in flight -------------------------------
# The subagent chip is read off the files Claude Code writes next to the
# transcript, so this shot needs a session directory shaped like a real one:
# a parent transcript that SPAWNS three Task agents and never collects their
# results (so all three are still running), plus one meta.json + transcript
# per agent saying which model and effort it actually got.
proj="$HOME/.claude/projects/shots"
tp="$proj/shot-agents.jsonl"
agents="$proj/shot-agents/subagents"
mkdir -p "$agents"

# id / model / effort ("-" for a model that has none) / requested alias
mk_agent() {
  printf '{"agentType":"general-purpose","description":"t","toolUseId":"toolu_%s","spawnDepth":1,"model":"%s"}' \
    "$1" "$4" > "$agents/agent-$1.meta.json"
  eff=",\"effort\":\"$3\""
  [ "$3" = "-" ] && eff=""
  printf '{"type":"user","isSidechain":true,"agentId":"%s","message":{"role":"user"}}\n{"type":"assistant","agentId":"%s"%s,"message":{"role":"assistant","model":"%s"}}\n' \
    "$1" "$1" "$eff" "$2" > "$agents/agent-$1.jsonl"
}
mk_agent A claude-opus-5   high   opus
mk_agent B claude-opus-5   high   opus
mk_agent C claude-sonnet-5 medium sonnet

# stop_reason "tool_use" is what keeps the bar in its WORKING state, which is
# the only state a fan-out can be seen in: the flower animates and the turn
# price is live rather than a finished "-3m" figure.
{
  printf '{"type":"user","uuid":"u1","message":{"role":"user","content":"go"}}\n'
  printf '{"type":"assistant","uuid":"a1","requestId":"r1","message":{"role":"assistant","stop_reason":"tool_use","usage":{"input_tokens":120,"output_tokens":900,"cache_read_input_tokens":48000,"cache_creation_input_tokens":300},"content":[{"type":"tool_use","id":"toolu_A","name":"Task"},{"type":"tool_use","id":"toolu_B","name":"Task"},{"type":"tool_use","id":"toolu_C","name":"Task"}]}}\n'
} > "$tp"

agentsub() { printf '{"session_id":"shot-agents","model":{"display_name":"Opus 5 (1M context)"},"effort":{"level":"xhigh"},"transcript_path":"'"$tp"'","context_window":{"used_percentage":5,"context_window_size":1000000},"cost":{"total_cost_usd":%s},"workspace":{"current_dir":"'"$DEMO"'"},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":'"$rs"'},"seven_day":{"used_percentage":30,"resets_at":'"$wr"'}}}' "$1"; }
shoot agentsub agents claude-subagents

# --- the prompt-cache clock, in all four of its states --------------------
# This is the part of the bar whose whole job is to stop you burning money by
# accident, so it gets its own picture. Everything it says is derived from the
# transcript: WHICH TTL the session is caching at (the API reports which
# ephemeral bucket each cache write landed in), HOW LONG ago the last response
# was, and WHETHER the current turn actually read the cached prefix back.
#
# So a shot is fully specified by three numbers -- the age to fake, the prompt
# size that was sitting in the cache, and how much of it this turn read back.
# Write a transcript saying that and the bar computes every figure itself.
cache_transcript() {   # 1=path 2=age_secs 3=prev_prompt 4=cache_read_now 5=stop_reason
  python3 - "$@" <<'PYCACHE'
import datetime, json, sys
path, age, prev, cr, stop = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
now = datetime.datetime.now(datetime.timezone.utc)
def ts(sec_ago):
    return (now - datetime.timedelta(seconds=sec_ago)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
rows = [
    # The turn BEFORE this one. Its total prompt size is the prefix that was
    # sitting in the cache, and the 1h bucket in its cache_creation is how the
    # session tells the bar it is caching at an hour rather than five minutes.
    {"type": "user", "uuid": "u0", "message": {"role": "user", "content": "earlier"}},
    {"type": "assistant", "uuid": "a0", "requestId": "r0", "timestamp": ts(age + 600),
     "message": {"role": "assistant", "stop_reason": "end_turn", "content": [],
                 "usage": {"input_tokens": 200, "output_tokens": 900,
                           "cache_read_input_tokens": prev - 1000,
                           "cache_creation_input_tokens": 800,
                           "cache_creation": {"ephemeral_5m_input_tokens": 0,
                                              "ephemeral_1h_input_tokens": 250000}}}},
    # The current turn. cache_read_input_tokens on THIS first request is the
    # whole verdict: near `prev` means the prefix survived, near zero means it
    # had to be rebuilt from scratch and this turn paid for it.
    {"type": "user", "uuid": "u1", "message": {"role": "user", "content": "now"}},
    {"type": "assistant", "uuid": "a1", "requestId": "r1", "timestamp": ts(age),
     "message": {"role": "assistant", "stop_reason": stop, "content": [],
                 "usage": {"input_tokens": 300, "output_tokens": 1200,
                           "cache_read_input_tokens": cr,
                           "cache_creation_input_tokens": max(0, prev - cr),
                           "cache_creation": {"ephemeral_5m_input_tokens": 0,
                                              "ephemeral_1h_input_tokens": 280000}}}},
]
with open(path, "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PYCACHE
}

ctp="$proj/shot-cache.jsonl"
# 30% of a 1M window = 300K of live context, which at Opus's input rate and a
# 1-hour TTL is what the "(miss=$...)" figure is pricing.
cachepay() { printf '{"session_id":"shot-cache","model":{"display_name":"Opus 5 (1M context)"},"effort":{"level":"xhigh"},"transcript_path":"'"$ctp"'","context_window":{"used_percentage":30,"context_window_size":1000000},"cost":{"total_cost_usd":%s},"workspace":{"current_dir":"'"$DEMO"'"},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":'"$rs"'},"seven_day":{"used_percentage":30,"resets_at":'"$wr"'}}}' "$1"; }

# 1. warm -- 12 min into a 1-hour cache, prefix fully read back. Nothing at stake.
cache_transcript "$ctp" 720 300000 300000 end_turn
shoot cachepay cache cache-warm '-12m'
# 2. expiring -- 52 min in, past 0.8 x TTL. The prefix is still alive and the bar
#    prices what losing it would cost: a deadline WITH a stake attached.
cache_transcript "$ctp" 3120 300000 300000 end_turn
shoot cachepay cache cache-expiring '[38;5;208m'
# 3. expired -- over the hour. The exact age stops mattering, so it collapses to ">1h".
cache_transcript "$ctp" 5400 300000 300000 end_turn
shoot cachepay cache cache-expired '[31m'
# 4. the post-mortem -- a turn that has ALREADY paid the rebuild: still working,
#    and its first request read back none of the 280K that had been cached.
cache_transcript "$ctp" 20 280000 0 tool_use
# The miss verdict is deterministic for this transcript, so the only thing that
# varies between renders is the flower frame -- wait for the full bloom, as
# everywhere else, and the row is reproducible.
shoot cachepay cache cache-miss '✻' 30.0 35.2

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
