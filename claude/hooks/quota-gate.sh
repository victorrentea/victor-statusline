#!/bin/sh
# Park this terminal when the 5h quota is nearly gone, and wake it after the
# window resets -- so unattended sessions resume by themselves instead of dying
# on "limit reached" and waiting for a human.
#
# Wired to UserPromptSubmit, PreToolUse and PostToolUse: those are the three
# points immediately before an API request. PostToolUse is the tightest (the
# tool result is already in hand), PreToolUse also avoids kicking off a long
# build right at the boundary, UserPromptSubmit covers a turn that ended in
# plain text.
#
# WAKING IS PURELY WALL-CLOCK, and it has to be. `rate_limits` only refreshes
# when a session gets an API response, so if every terminal is parked, nothing
# anywhere refreshes it -- a "wait until used% drops" condition would deadlock
# forever. `resets_at` is an absolute epoch already known before we sleep, so
# each terminal computes its own deadline and wakes independently. No terminal
# unblocks any other; none needs to.
#
# The guard `resets_at > now` is what makes this self-correcting. After waking,
# the cached reading still says ~100% used (frozen), but resets_at is now in the
# past, so the condition is false and the call goes through. Its response
# refreshes the headers for every terminal. Re-sleep loops are impossible.
#
# Env knobs: CLAUDE_QUOTA_MIN_PCT (default 5), CLAUDE_QUOTA_MAX_SLEEP (21600),
# CLAUDE_QUOTA_GATE=0 to disable.

INPUT=$(cat)                       # always drain stdin, else the writer gets SIGPIPE

[ "${CLAUDE_QUOTA_GATE:-1}" = "0" ] && exit 0

THRESH="${CLAUDE_QUOTA_MIN_PCT:-5}"
MAXSLEEP="${CLAUDE_QUOTA_MAX_SLEEP:-21600}"
LOG="$HOME/.claude/quota-gate.log"
PARKDIR="$HOME/.claude/quota-park"

state=$("$HOME/.claude/hooks/quota-state.sh" read 2>/dev/null) || exit 0
used=$(printf   '%s' "$state" | cut -d' ' -f1)
resets=$(printf '%s' "$state" | cut -d' ' -f2)
meas=$(printf   '%s' "$state" | cut -d' ' -f3)
case "$used" in ''|-1|*[!0-9.]*) exit 0 ;; esac   # no reading yet -> nothing to gate on

now=$(date +%s)

# Parking is a decision to stop working for up to five hours, so it is taken on
# CONFIRMED data only. quota-state.sh now records when a reading was last seen
# live; a reading nobody has re-confirmed within $STALE could equally well be
# describing a window that has already rolled over, and sleeping on it would
# idle every terminal on the machine for nothing. Refusing to park is also the
# recoverable error of the two: the worst case is one request that gets a 429 --
# and that 429's own headers immediately republish a fresh ~100% reading, so the
# very next hook parks on solid ground.
STALE="${CLAUDE_QUOTA_STALE_SECS:-900}"
case "$meas" in ''|*[!0-9]*|0) exit 0 ;; esac
[ "$((now - meas))" -le "$STALE" ] || exit 0

go=$(awk -v u="$used" -v t="$THRESH" -v r="$resets" -v n="$now" \
  'BEGIN{ print ((100 - u) < t && r > n) ? 1 : 0 }')
[ "$go" = 1 ] || exit 0

# Jitter so several parked terminals do not all fire at the same instant when
# the window rolls over. PID-derived rather than $RANDOM to stay portable.
JITTER="${CLAUDE_QUOTA_JITTER:-90}"
BUFFER="${CLAUDE_QUOTA_WAKE_BUFFER:-30}"
jitter=0
[ "$JITTER" -gt 0 ] 2>/dev/null && jitter=$(( $$ % JITTER ))
secs=$(( resets - now + BUFFER + jitter ))
[ "$secs" -le 0 ] && exit 0

session=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
[ -n "$session" ] || session=unknown
wake=$(( now + secs ))
stamp=$(date -r "$wake" '+%H:%M' 2>/dev/null)

if [ "$secs" -gt "$MAXSLEEP" ]; then
  printf '%s park-declined session=%s used=%s reset_in=%ss exceeds max=%ss\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "$session" "$used" "$secs" "$MAXSLEEP" >> "$LOG"
  exit 0
fi

mkdir -p "$PARKDIR"
printf '%s' "$wake" > "$PARKDIR/$session"
# Clean the marker even if the user interrupts the hook with Esc.
trap 'rm -f "$PARKDIR/$session"' EXIT INT TERM

printf '%s park session=%s used=%s%% sleeping=%ss until=%s\n' \
  "$(date '+%Y-%m-%dT%H:%M:%S')" "$session" "$used" "$secs" "$stamp" >> "$LOG"

sleep "$secs"

printf '%s wake session=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$session" >> "$LOG"
exit 0
