#!/bin/sh
# Minimal regression harness for claude/statusline-command.sh: feeds sample
# JSON payloads (what Claude Code hands the script on stdin) and asserts
# substrings in the rendered line, so the quota/park rendering is checked by
# an assertion instead of by eye. Not a general test framework -- just enough
# to keep the paused-on-quota segment (and the plain 5h segment next to it)
# from silently regressing.
#
# Runs in a throwaway $HOME so it never touches the real quota-park/cwd state
# under ~/.claude, and cleans up its /tmp state files (those are keyed by
# session_id and hardcoded to /tmp inside the script itself, HOME override or
# not -- see the "why /tmp and not $HOME" note in the script for cost/turn
# caching).
#
#   ./claude/test-statusline.sh
cd "$(dirname "$0")/.." || exit 2
SCRIPT="$PWD/claude/statusline-command.sh"

TMP=$(mktemp -d)
cleanup() {
  rm -rf "$TMP"
  rm -f /tmp/claude-statusline-*-statusline-test-*.txt 2>/dev/null
  rm -f /tmp/claude-turn-statusline-test-*.state 2>/dev/null
}
trap cleanup EXIT INT TERM
export HOME="$TMP"
mkdir -p "$HOME/.claude"

pass=0
fail=0

# strip_ansi + assert_contains "<label>" "<haystack>" "<needle>"
assert_contains() {
  label=$1; haystack=$2; needle=$3
  plain=$(printf '%s' "$haystack" | sed 's/\x1b\[[0-9;]*m//g')
  case "$plain" in
    *"$needle"*) pass=$((pass + 1)); printf 'ok    %s\n' "$label" ;;
    *)
      fail=$((fail + 1))
      printf 'FAIL  %s\n      expected to find: %s\n      got:              %s\n' \
        "$label" "$needle" "$plain"
      ;;
  esac
}

assert_not_contains() {
  label=$1; haystack=$2; needle=$3
  plain=$(printf '%s' "$haystack" | sed 's/\x1b\[[0-9;]*m//g')
  case "$plain" in
    *"$needle"*)
      fail=$((fail + 1))
      printf 'FAIL  %s\n      expected NOT to find: %s\n      got:                  %s\n' \
        "$label" "$needle" "$plain"
      ;;
    *) pass=$((pass + 1)); printf 'ok    %s\n' "$label" ;;
  esac
}

now=$(date +%s)
reset=$((now + 3 * 3600 + 23 * 60))   # 3h23m from now

