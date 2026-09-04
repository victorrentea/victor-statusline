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
# weekly clock includes a weekday because this pause can span several days.
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

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
