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
# TWO KINDS OF READING. A *session* reading is what a status line lifted off its
# own payload -- a cache of that session's last response headers. A *probe*
# reading is what quota-probe.sh got by asking the account's usage endpoint
# directly, the one Claude Code's /usage screen reads. The probe is the only
# reading in here that is not a cache of something, and each window remembers
# which kind it holds (`source`: "probe" / "session").
#
# WHY THE PROBE OUTRANKS FROZEN SESSIONS: the rules above can only ever walk
# `used` UP inside one window, and a plan change walks it DOWN. On 2026-09-11
# the account went Max 5x -> Max 20x mid-window: the site said 5% used, this
# file held 94% with the very same resets_at, and every idle terminal kept
# re-publishing its frozen 94% payload -- non-fresh, but ahead by value, so it
# won the merge again and again. Neither the value order nor the stale hatch
# can express "the allowance grew", so the bar sat on the old plan's number
# ("6% left / 10h") until the window reset. The same happens on any
# Pro <-> Max 5x <-> Max 20x switch in either direction, and whenever Anthropic
# adjusts limits mid-window. Hence the rule: while a window's stored reading
# came from the probe and is younger than 2 x $PROBE_SECS, a NON-fresh session
# reading never displaces it, whatever its value -- a cache cannot outrank a
# measurement. Fresh session readings keep the rules above: they are live
# observations of the same account, and if they run higher the account really
# did move. (A frozen payload mistaken for fresh -- a session's first render
# after /tmp was emptied -- can still win for one probe interval; the next probe
# puts the measured number back, so the bar converges within minutes either way.)
#
# CONCURRENCY: every statusline writes this ~2x/sec with no lock. Two writers
# can interleave and one update can be lost, but the merge is monotone-or-fresher
# and re-runs a second later, so a lost update self-heals. A lock would cost more
# than the race does.
#
#   quota-state.sh publish <u5> <r5> <u7> <r7> <fresh>
#                                       -> echoes merged "u5 r5 u7 r7 measured5"
#   quota-state.sh set <u5> <r5> <u7> <r7>
#                                       -> the probe's write: replaces both windows
#                                          unconditionally, measured_at=now, source=probe,
#                                          and stamps a top-level probed_at. A non-numeric
#                                          (or -1) <used> keeps that window's stored
#                                          reading instead of blanking it.
#                                          Echoes the same line as publish.
#   quota-state.sh read                 -> echoes stored "u5 r5 m5 source"  (five_hour)
#   quota-state.sh read7                -> echoes stored "u7 r7 m7 source"  (seven_day)
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
# How often quota-probe.sh asks the account (its own default, repeated here so
# the two agree on how long a probe reading stays authoritative: twice this, so
# one missed probe does not hand the bar back to the frozen caches).
PROBE_SECS="${CLAUDE_QUOTA_PROBE_SECS:-${CLAUDE_WEEKLY_QUOTA_PROBE_SECS:-300}}"
case "$PROBE_SECS" in ''|*[!0-9]*|0) PROBE_SECS=300 ;; esac

stored() {
  [ -f "$F" ] || { echo "-1 0 0 session"; return; }
  jq -r '"\(.five_hour.used // -1) \(.five_hour.resets_at // 0) \(.five_hour.measured_at // 0) \(.five_hour.source // "session")"' \
    "$F" 2>/dev/null || echo "-1 0 0 session"
}

stored7() {
  [ -f "$F" ] || { echo "-1 0 0 session"; return; }
  jq -r '"\(.seven_day.used // -1) \(.seven_day.resets_at // 0) \(.seven_day.measured_at // 0) \(.seven_day.source // "session")"' \
    "$F" 2>/dev/null || echo "-1 0 0 session"
}

stored_probed_at() {
  [ -f "$F" ] || { echo 0; return; }
  jq -r '.probed_at // 0' "$F" 2>/dev/null || echo 0
}

# merge <used> <resets> <fresh> <old_used> <old_resets> <old_measured> <old_source> <now>
#   -> echoes "used resets measured source"
# A non-numeric/absent new reading always loses, so a terminal that has never
# seen a header cannot blank out what the others know.
merge() {
  _u=$1; _r=${2:-0}; _f=$3; _ou=$4; _or=$5; _om=$6; _os=${7:-session}; _now=$8
  case "$_u" in ''|*[!0-9.]*) echo "$_ou $_or $_om $_os"; return ;; esac
  case "$_r" in ''|*[!0-9]*) _r=0 ;; esac
  case "$_om" in ''|*[!0-9]*) _om=0 ;; esac
  # A probe reading younger than two probe intervals is a measurement; a
  # non-fresh session reading is a cache. The cache never wins, whatever it
  # says -- that is the whole plan-switch fix (see the header).
  if [ "$_os" = probe ] && [ "$_f" != 1 ] && [ "$((_now - _om))" -lt "$((2 * PROBE_SECS))" ]; then
    echo "$_ou $_or $_om $_os"; return
  fi
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
    if [ "$_f" = 1 ]; then echo "$_u $_r $_now session"; else echo "$_u $_r $_om session"; fi
  else
    # Losing on value does not mean the caller learnt nothing: if it re-observed
    # the very numbers we hold, they are confirmed as of now. The provenance
    # stays -- the value is still the probe's, it has merely been seen again.
    if [ "$_f" = 1 ] && [ "$_u" = "$_ou" ] && [ "$_r" = "$_or" ]; then
      echo "$_ou $_or $_now $_os"
    else
      echo "$_ou $_or $_om $_os"
    fi
  fi
}

