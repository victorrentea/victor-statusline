# Victor's Copilot CLI status line

A rich one-line status bar for **GitHub Copilot CLI**. Example:

```
🤖 opus-5h 55/264K 21% | $0.09 ∈ Session: $0.4 | 79%↗ ($8.2/$10) left today | +15%⊂98% $197 (19694 AIC) / 19wd8h left
```

Four ` | `-separated segments:

1. **model/effort context** — model name (the `claude-` prefix stripped), the
  reasoning effort as **one letter glued straight on** (`opus-5h`, `sonnet-5m`,
  `…x` for xhigh, `…l` for low), and **used/limit** context tokens. `minimal` and
  `max` would both collide with `medium`, so those two keep their word behind a
  `/`. The two token counts **share one unit suffix** (`119/264K`) and the
  percentage stands bare beside them — the duplicated `K` and the parentheses were
  four columns carrying nothing.
  The used-token count turns **yellow ≥65%** and **red ≥95%** of the window. The
  `%` is shown only when the window isn't the full 1M.
2. **turn ∈ session** — `$0.09 ∈ Session: $0.4`: what the **last turn** cost, and
   the session total it is one of. The wording is Copilot's own footer
   (`Session: 285.11 AIC used`) on purpose, so the two numbers can be read against
   each other instead of looking like two unrelated things; the unit is dollars,
   because that is what the rest of the line speaks. The `∈` stands in for a label
   — the turn *is* an element of that session total, and the symbol says so in one
   column where the word `turn` took five.
   The **turn** figure is the session total minus whatever it was when that turn
   started. The payload has no per-turn figure and nothing in it marks a turn
   boundary, so it comes from the pair of files in **File 3**: a
   `userPromptSubmitted` hook drops an empty marker, and the next render promotes
   the total it last drew to the turn's baseline. That last render is the idle line
   from before the prompt, so the baseline is exact. Once the turn ends the total
   stops moving and the figure **freezes on what that turn cost** — walk back to a
   session you left working and the bar tells you what the prompt you fired on your
   way out actually burned. It is absent until a session's first prompt.
   The **session** figure is the same number Copilot prints in its footer as
   `Session: 11.18 AIC used`, and the **only live figure on the line**: it arrives
   in the payload on every render, while the two segments after it are read from a
   cache refreshed in the background *only while a session is rendering*, so on a
   session left idle they can sit an hour behind. Money is shown to the cent below
   \$1 — a turn is small change, and `$0.0` would say nothing.
3. **today** — share of *today's* budget **still unspent**, a pace arrow, and the
   absolutes in parentheses: `($ left/$ budget)`. Today's budget is
   "credits left at the start of today ÷ working days left until the reset",
   recomputed daily, so an overshoot never carries a debt — tomorrow simply gets
   a smaller slice. It **starts the day at `100%` and counts down**; both sides
   of the slash are "left" as well, so nothing inside the parentheses contradicts
   the percentage in front of them. Overspending shows as a negative (`-14% left
   today`) rather than being clamped at zero — how far past the plan you are is
   exactly the number worth seeing. The burn behind it comes from GitHub's
   per-day billing endpoint, which lags the spend by minutes, so **segment 2 acts
   as a floor on it**: the line must never read `$0 today` while announcing money
   burned in this very session. The floor only applies to a session that *started*
   today — checked against its wall-clock age — since an older one would be
   booking yesterday's credits onto today.
