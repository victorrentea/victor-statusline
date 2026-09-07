# Victor's Claude Code Status Line

Reference for the custom status line rendered at the bottom of every Claude Code
turn. The canonical script lives at `~/.claude/statusline-command.sh` and is
wired up in `~/.claude/settings.json`; its **full source is embedded at the
bottom of this file** (so it ships with the course materials and students get the
exact status bar to then polish):

```json
"statusLine": { "type": "command", "command": "/Users/victorrentea/.claude/statusline-command.sh", "refreshInterval": 1 }
```

Claude Code pipes a JSON blob to the script's stdin on every render (once per
second, `refreshInterval: 1`); the script prints one line. This file documents
what that line means **and** the engineering lessons baked into the script.

> **Keep this in sync.** The script carries a maintenance rule in its header:
> *whenever the script changes, this markdown must be updated in the same change.*
> Treat the two as one unit — a behaviour change that isn't reflected here is a
> bug in the change, not a follow-up.

## Example

Actively working, current turn already billing (the flower is **animated**: it
blooms `·` → `✢` → `✳` → `✻` → `✽` and closes again, one frame per second, the
same spinner Claude Code draws in front of "Working…"):

```
Opus 5xh 50K/1M | ↗98% / 4h47 | ✻0.5 ⊂ $25 | ai | (+24)70% / 1d1h
```

Idle, waiting on you (note the ticking "-N" clock and no flower):

```
Opus 5xh 50K/1M | 98% / 4h47 | $0.1 -3m ⊂ $25 | ai | (+24)70% / 1d1h
```

Just after you hit Enter, before the first response has billed anything — **no
turn price at all**, only the animated flower:

```
Opus 5xh 50K/1M | 98% / 4h47 | ✻ ⊂ $25 | ai | (+24)70% / 1d1h
```

Idle long enough that the prompt cache is gone. The loss is priced either way;
what changes with the amount is whether it moves. Below $2 it just sits there:

```
Opus 5h 170K/1M | ↑87% / 1h41 | $7.8 >1h (miss=$1.6) ⊂ $10 | ai | (+15)82% / 3wd8h
```

Above $2, `220K`, `>1h` and `$2.1` **blink red** in unison, one second on, one
second off (§1.1); everything else holds still:

```
Opus 5h 220K/1M | ↑87% / 1h42 | $1.5 >1h (miss=$2.1) ⊂ $23 | ai | (+15)82% / 3wd8h
```

Five-hour quota exhausted: `quota-gate.sh` has parked this terminal. The sleep
glyph rides on the quota figure it belongs to, and the wake clock hangs off the
window countdown that is already running down to it:

```
Opus 5h 3%💤 / 4h51 → 21:15 | ai | (+15)82% / 3wd8h
```

The same gate also parks at **1% or less weekly quota**, but marks the weekly
cell instead. Its wake clock is the next hourly live quota probe, not a blind
multi-day sleep to the cached reset:

```
Opus 5h 60% / 3h22 | ai | (-6)0%💤 → Fri 17:08 / 7h
```

Five `|`-separated segments: **model/effort/context**, **5h quota + burn-rate**,
**spend**, **location**, **7-day quota**. There is **no leading emoji** on the
model segment.

**The order is by how fast each figure moves.** The model line is fixed; the 5h
window and the spend move within a single turn; the folder changes when you
`cd`; the weekly figure barely moves at all. Reading left-to-right you can stop
as soon as you have what you came for — and the most static segment is the one
that falls off the right edge first on a narrow terminal.

