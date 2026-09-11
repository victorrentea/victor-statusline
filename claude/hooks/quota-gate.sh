#!/bin/sh
# Park this terminal when the 5h quota is nearly gone or the weekly quota has
# 1% or less left. The 5h gate wakes at its reset; the weekly gate also probes
# Claude's live usage endpoint every five minutes, so an early reset or plan
# boost can release unattended work without trusting a stale advertised reset.
#
# Wired to UserPromptSubmit, PreToolUse and PostToolUse: those are the three
# points immediately before an API request. PostToolUse is the tightest (the
# tool result is already in hand), PreToolUse also avoids kicking off a long
# build right at the boundary, UserPromptSubmit covers a turn that ended in
# plain text.
#
# `rate_limits` in the hook payload is cached, so it cannot itself discover a
# mid-window allowance change while every request is parked. The periodic probe
# (quota-probe.sh, shared with the status line) calls the same authenticated
# usage endpoint as Claude Code's Usage screen and writes both windows into the
# shared quota state as the reading no frozen cache can displace; this hook
# only decides WHEN to run it and reads the state back. The probe's own stamp
# and lock keep every parked terminal from probing independently.
#
# Env knobs: CLAUDE_QUOTA_MIN_PCT (default 5),
# CLAUDE_WEEKLY_QUOTA_MIN_PCT (default 1), CLAUDE_QUOTA_MAX_SLEEP (604920),
# CLAUDE_QUOTA_PROBE_SECS (default 300; CLAUDE_WEEKLY_QUOTA_PROBE_SECS is an
# accepted alias), CLAUDE_QUOTA_GATE=0 to disable.

INPUT=$(cat)                       # always drain stdin, else the writer gets SIGPIPE

[ "${CLAUDE_QUOTA_GATE:-1}" = "0" ] && exit 0

THRESH="${CLAUDE_QUOTA_MIN_PCT:-5}"
WEEK_THRESH="${CLAUDE_WEEKLY_QUOTA_MIN_PCT:-1}"
MAXSLEEP="${CLAUDE_QUOTA_MAX_SLEEP:-604920}"
PROBE_SECS="${CLAUDE_QUOTA_PROBE_SECS:-${CLAUDE_WEEKLY_QUOTA_PROBE_SECS:-300}}"
LOG="$HOME/.claude/quota-gate.log"
PARKDIR="$HOME/.claude/quota-park"
PROBE_STAMP="${CLAUDE_QUOTA_PROBE_FILE:-$HOME/.claude/quota-probe}"
PROBE="$HOME/.claude/hooks/quota-probe.sh"

case "$PROBE_SECS" in ''|*[!0-9]*|0) PROBE_SECS=300 ;; esac

STALE="${CLAUDE_QUOTA_STALE_SECS:-900}"
JITTER="${CLAUDE_QUOTA_JITTER:-90}"
BUFFER="${CLAUDE_QUOTA_WAKE_BUFFER:-30}"
jitter=0
[ "$JITTER" -gt 0 ] 2>/dev/null && jitter=$(( $$ % JITTER ))
session=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
[ -n "$session" ] || session=unknown

