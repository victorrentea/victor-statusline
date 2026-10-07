#!/bin/sh
# Claude Code status line:
#   "Model/e (ctx% of SIZE) [+N×agents +…] | 5h% / reset | spend folder[@branch] 7d quota $week/Nd"
#
# Ordered by how fast each figure moves: the model line is fixed, the 5h window
# and the spend change within a turn, the folder changes when you cd, and the
# weekly figure barely moves at all — so the eye can stop scanning left-to-right
# as soon as it has what it came for, and the most static segment is the one
# that falls off the right edge first on a narrow terminal.
#
# MAINTENANCE RULE: whenever this script changes (format, segments, colors,
# thresholds, turn-state logic — anything that alters behaviour), update its
# companion reference in the same change:
#   ~/workspace/victor-statusline/claude/victor-claude-statusline.md
#   (published at https://github.com/victorrentea/victor-statusline)
# The two are one unit; a behaviour change not reflected there is a bug in the
# change, not a follow-up.
# Epoch -> clock text. `date -r EPOCH` is the BSD/macOS spelling; on GNU (Linux)
# `-r` names a FILE and the epoch is spelled `date -d @EPOCH`. BSD goes first so
# macOS never pays for a second fork; on Linux the failed first call is silent.
# A non-numeric epoch is refused up front: BSD's `-d` is a DST flag, not a date,
# so junk must never fall through to it.
fmt_epoch() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  date -r "$1" "$2" 2>/dev/null || date -d "@$1" "$2" 2>/dev/null
}
# File mtime as epoch seconds. GNU spelling FIRST, and the order matters: on GNU
# `stat -f` means "filesystem status" -- it exits 1 but still writes a block of
# filesystem info to stdout, so trying the BSD form first would fill the caller's
# variable with that block. On BSD `stat -c` just fails, silently.
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
# "<mtime> <path>" per file, one stat(1) for the lot. Same GNU-first order.
files_mtime() { stat -c '%Y %n' "$@" 2>/dev/null || stat -f '%m %N' "$@" 2>/dev/null; }
# "2026-09-20T12:00:00" (UTC) -> epoch. BSD `date -j` first; the GNU `date -d`
# fallback runs only where `date --version` proves it is GNU, because on BSD `-d`
# is that DST flag and must not be reached with a string it cannot parse.
utc_epoch() {
  date -j -u -f "%Y-%m-%dT%H:%M:%S" "$1" +%s 2>/dev/null ||
    { date --version >/dev/null 2>&1 && date -u -d "$1" +%s 2>/dev/null; }
}
input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id // empty')
# --- Diagnostic hatch, off unless ~/.claude/statusline-debug exists ---------
# Records what each terminal was HANDED and what it RENDERED, one line per
# render. Off by default (one stat(2) per render); `touch` the flag file to arm.
# Worth keeping wired in rather than re-adding ad hoc: every quota bug in this
# bar has been a disagreement between terminals, and the only way to see one is
# to watch all of them at the same instant — which is unreproducible after the
# fact, because the evidence is overwritten by the next window.
if [ -f "$HOME/.claude/statusline-debug" ]; then
  echo "$input" | jq -c --arg t "$(date +%s)" \
    '{t:$t,sid:(.session_id//""|.[0:8]),rl:.rate_limits}' \
    >> "$HOME/.claude/statusline-debug.log" 2>/dev/null
fi
# ---------------------------------------------------------------------------
model=$(echo "$input" | jq -r '.model.display_name // "Claude"' | sed 's/ context)/)/')
effort=$(echo "$input" | jq -r '.effort.level // empty')
# Kept before either one is rewritten below: $model grows a size label and a
# placeholder, $effort shrinks to a letter, and the subagent chip further down
# needs both in their original form — it inherits them for agents that have not
# said yet what they are running on.
model_name="$model"
effort_raw="$effort"
# --- The 1M families' window size is a constant, and a constant is not information
# Opus and Fable only ever run at 1M here, so "(1M)" in the name and "/1M" after
# the token count repeat, on every render of every session, a fact that was
# never in doubt. Both are dropped: the segment reads "Opus 5xh 330K" or
# "Fable 5.1h 330K", and 330K against a window everyone in the room already
# knows is the whole message. The label survives for every other family,
# because there it is a real variable — Sonnet's "/200K" is a smaller window,
# and a small window is exactly the case where "how much room is left" still
# needs its denominator spelled out. (An Opus or Fable run at 200K would keep
# its label too: the suffix is only stripped when it is the one that says
# nothing.)
is_1m_family=""
case "$model" in
  *Opus*|*Fable*) is_1m_family=1; model="${model% (1M)}" ;;
esac
# Abbreviated to its initial(s), in LOWER case. The effort level is a mode you
# set and then rarely change, so the bar only has to CONFIRM it, not teach it —
# and one letter buys back three or four columns on the most-read part of the
# line. Lower case because the abbreviation is glued straight onto the model
# name ("Opus 5m"): a capital there reads as part of the name — "Opus 5M" looked
# like a model called 5M, exactly the misreading a memory-size suffix invites on
# a line that also prints "66K/200K" — while a lower-case letter is visibly a
# modifier hanging off the name and never competes with it.
# "max" is max and not m, deliberately: m is medium, and a silent collision
# between the cheapest and the most expensive setting is the one abbreviation
# that must never happen. An unrecognised level prints raw rather than being
# guessed at — a new level is worth reading in full the first time you meet it.
case "$effort" in
  low)    effort=l ;;
  medium) effort=m ;;
  high)   effort=h ;;
  xhigh)  effort=xh ;;
  max)    effort=max ;;
esac
# Glued straight onto the name, no separator: "Opus 5h", not "Opus 5/H". The
# slash was doing the work of a delimiter in a place that has no ambiguity to
# resolve — the effort is always a trailing lower-case letter or two, and the
# model name never ends in one — so it only added a stroke of visual noise to
# the very first thing the eye lands on. Model and effort are also one thought
# ("which brain, at what setting"), and the separator kept splitting them into
# two.
if [ -n "$effort" ]; then
  case "$model" in
    *" ("*) model="${model%% (*}${effort} (${model#* (}" ;;
    *)      model="${model}${effort}" ;;
  esac
fi
# Price of the model in play, so the cache-miss figures below are this session's
# money and not a generic one: $in_rate is base input $/MTok, $rd_mult the cache
# READ multiplier. Writes are the same everywhere (1.25x for 5m, 2x for 1h); the
# read is NOT — 0.1x is the old universal rule, but Opus 5.5 reads at 0.05x and
# Fable/Mythos 5.1 at 0.025x. From the pricing page, 2026-09-30:
#   Opus 5.5  $4  in, $5 5m-write, $8 1h-write, $0.20 read, $20 out
#   Opus 5/4.5-4.8 $5 · Sonnet 5/5.5 $2 · Sonnet 4.x $3 · Haiku 4.5 $1
#   Fable 5/5.1, Mythos $10 — 1M context at the standard rate, no long-context
#   premium on any of them.
# Matched on the model ID first (it names the exact version), then on the
# untouched display name ($model_name: $model already has the effort letter glued
# on, "Opus 5.5h", and further down grows a size label and a placeholder).
# ORDER MATTERS: "opus-5" is a prefix of "opus-5-5", so every x.5 comes before
# its x. A single "*Opus*) 5" once priced Opus 5.5 at Opus 5's $5 (25% high) and
# its reads at 0.1x instead of 0.05x — the whole miss figure was ~22% too dear.
model_id=$(echo "$input" | jq -r '.model.id // empty')
rd_mult=0.1
case "$model_id $model_name" in
  *fable-5-1*|*mythos-5-1*|*"Fable 5.1"*|*"Mythos 5.1"*) in_rate=10; rd_mult=0.025 ;;
  *fable*|*mythos*|*Fable*|*Mythos*)                     in_rate=10 ;;
  *opus-5-5*|*"Opus 5.5"*)                               in_rate=4;  rd_mult=0.05 ;;
  *opus-4-1*|*opus-4-0*|*opus-4-2025*|*"Opus 4.1"*)      in_rate=15 ;;
  *opus*|*Opus*)                                         in_rate=5 ;;
  *sonnet-5*|*"Sonnet 5"*)                               in_rate=2 ;;
  *sonnet*|*Sonnet*)                                     in_rate=3 ;;
  *haiku-3*|*"Haiku 3"*)                                 in_rate=0.8 ;;
  *haiku*|*Haiku*)                                       in_rate=1 ;;
  *)                                                     in_rate=5 ;;
esac

ctx=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
total=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
# The exact prompt size of the last request (input + cache write + cache read).
# used_percentage is Math.round()ed by Claude Code, so on a 1M window it moves in
# 10K steps; this is what the miss forecast is priced off when it is present.
ctx_in=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
five=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
week=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
week_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# `rate_limits` is NOT a live feed: it caches the headers of *this session's*
# last API response. A terminal that has been idle keeps showing frozen numbers,
# which is why two terminals disagree about how much quota is left. Merge with
# the machine-wide file so every terminal displays the freshest reading any of
# them has seen. Which terminal measured it stays bookkeeping -- not worth a
# glyph -- but HOW OLD the reading is is not, see the "?" below.
#
# Freshness is something only this script can report, because only it sees the
# payload twice: if `rate_limits` differs from what this session published on the
# previous render, a new API response landed in between and the numbers are being
# observed live. If it is byte-identical, we are re-reading a frozen cache and
# must not let it pass for evidence. (Under-reporting freshness is the safe
# direction: it can only make the bar admit doubt it need not have.)
rl_now="${five:-} ${reset:-0} ${week:-} ${week_reset:-0}"
rl_seen="/tmp/claude-statusline-rl-${session_id:-default}.txt"
fresh=0
if [ -n "$five" ]; then
  [ "$(cat "$rl_seen" 2>/dev/null)" = "$rl_now" ] || fresh=1
  [ "$fresh" = 1 ] && printf '%s' "$rl_now" > "$rl_seen"
fi
merged=$("$HOME/.claude/hooks/quota-state.sh" publish \
  "${five:-}" "${reset:-0}" "${week:-}" "${week_reset:-0}" "$fresh" 2>/dev/null)
five_age=""
if [ -n "$merged" ]; then
  m_five=$(printf '%s' "$merged" | cut -d' ' -f1)
  m_reset=$(printf '%s' "$merged" | cut -d' ' -f2)
  m_week=$(printf '%s' "$merged" | cut -d' ' -f3)
  m_week_reset=$(printf '%s' "$merged" | cut -d' ' -f4)
  m_meas=$(printf '%s' "$merged" | cut -d' ' -f5)
  if [ "$m_five" != "-1" ]; then
    five=$m_five
    reset=$m_reset
    case "$m_meas" in ''|*[!0-9]*|0) five_age=999999 ;;
      *) five_age=$(( $(date +%s) - m_meas )); [ "$five_age" -lt 0 ] && five_age=0 ;;
    esac
  fi
  if [ -n "$m_week" ] && [ "$m_week" != "-1" ]; then
    week=$m_week
    week_reset=$m_week_reset
  fi
  # Fields 6-8 are the account's tightest PER-MODEL weekly cap -- Fable has had
  # one since 2026-09 -- with the model's name and its own reset. It is a
  # different budget from the weekly above, not a better reading of it, so it
  # gets its own chip rather than being folded in. Probe-only: a session's
  # `rate_limits` never carries it, which is why it survives a render where the
  # probe has not run (quota-state.sh passes it through untouched).
  wscoped=$(printf '%s' "$merged" | cut -d' ' -f6)
  wscoped_label=$(printf '%s' "$merged" | cut -d' ' -f7)
  wscoped_reset=$(printf '%s' "$merged" | cut -d' ' -f8)
fi

# The merge above is only as good as the freshest SESSION cache on the machine,
# and a cache cannot notice an allowance that GREW: after a plan switch (Max 5x
# -> 20x, 2026-09-11) every idle terminal kept re-publishing the old plan's 94%
# and the bar read "6% left" for hours while the account was at 5% used -- see
# the header of quota-state.sh. So every CLAUDE_QUOTA_PROBE_SECS (300) some
# render kicks quota-probe.sh, which asks the account's usage endpoint and
# writes BOTH windows into quota.json as the reading the merge lets no frozen
# payload displace; it lands in $merged on the next render, so the 5h figure is
# corrected by the same request and is fresh by construction (measured_at=now).
# Kicked in the background and only when the stamp's mtime is old, so a render
# costs one stat(2) here; the probe takes a lock, so a hundred renders racing
# across the boundary send one request between them.
probe_stamp="${CLAUDE_QUOTA_PROBE_FILE:-$HOME/.claude/quota-probe}"
probe_secs="${CLAUDE_QUOTA_PROBE_SECS:-${CLAUDE_WEEKLY_QUOTA_PROBE_SECS:-300}}"
case "$probe_secs" in ''|*[!0-9]*|0) probe_secs=300 ;; esac
probe_at=$(file_mtime "$probe_stamp")
case "$probe_at" in ''|*[!0-9]*) probe_at=0 ;; esac
if [ "$(( $(date +%s) - probe_at ))" -ge "$probe_secs" ] \
   && [ -x "$HOME/.claude/hooks/quota-probe.sh" ]; then
  nohup "$HOME/.claude/hooks/quota-probe.sh" >/dev/null 2>&1 </dev/null &
fi
# Past this, no terminal on the machine has re-confirmed the 5h figure and it is
# no longer a fact, only the last thing anybody saw. It is still the best number
# available -- so it is shown, but marked (see $STALE_5H use below).
STALE_5H="${CLAUDE_QUOTA_STALE_SECS:-900}"

ESC=$(printf '\033')
RESET="${ESC}[0m"
ORANGE="${ESC}[38;5;208m"
RED="${ESC}[31m"
BLUE="${ESC}[38;5;111m"
GREEN="${ESC}[38;5;78m"
# Claude Code paints the prompt box border and the session title on it in teal;
# 80 (#5fd7d7) is the closest 256-colour match, so the folder name in the status
# line reads as part of that same frame. Bump to 73/79/116 to taste.
TEAL="${ESC}[38;5;80m"
# Grey is the "do not act on this" colour: it says the figure is present but
# unverified, without borrowing the meaning of orange/red (which mean "low").
GREY="${ESC}[38;5;244m"

# --- Light page -------------------------------------------------------------
# The Claude theme is `custom:follow-macos`, whose `base` Victor Addons flips
# with the macOS appearance, and session-color.sh repaints the Claude tabs with
# it: #2e3440 polar night in dark mode, #eceff4 snow storm in light mode. Every
# colour above was tuned on the dark tint — 111/78/80 are pale enough to vanish
# on the light one, and the quota and folder chips turn into heavy dark blocks.
# So on a light page the text colours drop to their deep counterparts and every
# chip becomes a pastel ground under black text. Read from the theme file, not
# from `defaults`: a builtin read instead of a fork per render, and it is the
# exact switch Claude itself is following. CLAUDE_STATUSLINE_LIGHT=0/1 overrides.
LIGHT_UI="${CLAUDE_STATUSLINE_LIGHT:-}"
if [ -z "$LIGHT_UI" ]; then
  LIGHT_UI=0
  _theme_json=''
  [ -r "$HOME/.claude/themes/follow-macos.json" ] \
    && read -r _theme_json < "$HOME/.claude/themes/follow-macos.json" 2>/dev/null
  case "$_theme_json" in *'"base": "light"'*) LIGHT_UI=1 ;; esac
fi
if [ "$LIGHT_UI" = 1 ]; then
  ORANGE="${ESC}[38;5;166m"
  BLUE="${ESC}[38;5;25m"
  GREEN="${ESC}[38;5;28m"
  TEAL="${ESC}[38;5;30m"