**`|` separates segments; `/` joins readings of the *same* window** — the 5h
pair `↗98% / 4h47`, and the weekly triple `(+24)70% / 1d1h` (pace, then
what's left, then how long the window has to run). It also buys back a couple of
columns per join versus a wordier separator.

---

## 0. The bound-session microphone — `🎙️`

A white-on-red badge in front of the model name, present only when **Walkie
Talkie is bound to this exact session**.

The relay's chip already says where the dictation goes, and it says it *beside
the cursor* — the one place Victor is not looking while an agent works, and which
macOS hides the moment he touches the keyboard. In a screen of identical
terminals that left *which of these is bound?* with no answer anywhere in the
window itself. This bar is always at the bottom of the right terminal, so it is
the receipt that cannot be missed.

**On a background, not as a bare emoji.** A lone 🎙️ is one more glyph in a row
already full of them — there and unseeable, the same failure the relay's own
selection row had once. A space either side makes it a badge: the eye finds it
without reading the row.

**Yellow means aimed here, red means talking.** Two facts the relay already keeps
apart — the chip says the first with a folder name and the second with a pulsing
dot — collapsed onto the one row that is always on screen. Bound is the state
that lasts hours, so it gets the colour that says *standing by*; the microphone
being open lasts a minute and is the one thing that must never be in doubt, so it
gets the alarm. Black on the 226, white on the 196: yellow that bright cannot
carry white text, and a badge that has to be squinted at is the failure the
background was added to fix.

The marker carries both in one line — `ttys006` or `ttys006 listening`, read with
a single `read -r _bt _bstate`. A second word rather than a second file: the
reader is a shell loop doing one builtin read, and two files would be two of them
plus a state that can be half-written.

**The tty is the only handle both sides hold**, which is §5.1's argument run
backwards. The relay binds a Terminal tab by tty and writes it to
`~/.walkie-talkie/bound-tty`; this bar resolves its own the same way the cwd
publisher does — from **`$PPID`**, since Claude Code spawns this script without a
controlling terminal of its own but keeps one itself. A tmux pane publishes the
*client's* tty, which is the outer tab and not the pty the agent is on, so it
fails to match rather than matching the wrong session; a blind-paste target has
no tty at all.

**A file, not the relay's `GET /target` route that already answers this.** The
bar re-renders every second in every open session, and an HTTP call on that beat
is exactly the per-second cost §"Making `refreshInterval: 1` affordable" exists
to avoid.

**The fast path is a file that is not there.** Nothing bound — the ordinary state
— costs one failed builtin `read` and no fork. The `ps` runs only when a binding
exists *and* this session's tty has not been resolved yet: once per session,
memoised in `~/.claude/cwd/.tty-$PPID` beside the cwd markers.

**The relay clears the marker at launch and at quit**, so a relay that was killed
rather than quit cannot leave a microphone on a row with nothing behind it. The
badge is only worth anything if it can be trusted.

## 1. Model & context — `Opus 5xh 50K/1M`

| Piece | Meaning | Source (stdin JSON) |
|-------|---------|---------------------|
| `Opus 5` | model display name (with ` context)` trimmed to `)`) | `.model.display_name` |
| `xh` | reasoning effort, abbreviated lower-case (`l`/`m`/`h`/`xh`/`max`), glued straight onto the name before any `(size)` | `.effort.level` |
| `50K` | absolute context tokens used (blue) = `used% × size` | `.context_window.used_percentage` × size |
| `/1M` | context window size | model's `(1M)` suffix, else `.context_window.context_window_size` |

- The effort letters carry **no separator**. It used to read `Opus 5/XH`, and
  that slash was a delimiter solving a problem that does not exist: the effort is
  always a trailing letter or two and no model name ends in one, so nothing was
  ever ambiguous. All it did was put a stroke of noise on the first thing the eye
  lands on — and split *one* thought ("which brain, at what setting") into two.
- **The letters are lower-case**, and that is what makes the gluing safe.
  `Opus 5XH` and especially `Opus 5M` read as part of the *name* — a model called
  5M — which is precisely the misreading a capital `M` invites on a line that
  also prints `200K/1M` two cells later. `Opus 5m` cannot be read that way: a
  lower-case tail is visibly a modifier hanging off the name instead of
  competing with it.
  `max` stays spelled out; `m` is medium, and a silent collision between the
  cheapest and the most expensive setting is the one abbreviation that must never
  happen.
- The absolute token count (`50K`) is rendered **blue** when there is nothing to
  worry about — and **blinks** when there is (§1.1).
- On the **1M window** the explicit `• N%` is **dropped** — the `used/size` pair
  (e.g. `50K/1M`) already makes the ratio obvious. On **smaller windows** the
  segment gains a trailing `• N%`, and that percentage turns **orange ≥ 65%**
  and **red ≥ 95%**.

### 1.1 The blink

The token count alternates its **foreground** between a warning hue and the
terminal's normal colour, **one second on, one second off**, in three cases, in
priority order:

| Trigger | Colour |
|---------|--------|
| the cached prefix has **expired** (idle ≥ TTL, §3.1) | red / normal |
| it is **about to expire** (idle ≥ 0.8 × TTL) | orange / normal |
| context is simply **enormous** (> 300K tokens) | red, **static** |

The first two **also blink the `-N` clock and its `miss=$…` price**, in the
same colour on the same beat, and that pairing is the entire point: the clock
says how much time the cache has left, the token count says how much that cache
is *worth*, and the price says it in money. Each alone answers a fraction of "is
sitting here about to cost me a dollar", which is why they light up together
rather than separately. The third trigger is standalone and does **not** blink —
an oversized context is a standing fact, not an event, and there is nothing to
do about it mid-turn.

Two deliberate choices:

- **Two states, not a gradient.** This replaced a six-step background ramp that
  breathed from black up to full hue and back over a 6-second cycle. It had the
  failure mode of every gradient pressed into service as an alarm: adjacent
  frames differ so little that the movement only registers *if you are already
  looking at it* — precisely the case where you did not need to be told. A hard
  on/off is unmissable in peripheral vision, which is the only place this warning
  is ever actually seen.
- **Foreground, not background.** Losing the wash gives the digits back the
  terminal's own contrast instead of white-on-dark-red, and on the off-beat the
  text is simply *normal* — fully legible half the time by construction, so the
  figure never has to be read through the alarm.
- **Only the variables blink.** In `-51m > 5m (miss=$1.7)`, the parts that
  move are `-51m` and `$1.7`. The scaffolding around them (`> 5m`, `miss=`)
  says how to read those two figures and holds still; blinking it too
  just widened the flashing block into a bar of moving text you had to wait out.

### Reporting and alarming are two different thresholds

The **price is always reported**. Every expired or expiring cache prints its
`(miss=$…)`, at any size, because that figure answers a question you may be
asking on purpose — *what did stepping away just cost me?* — and a number
withheld below an arbitrary line makes the bar useless for checking.

The **blink** is the part that is rationed: it only starts once losing the cache
would cost more than **$2** (`CLAUDE_MISS_FLOOR` to change it). So a cheap miss
sits there in plain text and a dear one starts moving:

```
… | $7.8 >1h (miss=$1.4) ⊂ $10 | …      ← states the loss, stays still
… | $7.8 >1h (miss=$2.1) ⊂ $10 | …      ← ">1h" and "$2.1" blink red
```

The alarm threshold used to be a flat 100K tokens, which is the wrong unit: what
makes a miss worth interrupting you over is the **money**, and the same 100K is
~19c of Haiku and ~$1.90 of Opus on a 1h TTL. It is the *same* figure the bar is
already printing, so the rule explains itself on screen — you see a blinking
`(miss=$2.1)` beside a still `(miss=$1.4)` and the reason is the number itself,
not a token count you would have to convert in your head.

`cache_phase()` therefore knows nothing about money — it answers a pure question
about *time*. Folding the threshold into it made the cheap case indistinguishable
from "the prefix is fine", so the clock could not report a $1.40 miss it knew
perfectly well had happened. Callers ask `cache_phase()` what the state is, then
ask `miss_big()` whether to shout about it. The **context counter** asks both,
which is why it can stay quietly blue while the clock beside it reports a
sub-threshold loss.

The one figure never printed is `$0.0`: below 5 cents it rounds to zero, and a
price of zero says less than no price at all.

Where the blink threshold actually falls, per model (idle past the TTL, whole
context) — below these the price is still printed, just calmly:

| Model | 5m TTL (×1.15) | 1h TTL (×1.90) |
|-------|----------------|----------------|
| Fable ($10/MTok) | ~174K | ~105K |
| Opus ($5) | ~348K | ~211K |
| Sonnet ($3) | ~580K | ~351K |
| Haiku ($1) | never (1M caps out at $1.15) | ~1.05M — never |

Haiku never blinking is the rule working, not a bug: a rebuilt Haiku prefix costs
less than a dollar even at a full 1M window, so there is no decision to interrupt
for — and the price is on screen anyway if you want to look. A bar that blinks
during cheap sessions is a bar you stop reading.

Implementation note: the counter is emitted into the segment as a literal
`@@CTX@@` placeholder and substituted at the very end of the script, because
whether it should sit still or blink depends on the prompt-cache TTL and the
idle age — neither known until the transcript has been parsed, a hundred lines
further down. Substituting last keeps layout in the layout block and the blink
rule next to the rest of the cache logic. The substitution is plain shell
parameter expansion, not `sed`: `$ctx_render` is full of ESC and `&` bytes that
`sed`'s replacement syntax would mangle.

---

## 1.2 Subagents in flight — `+{O5h*2,S5m}`

Glued onto the model segment while subagents are running, and absent otherwise:

```
Opus 5h 60K/1M +{O5h*2,S5m} | ↓48% / 4h44 | $0.3 -2m ⊂ $1.1 | victor-statusline | (-1)-1% / 0m
```

Two Opus-5 agents at high effort plus one Sonnet-5 at medium. Each entry is
`<model><effort>`, `*N` when a group has more than one, biggest group first.

**Why it exists.** Claude Code's own agent list under the bar names the agents
and shows their progress, but never says which model any of them got — and that
is the fact that decides what a fan-out costs and how good its answers will be.
The same `Task` lands on Opus, Sonnet, Fable or Haiku depending on the agent's
frontmatter, an explicit `model` override at the call site, or the configured
default subagent model, and none of those three is visible anywhere on screen.
A 24-way fan-out on Fable and a 24-way fan-out on Opus look identical while they
run and differ by an order of magnitude on the bill.

**Grouped, not listed.** One line per agent is a roster; the bar has room for
the *shape* of the fan-out, which is what you actually act on. `+{F5.1h*21,O5h*3}`
says "the bulk of this is Fable, with three Opus stragglers" in twelve columns.

**Where the data comes from.** Files Claude Code already writes, under
`<transcript-dir>/<session-id>/subagents/`:

| File | Carries |
|------|---------|
| `agent-<id>.meta.json` | `toolUseId`, `agentType`, the *requested* model alias |
| `agent-<id>.jsonl` | the agent's own transcript: `message.model` and `effort` |

The alias in the meta file (`"model":"opus"`) is a stand-in used only for the
seconds between spawn and the agent's first completed response — it names a
family, not a version, and it is absent entirely when the agent inherits. Once
the agent's own transcript exists it says exactly what it got
(`claude-fable-5-1`, `high`), and that supersedes the guess. Effort falls back
to *this* session's level, because that is what an agent inherits unless its own
definition overrides it.

A model with no reasoning-effort setting at all — Haiku — writes no `effort`
field, and renders bare: `+{H4.5*2,S5h}` is two Haiku 4.5 agents and one
Sonnet 5 at high. This was found by running the thing: requiring `effort`
alongside `model` when reading an agent's transcript meant every Haiku agent
failed to resolve, was never cached, and fell back to the alias — rendering as
`Hh`, which loses the version *and* claims an effort level Haiku does not have.

**Who is still running** is the only hard part, and the answer is in the parent
transcript rather than in file mtimes:

- a **synchronous** `Task` is done the moment its `toolUseId` shows up as a
  `tool_result`;
- an **async** agent is done when a task-notification carries its id in a
  `<tool-use-id>` block;
- the one `tool_result` that does **not** mean done is the *"Async agent
  launched successfully"* receipt, which lands at spawn time.

So the scan splits each transcript line on the `"tool_use_id":"` delimiter and
discounts that receipt chunk alone, instead of skipping the whole line — one
user turn can batch a synchronous result and an async launch together, and
skipping the line would lose the real result sitting next to the receipt. The
`tool_use` block that *starts* an agent carries the same id under `"id"`, never
`"tool_use_id"`, so a spawn can never read as a completion.

The mtime filter (`CLAUDE_SUB_STALE`, 900s) is only a floor against corpses: an
agent killed with Esc, or orphaned by a crash, may never get a marker, and with
no cutoff it would sit in the chip forever.

**Known limit.** An async agent *resumed* with `SendMessage` after it already
notified once counts as done — its original `toolUseId` keeps the marker it
earned at the first stop. Undoing that needs the marker's timestamp compared
against the agent file's, which is a date parse per render for one missing entry
in a chip that is an approximation by design.

**Cost.** Model and effort never change for a given agent, so they are resolved
once and cached in `/tmp/claude-statusline-agents-v1-<sid>.txt` for the rest of
the session; without that, a 24-way fan-out re-reads 24 agent transcripts every
refresh to learn something settled the first time. The directory is stat'ed in
one `stat(1)` call rather than one per agent, and the per-agent read stops after
40 lines (`nextfile`) because both facts are on the first completed response —
a long-running agent's transcript is megabytes, and none of it past the opening
entries says anything new about which model it is on. Measured on a real
24-agent session with a 1.1 MB parent transcript: **+80 ms** on a render that
otherwise costs 320 ms, and nothing at all for a session that never spawned an
agent (one `stat` on a directory that is not there).

---

## 2. Quota & burn-rate — `↗98% / 4h47`

Tracks the rolling **5-hour** rate-limit window.

| Piece | Meaning | Source |
|-------|---------|--------|
| `↗` | burn-rate indicator (see below), colored, **leading** the number | derived |
| `98%` | quota remaining = `100 − used%` | `.rate_limits.five_hour.used_percentage` |
| `4h47` | time until the window resets (`HhMM`, or `Mm` under an hour) | `.rate_limits.five_hour.resets_at` |

The `%` turns **orange < 15%** and **red < 5%**.

**There is no `left` label any more, on either figure.** The word used to trail
the pair (`98% / 4h47 left`), on the argument that one label could cover both
readings at once. It could — and it was still dead weight. Neither figure has
ever meant anything else here: a percentage that only counts down and a duration
that only counts down are both self-evidently remainders, and the word never
once resolved a real ambiguity. What it did do was cost five columns and wedge a
word between the segment and the next `|`, on the segment that changes fastest
and gets read most. Dropped in both shapes — with a countdown (`98% / 4h47`) and
without it (`98%`).

**The countdown is a duration, not a clock time.** `1h23`, not `1:23`. A colon
is how a wall clock is written, and this segment *has* a wall clock in it (the
reset hour), so `1:23` invited exactly one misreading: a time of day rather than
the time still to run. Unit letters cannot be misread that way. Under an hour it
was already `23m` and stays so — the `h` only appears when there are hours to
show — and the minutes stay zero-padded behind it (`1h05`) so the field does not
change width as the hour drains.

### Parked on 5-hour quota — `3%💤 / 4h51 → 21:15`

When `quota-gate.sh` has put this terminal to sleep because the 5-hour window is
nearly exhausted, the quota segment does **not** grow a third piece. Two glyphs
are folded into the two figures it already shows:

| Piece | Answers | Source |
|-------|---------|--------|
| `💤` glued to the `%` | *is this terminal parked on this window?* | `five_hour` in `~/.claude/quota-park/<session_id>` |
| `→ 21:15` after the countdown | *what time does it wake?* | the wake epoch from that file, as a local 24h clock |

The `💤` is unambiguous on its own (nothing else in the bar uses it), so it
doubles as the "execution is paused" indicator — there is no separate word for
"paused", because there is no other reason this glyph would be here.

**The sleep used to print its own countdown, and that was the same number
twice.** The old shape was `↓1% / 2h20 left • 💤2h22 / 23:21`. The gate sleeps
until the 5-hour window resets, so its countdown and the window countdown are
the same quantity *by construction* — thirteen columns spent restating `2h20`
with a different rounding, and two near-identical durations side by side invite
exactly the wrong question ("why do they disagree?"). What being parked actually
adds to the bar is one bit — *this terminal is not working* — plus the wall-clock
time it comes back. So the bit became a glyph on the percentage, and the clock
became a `→` hanging off the duration that was already counting down to it:
`↓1%💤 / 2h20 → 23:21`.

**`→` rather than a second `/`.** The `/` in this bar joins two readings of one
thing (quota and time, both readings of the window). The wake clock is not a
second reading of the countdown — it is where the countdown *lands*. An arrow
says that in one character, and keeps the pair from looking like the `98% /
4h47` grammar applied to two clocks.

**Nothing is lost by dropping the second countdown, including the heartbeat.**
The reason a countdown was there at all is that a moving number proves the
render loop is alive: a terminal frozen *on purpose* has to be told apart from
one that is hung, and a static `💤21:15` cannot do it. But `refreshInterval`
re-runs this script regardless of activity and the gate's `sleep` runs in a
child process, so the *window* countdown ticks down every second while the turn
is blocked. It does that job now, and it was always going to be on screen
anyway.

**The clock is what a countdown can't be: plannable without arithmetic.**
`💤45m` read at 2am still makes you do the addition before you know whether
that's worth waiting on or worth going to bed over. `21:15` is the number you
check the room against.

**It falls back to the sleep countdown if the clock can't be resolved.** `date
-r $pwake` is the only thing that can fail here, and only if `$pwake` is
malformed. In that one case the glyph carries the countdown again (`💤2h22`) —
the second duration earns its columns precisely when it is the only absolute
information available. A missing clock next to a correct countdown is a smaller
loss than a wrong clock beside it.

`$pwake` is not the bare `resets_at` from the API — `quota-gate.sh` adds a
buffer and some jitter before writing it (see its own comments), so `21:15` is
a few minutes *past* the true window reset, deliberately: better a few minutes
early back at your desk than a wake attempt that immediately 429s again.

The marker is one line, `<wake-epoch> <window>`. A legacy marker containing only
the epoch means `five_hour`, so upgrading the renderer while an old gate is
already sleeping does not move its glyph to the weekly cell.

**The arrow leads, it doesn't trail.** In a left-to-right line the glance lands
on the first glyph of a segment, so that slot goes to the part you read *without
parsing digits* — the trend — and the exact figure follows for when you actually
care. Same principle drives the weekly segment (§4).

### Burn-rate indicator

Compares how much **quota** is left against how much **time** is left in the
5-hour (18000s) window, so you can see at a glance whether you're spending
faster or slower than the clock:

- `quota_left = (100 − used%) / 100`
- `time_left  = seconds_until_reset / 18000`
- `r = quota_left / time_left`

| ratio `r` | meaning | arrow | color |
|-----------|---------|-------|-------|
| ≥ 1.5 | **much more** quota than time — big surplus | `↑` | green |
| 1.15 – 1.5 | **more** quota than time | `↗` | green |
| 0.87 – 1.15 | **on par** — spending in step with the clock | *(none)* | — |
| 0.67 – 0.87 | **less** quota than time | `↘` | orange |
| < 0.67 | **much less** — burning too fast | `↓` | red |

Bands are reciprocal-symmetric (1.5 ↔ 0.67, 1.15 ↔ 0.87) so surplus and deficit
are treated evenly. No arrow means you're on track.

### The grey `?` — an unconfirmed reading, `78%?`

`rate_limits` is a per-process cache, so a figure can be badly out of date
(*Cross-terminal quota state*, below). When no terminal on the machine has seen
the 5h numbers **change** for `CLAUDE_QUOTA_STALE_SECS` (default 900 s), the
segment drops to `78%?` in grey and **the arrow is withdrawn**.

The arrow has to be the first thing to go, and that is the whole point of the
marker. It is computed from quota-left over time-left, so a reading frozen early
in the window scores an enormous surplus and paints a confident green `↑` — the
bar's single most reassuring glyph — at exactly the moment it knows least. The
failure this fixes read `↑78% / 19m` while the account was at 100 % used:
not a wrong number politely displayed, but a wrong number **endorsed**. You
cannot have 78 % of a 5-hour budget left with 19 minutes to go unless you have
barely worked, and the bar was asserting both at once.

A stale figure is still the best one available, so it is still shown. What it
loses is the right to be believed. `< 15%` orange and `< 5%` red still apply on
top — a reading that says you are nearly out is safe to act on even when old;
one that says you have plenty is not.

**Quick mental check:** convert time-left to a percentage with
`minutes_left / 300 × 100`, then compare to the `%`. If they're within ~13% of
each other, you're on-par (blank). E.g. `4h47` = 287 min → 96% time left;
against `98%` quota that's `r ≈ 1.02` → on par (no arrow).

---

## 3. Spend — `✻0.5 ⊂ $25` / `$0.1 -3m ⊂ $25`

The spend segment shows **cost only** (no token counts). Three parts: the
**current/last turn**, a **separator that doubles as the turn-state indicator**,
then the **session total**.

| Piece | Meaning |
|-------|---------|
| `✻0.5` | cost of the **current turn** (one decimal) — the **animated flower stands in for the `$`** while it is still adding up |
| *(or)* `$0.1 -3m` | when idle: the finished turn's cost, `$` restored, + a ticking "-N" clock |
| *(or)* *nothing* | right after Enter, before this turn has billed: **no figure at all**, just the bare flower |
| `(2.7⏱)` | red — this turn **missed the prompt cache**; $2.70 of the turn's price went on rebuilding the prefix (see §3.1) |
| `⊂` | subset: the turn's spend is *contained in* the session's (see below) |
| `$25` | session total, **truncated** — one decimal under `$10` (`$0.3`), whole dollars from `$10` up, never below the turn figure |

Turn cost is shown to **one decimal**, truncated like the total: at this
granularity the second decimal was noise you never acted on, and dropping it
keeps the segment narrow. Truncated rather than rounded because the two figures
have to be cut the same way — see below.

**The total is truncated, never rounded, and its resolution follows its size.**
Truncation is the rule because the figure must not claim money that hasn't been
spent, and because it should only ever tick *upward*. The resolution shifts at
`$10`: below it one decimal, above it whole dollars, since `$25.40`'s cents are
beneath the resolution of any decision the number feeds. A flat `int()` was the
earlier rule and it broke the `⊂` relation on its own terms — a 30-cent session
rendered `✻0.3 ⊂ $0`, a subset visibly *larger* than the set containing it,
which is precisely the misreading the separator exists to prevent. The decimal
also matches the turn figure beside it, so the two are directly comparable
instead of being two different roundings of the same money. The widest form
below `$10` is `$9.9` — same five cells `int()` occupied, so nothing shifts.

**Neither figure may ever exceed the total beside it.** The containment sign
makes `turn > session` a contradiction printed on screen, and two ways of
cutting one number produce exactly that. Rounding the turn while truncating the
total renders a `$3.26` session spent in a single turn as `✻3.3 ⊂ $3.2`, so the
turn truncates too. Whole dollars above `$10` produce the same contradiction one
place up — `$12.75` spent in one turn is `$12.7 ⊂ $12` — so when the dollar
truncation would fall below the turn figure, the total keeps its decimal
(`$12.7 ⊂ $12.7`) instead. It stays truncated either way; only the *resolution*
drops back to the turn's, which is the resolution the pair needs to read as a
subset at all. That only happens when one turn is essentially the whole session
— the first turn, or a resumed one — so the wider cell is rare.

**The flower replaces the `$`, not the separator.** The currency sign is the one
cell in the segment carrying no information — you know the units — which makes it
the right cell to spend on the animation. The bloom then sits *directly on* the
number that is still growing rather than off to one side, so the figure it
qualifies can never be mistaken for the total, and nothing shifts width when it
starts or stops.

**The separator is `⊂`, in every state.** The two figures aren't siblings — one
is contained in the other, and a bullet says nothing about that while `⊂` states
it in a single cell: `$0.6 ⊂ $3` can only mean "this turn is part of that total".
Subset rather than the element-of `∈` it replaced, because the left-hand figure
is not one *member* of the total but a *portion* of it — the same kind of
quantity, a piece of the same money.

> **Token counts are no longer displayed.** The transcript is still parsed and
> deduped by `requestId` (see below), but that machinery now feeds only
> turn-state detection; `turn_tok` / `total_tok` / `abbr_tok()` are computed yet
> unused in the rendered line.

### How each number is derived

- **Session total** (`$25`) comes straight from `.cost.total_cost_usd`, which is
  authoritative and matches `/usage` "Total cost" (includes subagents). It's a
  running session total, truncated to one decimal below `$10` and to `int(cost)`
  from `$10` up. The `+1e-9` in that truncation isn't cosmetic: `0.3*10` is
  `2.9999999999999996` in binary floating point, so a bare `int()` would print
  `$0.2` for thirty cents — the same understatement the decimal was added to fix,
  one place further down.
- **Current/last-turn cost** — the transcript stores **no** per-message cost
  (`costUSD` is `null`), so it can't be read directly. It's the **delta** of the
  session total since the current turn began. A per-session state file at
  `/tmp/claude-statusline-turn-<session-id>.txt` records the cost snapshot taken
  when the latest user prompt first appeared; the turn cost is
  `current_total − snapshot`.

### The flower vs `-N` switch

**Three** states, driven by whether the agent is working **and** whether the
**current turn has actually billed yet** (`turn_cost > 0`):

- **working, nothing billed yet** (the 10–20 s between hitting Enter and the
  first response) → **the flower in place of the figure**: `✻ ⊂ $25`. The
  previous turn's price disappears the instant you press Enter.

  This is the one place where showing a number is worse than showing none. The
  turn-cost slot is the figure you glance at without reading its label, so a
  stale value there doesn't read as "the last turn cost $1.4" — it reads as
  "this is costing $1.4", and it does so for twenty seconds, every turn. An
  empty slot cannot be misread. The flower carries the only true statement
  available at that moment: counting has started, no figure yet. (The session
  total stays: it is still correct.)

  The `⊂` **stays** through this state, even with nothing on its left. Dropping
  it — the earlier rule — meant that the instant the first cost landed the
  separator appeared from nowhere and shoved the session total two cells to the
  right, so the one number on screen moved exactly when it started to matter.
  Holding every cell still costs one glyph and buys a segment that never jumps;
  and the claim is still true with the left side empty — whatever this turn ends
  up costing is contained in that total.
- **working AND turn has cost** → live figure with the flower **in the `$`'s
  place** (e.g. `✻0.5 ⊂ $25`) — it's still adding up. That cell carries no
  information anyway, so the bloom costs no width and nothing shifts when it
  starts or stops. There is
  **no `current` word**: a glyph that visibly moves already says "in progress",
  and it says it in one cell instead of eight. The frames are Claude Code's own
  spinner — `·` `✢` `✳` `✻` `✽` (U+00B7, U+2722, U+2733, U+273B, U+273D) —
  ping-ponged over a 9-step cycle keyed off `now % 9`, so the flower blooms and
  closes in sync with the "Working…" spinner above the prompt. Every glyph is
  single-cell, so the line never shifts width; `refreshInterval: 1` is what
  advances the frame, so the animation adds zero extra work per render.

  **The hue rides the same frame index — and stops at the glyph.** Each frame
  carries a colour from a five-step clay/salmon ramp (`BLOOM0`–`BLOOM4`, 256-colour
  180 → 174 → 173 → 209 → 202), so the flower opens and warms together, closes and
  cools together: one animation, not two that happen to overlap. The ramp travels
  *pale → saturated*, never dark → light, because a luminance ramp only works
  against a known background and this bar is read on a white IntelliJ terminal as
  often as on a dark one — `#ffd7af` disappears on white, `#444` on black, while
  saturation survives both. **The digits stay in the terminal's normal colour.**
  Colouring the figure too was the earlier rule and it defeated itself: the money
  is the thing you are trying to read, and a number whose hue changes every second
  is a number you keep re-reading to check whether the colour means something. It
  never did — the hue is a clock, not a verdict. The movement belongs entirely to
  the cell that carries no information; the figure holds still to be read.

  **The ninth frame is a literal `$`.** Since the flower is standing in for the
  currency sign, letting the real one surface once per cycle re-states what the
  glyph is replacing: the units flash back for a beat, and the animation stays
  honest about the slot it occupies. Single-cell like the rest, so the width
  still never moves.

  **Dropped on purpose: `∗` (U+2217).** Claude Code's spinner includes it, but
  it is a *math operator* while the rest are *Dingbats* — the font centres it on
  the math axis, so it sags below the baseline the others sit on and that one
  frame of the bloom visibly twitches. Five frames that hold still beat six that
  don't. A useful reminder that "same-looking glyph" ≠ "same vertical metrics":
  mixing Unicode blocks in an animation is how you get a wobble.
- **idle** → the finished turn's figure with its `$` back, a ticking `-N` and
  **no** flower. The minus already says it's the last turn.

  **The clock is a minus, not the word `ago`.** `-29m` says in one glyph what
  ` ago` said in four: a signed offset from now, the convention a diff or a
  timeline already uses. In a bar where every other cell is a number, a lone
  English word was the only thing asking to be *read* rather than seen — and it
  spent three cells in the one segment that also has to fit a price
  (`$7.8 -51m > 5m (miss=$2.1) ⊂ $10` is tight enough already). `>1h` keeps its
  own shape: the `>` points the same direction the minus would, and `->1h` would
  stack two symbols onto one meaning.

The just-finished turn's cost is still snapshotted as "previous turn" **before**
the baseline rolls forward (`prev_turn_cost` in the state file). It now only
surfaces in the rare *idle-but-nothing-billed* corner; the ordinary
just-hit-Enter window deliberately shows nothing instead.

## 3.1 Prompt-cache miss — the red `(2.7⏱)` on the turn price

```
Opus 5xh 200K/1M | 98% / 4h47 | $5.2(2.7⏱) ⊂ $34 | ai | (+24)70% / 1d1h
```

A red `(2.7⏱)` glued to the turn price means **this turn did not reuse the cached
prompt prefix** — it paid to build it again. Read it as a whole and its part:
**of this turn's $5.20, $2.70 was the rebuilt prefix**, and the $5.20 is in turn
part of the session's $34. While the turn is still running the flower stands in
for the leading `$` exactly as it does without a miss (`✻5.2(2.7⏱)`), so nothing
about the animation or the width changes.

**The price comes first, because the price is what the segment is for.** You look
here to find out what the turn cost; the miss is the footnote that explains part
of that figure. Writing the sum out ahead of it — `$⏱+2.7=5.2`, tried and
dropped — inverted the reading order: the eye met a small red number before the
one it came for, and had to walk an expression to arrive at the total. The
parenthetical says the same thing without ever standing between you and the
price. (An earlier attempt at the containment, the mirrored subset sign
`(⊃ $2.7 miss)`, lost for a different reason: you have to know the glyph.)

**Glued on, no space.** A parenthetical touching its number is a qualifier *of*
that number; one with a space in front of it is a separate item on the line. The
whole point is that the $2.70 is inside the $5.20.

The **red stops at the parenthesis.** `$5.2` is the ordinary turn cost and keeps
the colour it has in every other state — colouring through it would paint the
whole turn as the alarm, when the alarm is the $2.70.

**Why a glyph works here when it didn't before.** The very first version of this
marker was a bare red `!`, and it failed: `!` is an *alarm*, a mark that says
"react" without saying to what, so there was nothing to remember it by between
one sighting and the next — and a lone `!` beside a number reads as "big number"
long before it reads as "cache". That got replaced by the word `cache miss`, then
by `miss` alone (the word `cache` restated context the segment already carries —
the only thing this line can miss *is* the prompt cache). `⏱` now replaces the
word entirely, and the objection to `!` does not transfer: the stopwatch names
the **cause**, not the severity. What kills a prompt cache is a clock running
out; it is the same clock the `-N` reading two cells over is already counting;
the glyph *is* that clock.

It **trails** the figure, where a unit goes: `2.7⏱` reads as "2.7 worth of
clock" — one quantity with its kind named after it, which is precisely what it
is. Trailing also parks the two numbers you actually compare, `5.2` and `2.7`,
three cells apart instead of pushing a label between them.

The **price** is not optional. A bare `(⏱)` leaves you doing the subtraction
yourself to find out whether the miss was most of the turn or a rounding error on
it — and those two cases call for completely different reactions. It is priced
off **`$prev`** (below), the prefix that actually had to be rebuilt, *not* off
the current context: by the time the verdict renders the context has already
grown past what was cached, and charging today's size to yesterday's miss would
overstate it. The figure carries no `$` of its own (`miss_num`, not `miss_cost`)
because the price it hangs off already printed one, and both numbers are the same
money in the same units — a second currency sign four cells later would be
claiming otherwise.

Why it deserves a marker of its own: cached input is billed at **0.1×**, a cache
*write* at **1.25×**. Re-sending a 200 K-token prefix uncached is therefore
around a dollar of pure waste on Opus, and it is **completely invisible** in the
price — the turn just looks "expensive today". The label names the reason.

### How the verdict is reached (deterministic, from the API's own numbers)

Every assistant message in the transcript carries `message.usage` with the three
input buckets — `input_tokens`, `cache_read_input_tokens`,
`cache_creation_input_tokens`. Two of those are compared:

| Symbol | What it is |
|--------|------------|
| `$cr` | `cache_read_input_tokens` of the **first request of the current turn** |
| `$prev` | total prompt size (all three buckets) of the **last request before that turn** |

`$prev` is precisely the prefix that *was* sitting in the cache. If the cache
held, the next request reads essentially all of it back, so `$cr ≈ $prev`. If
the TTL lapsed, it reads back nothing and re-creates the lot.

> **miss ⇔ `$prev ≥ 5000` and `$cr < $prev / 2`**

Only the turn's **first** request is judged: it is the one that either reuses
the prefix or pays to rebuild it, and everything after it re-hits what that
request just wrote.

Comparing against `$prev` — rather than against a fixed number, or against this
request's own creation count — is what makes the rule survive contact with real
sessions. A turn that just dumped a 60 K tool result into context legitimately
*creates* 60 K on the next request while still *reading* the whole 200 K prefix;
an absolute or ratio-vs-creation test calls that a miss, the `$prev` test does
not. Measured on real transcripts the two populations don't overlap anywhere
near the cut-off: genuine misses read back **0–7 %** of `$prev`, healthy turns
**80–100 %**.

Two guards keep it from crying wolf:

- **`$prev ≥ 5000`** — nothing worth caching existed yet. This also silences the
  session's very first turn (`$prev = 0`), where the miss is unavoidable and
  therefore not information.
- **`$cr = -1`** (no request in this turn yet) — no verdict to give. *Absence of
  data must never render as a miss*; that's how a warning glyph becomes noise
  and stops being read. Note this is exactly the flower-only window above, which
  shows no price and hence no label.

Only the **main chain** is examined (`isSidechain != true`): a subagent has its
own cache and its own prefix, so its hits and misses say nothing about yours.

### The TTL is read, not assumed

The same `usage` blob states which bucket a cache write went into:

```json
"cache_creation": { "ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 17187 }
```

So the session **reports its own TTL** — no guessing, no configuration to keep
in sync. `300 s` is the fallback when nothing has been written yet.

**Which write decides is not "the last one".** A session writes into *both*
buckets: the stable prefix goes in at 1 h, and the conversational tail is
re-written every turn at 5 m. One real session put **245 K into a single 1-hour
write** and then a trickle of 1–3 K 5-minute writes — so last-write-wins reported
`300 s`, and the bar went red five minutes after you stepped away while a quarter
of a million cached tokens sat there for another hour. An alarm you cannot trust
is worse than no alarm.

The rule is therefore **by volume**: take the largest write in the session as the
yardstick, keep only writes within 4× of it, and let the last of *those* decide.
Tail deltas are ignored; a genuine mid-session switch still lands immediately,
because once the session drops to 5-minute caching the next big write goes into
the 5 m bucket and wins on its own.

That number then drives the **`-N` clock** (the price is always stated; the
blink only above **$2** — see §1.1):

| Age since the last turn | Rendering | Meaning |
|-------------------------|-----------|---------|
| `< 0.8 × TTL` | plain, `-12m` | prefix is warm — no price, nothing at stake |
| `0.8 × TTL … TTL` | orange, `-48m <= 1h (miss=$2.1)` | last chance — send now and you still pay 0.1× |
| `≥ TTL` | red, `-51m > 5m (miss=$2.1)` | prefix is gone; your next message rebuilds it at the write price |
| `≥ 1 h` | red, `>1h (miss=$2.1)` | as above, and the exact age no longer matters |

The colour **blinks** on/off in the bottom three rows only when the price clears
$2; below that the same text is rendered once, in the terminal's normal colour.

**The clock states its own verdict.** `-51m` is a number with no conclusion
attached — the reader has to remember what the TTL is and do the comparison. So
the blinking form prints the comparison itself, `-51m > 5m` or
`-48m <= 1h`, which is also the one wording that survives the TTL being 1 h
instead of 5 m without quietly changing meaning.

**Past an hour it stops counting.** `2h`, `16h` and `3d` all mean one single
thing — you are rebuilding from scratch — so they collapse into `>1h`, rather
than three buckets inviting you to compare numbers that no longer differ in
consequence. `>1h` is also its own verdict, which is why the `> TTL` comparison
is dropped in that row: `>1h > 1h` is noise. Below the hour the minutes stay
unrounded, because that is the range where a 1 h cache is still the thing being
decided about and the gap between `41m` and `58m` is the gap between "later" and
"now".

**And it prices the loss — in the orange phase too, not just past the TTL.**
`(miss=$2.1)` is the whole context re-written at the cache-**write** price
instead of read at the cache-**read** price — the spread between the two
multipliers, over `used_tokens`, at the model's own input rate (Opus $5/MTok,
Sonnet $3, Haiku $1, Fable $10). Naming the price *while the prefix is still
alive* is the entire point of the orange phase: `-4m <= 1h` is a deadline with
no stake attached, and a deadline you cannot price is one you cannot decide
about.