# --- Case 1: normal 5h quota, this terminal NOT parked -----------------------
payload=$(cat <<JSON
{"session_id":"statusline-test-normal","model":{"display_name":"Claude Opus"},
 "context_window":{},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains    "normal: quota-left percentage"     "$out" "60%"
assert_contains    "normal: window countdown"           "$out" "3h2"
assert_not_contains "normal: no pause glyph when awake" "$out" "💤"

# --- Case 2: quota exhausted AND parked by quota-gate.sh ---------------------
session="statusline-test-parked"
wake=$((now + 45 * 60 + 12))          # 45m12s from now
mkdir -p "$HOME/.claude/quota-park"
printf '%s' "$wake" > "$HOME/.claude/quota-park/$session"
back=$(date -r "$wake" +%H:%M)
payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Claude Opus"},
 "context_window":{},
 "rate_limits":{"five_hour":{"used_percentage":98,"resets_at":$reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "parked: pause glyph present"        "$out" "💤"
assert_contains "parked: absolute local wake clock"  "$out" "$back"
assert_contains "parked: glyph glued to the percentage" "$out" "%💤"
assert_contains "parked: wake clock hangs off the window countdown" "$out" "→ $back"
assert_not_contains "parked: no second sleep countdown"  "$out" "45m"

# --- Case 3: a park marker whose wake time has ALREADY passed (stale/woken) --
# quota-gate.sh's own trap removes this file on exit, but the render must not
# show a pause state, whether the file lingers or not.
session="statusline-test-woken"
mkdir -p "$HOME/.claude/quota-park"
printf '%s' "$((now - 60))" > "$HOME/.claude/quota-park/$session"
payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Claude Opus"},
 "context_window":{},
 "rate_limits":{"five_hour":{"used_percentage":98,"resets_at":$reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_not_contains "woken: no pause glyph once wake time has passed" "$out" "💤"

# --- Case 4: weekly quota exhausted and parked by quota-gate.sh -------------
# Window-aware markers put the sleep state on the quota that caused it. The
# weekly probe clock includes a weekday so an hour crossing midnight is clear.
session="statusline-test-weekly-parked"
week_reset=$((now + 2 * 86400 + 47 * 60))
wake=$((week_reset + 12))
mkdir -p "$HOME/.claude/quota-park"
printf '%s seven_day' "$wake" > "$HOME/.claude/quota-park/$session"
back=$(date -r "$wake" '+%a %H:%M')
payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Claude Opus"},
 "context_window":{},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset},
                "seven_day":{"used_percentage":100,"resets_at":$week_reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "weekly parked: glyph glued to weekly percentage" "$out" "0%💤"
assert_contains "weekly parked: wake clock includes weekday"      "$out" "→ $back"
assert_not_contains "weekly parked: five-hour percentage stays awake" "$out" "60%💤"

# --- Case 5: a live weekly probe outranks a frozen session payload ----------
# Plan boosts can return allowance without changing the advertised reset. The
# status line must show the authenticated probe result for the same hour instead
# of the session's stale 101%-used payload.
session="statusline-test-weekly-probe"
printf '%s 0 %s' "$now" "$week_reset" > "$HOME/.claude/quota-weekly-probe"
payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Claude Opus"},
 "context_window":{},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset},
                "seven_day":{"used_percentage":101,"resets_at":$week_reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "weekly probe: live allowance replaces stale exhausted value" "$out" "100%"
assert_not_contains "weekly probe: stale negative percentage is gone" "$out" "-1%"

# A failed network attempt writes only its timestamp. That partial record is a
# retry throttle, not quota data, and must never replace the session percentage.
printf '%s' "$now" > "$HOME/.claude/quota-weekly-probe"
payload=$(cat <<JSON
{"session_id":"statusline-test-weekly-probe-failed","model":{"display_name":"Claude Opus"},
 "context_window":{},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset},
                "seven_day":{"used_percentage":25,"resets_at":$week_reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "weekly probe: timestamp-only failed probe is not quota data" "$out" "75%"

# --- Case: subagents in flight ----------------------------------------------
# Builds a session directory shaped like the one Claude Code writes -- a parent
# transcript plus <sid>/subagents/agent-<id>.{meta.json,jsonl} -- and checks the
# three judgements the chip has to make: who is still running, what each one is
# running on, and how the groups collapse.
session="statusline-test-subagents"
proj="$HOME/.claude/projects/test"
sub="$proj/$session/subagents"
mkdir -p "$sub"
tp="$proj/$session.jsonl"

# id / model / effort / requested-alias
mk_agent() {
  printf '{"agentType":"general-purpose","description":"t","toolUseId":"toolu_%s","spawnDepth":1,"model":"%s"}' \
    "$1" "$4" > "$sub/agent-$1.meta.json"
  printf '{"type":"user","isSidechain":true,"agentId":"%s","message":{"role":"user"}}\n{"type":"assistant","agentId":"%s","effort":"%s","message":{"role":"assistant","model":"%s"}}\n' \
    "$1" "$1" "$3" "$2" > "$sub/agent-$1.jsonl"
}
mk_agent A claude-opus-5              high   opus
mk_agent B claude-opus-5              high   opus
mk_agent C claude-sonnet-5            medium sonnet
mk_agent D claude-opus-5              high   opus
mk_agent E claude-haiku-4-5-20251001  high   haiku
mk_agent F claude-fable-5-1           high   fable
mk_agent G claude-opus-5              high   opus

{
  # The spawn itself: tool_use blocks carry the id as "id", never as
  # "tool_use_id", so none of these may read as a finished agent.
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_A","name":"Task"},{"type":"tool_use","id":"toolu_D","name":"Task"}]}}\n'
  # D returned; E was launched async in the SAME user turn. The launch receipt
  # must not be mistaken for D's result, nor D's result for E's.
  printf '{"type":"user","message":{"content":[{"tool_use_id":"toolu_D","type":"tool_result","content":"the report"},{"tool_use_id":"toolu_E","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully. agentId: E"}]}]}}\n'
  # F was launched async and has since notified that it stopped.
  printf '{"type":"user","message":{"content":[{"tool_use_id":"toolu_F","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully. agentId: F"}]}]}}\n'
  printf '{"type":"user","message":{"content":"<task-notification>\\n<task-id>F</task-id>\\n<tool-use-id>toolu_F</tool-use-id>\\n<status>completed</status>\\n</task-notification>"}}\n'
} > "$tp"

# G never got a marker but has been silent for hours: a corpse, not a worker.
touch -t 202001010000 "$sub/agent-G.jsonl"

payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Opus 5 (1M context)"},
 "effort":{"level":"high"},"transcript_path":"$tp",
 "context_window":{"used_percentage":6,"context_window_size":1000000},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains     "subagents: groups by model+effort, biggest first" "$out" "+{O5h*2,H4.5h,S5m}"
assert_contains     "subagents: chip hangs off the model segment"      "$out" "/1M +{"
assert_not_contains "subagents: a returned Task is gone"               "$out" "*3"
assert_not_contains "subagents: a notified async agent is gone"        "$out" "F5.1"
assert_not_contains "subagents: a silent corpse is not counted"        "$out" "*4"

# Second render, same state: the per-agent facts now come from the cache file
# rather than from re-reading seven agent transcripts. Same answer either way.
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "subagents: cached second render is identical" "$out" "+{O5h*2,H4.5h,S5m}"

# A session that never spawned anything renders no chip at all.
session="statusline-test-no-subagents"
tp="$proj/$session.jsonl"
printf '{"type":"assistant","message":{"content":[]}}\n' > "$tp"
payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Opus 5 (1M context)"},
 "effort":{"level":"high"},"transcript_path":"$tp",
 "context_window":{"used_percentage":6,"context_window_size":1000000},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_not_contains "no subagents: no chip, no placeholder" "$out" "+{"
assert_not_contains "no subagents: placeholder is resolved" "$out" "@@SUB@@"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