fi

# --- Bloom ramp: the five brightness steps the running turn's cost breathes
# through, in step with the flower's own bloom (see the $((now % 9)) case below).
# The clay/salmon family, because that is what Claude Code paints "Working…" in
# — the two are not synchronised (the spinner redraws several times a second and
# does not expose its phase; this bar redraws once), but they should at least be
# the same colour of "busy".
#
# The ramp travels pale -> SATURATED, not dark -> light. A luminance ramp only
# works against a known background, and this bar is read on a white IntelliJ
# terminal as often as on a dark one: #ffd7af at the peak is invisible on white,
# #444 at the trough is invisible on black. Saturation survives both, so every
# frame stays legible and only the *urgency* of the hue moves.
BLOOM0="${ESC}[38;5;180m"   # #d7af87 palest — the closed "·"
BLOOM1="${ESC}[38;5;174m"   # #d78787 muted salmon
BLOOM2="${ESC}[38;5;173m"   # #d7875f clay, Claude's own
BLOOM3="${ESC}[38;5;209m"   # #ff875f coral
BLOOM4="${ESC}[38;5;202m"   # #ff5f00 peak — full bloom, and the "$" flash

# --- Warning hue (was: Blink) ------------------------------------------------
# No longer blinks (7 Oct 2026): the warning is a steady foreground hue. It used
# to alternate between the hue and the terminal's normal colour once a second;
# the history below explains why it was two states rather than a ramp.
#
# This replaces a six-step background ramp that breathed from black up to full
# hue and back. The ramp had the failure mode of all gradients used as alarms:
# adjacent frames differ so little that the movement only registers if you are
# already looking at it, which is precisely the case where you did not need to be
# told. Two states are unmissable in peripheral vision, which is the only place
# this warning is ever actually seen. Losing the background also gives the digits
# back the terminal's own contrast instead of white-on-dark-red.
#
#   pulse red|orange <text>
pulse() {
  _hue=$1; shift
  case "$_hue" in
    red) _col=$RED ;;
    *)   _col=$ORANGE ;;
  esac
  # STEADY since 7 Oct 2026: Victor asked for no more blinking — the warning
  # stays lit in its hue on every frame. The name and the call sites are kept
  # so the "which cells light up together" logic below is unchanged.
  printf '%s%s%s' "$_col" "$*" "$RESET"
}

if [ -n "$ctx" ]; then
  ctx_pct=$(printf '%.0f' "$ctx")

  # Resolve size label
  size_label=""
  if echo "$model" | grep -q '('; then
    size_label=$(echo "$model" | sed -n 's/.*(\(.*\)).*/\1/p')
    model=$(echo "$model" | sed 's/ *(.*)//')
  elif [ -n "$total" ]; then
    if [ "$total" -ge 1000000 ]; then
      size_label=$(printf '%.0fM' "$(echo "$total / 1000000" | bc -l)")
    else
      size_label=$(printf '%.0fK' "$(echo "$total / 1000" | bc -l)")
    fi
  fi

  if [ -n "$size_label" ] && [ -n "$total" ]; then
    used_tokens=$(printf '%.0f' "$(echo "$ctx * $total / 100" | bc -l)")
    if [ "$used_tokens" -ge 1000000 ]; then
      abs_label=$(printf '%.2fM' "$(echo "$used_tokens / 1000000" | bc -l)")
    elif [ "$used_tokens" -ge 1000 ]; then
      abs_label=$(printf '%.0fK' "$(echo "$used_tokens / 1000" | bc -l)")
    else
      abs_label="${used_tokens}"
    fi
    pct_str="${ctx_pct}%"
    if [ "$ctx_pct" -ge 95 ]; then
      pct_str="${RED}${pct_str}${RESET}"
    elif [ "$ctx_pct" -ge 65 ]; then
      pct_str="${ORANGE}${pct_str}${RESET}"
    fi
    # On a 1M window the denominator is dropped entirely for Opus and Fable
    # (see the is_1m_family note at the top) and the "• N%" goes with it: the
    # pair "330K" and "a window you already know is 1M" IS the ratio, and a
    # percentage would only restate it in a second unit. Any other family on a
    # 1M window keeps "used/size", which is likewise self-evident. Smaller
    # windows keep the explicit "• N%", where the ratio is not something the
    # eye can do on sight.
    # The token count is emitted as a PLACEHOLDER, not as final text: whether it
    # should sit still in blue or breathe orange/red depends on the prompt-cache
    # TTL and on how long you have been idle, and neither is known until the
    # transcript has been parsed a hundred lines below. Substituting at the end
    # keeps this block about layout and the pulse decision in one place with the
    # other cache logic, instead of splitting the rule across the file.
    if [ "$size_label" = "1M" ] && [ -n "$is_1m_family" ]; then
      model="$model @@CTX@@"
    elif [ "$size_label" = "1M" ]; then
      model="$model @@CTX@@/${size_label}"
    else
      model="$model @@CTX@@/${size_label} • ${pct_str}"
    fi
  fi
fi

# **A microphone in front of the row when Walkie Talkie is bound to THIS
# session.** The relay's chip already says where the words go, and it says it
# beside the cursor — the one place Victor is not looking while an agent works,
# and which macOS hides the moment he touches the keyboard. In a screen of
# identical terminals that left *which of these is bound?* unanswered anywhere in
# the window itself. This row is always at the bottom of the right terminal.
#
# **On a violent background, not as a bare emoji.** 🎙️ alone on the status line
# is one more glyph in a row already full of them — it was there and could not be
# seen, which is the same failure the chip's own selection row had. White on 196
# is a badge: the eye finds it without reading the row.
#
# **The tty is the only handle both sides hold.** The relay binds a Terminal tab
# by tty and publishes it; this bar already resolves its own tty for the
# `~/.claude/cwd/<ttysNNN>` publisher below, and for the same reason — $PPID's,
# not $$'s, since Claude Code spawns this script without a controlling terminal
# but keeps one itself.
#
# **The fast path is a file that is not there.** Nothing bound means one failed
# builtin `read` and no fork at all, which matters on a bar that re-renders every
# second in every open session. The `ps` runs only when a binding exists *and*
# this session's tty has not been resolved yet — once per session, memoised
# beside the cwd markers.
mic=""
_bt=""
[ -r "$HOME/.walkie-talkie/bound-tty" ] && read -r _bt < "$HOME/.walkie-talkie/bound-tty" 2>/dev/null
if [ -n "$_bt" ]; then
  _mytty=""
  _ttyf="$HOME/.claude/cwd/.tty-$PPID"
  [ -r "$_ttyf" ] && read -r _mytty < "$_ttyf" 2>/dev/null
  if [ -z "$_mytty" ]; then
    # tr, not ${_mytty// /}: this is a #!/bin/sh script and dash aborts the whole
    # render on that bash-only expansion ("Bad substitution").
    _mytty=$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')
    case "$_mytty" in
      ttys*) { mkdir -p "$HOME/.claude/cwd" && printf '%s' "$_mytty" > "$_ttyf"; } 2>/dev/null || : ;;
    esac
  fi
  if [ -n "$_mytty" ] && [ "$_bt" = "$_mytty" ]; then
    # **Yellow means aimed here.** The one fact the marker carries — this is the
    # session the relay's words would come to — on the one row that is always on
    # screen. Black on the 226: yellow that bright cannot carry white text, and a
    # badge that has to be squinted at is the failure this background was added
    # to fix in the first place.
    mic="${ESC}[1;30;48;5;226m 🎙️ ${RESET} "
  fi
fi
unset _bt _mytty _ttyf

out="${mic}${model}@@SUB@@"

# quota-gate.sh writes the wake epoch and the window that caused this terminal
# to park. Old one-field markers predate weekly gating and are therefore 5h.
# Read it once so the sleep indicator can be attached to the matching quota.
park_wake=""
park_window=""
park="$HOME/.claude/quota-park/$session_id"
if [ -n "$session_id" ] && [ -f "$park" ]; then
  IFS=' ' read -r park_wake park_window < "$park" || :
  [ -n "$park_window" ] || park_window=five_hour
  case "$park_window" in five_hour|seven_day|weekly_scoped) ;; *) park_wake=""; park_window="" ;; esac
  case "$park_wake" in
    ''|*[!0-9]*) park_wake=""; park_window="" ;;
    *)
      park_now=$(date +%s)
      if [ "$park_wake" -le "$park_now" ] 2>/dev/null; then
        park_wake=""; park_window=""
      fi
      ;;
  esac
fi

if [ -n "$five" ]; then
  left=$(printf '%.0f' "$(echo "100 - $five" | bc -l)")
  # --- The quota chip: this cell's own background block ----------------------
  # Same move as the folder chip further down, and for the same reason: a
  # painted block is a harder edge than a pipe, so the two pipes that used to
  # fence this cell off are gone and a single space on each side does the job.
  # With the folder already chipped, chipping this one turns the bar into a
  # ZEBRA -- model, [chip], spend, [chip], weekly -- and alternating ground is
  # something the eye sorts before it has read a single glyph, which is exactly
  # what a status bar wants from its separators.
  #
  # The ground is DARK and light text stays light, unlike the folder chip's pale
  # half. A pale block here was tried first and read as violent: it lands in the
  # middle of the bar, it is on screen every second of every session, and the
  # eye kept going to it instead of to the thing it was actually looking for.
  # 60 (#5f5f87) is one step up from the window's own polar night (#2e3440) in
  # the same blue-grey family -- close enough to sit quietly, far enough to
  # still read as a block. The folder chip is the loud one BY DESIGN (it changes
  # per folder, so it has to be told apart from nineteen others); this one never
  # changes, so it only has to be found.
  #
  # The ground carries the low-quota alarm, staying dark as it does so.
  # Painting the digits red inside the cell is the weaker signal of the two, and
  # it never worked anyway: $pct_part already ends in a colour reset from the
  # arrow, so the wrapping red died before it reached the number it was meant to
  # warn about. Moving the alarm to the background fixes that by construction --
  # no inner sequence can cancel a ground -- and the whole cell changes colour at
  # a glance instead of two digits inside it.
  #   >=15%  slate blue-grey (60) -- calm, the steady state, matched to the window
  #   <15%   dark amber      (94) -- spend it more slowly
  #   <5%    dark maroon     (88) -- about to run out
  # Text stays 231 on all three: the alarm is the hue of the block, not a
  # second thing to read.
  _qbg=60
  if [ "$left" -lt 5 ] 2>/dev/null; then
    _qbg=88
  elif [ "$left" -lt 15 ] 2>/dev/null; then
    _qbg=94
  fi
  # Every colour used INSIDE the chip carries the ground with it, and "back to
  # normal" means back to $QCHIP, never $RESET: a reset punches a hole straight
  # through the block, and the arrow, the 💤 and the stale "?" all sit in the
  # middle of it. The hues are the bar's usual green/orange/red -- they were
  # tuned for a dark terminal and this ground is a dark terminal -- except the
  # grey, which climbs from 244 to 248 because 244 on a lifted ground is no
  # longer muted, it is merely dim.
  _qb="${ESC}[48;5;${_qbg}m"
  QCHIP="${_qb}${ESC}[38;5;231m"
  QGREEN="${_qb}${ESC}[38;5;78m"
  QORANGE="${_qb}${ESC}[38;5;208m"
  QRED="${_qb}${ESC}[38;5;203m"
  QGREY="${_qb}${ESC}[38;5;248m"
  # Light page: the same three states as pastels — lavender 189 (calm), peach
  # 223 (<15%), pink 217 (<5%) — under black text, with the arrow hues deepened
  # to stay legible on a pale ground.
  if [ "$LIGHT_UI" = 1 ]; then
    case "$_qbg" in 88) _qbg=217 ;; 94) _qbg=223 ;; *) _qbg=189 ;; esac
    _qb="${ESC}[48;5;${_qbg}m"
    QCHIP="${_qb}${ESC}[38;5;16m"
    QGREEN="${_qb}${ESC}[38;5;28m"
    QORANGE="${_qb}${ESC}[38;5;166m"
    QRED="${_qb}${ESC}[38;5;160m"
    QGREY="${_qb}${ESC}[38;5;242m"
  fi
  ind=""
  dur=""
  until_time=""
  if [ -n "$reset" ]; then
    now=$(date +%s)
    diff=$((reset - now))
    if [ "$diff" -gt 0 ]; then
      h=$((diff / 3600))
      m=$(((diff % 3600) / 60))
      until_time=$(fmt_epoch "$reset" +%H:%M)
      # "1h23", not "1:23". A colon is how a WALL CLOCK is written, and this
      # segment has a real wall clock in it ($until_time, the reset hour), so
      # "1:23" invited exactly one misreading — a time of day rather than the
      # time still to run. Unit letters cannot be misread as an hour. Under an
      # hour it is already "23m" and stays that way; the "h" only shows up when
      # there are hours to show, and the minutes stay zero-padded behind it
      # ("1h05") so the field does not change width as the hour drains.
      if [ "$h" -gt 0 ]; then
        dur=$(printf '%dh%02d' "$h" "$m")
      else
        dur="${m}m"
      fi
      # Burn-rate vs time: compare quota-remaining to time-remaining within the
      # 5h (18000s) window. ratio r = quota_left_frac / time_left_frac.
      # r>1 => more quota than time left (surplus); r<1 => burning too fast.
      ind=$(awk -v five="$five" -v diff="$diff" 'BEGIN{
        q=(100-five)/100; t=diff/18000;
        if (t<=0){ exit }
        r=q/t;
        if (r>=1.5)       print "↑";
        else if (r>=1.15) print "↗";
        else if (r>=0.87) print "";
        else if (r>=0.67) print "↘";
        else              print "↓";
      }')
      # Color the burn-rate arrow: up/surplus green, mild deficit orange, hard deficit red.
      case "$ind" in
        "↑"|"↗") ind="${QGREEN}${ind}${QCHIP}" ;;
        "↘")     ind="${QORANGE}${ind}${QCHIP}" ;;
        "↓")     ind="${QRED}${ind}${QCHIP}" ;;
      esac
    fi
  fi
  # Arrow LEADS the number ("↗98%"), it does not trail it. The arrow is the
  # part you read at a glance without parsing digits, and in a left-to-right line
  # the glance lands on the first glyph of the segment — so the trend gets that
  # slot and the exact figure follows for when you actually care.
  #
  # Unless nobody has re-confirmed the reading in $STALE_5H, in which case both
  # of those glyphs are withdrawn and a grey "?" takes their place. The arrow is
  # the part that has to go FIRST: it is computed from quota-left over
  # time-left, so a reading frozen early in the window scores a huge surplus and
  # paints a confident green "↑" — the bar's single most reassuring glyph — at
  # precisely the moment it knows least. "↑78% / 19m" was that failure: not
  # a wrong number politely displayed, but a wrong number ENDORSED. A stale
  # figure is still the best one available and is still shown; what it loses is
  # the right to be believed.
  if [ -n "$five_age" ] && [ "$five_age" -gt "$STALE_5H" ] 2>/dev/null; then
    pct_part="${QGREY}${left}%?${QCHIP}"
  else
    pct_part="${ind}${left}%"
  fi
  # "↗98% / 1h23": quota-left and time-left are two readings of the SAME
  # window, joined with "/" rather than the "•" it replaces. "/" is the only
  # separator inside the cell; where the cell itself ends is said by the chip's
  # edge, which is why there is no pipe around it any more.
  #
  # The word "left" used to trail the pair, on the argument that one label could
  # cover both figures. It could -- and it was still dead weight. Neither figure
  # has ever meant anything else here: a percentage that only ever counts down
  # and a duration that only ever counts down are both obviously remainders, and
  # in months of reading this bar the word never once resolved an ambiguity. It
  # was five columns and a word-shaped speed bump between the numbers and the
  # next segment, on the segment that changes fastest. Dropped in both shapes,
  # with and without a duration.
  # Parked by quota-gate.sh: the account confirmed low quota, and the gate will
  # recheck at $pwake. The glyph stays glued to the quota figure; the next probe
  # clock precedes the reset countdown: "↓1%💤 → 23:21 / 2h20". The two clocks
  # describe different facts, just as they do in the weekly cell.
  #
  # The countdown is still what proves the terminal is alive rather than hung:
  # `refreshInterval` re-runs this script regardless of activity and the gate's
  # `sleep` runs in a child process, so $dur ticks down every render while the
  # turn is blocked.
  #
  # If neither `date -r` (BSD) nor `date -d @` (GNU) can resolve $pwake there is
  # no clock to land on, and the
  # sleep countdown comes back glued to the glyph ("💤2h22") rather than being
  # guessed at — the only case where the second duration earns its columns is
  # the one where it is the only absolute information available.
  sleep_mark=""
  sleep_tail=""
  if [ "$park_window" = five_hour ]; then
    pwake=$park_wake
    pnow=$park_now
    if [ -n "$pwake" ]; then
      pclock=$(fmt_epoch "$pwake" +%H:%M)
      if [ -n "$pclock" ]; then
        sleep_mark="${QORANGE}💤${QCHIP}"
        sleep_tail=" ${QORANGE}→ ${pclock}${QCHIP}"
      else
        pleft=$((pwake - pnow))
        ph=$((pleft / 3600))
        pm=$(((pleft % 3600) / 60))
        if [ "$ph" -gt 0 ]; then
          pfmt=$(printf '%dh%02d' "$ph" "$pm")
        elif [ "$pm" -gt 0 ]; then
          pfmt="${pm}m"
        else
          # Sub-minute: "0m" reads as "stuck", "<1m" reads as "about to wake".
          pfmt="<1m"
        fi
        sleep_mark="${QORANGE}💤${pfmt}${QCHIP}"
      fi
    fi
  fi
  # Low quota is painted by the CHIP'S GROUND, chosen with $_qbg above -- there
  # is no per-figure colouring left here. The old shape wrapped $pct_part and
  # $dur in red, and it could not work: both already end in a colour reset (the
  # arrow's, the 💤's), so the wrapping colour was cancelled before it reached
  # the digits. A ground cannot be cancelled from the inside, and it warns
  # across the whole cell instead of two characters within it.
  if [ -n "$dur" ]; then
    if [ -n "$sleep_tail" ]; then
      body="${pct_part}${sleep_mark}${sleep_tail} / ${dur}"
    else
      body="${pct_part}${sleep_mark} / ${dur}"
    fi
  else
    body="${pct_part}${sleep_mark}${sleep_tail}"
  fi
  five_str="${QCHIP}${body}${RESET}"
  # A space on each side, no pipes: the chip's own edges already say where the
  # cell starts and stops (same argument as the folder chip). The trailing space
  # is handed to whoever comes next through $_five_sep, so the pipe comes back
  # by itself on the days this cell is missing entirely.
  out="$out $five_str"
  _five_sep=' '
