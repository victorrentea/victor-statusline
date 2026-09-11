#!/bin/sh
# Park this terminal when the 5h quota is nearly gone or the weekly quota has
# 1% or less left. The 5h gate wakes at its reset; the weekly gate also probes
# Claude's live usage endpoint every five minutes, so an early reset or plan boost can
# release unattended work without trusting a stale advertised reset.
#
# Wired to UserPromptSubmit, PreToolUse and PostToolUse: those are the three
# points immediately before an API request. PostToolUse is the tightest (the
# tool result is already in hand), PreToolUse also avoids kicking off a long
# build right at the boundary, UserPromptSubmit covers a turn that ended in
# plain text.
#
# `rate_limits` in the hook payload is cached, so it cannot itself discover a
# mid-window allowance change while every request is parked. The periodic probe
# calls the same authenticated usage endpoint as Claude Code's Usage screen and
# republishes its seven-day reading into the shared quota state. A machine-wide
# attempt timestamp prevents every parked terminal from probing independently.
#
# Env knobs: CLAUDE_QUOTA_MIN_PCT (default 5),
# CLAUDE_WEEKLY_QUOTA_MIN_PCT (default 1), CLAUDE_QUOTA_MAX_SLEEP (604920),
# CLAUDE_WEEKLY_QUOTA_PROBE_SECS (default 300),
# CLAUDE_QUOTA_GATE=0 to disable.

INPUT=$(cat)                       # always drain stdin, else the writer gets SIGPIPE

[ "${CLAUDE_QUOTA_GATE:-1}" = "0" ] && exit 0

THRESH="${CLAUDE_QUOTA_MIN_PCT:-5}"
WEEK_THRESH="${CLAUDE_WEEKLY_QUOTA_MIN_PCT:-1}"
MAXSLEEP="${CLAUDE_QUOTA_MAX_SLEEP:-604920}"
PROBE_SECS="${CLAUDE_WEEKLY_QUOTA_PROBE_SECS:-300}"
LOG="$HOME/.claude/quota-gate.log"
PARKDIR="$HOME/.claude/quota-park"
PROBE_STAMP="${CLAUDE_WEEKLY_QUOTA_PROBE_FILE:-$HOME/.claude/quota-weekly-probe}"

case "$PROBE_SECS" in ''|*[!0-9]*|0) PROBE_SECS=300 ;; esac

iso_to_epoch() {
  # macOS date(1) cannot parse fractional seconds or the colon in +00:00.
  _iso=$(printf '%s' "$1" | sed -E 's/\.[0-9]+([+-][0-9][0-9]):([0-9][0-9])$/\1\2/')
  date -j -f '%Y-%m-%dT%H:%M:%S%z' "$_iso" +%s 2>/dev/null
}

probe_weekly() {
  if [ -n "${CLAUDE_WEEKLY_QUOTA_PROBE_COMMAND:-}" ]; then
    "$CLAUDE_WEEKLY_QUOTA_PROBE_COMMAND"
    return
  fi

  _credentials=$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null) || return 1
  _token=$(printf '%s' "$_credentials" | jq -er '.claudeAiOauth.accessToken' 2>/dev/null) || return 1
  _body=$(curl -fsS --max-time 15 \
    -H "Authorization: Bearer $_token" \
    -H 'anthropic-beta: oauth-2025-04-20' \
    -H 'User-Agent: claude-code/quota-gate' \
    'https://api.anthropic.com/api/oauth/usage' 2>/dev/null) || return 1
  _probe_used=$(printf '%s' "$_body" | jq -r '.seven_day.utilization // empty' 2>/dev/null)
  _probe_iso=$(printf '%s' "$_body" | jq -r '.seven_day.resets_at // empty' 2>/dev/null)
  case "$_probe_used" in ''|*[!0-9.]*) return 1 ;; esac
  _probe_reset=$(iso_to_epoch "$_probe_iso")
  case "$_probe_reset" in ''|*[!0-9]*) _probe_reset=0 ;; esac
  printf '%s %s\n' "$_probe_used" "$_probe_reset"
}

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

  # A low cached weekly reading is rechecked live once the shared attempt clock
  # is five minutes old. `measured_at` is deliberately irrelevant here: a restarted
  # status line can mistake its first frozen payload for a new API response.
  # Writing the attempt before curl makes concurrent sleepers converge on the
  # same next deadline even when the network request fails. A successful result
  # stays in the same file so all hooks trust it until the next periodic probe.
  if [ "$go7" = 1 ]; then
    probe_record=$(sed -n '1p' "$PROBE_STAMP" 2>/dev/null)
    probe_last="" probe_cached_used="" probe_cached_reset=""
    IFS=' ' read -r probe_last probe_cached_used probe_cached_reset <<EOF
$probe_record
EOF
    case "$probe_last" in
      ''|*[!0-9]*) probe_last=0 ;;
    esac
    if [ "$probe_last" -gt 0 ] && [ "$now" -lt "$((probe_last + PROBE_SECS))" ]; then
      case "$probe_cached_used" in
        ''|*[!0-9.]*) ;;
        *)
          case "$probe_cached_reset" in ''|*[!0-9]*|0) probe_cached_reset=$resets7 ;; esac
          used7=$probe_cached_used
          resets7=$probe_cached_reset
          go7=$(awk -v u="$used7" -v t="$WEEK_THRESH" -v r="$resets7" -v n="$now" \
            'BEGIN{ print ((100 - u) <= t && r > n) ? 1 : 0 }')
          ;;
      esac
    elif [ "$now" -ge "$((probe_last + PROBE_SECS))" ]; then
      mkdir -p "$(dirname "$PROBE_STAMP")"
      printf '%s' "$now" > "$PROBE_STAMP"
      live7=$(probe_weekly 2>/dev/null)
      probe_used=$(printf '%s' "$live7" | cut -d' ' -f1)
      probe_reset=$(printf '%s' "$live7" | cut -d' ' -f2)
      case "$probe_used" in
        ''|*[!0-9.]*)
          printf '%s probe-failed session=%s window=seven_day\n' \
            "$(date '+%Y-%m-%dT%H:%M:%S')" "$session" >> "$LOG"
          ;;
        *)
          case "$probe_reset" in ''|*[!0-9]*|0) probe_reset=$resets7 ;; esac
          printf '%s %s %s' "$now" "$probe_used" "$probe_reset" > "$PROBE_STAMP"
          "$HOME/.claude/hooks/quota-state.sh" publish \
            -1 0 "$probe_used" "$probe_reset" 1 >/dev/null 2>&1
          used7=$probe_used
          resets7=$probe_reset
          go7=$(awk -v u="$used7" -v t="$WEEK_THRESH" -v r="$resets7" -v n="$now" \
            'BEGIN{ print ((100 - u) <= t && r > n) ? 1 : 0 }')
          printf '%s probe session=%s window=seven_day used=%s%% gate=%s\n' \
            "$(date '+%Y-%m-%dT%H:%M:%S')" "$session" "$used7" "$go7" >> "$LOG"
          ;;
      esac
    fi
  fi

  [ "$go" = 1 ] || [ "$go7" = 1 ] || exit 0

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
