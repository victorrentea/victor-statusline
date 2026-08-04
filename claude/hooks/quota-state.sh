#!/bin/sh
# Shared 5h/7d-quota state across every Claude Code terminal on this machine.
#
# WHY THIS EXISTS: `rate_limits` in the statusLine payload is not a live feed --
# it is a cache of the headers from *that session's* last API response. A
# terminal that has been idle shows frozen numbers, which is why two terminals
# disagree about how much quota is left. This file is the union of what all
# terminals have seen.
#
# MERGE RULE, and why it needs a clock. The original rule was purely
# value-based: within one window `used` only increases and across windows
# `resets_at` increases, so (resets_at, used) compared lexicographically is a
# total "which reading is newer" order -- no timestamps needed. That is true of
# any two readings *of the same account state*, and it is still the tie-break
# below. What it cannot survive is a reading that is simply WRONG-BUT-AHEAD: one
# whose resets_at sits a few minutes past the real window boundary. Nothing can
# ever outrank it (every honest reading has a smaller resets_at), so it pins
# BOTH numbers -- the percentage and the countdown -- for every terminal on the
# machine, for the rest of the window. The observed failure was exactly that
# signature: "78% left / 19m" while the account was at 100% used with 14m to go.
#
# So a reading now also carries WHEN IT WAS OBSERVED LIVE, and freshness
# outranks value: a reading a caller just saw arrive beats a stored one that no
# terminal has re-confirmed in $STALE seconds. That is the only rule that can
# walk a wrong value back down; the value order alone is monotone by
# construction and therefore cannot.
#
# `measured_at` is NOT the time we wrote the file -- it is the time some
# terminal saw these numbers change, i.e. the moment an API response actually
# carried them. The caller says so with the <fresh> flag (the statusline sets it
# when the payload differs from what that session published last). Readings that
# merely repeat what the caller already had do not refresh the clock, because
# re-reading a frozen cache is not evidence of anything.
#
# CONCURRENCY: every statusline writes this ~2x/sec with no lock. Two writers
# can interleave and one update can be lost, but the merge is monotone-or-fresher
# and re-runs a second later, so a lost update self-heals. A lock would cost more
# than the race does.
#
#   quota-state.sh publish <u5> <r5> <u7> <r7> <fresh>
#                                       -> echoes merged "u5 r5 u7 r7 measured5"
#   quota-state.sh read                 -> echoes stored "u5 r5 m5"  (five_hour)
#   quota-state.sh read7                -> echoes stored "u7 r7 m7"  (seven_day)
#
# Both windows are merged independently by the rule above: the weekly reading
# goes stale in exactly the same way as the 5h one, and it is the *slower* of the
# two to refresh (a terminal can sit idle for hours), so sharing matters more
# there, not less. Both share ONE <fresh> flag because both come off the same
# response headers -- if one moved, the response was new, and the other was
# re-confirmed by that same response even when its value did not change.

F="${CLAUDE_QUOTA_FILE:-$HOME/.claude/quota.json}"
# How long a reading stays believable without any terminal re-confirming it.
# 15 minutes: long enough that a genuinely quiet machine does not flap (nobody
# working means nobody burning, so an old reading is still a correct one), short
# enough that a window cannot run to its end on a number seen once at the start.
STALE="${CLAUDE_QUOTA_STALE_SECS:-900}"

stored() {
  [ -f "$F" ] || { echo "-1 0 0"; return; }
  jq -r '"\(.five_hour.used // -1) \(.five_hour.resets_at // 0) \(.five_hour.measured_at // 0)"' \
    "$F" 2>/dev/null || echo "-1 0 0"
}

stored7() {
  [ -f "$F" ] || { echo "-1 0 0"; return; }
  jq -r '"\(.seven_day.used // -1) \(.seven_day.resets_at // 0) \(.seven_day.measured_at // 0)"' \
    "$F" 2>/dev/null || echo "-1 0 0"
}