# write_state <u5> <r5> <m5> <s5> <u7> <r7> <m7> <s7> <probed_at> <now>
# Built from arguments, not by editing the file in place, so a corrupt file is
# overwritten by the next write instead of wedging every terminal.
write_state() {
  tmp="$F.tmp.$$"
  if jq -n --argjson u "$1" --argjson r "$2" --argjson m "$3" --arg s "$4" \
          --argjson u7 "$5" --argjson r7 "$6" --argjson m7 "$7" --arg s7 "$8" \
          --argjson p "$9" --argjson n "${10}" \
       '{five_hour:{used:$u,resets_at:$r,measured_at:$m,source:$s},
         seven_day:{used:$u7,resets_at:$r7,measured_at:$m7,source:$s7},
         probed_at:$p, updated_at:$n}' \
       > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$F"
  else
    rm -f "$tmp"
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
    old_src=$(printf '%s' "$old" | cut -d' ' -f4)
    old7=$(stored7)
    old7_used=$(printf '%s' "$old7" | cut -d' ' -f1)
    old7_resets=$(printf '%s' "$old7" | cut -d' ' -f2)
    old7_meas=$(printf '%s' "$old7" | cut -d' ' -f3)
    old7_src=$(printf '%s' "$old7" | cut -d' ' -f4)

    new=$(merge "$2" "${3:-0}" "$fresh" "$old_used" "$old_resets" "$old_meas" "$old_src" "$now")
    new7=$(merge "$4" "${5:-0}" "$fresh" "$old7_used" "$old7_resets" "$old7_meas" "$old7_src" "$now")
    used=$(printf  '%s' "$new"  | cut -d' ' -f1)
    resets=$(printf '%s' "$new"  | cut -d' ' -f2)
    meas=$(printf   '%s' "$new"  | cut -d' ' -f3)
    src=$(printf    '%s' "$new"  | cut -d' ' -f4)
    used7=$(printf  '%s' "$new7" | cut -d' ' -f1)
    resets7=$(printf '%s' "$new7" | cut -d' ' -f2)
    meas7=$(printf  '%s' "$new7" | cut -d' ' -f3)
    src7=$(printf   '%s' "$new7" | cut -d' ' -f4)

    if [ "$new $new7" != "$old $old7" ]; then
      write_state "$used" "$resets" "$meas" "$src" \
                  "$used7" "$resets7" "$meas7" "$src7" "$(stored_probed_at)" "$now"
    fi
    echo "$used $resets $used7 $resets7 $meas"
    ;;
  set)
    now=$(date +%s)
    old=$(stored)
    old7=$(stored7)
    u5=$2; r5=${3:-0}; u7=$4; r7=${5:-0}
    case "$r5" in ''|*[!0-9]*) r5=0 ;; esac
    case "$r7" in ''|*[!0-9]*) r7=0 ;; esac
    case "$u5" in ''|*[!0-9.]*) new=$old ;; *) new="$u5 $r5 $now probe" ;; esac
    case "$u7" in ''|*[!0-9.]*) new7=$old7 ;; *) new7="$u7 $r7 $now probe" ;; esac
    used=$(printf  '%s' "$new"  | cut -d' ' -f1)
    resets=$(printf '%s' "$new"  | cut -d' ' -f2)
    meas=$(printf   '%s' "$new"  | cut -d' ' -f3)
    src=$(printf    '%s' "$new"  | cut -d' ' -f4)
    used7=$(printf  '%s' "$new7" | cut -d' ' -f1)
    resets7=$(printf '%s' "$new7" | cut -d' ' -f2)
    meas7=$(printf  '%s' "$new7" | cut -d' ' -f3)
    src7=$(printf   '%s' "$new7" | cut -d' ' -f4)
    write_state "$used" "$resets" "$meas" "$src" \
                "$used7" "$resets7" "$meas7" "$src7" "$now" "$now"
    echo "$used $resets $used7 $resets7 $meas"
    ;;
  *)
    echo "usage: $0 {publish <u5> <r5> <u7> <r7> <fresh>|set <u5> <r5> <u7> <r7>|read|read7}" >&2
    exit 64
    ;;
esac