4. **AI Credits** — a signed **reserve** in percentage points (working time
   elapsed − credits burned) joined by `⊂` to the `% left`, because the reserve is
   a *part* of what is left rather than another name for it (`+15%⊂98%` reads "of
   the 98% still mine, 15 points are ahead of schedule"); then the balance in
   dollars with the credits as a parenthesised footnote, then the **working** days
   + hours until the monthly quota resets (weekends excluded). One `left` serves
   the whole segment and sits at the very end, after the clock: the balance and the
   countdown are both what is left of the month, and a static word is cheaper read
   once, last, than stepped over in the middle.

Every figure on the line is in **list-price dollars** at 100 AIC = \$1. Credits are
an abstract unit invented for billing; the dollar is the one both a daily burn rate
and a monthly balance can be judged in without mental arithmetic — and printing both
units on every number (`$2.6≈257 AIC`) cost twice the width to say the same thing
twice. The credit figure survives in **one** place, the monthly balance
(`$197 (19694 AIC)`), because that is the number GitHub's own UI quotes back in
credits, so the line stays comparable with it — in parentheses, as a footnote to
the dollars rather than their equal.

The finished line is **cut to the terminal width with a `…`**. Copilot CLI redraws
the status line in place, so one column too many wraps it onto a second row that
the TUI never repaints away. The width comes from `stty size </dev/tty` (our
stdout is captured, so `$COLUMNS` and `tput cols` are both blind), and columns are
counted printable — colour escapes are zero-width, the emoji is two. Override with
`COPILOT_STATUSLINE_COLS`; an unknown width disables the trim rather than guessing.
`COPILOT_STATUSLINE_NOW` (ISO-8601) pins the clock the same way, because the
"today" segment changes shape with the calendar — no daily budget on a weekend,
so no percentage and no pace arrow — and the screenshot generator needs the
working-day shape on whatever day it happens to run.

---

## TL;DR — let your Copilot CLI configure itself

From a repo that contains this file, run `copilot` and paste:

> Read `copilot/victor-copilot-statusline.md` and set me up an identical Copilot
> CLI status line. Create `~/.copilot/statusline.sh` and `~/.copilot/quota-refresh.sh`
> exactly as in the doc, `chmod +x` both, prime the cache by running
> `bash ~/.copilot/quota-refresh.sh`, add `~/.copilot/hooks/turn-mark.sh`
> (`chmod +x`) and `~/.copilot/hooks/turn-mark.json` from File 3, and add the
> `statusLine` block to `~/.copilot/settings.json` (merge with existing JSON,
> don't clobber it).
> Then verify by piping a sample JSON payload into `statusline.sh`.

**Prerequisites:** `bash`, `python3`, and the `gh` CLI authenticated
(`gh auth status`) with a Copilot subscription.

---

## Anatomy of the data

Copilot CLI feeds the status-line command a JSON payload **on stdin** each render.
The fields we use:

| Field | Used for |
|-------|----------|
| `model.display_name` (e.g. `claude-opus-4.8 · high · 1M context`) | model · effort segment |
| `context_window.current_context_tokens` | used tokens |
| `context_window.displayed_context_limit` | window size |
| `ai_used.total_nano_aiu` (credits × 10⁹, e.g. `11177320000`) | this session's burn, and — against the stored baseline — this turn's |
| `session_id` | which turn-state file to read and write |
| `cost.total_duration_ms` | session age, guarding the "today" floor |

The **monthly AI-Credit balance and reset date are NOT in that payload.** They
come from `gh api copilot_internal/user`, cached to `~/.copilot/quota-cache.json`
and refreshed in the background (at most once a minute, `TTL` in the script) so
rendering stays instant.
The relevant snapshot is `quota_snapshots.premium_interactions`
(`remaining`, `percent_remaining`) plus `reset_utc` / `reset_date`.

---

## File 1 — `~/.copilot/statusline.sh`

```bash
#!/usr/bin/env bash
# Copilot CLI status line. Example output:
#   🤖 sonnet-5m 55/264K 21% | $0.09 ∈ Session: $0.4 | 26%↗ ($0.9/$3.5) left today | +3%⊂95% $66 (6646 AIC) / 20wd7h left
#
#   • model: display_name with the "claude-" prefix stripped, the reasoning
#     effort glued on as one letter (medium→m, high→h, xhigh→x, low→l) and the
#     " · N context" tail replaced by "<used>/<limit>" context tokens, sharing
#     one unit suffix ("119/264K"), plus a bare % (used count coloured yellow
#     ≥65% / red ≥95%; % hidden when the window is 1M).
#   • turn ∈ session: what the LAST TURN burned, then the session total it is part
#     of, worded like Copilot's own footer ("Session: 285.11 AIC used") so the two
#     can be read against each other — in dollars, since that is the unit the rest
#     of the line speaks. The turn is the running session total minus what it
#     was when that turn started. Where a turn starts comes from the
#     userPromptSubmitted hook (turn-mark.sh), which drops a marker this script
#     turns into a baseline on its next render; absent before a session's first
#     prompt. Frozen once the turn ends, so walking back to a session tells you
#     what the prompt you left running actually cost. The session figure is the only live credit
#     figure on the line, and the one Copilot itself prints in its footer as
#     "Session: 11.18 AIC used". It arrives in the payload on every render,
#     whereas the two segments after it come from a cache that is only
#     refreshed while a session is busy, so they can sit hours behind. Shown to
#     cents below a dollar: a turn is small change, and "$0.0" would say nothing.
#   • today: share of today's budget still UNSPENT + ($ left/$ budget),
#     where the budget is simply "credits left at the start of today ÷ working
#     days left until the reset". Because it is recomputed from the CURRENT
#     balance every day, overshooting or undershooting today never carries a
#     debt — tomorrow just gets a smaller or larger slice, and the plan still
#     lands on 0 exactly at the reset. The arrow compares the share of the
#     budget spent against the share of the WORKING DAY (09:00–18:00 local)
#     elapsed, so it says "am I burning faster than the clock" (↑↗ green ahead /
#     none on-track / ↘ yellow / ↓ red too fast).
#   • AI Credits: a signed RESERVE in percentage points ("how much of the month's
#     entitlement I still have beyond what I should have left by now", i.e.
#     working-time elapsed − credits burned), joined by "⊂" to the remaining %
#     because the reserve is a PART of what is left, not another name for it;
#     then the balance in dollars with the credits in parentheses, then the
#     WORKING days + hours until the monthly quota resets. Signed number rather
#     than an arrow so it reads in the same unit as the "% left" beside it
#     — mirrors the weekly segment of victor-claude-statusline.md.
#   • money: everything on the line is DOLLARS at AIC_PER_USD credits per dollar.
#     Credits are an abstract unit — the dollar is the one both a burn rate and a
#     balance can be judged in without doing arithmetic in your head, and printing
#     both units on every figure ("$2.6≈257 AIC") doubled the width of each number
#     to say the same thing twice. The credit figure survives in exactly one place,
#     the monthly balance ("$198 (19819 AIC)"), because that is the number GitHub's
#     own UI quotes back in credits, so the line has to stay comparable with it —
#     parenthesised, as the footnote to the dollars rather than their equal.
#
#   • width: the finished line is cut to the terminal width with a "…" when it
#     would not fit. Copilot CLI redraws the status line in place, so a single
#     column too many makes the terminal wrap it onto a second row — which the
#     TUI then leaves behind as a stray leftover line instead of repainting it.
#
# Copilot CLI pipes the session status as JSON on stdin; we print one line to
# stdout. The monthly AI-Credit balance and reset date are NOT in that payload,
# so they come from a small cache refreshed in the background by quota-refresh.sh
# from `gh api copilot_internal/user`. See victor-copilot-statusline.md.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
CACHE="$HOME/.copilot/quota-cache.json"
TTL=60    # refresh the quota cache at most once per minute (keeps AIC current)

INPUT="$(cat 2>/dev/null)"

# --- terminal width, for trimming the line to one row ----------------------
# Copilot CLI captures our stdout, so $COLUMNS is not exported to us and
# `tput cols` has no terminal to interrogate. The controlling terminal is still
# reachable as /dev/tty, and `stty size` reads its size straight off the ioctl.
# 0 means "unknown" downstream, which disables trimming rather than guessing.
COLS="${COPILOT_STATUSLINE_COLS:-}"
[ -z "$COLS" ] && COLS="$(stty size </dev/tty 2>/dev/null | awk '{print $2}')"
[ -z "$COLS" ] && COLS="$(tput cols 2>/dev/null)"
case "$COLS" in ''|*[!0-9]*) COLS=0 ;; esac

# --- the bound-session microphone -------------------------------------------
# Black 🎙️ on yellow in front of the line when Walkie Talkie is bound to THIS
# session — the same badge as victor-claude-statusline.md §0, for the same
# reason: in a screen of identical terminals the bar is the one place that says
# which of them the dictation goes to. The relay publishes the bound tty as the
# first line of ~/.walkie-talkie/bound-tty; Copilot CLI ($PPID) holds the
# session's terminal. Nothing bound = one failed builtin `read`, no fork.
MIC=""
_bt=""
[ -r "$HOME/.walkie-talkie/bound-tty" ] && read -r _bt < "$HOME/.walkie-talkie/bound-tty" 2>/dev/null
if [ -n "$_bt" ]; then
  _mytty=$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')
  [ "$_bt" = "$_mytty" ] && MIC=1
fi

# --- refresh the monthly-quota cache in the background when stale (non-blocking) --
now=$(date +%s 2>/dev/null || echo 0)
# GNU `stat -c` first: on GNU `stat -f` exits 1 yet still prints a block of
# filesystem info to stdout, which the BSD-first order let into the result.
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
cmtime=0; [ -f "$CACHE" ] && cmtime=$(file_mtime "$CACHE")
lock="$CACHE.lock"; lmtime=0; [ -f "$lock" ] && lmtime=$(file_mtime "$lock")
if [ "$(( now - cmtime ))" -ge "$TTL" ] && [ "$(( now - lmtime ))" -ge "$TTL" ]; then
  : > "$lock" 2>/dev/null || true           # stampede guard: one refresh per TTL
  [ -f "$DIR/quota-refresh.sh" ] && nohup bash "$DIR/quota-refresh.sh" "$CACHE" >/dev/null 2>&1 &
fi

python3 - "$INPUT" "$CACHE" "$COLS" "$MIC" <<'PY'
import sys, json, os, time

raw   = sys.argv[1] if len(sys.argv) > 1 else ""
cache = sys.argv[2] if len(sys.argv) > 2 else ""
try:
    cols = int(sys.argv[3]) if len(sys.argv) > 3 else 0
except ValueError:
    cols = 0
try:
    d = json.loads(raw) if raw.strip() else {}
except Exception:
    print("🤖 copilot"); sys.exit(0)

def find(obj, *names):
    """First value (by NAME priority) for any of `names`, searched recursively."""
    for name in names:
        stack = [obj]
        while stack:
            cur = stack.pop()
            if isinstance(cur, dict):
                if name in cur and not isinstance(cur[name], (dict, list)):
                    return cur[name]
                stack.extend(cur.values())
            elif isinstance(cur, list):
                stack.extend(cur)
    return None

def human(n):
    try: n = float(n)
    except (TypeError, ValueError): return None
    if n >= 1_000_000: return f"{n/1_000_000:.0f}M" if n % 1_000_000 == 0 else f"{n/1_000_000:.1f}M"
    if n >= 1_000:     return f"{n/1_000:.0f}K"
    return f"{n:.0f}"

# GitHub bills AI Credits at this many per dollar of list price; every credit
# figure on the line is shown in dollars too, because "$99" lands instantly
# where "19819 AIC" needs a conversion done in your head first.
AIC_PER_USD = 100.0

def prune_turn_state(sdir, max_age=14 * 86400):
    """Forget sessions nobody has rendered in a fortnight. Called once per turn
    (when a marker is consumed), which is rare enough to cost nothing and often
    enough that the directory never grows into a listing worth noticing."""
    try: names = os.listdir(sdir)
    except OSError: return
    cutoff = time.time() - max_age
    for n in names:
        f = os.path.join(sdir, n)
        try:
            if os.path.getmtime(f) < cutoff: os.unlink(f)
        except OSError:
            pass

def usd(credits):
    """Credits as list-price dollars, at the precision the size deserves: cents
    under a dollar (a single turn is small change, and "$0.0" would say nothing),
    one decimal under $10, whole dollars above — nobody reads a monthly balance
    to the cent."""
    try: v = float(credits) / AIC_PER_USD
    except (TypeError, ValueError, ZeroDivisionError): return None
    if abs(v) < 1:  return f"${v:.2f}"
    return f"${v:.1f}" if abs(v) < 10 else f"${v:.0f}"

# ANSI colours (used-token count, pace arrow, reserve) — mirrors victor-claude-statusline.md
CLR_RESET = "\033[0m"
CLR_RED   = "\033[31m"
CLR_YEL   = "\033[38;5;208m"
CLR_GRN   = "\033[38;5;78m"

parts = []

# --- model/effort context-usage ------------------------------------------
# display_name looks like "claude-sonnet-5 · medium · 264K context"; we strip
# the "claude-" prefix, glue the effort onto the name as ONE letter, and
# replace the " · <N> context" tail with used/limit tokens. The whole segment
# is one glance's worth of "which brain, how hard, how full".
#
# "sonnet-5m", not "sonnet-5/med": four columns and a separator to say what the
# single letter says, on a line that is already fighting for width, and everyone
# reads the letter right the first time. Only efforts whose initial is
# unambiguous get one — "minimal" and "max" would both collide with "medium", so
# they keep their word and, with it, the "/" that marks them as a separate token.
EFFORT_SHORT = {"minimal": "min", "min": "min", "low": "l",
                "medium": "m", "med": "m", "high": "h",
                "xhigh": "x", "x-high": "x", "extra high": "x",
                "very high": "x", "max": "max", "maximum": "max"}

model = find(d, "display_name", "displayName") or find(d, "id", "model") or "copilot"
if isinstance(model, str):
    if model.lower().startswith("claude-"):
        model = model[len("claude-"):]
    bits = [p.strip() for p in model.split(" · ") if "context" not in p.lower()]
    label = bits[0] if bits else "copilot"
    if len(bits) > 1 and bits[1]:
        eff = EFFORT_SHORT.get(bits[1].lower(), bits[1])
        label += eff if len(eff) == 1 else "/" + eff
    used  = find(d, "current_context_tokens", "currentContextTokens")
    limit = find(d, "displayed_context_limit", "displayedContextLimit",
                 "context_window_size", "contextWindowSize")
    if used is not None and limit is not None:
        try: upct = 100.0 * float(used) / float(limit)
        except (TypeError, ValueError, ZeroDivisionError): upct = None
        used_lbl, lim_lbl = human(used), human(limit)
        # "119/264K", not "119K/264K": the unit is the same on both sides of the
        # slash, so the first one is a column spent on nothing. It is only dropped
        # when the two agree — "55K/1M" still needs both.
        if used_lbl and lim_lbl and used_lbl[-1] == lim_lbl[-1] and not used_lbl[-1].isdigit():
            used_lbl = used_lbl[:-1]
        if upct is not None:            # colour the used-token count as the window fills
            if   upct >= 95: used_lbl = f"{CLR_RED}{used_lbl}{CLR_RESET}"
            elif upct >= 65: used_lbl = f"{CLR_YEL}{used_lbl}{CLR_RESET}"
        ctx = f"{used_lbl}/{lim_lbl}"
        # Bare, not parenthesised: nothing else is competing for that spot, so the
        # brackets were two more columns holding a number that needs no framing.
        if lim_lbl != "1M" and upct is not None:  # show % only when window isn't the full 1M
            ctx += f" {upct:.0f}%"
        label = f"{label} {ctx}"
    model = label
parts.append(f"🤖 {model}")

# --- this session's own credit burn ---------------------------------------
# The one LIVE credit figure on the line. Copilot ships it in the payload on
# every render (the same number its own footer shows as "Session: 11.18 AIC
# used"), while everything after this segment comes from a background cache
# that is only refreshed while a session is rendering — so on an idle session
# the monthly figures can be an hour stale and this one is never stale at all.
# Counted in nano-credits, because 11.17732 AIC has no float representation
# worth trusting and GitHub sends the integer.
session_credits = None
nano = find(d, "total_nano_aiu", "totalNanoAiu")
if nano is not None:
    try: session_credits = float(nano) / 1e9
    except (TypeError, ValueError): session_credits = None
# --- what the LAST TURN cost ----------------------------------------------
# The number you want when you walk back to a session you left working: what the
# prompt you fired before leaving actually burned. The payload has no per-turn
# figure, only the session's running total, so the turn's cost is that total minus
# its value when the turn began — and where a turn begins is told to us by the
# userPromptSubmitted hook (turn-mark.sh), which drops an empty marker file.
#
# The marker cannot carry the baseline itself (the hook payload has no spend in
# it), so this is where the two halves meet: every render records the total it
# just drew, and a marker means "the value you last drew is where this turn
# starts". That is exactly right, because the last render before a prompt is the
# idle line — no credits have moved since.
#
# Once the turn ends the total stops moving, so the segment freezes on the final
# cost of that turn and stays there until the next prompt. Before the first
# prompt of a session there is no baseline and no segment at all.
turn_credits = None
sid = find(d, "session_id", "sessionId")
if sid is not None and session_credits is not None:
    sdir = os.path.join(os.path.expanduser("~"), ".copilot", "turn-state")
    sfile = os.path.join(sdir, f"{sid}.json")
    marker = os.path.join(sdir, f"{sid}.new")
    st = {}
    try:
        with open(sfile) as f: st = json.load(f)
    except Exception:
        st = {}
    if not isinstance(st, dict): st = {}
    base = st.get("base")
    if os.path.exists(marker):
        base = st.get("last", session_credits)
        try: os.unlink(marker)
        except OSError: pass
        prune_turn_state(sdir)
    # A total that went BACKWARDS is a session id reused against a stale file;
    # trust the payload and start over rather than print a negative turn.
    if base is None or base > session_credits:
        base = None if base is None else session_credits
    if base is not None:
        turn_credits = session_credits - base
    try:
        os.makedirs(sdir, exist_ok=True)
        tmp = sfile + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"last": session_credits, "base": base}, f)
        os.replace(tmp, sfile)
    except Exception:
        pass

# "$0.09 ∈ Session: $2.9" — Copilot's own footer three lines below says
# "Session: 285.11 AIC used", so the bar answers in the same words, only in money:
# two figures that disagree in unit and in wording read as two different things.
# The turn hangs off it with "∈" rather than a label of its own: it IS one of the
# turns that make up that session total, and the symbol says so in one column
# where the word "turn" took five.
if session_credits is not None:
    seg = f"Session: {usd(session_credits)}"
    if turn_credits is not None:
        seg = f"{usd(turn_credits)} ∈ {seg}"
    parts.append(seg)

# --- AI Credits remaining, reserve, working-days to reset ------------------
q = {}
try:
    with open(cache) as f:
        q = json.load(f)
except Exception:
    q = {}

from datetime import datetime, timezone, timedelta

# One clock for the whole line. COPILOT_STATUSLINE_NOW (ISO-8601, with offset)
# pins it, for the same reason COPILOT_STATUSLINE_COLS pins the width: the
# screenshot generator has to be reproducible, and this line changes shape with
# the calendar -- on a weekend there is no daily budget, so the "today" segment
# drops its percentage and its pace arrow. A picture taken on a Sunday would
# document the fallback shape as if it were the bar.
def _now():
    pin = os.environ.get("COPILOT_STATUSLINE_NOW")
    if pin:
        try: return datetime.fromisoformat(pin).astimezone(timezone.utc)
        except ValueError: pass
    return datetime.now(timezone.utc)

reset = q.get("reset_utc") or q.get("reset_date")
reset_dt = None
if reset:
    try:
        reset_dt = datetime.fromisoformat(str(reset).replace("Z", "+00:00"))
        if reset_dt.tzinfo is None:
            reset_dt = reset_dt.replace(tzinfo=timezone.utc)
    except Exception:
        reset_dt = None

def working_seconds(a, b):
    """Seconds in [a, b) that fall on weekdays (Sat/Sun excluded)."""
    total, cur = 0.0, a
    while cur < b:
        nxt = datetime(cur.year, cur.month, cur.day, tzinfo=timezone.utc) + timedelta(days=1)
        seg = min(nxt, b)
        if cur.weekday() < 5:
            total += (seg - cur).total_seconds()
        cur = seg
    return total

def working_days_left(now_local, reset_local_date):
    """Weekdays from today (inclusive) up to the reset date (exclusive)."""
    day, n = now_local.date(), 0
    while day < reset_local_date:
        if day.weekday() < 5:
            n += 1
        day += timedelta(days=1)
    return n

def pace_arrow(ratio):
    """Arrow for 'budget share left' ÷ 'time share left' — >1 means ahead."""
    if   ratio >= 1.5:  return f"{CLR_GRN}↑{CLR_RESET}"
    elif ratio >= 1.15: return f"{CLR_GRN}↗{CLR_RESET}"
    elif ratio >= 0.87: return ""
    elif ratio >= 0.67: return f"{CLR_YEL}↘{CLR_RESET}"
    return f"{CLR_RED}↓{CLR_RESET}"

snaps = q.get("quota_snapshots") or {}
snap = snaps.get("premium_interactions")
if not snap:
    for s in snaps.values():
        if isinstance(s, dict) and s.get("has_quota") and not s.get("unlimited") \
           and (s.get("entitlement") or 0) > 0:
            snap = s
            break

# --- credits burned today vs today's slice of what's left -----------------
# Today's usage comes from the per-day billing endpoint (cached by
# quota-refresh.sh); if that endpoint is unavailable we fall back to the
# month-to-date delta since the first refresh of the day.
WORK_START, WORK_END = 9, 18          # local working hours driving the pace arrow

lnow = _now().astimezone()
today_str = lnow.strftime("%Y-%m-%d")
today_used = None
if isinstance(snap, dict) and not snap.get("unlimited"):
    if q.get("today_credits") is not None and q.get("today_credits_date") == today_str:
        today_used = float(q["today_credits"])
    else:
        base = q.get("day_baseline") or {}
        if base.get("date") == today_str and base.get("month_used_at_start") is not None \
           and snap.get("credits_used") is not None:
            today_used = max(0.0, float(snap["credits_used"]) - float(base["month_used_at_start"]))

# A session that started today has certainly spent its credits today, so its
# live figure is a FLOOR for the day's burn. Without it the line can contradict
# itself — "11.2 AIC this session" sitting next to "0 AIC today" — because the
# per-day billing endpoint lags the spend by minutes and the cache in front of
# it only refreshes while a session is rendering. Guarded by the session's
# wall-clock age: one running since yesterday would book yesterday's credits
# onto today.
if today_used is not None and session_credits is not None and session_credits > today_used:
    age_ms = find(d, "total_duration_ms", "totalDurationMs")
    try: started = lnow - timedelta(milliseconds=float(age_ms))
    except (TypeError, ValueError): started = None
    if started is not None and started.date() == lnow.date():
        today_used = session_credits

if today_used is not None:
    seg = f"{usd(today_used)} today"
    rem = snap.get("remaining")
    wdl = working_days_left(lnow, reset_dt.astimezone().date()) if reset_dt else 0
    # On a weekend there is no daily budget to measure against — just the raw burn.
    if wdl > 0 and rem is not None and lnow.weekday() < 5:
        budget = (float(rem) + today_used) / wdl
        if budget > 0:
            frac = today_used / budget
            # What is LEFT, not what is gone: the segment says "left today", so the
            # number next to it has to count down from 100% as the day is spent.
            # It had been printing the burned share under a "left" label — the one
            # number on the line you could read backwards without noticing.
            # Allowed to go negative: "-14% left today" is the whole point of an
            # overspend, and clamping it at 0% would hide how far past the plan it is.
            left = 1.0 - frac
            pct = f"{left * 100:.0f}%"
            if   left <= 0.0:  pct = f"{CLR_RED}{pct}{CLR_RESET}"
            elif left <= 0.15: pct = f"{CLR_YEL}{pct}{CLR_RESET}"
            start = lnow.replace(hour=WORK_START, minute=0, second=0, microsecond=0)
            end   = lnow.replace(hour=WORK_END,   minute=0, second=0, microsecond=0)
            elapsed = (lnow - start).total_seconds() / max(1.0, (end - start).total_seconds())
            elapsed = min(1.0, max(0.0, elapsed))
            # Ahead of the clock => spent a smaller share of the budget than of the day.
            arrow = pace_arrow(99.0 if frac <= 0 else elapsed / frac)
            # Percentage first, absolutes in parentheses: the share is the glance,
            # the dollars are the detail you read second. Both sides of the slash
            # are "left" too — money still available out of today's budget — so the
            # parentheses cannot be read against the percentage in front of them.
            seg = f"{pct}{arrow} ({usd(max(0.0, budget - today_used))}/{usd(budget)}) left today"
    parts.append(seg)

# --- working days + hours until the reset (weekends excluded) -------------
time_left = ""
if reset_dt:
    now  = _now()
    secs = int((reset_dt - now).total_seconds())
    if secs > 0:
        hh = (secs % 86400) // 3600
        wd = working_days_left(lnow, reset_dt.astimezone().date())
        time_left = f"{wd}wd{hh}h" if wd else f"{hh}h"

if isinstance(snap, dict):
    if snap.get("unlimited"):
        seg = "∞ AIC"
    else:
        rem = snap.get("remaining")
        pr  = snap.get("percent_remaining")
        seg = f"{pr:.0f}% " if pr is not None else ""
        # Dollars bare, credits parenthesised: the dollar is the figure being
        # read, the credit count is the footnote that makes it checkable against
        # what GitHub's own UI quotes back.
        seg += f"{usd(rem)} ({int(rem)} AIC)" if rem is not None else ""
        # RESERVE, in percentage points: working time already elapsed in the
        # billing period minus credits already burned. "+3%" = I am three points
        # of the monthly entitlement richer than the calendar says I should be.
        # A point-difference (not a ratio) because it stays readable at both ends
        # of the month, and because it compares directly with the "% left" next to it.
        now = _now()
        if pr is not None and reset_dt and reset_dt > now:
            ps = datetime(reset_dt.year if reset_dt.month > 1 else reset_dt.year - 1,
                          reset_dt.month - 1 if reset_dt.month > 1 else 12, 1,
                          tzinfo=timezone.utc)
            total_w, left_w = working_seconds(ps, reset_dt), working_seconds(now, reset_dt)
            if total_w > 0:
                delta = round(100.0 * (total_w - left_w) / total_w - (100.0 - pr))
                if   delta > 0: res = f"{CLR_GRN}+{delta:.0f}%{CLR_RESET}"
                elif delta == 0: res = "0%"
                elif delta > -10: res = f"{CLR_YEL}{delta:.0f}%{CLR_RESET}"
                else: res = f"{CLR_RED}{delta:.0f}%{CLR_RESET}"
                # "⊂", not "=": the reserve is not equal to what is left, it is a
                # PART of it — "+21%⊂69%" reads "of the 69% still mine, 21 points
                # are ahead of schedule". The "=" said the two were the same
                # number. No spaces: one token, so the eye does not stop twice.
                seg = f"{res}⊂{seg}"
    # One "left" for the whole segment, parked at the very end after the clock:
    # the balance and the countdown are both what is LEFT of the month, and the
    # word is static furniture — reading it once, last, costs nothing and frees
    # the middle of the segment for figures that actually move.
    if time_left:
        seg = f"{seg.rstrip()} / {time_left} left"
    parts.append(seg)
elif time_left:
    parts.append(f"resets in {time_left}")

# --- fit to one row --------------------------------------------------------
# Width has to be counted in PRINTABLE columns, which is neither len() nor the
# byte count: the colour escapes take zero columns and the emoji takes two. What
# overflows is cut and replaced by a single "…", so the line always ends in the
# marker that says "there was more" rather than mid-number.
import re, unicodedata

ANSI = re.compile(r"\033\[[0-9;]*m")

def cw(ch):
    """Columns one character occupies in a terminal."""
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1

def fit(s, cols):
    if cols <= 0:                      # width unknown: never risk cutting
        return s
    budget = cols - 1                  # never touch the last column: a glyph
                                       # landing there wraps on some terminals
    if sum(cw(c) for c in ANSI.sub("", s)) <= budget:
        return s
    keep, w, limit, i = [], 0, budget - 1, 0   # -1 leaves room for the "…"
    while i < len(s):
        m = ANSI.match(s, i)
        if m:                          # escapes cost nothing, copy them through
            keep.append(m.group()); i = m.end(); continue
        if w + cw(s[i]) > limit:
            break
        keep.append(s[i]); w += cw(s[i]); i += 1
    return "".join(keep) + "…" + CLR_RESET   # reset: the cut may drop one

mic = "\033[1;30;48;5;226m 🎙️ \033[0m " if len(sys.argv) > 4 and sys.argv[4] else ""
print(fit(mic + " | ".join(parts), cols))
PY
```

## File 2 — `~/.copilot/quota-refresh.sh`

Fetches the monthly quota snapshot into the cache the status line reads. Called
detached by `statusline.sh`, and safe to run standalone to prime the cache.

```bash
#!/usr/bin/env bash
# Fetch the user's Copilot quota snapshot into a small cache file that
# statusline.sh reads. Called detached (in the background) by statusline.sh, but
# safe to run standalone:  bash quota-refresh.sh [cache-path]
#
# Two sources are merged into the cache:
#   • `copilot_internal/user` — the undocumented endpoint the Copilot CLI itself
#     uses for its footer budget: monthly entitlement, remaining, reset date.
#   • `/users/{login}/settings/billing/premium_request/usage?year&month&day` —
#     the only endpoint with a per-DAY breakdown, used for "burned today".
#     Needs the `user` OAuth scope (gh auth refresh -h github.com -s user); when
#     it is missing we fall back to a locally tracked day baseline (see below).
#
# Field names of the internal endpoint are undocumented and may change.
# We store only quota-relevant fields (no account identifiers).
set -u
CACHE="${1:-$HOME/.copilot/quota-cache.json}"
command -v gh >/dev/null 2>&1 || exit 0

tmp="$CACHE.$$.tmp"
gh api copilot_internal/user \
  --jq '{plan: .copilot_plan, reset_utc: .quota_reset_date_utc, reset_date: .quota_reset_date, quota_snapshots: .quota_snapshots}' \
  >"$tmp" 2>/dev/null
[ -s "$tmp" ] || { rm -f "$tmp" 2>/dev/null; exit 0; }

# --- credits burned today (local calendar day) ----------------------------
login=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["lastLoggedInUser"]["login"])' \
          "$HOME/.copilot/config.json" 2>/dev/null)
[ -n "$login" ] || login=$(gh api user --jq .login 2>/dev/null)

today=$(date +%Y-%m-%d)
today_credits=""
if [ -n "$login" ]; then
  # grossAmount is in dollars at $0.01/credit, so ×100 gives credits.
  today_credits=$(gh api -X GET "/users/$login/settings/billing/premium_request/usage" \
      -f "year=$(date +%Y)" -f "month=$(date +%-m)" -f "day=$(date +%-d)" \
      --jq '[.usageItems[]? | select(.product == "Copilot") | .grossAmount] | add // 0 | . * 100' \
      2>/dev/null)
fi

# Merge: add today's burn plus a day baseline (month-to-date credits at the first
# refresh of the day) so the statusline can still derive "burned today" by
# subtraction when the billing endpoint is unavailable.
python3 - "$CACHE" "$tmp" "$today" "$today_credits" <<'PY'
import json, os, sys

cache_path, tmp_path, today, today_credits = sys.argv[1:5]

with open(tmp_path) as f:
    fresh = json.load(f)

prev = {}
if os.path.exists(cache_path):
    try:
        with open(cache_path) as f:
            prev = json.load(f)
    except Exception:
        prev = {}

snap = (fresh.get("quota_snapshots") or {}).get("premium_interactions") or {}
month_used = snap.get("credits_used")

# The baseline is captured once per day and then frozen, so the fallback
# ("month-to-date now" minus "month-to-date at day start") resets every midnight.
base = prev.get("day_baseline") or {}
if base.get("date") != today or month_used is None:
    base = {"date": today, "month_used_at_start": month_used}
fresh["day_baseline"] = base

if today_credits.strip():
    try:
        fresh["today_credits"] = round(float(today_credits), 1)
        fresh["today_credits_date"] = today
    except ValueError:
        pass

with open(tmp_path, "w") as f:
    json.dump(fresh, f)
PY

mv "$tmp" "$CACHE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
```

## File 3 — the turn marker hook

Two files in `~/.copilot/hooks/`. They exist only so the **turn** segment can know
where a turn begins: the status-line payload carries the session's running total
and nothing else, and no field in it says "a new prompt just went out".

`~/.copilot/hooks/turn-mark.sh` (`chmod +x`):

```bash
#!/usr/bin/env bash
# Copilot CLI hook (userPromptSubmitted): mark that a NEW TURN has begun.
#
# The status line wants to show what the last turn cost — the single most useful
# number when you come back to a session you left working — but the payload it
# renders from only carries the session's RUNNING total (ai_used.total_nano_aiu).
# A per-turn figure is that total minus whatever it was when the turn started,
# and nothing in the payload says where a turn starts.
#
# So this hook does the only thing it is in a position to do: drop a marker.
# It cannot record the credits itself — the hook payload has no spend in it — but
# the status line remembers the last total it rendered, and a turn begins exactly
# where that value was frozen. The next render sees the marker, promotes its own
# "last seen" figure to the turn's baseline, and deletes the marker.
#
# Written as a marker rather than a timestamp on purpose: a heuristic ("no render
# for 30s ⇒ new turn") would reset the counter in the middle of any slow tool call.
set -u
sid="$(python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("sessionId") or "")
except Exception: print("")' 2>/dev/null)"
[ -n "$sid" ] || exit 0
dir="$HOME/.copilot/turn-state"
mkdir -p "$dir" || exit 0
: > "$dir/$sid.new"
```

`~/.copilot/hooks/turn-mark.json` — registers it on `userPromptSubmitted`:

```json
{
  "version": 1,
  "hooks": {
    "userPromptSubmitted": [
      {
        "type": "command",
        "bash": "bash \"$HOME/.copilot/hooks/turn-mark.sh\"",
        "timeoutSec": 5
      }
    ]
  }
}
```

The marker is deliberately **empty**: the hook payload has no spend figure in it,
so it cannot record the baseline itself. It only says *when*; the status line
supplies the *how much*, from the total it last rendered. Skip both files and
everything else still works — the bar simply never grows a `turn` segment.

---

## File 4 — wire it into `~/.copilot/settings.json`

Merge this key into your existing `settings.json` (keep your other settings):

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.copilot/statusline.sh"
  }
}
```

---

## Manual install (if you'd rather not delegate)

```sh
# 1. Save File 1 and File 2 to ~/.copilot/, then:
chmod +x ~/.copilot/statusline.sh ~/.copilot/quota-refresh.sh

