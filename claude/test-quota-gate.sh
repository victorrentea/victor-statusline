#!/bin/sh
# Regression harness for the request gate. It runs the real hook against a
# throwaway Claude home, observes the marker written before sleep, then kills
# only the test-owned sleeper so no test waits for an actual quota reset.
cd "$(dirname "$0")/.." || exit 2
GATE="$PWD/claude/hooks/quota-gate.sh"
STATE="$PWD/claude/hooks/quota-state.sh"
PROBE_SH="$PWD/claude/hooks/quota-probe.sh"

TMP=$(mktemp -d)
gate_pid=""
stop_gate() {
  if [ -n "$gate_pid" ]; then
    # The hook shell is waiting on sleep. Stop that child first so the shell can
    # run its EXIT trap and remove the marker instead of leaving an orphan.
    pkill -TERM -P "$gate_pid" 2>/dev/null || true
    kill -TERM "$gate_pid" 2>/dev/null || true
    tries=0
    while kill -0 "$gate_pid" 2>/dev/null && [ "$tries" -lt 50 ]; do
      sleep 0.02
      tries=$((tries + 1))
    done
    if kill -0 "$gate_pid" 2>/dev/null; then
      fail=$((fail + 1)); printf 'FAIL  interrupt: parked gate did not stop on TERM\n'
      pkill -KILL -P "$gate_pid" 2>/dev/null || true
      kill -KILL "$gate_pid" 2>/dev/null || true
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
ln -s "$PROBE_SH" "$HOME/.claude/hooks/quota-probe.sh"

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

assert_between() {
  label=$1 actual=$2 minimum=$3 maximum=$4
  if [ "$actual" -ge "$minimum" ] 2>/dev/null && [ "$actual" -le "$maximum" ] 2>/dev/null; then
    pass=$((pass + 1)); printf 'ok    %s\n' "$label"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n      expected: %s..%s\n      got:      %s\n' \
      "$label" "$minimum" "$maximum" "$actual"
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

line_count() {
  [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0
}

# Stands in for the usage endpoint: prints "u5 r5 u7 r7" the way quota-probe.sh
# expects. The 5h pair defaults to "-1 0", i.e. unknown, which `set` keeps
# stored -- these tests are about the weekly window.
probe="$TMP/weekly-probe.sh"
printf '#!/bin/sh\nprintf "called\\n" >> "$CLAUDE_TEST_PROBE_CALLS"\nprintf "%%s %%s %%s %%s\\n" "${CLAUDE_TEST_PROBE_USED5:--1}" "${CLAUDE_TEST_PROBE_RESET5:-0}" "$CLAUDE_TEST_PROBE_USED" "$CLAUDE_TEST_PROBE_RESET"\n' > "$probe"
chmod +x "$probe"

now=$(date +%s)
five_reset=$((now + 1800))
week_reset=$((now + 7200))

# The default retry cadence is deliberately short enough to notice an account
# upgrade without leaving every Claude request parked for the rest of an hour.
session=quota-gate-test-default-probe-cadence
probe_calls="$TMP/weekly-default-probe.calls"
write_state 88 "$five_reset" "$now" 99 "$week_reset" "$now"
printf '{"session_id":"%s"}' "$session" \
  | env -u CLAUDE_QUOTA_PROBE_SECS -u CLAUDE_WEEKLY_QUOTA_PROBE_SECS \
      CLAUDE_QUOTA_JITTER=0 CLAUDE_QUOTA_WAKE_BUFFER=0 \
      CLAUDE_QUOTA_PROBE_FILE="$TMP/weekly-default-probe.stamp" \
      CLAUDE_WEEKLY_QUOTA_PROBE_COMMAND="$probe" \
      CLAUDE_TEST_PROBE_CALLS="$probe_calls" \
      CLAUDE_TEST_PROBE_USED=99 CLAUDE_TEST_PROBE_RESET="$week_reset" sh "$GATE" \
      >/dev/null 2>&1 &
gate_pid=$!
marker="$HOME/.claude/quota-park/$session"
wait_for_marker "$marker"
contents=$(sed -n '1p' "$marker" 2>/dev/null)
default_wake=$(printf '%s' "$contents" | cut -d' ' -f1)
assert_between "weekly: default live probe cadence is five minutes" \
  "$default_wake" "$((now + 299))" "$((now + 305))"
stop_gate

# An explicit hourly override remains supported: weekly quota at exactly 1%
# left parks only until that configured probe, not the advertised reset.
session=quota-gate-test-weekly
probe_calls="$TMP/weekly-first-probe.calls"
write_state 88 "$five_reset" "$now" 99 "$week_reset" "$now"
printf '{"session_id":"%s"}' "$session" \
  | CLAUDE_QUOTA_JITTER=0 CLAUDE_QUOTA_WAKE_BUFFER=0 \
      CLAUDE_WEEKLY_QUOTA_PROBE_SECS=3600 \
      CLAUDE_QUOTA_PROBE_FILE="$TMP/weekly-first-probe.stamp" \
      CLAUDE_WEEKLY_QUOTA_PROBE_COMMAND="$probe" \
      CLAUDE_TEST_PROBE_CALLS="$probe_calls" \
      CLAUDE_TEST_PROBE_USED=99 CLAUDE_TEST_PROBE_RESET="$week_reset" sh "$GATE" \
      >/dev/null 2>&1 &
gate_pid=$!
marker="$HOME/.claude/quota-park/$session"
wait_for_marker "$marker"
contents=$(sed -n '1p' "$marker" 2>/dev/null)
weekly_wake=$(printf '%s' "$contents" | cut -d' ' -f1)
weekly_window=$(printf '%s' "$contents" | cut -d' ' -f2)
assert_eq "weekly: one percent left parks on the seven-day window" \
  "$weekly_window" "seven_day"
assert_between "weekly: configured hourly probe sets the park deadline" \
  "$weekly_wake" "$((now + 3599))" "$((now + 3605))"
assert_eq "weekly: no prior real probe means probe immediately" \
  "$(line_count "$probe_calls")" "1"
stop_gate

# A live probe can discover that quota was returned inside the same advertised
# weekly window. In that case the queued request must be released immediately.
probe_calls="$TMP/weekly-probe.calls"
session=quota-gate-test-weekly-reset-early
write_state 88 "$five_reset" "$now" 101 "$week_reset" "$((now - 3601))"
printf '{"session_id":"%s"}' "$session" \
  | CLAUDE_QUOTA_JITTER=0 CLAUDE_QUOTA_WAKE_BUFFER=0 \
      CLAUDE_WEEKLY_QUOTA_PROBE_SECS=3600 \
      CLAUDE_QUOTA_PROBE_FILE="$TMP/weekly-reset-probe.stamp" \
      CLAUDE_WEEKLY_QUOTA_PROBE_COMMAND="$probe" \
      CLAUDE_TEST_PROBE_CALLS="$probe_calls" \
      CLAUDE_TEST_PROBE_USED=0 CLAUDE_TEST_PROBE_RESET="$week_reset" sh "$GATE"
calls=$(line_count "$probe_calls")
assert_eq "weekly: an overdue live probe runs once" "$calls" "1"
if [ ! -f "$HOME/.claude/quota-park/$session" ]; then
  pass=$((pass + 1)); printf 'ok    weekly: a mid-window quota return releases the request\n'
else
  fail=$((fail + 1)); printf 'FAIL  weekly: a mid-window quota return releases the request\n'
fi

# Until the configured hour, every other hook must reuse that live "quota available"
# result instead of either probing again or trusting a repinned stale 101. The
# repin is what an idle terminal does every render: it re-publishes the frozen
# payload it was handed before the allowance came back, non-fresh, and by value
# 101 beats 0 -- the plan-switch bug. The merge must refuse it while the
# probe's reading is young.
session=quota-gate-test-weekly-reset-cached
"$STATE" publish -1 0 101 "$week_reset" 0 >/dev/null
assert_eq "weekly: a frozen session payload cannot displace a young probe reading" \
  "$("$STATE" read7 | cut -d' ' -f1,4)" "0 probe"
printf '{"session_id":"%s"}' "$session" \
  | CLAUDE_QUOTA_JITTER=0 CLAUDE_QUOTA_WAKE_BUFFER=0 \
      CLAUDE_WEEKLY_QUOTA_PROBE_SECS=3600 \
      CLAUDE_QUOTA_PROBE_FILE="$TMP/weekly-reset-probe.stamp" \
      CLAUDE_WEEKLY_QUOTA_PROBE_COMMAND="$probe" \
      CLAUDE_TEST_PROBE_CALLS="$probe_calls" \
      CLAUDE_TEST_PROBE_USED=0 CLAUDE_TEST_PROBE_RESET="$week_reset" sh "$GATE" \
      >/dev/null 2>&1 &
gate_pid=$!
marker="$HOME/.claude/quota-park/$session"
wait_for_marker "$marker"
if ! kill -0 "$gate_pid" 2>/dev/null && [ ! -f "$marker" ]; then
  pass=$((pass + 1)); printf 'ok    weekly: fresh available probe result overrides a repinned stale cache\n'
else
  fail=$((fail + 1)); printf 'FAIL  weekly: fresh available probe result overrides a repinned stale cache\n'
fi
assert_eq "weekly: hourly override probes at most once per hour" \
  "$(line_count "$probe_calls")" "1"
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

# If both limits are exhausted, the configured hourly weekly probe is the first
# point at which the combined gate might clear (the 5h reset happens sooner).
session=quota-gate-test-both
probe_calls="$TMP/weekly-both-probe.calls"
write_state 96 "$five_reset" "$now" 99 "$week_reset" "$now"
printf '{"session_id":"%s"}' "$session" \
  | CLAUDE_QUOTA_JITTER=0 CLAUDE_QUOTA_WAKE_BUFFER=0 \
      CLAUDE_WEEKLY_QUOTA_PROBE_SECS=3600 \
      CLAUDE_QUOTA_PROBE_FILE="$TMP/weekly-both-probe.stamp" \
      CLAUDE_WEEKLY_QUOTA_PROBE_COMMAND="$probe" \
      CLAUDE_TEST_PROBE_CALLS="$probe_calls" \
      CLAUDE_TEST_PROBE_USED=99 CLAUDE_TEST_PROBE_RESET="$week_reset" sh "$GATE" \
      >/dev/null 2>&1 &
gate_pid=$!
marker="$HOME/.claude/quota-park/$session"
wait_for_marker "$marker"
contents=$(sed -n '1p' "$marker" 2>/dev/null)
both_wake=$(printf '%s' "$contents" | cut -d' ' -f1)
both_window=$(printf '%s' "$contents" | cut -d' ' -f2)
assert_eq "both: weekly quota remains the limiting window" \
  "$both_window" "seven_day"
assert_between "both: configured weekly probe remains hourly" \
  "$both_wake" "$((now + 3599))" "$((now + 3605))"
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

# Hooks arriving while the machine-wide probe is in flight must wait only for
# that probe, not for the entire polling interval. This is the multi-session
# race that otherwise leaves some requests parked after a successful refresh.
session=quota-gate-test-weekly-probe-in-flight
pending_stamp="$TMP/weekly-pending-probe.stamp"
write_state 88 "$five_reset" "$now" 99 "$week_reset" "$now"
printf '%s pending' "$now" > "$pending_stamp"
(
  sleep 0.1
  write_state 88 "$five_reset" "$now" 0 "$week_reset" "$now"
  printf '%s ok' "$now" > "$pending_stamp"
) &
updater_pid=$!
printf '{"session_id":"%s"}' "$session" \
  | CLAUDE_QUOTA_JITTER=0 CLAUDE_QUOTA_WAKE_BUFFER=0 \
      CLAUDE_WEEKLY_QUOTA_PROBE_SECS=300 \
      CLAUDE_QUOTA_PROBE_FILE="$pending_stamp" sh "$GATE" \
      >/dev/null 2>&1 &
gate_pid=$!
tries=0
while kill -0 "$gate_pid" 2>/dev/null && [ "$tries" -lt 125 ]; do
  sleep 0.02
  tries=$((tries + 1))
done
wait "$updater_pid"
if ! kill -0 "$gate_pid" 2>/dev/null \
   && [ ! -f "$HOME/.claude/quota-park/$session" ]; then
  pass=$((pass + 1)); printf 'ok    weekly: a concurrent hook follows the in-flight probe result\n'
else
  fail=$((fail + 1)); printf 'FAIL  weekly: a concurrent hook follows the in-flight probe result\n'
fi
stop_gate

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