fi

# Session spend, broken down as: last turn + session total, each with its token count.
# cost.total_cost_usd is authoritative (matches /usage "Total cost", incl. subagents) but
# is only a running session total; the transcript has no per-message cost (costUSD is null).
# So the last turn's cost is tracked as the delta of the session total since the turn began,
# and the last turn's tokens are summed from the transcript's assistant messages after the
# most recent user prompt. Tokens are deduped by requestId (streaming logs the same usage
# on several lines per API request, so a naive sum over-counts ~2-3x).
abbr_tok() {
  t=$1
  if [ "$t" -ge 1000000 ] 2>/dev/null; then
    printf '%.2fM' "$(echo "$t / 1000000" | bc -l)"
  elif [ "$t" -ge 1000 ] 2>/dev/null; then
    printf '%.0fK' "$(echo "$t / 1000" | bc -l)"
  else
    printf '%s' "$t"
  fi
}

# Format seconds-since-the-turn-ended as " <rel>" (leading space included):
#   <60s -> "-Ns" (ticks -1s,-2s,-3s...), <60m -> "-Nm", else ">1h".
# The leading MINUS is what the word "ago" used to do, in one glyph instead of
# four: a signed offset from now, the same convention a diff or a timeline uses.
# It reads at a glance in a bar where every other cell is already a number, and
# it buys back three cells in the one segment that also has to fit a price.
# ">1h" keeps its own shape — the ">" already points the same direction the minus
# would, and "->1h" would stack two symbols onto one meaning.
# Colored against the ACTUAL prompt-cache TTL of this session ($ttl_secs, read
# off the API usage — 300s or 3600s, see below), not a hardcoded 5 minutes:
#   orange in the last 20% before the TTL (spend it or lose it),
#   red once the TTL has passed (the prefix is gone; your next message pays the
#   cache-WRITE price again — 1.25x or 2x — instead of the read price, $rd_mult).
# Concretely, on a 5-minute TTL: "-4m" is >= 240s and still under 300s, so it
# goes ORANGE — the prefix is alive and you have about a minute to use it.
# "-51m" is far past 300s, so it goes RED — that cache is already gone.
# On a 1-hour TTL the same two readings say the opposite thing: "-4m" is not
# coloured at all, and "-51m" is the orange one (48m is 80% of 60m) with red
# only from 60m on. Which is exactly why the TTL is detected rather than assumed
# — the same "-51m" is a shrug or an emergency depending on it.
# The colour BLINKS only above $MISS_FLOOR; below it the same verdict, price and
# all, is rendered once in the normal colour (see the report-vs-alarm note below).
# Uses globals $used_tokens/$ttl_secs/colors. Echoes nothing for invalid input.
fmt_age() {
  _secs=$1
  case "$_secs" in ''|*[!0-9]*) return 0 ;; esac
  _mins=$((_secs / 60))
  if [ "$_mins" -lt 1 ]; then
    _rel="-${_secs}s"
  elif [ "$_mins" -lt 60 ]; then
    # Minutes stay unrounded through the whole first hour — that is the range
    # where the 1h cache is still the thing being decided about, and where the
    # difference between 41m and 58m is the difference between "later" and "now".
    _rel="-${_mins}m"
  else
    # Past an hour every cache is gone and the reading stops being actionable:
    # 2h, 16h and 3d all mean the same single thing — you are rebuilding from
    # scratch — so they collapse into one glyph-cheap ">1h" rather than three
    # buckets that invite you to compare numbers that no longer differ in
    # consequence. It also reads as its own verdict, which is why the "> TTL"
    # comparison below is dropped in this case: ">1h > 1h" is noise.
    _rel=">1h"
  fi
  # Say WHY it is blinking, in the terms the reader would otherwise have to
  # supply from memory: the idle time, the TTL it is measured against, and what
  # crossing it costs. "-51m" alone is a number with no verdict attached —
  # "(-51m > 5m⇒+=$1.7)" is the verdict, and it is also the one form that
  # survives the TTL being 1h instead of 5m without silently changing meaning.
  #
  # The whole clause sits INSIDE one pair of brackets because it is one
  # statement, not two. The older shape — "-51m > 5m (miss=$1.7)" — put the age
  # and the price side by side as if they were separate readings you happened to
  # get at the same time, and left the reader to supply the connective. They are
  # not separate: the idle time is the CAUSE and the price is its CONSEQUENCE,
  # so "⇒" is printed rather than implied, and "+=" says the figure is what your
  # next message ADDS on top of the turn price to its left, not a second total
  # competing with it. Bracketing the pair also stops the price from floating
  # loose next to the "⊂ $10" that follows and reading as part of the budget.
  # The word "miss" used to sit between "⇒" and "+=" and was dropped (2 Oct 2026):
  # an age past the TTL, an arrow and an added price already say it, and the
  # word only made the clause wider.
  #
  # Only the two VARIABLES blink — the elapsed time and the price. The words
  # around them ("> 5m", "⇒+=") are fixed scaffolding that says how to
  # read those two figures, and blinking them too just widened the flashing block
  # until it was a bar of moving text you had to wait out to read. Held steady,
  # they stay legible during the off-beat and the eye lands straight on whichever
  # of the two numbers it came for.
  #
  # REPORTING and ALARMING are two different thresholds. The price is stated for
  # every expired cache, however small, because it is the answer to a question you
  # may be asking on purpose ("what did stepping away just cost me?") and a number
  # withheld below an arbitrary line is a bar you cannot use to check. The BLINK is
  # reserved for the ones worth interrupting you over ($MISS_FLOOR). So a cheap
  # miss prints "(-51m > 5m⇒+=$1.4)" in plain text and stays out of the way,
  # and only a dear one starts moving.
  _phase=$(cache_phase "$_secs")
  case "$_phase" in
    expired)  _hue=red ;;
    expiring) _hue=orange ;;
    *)        printf ' %s' "$_rel"; return 0 ;;
  esac
  # ">1h" is already its own verdict, so it does not also get compared to the TTL.
  _cmp=""
  if [ "$_rel" != ">1h" ]; then
    if [ "$_phase" = expired ]; then _cmp=" > $(fmt_ttl)"; else _cmp=" <= $(fmt_ttl)"; fi
  fi
  # One floor is not a policy choice but arithmetic: below 5 cents the figure
  # rounds to "$0.0", and printing a price of zero says less than printing nothing.
  _price=$(miss_cost)
  if [ "$_price" = '$0.0' ]; then
    printf ' %s%s' "$_rel" "$_cmp"
  elif miss_big; then
    printf ' (%s%s⇒+=%s)' \
      "$(pulse "$_hue" "$_rel")" "$_cmp" "$(pulse "$_hue" "$_price")"
  else
    printf ' (%s%s⇒+=%s)' "$_rel" "$_cmp" "$_price"
  fi
}

# The TTL as the reader thinks of it, not in seconds.
fmt_ttl() {
  if [ "${ttl_secs:-300}" -ge 3600 ]; then echo "1h"; else echo "5m"; fi
}

# What crossing the TTL just cost, in dollars, on the ONLY question that has a
# defensible answer: the cached prefix has to be written again at the cache-WRITE
# price instead of being read at the cache-READ price, so the loss is the spread
# between the two multipliers over the tokens that had to be rebuilt.
#
#   miss $ = tokens x $in_rate x (write - $rd_mult)
#   write = 1.25x on a 5m TTL, 2x on a 1h one; read = 0.1x, but 0.05x on Opus 5.5
#   and 0.025x on Fable/Mythos 5.1 (see $rd_mult at the top).
#   Opus 5.5, 1h TTL: 4 x (2 - 0.05) = $7.80 per MTok rebuilt.
#
# The spread is not "1.9x of whatever the input rate is": with the read at 0.05x
# it is 1.95x, and on the model that bills $4 — not the $5 the old flat Opus rate
# assumed — so the flat formula overstated every Opus 5.5 miss by ~22% before
# counting anything else.
#
# The 1h cache costs nearly twice as much to lose as the 5m one, which is the
# opposite of the intuition that a longer TTL is strictly the safer setting —
# reason enough to print the number rather than leave it to be guessed at.
#
# $1 = tokens that are (or were) rebuilt; $2 = the write multiplier they were
# (or will be) written at. The two callers price two different things:
#   * the idle clock FORECASTS losing what you are sitting on right now:
#     $fc_tokens = the live prompt MINUS the part a cold start still reads back
#     (the system prompt and tools, which other sessions keep warm — measured
#     25-28K on every real miss here), at the session's own TTL;
#   * the "(N⏱)" tag prices a rebuild that ALREADY happened, off the usage of
#     the request that paid it: what it wrote (never more than what was cached
#     before, never the new message on top), at the 5m/1h split it was billed at.
# Omit both and it is the forecast.
#
# Shown from the moment the cache is at risk (orange, still savable) as well as
# past the TTL, at any size. Naming the price while the prefix is still alive is
# the whole point of the orange phase: "-4m <= 1h" is a deadline with no stake
# attached, and a deadline you cannot price is one you cannot decide about.
#
# miss_usd is the raw number for arithmetic, miss_num the same figure formatted
# for the bar, miss_cost that with the "$" glued on, miss_big the blink threshold
# as a true/false. All of them off one expression, because the threshold test and
# the displayed price must be the same quantity — a gate computed one way and a
# price printed another is how you get a bar that blinks while showing a number
# below its own stated floor.
ttl_wmult() { if [ "${ttl_secs:-300}" -ge 3600 ]; then echo 2; else echo 1.25; fi; }
miss_usd() {
  awk -v t="${1:-${fc_tokens-${used_tokens:-0}}}" -v r="${in_rate:-5}" \
      -v w="${2:-$(ttl_wmult)}" -v rd="${rd_mult:-0.1}" \
    'BEGIN{ if (t < 0) t = 0; printf "%.4f", t/1000000 * r * (w - rd) }'
}
# The bare figure, no currency sign: the turn-cost segment prints its own "$"
# (or the flower standing in for it) at the head of the cell and then folds the
# miss in as a parenthetical — "$5.2(2.7⏱)" — so a second "$" inside it would
# be claiming a second unit for the same money.
miss_num() {
  awk -v c="$(miss_usd "$@")" \
    'BEGIN{ printf (c >= 10 ? "%.0f" : "%.1f"), c }'
}
miss_cost() { printf '$%s' "$(miss_num "$@")"; }
# One decimal, always TRUNCATED, never rounded — the same rule the session total
# obeys, applied to the turn figure sitting next to it. Both figures have to be
# cut the same way or the "⊂" starts lying: $3.26 of session spent entirely in
# one turn rounds the turn UP to 3.3 while the total truncates DOWN to 3.2, and
# the bar prints "✻3.3 ⊂ $3.2" — a subset larger than the set containing it.
# The +1e-9 defends against 3.2*10 = 31.999999999999996 in binary floating point.
trunc1() { awk -v v="${1:-0}" 'BEGIN{ printf "%.1f", int(v*10 + 1e-9)/10 }'; }
# Is the loss big enough to MOVE for? The gate used to be a flat 100K tokens,
# which is the wrong unit: what makes a miss worth interrupting you over is the
# MONEY, and the same 100K on a 1h TTL is ~19c of Haiku and ~78c of Opus 5.5.
# Testing the dollar figure the bar is about to print also makes the rule
# self-evident on screen — you see "⇒+=$2.1" blinking next to a "⇒+=$1.4"
# that does not, and the reason is the number itself, not a token count you would
# have to convert. Raise the floor if the bar still interrupts too eagerly:
#   export CLAUDE_MISS_FLOOR=5
MISS_FLOOR="${CLAUDE_MISS_FLOOR:-2}"
miss_big() {
  awk -v c="$(miss_usd "$@")" -v f="$MISS_FLOOR" 'BEGIN{ exit !(c > f) }'
}

# Which side of the prompt-cache TTL is this idle gap on? The single source of
# truth for both things that react to it — the "-N" clock and the context
# counter — so they can never disagree about what state the cache is in.
#   expiring = inside the last 20% before the TTL: the prefix is still warm, send
#              something NOW and you keep paying 0.1x
#   expired  = past the TTL: the prefix is gone, the next message rebuilds it at
#              1.25x
# Purely a question about TIME. It deliberately does NOT know about $MISS_FLOOR:
# what the cache is doing and whether that is worth an alarm are two separate
# facts, and folding the money into this predicate made the cheap case
# indistinguishable from "the prefix is fine" — so the clock could not report a
# $1.40 miss it knew perfectly well had happened. Callers ask this what the state
# is, then ask miss_big whether to shout about it.
cache_phase() {
  _s=$1
  case "$_s" in ''|*[!0-9]*) echo none; return ;; esac
  _t=${ttl_secs:-300}
  if [ "$_s" -ge "$_t" ]; then echo expired
  elif [ "$_s" -ge $((_t * 4 / 5)) ]; then echo expiring
  else echo none
  fi
}

cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
[ -n "$cost" ] || cost=0
tp=$(echo "$input" | jq -r '.transcript_path // empty')
spend_seg=""

if [ -n "$tp" ] && [ -f "$tp" ]; then
  tok_prog='
def utoks($u): ($u // {}) | ((.input_tokens//0)+(.output_tokens//0)+(.cache_read_input_tokens//0)+(.cache_creation_input_tokens//0));
# Everything that was SENT on a request (prompt side only, no output): the three
# input buckets. On a cache hit almost all of it lands in cache_read.
def ptoks($u): ($u // {}) | ((.input_tokens//0)+(.cache_read_input_tokens//0)+(.cache_creation_input_tokens//0));
def isprompt: (.type=="user") and (.isSidechain!=true) and (.isMeta!=true)
  and (((.message.content|type)=="string")
       or (((.message.content|type)=="array") and ((.message.content|map(.type)|index("tool_result"))==null)));
. as $all
| ([ range(0; ($all|length)) as $i | select($all[$i]|isprompt) | $i ] | last) as $lu
| ([ range(0; ($all|length)) as $i | select($all[$i].type=="assistant" and ($all[$i].isSidechain != true)) | $i ] | last) as $lastA
| ($lastA != null
   and (($all[$lastA].message.stop_reason // "") != "tool_use")
   and ([ range(($lastA + 1); ($all|length)) as $j
          | select($all[$j].type=="user" and ($all[$j].isSidechain != true) and ($all[$j].isMeta != true)) ] | length) == 0
  ) as $idle
| ([ $all[] | select(.type=="assistant" and .requestId!=null) ] | group_by(.requestId) | map(utoks(.[0].message.usage)) | add // 0) as $total
| ([ ($all[ (($lu // -1)+1) : ])[] | select(.type=="assistant" and .requestId!=null) ] | group_by(.requestId) | map(utoks(.[0].message.usage)) | add // 0) as $turn
| (if $lu==null then "" else ($all[$lu].uuid // "") end) as $lu_uuid
| ([ $all[] | select(.type=="assistant" and (.isSidechain != true)) | .timestamp // empty ] | last) as $last_ts
# --- Prompt-cache forensics, main chain only (a subagent has its own cache, so
#     sidechain requests say nothing about whether YOUR prefix survived).
# $cr    = cached tokens READ by the FIRST request of the current turn. That one
#          request is the whole story: it is the one that either reuses the
#          prefix or pays to rebuild it; later requests in the turn re-hit what
#          it just wrote.
# $prev  = prompt size of the LAST request before this turn — i.e. exactly the
#          prefix that WAS cached and that this turn should have read back.
#          Comparing $cr against $prev (rather than against a fixed number) is
#          what makes the verdict robust: normal turn-over-turn growth still
#          reads back ~all of $prev, while an expired prefix reads back ~none.
| ([ ($all[(($lu // -1)+1):])[] | select(.type=="assistant" and .requestId!=null and (.isSidechain!=true)) ] | first | .message.usage) as $fu
| ([ $all[0:(($lu // 0))][] | select(.type=="assistant" and .requestId!=null and (.isSidechain!=true)) ] | last | .message.usage) as $pu
| (if $fu == null then -1 else ($fu.cache_read_input_tokens // 0) end) as $cr
| (ptoks($pu)) as $prev
# What that first request WROTE, and into which bucket: on a miss this is the
# rebuild, and the 5m/1h split is what it was billed at (2x vs 1.25x). $fp is
# its whole prompt, which is how a COMPACTION is told apart from a miss: after
# /compact the prompt shrinks to a fraction of $prev and reads back little of
# it, exactly like an expired cache, but nothing that was cached is being
# rebuilt; the old prefix was thrown away on purpose. Real ones, 2026-09-27:
# 976K -> 77K and 511K -> 71K, each of which the bar priced as a $7-9 miss on a
# turn that cost about a dollar.
| (($fu // {}).cache_creation_input_tokens // 0) as $fcc
| (($fu // {}).cache_creation // {}) as $fsplit
| ($fsplit.ephemeral_1h_input_tokens // 0) as $fc1h
| ($fsplit.ephemeral_5m_input_tokens // 0) as $fc5m
| (ptoks($fu)) as $fp
# The part of the prompt a COLD start still reads back: the cache_read of the
# latest request that found no prefix of its own, i.e. read back less than half
# of its own prompt (a fresh session, the first request after a miss or after a
# compaction). What it reads is the system prompt and tool list, which every
# session shares and keeps warm, so it survives an expired TTL and does not
# belong in the forecast of the loss. Judged against the request OWN prompt, not
# by position: a session resumed inside the TTL opens with a WARM read of the
# whole prefix, and taking that as the survivor would forecast a $0 loss. No
# cold request seen yet -> 0, and the forecast prices the whole prompt.
| ([ $all[] | select(.type=="assistant" and .requestId!=null and (.isSidechain!=true))
     | .message.usage | select(((.cache_read_input_tokens // 0) * 2) < ptoks(.))
     | (.cache_read_input_tokens // 0) ] | last // 0) as $keep
# TTL is not guesswork: the API reports which ephemeral bucket the cache write
# went into (`cache_creation.ephemeral_5m_input_tokens` vs `..._1h_...`), so the
# session states its own TTL. 0 = nothing written yet / unknown.
#
# But a session writes into BOTH buckets, so "whichever bucket the most recent
# write landed in" is the wrong reading — and it was wrong in the common case. A
# real session here put 245K into one 1h write and then a trickle of ~1-3K 5m
# writes for the conversational tail; last-write-wins reported 300s, so the bar
# went red five minutes after you stepped away while a quarter-million cached
# tokens were still sitting there for another hour. An alarm you cannot trust is
# worse than no alarm.
#
# What the pulse is actually about is the EXPENSIVE rebuild, so the TTL that
# matters is the one guarding the bulk of the prefix. Take the largest write in
# the session as the yardstick and keep only writes within 4x of it — that
# ignores the tail deltas while still tracking a genuine mid-session switch (if
# the session drops to 5m caching, the next big write lands in the 5m bucket and
# wins on its own). Then `last` of those, so a switch takes effect immediately.
# NOTE: no apostrophes below or above inside this program — it is one big
# single-quoted shell string, and one stray quote ends it mid-jq.
| ([ $all[] | select(.type=="assistant" and (.isSidechain!=true)) | .message.usage.cache_creation
     | select(. != null)
     | {h: (.ephemeral_1h_input_tokens//0), m: (.ephemeral_5m_input_tokens//0)}
     | select((.h + .m) > 0) ]) as $ccs
| (($ccs | map(.h + .m) | max) // 0) as $ccmax
| ([ $ccs[] | select((.h + .m) * 4 >= $ccmax) ] | last) as $cc
| (if $cc == null then 0 elif ($cc.h > $cc.m) then 3600 else 300 end) as $ttl
| "\($total)\t\($turn)\t\($lu_uuid)\t\($last_ts // "")\t\(if $idle then 1 else 0 end)\t\($cr)\t\($prev)\t\($ttl)\t\($fcc)\t\($fc1h)\t\($fc5m)\t\($fp)\t\($keep)"'
  sid=$(basename "$tp" .jsonl)
  # The jq -s above slurps the ENTIRE transcript (often multi-MB) — far too
  # costly to re-run on every 1s idle refresh. Cache its single-line output and
  # reuse it while the transcript file is untouched (same mtime); any new
  # message bumps the mtime and forces a fresh parse. This keeps
  # refreshInterval=1 cheap so the idle "-N" clock can tick per-second.
  # -v3: the cached line grew five more fields (the first request's write and
  # its 5m/1h split, its prompt size, the cold-start read). The cache is keyed by
  # mtime alone, so an older line would be served as valid until the transcript
  # next changes; the version in the name retires it.
  cache="/tmp/claude-statusline-cache-v3-${sid}.txt"
  mtime=$(file_mtime "$tp")
  cached_mtime=""; tok_line=""
  if [ -f "$cache" ]; then
    cached_mtime=$(sed -n '1p' "$cache")
    tok_line=$(sed -n '2p' "$cache")
  fi
  if [ -z "$tok_line" ] || [ "$cached_mtime" != "$mtime" ]; then
    tok_line=$(jq -s -r "$tok_prog" "$tp" 2>/dev/null)
    printf '%s\n%s\n' "$mtime" "$tok_line" > "$cache"
  fi
  total_tok=$(printf '%s' "$tok_line" | cut -f1)
  turn_tok=$(printf '%s' "$tok_line" | cut -f2)
  last_user=$(printf '%s' "$tok_line" | cut -f3)
  last_ts=$(printf '%s' "$tok_line" | cut -f4)
  idle=$(printf '%s' "$tok_line" | cut -f5)
  turn_cache_read=$(printf '%s' "$tok_line" | cut -f6)
  prev_prompt=$(printf '%s' "$tok_line" | cut -f7)
  ttl_secs=$(printf '%s' "$tok_line" | cut -f8)
  first_write=$(printf '%s' "$tok_line" | cut -f9)
  first_w1h=$(printf '%s' "$tok_line" | cut -f10)
  first_w5m=$(printf '%s' "$tok_line" | cut -f11)
  first_prompt=$(printf '%s' "$tok_line" | cut -f12)
  keep_tokens=$(printf '%s' "$tok_line" | cut -f13)
  [ -n "$total_tok" ] || total_tok=0
  [ -n "$turn_tok" ] || turn_tok=0

  # Track the cost delta for the current turn in a per-session state file.
  state="/tmp/claude-statusline-turn-${sid}.txt"
  prev_uuid=""; base=""; prev_turn_cost=""
  if [ -f "$state" ]; then
    prev_uuid=$(sed -n '1p' "$state")
    base=$(sed -n '2p' "$state")
    prev_turn_cost=$(sed -n '3p' "$state")
  fi
  if [ "$prev_uuid" != "$last_user" ] || [ -z "$base" ]; then
    # New user prompt => the turn that just finished becomes the "previous
    # turn". Snapshot its cost (cost - old base) before rolling the baseline
    # forward, so the brief window before the new turn's usage lands can keep
    # showing the previous turn's number instead of flashing $0.00.
    if [ -n "$base" ]; then
      prev_turn_cost=$(echo "$cost - $base" | bc -l)
      [ "$(echo "$prev_turn_cost < 0" | bc -l)" = "1" ] && prev_turn_cost=0
    fi
    base="$cost"
    printf '%s\n%s\n%s\n' "$last_user" "$cost" "$prev_turn_cost" > "$state"
  fi
  turn_cost=$(echo "$cost - $base" | bc -l)
  if [ "$(echo "$turn_cost < 0" | bc -l)" = "1" ]; then turn_cost=0; fi
  [ -n "$prev_turn_cost" ] || prev_turn_cost=0

  # Fallback idle/age from the transcript's stop_reason + last-message timestamp.
  # Used only until the Stop hook has run on this session (the hook state in the
  # shared block below is authoritative once present).
  fb_idle="$idle"
  fb_age_secs=""
  if [ -n "$last_ts" ]; then
    ts_clean=${last_ts%%.*}; ts_clean=${ts_clean%Z}
    ts_epoch=$(utc_epoch "$ts_clean")
    if [ -n "$ts_epoch" ]; then
      _now=$(date +%s); fb_age_secs=$((_now - ts_epoch)); [ "$fb_age_secs" -lt 0 ] && fb_age_secs=0
    fi
  fi
  spend_ready=1
elif [ -n "$cost" ]; then
  # === No readable transcript. Claude Code 2.1.x stores some sessions in a
  # per-session directory and still hands the status line a "<id>.jsonl" path
  # that doesn't exist, and there's no documented way to find the real one. With
  # no stop_reason we infer turn state from the COST CLOCK: total_cost_usd rises
  # while the agent works and goes flat between turns, and refreshInterval=1
  # re-runs us every second. So cost flat for >= IDLE_GRACE seconds => idle, and
  # the age is the time since cost last moved (~ when the turn ended). Only a flat
  # stretch over NEW_TURN_GAP rolls the baseline to a genuinely new turn, so a
  # tool/think pause mid-turn doesn't split one turn's cost in two.
  # Caveat (accepted): a long mid-turn step with no API billing (cost flat) can
  # briefly read as "previous turn" + a ticking age; it snaps back when cost moves.
  IDLE_GRACE=3          # seconds of flat cost before we call it idle
  NEW_TURN_GAP=30       # flat-cost gap that marks a real new user turn
  state="/tmp/claude-statusline-heur-${session_id:-default}.txt"
  now=$(date +%s)
  # State lines: 1) cost-last-changed epoch  2) turn baseline cost
  #              3) previous turn's cost      4) cost at the previous render
  change_epoch=""; turn_base=""; prev_turn_cost=""; prev_cost=""
  if [ -f "$state" ]; then
    change_epoch=$(sed -n '1p' "$state")
    turn_base=$(sed -n '2p' "$state")
    prev_turn_cost=$(sed -n '3p' "$state")
    prev_cost=$(sed -n '4p' "$state")
  fi
  case "$change_epoch" in ''|*[!0-9]*) change_epoch="" ;; esac
  if [ -z "$turn_base" ] || [ -z "$change_epoch" ] || [ -z "$prev_cost" ]; then
    # First render (or migrating from an older state file): start a turn here.
    turn_base="$cost"; change_epoch="$now"; prev_cost="$cost"
    [ -n "$prev_turn_cost" ] || prev_turn_cost=0
  elif [ "$(echo "$cost != $prev_cost" | bc -l)" = "1" ]; then
    # Cost moved. If it had been flat long enough to be a genuine new turn, roll
    # the baseline forward (the just-finished turn becomes the "previous turn").
    if [ "$((now - change_epoch))" -ge "$NEW_TURN_GAP" ]; then
      prev_turn_cost=$(echo "$prev_cost - $turn_base" | bc -l)
      [ "$(echo "$prev_turn_cost < 0" | bc -l)" = "1" ] && prev_turn_cost=0
      turn_base="$prev_cost"
    fi
    change_epoch="$now"
  fi
  [ -n "$prev_turn_cost" ] || prev_turn_cost=0
  printf '%s\n%s\n%s\n%s\n' "$change_epoch" "$turn_base" "$prev_turn_cost" "$cost" > "$state"

  turn_cost=$(echo "$cost - $turn_base" | bc -l)
  [ "$(echo "$turn_cost < 0" | bc -l)" = "1" ] && turn_cost=0
  secs_idle=$((now - change_epoch)); [ "$secs_idle" -lt 0 ] && secs_idle=0
  if [ "$secs_idle" -ge "$IDLE_GRACE" ]; then fb_idle=1; else fb_idle=0; fi
  fb_age_secs="$secs_idle"
  spend_ready=1
fi

# --- Idle + age (shared): prefer Claude Code's lifecycle hooks (Stop /
#     UserPromptSubmit, written by ~/.claude/hooks/turn-state.sh), which mark turn
#     boundaries reliably for EVERY storage format. The status-line JSON has no
#     live "is the agent thinking?" signal, and new-format sessions have no
#     readable transcript — so the hook state is authoritative whenever it exists.
#     The per-branch signal (transcript stop_reason / cost heuristic) is only a
#     fallback until this session's first Stop hook has run.
if [ -n "$spend_ready" ]; then
  now=$(date +%s)
  idle="$fb_idle"; age_secs="$fb_age_secs"

  # --- Prompt-cache verdict for the CURRENT turn, rendered as a red parenthetical
  # glued to the turn price: "$5.2(2.7⏱) ⊂ $34" — of this turn's $5.20, $2.70 was
  # the rebuilt prefix. The PRICE COMES FIRST because the price is what the
  # segment is for: you look here to learn what the turn cost, and the miss is the
  # footnote explaining part of it. Spelling the sum out ahead of it
  # ("$⏱+2.7=5.2") made the reading order wrong — the eye met a small red number
  # before the figure it came for, and had to walk the whole expression to reach
  # the total. Glued with no space so the two are one cell-group: a parenthetical
  # touching its number is a qualifier, one with a space in front is a new item.
  # The question it answers is the one you can't see
  # from the price alone: did this turn reuse the cached prefix at the read
  # price, or did it rebuild it at the write price? A rebuilt 200K prefix on Opus
  # 5.5 at a 1h TTL is $1.56 of pure waste, and it is invisible unless something
  # points at it.
  #
  # Deterministic, not guessed: compare what the turn's first request READ back
  # ($turn_cache_read) with what the request before it had cached
  # ($prev_prompt). Half is the cut-off — measured misses read back ~0-7% of the
  # prefix, while healthy turns read back 80-100% even after a fat tool result,
  # so nothing real lands near the line. Two guards keep it quiet:
  #   * $prev_prompt < 5000 -> there was nothing worth caching yet (and the
  #     session's very first turn, where a miss is unavoidable, has $prev = 0);
  #   * $turn_cache_read = -1 -> the turn has issued no request yet, so there is
  #     no verdict to give. Absence of data must not read as a miss;
  #   * $first_prompt < half of $prev_prompt -> the prompt SHRANK: a /compact
  #     (or a rewind) replaced the old prefix on purpose. Reading little of it
  #     back is the point, not a lost cache — see $fp in the jq program.
  case "$turn_cache_read" in ''|*[!0-9-]*) turn_cache_read=-1 ;; esac
  case "$prev_prompt" in ''|*[!0-9]*) prev_prompt=0 ;; esac
  case "$ttl_secs" in ''|*[!0-9]*|0) ttl_secs=300 ;; esac
  case "$first_write"  in ''|*[!0-9]*) first_write=0 ;; esac
  case "$first_w1h"    in ''|*[!0-9]*) first_w1h=0 ;; esac
  case "$first_w5m"    in ''|*[!0-9]*) first_w5m=0 ;; esac
  case "$first_prompt" in ''|*[!0-9]*) first_prompt=0 ;; esac
  case "$keep_tokens"  in ''|*[!0-9]*) keep_tokens=0 ;; esac
  # The forecast the idle clock prices: the live prompt minus what a cold start
  # still reads back. Exact size when Claude Code sends it, else the rounded %.
  _live=${ctx_in:-${used_tokens:-0}}
  case "$_live" in ''|*[!0-9]*) _live=${used_tokens:-0} ;; esac
  fc_tokens=$((_live - keep_tokens)); [ "$fc_tokens" -lt 0 ] && fc_tokens=0
  miss_tag=""
  if [ "$turn_cache_read" -ge 0 ] && [ "$prev_prompt" -ge 5000 ] \
     && [ "$turn_cache_read" -lt $((prev_prompt / 2)) ] \
     && [ $((first_prompt * 2)) -ge "$prev_prompt" ]; then
    # With the price attached, not just the fact: a bare "⏱" makes you do the
    # subtraction yourself to find out whether the miss was most of the turn or a
    # rounding error on it — and the two cases call for completely different
    # reactions.
    #
    # Priced off the request that PAID it, not off $prev_prompt. What was lost is
    # the part of the old prefix that was written again instead of read: the
    # previous prompt minus what this request still read back (the ~25K system
    # prompt and tools survive every expiry), and never more than it actually
    # wrote (its write also carries the new message, which a hit pays for too).
    # At the write multiplier it was billed at, from its own 5m/1h split. The
    # old "whole $prev_prompt at a flat rate" printed "$1.6(2.2⏱)" on a real
    # Opus 5.5 turn: a miss dearer than the turn it was part of.
    #
    # No "$" on the inner figure: the turn price it hangs off already printed one
    # (or the flower standing in for it), and both numbers are the same money in
    # the same units. A second currency sign four cells later would be claiming
    # otherwise.
    #
    # "⏱" where the word "(cache miss)" used to be. A glyph failed here once
    # before — the original bare red "!" — but for a reason this one does not
    # repeat: "!" was an ALARM, a mark that says "react" without saying to what,
    # so there was nothing to remember it by. The stopwatch names the CAUSE. What
    # kills a prompt cache is a clock running out, it is the same clock the "-N"
    # segment two cells over is already counting, and the glyph is that
    # clock. It TRAILS the figure, where a unit goes: "2.7⏱" reads as "2.7 worth
    # of clock", one quantity with its kind named after it, which is exactly what
    # it is — and it puts the two numbers, the ones you actually compare, nearer
    # each other than any leading label can.
    _lost=$((prev_prompt - turn_cache_read))
    [ "$first_write" -lt "$_lost" ] && _lost=$first_write
    _wm=$(awk -v h="$first_w1h" -v m="$first_w5m" -v d="$(ttl_wmult)" \
      'BEGIN{ print (h + m > 0) ? (h*2 + m*1.25) / (h + m) : d }')
    [ "$_lost" -gt 0 ] && miss_tag="${RED}($(miss_num "$_lost" "$_wm")⏱)${RESET}"
  fi
  hookstate="/tmp/claude-turn-${session_id:-default}.state"
  if [ -f "$hookstate" ]; then
    hstate=$(sed -n '1p' "$hookstate"); hts=$(sed -n '2p' "$hookstate")
    case "$hstate" in
      # Keep age_secs (the fallback "time since last activity") ticking even while
      # working, so the "-<age>" clock keeps running through the window right
      # after you hit Enter — until this turn's first cost actually lands.
      working) idle=0 ;;
      idle)    idle=1; case "$hts" in ''|*[!0-9]*) ;; *) age_secs=$((now - hts)); [ "$age_secs" -lt 0 ] && age_secs=0 ;; esac ;;
    esac
  fi
  # Displayed cost + label. Three states, driven by "am I working" AND by whether
  # the current turn has actually billed yet (turn_cost>0):
  #   working, nothing billed yet (you just hit Enter) -> FOUR STARS in place
  #     of the figure ("★★★★ ⊂ $12"). The previous turn's price vanishes the
  #     instant you press Enter: for the 10-20s before the first response lands
  #     there is no current cost, and leaving the old number on screen means the
  #     one figure you look at is silently stale — you read "$1.4" and attribute
  #     it to the thing you just asked for. Better an empty slot that is honestly
  #     empty. It used to be ONE bare flower, and one flower is exactly the glyph
  #     that, a second later, stands in for the "$" in front of the live figure —
  #     so "no number yet" and "a number is on its way" looked the same at a
  #     glance (2026-09-30, Victor: never a single flower when the turn has just
  #     started). A row of stars is a different SHAPE, not a different frame, so
  #     the empty state cannot be misread as the first beat of the figure; and
  #     it is a fixed string, never the flower repeated to pad the slot.
  #   working AND the current turn has cost -> live figure with the animated
  #     flower STANDING IN FOR THE "$" ("✻0.7 ⊂ $12"). The currency sign is the
  #     one cell in the segment that carries no information — you know the units
  #     — so it is the right place to spend on the animation: the bloom sits
  #     directly ON the number that is still growing, rather than off to one
  #     side, and the figure it qualifies cannot be mistaken for the total.
  #     Nothing shifts width when it starts or stops.
  #   idle -> the finished turn's figure, its "$" back, plus a ticking
  #     "-<age>" — the minus already says it's the last turn.
  # The separator between the two figures is ALWAYS "⊂", in every state.
  if [ "$idle" != "1" ]; then
    # Claude Code's own "Working…" spinner: the asterisk-flower blooming and
    # closing again (· ✢ ✳ ✻ ✽ then back down), so the status line pulses in
    # sync with the spinner above the prompt. Every glyph is a single cell, so
    # the segment never changes width. The frame index comes from the wall clock
    # ($now, already fetched) and refreshInterval=1 is what advances it — the
    # animation costs no extra work per render.
    #
    # ∗ (U+2217) is deliberately NOT in the cycle even though Claude Code uses
    # it: it is a MATH OPERATOR, not a Dingbat like the others, so the font
    # centres it on the math axis and it visibly sags below the baseline next to
    # ✳/✻/✽ — one frame of the bloom dropping half a pixel-row. Five frames that
    # sit still beat six that twitch.
    #
    # "$" is the ninth frame, treated as just another bloom in the cycle: since
    # the flower is standing in for the currency sign anyway, letting the real
    # "$" surface once per cycle re-states what the glyph is replacing — the
    # units flash back for a beat and the animation stays honest about the slot
    # it occupies. Single cell like the rest, so the width still never moves.
    #
    # The COLOUR rides the same case, on the same frame index, so the hue and the
    # glyph are two readings of one number rather than two animations that happen
    # to overlap: the bloom opens and warms together, closes and cools together.
    #
    # The bloom stops at the glyph: the DIGITS stay in the terminal's normal
    # colour. Colouring the figure too was the earlier rule and it defeated
    # itself — the money is the thing you are trying to read, and a number whose
    # hue changes every second is a number you keep re-reading to check whether
    # the colour means something. It never did; only the glyph is animated, and
    # the glyph is the cell that carries no information anyway. Now the movement
    # sits entirely in the decoration and the figure holds still to be read.
    case $((now % 9)) in
      0) flower="·"; bloom=$BLOOM0 ;;
      1|7) flower="✢"; bloom=$BLOOM1 ;;
      2|6) flower="✳"; bloom=$BLOOM2 ;;
      3|5) flower="✻"; bloom=$BLOOM3 ;;
      8) flower="$"; bloom=$BLOOM4 ;;
      *) flower="✽"; bloom=$BLOOM4 ;;
    esac
    # The flower stands in for the "$". No cost yet on this turn => print no
    # figure at all; the four stars below hold the slot instead.
    if [ "$(echo "$turn_cost > 0" | bc -l)" = "1" ]; then
      turn_disp=$(trunc1 "$turn_cost")
      turn_money=$(printf '%s%s%s%s' "$bloom" "$flower" "$RESET" "$turn_disp")
    else
      turn_money=""
    fi
    turn_suffix=""
    # ★ (U+2605), not one of the bloom glyphs: ✢ ✳ ✻ ✽ are the flower, and the
    # placeholder must not read as a flower. Exactly four, one cell each: the
    # width of the figure it stands in for ("✻0.7" is four cells), so the slot
    # is the same size empty or full. The hue still breathes with the bloom, so
    # the bar says "working" as before.
    lone="${bloom}★★★★${RESET}"
  else
    # idle after a finished turn -> that turn's cost is in turn_cost; just after
    # Enter (turn_cost==0) -> fall back to the previous turn's cost.
    if [ "$(echo "$turn_cost > 0" | bc -l)" = "1" ]; then disp_cost="$turn_cost"; else disp_cost="$prev_turn_cost"; fi
    turn_disp=$(trunc1 "$disp_cost")
    turn_money=$(printf '$%s' "$turn_disp")
    age_str=""
    [ -n "$age_secs" ] && age_str=$(fmt_age "$age_secs")
    turn_suffix="$age_str"
    lone=""
  fi
  # "⊂", not a neutral bullet: the two figures are not siblings — the turn's
  # spend is CONTAINED IN the session's. The subset sign states that in one cell,
  # so "$0.6 ⊂ $3" reads as "this turn is part of that", not as "0.6 and 3".
  # Subset rather than the element-of "∈" it replaced, because what is on the
  # left is not a single member of the total but a *portion* of it — the same
  # kind of quantity, a piece of the same money.
  sep="⊂"
  # The total is always TRUNCATED, never rounded — it may not claim money that
  # has not been spent, and it should only ever tick upward. What changes with
  # size is the RESOLUTION: one decimal below $10, whole dollars from $10 up.
  #
  # A flat int() was the earlier rule and it broke the "⊂" relation on its own
  # terms: a 30-cent session rendered "✻0.3 ⊂ $0" — a subset visibly LARGER than
  # the set containing it, i.e. the one reading the separator exists to prevent.
  # Truncating to the dollar is right at $25.40, where the cents are below the
  # resolution of any decision it feeds; at $0.34 that same truncation eats the
  # entire number. The decimal also matches the turn figure sitting next to it,
  # so the pair is directly comparable instead of being two different roundings.
  #
  # The +1e-9 is not cosmetic: 0.3*10 is 2.9999999999999996 in binary floating
  # point, so a bare int() would print "$0.2" for thirty cents — the same
  # understatement being fixed here, one decimal place down. Below $10 the widest
  # output is "$9.9", so the segment never grows past the 5 cells int() used.
  #
  # Above $10 the whole-dollar truncation can drop the total BELOW the turn
  # figure printed beside it — a $12.75 session spent in one $12.7 turn renders
  # "$12.7 ⊂ $12". The containment sign makes that a contradiction on its face,
  # so when whole dollars would fall short of the turn, the total keeps the
  # decimal instead. Truncation is preserved either way (the total still never
  # claims unspent money); only the RESOLUTION drops back to the turn's, which
  # is exactly the resolution needed for the pair to stay readable as a subset.
  # This only ever fires when one turn accounts for essentially the whole
  # session — the first turn, or a resumed one — so the wider cell is rare.
  total_money=$(awk -v c="$cost" -v t="${turn_disp:-0}" \
    'BEGIN{ d = int(c); tr = int(c*10 + 1e-9)/10
            if (c >= 10 && d >= t) printf "$%d", d; else printf "$%.1f", tr }')
  if [ -n "$turn_money" ]; then
    spend_seg="${turn_money}${miss_tag}${turn_suffix} ${sep} ${total_money}"
  else
    # Nothing billed yet: the stars stand in for the missing figure, but the
    # "⊂" stays ("★★★★ ⊂ $12"). Dropping it was the earlier rule and it made the
    # segment jump: the moment the first cost landed, "⊂" appeared out of nowhere
    # and shoved the total two cells right, so the one number you were watching
    # moved exactly when it started mattering. Keeping the separator through the
    # empty state keeps the segment's shape, and it is still true — whatever this
    # turn ends up costing IS contained in that total, figure or no figure. The
    # stars are four for the same reason: "✻0.7" is four cells, so when the
    # first cost lands the figure drops into exactly the room the stars held
    # and the total does not move at all. (It used to be seven stars, three
    # cells wider than the figure, and the total stepped left once on the
    # first cost -- a settle that four removes. A turn of $10 or more prints
    # one cell wider, but such a turn has long since replaced the stars.)
    spend_seg="${lone} ${sep} ${total_money}"
  fi
fi

if [ -n "$spend_seg" ] && [ "$(printf '%.2f' "$cost")" != "0.00" ]; then
  out="$out${_five_sep:- | }$spend_seg"
fi

# --- Weekly quota, last cell of the bar: "+6=27% / 1wd1h"
# The 5h segment answers "can I keep going right now"; this one answers the
# slower question — am I going to run out of week before the week runs out.
# Three numbers, in the order you actually ask them:
#   +6=   pace, in percentage POINTS off a straight line: elapsed% − used%.
#         Positive = consumed less than the clock, i.e. points of slack in hand;
#         negative = burning ahead of the week. Points, not a ratio, because
#         over a whole week the linear budget is the mental model people
#         actually use ("it's Thursday, I should be ~80% in").
#   27%   quota left in the 7-day window (the absolute figure)
#   1wd1h WORKING time until the window resets — weekends excluded, see below
# Deliberately NOT the ratio-with-bands used for the 5h arrow: on a 7-day window
# a ratio is wildly unstable in the first hours (tiny elapsed => huge ratio) and
# numb at the end, whereas the point-difference stays readable throughout.
if [ -n "$week" ]; then
  wleft=$(printf '%.0f' "$(echo "100 - $week" | bc -l)")
  wleft_str="${wleft}%"
  if [ "$wleft" -lt 5 ]; then
    wleft_str="${RED}${wleft_str}${RESET}"
  elif [ "$wleft" -lt 15 ]; then
    wleft_str="${ORANGE}${wleft_str}${RESET}"
  fi

  # A weekly park belongs on the weekly percentage, never on the healthy 5h
  # figure. Include the weekday so the probe deadline remains unambiguous next
  # to a potentially multi-day weekly reset; a bare clock suffices for 5h.
  if [ "$park_window" = seven_day ]; then
    week_wake=$(fmt_epoch "$park_wake" '+%a %H:%M')
    week_sleep="${ORANGE}💤${RESET}"
    [ -n "$week_wake" ] && week_sleep="${week_sleep} ${ORANGE}→ ${week_wake}${RESET}"
    wleft_str="${wleft_str}${week_sleep}"
  fi

  # --- The per-model weekly cap, riding the weekly cell as "(F86%)"
  # An account can hold two weekly budgets at once: the account-wide one, which
  # is the figure beside this chip, and a per-model cap with its own allowance
  # (Fable's, since 2026-09). Until now the bar showed whichever was tighter and
  # said nothing about which, so it read "86% left" on an account /usage put at
  # 92% -- the right number for the wrong budget, and no way to tell from the
  # bar. Two figures side by side cost three columns and remove the ambiguity
  # entirely: the weekly number is always the account, the chip is always a
  # model.
  # The model is one INITIAL, not a name: this chip sits in the last cell of an
  # already crowded bar, the set of scoped models is tiny, and the letter only
  # has to disambiguate against the account figure it is glued to -- "(F86%)"
  # cannot be read as anything but "Fable, 86% left". The chip disappears with
  # the cap, so an account with no scoped weekly shows the weekly cell it always
  # had.
  wchip=""
  # --- ...and only while that model is the one in play
  # The cap is a number about Fable. On an Opus session it is a budget this
  # turn cannot spend and cannot exhaust: three columns of someone else's
  # business parked in the cell the eye goes to for "how much room do I have",
  # and a figure that never moves while you watch it teaches the eye to skip
  # the cell -- taking the account weekly glued beside it along with it. So the
  # chip is scoped to the session the way the cap is scoped to the model: it
  # appears the moment this terminal switches to that model, which is the same
  # moment it starts describing this terminal.
  # The one exception is a park on this very window: there the cap is the
  # reason nothing is running at all, so it has to stay readable whatever model
  # happens to be selected while you wait it out.
  wscoped_mine=""
  case "$wscoped_label" in
    ''|-) ;;
    *)
      # Matched on the UNTOUCHED display name (§the model cell rewrites $model)
      # and case-folded both ways, because the label is the endpoint's
      # `scope.model.display_name` and nothing promises the two spell the
      # family with the same capitals.
      mlc=$(printf '%s' "$model_name" | tr '[:upper:]' '[:lower:]')
      slc=$(printf '%s' "$wscoped_label" | tr '[:upper:]' '[:lower:]')
      case "$mlc" in *"$slc"*) wscoped_mine=1 ;; esac
      ;;
  esac
  [ "$park_window" = weekly_scoped ] && wscoped_mine=1
  case "$wscoped" in
    ''|-|-1|*[!0-9.]*) ;;
    *)
      # A stored reading whose window has already turned over is last week's
      # budget; drop it rather than show a figure the account no longer holds.
      if [ -n "$wscoped_mine" ] \
         && { [ -z "$wscoped_reset" ] || [ "$wscoped_reset" = 0 ] \
              || [ "$wscoped_reset" -gt "$(date +%s)" ] 2>/dev/null; }; then
        case "$wscoped_label" in
          ''|-) ;;
          *)
            sleft=$(printf '%.0f' "$(echo "100 - $wscoped" | bc -l)")
            sinit=$(printf '%s' "$wscoped_label" | cut -c1 | tr '[:lower:]' '[:upper:]')
            schip="${sinit}${sleft}%"
            if [ "$sleft" -lt 5 ]; then
              schip="${RED}${schip}${RESET}"
            elif [ "$sleft" -lt 15 ]; then
              schip="${ORANGE}${schip}${RESET}"
            fi
            # A park caused by the scoped cap belongs on the scoped figure: the
            # account weekly beside it is not what stopped the terminal.
            if [ "$park_window" = weekly_scoped ]; then
              s_wake=$(fmt_epoch "$park_wake" '+%a %H:%M')
              schip="${schip}${ORANGE}💤${RESET}"
              [ -n "$s_wake" ] && schip="${schip} ${ORANGE}→ ${s_wake}${RESET}"
            fi
            wchip="(${schip})"
            ;;
        esac
      fi
      ;;
  esac

  wpace=""
  wdur=""
  if [ -n "$week_reset" ] && [ "$week_reset" -gt 0 ] 2>/dev/null; then
    now=$(date +%s)
    wdiff=$((week_reset - now))
    if [ "$wdiff" -gt 0 ]; then
      # BOTH the pace and the time-left are measured in WORKING time: Saturday
      # and Sunday are subtracted from the window, from the time elapsed and
      # from the time remaining, because a weekend burns none of the quota.
      # Straight calendar time lied in both directions — it called you "behind"
      # all Friday when the two days you supposedly had left were days you would
      # not work, and it flattered you on Monday by counting a weekend you had
      # already skipped. "1wd1h" on a Thursday night is a number you can act on;
      # "3d1h" is not, because two of those days aren't yours.
      #
      # Local weekday without strftime (macOS awk has none): 1970-01-01 was a
      # Thursday, so for local day index D, dow = (D+4) % 7 with 0=Sun, 6=Sat.
      # The UTC offset comes from date(1) once. A DST shift inside the window
      # skews this by an hour — irrelevant against a 5-day budget.
      off=$(date +%z | awk '{ s=(substr($0,1,1)=="-")?-1:1;
        print s*(substr($0,2,2)*3600 + substr($0,4,2)*60) }')
      # One awk pass yields both numbers: "<work_seconds_left> <pace_points>".
      wcalc=$(awk -v u="$week" -v now="$now" -v r="$week_reset" -v off="$off" '
        # seconds in [a,b) that fall on a weekday, walked one local day at a time
        function work(a, b,   s, d, dow, ds, de, x, y) {
          if (b <= a) return 0;
          s = 0; d = int((a + off) / 86400);
          while (d * 86400 - off < b) {
            dow = (d + 4) % 7;
            if (dow != 0 && dow != 6) {
              ds = d * 86400 - off; de = ds + 86400;
              x = (a > ds) ? a : ds; y = (b < de) ? b : de;
              if (y > x) s += y - x;
            }
            d++;
          }
          return s;
        }
        BEGIN{
          ws = r - 604800; if (now < ws) now = ws;
          wt = work(ws, r); wl = work(now, r);
          # wt==0 is unreachable for a 7-day window (it always holds 5 weekdays),
          # but fall back to calendar time rather than divide by zero.
          e = (wt > 0) ? (wt - wl) / wt * 100 : (604800 - (r - now)) / 604800 * 100;
          if (e < 0) e = 0; if (e > 100) e = 100;
          printf "%d %.0f", wl, e - u;
        }')
      wsecs=${wcalc%% *}
      delta=${wcalc##* }
      # Time left as "1wd1h" -- mixed units rather than a decimal day, because
      # "1.1d" needs mental arithmetic to become an hour you can plan around.
      # The unit is "wd" (WORKING days), not "d": these are weekday-only seconds,
      # and a bare "d" invites reading them as calendar days -- the exact
      # confusion this segment exists to remove.
      # A zero tail is dropped ("3wd", not "3wd0h"); under a day it degrades to
      # "5h", then "45m". Across the weekend this legitimately reads "0m":
      # there is no working time left before the reset, which is the point.
      wdur=$(awk -v d="$wsecs" 'BEGIN{
        dd=int(d/86400); hh=int((d%86400)/3600);
        if (dd>0)      printf (hh>0 ? "%dwd%dh" : "%dwd"), dd, hh;
        else if (hh>0) printf "%dh", hh;
        else           printf "%dm", int(d/60) }')
      # Signed number rather than an arrow glyph: the pace sits right next to
      # the "% left" figure, and two numbers in the same unit compare instantly
      # ("28% left, but 18% behind") where a "↓18" invites reading the second one
      # as a different kind of quantity. The sign carries the direction, so no
      # glyph has to. The "%" is NOT repeated on the pace — it is glued to a
      # figure that already carries the unit, and both are points of the same
      # window, so one "%" serves the pair.
      # ON PACE PRINTS NOTHING. "0" and awk's "-0" (a pace between -0.5 and 0)
      # both mean the same thing -- you are where a straight line says you
      # should be -- and that is the DEFAULT state of the window, the one the
      # bar is in most of the time. A "+0=" spent three columns, in the one cell
      # that already carries three readings, to announce that there was nothing
      # to announce; worse, it drew a signed figure shaped exactly like the
      # "-12=" that IS worth a glance, so the eye had to read it before it could
      # discard it. Absence says "on pace" faster than any glyph can, and the
      # "% left" beside it is never ambiguous on its own. The pace reappears the
      # moment it is a full point off in either direction, which is the only
      # time it changes what you do.
      case "$delta" in
        0|-0) wtxt=""; wcol="" ;;
        -*) wtxt="-${delta#-}"
            if [ "${delta#-}" -ge 10 ]; then wcol="$RED"; else wcol="$ORANGE"; fi ;;
        *)  wtxt="+${delta}"; wcol="$GREEN" ;;
      esac
      if [ -n "$wcol" ]; then
        wpace="${wcol}${wtxt}${RESET}"
      else
        wpace="$wtxt"
      fi
    fi
  fi
  # Pace LEADS the absolute figure, same reasoning as the 5h arrow: the signed
  # number is the "am I OK?" glance, the "% left" is the detail you read second.
  # The two are JOINED BY "=" and left unspaced -- "+6=27%" -- rather than
  # bracketed ("(+6)27%") or separated by a spaced "⊂". All three forms said the
  # pace belongs to the figure beside it; they differ in what they cost and in
  # what else they look like. "⊂" said it across two spaces, which is exactly
  # what a separator does: it made two readings out of what the eye should take
  # as one. Brackets bound tightly enough, but they spent two columns on
  # punctuation that carries no reading of its own, and in a bar that already
  # uses "(...)" for the spend cell's rider ("$5.2(2.7⏱)") they claimed one
  # shape for two different relationships -- there the brackets hold a SECOND
  # quantity riding on the figure before them, here they held the FIRST. "="
  # spends one column, keeps the pair unspaced so it still reads as one token,
  # and means the right thing on its own: two sides of the same window, "6
  # points of slack, hence 27% left". The "/" before the duration stays -- the
  # time left really IS a separate reading of the window, which is what "/" means
  # everywhere else in this bar ("96% / 4h44").
  if [ -n "$wpace" ]; then
    week_seg="${wpace}=${wleft_str}"
  else
    week_seg="$wleft_str"
  fi
  [ -n "$wchip" ] && week_seg="${week_seg} ${wchip}"
  [ -n "$wdur" ] && week_seg="${week_seg} / ${wdur}"
fi
# $week_seg is BUILT here, next to the arithmetic that produces it, but APPENDED
# below the location segment — this is the last cell of the bar.

# --- Location: "folder" or "folder@branch" ----------------------------------
# Back in the bar after living in the session title: the title is being freed
# for Claude Code's own per-session names (it only auto-titles when no custom
# title is set), and once it is no longer pinned to the location, the location
# needs a home. TEAL is the deliberate choice — it is the closest 256-colour
# match to the prompt-box border, so the folder still reads as part of that
# frame even though it now sits a line below it.
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
[ -n "$cwd" ] || cwd=$PWD

# THE NAME SHOWN IS THE REPO'S, NOT THE DIRECTORY'S: in petclinic/backend the
# segment still reads `petclinic`. A bare `backend` is the one answer this
# segment can give that is actively misleading — half the repos here have a
# `backend`, a `docs`, a `src`, so the landmark disappeared exactly when you had
# descended far enough to need it, and two windows in two different projects
# printed the same word. The enclosing repo is the coarsest thing that is still
# true and it is what the eye is actually looking for; a worktree names itself,
# since `--show-toplevel` stops at the linked worktree rather than the main
# repo (§6). Outside a repo (~/workspace itself, $HOME) there is no root to find
# and the directory's own name is all there is.
#
# CACHED, for the reason the chip below is cached: this is a fork, the bar
# re-renders every second in every open session, and the answer only changes
# when you cd. Two lines and the key first, so that a path containing spaces
# survives a builtin `read` with no quoting games. An empty second line means
# "asked, not a repo" — the miss is worth caching too, since ~/workspace is a
# non-repo and is where most of these sessions are launched.
_repo_file="$HOME/.claude/cwd/.repo-$PPID"
_repo_key=''
_repo_root=''
[ -r "$_repo_file" ] && { read -r _repo_key; read -r _repo_root; } < "$_repo_file" 2>/dev/null
if [ "$_repo_key" != "$cwd" ]; then
  _repo_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
  { mkdir -p "$HOME/.claude/cwd" \
      && printf '%s\n%s\n' "$cwd" "$_repo_root" > "$_repo_file"; } 2>/dev/null || :
fi
# What the segment names, and what the chip is hashed from — the two have to be
# the same string, or petclinic and petclinic/backend would print one name in
# two colours.
locpath=${_repo_root:-$cwd}
loc=$(basename "$locpath")
unset _repo_file _repo_key _repo_root

# --- Publish it, keyed by the terminal ----------------------------------------
# Walkie Talkie draws the bound terminal's folder on its overlay chip and had no
# honest way to learn it. Claude Code keeps *two* directories: the session's,
# which is what `.workspace.current_dir` above carries and what this bar shows,
# and the process's, which never leaves wherever it was launched — verified on a
# live session working in walkie-talkie, where `lsof -d cwd` on the pid still
# answered ~/workspace. Reading ~/.claude/projects instead would mean guessing
# which of several sessions sharing a launch directory a pid belongs to, and a
# confidently wrong folder is worse than none.
#
# **The tty is the only handle both sides hold.** The relay knows it (it binds a
# Terminal tab by tty); this script can ask for it. `TERM_SESSION_ID` looked
# ideal — free, already in the environment — but the relay cannot read it back:
# macOS only lets `ps -E` show a process's environment to its own descendants,
# so an app launched separately sees nothing (measured: 2926 bytes for a process
# in this shell's ancestry, 4 for an unrelated terminal's).
#
# **The `ps` costs a fork, so it runs only when the answer changes.** This bar
# re-renders every second in every open session, which is exactly the shape of
# the load that made everything feel slow once before. The guard is a bash
# builtin `read` against the last value written — no subprocess — so the steady
# state costs nothing and the fork happens only when Victor actually changes
# directory. Everything is best-effort: a status line that breaks over a
# publishing side-effect is a status line that broke for nothing.
if [ -n "$cwd" ]; then
  _pubdir="$HOME/.claude/cwd"
  # Keyed by $PPID — claude's own pid, free and stable for the life of the
  # session. A single shared guard file would have several sessions in different
  # directories invalidating each other's answer every second, which is worse
  # than no guard at all.
  _guard="$_pubdir/.last-$PPID"
  _prev=""
  [ -r "$_guard" ] && read -r _prev < "$_guard" 2>/dev/null
  if [ "$_prev" != "$cwd" ]; then
    # **$PPID, not $$.** Claude Code spawns this script without a controlling
    # terminal of its own (measured: `??`), but it keeps one itself — so the tty
    # to publish under is the parent's, which is also the tty the relay binds by.
    # tr, not ${_tty// /}: this is a #!/bin/sh script and dash aborts the whole
    # render on that bash-only expansion ("Bad substitution").
    _tty=$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')
    case "$_tty" in
      ttys*) { mkdir -p "$_pubdir" \
                 && printf '%s' "$cwd" > "$_pubdir/$_tty" \
                 && printf '%s' "$cwd" > "$_guard"; } 2>/dev/null || : ;;
      *) : ;;   # no controlling terminal: nothing the relay could look up
    esac
  fi
  unset _pubdir _guard _prev _tty
fi
# ONE git call, deliberately: this bar re-renders every second, so a subprocess
# here is a per-second cost, not a per-prompt one. Resolving worktrees properly
# would need two more rev-parse calls, and that is the one thing this segment
# gives up (see §6 of the companion doc).
# --show-current and not `rev-parse --abbrev-ref HEAD`: the latter FAILS on an
# unborn branch (a fresh `git init` before the first commit), which is exactly
# when you most want to be told which branch you are on.
# Trunk branches are omitted: master/main is the default state, so naming it
# trains the eye to skip the field.
branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
case "$branch" in
  ''|master|main) branch_sfx= ;;
  *) branch_sfx="@${branch}" ;;
esac

# --- The folder chip: a background colour hashed from the folder's path ------
# Same folder, same chip, in every window and after every restart. It is a
# landmark to jump to, not an identifier: with ~20 active folders some pairs
# necessarily share a chip, and the name is right there for when you must be
# sure.
#
# TWENTY combinations, not twelve, and half of them INVERTED — dark text on a
# pale background alongside white text on a dark one. Sticking to dark
# backgrounds capped the palette at about a dozen hues that were still legible
# and still distinguishable from each other; opening up the pale half roughly
# doubles the range, and the light/dark split itself is the fastest thing the
# eye sorts on, before it has resolved any hue at all. It also stops the chip
# from disappearing into the window: these sessions run on Nord polar night
# (#2e3440), which is why the palette carries no mid-grey — 238 (#444444) was
# in the first draft and sank straight into that background; 88 (#870000) took
# its slot.
#
# 256-colour and not 24-bit: Apple Terminal, where this bar spends its life, has
# no truecolor, and a `48;2;r;g;b` chip degrades there to no chip at all.
#
# Each entry is background:foreground.
FOLDER_CHIPS='25:231 61:231 91:231 126:231 28:231 30:231 100:231 130:231 19:231 88:231 223:16 194:16 189:16 224:16 230:16 195:16 217:16 186:16 183:16 252:16'
# Light page: every slot becomes a pastel under black text, position by position,
# so a folder keeps its hue family across the flip (25 blue -> 153 pale blue, 28
# green -> 157 pale green, ...). The near-whites of the dark palette (230, 195,
# 252) each step one shade deeper, or they would melt into #eceff4.
if [ "$LIGHT_UI" = 1 ]; then
  FOLDER_CHIPS='153:16 147:16 219:16 218:16 157:16 158:16 229:16 222:16 117:16 181:16 223:16 194:16 189:16 224:16 187:16 159:16 217:16 186:16 183:16 250:16'
fi

# The hash costs a fork and this bar re-renders every second in every open
# session — the exact shape of load that once made the whole machine feel slow.
# So it is computed only when the directory actually CHANGES, cached in
# ~/.claude/cwd/.chip-$PPID; the steady state is one builtin `read` and no
# subprocess. $PPID is claude's own pid: free, stable for the life of the
# session, and per-session, so two windows in different folders cannot
# invalidate each other's answer every render. Same key, same reasoning, as the
# cwd publisher above.
#
# What is cached is the RAW checksum, not the palette index. Taking the modulo
# at render time costs nothing (shell arithmetic, no fork) and means editing
# FOLDER_CHIPS takes effect immediately, instead of leaving every session
# holding an index that may now point past the end of a shorter palette.
_chip_file="$HOME/.claude/cwd/.chip-$PPID"
_chip_sum=''
_chip_key=''
[ -r "$_chip_file" ] && read -r _chip_sum _chip_key < "$_chip_file" 2>/dev/null
if [ "$_chip_key" != "$locpath" ]; then
  # cksum, not shasum: the hash only has to spread paths over the palette, and
  # it is the cheaper fork. The sum is written FIRST so that `read sum path`
  # reassembles a path containing spaces (~/Library/Application Support/…) out
  # of the tail field.
  _chip_sum=$(printf '%s' "$locpath" | cksum 2>/dev/null | cut -d' ' -f1)
  case "$_chip_sum" in ''|*[!0-9]*) _chip_sum=0 ;; esac
  { mkdir -p "$HOME/.claude/cwd" \
      && printf '%s %s\n' "$_chip_sum" "$locpath" > "$_chip_file"; } 2>/dev/null || :
fi
_chip_n=0
for _pair in $FOLDER_CHIPS; do _chip_n=$(( _chip_n + 1 )); done
_chip=''
if [ "$_chip_n" -gt 0 ]; then
  _chip_idx=$(( ${_chip_sum:-0} % _chip_n ))
  _i=0
  for _pair in $FOLDER_CHIPS; do
    if [ "$_i" -eq "$_chip_idx" ]; then
      _chip="${ESC}[48;5;${_pair%:*}m${ESC}[38;5;${_pair#*:}m"
      break
    fi
    _i=$(( _i + 1 ))
  done
fi
# Anything unexpected above leaves the folder readable in the old teal rather
# than unpainted: the chip is a convenience, never a reason for a blank segment.
[ -n "$_chip" ] || _chip="$TEAL"

# The branch is UNPAINTED and OUTSIDE the chip. Outside, because the chip frames
# "which folder", and a branch name is not part of that — putting it inside would
# make the same folder look like a different block depending on where its HEAD is.
# Unpainted, because the chip is already the one coloured thing in this segment:
# a teal tail hanging off it read as a second highlight competing with the folder
# name, so the branch now uses the bar's default foreground like every other
# figure on the line, and the eye goes straight to the chip.
#
# NO " | " ON EITHER SIDE. A cell of plain text needs the pipe, because two such
# runs with only a space between them read as one run; a chipped cell does not,
# because a coloured block is already a harder edge than a pipe ever was. The
# folder was the first cell to drop its pipes on that argument and the 5h quota
# followed, which is what gives the bar its zebra. Keeping both
# meant the eye crossed three separators — pipe, chip edge, chip edge, pipe —
# to read one word. A single space on each side is enough air around the chip;
# the pipes are what the chip replaced.
if [ -n "$loc" ]; then
  out="$out ${_chip}${loc}${RESET}${branch_sfx}"
  _loc_sep=' '            # the next cell butts against the chip, not a pipe
fi

# --- Weekly quota, last cell (built above, next to its arithmetic) ----------
# Its leading separator is the folder's trailing one: a space when the chip is
# there to divide them, the usual pipe when there is no folder segment at all.
[ -n "$week_seg" ] && out="$out${_loc_sep:- | }$week_seg"

# --- Week's spend at API prices, the very last cell: "$1840/6d" ---------------
# The weekly cell says how much of the ALLOWANCE is gone, never what it is worth.
# This is the week's usage priced as if every token had gone through an API key:
# dollars from the start of the 7-day window to LOCAL MIDNIGHT, over the days
# that covers. Today is deliberately left out -- the count scans every
# transcript touched this week, so it runs once a day (week-spend.py, in the
# background, one at a time under a lock) and the bar only ever READS its
# one-line cache. A stale key (new day, or the window turned over) is what kicks
# the recount; until it lands the cell is simply absent, never yesterday's
# figure under today's label. Hidden while the window holds no complete day.
# A bare space in front, no pipe: the "$" already marks where the cell starts,
# and "/ 3wd11h $1840/6d" cannot be misread as one figure.
if [ -n "$week_reset" ] && [ "$week_reset" -gt 604800 ] 2>/dev/null; then
  _ws_file="${CLAUDE_WEEK_SPEND_FILE:-$HOME/.claude/week-spend}"
  _ws_key="$((week_reset - 604800)) $(date +%F)"
  _ws_start='' _ws_date='' _ws_usd='' _ws_days=''
  [ -r "$_ws_file" ] && read -r _ws_start _ws_date _ws_usd _ws_days < "$_ws_file" 2>/dev/null
  case "$_ws_start $_ws_date" in
    "$_ws_key")
      _ws_usd=$(printf '%.0f' "$_ws_usd" 2>/dev/null)
      _ws_days=$(printf '%.0f' "$_ws_days" 2>/dev/null)
      [ "${_ws_days:-0}" -gt 0 ] 2>/dev/null \
        && out="$out \$${_ws_usd}/${_ws_days}d"
      ;;
    *)
      [ -x "$HOME/.claude/hooks/week-spend.py" ] \
        && nohup "$HOME/.claude/hooks/week-spend.py" "$week_reset" >/dev/null 2>&1 </dev/null &
      ;;
  esac
  unset _ws_file _ws_key _ws_start _ws_date _ws_usd _ws_days
fi

# --- Subagents in flight: "+2×O5h +S5m" glued onto the model segment --------
# WHAT IT SAYS: how many subagents are working right now, on which brain, at
# which effort — "+2×O5h +S5m" is two Opus-5-high agents plus one Sonnet-5-medium,
# written as a sum added onto the session's own model: no braces, the count as a
# coefficient in front, a plain "+" between groups.
# Claude Code's own agent list under the bar names the agents but never the model
# they got, and that is the fact which decides what a fan-out costs and how good
# its answers will be: the same Task lands on Opus, Sonnet, Fable or Haiku
# depending on agent frontmatter, an explicit model override, or the configured
# default subagent model — none of it visible anywhere on screen. Grouped rather
# than listed one-per-agent because a 24-way fan-out is one decision, not 24: the
# bar has room for its shape, not for the roster.
#
# WHERE IT COMES FROM: files Claude Code already writes, under
#   <transcript-dir>/<session-id>/subagents/
#     agent-<id>.meta.json   toolUseId, agentType, the requested model alias,
#                            and parentAgentId when another agent spawned it
#     agent-<id>.jsonl       the agent's own transcript: message.model + effort
# Nothing here probes a running process; it reads what the agents leave behind.
# Agents spawned BY an agent land in the same directory (spawnDepth 2, with a
# parentAgentId), so a fan-out inside a fan-out is counted like any other.
#
# WHO IS STILL RUNNING is the only hard part, and it is a race between two
# clocks. An agent STOPS when the transcript it reports to — the session's for a
# depth-1 agent, its parent agent's for a nested one — records the fact: its
# toolUseId as a tool_result (a synchronous Task returning) or inside a
# <tool-use-id> block, or its agentId inside a <task-id> block (the
# task-notification an async agent fires when its turn ends). The one tool_result
# that does NOT mean stopped is the "Async agent launched successfully" receipt,
# which lands at spawn time — so the scan splits each line on the id delimiter
# and discounts that chunk alone, rather than skipping the whole line: one turn
# can batch a sync result and an async launch together. A forked skill
# (/code-review run in the background, @code-review-2 under the bar) has no
# toolUseId at all, only a name; its key is its agentId and its stop is the
# <task-id> of its notification.
#
# But a stop is NOT final, and that is what every earlier version of this scan
# got wrong. An async agent whose turn has ended and been notified is woken
# again — by a SendMessage from whoever spawned it, or, with no one's hand on it,
# by a background task of its own returning: a `run_in_background` Bash or a
# child agent re-invokes it when it finishes, exactly as they re-invoke the main
# session. Seen 20 Sep 2026: a nested agent notified "completed" at 18:53, was
# woken by its own background sweep thirty seconds later, and worked ten more
# minutes to a second "completed" — while the chip, which had remembered the
# first stop as permanent, showed one agent fewer than the native list. A
# marker-then-resume scan (the previous design) only knew the SendMessage kind of
# wake, and only when it happened in the transcript being scanned.
#
# So the two clocks: every wake, of any kind, from anywhere, appends lines to the
# AGENT'S OWN transcript, and every stop stamps a marker into the transcript it
# reports to. An agent is idle exactly when its latest stop-marker is at least as
# recent as the last line it wrote; anything written after that marker means it
# is running again, and it will earn a newer marker when it stops again. Both
# sides carry ISO timestamps, so this is one comparison per agent — no line
# ordering, no resume detection, no assumption that a marker is monotonic.
# $SUB_SLACK seconds of tolerance cover the interval between the agent's final
# write and the harness stamping its stop (0.1–3 s observed); a wake inside that
# window is missed only until the agent's next line lands, seconds later.
#
# The mtime filter is only a floor against corpses — an agent killed with Esc,
# or orphaned by a crash, may never get a marker, and with no cutoff it would
# sit in the chip forever.
#
# A MARKER FOUND ONCE IS REMEMBERED, with its timestamp, in /tmp beside the
# model cache. Only the last $SUB_TAIL bytes of each scanned transcript are
# read, and a marker does not stay in that window: a busy session writes past
# it, the marker scrolls out, and from that render on the scan can no longer see
# that the agent ever stopped. Raising $SUB_TAIL only moves the threshold — any
# fixed window is outrun by a long enough session — so the timestamp is written
# down the first time it is seen and the cached value is merged with whatever
# the window still holds; the newest wins. Remembering is safe precisely because
# the comparison is against the agent's own last line, not against the cache:
# a remembered stop cannot hide a later wake.
SUB_STALE="${CLAUDE_SUB_STALE:-900}"   # s of silence before an agent counts as a corpse
SUB_TAIL="${CLAUDE_SUB_TAIL:-2000000}" # bytes of each reporting transcript scanned for stop-markers
SUB_SLACK="${CLAUDE_SUB_SLACK:-5}"     # s a stop-marker may precede the agent's last line and still count
sub_render=""
_sdir=""
[ -n "$tp" ] && _sdir="${tp%.jsonl}/subagents"
if [ -n "$_sdir" ] && [ -d "$_sdir" ] && [ -n "${sid:-}" ]; then
  # One stat(1) for the whole directory rather than one per agent: a wide
  # fan-out is exactly when this code runs, and exactly when forking twenty-odd
  # times per render would be felt.
  _now=$(date +%s)
  _fresh=""
  _stat=$(files_mtime "$_sdir"/agent-*.jsonl)
  while IFS=' ' read -r _mt _p; do
    case "$_mt" in ''|*[!0-9]*) continue ;; esac
    [ $((_now - _mt)) -le "$SUB_STALE" ] || continue
    _i=${_p##*/agent-}; _i=${_i%.jsonl}
    _fresh="$_fresh,$_i"
  done <<EOF
$_stat
EOF
  _meta=""
  if [ -n "$_fresh" ]; then
    # id -> key + the model ALIAS that was requested + the agent's name + the
    # parent agent, if one spawned it. The alias is a stand-in only: it says
    # "opus", not which Opus, and it is missing entirely when the agent
    # inherits. It carries the chip through the seconds between spawn and the
    # agent's first completed response; after that the agent's own transcript
    # says what it actually got, and the alias is never read again. The key is
    # the toolUseId when there is one and the agentId when there is not (a
    # forked skill) — the scan below only needs it to be the string the
    # reporting transcript will name when this agent stops.
    # "-" rather than an empty column: the reader splits on runs of blanks, so an
    # absent field would otherwise shift the ones after it left into its place.
    _meta=$(awk -v want="$_fresh" '
      BEGIN { n = split(want, a, ","); for (i = 1; i <= n; i++) if (a[i] != "") w[a[i]] = 1 }
      {
        id = FILENAME; sub(/.*\/agent-/, "", id); sub(/\.meta\.json$/, "", id)
        if (!(id in w) || (id in seen)) next
        seen[id] = 1
        t = ""; if (match($0, /"toolUseId":"[^"]*"/))      t = substr($0, RSTART + 13, RLENGTH - 14)
        m = ""; if (match($0, /"model":"[^"]*"/))          m = substr($0, RSTART + 9,  RLENGTH - 10)
        nm = ""; if (match($0, /"name":"[^"]*"/))          nm = substr($0, RSTART + 8, RLENGTH - 9)
        pa = ""; if (match($0, /"parentAgentId":"[^"]*"/)) pa = substr($0, RSTART + 17, RLENGTH - 18)
        if (t == "") t = id
        print id " " t " " (m == "" ? "-" : m) " " (nm == "" ? "-" : nm) " " (pa == "" ? "-" : pa)
      }' "$_sdir"/agent-*.meta.json 2>/dev/null)
  fi
  _running=""
  if [ -n "$_meta" ]; then
    # The agent side of the comparison: the last line each fresh agent wrote,
    # all in one tail(1) call. Every line names its agentId, so the output needs
    # no per-file bookkeeping. A last line with no timestamp (a transcript still
    # being born) reads as running.
    set --
    for _i in $(printf '%s' "$_fresh" | tr ',' ' '); do set -- "$@" "$_sdir/agent-$_i.jsonl"; done
    _last=$(tail -q -n 1 "$@" 2>/dev/null)
    # The transcripts an agent stops INTO: the session's own, plus the
    # transcript of every parent agent named by a fresh nested agent. Each is
    # tailed separately; markers carry absolute timestamps, so the order in
    # which the tails are concatenated does not matter.
    set -- "$tp"
    for _pa in $(printf '%s\n' "$_meta" | awk '$5 != "-" && !s[$5]++ { print $5 }'); do
      [ -r "$_sdir/agent-$_pa.jsonl" ] && set -- "$@" "$_sdir/agent-$_pa.jsonl"
    done
    # Markers already seen by earlier renders of THIS session, one "key stamp"
    # line each, newest appended last.
    _done_file="/tmp/claude-statusline-agentdone-v2-${sid}.txt"
    _done=""
    [ -r "$_done_file" ] && _done=$(cat "$_done_file" 2>/dev/null)
    # Through the environment, not -v: an awk -v assignment is a single line
    # and runs backslash escapes over the value, and these are tables.
    # Two kinds of line come back: "R <id> <alias>" for an agent still running,
    # "D <key> <stamp>" for a marker newer than anything remembered.
    _scan=$(for _f in "$@"; do tail -c "$SUB_TAIL" "$_f" 2>/dev/null; echo; done |
      _meta="$_meta" _done="$_done" _last="$_last" SLACK="$SUB_SLACK" awk '
      # ISO-8601 UTC "2026-09-20T18:53:34.378Z" -> a monotonic number in seconds.
      # Not an epoch (months are taken as 32 days) — only differences within a
      # day are ever looked at, and those it gets exactly.
      function iso2n(t,   y, mo, d, h, mi, s) {
        y = substr(t, 1, 4) + 0; mo = substr(t, 6, 2) + 0; d = substr(t, 9, 2) + 0
        h = substr(t, 12, 2) + 0; mi = substr(t, 15, 2) + 0; s = substr(t, 18) + 0
        return (((y * 12 + mo) * 32 + d) * 24 + h) * 3600 + mi * 60 + s
      }
      # The newest timestamp on a line. A line may quote older ones — a tool
      # result that dumped a transcript, an agent report that mentions a time —
      # and none of them can be later than the line itself, so the maximum is
      # the line’s own stamp. Only the UTC shape is accepted: a local-time
      # string quoted in a report would otherwise sort after the real one.
      function stamp(line,   best, s) {
        best = ""
        while (match(line, /"timestamp":"20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9](\.[0-9]+)?Z"/)) {
          s = substr(line, RSTART + 13, RLENGTH - 14)
          if (s > best) best = s
          line = substr(line, RSTART + RLENGTH)
        }
        return best
      }
      BEGIN {
        n = split(ENVIRON["_meta"], rows, "\n")
        for (i = 1; i <= n; i++) {
          if (split(rows[i], f, " ") < 5 || f[2] == "") continue
          live[f[2]] = f[1]
          alias[f[1]] = (f[3] == "-") ? "" : f[3]
          # The agentId is how a <task-id> names an agent — the only handle a
          # forked skill has, and a second witness for everyone else.
          aid[f[1]] = f[2]
        }
        n = split(ENVIRON["_done"], d, "\n")
        for (i = 1; i <= n; i++) {
          if (split(d[i], g, " ") < 2 || !(g[1] in live)) continue
          if (g[2] > mark[g[1]]) mark[g[1]] = g[2]
          cached[g[1]] = mark[g[1]]
        }
        n = split(ENVIRON["_last"], d, "\n")
        for (i = 1; i <= n; i++) {
          if (!match(d[i], /"agentId":"[^"]*"/)) continue
          a = substr(d[i], RSTART + 11, RLENGTH - 12)
          if (a in aid) last[a] = stamp(d[i])
        }
      }
      {
        ts = ""
        n = split($0, parts, /"tool_use_id":"/)
        for (i = 2; i <= n; i++) {
          p = parts[i]; q = index(p, "\""); if (q < 2) continue
          id = substr(p, 1, q - 1)
          # A launch receipt is not a return value.
          if (!(id in live) || index(p, "Async agent launched successfully")) continue
          if (ts == "") ts = stamp($0)
          if (ts > mark[id]) mark[id] = ts
        }
        n = split($0, g, /<tool-use-id>/)
        for (i = 2; i <= n; i++) {
          q = index(g[i], "<"); if (q < 2) continue
          id = substr(g[i], 1, q - 1)
          if (!(id in live)) continue
          if (ts == "") ts = stamp($0)
          if (ts > mark[id]) mark[id] = ts
        }
        n = split($0, k, /<task-id>/)
        for (i = 2; i <= n; i++) {
          q = index(k[i], "<"); if (q < 2) continue
          a = substr(k[i], 1, q - 1)
          if (!(a in aid)) continue
          if (ts == "") ts = stamp($0)
          if (ts > mark[aid[a]]) mark[aid[a]] = ts
        }
      }
      END {
        for (t in live) {
          id = live[t]
          if ((t in mark) && mark[t] != "" && mark[t] != cached[t]) print "D " t " " mark[t]
          if ((t in mark) && mark[t] != "" && (id in last) && last[id] != "" &&
              iso2n(mark[t]) >= iso2n(last[id]) - SLACK) continue
          print "R " id " " alias[id]
        }
      }')
    _running=$(printf '%s\n' "$_scan" | sed -n 's/^R //p')
    # Append rather than rewrite: a line is written only when the stamp is newer
    # than the one remembered, so the file grows by one line per stop of an
    # agent and never repeats itself. A failed write costs nothing but the old
    # behaviour.
    _newly_done=$(printf '%s\n' "$_scan" | sed -n 's/^D //p')
    [ -n "$_newly_done" ] && { printf '%s\n' "$_newly_done" >> "$_done_file"; } 2>/dev/null
    set --
  fi
  if [ -n "$_running" ]; then
    # Model and effort never change for a given agent, so they are resolved once
    # and remembered for the rest of the session. Without this a 24-way fan-out
    # re-reads 24 agent transcripts every five seconds to learn something that
    # was already settled the first time.
    _ac="/tmp/claude-statusline-agents-v1-${sid}.txt"
    _known="|"
    if [ -f "$_ac" ]; then
      while IFS= read -r _line; do
        [ -n "$_line" ] && _known="$_known$_line|"
      done < "$_ac"
    fi
    _rows=""
    set --
    while IFS=' ' read -r _id _alias; do
      [ -n "$_id" ] || continue
      case "$_known" in
        *"|$_id "*)
          _hit=${_known#*"|$_id "}; _hit=${_hit%%"|"*}
          _rows="$_rows
$_id $_hit"
          continue ;;
      esac
      set -- "$@" "$_sdir/agent-$_id.jsonl"
      # Alias fallback, so a just-spawned agent is in the chip immediately rather
      # than popping in once it has finished thinking. Effort is inherited from
      # this session, because that is what an agent gets unless its own
      # definition overrides it — and a wrong guess is corrected the moment the
      # agent's transcript becomes readable.
      [ -n "$_alias" ] || _alias="$model_name"
      _rows="$_rows
$_id $_alias $effort_raw"
    done <<EOF
$_running
EOF
    if [ "$#" -gt 0 ]; then
      # Both facts are on the agent's first completed response, so this reads
      # the head of each file and leaves: a long-running agent's transcript is
      # megabytes, and none of it after the opening entries says anything new
      # about which model it is on.
      # Model is required, effort is not: Haiku has no reasoning-effort setting
      # and writes no `effort` field at all, so demanding one meant every Haiku
      # agent failed to resolve, was never cached, and rendered as the bare alias
      # "H" carrying THIS session's effort — a letter it does not have.
      _new=$(awk '
        FNR > 40 { nextfile }
        /"type":"assistant"/ && /"model":"/ {
          id = FILENAME; sub(/.*\/agent-/, "", id); sub(/\.jsonl$/, "", id)
          m = ""; if (match($0, /"model":"[^"]*"/))  m = substr($0, RSTART + 9,  RLENGTH - 10)
          e = ""; if (match($0, /"effort":"[^"]*"/)) e = substr($0, RSTART + 10, RLENGTH - 11)
          if (m != "") { print id " " m " " e; nextfile }
        }' "$@" 2>/dev/null)
      set --
      if [ -n "$_new" ]; then
        printf '%s\n' "$_new" >> "$_ac"
        # Appended AFTER the guesses, and the aggregator keeps the last word per
        # agent: what the agent actually ran on overrides what was asked for.
        _rows="$_rows
$_new"
      fi
    fi
    sub_chip=$(printf '%s\n' "$_rows" | awk '
      # "claude-fable-5-1" -> F5.1, "claude-haiku-4-5-20251001" -> H4.5,
      # "Opus 5 (1M)" -> O5, the bare alias "opus" -> O. Family initial plus
      # whatever version the name carries: the initial is what the eye reads, the
      # digits are what tell two generations apart, everything else is noise.
      function abbr(s,   v, i, n, p) {
        s = tolower(s)
        sub(/^claude-/, "", s)
        sub(/ *\(.*\)$/, "", s)
        sub(/\[[^]]*\]$/, "", s)
        gsub(/[ _]/, "-", s)
        sub(/-2[0-9][0-9][0-9][0-9][0-9][0-9][0-9]$/, "", s)
        n = split(s, p, "-")
        v = ""
        for (i = 2; i <= n; i++) v = v (v == "" ? "" : ".") p[i]
        return toupper(substr(p[1], 1, 1)) v
      }
      # Same table as the main model segment above, and for the same reason: "m"
      # is medium, so "max" stays spelled out rather than colliding with it.
      function eff(e) {
        if (e == "low")    return "l"
        if (e == "medium") return "m"
        if (e == "high")   return "h"
        if (e == "xhigh")  return "xh"
        if (e == "max")    return "max"
        return e
      }
      NF >= 2 { mdl[$1] = $2; lvl[$1] = $3 }
      END {
        for (id in mdl) { k = abbr(mdl[id]) eff(lvl[id]); if (!(k in c)) ord[++n] = k; c[k]++ }
        if (!n) exit
        # Biggest group first: the chip answers "what is the bulk of this
        # fan-out running on" before it answers "what else is in there".
        for (i = 2; i <= n; i++) {
          k = ord[i]
          for (j = i - 1; j >= 1 && (c[ord[j]] < c[k] || (c[ord[j]] == c[k] && ord[j] > k)); j--) ord[j + 1] = ord[j]
          ord[j + 1] = k
        }
        s = ""
        for (i = 1; i <= n; i++) s = s (i > 1 ? " +" : "+") (c[ord[i]] > 1 ? c[ord[i]] "×" : "") ord[i]
        printf "%s", s
      }')
    [ -n "$sub_chip" ] && sub_render=" ${GREEN}${sub_chip}${RESET}"
  fi
fi
unset _sdir _stat _fresh _meta _running _known _rows _new _ac _line _id _alias _hit _mt _p _i _now _last _pa _f _scan _done _done_file _newly_done
out="${out%%@@SUB@@*}${sub_render}${out#*@@SUB@@}"

# --- Resolve the context counter's placeholder, now that the cache state is known.
# Three reasons the number stops being calm blue, in priority order:
#   1. the cached prefix has EXPIRED, dearly    -> red blink
#   2. it is about to expire, dearly            -> orange blink
#   3. the context is simply enormous (>300K)   -> static red
#      (Opus/Fable: static orange >300K, red only from 650K)
# (1) and (2) also blink the "-N" clock, and the pair is the whole point: the
# clock says how long the cache has left, the token count says how much it is
# worth. Watching either alone tells you half of "is idling here about to cost
# me a dollar" — so they light up together, in the same colour, on the same beat.
# (3) is the standalone case: an oversized context is expensive to carry whether
# or not it is cached, and it means compaction is coming.
#
# "Dearly" is miss_big, and it is asked HERE rather than inside cache_phase so
# the clock can still report a sub-threshold miss in plain text while this
# counter stays quietly blue. The alarm and the report have different floors on
# purpose; only the alarm is shared.
if [ -n "$abs_label" ]; then
  # TTL phase only counts while IDLE. While the agent is working it is hitting
  # the cache every few seconds, so the prefix is warm by definition and the
  # "time since the last turn" clock says nothing about it — blinking off a stale
  # age there would fire the warning during exactly the period when there is
  # nothing to warn about.
  ctx_phase=none
  if [ "${idle:-0}" = "1" ] && miss_big; then
    ctx_phase=$(cache_phase "${age_secs:-}")
  fi
  case "$ctx_phase" in
    expired)  ctx_render=$(pulse red "$abs_label") ;;
    expiring) ctx_render=$(pulse orange "$abs_label") ;;
    *)
      # Static, NOT a blink: an oversized context is a standing fact, not
      # an event. The blink is reserved for the cache-TTL cases above, which
      # are time-critical and only fire while idle — letting the size rule
      # blink too meant a 380K session flashing red for the whole turn, which
      # is exactly when there is nothing you can do about it.
      # On Opus/Fable (always a 1M window) 300K is a third of the room, not an
      # emergency: it goes orange there, and red only from 650K.
      if [ -n "$is_1m_family" ] && [ "${used_tokens:-0}" -ge 650000 ] 2>/dev/null; then
        ctx_render="${RED}${abs_label}${RESET}"
      elif [ "${used_tokens:-0}" -gt 300000 ] 2>/dev/null; then
        if [ -n "$is_1m_family" ]; then
          ctx_render="${ORANGE}${abs_label}${RESET}"
        else
          ctx_render="${RED}${abs_label}${RESET}"
        fi
      else
        ctx_render="${BLUE}${abs_label}${RESET}"
      fi
      ;;
  esac
  # Plain shell substitution, not sed: $ctx_render is full of ESC and & bytes
  # that sed's replacement syntax would mangle.
  out="${out%%@@CTX@@*}${ctx_render}${out#*@@CTX@@}"
fi

if [ -f "$HOME/.claude/statusline-debug" ]; then
  printf '%s OUT %s %s\n' "$(date +%s)" "${session_id%%-*}" \
    "$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')" \
    >> "$HOME/.claude/statusline-debug.log" 2>/dev/null
fi
echo "$out"