| TTL | write | read | spread charged on the rebuild |
|-----|-------|------|-------------------------------|
| 5 m | 1.25× | 0.1× | **1.15×** base input |
| 1 h | 2.00× | 0.1× | **1.90×** base input |

So 300 K of Opus context is **$1.7** to lose on a 5-minute cache and **$2.8** on
a 1-hour one. That inversion is the reason the figure is printed rather than left
to intuition: the longer TTL is the *safer* setting right up until you blow past
it, at which point it is the more expensive one.

The clock and the context counter share one predicate — `cache_phase()`,
returning `none` / `expiring` / `expired` — so the two can never disagree about
what state the cache is in. That predicate is also where the $2 floor lives, so
the clock, the counter and the gate are one decision made once. See §1.1 for the
blink itself.

On a 1-hour cache that reads: plain until 48 min, orange 48–60 min, red past the
hour. On a 5-minute cache: orange at 4 min, red at 5. The old hardcoded
"orange past ~5 min" is gone — it was simply wrong for a 1 h TTL, warning an hour
early, every turn.

The two signals are complements, not duplicates: the **orange clock is a
forecast** ("you are about to lose it"), the **red `(N⏱)` is a
post-mortem** ("you just did").

---

### Caveats

- Current/last-turn cost is a derived delta. If the very first render of a turn
  lands *after* the model already made an API call, that turn slightly
  undercounts (it self-corrects on the next turn).