# 2. Prime the AI-Credit cache (needs `gh` logged in):
bash ~/.copilot/quota-refresh.sh

# 3. Add the statusLine block to ~/.copilot/settings.json (see File 4), and
#    drop File 3's two hook files into ~/.copilot/hooks/ for the turn segment.

# 4. Smoke-test the renderer with a fake payload:
echo '{"model":{"display_name":"claude-opus-4.8 · high · 1M context"},
       "context_window":{"current_context_tokens":54546,"displayed_context_limit":1000000}}' \
  | bash ~/.copilot/statusline.sh
```

Restart Copilot CLI (or start a new session) to see the bar.

---

## Design notes

### The bound-session microphone — `🎙️`

A black 🎙️ on a yellow (256-colour 226) badge in front of `🤖`, present only while
[Walkie Talkie](https://github.com/victorrentea/walkie-talkie) is bound to **this**
session — the same badge, for the same reason, as §0 of the Claude Code bar: in a
screen of identical terminals, the bar is the one row that says which one the
dictation goes to. The relay writes the bound tty as the first line of
`~/.walkie-talkie/bound-tty`; the script compares it with the tty of `$PPID`
(Copilot CLI itself, which holds the terminal). No file means no badge and no
fork; a binding elsewhere costs one `ps`.

### Consumption-trend arrow

`r = (aic_percent_remaining / 100) / (working_time_left / working_time_total)`
over the current billing month (period start = 1st of the reset month's previous
month; weekends contribute zero time). Bands are reciprocal-symmetric:

| ratio `r` | meaning | arrow | color |
|-----------|---------|-------|-------|
| ≥ 1.5 | far more credit than time — big surplus | `↑` | green |
| 1.15 – 1.5 | more credit than time | `↗` | green |
| 0.87 – 1.15 | on track | *(none)* | — |
| 0.67 – 0.87 | less credit than time | `↘` | yellow |
| < 0.67 | burning too fast | `↓` | red |

### Used-token color thresholds

Based on `used/limit`: **≥95% → red**, **≥65% → yellow**, else default.

### Credits in dollars

`AIC_PER_USD = 100.0` near the top of the Python block converts every credit
figure to list-price dollars. Under \$10 it keeps one decimal (`$1.1`) because a
day's burn is a small number where the tenth carries the information; at or above
\$10 it rounds to whole dollars, since nobody reads a monthly balance to the cent.
Change the constant if your plan's rate differs. Only the monthly balance still
prints the credits beside the dollars (`$197 (19694 AIC)`) — everywhere else the
second unit was noise.

### Working-days countdown

`resets in Nd Hh` counts only Mon–Fri days between now and the reset instant; the `Hh`
is the leftover hours of the partial day.

---

## Customizing

- **Colors:** edit the `CLR_*` ANSI codes near the top of the Python block.
- **Thresholds:** change `65`/`95` (token colors) or the arrow ratio bands.
- **Emojis / labels:** the `parts.append(...)` calls build each segment.
- **Not on AI-Credit billing?** The `premium_interactions` snapshot still carries
  `remaining`/`percent_remaining`; the same code renders premium-request quotas.

## Troubleshooting

- **You see raw escape codes** (`^[[38;5;...`) instead of colors → your terminal
  or CLI build isn't rendering ANSI in the status line; delete the `CLR_*` usages
  (or set them to `""`) for a plain bar.
- **AIC segment missing** → run `gh auth status`; then `bash ~/.copilot/quota-refresh.sh`
  and inspect `~/.copilot/quota-cache.json`.
- **Nothing shows at all** → confirm `settings.json` has the `statusLine` block and
  that `python3` is on PATH.

> Companion doc: `../claude/victor-claude-statusline.md` (the Claude Code original
> this Copilot port is inspired by).
