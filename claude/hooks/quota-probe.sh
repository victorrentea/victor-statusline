#!/bin/sh
# Ask the account what it really has left, and make that the reading every
# terminal shows. `rate_limits` in a session payload is a cache of that session's
# last response headers; the usage endpoint behind Claude Code's /usage screen is
# the account itself. This is the only reading in ~/.claude/quota.json that is
# not a cache of something, which is why quota-state.sh lets it outrank frozen
# session readings (see the plan-switch note in its header: "6% left" stuck on
# the bar for hours after Max 5x -> Max 20x, 2026-09-11, because a cache can
# only ever report the allowance it was cut from).
#
# Fired by the status line (in the background, whenever the stamp is older than
# CLAUDE_QUOTA_PROBE_SECS) and by quota-gate.sh (in the foreground, while it is
# parked on the weekly window). Either may fire from many terminals at once: a
# mkdir lock lets one request per interval leave the machine and the rest exit
# at once, so a caller never waits for anything but its own curl.
#
# Stamp `~/.claude/quota-probe`, first line "<epoch> <pending|ok|failed>". The
# epoch is when the attempt STARTED, written before curl so that concurrent
# callers converge on the same next deadline even when the request fails;
# `pending` is what lets a parked gate re-read a second later instead of
# sleeping a whole interval. A failed attempt keeps the interval: retrying on
# every render would turn one outage into a request storm.
#
# The OAuth token comes from the Keychain item Claude Code itself uses and is
# never written anywhere. The weekly figure is the TIGHTEST of the account's
# weekly caps (`limits[] | select(.group == "weekly")`: weekly_all plus any
# per-model scoped cap), falling back to `seven_day.utilization`; the 5h figure
# is `five_hour.utilization`.
#
#   quota-probe.sh            probe if due   (exit 0 probed, 1 failed, 2 skipped)
#   quota-probe.sh --force    probe now, ignoring the interval (still one at a time)
#
# Env: CLAUDE_QUOTA_PROBE_SECS (default 300; CLAUDE_WEEKLY_QUOTA_PROBE_SECS is an
# accepted alias), CLAUDE_QUOTA_PROBE_FILE (the stamp),
# CLAUDE_WEEKLY_QUOTA_PROBE_COMMAND (test hook: a command that prints
# "u5 r5 u7 r7" -- or just "u7 r7" -- instead of calling the endpoint; resets
# may be epochs or the endpoint's ISO form).

PROBE_SECS="${CLAUDE_QUOTA_PROBE_SECS:-${CLAUDE_WEEKLY_QUOTA_PROBE_SECS:-300}}"
case "$PROBE_SECS" in ''|*[!0-9]*|0) PROBE_SECS=300 ;; esac
STAMP="${CLAUDE_QUOTA_PROBE_FILE:-$HOME/.claude/quota-probe}"
LOCK="$STAMP.lock"
STATE="$HOME/.claude/hooks/quota-state.sh"
LOG="$HOME/.claude/quota-gate.log"

force=0
[ "${1:-}" = "--force" ] && force=1

iso_to_epoch() {
  # macOS date(1) cannot parse fractional seconds or the colon in +00:00.
  _iso=$(printf '%s' "$1" | sed -E 's/\.[0-9]+([+-][0-9][0-9]):([0-9][0-9])$/\1\2/')
  date -j -f '%Y-%m-%dT%H:%M:%S%z' "$_iso" +%s 2>/dev/null
}

# Epochs pass through; anything else is tried as ISO; garbage becomes 0, which
# every reader already treats as "reset unknown".
to_epoch() {
  case "$1" in
    ''|-)       echo 0 ;;
    *[!0-9]*)   iso_to_epoch "$1" || echo 0 ;;
    *)          echo "$1" ;;
  esac
}

fetch() {
  if [ -n "${CLAUDE_WEEKLY_QUOTA_PROBE_COMMAND:-}" ]; then
    "$CLAUDE_WEEKLY_QUOTA_PROBE_COMMAND"
    return
  fi
  _credentials=$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null) || return 1
  _token=$(printf '%s' "$_credentials" | jq -er '.claudeAiOauth.accessToken' 2>/dev/null) || return 1
  _body=$(curl -fsS --max-time 15 \
    -H "Authorization: Bearer $_token" \
    -H 'anthropic-beta: oauth-2025-04-20' \
    -H 'User-Agent: claude-code/quota-probe' \
    'https://api.anthropic.com/api/oauth/usage' 2>/dev/null) || return 1
  printf '%s' "$_body" | jq -r '
    ([.limits[]? | select(.group == "weekly" and (.percent | type) == "number")]
      | max_by(.percent)) as $w
    | "\(.five_hour.utilization // "-") \(.five_hour.resets_at // "-") \($w.percent // .seven_day.utilization // "-") \($w.resets_at // .seven_day.resets_at // "-")"' \
    2>/dev/null
}

due() {
  [ "$force" = 1 ] && return 0
  _last=$(sed -n '1p' "$STAMP" 2>/dev/null | cut -d' ' -f1)
  case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
  [ "$((now - _last))" -ge "$PROBE_SECS" ]
}

now=$(date +%s)
due || exit 2
mkdir -p "$(dirname "$STAMP")" 2>/dev/null
if ! mkdir "$LOCK" 2>/dev/null; then
  # A lock older than any request can take (curl gives up at 15s) belongs to a
  # prober that was killed mid-flight; reclaim it rather than never probe again.
  _lock_at=$(stat -f %m "$LOCK" 2>/dev/null)
  case "$_lock_at" in ''|*[!0-9]*) _lock_at=$now ;; esac
  [ "$((now - _lock_at))" -gt 60 ] && rmdir "$LOCK" 2>/dev/null && mkdir "$LOCK" 2>/dev/null || exit 2
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
trap 'exit 130' INT TERM
due || exit 2                     # someone else finished between our check and the lock

printf '%s pending' "$now" > "$STAMP"
# shellcheck disable=SC2046  # word-splitting the four fields is the point
set -- $(fetch 2>/dev/null)
case $# in
  2) u5=-; r5=-; u7=$1; r7=$2 ;;
  4) u5=$1; r5=$2; u7=$3; r7=$4 ;;
  *) u5=-; r5=-; u7=-; r7=- ;;
esac
case "$u7" in
  ''|*[!0-9.]*)
    printf '%s failed' "$now" > "$STAMP"
    printf '%s probe-failed\n' "$(date '+%Y-%m-%dT%H:%M:%S')" >> "$LOG"
    exit 1
    ;;
esac
case "$u5" in ''|*[!0-9.]*) u5=-1 ;; esac
r5=$(to_epoch "$r5")
r7=$(to_epoch "$r7")
if ! "$STATE" set "$u5" "$r5" "$u7" "$r7" >/dev/null 2>&1; then
  printf '%s failed' "$now" > "$STAMP"
  printf '%s probe-failed (quota-state.sh set)\n' "$(date '+%Y-%m-%dT%H:%M:%S')" >> "$LOG"
  exit 1
fi
printf '%s ok' "$now" > "$STAMP"
printf '%s probe five_hour=%s%% seven_day=%s%%\n' \
  "$(date '+%Y-%m-%dT%H:%M:%S')" "$u5" "$u7" >> "$LOG"
exit 0