- The `(N⏱)` marker and the TTL both need a **readable transcript**. In
  the newer per-session storage format (the cost-clock fallback branch) there is
  none, so no label is ever shown and the TTL falls back to 300 s.
- A **context compaction** legitimately invalidates the prefix and will be
  flagged as a miss. That is accurate — it did cost you the rebuild.
- The session total *includes* subagent/sidechain cost (it comes from
  `.cost.total_cost_usd`), even though the transcript token parse only sees the
  main transcript. Minor inconsistency by design.
- The window length is hardcoded to 5h (18000s); the status input only provides
  `resets_at`, not the window size.

---

## 4. Weekly quota — `(+24)70% / 1d1h`

The **last** segment, tracking the rolling **7-day** (604800s) rate-limit window.
Segment 2 answers *"can I keep going right now"*; this one answers the slower
question — *am I going to run out of week before the week runs out*. It sits at
the far end because it is the slowest-moving figure on the bar: you consult it
once in a while, not every turn.

Three readings of the one window, in the order you ask them: the **pace**, then
**what's left**, then **how long the window has to run**. The last join is a `/`,
the same separator the 5h pair uses (`98% / 4h47`) and meaning the same
thing here — one window, several readings. The first two are not joined at all:
the pace is **bracketed and glued** to the figure it qualifies, see below.

| Piece | Meaning | Source |
|-------|---------|--------|
| `(+24)` | pace: **percentage points** off a straight line, `elapsed% − used%`; bracketed and glued to the figure it qualifies (see below) | derived |
| `70%` | quota remaining this week = `100 − used%` | `.rate_limits.seven_day.used_percentage` |
| `1d1h` | **working** time until the weekly window resets (weekends excluded) | `.rate_limits.seven_day.resets_at` |

Pace **leads** the absolute figure, mirroring the 5h arrow: the signed number is
the "am I OK?" glance, the `% left` is the detail you read second.

