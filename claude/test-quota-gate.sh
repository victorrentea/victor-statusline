#!/bin/sh
# Regression harness for the request gate. It runs the real hook against a
# throwaway Claude home, observes the marker written before sleep, then kills
# only the test-owned sleeper so no test waits for an actual quota reset.
cd "$(dirname "$0")/.." || exit 2
GATE="$PWD/claude/hooks/quota-gate.sh"
STATE="$PWD/claude/hooks/quota-state.sh"

TMP=$(mktemp -d)
gate_pid=""
stop_gate() {
  if [ -n "$gate_pid" ]; then
    # The hook shell is waiting on sleep. Stop that child first so the shell can
    # run its EXIT trap and remove the marker instead of leaving an orphan.
    if ! pkill -TERM -P "$gate_pid" 2>/dev/null; then
      kill "$gate_pid" 2>/dev/null || true
    fi
    wait "$gate_pid" 2>/dev/null || true
    gate_pid=""
  fi
}
cleanup() {
  stop_gate
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM
export HOME="$TMP"
mkdir -p "$HOME/.claude/hooks"
ln -s "$STATE" "$HOME/.claude/hooks/quota-state.sh"

pass=0
fail=0

assert_eq() {
  label=$1 actual=$2 expected=$3
  if [ "$actual" = "$expected" ]; then
    pass=$((pass + 1)); printf 'ok    %s\n' "$label"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n      expected: %s\n      got:      %s\n' \
      "$label" "$expected" "$actual"
  fi
}

write_state() {
  jq -n --argjson u5 "$1" --argjson r5 "$2" --argjson m5 "$3" \
        --argjson u7 "$4" --argjson r7 "$5" --argjson m7 "$6" \
    '{five_hour:{used:$u5,resets_at:$r5,measured_at:$m5},
      seven_day:{used:$u7,resets_at:$r7,measured_at:$m7}}' \
    > "$HOME/.claude/quota.json"
}

wait_for_marker() {
  marker=$1
  tries=0
  while [ ! -f "$marker" ] && [ "$tries" -lt 50 ]; do
    sleep 0.02
    tries=$((tries + 1))
  done
}

now=$(date +%s)
five_reset=$((now + 1800))
week_reset=$((now + 7200))

# Weekly quota at exactly 1% left must park even though the 5h window is healthy.
session=quota-gate-test-weekly
write_state 88 "$five_reset" "$now" 99 "$week_reset" "$((now - 3600))"
printf '{"session_id":"%s"}' "$session" \
  | CLAUDE_QUOTA_JITTER=0 CLAUDE_QUOTA_WAKE_BUFFER=0 sh "$GATE" \
      >/dev/null 2>&1 &
gate_pid=$!
marker="$HOME/.claude/quota-park/$session"
wait_for_marker "$marker"
contents=$(sed -n '1p' "$marker" 2>/dev/null)
assert_eq "weekly: one percent left parks on the seven-day window" \
  "$contents" "$week_reset seven_day"
stop_gate

# The existing 5h path remains active at 4% left (its strict <5 rule).
session=quota-gate-test-five-hour
write_state 96 "$five_reset" "$now" 98 "$week_reset" "$now"
printf '{"session_id":"%s"}' "$session" \
  | CLAUDE_QUOTA_JITTER=0 CLAUDE_QUOTA_WAKE_BUFFER=0 sh "$GATE" \
      >/dev/null 2>&1 &
gate_pid=$!
marker="$HOME/.claude/quota-park/$session"
wait_for_marker "$marker"
contents=$(sed -n '1p' "$marker" 2>/dev/null)
assert_eq "five-hour: existing low-quota path still parks" \
  "$contents" "$five_reset five_hour"
stop_gate

# If both limits are exhausted, waking at the earlier reset would still 429.
session=quota-gate-test-both
write_state 96 "$five_reset" "$now" 99 "$week_reset" "$now"
printf '{"session_id":"%s"}' "$session" \
  | CLAUDE_QUOTA_JITTER=0 CLAUDE_QUOTA_WAKE_BUFFER=0 sh "$GATE" \
      >/dev/null 2>&1 &
gate_pid=$!
marker="$HOME/.claude/quota-park/$session"
wait_for_marker "$marker"
contents=$(sed -n '1p' "$marker" 2>/dev/null)
assert_eq "both: later weekly reset is the limiting window" \
  "$contents" "$week_reset seven_day"
stop_gate

# Two percent left is above the weekly threshold and must not pause work.
session=quota-gate-test-weekly-above-threshold
write_state 88 "$five_reset" "$now" 98 "$week_reset" "$now"
printf '{"session_id":"%s"}' "$session" \
  | CLAUDE_QUOTA_JITTER=0 CLAUDE_QUOTA_WAKE_BUFFER=0 sh "$GATE"
if [ ! -f "$HOME/.claude/quota-park/$session" ]; then
  pass=$((pass + 1)); printf 'ok    weekly: two percent left stays awake\n'
else
  fail=$((fail + 1)); printf 'FAIL  weekly: two percent left stays awake\n'
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