while :; do
  state=$("$HOME/.claude/hooks/quota-state.sh" read 2>/dev/null) || exit 0
  used=$(printf   '%s' "$state" | cut -d' ' -f1)
  resets=$(printf '%s' "$state" | cut -d' ' -f2)
  meas=$(printf   '%s' "$state" | cut -d' ' -f3)
  state7=$("$HOME/.claude/hooks/quota-state.sh" read7 2>/dev/null)
  used7=$(printf   '%s' "$state7" | cut -d' ' -f1)
  resets7=$(printf '%s' "$state7" | cut -d' ' -f2)
  now=$(date +%s)

  # Preserve the existing 5h decision exactly: park only on confirmed data.
  go=0
  case "$used" in
    ''|-1|*[!0-9.]*) ;;
    *)
      case "$meas" in
        ''|*[!0-9]*|0) ;;
        *)
          if [ "$((now - meas))" -le "$STALE" ]; then
            go=$(awk -v u="$used" -v t="$THRESH" -v r="$resets" -v n="$now" \
              'BEGIN{ print ((100 - u) < t && r > n) ? 1 : 0 }')
          fi
          ;;
      esac
      ;;
  esac

  go7=0
  case "$used7" in
    ''|-1|*[!0-9.]*) ;;
    *)
      go7=$(awk -v u="$used7" -v t="$WEEK_THRESH" -v r="$resets7" -v n="$now" \
        'BEGIN{ print ((100 - u) <= t && r > n) ? 1 : 0 }')
      ;;
  esac

  # A low cached weekly reading is rechecked live once the shared probe stamp is
  # PROBE_SECS old. `measured_at` is deliberately irrelevant here: a restarted
  # status line can mistake its first frozen payload for a new response. The
  # probe owns the stamp, the lock and the write into quota.json (where the
  # merge keeps its reading safe from frozen session payloads until the next
  # poll), so this hook only runs it and reads the state back. A stamp still
  # `pending` means another hook's request is in flight.
  probe_pending=0
  if [ "$go7" = 1 ]; then
    probe_record=$(sed -n '1p' "$PROBE_STAMP" 2>/dev/null)
    probe_last=$(printf '%s' "$probe_record" | cut -d' ' -f1)
    probe_status=$(printf '%s' "$probe_record" | cut -d' ' -f2)
    case "$probe_last" in ''|*[!0-9]*) probe_last=0 ;; esac
    if [ "$now" -lt "$((probe_last + PROBE_SECS))" ]; then
      [ "$probe_status" = pending ] && probe_pending=1
    else
      "$PROBE" >/dev/null 2>&1
      state7=$("$HOME/.claude/hooks/quota-state.sh" read7 2>/dev/null)
      used7=$(printf   '%s' "$state7" | cut -d' ' -f1)
      resets7=$(printf '%s' "$state7" | cut -d' ' -f2)
      go7=$(awk -v u="$used7" -v t="$WEEK_THRESH" -v r="$resets7" -v n="$now" \
        'BEGIN{ print ((100 - u) <= t && r > n) ? 1 : 0 }')
      [ "$(sed -n '1p' "$PROBE_STAMP" 2>/dev/null | cut -d' ' -f2)" = pending ] && probe_pending=1
      printf '%s probe session=%s window=seven_day used=%s%% gate=%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S')" "$session" "$used7" "$go7" >> "$LOG"
    fi
  fi

  [ "$go" = 1 ] || [ "$go7" = 1 ] || exit 0

  # Another hook owns the live request. Re-read its result promptly instead of
  # turning the short network call into a full polling-interval sleep.
  if [ "$go7" = 1 ] && [ "$probe_pending" = 1 ]; then
    sleep 1
    continue
  fi

  if [ "$go7" = 1 ]; then
    window=seven_day
    used=$used7
    probe_last=$(sed -n '1p' "$PROBE_STAMP" 2>/dev/null)
    probe_last=$(printf '%s' "$probe_last" | cut -d' ' -f1)
    case "$probe_last" in
      ''|*[!0-9]*) probe_last=$now ;;
    esac
    wake=$((probe_last + PROBE_SECS + jitter))
    reset_wake=$((resets7 + BUFFER + jitter))
    [ "$reset_wake" -lt "$wake" ] && wake=$reset_wake
  else
    window=five_hour
    wake=$((resets + BUFFER + jitter))
  fi

  secs=$((wake - now))
  [ "$secs" -le 0 ] && continue
  stamp=$(date -r "$wake" '+%H:%M' 2>/dev/null)

  if [ "$secs" -gt "$MAXSLEEP" ]; then
    printf '%s park-declined session=%s window=%s used=%s reset_in=%ss exceeds max=%ss\n' \
      "$(date '+%Y-%m-%dT%H:%M:%S')" "$session" "$window" "$used" "$secs" "$MAXSLEEP" >> "$LOG"
    exit 0
  fi

  mkdir -p "$PARKDIR"
  printf '%s %s' "$wake" "$window" > "$PARKDIR/$session"
  trap 'rm -f "$PARKDIR/$session"' EXIT
  trap 'exit 130' INT TERM

  printf '%s park session=%s window=%s used=%s%% sleeping=%ss until=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "$session" "$window" "$used" "$secs" "$stamp" >> "$LOG"
  sleep "$secs"
  printf '%s wake session=%s window=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "$session" "$window" >> "$LOG"
done