There is **no separator** between them: the pace is **bracketed and glued** on,
`(+6)27%`, the same move [the spend cell](#3-spend--05--25) makes with
`$5.2(2.7⏱)` — a qualifier riding on the figure it qualifies rather than a cell
of its own. `+6% 27%`, two bare percentages jammed together, was never an option:
nothing signals they are different quantities, so the eye tries to relate them
and stalls. A `/` (an early rule, with an `=` before that) at least separated
them, but put them on equal footing. A spaced **`⊂`** (the rule this replaced)
got the *relation* right — the pace is a slice of what's left, six of the
twenty-seven points still in the window are slack you are ahead by — yet it
still said so across two spaces, and a separator, whatever it means, makes two
readings out of what the eye should take as one. Brackets bind tighter than any
spaced sign can, and the pair gets narrower in the one cell already carrying
three readings.

The pace also **drops its own `%`**: it is glued to a figure that already carries
the unit, and both are percentage points of the same window, so one `%` serves
the pair.

`% left` uses the same thresholds as the 5h segment: **orange < 15%**, **red < 5%**.

### The clock is the *working* week — weekends are subtracted

Everything time-related in this segment ignores Saturday and Sunday: the window
is **5 working days**, not 7 calendar days, and both the elapsed fraction and the
displayed time-left are counted in working seconds only.

Calendar time lied in **both** directions. It called you "behind" all Friday,
when the two days you supposedly still had were days you would not work — and it
flattered you on Monday morning by counting a weekend you had already skipped.
`1d1h` on a Thursday night is a number you can act on; `3d1h` is not, because two
of those days aren't yours.

Consequences worth knowing:

- Monday 00:00 the segment starts at `5d`, not `7d`.
- From **Saturday 00:00 the time-left reads `0m`** and the pace freezes for the
  rest of the weekend. That is not a bug: there is no working time left before
  the reset, so whatever quota you still hold is pure surplus and cannot run out.
- A DST shift inside the window skews the accounting by an hour. Irrelevant
  against a 5-day budget, and not worth the code to correct.

Implementation note — macOS `awk` has no `strftime`, so the weekday is derived
arithmetically: 1970-01-01 was a **Thursday**, so for local day index `D`,
`dow = (D + 4) % 7` with `0 = Sunday`, `6 = Saturday`. The UTC offset is read
from `date +%z` once per render, and one awk pass walks the interval a day at a
time, returning *both* the working seconds left and the pace.

### Pace: a signed percentage, not an arrow

`elapsed% − used%` over the working window:

| pace | meaning | color |
|------|---------|-------|
| `+N%` | consumed **less** than the working week — `N` points of slack in hand | green |
| `0%` | dead on the linear budget | — |
| `-N%` (N < 10) | running **ahead** of the working week | orange |
| `-N%` (N ≥ 10) | badly ahead — this week ends early | red |

Two decisions here, both about **reading speed**:

- **Points, not a ratio** — deliberately not the ratio-with-bands used for the
  5h arrow. Over a week a ratio is unusable at both ends: in the first hours
  `time_left ≈ 1` makes it explode, and near the reset it goes numb. The
  point-difference stays readable throughout, and it matches the arithmetic
  people actually do in their heads ("it's Thursday, I should be about 57% in").
- **A signed `%`, not a `↑`/`↓` glyph** — the pace sits immediately next to the
  "% left" figure. Rendering both in the *same unit* lets you compare them
  without a mental conversion ("28% left, but 18% behind"); a bare `↓18` beside
  a `28%` invites reading the two as different kinds of quantity. The sign
  carries the direction an arrow would have, at the same width.

The `0%` case is printed rather than blanked so the segment doesn't change width
as you cross the line.

### Time left: mixed units, not a decimal day

`1d1h`, not `1.1d`. A decimal day needs mental arithmetic before it becomes an
hour you can plan around — and the whole point of the segment is deciding what to
do *today*. A zero tail is dropped (`5d`, never `5d0h`), and below a day it
degrades to `10h`, then `44m`, then `0m` across the weekend.

### Why this segment can be trusted more than you'd expect

The weekly reading goes stale the same way the 5h one does — `rate_limits` is a
cache of *this session's* last API response — but **worse**, because a terminal
can sit idle for hours while the week keeps moving. That's exactly why it goes
through the same machine-wide merge (see *Cross-terminal quota state* below):
whichever of your terminals talked to the API most recently is the one whose
number you see.

### Parked on weekly quota — `0%💤 → Fri 17:08 / 7h`

The request gate pauses when weekly quota remaining reaches **1% or less**
(`used_percentage >= 99`). This is a separate threshold from the unchanged
5-hour rule: `CLAUDE_WEEKLY_QUOTA_MIN_PCT` defaults to `1`, while
`CLAUDE_QUOTA_MIN_PCT` still defaults to `5` and keeps its existing strict
comparison.

The weekly sleep state belongs here, not beside an otherwise healthy 5-hour
number. `💤` is therefore glued to the weekly percentage, followed immediately
by the next probe's weekday and local clock (`→ Fri 17:08`). The normal weekly
duration still describes working time until the advertised window reset, so it
stays after the probe clock. These are deliberately different facts: the arrow
says when the gate will check again; `/ 7h` says how much working time the cached
window claims remains.

A cached low weekly reading is actionable, but no longer trusted for one long
sleep. The observed counterexample was a temporary plan boost: the shared cache
still said `101%` used and reset Monday at 00:00 while Claude's Usage screen said
`0%` used in the same advertised window. `CLAUDE_WEEKLY_QUOTA_PROBE_SECS`
therefore defaults to `3600`. At that interval the parked hook calls Claude's
authenticated `/api/oauth/usage` endpoint, republishes the live seven-day value,
and releases the already queued request as soon as more quota exists. The OAuth
token is read from the same macOS Keychain item Claude Code uses; it is never
written to the probe stamp or log.

`~/.claude/quota-weekly-probe` stores the machine-wide last-attempt epoch and,
after a successful call, its live `used` and `resets_at`. Every parked terminal
uses it as the next deadline and trusts that live result for the hour; the status
line does too, so a frozen session payload cannot keep painting `-1%` after the
gate has correctly released it. The timestamp is written before the network
call: an outage does not turn many parked terminals into a tight retry loop.
PID-derived jitter still spreads terminals around that deadline.

If both windows are exhausted, the hourly weekly probe remains the wake event.
When it returns quota, the loop re-evaluates the five-hour gate and waits for its
reset too if necessary. The `604920`-second safety ceiling and `605040` hook
timeouts remain, although an individual weekly sleep is now only about an hour.

---

## 5. Location — `ai@fix-cache`

Second-to-last segment: the **folder**, plus `@branch` when the branch is not the
trunk. The folder name sits on a **colour chip** — a background hashed from its
path, one of twenty combinations, so a folder always looks the same (see
below). The `@branch` stays **teal** (256-colour 80, `#5fd7d7`) and outside
the chip — the closest match to the border Claude Code draws around the
prompt, so that half still reads as part of the same frame.

| cwd | Segment |
|-----|---------|
| not a repo | `workspace` |
| repo on `master`/`main` | `ai` |
| repo off the trunk | `ai@fix-cache` |
| detached HEAD | `ai` |
| fresh `git init`, no commits yet | `ai@fix-cache` |

- **Trunk branches are omitted**: `master`/`main` is the default state, so naming
  it trains the eye to skip the field. No `@branch` ⇒ you're on the trunk, and any
  `@something` you *do* see is worth reading.
- **`git branch --show-current`, not `rev-parse --abbrev-ref HEAD`.** The latter
  fails on an **unborn branch** — a `git init` before the first commit — which is
  exactly when you most want to be told where you are.
- **One git call per render, not two.** The bar re-renders at
  `refreshInterval: 1`, so a subprocess here costs once a second, not once a
  prompt. That is why this segment does *not* resolve worktrees, which needs two
  more `rev-parse` calls; a worktree still shows its own directory name, just
  without the `<main-repo>@<branch>/<worktree>` expansion (§6).

> **This segment is now the only place the location appears.** It used to be on
> screen twice, because a sibling hook also wrote the location into the session
> title; that hook has since been removed precisely so the title could go back to
> holding Claude Code's own per-session summaries (§6).

### The folder chip — twenty combinations, hashed from the path

The folder name sits on a background colour picked from a hash of its full path.
Same folder, same chip, in every window and after every restart: `petclinic` is
the same chip in the session you opened this morning and in the one you open
next month.

**Twenty combinations, and half of them inverted** — dark text on a pale
background alongside white text on a dark one:

```
dark bg, white text   25  61  91  126  28  30  100  130  19  88
pale bg, black text   223 194 189 224  230 195 217  186  183 252
```

Sticking to dark backgrounds, as the first version did, capped the palette at
about a dozen hues that were both legible and still distinguishable from each
other — and twelve buckets over ~20 active folders collided constantly
(measured on the real folder list: 10 collisions at 12 hues; `walkie-talkie` and
`victor-macos-addons`, the pair most often open side by side, landed on the same
orange). Opening up the pale half roughly doubles the range, and the light/dark
split is the fastest thing the eye sorts on — it lands before any hue has been
resolved. It also keeps the chip from sinking into the window: these sessions run
on Nord polar night (`#2e3440`), which is why the palette carries no mid-grey —
238 (`#444444`) was in the first draft and vanished straight into that
background, so 88 (`#870000`) took its slot.

It is still a **landmark, not an identifier**. Twenty buckets over twenty
folders still collide; the chip is what fires before you read, and the name is
right next to it for when you need to be sure.

**256-colour, not 24-bit.** Apple Terminal, where this bar spends its life, has
no truecolor: a `48;2;r;g;b` chip degrades there to no chip at all. Every value
is a cube colour, so they survive.

**The hash is computed only when you `cd`.** It costs a fork, and this bar
re-renders every second in every open session — the exact shape of load that once
made the whole machine feel slow. So it is cached in `~/.claude/cwd/.chip-$PPID`
and re-derived only when the directory actually changes; steady state is one
builtin `read` and no subprocess. The key is `$PPID` — claude's own pid: free,
stable for the life of the session, and per-session, so two windows in different
folders cannot invalidate each other's answer every render. Same key and same
reasoning as the cwd publisher below.

What is cached is the **raw checksum, not the palette index**. Taking the modulo
at render time is shell arithmetic with no fork, and it means editing
`FOLDER_CHIPS` takes effect immediately instead of leaving live sessions holding
an index that now points past the end of a shorter palette.

`cksum` and not `shasum`: the hash only has to spread paths over the palette, and
it is the cheaper fork.

**The branch stays outside the chip**, in the old teal — colouring it in would
make one folder look like a different block depending on where its HEAD is.

### …and it publishes what it found, for anything outside the process

The bar also writes the directory to `~/.claude/cwd/<ttysNNN>`. Nothing in the
status line uses it; it exists because that value is **otherwise unobtainable
from outside**, and something else on this Mac needs it.

Claude Code keeps two directories. The session's — `.workspace.current_dir`,
what this segment shows, what moves when you move — and the process's, which
stays wherever the session was launched for as long as it lives. Measured on a
live session working in `walkie-talkie`: `lsof -d cwd` on the pid still answered
`~/workspace`. So an outside observer holding the pid learns the launch
directory and nothing else. Reading `~/.claude/projects/` instead means guessing
which of several sessions sharing a launch directory a given pid belongs to,
and a confidently wrong answer is worse than none.

**Keyed by the tty, because that is the only handle both sides hold.** The
consumer here is Walkie Talkie, which binds a Terminal tab *by tty* and draws its
folder on an overlay chip. `TERM_SESSION_ID` would have been the cheaper key —
free, already in the environment — and cannot be read back: macOS shows a
process's environment only to its own descendants, so a separately launched app
sees nothing (measured: 2926 bytes for a process in the caller's ancestry, 4 for
an unrelated terminal's). Note the tty published is **`$PPID`'s, not `$$`'s** —
Claude Code spawns this script without a controlling terminal of its own, but
keeps one itself.

**The write is guarded so the steady state costs nothing.** This bar re-renders
in every open session, which is exactly the shape of load that once made the
whole machine feel slow, and resolving the tty costs a `ps`. So the guard is a
bash builtin `read` against the last value published for this session — keyed by
`$PPID`, free and stable, and *not* a single shared file, which would have
sessions in different directories invalidating each other every render. The fork
happens only when the directory actually changes.

Everything about it is best-effort and silenced: a status line that breaks over
a publishing side-effect is a status line that broke for nothing. A stale entry
is harmless too — tty numbers are reused by the next tab, so the consumer is
expected to check the directory still exists.

---

## 6. The session title — left to Claude Code

Not part of the status line, but the other half of the same display: Claude Code
draws a **session title** on the prompt box border, one line above the bar, and
lists sessions by that same value in `/resume`.

**Nothing in this repo sets it any more.** The title is Claude Code's own
generated summary — "Fixed prompt-cache detection in the status line" rather than
`ai@fix-cache`. This section exists to record *why* that is the right default,
because the obvious-looking improvement is a trap that costs you the summaries.

### There was a hook here, and removing it was the plan all along

`~/.claude/hooks/session-title.sh` used to name each session after **where** it
was — `ai`, `ai@fix-cache`, `agentic-how@embabel-demo/kind-mendeleev-f33675`,
`☢️ victorrentea` for `$HOME` — resolving linked worktrees through
`--git-common-dir` so the title named the *main* repo and the worktree instead of
a generated `kind-mendeleev-f33675` that identifies nothing.

It was deleted because **the location segment in the bar (§5) already says all of
that**, on every render rather than once a prompt. Once the bar carried the
location, the hook was buying a duplicate — and paying for it with the summaries.
The bar's version is slightly weaker (no worktree expansion, to stay at one `git`
call per second), which is the whole of what was given up.

### Why setting it at all costs you the AI title

**Setting `sessionTitle` from a hook permanently disables the built-in session
summary.** In the 2.1.221 binary the native titler is gated on there being no
custom title:

```js
let bs = Dt();                    // session id
if (!Iw(bs)) {                    // Iw = get custom title -> only if UNSET
  hZe(Po, ba).then(Jr => { ...; Uwe(bs, Jr); uca(Jr) })   // generate + save + sync
}
```

and the hook path writes into that very store (`FXe(title, "hook")`, read back by
`Iw`). The AI title is generated **once, on the first user message** — not at
session exit — so a hook that fires on `SessionStart` closes the window before it
ever opens. Titles are persisted into the transcript as `custom-title` entries
(hook/rename) and `ai-title` entries (generated); the custom one wins wherever
both exist.

There is no way to have both through `sessionTitle` — the prompt-box title, the
terminal window title, and the `/resume` label are one single value. Deleting the
hook *is* the escape hatch the previous revision of this section described. If you
want the location back in the window title without paying for it again, don't
re-add the hook: set `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` and write an OSC 0
sequence to `/dev/tty` yourself, which leaves `sessionTitle` unset and the
prompt-box/resume label Claude's own.

### And do not replace it with a summarizer

Before the location hook there was an LLM summarizer that spawned a
`claude -p --model haiku` on every prompt to guess a 5-7 word topic. It is worth
knowing why it lost, since the AI title now fills that slot for free:

- it was **wrong often enough not to be trusted**, which makes a title worse than
  no title — you read it, believe it, and it's describing the previous topic;
- it **lagged one prompt behind by construction** (the CLI needs 10-15 s to cold
  start, so it could never sit on the blocking path);
- and it answered **the question you already know the answer to**. "What am I
  working on" is in your head; "which of these nine terminals is this" is not —
  and that one is now the bar's job, at no token cost and with no network.

> Unrelated historical note, to stop the next person drawing a false conclusion:
> the `~/.claude/projects/**/*.jsonl.auto-rename` sidecar files (240 of them,
> none newer than 2026-06-11) are **not** evidence of title suppression. That was
> an older storage mechanism; the string `auto-rename` does not appear in the
> 2.1.221 binary at all. They stopped because the product changed, not because of
> any hook.

---

## Implementation tricks

The interesting engineering isn't in *what* is shown but in squeezing accurate,
per-turn numbers out of an input that only ever gives a running **session**
total, and doing it cheaply enough to re-render every second. Highlights:

### Deriving a *per-turn* cost from a session-total-only input
- `.cost.total_cost_usd` is authoritative (matches `/usage`, includes subagents)
  but is a **monotonic session total**. The transcript stores no per-message cost
  (`costUSD` is `null`), so the turn cost can't be read — it's computed as the
  **delta** of the total since the turn began, with the baseline snapshotted in a
  per-session `/tmp` state file keyed by the last user prompt's UUID.
- When a new prompt appears, the just-finished turn's cost is snapshotted as
  "previous turn" **before** rolling the baseline forward — so the gap before the
  new turn's usage lands shows the old number instead of **flashing $0.00**.
- The displayed-cost switch keys off `turn_cost > 0`, not "am I working", so
  pressing Enter keeps showing `$X.X -<age>` (never a bare flower with no
  number) until this turn's first cost actually lands.

### Token counting that doesn't over-count (still parsed, no longer shown)
- Tokens are summed from the transcript JSONL, **deduped by `requestId`** via
  `group_by`. Streaming logs the *same* `usage` object on several lines per API
  request, so a naive sum inflates by ~2–3×.
- A jq predicate isolates the **last real user prompt** — excluding sidechain,
  meta, and messages whose content is only a `tool_result` — so "this turn" starts
  at the right message. This same parse yields the `idle` flag, the last user
  UUID, and the last-assistant timestamp that drive turn-state.

### Making `refreshInterval: 1` affordable
- The `jq -s` that slurps the **entire** (often multi-MB) transcript is far too
  costly to run every second. Its one-line output is **cached against the
  transcript's mtime** (`/tmp/claude-statusline-cache-<id>.txt`); while the file
  is untouched the cache is reused, and any new message bumps the mtime and forces
  a re-parse. This is what lets the idle "-N" clock tick per-second for free.

### Layered turn-state resolution (three fallbacks)
Knowing whether the agent is *thinking* or *waiting on you* — and when the last
turn ended — is hard because the status JSON has no live signal. Resolved in
priority order:
1. **Hook state (authoritative):** a `Stop` / `UserPromptSubmit` hook
  (`~/.claude/hooks/turn-state.sh`) writes `/tmp/claude-turn-<id>.state` that
  marks boundaries reliably for *every* storage format. While `working`, the
  fallback "-N" clock is kept ticking so it keeps running through the window
  right after you hit Enter — until this turn's first cost lands.
2. **Transcript fallback:** `stop_reason != "tool_use"` + no trailing user
  message ⇒ idle; age from the last assistant `timestamp`.
3. **Cost-clock heuristic:** for Claude Code 2.1.x sessions whose `<id>.jsonl`
  path doesn't exist, turn state is inferred purely from the **cost clock** —
  cost rises while working, flat between turns. Flat ≥ `IDLE_GRACE` (3s) ⇒ idle;
  flat ≥ `NEW_TURN_GAP` (30s) ⇒ genuinely new turn (so a mid-turn tool pause
  doesn't split one turn in two).

### Cross-terminal quota state
`rate_limits` is **not a live feed** — it's a cache of the headers from *that
session's* last API response. A terminal idle for an hour keeps showing frozen
numbers, which is why two terminals openly disagree about how much quota is left.
`~/.claude/hooks/quota-state.sh` fixes this with a machine-wide `~/.claude/quota.json`
that every status line writes (~1×/sec) and reads back, for **both** windows:

- **Value order, as the tie-break.** During ordinary consumption within one
  allowance, `used` increases, and across windows `resets_at` increases — so
  comparing `(resets_at, used)` lexicographically orders frozen session payloads.
  It is not an absolute law: a plan boost can return weekly allowance inside the
  same window. The gate's hourly authenticated probe is the explicit escape hatch
  for that case.
- **…but value order alone cannot self-correct, and that was a real bug.** It is
  monotone by construction, so a reading that is *wrong but ahead* — one whose
  `resets_at` sits a few minutes past the true window boundary — can never be
  outranked by an honest one, and it pins **both** numbers (the percentage *and*
  the countdown) for every terminal on the machine for the rest of the window.
  Observed in the wild as `↑78% / 19m` while the account was actually at
  100 % used with 14 min to go — and, because `quota-gate.sh` gates on the same
  value, no terminal parked either.
- **So a reading now carries when it was seen live.** `measured_at` is *not* the
  file's write time; it is the moment some terminal watched these numbers
  **change**. Only the status line can tell: it sees the payload twice, so
  `rate_limits` differing from what that session published on the previous render
  means a new API response landed in between. Identical bytes mean a frozen cache
  re-read, which is evidence of nothing. Under-reporting freshness is the safe
  direction — it can only make the bar admit doubt it need not have.
- **Freshness outranks value.** A reading a caller just saw arrive beats a stored
  one that nobody has re-confirmed in `CLAUDE_QUOTA_STALE_SECS` (default 900 s).
  That clause is the *only* way a wrong-but-ahead value ever walks back down.
  15 min: long enough that a quiet machine doesn't flap (nobody working means
  nobody burning, so an old reading is still a correct one), short enough that a
  window can't run to its end on a number seen once at the start.
- **Weekly exhaustion is probed hourly.** The gate reads Claude Code's live Usage
  endpoint after `CLAUDE_WEEKLY_QUOTA_PROBE_SECS` (default 3600 s) and publishes
  the returned seven-day value as fresh. Because an hour exceeds the normal
  stale threshold, a real lower value replaces a cached `101%` reading even when
  `resets_at` did not change.
- **Self-healing instead of locking.** Every terminal writes unlocked, so two
  writers can interleave and lose an update — but the merge is monotone-or-fresher
  and re-runs a second later, so a lost update heals itself. A lock would cost more
  than the race does.
- **Never blanks out knowledge.** A non-numeric or absent new reading always loses
  the merge, so a terminal that has not yet seen a single header cannot wipe what
  the others already know.
- The merged value is shown **unmarked while it is fresh** — which terminal
  measured it stays bookkeeping, not worth a glyph. How *old* it is, is not: see
  the grey `?` in §2.
- `quota-state.sh read` emits `used resets_at measured_at` for the 5h window;
  `read7` emits the weekly triple. The sibling `quota-gate.sh` consumes both.
  They are parsed with `cut -d' ' -f<n>`, **not** `${x%% *}`/`${x##* }` —
  when the output grew a third field the suffix-strip form silently started
  returning `measured_at` where `resets_at` was meant. Extending an output that
  others parse positionally is exactly where a "harmless" change breaks a consumer.

### Context-aware idle warning
- The "-N" clock and the context counter are coloured against **the session's
  real prompt-cache TTL** (read off `cache_creation.ephemeral_{5m,1h}_input_tokens`,
  see §3.1) via one shared `cache_phase()` predicate: orange in the last 20 %
  before it, red once past it. That predicate is deliberately **money-blind** — it
  answers a question about time only — and a second predicate, `miss_big()`,
  decides whether the state is worth *blinking* about (uncached re-send > **$2**,
  the same figure the bar prints as `(miss=$2.1)`). Splitting them is what lets
  the clock report a cheap miss in plain text instead of having to choose between
  shouting and staying silent; gating the alarm on money rather than tokens means
  the threshold means the same thing on Haiku as on Opus, and the reason for the
  alarm is legible in the alarm itself.
- The cached-transcript file is versioned in its **name**
  (`claude-statusline-cache-v2-<id>.txt`). It's keyed on the transcript's mtime
  alone, so when the cached line gained three fields, an old five-field line
  would have been served as "valid" until the transcript next changed. Bumping
  the filename retires the whole generation at once — cheaper than teaching the
  reader to detect its own staleness.

### Cheap shell/rendering touches
- **Free animation off the refresh clock:** the "billing" flower animates
  (`·` `✢` `✳` `✻` `✽` plus a `$` beat, ping-ponged) by deriving its frame from `now % 9` — a
  wall-clock value the script already fetches — and letting `refreshInterval: 1`
  advance it. No timers, no background process, zero extra work per render. All
  five glyphs are **single cell** *and* share a baseline (see the `∗` note
  above), so the line neither shifts width nor wobbles mid-animation. Reusing
  Claude Code's own spinner glyphs is deliberate: the status line then reads as
  part of the UI rather than as a bolt-on.
- ANSI colors are built once from `printf '\033'`; thresholds recolor each field
  (context %, quota left, burn arrow, idle age) inline.
- The `/effort` suffix is spliced **around** the model's `(context)` label using
  pure shell parameter expansion (`${model%% (*}` / `${model#* (}`) — no subshell.
- Size label comes from either the model's `(1M)` suffix (sed) or is computed from
  `context_window_size` (bc), then abbreviated K/M.
- **Burn-rate arrow** (`↑↗↘↓`): awk ratio `r = quota_left_frac / time_left_frac`
  over the hardcoded 18000s window, with reciprocal-symmetric bands so surplus and
  deficit are treated evenly; no arrow when on-track; arrow colored green/orange/red.
- The whole spend segment is **suppressed** when the session total rounds to
  `$0.00`.
- **`folder@branch` is second-to-last, between spend and the weekly quota** (§5),
  painted teal (256-colour 80, `#5fd7d7`) to match the border Claude Code draws
  around the prompt and the session title it writes on that border — so the two
  read as one frame.
- **The effort level is abbreviated to its lower-case initial(s)** — `l` / `m` /
  `h` / `xh` / `max`. It is a mode you set and rarely change, so the bar only has
  to *confirm* it, and lower case keeps the suffix from being read as part of the
  model name (§1). `max` is `max` and not `m` on purpose: `m` is `medium`, and a
  silent collision between the cheapest and the most expensive setting is the one
  abbreviation that must never happen. An unrecognised level prints raw.
- **The branch is printed only when it is neither `master` nor `main`.** The
  trunk is the default state, so naming it says nothing; printing it on every
  render trains the eye to skip that part of the line — which is exactly when
  you'd miss the one time it mattered. Absence of `@branch` therefore *means*
  "on the trunk", and any `@something` you do see is worth reading.
- **The spend segment is built early but emitted last.** It is computed next to
  the prompt-cache forensics it derives from (§3.1) and appended after the
  location, so the assembly order in the script is deliberately not the reading
  order of the bar.

---

## The full script — `~/.claude/statusline-command.sh`

To reproduce this exact status line: save the script below to `~/.claude/statusline-command.sh`, make it executable (`chmod +x`), and wire it up with the `statusLine` block shown at the top of this file. It is embedded here verbatim so it ships with the course materials — this copy is a snapshot and must be re-synced whenever the canonical script changes.

```sh
#!/bin/sh
# Claude Code status line:
#   "Model/e (ctx% of SIZE) [+{subagents}] | 5h% / reset | spend | folder[@branch] | 7d quota"
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
# Abbreviated to its initial(s), in LOWER case. The effort level is a mode you
# set and then rarely change, so the bar only has to CONFIRM it, not teach it —
# and one letter buys back three or four columns on the most-read part of the
# line. Lower case because the abbreviation is glued straight onto the model
# name ("Opus 5m"): a capital there reads as part of the name — "Opus 5M" looked
# like a model called 5M, exactly the misreading a memory-size suffix invites on
# a line that also prints "200K/1M" — while a lower-case letter is visibly a
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
# Input $/MTok for the model in play, so the cache-miss figure below is this
# session's money and not a generic one. Read here, off the untouched display
# name, because $model is rewritten further down (effort suffix, size label,
# the @@CTX@@ placeholder) and by then the family is no longer reliably in it.
case "$model" in
  *Fable*|*Mythos*) in_rate=10 ;;
  *Opus*)           in_rate=5 ;;
  *Sonnet*)         in_rate=3 ;;
  *Haiku*)          in_rate=1 ;;
  *)                in_rate=5 ;;
esac

ctx=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
total=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
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
fi

# A successful authenticated weekly probe is stronger evidence than any
# session's frozen rate_limits payload. Keep its result authoritative for the
# same hour the request gate uses before probing again; this also prevents a
# restarted status line from immediately repainting a returned allowance as the
# old cached 101%-used value.
probe_record=$(sed -n '1p' "$HOME/.claude/quota-weekly-probe" 2>/dev/null)
probe_at="" probe_week="" probe_reset=""
IFS=' ' read -r probe_at probe_week probe_reset <<EOF
$probe_record
EOF
probe_secs="${CLAUDE_WEEKLY_QUOTA_PROBE_SECS:-3600}"
case "$probe_secs" in ''|*[!0-9]*|0) probe_secs=3600 ;; esac
case "$probe_at:$probe_week:$probe_reset" in
  *[!0-9.:]*|*::*|:*|*:) ;;
  *)
    probe_age=$(( $(date +%s) - probe_at ))
    if [ "$probe_age" -ge 0 ] && [ "$probe_age" -lt "$probe_secs" ]; then
      week=$probe_week
      week_reset=$probe_reset
    fi
    ;;
esac
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

# --- Blink ------------------------------------------------------------------
# Two states, one second apart (refreshInterval 1): the FOREGROUND is either the
# warning hue or the terminal's normal colour. Nothing in between.
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
  # $now is the render's wall clock; the same second gives the same phase
  # everywhere in the bar, so context and clock blink in unison.
  if [ $(( ${now:-$(date +%s)} % 2 )) -eq 0 ]; then
    printf '%s%s%s' "$_col" "$*" "$RESET"
  else
    printf '%s' "$*"
  fi
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
    # On the 1M window the "used/size" pair (e.g. 100K/1M) already makes the
    # percentage trivial to eyeball, so drop the explicit "• N%" there; keep it
    # for smaller windows where the ratio is less obvious.
    # The token count is emitted as a PLACEHOLDER, not as final text: whether it
    # should sit still in blue or breathe orange/red depends on the prompt-cache
    # TTL and on how long you have been idle, and neither is known until the
    # transcript has been parsed a hundred lines below. Substituting at the end
    # keeps this block about layout and the pulse decision in one place with the
    # other cache logic, instead of splitting the rule across the file.
    if [ "$size_label" = "1M" ]; then
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
[ -r "$HOME/.walkie-talkie/bound-tty" ] && read -r _bt _bstate < "$HOME/.walkie-talkie/bound-tty" 2>/dev/null
if [ -n "$_bt" ]; then
  _mytty=""
  _ttyf="$HOME/.claude/cwd/.tty-$PPID"
  [ -r "$_ttyf" ] && read -r _mytty < "$_ttyf" 2>/dev/null
  if [ -z "$_mytty" ]; then
    _mytty=$(ps -o tty= -p $PPID 2>/dev/null)
    _mytty=${_mytty// /}
    case "$_mytty" in
      ttys*) { mkdir -p "$HOME/.claude/cwd" && printf '%s' "$_mytty" > "$_ttyf"; } 2>/dev/null || : ;;
    esac
  fi
  if [ -n "$_mytty" ] && [ "$_bt" = "$_mytty" ]; then
    # **Yellow means aimed here, red means talking.** Two facts the relay already
    # keeps apart — the chip says the first with a folder name and the second
    # with a pulsing dot — collapsed onto the one row that is always on screen.
    # Bound is the state that lasts hours, so it gets the colour that says
    # *standing by*; the microphone being open lasts a minute and is the one
    # thing that must never be in doubt, so it gets the alarm.
    #
    # Black on the yellow, white on the red: 226 is far too bright to carry
    # white text, and a badge that has to be squinted at is the failure this
    # background was added to fix in the first place.
    if [ "$_bstate" = "listening" ]; then
      mic="${ESC}[1;97;48;5;196m 🎙️ ${RESET} "
    else
      mic="${ESC}[1;30;48;5;226m 🎙️ ${RESET} "
    fi
  fi
fi
unset _bt _bstate _mytty _ttyf

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
  case "$park_window" in five_hour|seven_day) ;; *) park_wake=""; park_window="" ;; esac
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
  ind=""
  dur=""
  until_time=""
  if [ -n "$reset" ]; then
    now=$(date +%s)
    diff=$((reset - now))
    if [ "$diff" -gt 0 ]; then
      h=$((diff / 3600))
      m=$(((diff % 3600) / 60))
      until_time=$(date -r "$reset" +%H:%M)
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
        "↑"|"↗") ind="${GREEN}${ind}${RESET}" ;;
        "↘")     ind="${ORANGE}${ind}${RESET}" ;;
        "↓")     ind="${RED}${ind}${RESET}" ;;
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
    pct_part="${GREY}${left}%?${RESET}"
  else
    pct_part="${ind}${left}%"
  fi
  # "↗98% / 1h23": quota-left and time-left are two readings of the SAME
  # window, joined with "/" rather than the "•" it replaces; "|" stays reserved
  # for segment boundaries, so the eye still parses where the segment ends.
  #
  # The word "left" used to trail the pair, on the argument that one label could
  # cover both figures. It could -- and it was still dead weight. Neither figure
  # has ever meant anything else here: a percentage that only ever counts down
  # and a duration that only ever counts down are both obviously remainders, and
  # in months of reading this bar the word never once resolved an ambiguity. It
  # was five columns and a word-shaped speed bump between the numbers and the
  # next segment, on the segment that changes fastest. Dropped in both shapes,
  # with and without a duration.
  # Parked by quota-gate.sh: this terminal is sleeping until the window resets.
  # The sleep is folded INTO the quota reading rather than parked next to it as
  # its own "• 💤2h22 / 23:21" clause, because the old shape printed the same
  # fact twice. The gate sleeps until the 5h window resets, so its countdown and
  # the window countdown are the same number by construction — "↓1% / 2h20 left
  # • 💤2h22 / 23:21" spent thirteen columns restating "2h20" with a different
  # rounding, and the two near-identical durations invited exactly the wrong
  # question ("why do they disagree?"). What sleeping actually adds is one bit —
  # this terminal is parked, not working — plus the wall-clock time it comes
  # back. So the bit becomes a 💤 glued onto the percentage, where it modifies
  # the reading it belongs to, and the wake clock becomes "→ 23:21" hanging off
  # the duration that was already counting down to it: "↓1%💤 / 2h20 → 23:21".
  # The arrow is doing what the second "/" cannot — "/" joins two readings of
  # one thing, "→" says this duration LANDS on that clock.
  #
  # The countdown is still what proves the terminal is alive rather than hung:
  # `refreshInterval` re-runs this script regardless of activity and the gate's
  # `sleep` runs in a child process, so $dur ticks down every render while the
  # turn is blocked. It is the window countdown doing that job now instead of a
  # second copy of it.
  #
  # If `date -r` cannot resolve $pwake there is no clock to land on, and the
  # sleep countdown comes back glued to the glyph ("💤2h22") rather than being
  # guessed at — the only case where the second duration earns its columns is
  # the one where it is the only absolute information available.
  sleep_mark=""
  sleep_tail=""
  if [ "$park_window" = five_hour ]; then
    pwake=$park_wake
    pnow=$park_now
    if [ -n "$pwake" ]; then
      pclock=$(date -r "$pwake" +%H:%M 2>/dev/null)
      if [ -n "$pclock" ]; then
        sleep_mark="${ORANGE}💤${RESET}"
        sleep_tail=" ${ORANGE}→ ${pclock}${RESET}"
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
        sleep_mark="${ORANGE}💤${pfmt}${RESET}"
      fi
    fi
  fi
  # The low-quota colour is painted onto the two figures themselves rather than
  # around the whole segment, because the segment is no longer one run of text:
  # the 💤 and the wake clock carry their own colour, and wrapping the lot would
  # end at their RESET and leave the tail of the line uncoloured.
  qcol=""
  if [ "$left" -lt 5 ]; then
    qcol="$RED"
  elif [ "$left" -lt 15 ]; then
    qcol="$ORANGE"
  fi
  if [ -n "$qcol" ]; then
    pct_part="${qcol}${pct_part}${RESET}"
    [ -n "$dur" ] && dur="${qcol}${dur}${RESET}"
  fi
  if [ -n "$dur" ]; then
    body="${pct_part}${sleep_mark} / ${dur}${sleep_tail}"
  else
    body="${pct_part}${sleep_mark}${sleep_tail}"
  fi
  five_str="${body}"
  out="$out | $five_str"
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
#   full 1.25x cache-WRITE price again instead of the 0.1x read price).
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
  # "-51m > 5m (miss=$1.7)" is the verdict, and it is also the one form that
  # survives the TTL being 1h instead of 5m without silently changing meaning.
  #
  # Only the two VARIABLES blink — the elapsed time and the price. The words
  # around them ("> 5m", "miss=") are fixed scaffolding that says how to
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
  # miss prints "-51m > 5m (miss=$1.4)" in plain text and stays out of the way,
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
    printf ' %s%s (miss=%s)' \
      "$(pulse "$_hue" "$_rel")" "$_cmp" "$(pulse "$_hue" "$_price")"
  else
    printf ' %s%s (miss=%s)' "$_rel" "$_cmp" "$_price"
  fi
}

# The TTL as the reader thinks of it, not in seconds.
fmt_ttl() {
  if [ "${ttl_secs:-300}" -ge 3600 ]; then echo "1h"; else echo "5m"; fi
}

# What crossing the TTL just cost, in dollars, on the ONLY question that has a
# defensible answer: the cached prefix has to be written again at the cache-WRITE
# price instead of being read at the cache-READ price, so the loss is the spread
# between the two multipliers over the whole context.
#
#   5m TTL:  write 1.25x, read 0.1x -> 1.15x base input, per token
#   1h TTL:  write 2.00x, read 0.1x -> 1.90x base input, per token
#
# The 1h cache costs nearly twice as much to lose as the 5m one, which is the
# opposite of the intuition that a longer TTL is strictly the safer setting —
# reason enough to print the number rather than leave it to be guessed at.
# Takes the prefix size in tokens, defaulting to the whole current context. The
# argument exists because the two callers price two different things: the idle
# clock is forecasting the loss of the context you are sitting on RIGHT NOW,
# while the "(N⏱)" tag is pricing a rebuild that ALREADY happened,
# whose size is the prompt that was cached at the time ($prev_prompt) — by then
# the context has grown past it, so charging today's size to yesterday's miss
# would overstate it.
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
miss_usd() {
  _mult=1.15
  [ "${ttl_secs:-300}" -ge 3600 ] && _mult=1.9
  awk -v t="${1:-${used_tokens:-0}}" -v r="${in_rate:-5}" -v m="$_mult" \
    'BEGIN{ printf "%.4f", t/1000000 * r * m }'
}
# The bare figure, no currency sign: the turn-cost segment prints its own "$"
# (or the flower standing in for it) at the head of the cell and then folds the
# miss in as a parenthetical — "$5.2(2.7⏱)" — so a second "$" inside it would
# be claiming a second unit for the same money.
miss_num() {
  awk -v c="$(miss_usd "$1")" \
    'BEGIN{ printf (c >= 10 ? "%.0f" : "%.1f"), c }'
}
miss_cost() { printf '$%s' "$(miss_num "$1")"; }
# One decimal, always TRUNCATED, never rounded — the same rule the session total
# obeys, applied to the turn figure sitting next to it. Both figures have to be
# cut the same way or the "⊂" starts lying: $3.26 of session spent entirely in
# one turn rounds the turn UP to 3.3 while the total truncates DOWN to 3.2, and
# the bar prints "✻3.3 ⊂ $3.2" — a subset larger than the set containing it.
# The +1e-9 defends against 3.2*10 = 31.999999999999996 in binary floating point.
trunc1() { awk -v v="${1:-0}" 'BEGIN{ printf "%.1f", int(v*10 + 1e-9)/10 }'; }
# Is the loss big enough to MOVE for? The gate used to be a flat 100K tokens,
# which is the wrong unit: what makes a miss worth interrupting you over is the
# MONEY, and the same 100K is ~19c of Haiku and ~$1.90 of Opus-on-a-1h-TTL.
# Testing the dollar figure the bar is about to print also makes the rule
# self-evident on screen — you see "(miss=$2.1)" blinking next to a "(miss=$1.4)"
# that does not, and the reason is the number itself, not a token count you would
# have to convert. Raise the floor if the bar still interrupts too eagerly:
#   export CLAUDE_MISS_FLOOR=5
MISS_FLOOR="${CLAUDE_MISS_FLOOR:-2}"
miss_big() {
  awk -v c="$(miss_usd "$1")" -v f="$MISS_FLOOR" 'BEGIN{ exit !(c > f) }'
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
| "\($total)\t\($turn)\t\($lu_uuid)\t\($last_ts // "")\t\(if $idle then 1 else 0 end)\t\($cr)\t\($prev)\t\($ttl)"'
  sid=$(basename "$tp" .jsonl)
  # The jq -s above slurps the ENTIRE transcript (often multi-MB) — far too
  # costly to re-run on every 1s idle refresh. Cache its single-line output and
  # reuse it while the transcript file is untouched (same mtime); any new
  # message bumps the mtime and forces a fresh parse. This keeps
  # refreshInterval=1 cheap so the idle "-N" clock can tick per-second.
  # -v2: the cached line grew three fields (cache read / previous prompt size /
  # TTL). The cache is keyed by mtime alone, so a v1 line would be served as
  # valid until the transcript next changes; the version in the name retires it.
  cache="/tmp/claude-statusline-cache-v2-${sid}.txt"
  mtime=$(stat -f %m "$tp" 2>/dev/null)
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
    ts_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$ts_clean" +%s 2>/dev/null)
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
  # from the price alone: did this turn reuse the cached prefix at 0.1x, or did
  # it rebuild it at 1.25x? A rebuilt 200K prefix is roughly a dollar of pure
  # waste, and it is invisible unless something points at it.
  #
  # Deterministic, not guessed: compare what the turn's first request READ back
  # ($turn_cache_read) with what the request before it had cached
  # ($prev_prompt). Half is the cut-off — measured misses read back ~0-7% of the
  # prefix, while healthy turns read back 80-100% even after a fat tool result,
  # so nothing real lands near the line. Two guards keep it quiet:
  #   * $prev_prompt < 5000 -> there was nothing worth caching yet (and the
  #     session's very first turn, where a miss is unavoidable, has $prev = 0);
  #   * $turn_cache_read = -1 -> the turn has issued no request yet, so there is
  #     no verdict to give. Absence of data must not read as a miss.
  case "$turn_cache_read" in ''|*[!0-9-]*) turn_cache_read=-1 ;; esac
  case "$prev_prompt" in ''|*[!0-9]*) prev_prompt=0 ;; esac
  case "$ttl_secs" in ''|*[!0-9]*|0) ttl_secs=300 ;; esac
  miss_tag=""
  if [ "$turn_cache_read" -ge 0 ] && [ "$prev_prompt" -ge 5000 ] \
     && [ "$turn_cache_read" -lt $((prev_prompt / 2)) ]; then
    # With the price attached, not just the fact: a bare "⏱" makes you do the
    # subtraction yourself to find out whether the miss was most of the turn or a
    # rounding error on it — and the two cases call for completely different
    # reactions. Priced off $prev_prompt, the prefix that actually had to be
    # rebuilt.
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
    miss_tag="${RED}($(miss_num "$prev_prompt")⏱)${RESET}"
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
  #   working, nothing billed yet (you just hit Enter) -> the animated flower in
  #     place of the figure ("✻ ⊂ $12"). The previous turn's price vanishes the
  #     instant you press Enter: for the 10-20s before the first response lands
  #     there is no current cost, and leaving the old number on screen means the
  #     one figure you look at is silently stale — you read "$1.4" and attribute
  #     it to the thing you just asked for. Better an empty slot that is honestly
  #     empty; the flower says "counting has started, no number yet".
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
    # figure at all and let the bare flower open the segment.
    if [ "$(echo "$turn_cost > 0" | bc -l)" = "1" ]; then
      turn_disp=$(trunc1 "$turn_cost")
      turn_money=$(printf '%s%s%s%s' "$bloom" "$flower" "$RESET" "$turn_disp")
    else
      turn_money=""
    fi
    turn_suffix=""
    lone="${bloom}${flower}${RESET}"
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
    # Nothing billed yet: the flower stands in for the missing figure, but the
    # "⊂" stays ("✻ ⊂ $12"). Dropping it was the earlier rule and it made the
    # segment jump: the moment the first cost landed, "⊂" appeared out of nowhere
    # and shoved the total two cells right, so the one number you were watching
    # moved exactly when it started mattering. Keeping the separator through the
    # empty state holds every cell in place, and it is still true — whatever this
    # turn ends up costing IS contained in that total, figure or no figure.
    spend_seg="${lone} ${sep} ${total_money}"
  fi
fi

if [ -n "$spend_seg" ] && [ "$(printf '%.2f' "$cost")" != "0.00" ]; then
  out="$out | $spend_seg"
fi

# --- Weekly quota, last cell of the bar: "(+6)27% / 1wd1h"
# The 5h segment answers "can I keep going right now"; this one answers the
# slower question — am I going to run out of week before the week runs out.
# Three numbers, in the order you actually ask them:
#   (+6)  pace, in percentage POINTS off a straight line: elapsed% − used%.
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
  # figure. Include the weekday so the next hourly probe remains unambiguous
  # around midnight; a bare clock is sufficient inside a five-hour window.
  if [ "$park_window" = seven_day ]; then
    week_wake=$(date -r "$park_wake" '+%a %H:%M' 2>/dev/null)
    week_sleep="${ORANGE}💤${RESET}"
    [ -n "$week_wake" ] && week_sleep="${week_sleep} ${ORANGE}→ ${week_wake}${RESET}"
    wleft_str="${wleft_str}${week_sleep}"
  fi

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
      case "$delta" in
        -*) wtxt="(-${delta#-})"
            if [ "${delta#-}" -ge 10 ]; then wcol="$RED"; else wcol="$ORANGE"; fi ;;
        0)  wtxt="(0)"; wcol="" ;;
        *)  wtxt="(+${delta})"; wcol="$GREEN" ;;
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
  # It is PARENTHESISED and GLUED to it -- "(+6)27%" -- rather than separated by
  # a spaced "⊂". Both forms said the pace belongs to the figure beside it, but
  # "⊂" said it across two spaces, which is exactly what a separator does: it
  # made two readings out of what the eye should take as one. Brackets bind
  # tighter than any spaced sign can, and they are the same move the spend cell
  # makes with "$5.2(2.7⏱)" -- a qualifier riding on the figure it qualifies,
  # not a second cell. The pair also gets narrower, in the one cell that already
  # carries three readings. The "/" before the duration stays -- the time left
  # really IS a separate reading of the window, which is what "/" means
  # everywhere else in this bar ("96% / 4h44").
  if [ -n "$wpace" ]; then
    week_seg="${wpace}${wleft_str}"
  else
    week_seg="$wleft_str"
  fi
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
loc=$(basename "$cwd")

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
    _tty=$(ps -o tty= -p $PPID 2>/dev/null)
    _tty=${_tty// /}
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
_chip_cwd=''
[ -r "$_chip_file" ] && read -r _chip_sum _chip_cwd < "$_chip_file" 2>/dev/null
if [ "$_chip_cwd" != "$cwd" ]; then
  # cksum, not shasum: the hash only has to spread paths over the palette, and
  # it is the cheaper fork. The sum is written FIRST so that `read sum cwd`
  # reassembles a path containing spaces (~/Library/Application Support/…) out
  # of the tail field.
  _chip_sum=$(printf '%s' "$cwd" | cksum 2>/dev/null | cut -d' ' -f1)
  case "$_chip_sum" in ''|*[!0-9]*) _chip_sum=0 ;; esac
  { mkdir -p "$HOME/.claude/cwd" \
      && printf '%s %s\n' "$_chip_sum" "$cwd" > "$_chip_file"; } 2>/dev/null || :
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

# The branch stays TEAL and OUTSIDE the chip. The chip frames "which folder",
# and a branch name is not part of that — putting it inside would make the same
# folder look like a different block depending on where its HEAD is.
[ -n "$branch_sfx" ] && branch_sfx="${TEAL}${branch_sfx}${RESET}"
[ -n "$loc" ] && out="$out | ${_chip}${loc}${RESET}${branch_sfx}"

# --- Weekly quota, last cell (built above, next to its arithmetic) ----------
[ -n "$week_seg" ] && out="$out | $week_seg"

# --- Subagents in flight: "+{O5h*2,S5m}" glued onto the model segment -------
# WHAT IT SAYS: how many subagents are working right now, on which brain, at
# which effort — "+{O5h*2,S5m}" is two Opus-5-high agents plus one Sonnet-5-medium.
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
#     agent-<id>.meta.json   toolUseId, agentType, the requested model alias
#     agent-<id>.jsonl       the agent's own transcript: message.model + effort
# Nothing here probes a running process; it reads what the agents leave behind.
#
# WHO IS STILL RUNNING is the only hard part, and the answer is in the PARENT
# transcript, not in mtimes: an agent is done the moment its toolUseId appears as
# a tool_result (a synchronous Task returning) or inside a <tool-use-id> block
# (the task-notification an async agent fires when it stops). The one tool_result
# that does NOT mean done is the "Async agent launched successfully" receipt,
# which lands at spawn time — so the scan splits each line on the id delimiter
# and discounts that chunk alone, rather than skipping the whole line: one user
# turn can batch a sync result and an async launch together.
# The mtime filter is only a floor against corpses — an agent killed with Esc, or
# orphaned by a crash, may never get a marker, and with no cutoff it would sit in
# the chip forever.
#
# KNOWN LIMIT: an async agent RESUMED with SendMessage after it already notified
# once counts as done, because its original toolUseId keeps the marker it earned
# at the first stop. Undoing that needs the marker's timestamp compared against
# the agent file's — a date parse per render, for one missing entry in a chip
# that is an approximation by design.
SUB_STALE="${CLAUDE_SUB_STALE:-900}"   # s of silence before an agent counts as a corpse
SUB_TAIL="${CLAUDE_SUB_TAIL:-2000000}" # bytes of parent transcript scanned for done-markers
sub_render=""
_sdir=""
[ -n "$tp" ] && _sdir="${tp%.jsonl}/subagents"
if [ -n "$_sdir" ] && [ -d "$_sdir" ] && [ -n "${sid:-}" ]; then
  # One stat(1) for the whole directory rather than one per agent: a wide
  # fan-out is exactly when this code runs, and exactly when forking twenty-odd
  # times per render would be felt.
  _now=$(date +%s)
  _fresh=""
  _stat=$(stat -f '%m %N' "$_sdir"/agent-*.jsonl 2>/dev/null)
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
    # id -> toolUseId + the model ALIAS that was requested. The alias is a
    # stand-in only: it says "opus", not which Opus, and it is missing entirely
    # when the agent inherits. It carries the chip through the seconds between
    # spawn and the agent's first completed response; after that the agent's own
    # transcript says what it actually got, and the alias is never read again.
    _meta=$(awk -v want="$_fresh" '
      BEGIN { n = split(want, a, ","); for (i = 1; i <= n; i++) if (a[i] != "") w[a[i]] = 1 }
      {
        id = FILENAME; sub(/.*\/agent-/, "", id); sub(/\.meta\.json$/, "", id)
        if (!(id in w) || (id in seen)) next
        seen[id] = 1
        t = ""; if (match($0, /"toolUseId":"[^"]*"/)) t = substr($0, RSTART + 13, RLENGTH - 14)
        m = ""; if (match($0, /"model":"[^"]*"/))     m = substr($0, RSTART + 9,  RLENGTH - 10)
        if (t != "") print id " " t " " m
      }' "$_sdir"/agent-*.meta.json 2>/dev/null)
  fi
  _running=""
  if [ -n "$_meta" ]; then
    # Through the environment, not -v: an awk -v assignment is a single line
    # and runs backslash escapes over the value, and this one is a table.
    _running=$(tail -c "$SUB_TAIL" "$tp" 2>/dev/null | _meta="$_meta" awk '
      BEGIN {
        n = split(ENVIRON["_meta"], rows, "\n")
        for (i = 1; i <= n; i++) {
          split(rows[i], f, " ")
          if (f[2] != "") { live[f[2]] = f[1]; alias[f[1]] = f[3] }
        }
      }
      {
        n = split($0, parts, /"tool_use_id":"/)
        for (i = 2; i <= n; i++) {
          p = parts[i]; q = index(p, "\""); if (q < 2) continue
          id = substr(p, 1, q - 1)
          # A launch receipt is not a return value.
          if ((id in live) && index(p, "Async agent launched successfully") == 0) delete live[id]
        }
        n = split($0, g, /<tool-use-id>/)
        for (i = 2; i <= n; i++) {
          q = index(g[i], "<"); if (q < 2) continue
          id = substr(g[i], 1, q - 1)
          if (id in live) delete live[id]
        }
      }
      END { for (t in live) print live[t] " " alias[live[t]] }')
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
        for (i = 1; i <= n; i++) s = s (s == "" ? "" : ",") ord[i] (c[ord[i]] > 1 ? "*" c[ord[i]] : "")
        printf "+{%s}", s
      }')
    [ -n "$sub_chip" ] && sub_render=" ${GREEN}${sub_chip}${RESET}"
  fi
fi
unset _sdir _stat _fresh _meta _running _known _rows _new _ac _line _id _alias _hit _mt _p _i _now
out="${out%%@@SUB@@*}${sub_render}${out#*@@SUB@@}"

# --- Resolve the context counter's placeholder, now that the cache state is known.
# Three reasons the number stops being calm blue, in priority order:
#   1. the cached prefix has EXPIRED, dearly    -> red blink
#   2. it is about to expire, dearly            -> orange blink
#   3. the context is simply enormous (>300K)   -> static red
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
      if [ "${used_tokens:-0}" -gt 300000 ] 2>/dev/null; then
        # Static red, NOT a blink: an oversized context is a standing fact, not
        # an event. The blink is reserved for the cache-TTL cases above, which
        # are time-critical and only fire while idle — letting the size rule
        # blink too meant a 380K session flashing red for the whole turn, which
        # is exactly when there is nothing you can do about it.
        ctx_render="${RED}${abs_label}${RESET}"
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
```

---

*Maintained by Victor. The live script is `~/.claude/statusline-command.sh`,
which is a symlink to the copy in this repo — they cannot drift. This file
documents it **and embeds a verbatim copy** (above), so the whole thing ships
with the repo. Keep them in lockstep — a behaviour change must update the script,
this documentation, and the embedded copy in the same change (see the rule in the
script header).*