# merge <used> <resets> <fresh> <old_used> <old_resets> <old_measured> <now>
#   -> echoes "used resets measured"
# A non-numeric/absent new reading always loses, so a terminal that has never
# seen a header cannot blank out what the others know.
merge() {
  _u=$1; _r=${2:-0}; _f=$3; _ou=$4; _or=$5; _om=$6; _now=$7
  case "$_u" in ''|*[!0-9.]*) echo "$_ou $_or $_om"; return ;; esac
  case "$_r" in ''|*[!0-9]*) _r=0 ;; esac
  case "$_om" in ''|*[!0-9]*) _om=0 ;; esac
  # Take the new reading when it is newer BY VALUE (the original order), or when
  # it is FRESH and what we hold has gone unconfirmed past $STALE. The second
  # clause is the escape hatch: it is the only way a stored reading whose
  # resets_at is ahead of reality can ever be displaced.
  _take=$(awk -v u="$_u" -v r="$_r" -v f="$_f" -v ou="$_ou" -v orr="$_or" \
               -v om="$_om" -v now="$_now" -v st="$STALE" 'BEGIN{
    if (ou < 0)                        { print 1; exit }   # nothing stored yet
    if (r > orr)                       { print 1; exit }
    if (r == orr && u > ou)            { print 1; exit }
    if (f == 1 && (now - om) > st)     { print 1; exit }   # stale gets overruled
    print 0 }')
  if [ "$_take" = 1 ]; then
    # Only a FRESH reading may advance the clock. Winning on value alone proves
    # the reading is newer than ours, but not by how much -- and a timestamp we
    # cannot justify is worse than an old one we can, because it is the number
    # the display uses to decide whether to trust itself.
    if [ "$_f" = 1 ]; then echo "$_u $_r $_now"; else echo "$_u $_r $_om"; fi
  else
    # Losing on value does not mean the caller learnt nothing: if it re-observed
    # the very numbers we hold, they are confirmed as of now.
    if [ "$_f" = 1 ] && [ "$_u" = "$_ou" ] && [ "$_r" = "$_or" ]; then
      echo "$_ou $_or $_now"
    else
      echo "$_ou $_or $_om"
    fi
  fi
}

case "$1" in
  read)
    stored
    ;;
  read7)
    stored7
    ;;
  publish)
    now=$(date +%s)
    fresh=${6:-0}
    case "$fresh" in 1) ;; *) fresh=0 ;; esac

    old=$(stored)
    old_used=$(printf '%s' "$old" | cut -d' ' -f1)
    old_resets=$(printf '%s' "$old" | cut -d' ' -f2)
    old_meas=$(printf '%s' "$old" | cut -d' ' -f3)
    old7=$(stored7)
    old7_used=$(printf '%s' "$old7" | cut -d' ' -f1)
    old7_resets=$(printf '%s' "$old7" | cut -d' ' -f2)
    old7_meas=$(printf '%s' "$old7" | cut -d' ' -f3)

    new=$(merge "$2" "${3:-0}" "$fresh" "$old_used" "$old_resets" "$old_meas" "$now")
    new7=$(merge "$4" "${5:-0}" "$fresh" "$old7_used" "$old7_resets" "$old7_meas" "$now")
    used=$(printf  '%s' "$new"  | cut -d' ' -f1)
    resets=$(printf '%s' "$new"  | cut -d' ' -f2)
    meas=$(printf   '%s' "$new"  | cut -d' ' -f3)
    used7=$(printf  '%s' "$new7" | cut -d' ' -f1)
    resets7=$(printf '%s' "$new7" | cut -d' ' -f2)
    meas7=$(printf  '%s' "$new7" | cut -d' ' -f3)

    if [ "$used $resets $meas $used7 $resets7 $meas7" \
       != "$old_used $old_resets $old_meas $old7_used $old7_resets $old7_meas" ]; then
      tmp="$F.tmp.$$"
      if jq -n --argjson u "$used" --argjson r "$resets" --argjson m "$meas" \
              --argjson u7 "$used7" --argjson r7 "$resets7" --argjson m7 "$meas7" \
              --argjson n "$now" \
           '{five_hour:{used:$u,resets_at:$r,measured_at:$m},
             seven_day:{used:$u7,resets_at:$r7,measured_at:$m7},
             updated_at:$n}' \
           > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$F"
      else
        rm -f "$tmp"
      fi
    fi
    echo "$used $resets $used7 $resets7 $meas"
    ;;
  *)
    echo "usage: $0 {publish <u5> <r5> <u7> <r7> <fresh>|read|read7}" >&2
    exit 64
    ;;
esac
