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
Opus 4.8/XH 50K/1M | ↗98% left / 4:47h | ✻0.5 ⊂ $25 | ai | +24% / 70% / 1d1h
```

Idle, waiting on you (note the ticking "N ago" clock and no flower):

```
Opus 4.8/XH 50K/1M | 98% left / 4:47h | $0.1 3m ago ⊂ $25 | ai | +24% / 70% / 1d1h
```

Just after you hit Enter, before the first response has billed anything — **no
turn price at all**, only the animated flower:

```
Opus 4.8/XH 50K/1M | 98% left / 4:47h | ✻ $25 | ai | +24% / 70% / 1d1h
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
pair `↗98% left / 4:47h`, and the weekly triple `+24% / 70% / 1d1h` (pace, then
what's left, then how long the window has to run). It also buys back a couple of
columns per join versus a wordier separator.

---

## 1. Model & context — `Opus 4.8/XH 50K/1M`

| Piece | Meaning | Source (stdin JSON) |
|-------|---------|---------------------|
| `Opus 4.8` | model display name (with ` context)` trimmed to `)`) | `.model.display_name` |
| `/XH` | reasoning effort, abbreviated (`L`/`M`/`H`/`XH`/`MAX`), spliced in before any `(size)` | `.effort.level` |
| `50K` | absolute context tokens used (blue) = `used% × size` | `.context_window.used_percentage` × size |
| `/1M` | context window size | model's `(1M)` suffix, else `.context_window.context_window_size` |

- The absolute token count (`50K`) is rendered **blue** when there is nothing to
  worry about — and **pulses** when there is (§1.1).
- On the **1M window** the explicit `• N%` is **dropped** — the `used/size` pair
  (e.g. `50K/1M`) already makes the ratio obvious. On **smaller windows** the
  segment gains a trailing `• N%`, and that percentage turns **orange ≥ 65%**
  and **red ≥ 95%**.

### 1.1 The pulse

The token count breathes a coloured background — **black** → full hue → black
over a **6-second cycle**, one frame per render — in three cases, in priority
order:

| Trigger | Colour |
|---------|--------|
| the cached prefix has **expired** (idle ≥ TTL, §3.1) | red |
| it is **about to expire** (idle ≥ 0.8 × TTL) | orange |
| context is simply **enormous** (> 300K tokens) | red |

The first two **also pulse the `N ago` clock**, in the same colour on the same
beat, and that pairing is the entire point: the clock says how much time the
cache has left, the token count says how much that cache is *worth*. Either one
alone answers half of "is sitting here about to cost me a dollar", which is why
they light up together rather than separately. The third is standalone — an
oversized context is expensive to carry cached or not, and it means compaction
is coming.

Two deliberate choices:

- **Slow, and 1 fps is the whole budget.** A fast blink is an alarm, and an alarm
  in a bar you stare at all day is something you learn to tune out within a day.
  Something that *breathes* at the edge of vision keeps registering as movement
  without seizing the focus a strobe demands — and movement registers at one
  frame per second as well as at ten, so the render interval is the frame rate
  and nothing is spent chasing smoothness. Six steps means no frame is far from
  its neighbour, so it reads as a fade rather than a flicker.
- **One hue, from black.** Both ramps start at 16 (true black) and stay on a
  single hue: `16 52 88 124 88 52` for red, `16 94 130 166 130 94` for amber.
  The earlier ramps opened on 52/58, and 58 in particular is a dark olive that
  reads as **green** on most terminal themes — so a warning wash spent two of
  its six frames wearing a success colour. A pulse whose colour changes meaning
  mid-cycle communicates nothing.
- **Background, not foreground.** The thing being flagged is a **number you
  still have to read**. Recolouring the glyphs fights legibility exactly when
  you most need the digits; a wash behind them leaves them intact. Bright white
  is pinned on top so contrast holds across the whole ramp.

Both pulses are silent below **100K** tokens — there the rebuild is too cheap to
interrupt anyone over, and a bar that pulses during trivial sessions is a bar
you stop reading.

Implementation note: the counter is emitted into the segment as a literal
`@@CTX@@` placeholder and substituted at the very end of the script, because
whether it should sit still or pulse depends on the prompt-cache TTL and the
idle age — neither known until the transcript has been parsed, a hundred lines
further down. Substituting last keeps layout in the layout block and the pulse
rule next to the rest of the cache logic. The substitution is plain shell
parameter expansion, not `sed`: `$ctx_render` is full of ESC and `&` bytes that
`sed`'s replacement syntax would mangle.

---

## 2. Quota & burn-rate — `↗98% left / 4:47h`

Tracks the rolling **5-hour** rate-limit window.

| Piece | Meaning | Source |
|-------|---------|--------|
| `↗` | burn-rate indicator (see below), colored, **leading** the number | derived |
| `98%` | quota remaining = `100 − used%` | `.rate_limits.five_hour.used_percentage` |
| `left / 4:47h` | time until the window resets (`H:MMh`, or `Mm` under an hour) | `.rate_limits.five_hour.resets_at` |

The `% left` turns **orange < 15%** and **red < 5%**.

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
failure this fixes read `↑78% left / 19m` while the account was at 100 % used:
not a wrong number politely displayed, but a wrong number **endorsed**. You
cannot have 78 % of a 5-hour budget left with 19 minutes to go unless you have
barely worked, and the bar was asserting both at once.

A stale figure is still the best one available, so it is still shown. What it
loses is the right to be believed. `< 15%` orange and `< 5%` red still apply on
top — a reading that says you are nearly out is safe to act on even when old;
one that says you have plenty is not.

**Quick mental check:** convert time-left to a percentage with
`minutes_left / 300 × 100`, then compare to `% left`. If they're within ~13% of
each other, you're on-par (blank). E.g. `4:47h` = 287 min → 96% time left;
against `98%` quota that's `r ≈ 1.02` → on par (no arrow).

---

## 3. Spend — `✻0.5 ⊂ $25` / `$0.1 3m ago ⊂ $25`

The spend segment shows **cost only** (no token counts). Three parts: the
**current/last turn**, a **separator that doubles as the turn-state indicator**,
then the **session total**.

| Piece | Meaning |
|-------|---------|
| `✻0.5` | cost of the **current turn** (one decimal) — the **animated flower stands in for the `$`** while it is still adding up |
| *(or)* `$0.1 3m ago` | when idle: the finished turn's cost, `$` restored, + a ticking "N ago" clock |
| *(or)* *nothing* | right after Enter, before this turn has billed: **no figure at all**, just the bare flower |
| `(cache miss)` | red — this turn **missed the prompt cache** (see §3.1) |
| `⊂` | subset: the turn's spend is *contained in* the session's (see below) |
| `$25` | session total, **truncated** — one decimal under `$10` (`$0.3`), whole dollars from `$10` up |

Turn cost is rounded to **one decimal**: at this granularity the second decimal
was noise you never acted on, and dropping it keeps the segment narrow.

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

### The flower vs `N ago` switch

**Three** states, driven by whether the agent is working **and** whether the
**current turn has actually billed yet** (`turn_cost > 0`):

- **working, nothing billed yet** (the 10–20 s between hitting Enter and the
  first response) → **the flower alone**: `✻ $25`. The previous turn's price
  disappears the instant you press Enter.

  This is the one place where showing a number is worse than showing none. The
  turn-cost slot is the figure you glance at without reading its label, so a
  stale value there doesn't read as "the last turn cost $1.4" — it reads as
  "this is costing $1.4", and it does so for twenty seconds, every turn. An
  empty slot cannot be misread. The flower carries the only true statement
  available at that moment: counting has started, no figure yet. (The session
  total stays: it is still correct.)

  Note the flower **stops being a separator** here and simply opens the segment
  — there are no longer two numbers for it to sit between.
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
- **idle** → the finished turn's figure with its `$` back, a ticking `N ago` and
  **no** flower. The "ago" already says it's the last turn.

The just-finished turn's cost is still snapshotted as "previous turn" **before**
the baseline rolls forward (`prev_turn_cost` in the state file). It now only
surfaces in the rare *idle-but-nothing-billed* corner; the ordinary
just-hit-Enter window deliberately shows nothing instead.

## 3.1 Prompt-cache miss — the red `(cache miss)`

```
Opus 4.8/XH 200K/1M | 98% left / 4:47h | ✻1.2 (cache miss) ⊂ $30 | ai | +24% / 70% / 1d1h
```

A red `(cache miss)` right after the turn price means **this turn did not reuse
the cached prompt prefix** — it paid to build it again.

It used to be a bare red `!`, and that failed for a reason worth recording: the
marker fires rarely enough that by the time you see one you no longer remember
what it meant, and a lone `!` next to a number reads as "big number" long before
it reads as "cache". A label that costs eleven columns a handful of times a day
is cheaper than a glyph you have to go look up.

Why it deserves a glyph of its own: cached input is billed at **0.1×**, a cache
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

That number then drives the **`N ago` clock's colour** (still only when context
≥ 100 K, where a rebuild actually costs something):

| Age since the last turn | Rendering | Meaning |
|-------------------------|-----------|---------|
| `< 0.8 × TTL` | plain | prefix is warm |
| `0.8 × TTL … TTL` | **orange pulse**, `4m ago <= 5m` | last chance — send now and you still pay 0.1× |
| `≥ TTL` | **red pulse**, `51m ago > 5m (miss=$1.7)` | prefix is gone; your next message rebuilds it at the write price |

**The clock states its own verdict.** `51m ago` is a number with no conclusion
attached — the reader has to remember what the TTL is and do the comparison. So
the pulsing form prints the comparison itself, `51m ago > 5m` or `4m ago <= 5m`,
which is also the one wording that survives the TTL being 1 h instead of 5 m
without quietly changing meaning. (Minutes run to **two** hours rather than one
for the same reason: rounding 65 min to `1h` next to a 1-hour TTL renders the
nonsense `1h ago > 1h`.)

**And past the TTL it prices the loss.** `(miss=$1.7)` is the whole context
re-written at the cache-**write** price instead of read at the cache-**read**
price — the spread between the two multipliers, over `used_tokens`, at the
model's own input rate (Opus $5/MTok, Sonnet $3, Haiku $1, Fable $10):

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
what state the cache is in. See §1.1 for the pulse itself.

On a 1-hour cache that reads: plain until 48 min, orange 48–60 min, red past the
hour. On a 5-minute cache: orange at 4 min, red at 5. The old hardcoded
"orange past ~5 min" is gone — it was simply wrong for a 1 h TTL, warning an hour
early, every turn.

The two signals are complements, not duplicates: the **orange clock is a
forecast** ("you are about to lose it"), the **red `(cache miss)` is a
post-mortem** ("you just did").

---

### Caveats

- Current/last-turn cost is a derived delta. If the very first render of a turn
  lands *after* the model already made an API call, that turn slightly
  undercounts (it self-corrects on the next turn).
- The `(cache miss)` label and the TTL both need a **readable transcript**. In
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

## 4. Weekly quota — `+24% / 70% / 1d1h`

The **last** segment, tracking the rolling **7-day** (604800s) rate-limit window.
Segment 2 answers *"can I keep going right now"*; this one answers the slower
question — *am I going to run out of week before the week runs out*. It sits at
the far end because it is the slowest-moving figure on the bar: you consult it
once in a while, not every turn.

Three readings of the one window, `/`-separated in the order you ask them: the
**pace**, then **what's left**, then **how long the window has to run**. `/` is
the same separator the 5h pair uses (`98% left / 4:47h`) and means the same
thing here — one window, several readings. It replaced an `=`, which invited
being read as arithmetic that doesn't hold.

| Piece | Meaning | Source |
|-------|---------|--------|
| `+24%` | pace: **percentage points** off a straight line, `elapsed% − used%` | derived |
| `/` | separator: three readings of one window (see below) | — |
| `70%` | quota remaining this week = `100 − used%` | `.rate_limits.seven_day.used_percentage` |
| `1d1h` | **working** time until the weekly window resets (weekends excluded) | `.rate_limits.seven_day.resets_at` |

Pace **leads** the absolute figure, mirroring the 5h arrow: the signed number is
the "am I OK?" glance, the `% left` is the detail you read second.

The `=` between them is **punctuation, not arithmetic**. Without it, `-19% 27%`
is two bare percentages jammed together with nothing signalling they're different
quantities — the eye tries to relate them and stalls. The `=` makes the pair scan
as a single statement ("19% behind, which leaves 27%") for the price of one cell.
A worked example of the general rule: when two adjacent numbers share a unit,
spend a character telling the reader they don't share a *meaning*.

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

---

## 5. Location — `ai@fix-cache`

Second-to-last segment: the **folder**, plus `@branch` when the branch is not the
trunk. Painted **teal** (256-colour 80, `#5fd7d7`) — the closest match to the
border Claude Code draws around the prompt, so the folder still reads as part of
that frame even though it sits a line below it.

| cwd | Segment |
|-----|---------|
| not a repo | `workspace` |
| repo on `master`/`main` | `ai` |
| repo off the trunk | `ai@fix-cache` |
| detached HEAD | `ai` |
| fresh `git init`, no commits yet | `ai@fix-cache` |

- **Trunk branches are omitted**, same rule as the title (§6): `master`/`main` is
  the default state, so naming it trains the eye to skip the field. No `@branch`
  ⇒ you're on the trunk, and any `@something` you *do* see is worth reading.
- **`git branch --show-current`, not `rev-parse --abbrev-ref HEAD`.** The latter
  fails on an **unborn branch** — a `git init` before the first commit — which is
  exactly when you most want to be told where you are.
- **One git call per render, not two.** The bar re-renders at
  `refreshInterval: 1`, so a subprocess here costs once a second, not once a
  prompt. That is why this segment does *not* do the title's worktree resolution
  (§6), which needs two more `rev-parse` calls; a worktree still shows its own
  directory name, just without the `<main-repo>@<branch>/<worktree>` expansion.

> **This currently duplicates the session title (§6)**, which also carries the
> location. That is deliberate but temporary: it is the precondition for freeing
> the title to hold Claude Code's own per-session names, which it only generates
> when no custom title is set. Until `session-title.sh` stops emitting
> `sessionTitle`, the location is on screen twice.

---

## 6. The session title — `ai@fix-cache/kind-mendeleev-f33675`

Not part of the status line, but the other half of the same display: Claude Code
draws a **session title** on the prompt box border, one line above the bar. It is
set by a sibling hook, `~/.claude/hooks/session-title.sh`.

It names **where the session is**, never what it is about:

| cwd | Title |
|-----|-------|
| repo on the trunk | `ai` |
| repo off the trunk | `ai@fix-cache` |
| inside a linked git worktree | `agentic-how@embabel-demo/kind-mendeleev-f33675` |
| `$HOME` | `☢️ victorrentea` |

- **Trunk branches are omitted.** `master`/`main` is the default state, so naming
  it says nothing and trains the eye to skip the field — which is exactly when
  you'd miss the one time it said something else. No branch shown ⇒ you're on the
  trunk. (Same rule the location segment in the bar uses — §5.)
- **A worktree shows both repo and worktree.** A linked worktree's git-dir is
  `<main-repo>/.git/worktrees/<name>`, while `--git-common-dir` always points at
  the main repo. That pair lets the title say *which repo* **and** *which
  worktree* — otherwise you get a generated name like `kind-mendeleev-f33675`,
  which identifies nothing you know.
- Wired on **SessionStart** (a fresh terminal is named before the first prompt)
  **and UserPromptSubmit** (so it follows a `cd` or a branch switch mid-session).

### Why location and not a summary

This replaced an LLM summarizer that spawned a `claude -p --model haiku` on every
prompt to guess a 5-7 word topic, cached it, and rendered `folder --- <summary>`.
It was retired because:

- it was **wrong often enough not to be trusted**, which makes a title worse than
  no title — you read it, believe it, and it's describing the previous topic;
- it **lagged one prompt behind by construction** (the CLI needs 10-15 s to cold
  start, so it could never sit on the blocking path);
- and it answered **the question you already know the answer to**. "What am I
  working on" is in your head. "Which of these nine terminals is this, and am I
  in the worktree or the real repo?" is the thing you cannot tell at a glance and
  the thing that gets you burned. Location is also always correct, costs no
  tokens, and needs no network.

### The trade-off: this suppresses Claude Code's own AI title

**Setting `sessionTitle` from a hook permanently disables the built-in session
summary**, and that same value is what `/resume` lists sessions by. So the
resume picker now shows `ai`, `ai@fix-cache`, … instead of "Fixed prompt-cache
detection in the status line".

This is not a guess. In the 2.1.221 binary the native titler is gated on there
being no custom title:

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
terminal window title, and the `/resume` label are one single value. If the
`/resume` summaries are ever worth more than the folder name, the escape hatch is
to stop emitting `sessionTitle` entirely, set `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`,
and write the folder into the terminal's window title directly with an OSC 0
sequence to `/dev/tty` — the window title bar then carries the location and the
prompt-box/resume label goes back to being Claude's own summary.

> Unrelated historical note, to stop the next person drawing a false conclusion:
> the `~/.claude/projects/**/*.jsonl.auto-rename` sidecar files (240 of them,
> none newer than 2026-06-11) are **not** evidence of this suppression. That was
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
  pressing Enter keeps showing `$X.X <age> ago` (never a bare flower with no
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
  a re-parse. This is what lets the idle "N ago" clock tick per-second for free.

### Layered turn-state resolution (three fallbacks)
Knowing whether the agent is *thinking* or *waiting on you* — and when the last
turn ended — is hard because the status JSON has no live signal. Resolved in
priority order:
1. **Hook state (authoritative):** a `Stop` / `UserPromptSubmit` hook
  (`~/.claude/hooks/turn-state.sh`) writes `/tmp/claude-turn-<id>.state` that
  marks boundaries reliably for *every* storage format. While `working`, the
  fallback "N ago" clock is kept ticking so it keeps running through the window
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

- **Value order, as the tie-break.** Within a window `used` only ever *increases*
  (quota is consumed, never returned), and across windows `resets_at` increases —
  so comparing `(resets_at, used)` lexicographically *is* a total "which reading is
  newer" order for any two readings of the same account state.
- **…but value order alone cannot self-correct, and that was a real bug.** It is
  monotone by construction, so a reading that is *wrong but ahead* — one whose
  `resets_at` sits a few minutes past the true window boundary — can never be
  outranked by an honest one, and it pins **both** numbers (the percentage *and*
  the countdown) for every terminal on the machine for the rest of the window.
  Observed in the wild as `↑78% left / 19m` while the account was actually at
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
- `quota-state.sh read` emits `used resets_at measured_at` for the 5h window (the
  sibling `quota-gate.sh` consumes all three); the weekly triple is a separate
  `read7`. It is parsed with `cut -d' ' -f<n>`, **not** `${x%% *}`/`${x##* }` —
  when the output grew a third field the suffix-strip form silently started
  returning `measured_at` where `resets_at` was meant. Extending an output that
  others parse positionally is exactly where a "harmless" change breaks a consumer.

### Context-aware idle warning
- The "N ago" clock and the context counter are coloured against **the session's
  real prompt-cache TTL** (read off `cache_creation.ephemeral_{5m,1h}_input_tokens`,
  see §3.1) via one shared `cache_phase()` predicate: an orange pulse in the last
  20 % before it, red once past it — and *only* when context ≥ 100K tokens,
  because only then is the uncached re-send of your next message expensive enough
  to be worth flagging.
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
- **The effort level is abbreviated to its initial(s)** — `L` / `M` / `H` / `XH`
  / `MAX`. It is a mode you set and rarely change, so the bar only has to
  *confirm* it. `max` is `MAX` and not `M` on purpose: `M` is `medium`, and a
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
#   "Model/E (ctx% of SIZE) | 5h% left | spend | folder[@branch] | 7d quota"
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
# Abbreviated to its initial(s). The effort level is a mode you set and then
# rarely change, so the bar only has to CONFIRM it, not teach it — and one
# letter buys back three or four columns on the most-read part of the line.
# "max" is MAX and not M, deliberately: M is medium, and a silent collision
# between the cheapest and the most expensive setting is the one abbreviation
# that must never happen. An unrecognised level prints raw rather than being
# guessed at — a new level is worth reading in full the first time you meet it.
case "$effort" in
  low)    effort=L ;;
  medium) effort=M ;;
  high)   effort=H ;;
  xhigh)  effort=XH ;;
  max)    effort=MAX ;;
esac
if [ -n "$effort" ]; then
  case "$model" in
    *" ("*) model="${model%% (*}/${effort} (${model#* (}" ;;
    *)      model="${model}/${effort}" ;;
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

# --- Slow pulse -------------------------------------------------------------
# Breathes a background from BLACK up to full hue and back, one frame per render
# (refreshInterval 1 => 1 fps, a 6-second cycle). One frame a second is the whole
# budget: the point is that something in the corner of your eye keeps moving, and
# movement registers at 1fps just as well as at 10 — while a fast blink is an
# alarm you learn to tune out within a day. Six steps also means no frame is far
# from its neighbour, so it reads as a fade rather than a strobe.
#
# Both ramps start at 16 (true black) and stay on ONE hue the whole way up. The
# earlier ramps opened on 52/58 — a dark red and, worse, a dark olive that reads
# as green on most terminal themes, so the "warning" wash spent two of its six
# frames looking like a success colour. A pulse whose colour changes meaning
# mid-cycle communicates nothing; black->red is a single unambiguous statement,
# and black->amber likewise.
#
# Background rather than foreground because the thing being flagged is a NUMBER
# you still have to read: recolouring the glyphs fights legibility exactly when
# you most need the digits, whereas a wash behind them leaves them intact.
# Bright white text is pinned on top so contrast holds at every step of the ramp.
#
#   pulse red|orange <text>
RED_RAMP="16 52 88 124 88 52"
ORANGE_RAMP="16 94 130 166 130 94"
pulse() {
  _hue=$1; shift
  case "$_hue" in
    red) _ramp=$RED_RAMP ;;
    *)   _ramp=$ORANGE_RAMP ;;
  esac
  # $now is the render's wall clock; the same second gives the same frame
  # everywhere in the bar, so context and clock breathe in unison.
  _frame=$(( ${now:-$(date +%s)} % 6 + 1 ))
  _bg=$(echo "$_ramp" | cut -d' ' -f"$_frame")
  printf '%s[48;5;%sm%s[38;5;231m%s%s' "$ESC" "$_bg" "$ESC" "$*" "$RESET"
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

out="$model"

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
      if [ "$h" -gt 0 ]; then
        dur=$(printf '%d:%02dh' "$h" "$m")
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
  # Arrow LEADS the number ("↗98% left"), it does not trail it. The arrow is the
  # part you read at a glance without parsing digits, and in a left-to-right line
  # the glance lands on the first glyph of the segment — so the trend gets that
  # slot and the exact figure follows for when you actually care.
  #
  # Unless nobody has re-confirmed the reading in $STALE_5H, in which case both
  # of those glyphs are withdrawn and a grey "?" takes their place. The arrow is
  # the part that has to go FIRST: it is computed from quota-left over
  # time-left, so a reading frozen early in the window scores a huge surplus and
  # paints a confident green "↑" — the bar's single most reassuring glyph — at
  # precisely the moment it knows least. "↑78% left / 19m" was that failure: not
  # a wrong number politely displayed, but a wrong number ENDORSED. A stale
  # figure is still the best one available and is still shown; what it loses is
  # the right to be believed.
  if [ -n "$five_age" ] && [ "$five_age" -gt "$STALE_5H" ] 2>/dev/null; then
    pct_part="${GREY}${left}%?${RESET}"
  else
    pct_part="${ind}${left}%"
  fi
  # "↗98% left / 4:47h": quota-left and time-left are two readings of the SAME
  # window, joined with "/" rather than the "•" it replaces; "|" stays reserved
  # for segment boundaries, so the eye still parses where the segment ends.
  if [ -n "$dur" ]; then
    body="${pct_part} left / ${dur}"
  else
    body="${pct_part} left"
  fi
  if [ "$left" -lt 5 ]; then
    body="${RED}${body}${RESET}"
  elif [ "$left" -lt 15 ]; then
    body="${ORANGE}${body}${RESET}"
  fi
  # Parked by quota-gate.sh: this terminal is sleeping until the window resets.
  # Show the wake time so a frozen-looking terminal is legibly frozen on purpose.
  park="$HOME/.claude/quota-park/$session_id"
  if [ -n "$session_id" ] && [ -f "$park" ]; then
    pwake=$(cat "$park" 2>/dev/null)
    if [ -n "$pwake" ] && [ "$pwake" -gt "$(date +%s)" ] 2>/dev/null; then
      body="${body} • ${ORANGE}💤$(date -r "$pwake" +%H:%M)${RESET}"
    fi
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

# Format seconds-since-the-turn-ended as " <rel> ago" (leading space included):
#   <60s -> "Ns" (ticks 1s,2s,3s...), <60m -> "Nm", <24h -> "Nh", else "Nd".
# Colored against the ACTUAL prompt-cache TTL of this session ($ttl_secs, read
# off the API usage — 300s or 3600s, see below), not a hardcoded 5 minutes:
#   orange in the last 20% before the TTL (spend it or lose it),
#   red once the TTL has passed (the prefix is gone; your next message pays the
#   full 1.25x cache-WRITE price again instead of the 0.1x read price).
# Concretely, on a 5-minute TTL: "4m ago" is >= 240s and still under 300s, so it
# breathes ORANGE — the prefix is alive and you have about a minute to use it.
# "51m ago" is far past 300s, so it breathes RED — that cache is already gone.
# On a 1-hour TTL the same two readings say the opposite thing: "4m ago" is not
# coloured at all, and "51m ago" is the orange one (48m is 80% of 60m) with red
# only from 60m on. Which is exactly why the TTL is detected rather than assumed
# — the same "51m ago" is a shrug or an emergency depending on it.
# Only when the context is big (>=100K tokens) — below that the re-send isn't
# expensive enough to warn about. Uses globals $used_tokens/$ttl_secs/colors.
# Echoes nothing for empty/invalid input.
fmt_age() {
  _secs=$1
  case "$_secs" in ''|*[!0-9]*) return 0 ;; esac
  _mins=$((_secs / 60))
  if [ "$_mins" -lt 1 ]; then
    _rel="${_secs}s"
  elif [ "$_mins" -lt 120 ]; then
    # Minutes up to TWO hours, not one. The hour bucket used to start at 60m,
    # which made 65m render as "1h" — and next to a 1h TTL that prints the
    # nonsense "1h ago > 1h", a comparison that looks false while being true.
    # Minutes stay unambiguous through the whole range where the 1h cache is
    # the thing being decided about.
    _rel="${_mins}m"
  else
    _h=$((_mins / 60))
    if [ "$_h" -lt 24 ]; then _rel="${_h}h"; else _rel="$((_h / 24))d"; fi
  fi
  _age="${_rel} ago"
  # Say WHY it is pulsing, in the two terms the reader would otherwise have to
  # supply from memory: the idle time and the TTL it is being measured against.
  # "51m ago" alone is a number with no verdict attached — "51m ago > 5m" is the
  # verdict, and it is also the one form that survives the TTL being 1h instead
  # of 5m without silently changing meaning.
  case "$(cache_phase "$_secs")" in
    expired)   _age=$(pulse red "$_age > $(fmt_ttl) (miss=$(miss_cost))") ;;
    expiring)  _age=$(pulse orange "$_age <= $(fmt_ttl)") ;;
  esac
  printf ' %s' "$_age"
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
# Only shown past the TTL, and only above 100K tokens (cache_phase already
# gates on that), so it never appears next to a sum too small to act on.
miss_cost() {
  _mult=1.15
  [ "${ttl_secs:-300}" -ge 3600 ] && _mult=1.9
  awk -v t="${used_tokens:-0}" -v r="${in_rate:-5}" -v m="$_mult" \
    'BEGIN{ c = t/1000000 * r * m; printf (c >= 10 ? "$%.0f" : "$%.1f"), c }'
}

# Which side of the prompt-cache TTL is this idle gap on? The single source of
# truth for both things that react to it — the "N ago" clock and the context
# counter — so they can never disagree about what state the cache is in.
#   expiring = inside the last 20% before the TTL: the prefix is still warm, send
#              something NOW and you keep paying 0.1x
#   expired  = past the TTL: the prefix is gone, the next message rebuilds it at
#              1.25x
# Silent below 100K tokens: there the rebuild is too cheap to interrupt anyone
# over, and a bar that pulses during trivial sessions is a bar you stop reading.
cache_phase() {
  _s=$1
  case "$_s" in ''|*[!0-9]*) echo none; return ;; esac
  [ "${used_tokens:-0}" -ge 100000 ] 2>/dev/null || { echo none; return; }
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
  # refreshInterval=1 cheap so the idle "N ago" clock can tick per-second.
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

  # --- Prompt-cache verdict for the CURRENT turn, rendered as a red "(cache
  # miss)" right after its cost ("$1.2 (cache miss) ⊂ $30"). Spelled out rather
  # than a bare "!" because the glyph was unreadable: it fires rarely enough that
  # by the time you see one you no longer remember what it meant, and a lone "!"
  # next to a number reads as "big number" long before it reads as "cache".
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
  cache_bang=""
  if [ "$turn_cache_read" -ge 0 ] && [ "$prev_prompt" -ge 5000 ] \
     && [ "$turn_cache_read" -lt $((prev_prompt / 2)) ]; then
    cache_bang="${RED} (cache miss)${RESET}"
  fi
  hookstate="/tmp/claude-turn-${session_id:-default}.state"
  if [ -f "$hookstate" ]; then
    hstate=$(sed -n '1p' "$hookstate"); hts=$(sed -n '2p' "$hookstate")
    case "$hstate" in
      # Keep age_secs (the fallback "time since last activity") ticking even while
      # working, so the "<age> ago" clock keeps running through the window right
      # after you hit Enter — until this turn's first cost actually lands.
      working) idle=0 ;;
      idle)    idle=1; case "$hts" in ''|*[!0-9]*) ;; *) age_secs=$((now - hts)); [ "$age_secs" -lt 0 ] && age_secs=0 ;; esac ;;
    esac
  fi
  # Displayed cost + label. Three states, driven by "am I working" AND by whether
  # the current turn has actually billed yet (turn_cost>0):
  #   working, nothing billed yet (you just hit Enter) -> the animated flower
  #     ALONE ("✻ $12"). The previous turn's price vanishes the instant you press
  #     Enter: for the 10-20s before the first response lands there is no current
  #     cost, and leaving the old number on screen means the one figure you look
  #     at is silently stale — you read "$1.4" and attribute it to the thing you
  #     just asked for. Better an empty slot that is honestly empty; the flower
  #     says "counting has started, no number yet".
  #   working AND the current turn has cost -> live figure with the animated
  #     flower STANDING IN FOR THE "$" ("✻0.7 ⊂ $12"). The currency sign is the
  #     one cell in the segment that carries no information — you know the units
  #     — so it is the right place to spend on the animation: the bloom sits
  #     directly ON the number that is still growing, rather than off to one
  #     side, and the figure it qualifies cannot be mistaken for the total.
  #     Nothing shifts width when it starts or stops.
  #   idle -> the finished turn's figure, its "$" back, plus a ticking
  #     "<age> ago" — the "ago" already says it's the last turn.
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
    case $((now % 9)) in
      0) flower="·" ;;
      1|7) flower="✢" ;;
      2|6) flower="✳" ;;
      3|5) flower="✻" ;;
      8) flower="$" ;;
      *) flower="✽" ;;
    esac
    # The flower stands in for the "$". No cost yet on this turn => print no
    # figure at all and let the bare flower open the segment.
    if [ "$(echo "$turn_cost > 0" | bc -l)" = "1" ]; then
      turn_money=$(printf '%s%.1f' "$flower" "$turn_cost")
    else
      turn_money=""
    fi
    turn_suffix=""
    lone="$flower"
  else
    # idle after a finished turn -> that turn's cost is in turn_cost; just after
    # Enter (turn_cost==0) -> fall back to the previous turn's cost.
    if [ "$(echo "$turn_cost > 0" | bc -l)" = "1" ]; then disp_cost="$turn_cost"; else disp_cost="$prev_turn_cost"; fi
    turn_money=$(printf '$%.1f' "$disp_cost")
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
  total_money=$(awk -v c="$cost" \
    'BEGIN{ if (c >= 10) printf "$%d", int(c); else printf "$%.1f", int(c*10 + 1e-9)/10 }')
  if [ -n "$turn_money" ]; then
    spend_seg="${turn_money}${cache_bang}${turn_suffix} ${sep} ${total_money}"
  else
    # Nothing billed yet: no figure, so no relation to state either — just the
    # flower and the total ("✻ $12").
    spend_seg="${lone} ${total_money}"
  fi
fi

if [ -n "$spend_seg" ] && [ "$(printf '%.2f' "$cost")" != "0.00" ]; then
  out="$out | $spend_seg"
fi

# --- Weekly quota, last cell of the bar: "+6% / 27% / 1wd1h"
# The 5h segment answers "can I keep going right now"; this one answers the
# slower question — am I going to run out of week before the week runs out.
# Three numbers, in the order you actually ask them:
#   +6%   pace, in percentage POINTS off a straight line: elapsed% − used%.
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
      # Signed percentage rather than an arrow glyph: the pace sits right next to
      # the "% left" figure, and two numbers in the same unit compare instantly
      # ("28% left, but 18% behind") where a "%" next to a "↓18" invites reading
      # the second one as a different kind of quantity.
      case "$delta" in
        -*) wtxt="-${delta#-}%"
            if [ "${delta#-}" -ge 10 ]; then wcol="$RED"; else wcol="$ORANGE"; fi ;;
        0)  wtxt="0%"; wcol="" ;;
        *)  wtxt="+${delta}%"; wcol="$GREEN" ;;
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
  # "/" and not "=": this segment is three readings of ONE window -- pace, what
  # is left, how long it runs -- and "/" is already the separator that means
  # exactly that everywhere else in this bar ("96% left / 4:44h"). An "=" read
  # as arithmetic that does not hold; one separator, used consistently, does
  # the same job of saying "these are different quantities" for the same cell.
  if [ -n "$wpace" ]; then
    week_seg="${wpace} / ${wleft_str}"
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
# ONE git call, not the two session-title.sh makes: this bar re-renders every
# second, so a subprocess here is a per-second cost, not a per-prompt one.
# --show-current and not `rev-parse --abbrev-ref HEAD`: the latter FAILS on an
# unborn branch (a fresh `git init` before the first commit), which is exactly
# when you most want to be told which branch you are on.
# Trunk branches are omitted for the same reason as in the title — master/main
# is the default state, so naming it trains the eye to skip the field.
branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
case "$branch" in
  ''|master|main) ;;
  *) loc="${loc}@${branch}" ;;
esac
[ -n "$loc" ] && out="$out | ${TEAL}${loc}${RESET}"

# --- Weekly quota, last cell (built above, next to its arithmetic) ----------
[ -n "$week_seg" ] && out="$out | $week_seg"

# --- Resolve the context counter's placeholder, now that the cache state is known.
# Three reasons the number stops being calm blue, in priority order:
#   1. the cached prefix has EXPIRED           -> red pulse
#   2. it is about to expire                   -> orange pulse
#   3. the context is simply enormous (>300K)  -> static red
# (1) and (2) also pulse the "N ago" clock, and the pair is the whole point: the
# clock says how long the cache has left, the token count says how much it is
# worth. Watching either alone tells you half of "is idling here about to cost
# me a dollar" — so they light up together, in the same colour, on the same beat.
# (3) is the standalone case: an oversized context is expensive to carry whether
# or not it is cached, and it means compaction is coming.
if [ -n "$abs_label" ]; then
  # TTL phase only counts while IDLE. While the agent is working it is hitting
  # the cache every few seconds, so the prefix is warm by definition and the
  # "time since the last turn" clock says nothing about it — pulsing off a stale
  # age there would fire the warning during exactly the period when there is
  # nothing to warn about.
  ctx_phase=none
  [ "${idle:-0}" = "1" ] && ctx_phase=$(cache_phase "${age_secs:-}")
  case "$ctx_phase" in
    expired)  ctx_render=$(pulse red "$abs_label") ;;
    expiring) ctx_render=$(pulse orange "$abs_label") ;;
    *)
      if [ "${used_tokens:-0}" -gt 300000 ] 2>/dev/null; then
        # Static red, NOT a pulse: an oversized context is a standing fact, not
        # an event. The breathing background is reserved for the cache-TTL cases
        # above, which are time-critical and only fire while idle — letting the
        # size rule pulse too meant a 380K session washed red for the whole turn,
        # which is exactly when there is nothing you can do about it.
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

## The title hook — `~/.claude/hooks/session-title.sh`

Wired in `~/.claude/settings.json` on both `SessionStart` and `UserPromptSubmit`
(see §6):

```json
"SessionStart":     [{"hooks": [{"type": "command", "command": "~/.claude/hooks/session-title.sh"}]}],
"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "~/.claude/hooks/session-title.sh"}]}]
```

```sh
#!/bin/sh
# UserPromptSubmit + SessionStart hook: name the session after WHERE it is, not
# what it is about.
#
#   ai                                  plain folder, on the trunk
#   ai@fix-cache                        off master/main -> the branch matters
#   agentic-how@embabel-demo/kind-mendeleev-f33675
#                                       inside a linked git worktree: the MAIN
#                                       repo, the branch, and the worktree name
#   ☢️ victorrentea                      operating straight out of $HOME
#
# This title is what Claude Code paints on the prompt-box border, in the
# terminal's window title, and in the /resume picker.
#
# Why location and not a summary: this replaced an LLM summarizer that spawned a
# Haiku CLI on every prompt to guess a 5-7 word topic. It was wrong often enough
# that it could not be trusted, it lagged a prompt behind by construction, and
# "what am I working on" is the one thing you already know — whereas "which of my
# nine terminals is this, and is it the worktree or the real repo" is exactly
# what you cannot tell at a glance and what you get burned by. Location is also
# always correct, costs no tokens, and needs no network.
#
# NOTE — this deliberately keeps overriding the session title, which suppresses
# Claude Code's own AI title (it only auto-titles a session when no custom title
# is set). See ~/workspace/victor-statusline/claude/victor-claude-statusline.md §6
# (published at https://github.com/victorrentea/victor-statusline).
#
# Trunk branches are omitted on purpose: master/main is the default state, so
# naming it says nothing and trains the eye to skip the field — which is exactly
# when you'd miss the one time it said something else.

# Don't title throwaway `claude -p` children spawned by tooling.
for v in CLAUDE_TITLE_HOOK_RUNNING CLAUDE_RENAME_HOOK_RUNNING CLAUDE_SKIP_PROMPT_CAPTURE; do
    eval "[ -n \"\$$v\" ]" && exit 0
done

INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // .workspace.current_dir // empty' 2>/dev/null)
[ -n "$CWD" ] || CWD=$PWD

NAME=$(basename "$CWD")
BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)

# A linked worktree's git-dir is <main-repo>/.git/worktrees/<worktree-name>,
# while --git-common-dir always points at the MAIN repo's .git. That pair is what
# lets the title say "which repo" and "which worktree" instead of just showing a
# generated worktree name (kind-mendeleev-f33675) that names nothing you know.
GITDIR=$(git -C "$CWD" rev-parse --absolute-git-dir 2>/dev/null)
WORKTREE=""
case "$GITDIR" in
    */worktrees/*)
        WORKTREE=$(basename "$GITDIR")
        COMMON=$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
        [ -n "$COMMON" ] && NAME=$(basename "$(dirname "$COMMON")")
        ;;
esac

TITLE="$NAME"
case "$BRANCH" in
    ''|master|main) ;;
    *) TITLE="${TITLE}@${BRANCH}" ;;
esac
[ -n "$WORKTREE" ] && TITLE="${TITLE}/${WORKTREE}"

# Radioactive marker for $HOME: nothing here is a project, and edits land in
# dotfiles rather than in a repo you can revert.
[ "$(cd "$CWD" 2>/dev/null && pwd -P)" = "$(cd "$HOME" && pwd -P)" ] && TITLE="☢️ ${TITLE}"

# Wired on BOTH SessionStart (so a fresh terminal is named before the first
# prompt) and UserPromptSubmit (so it follows a `cd` or a branch switch mid-
# session). SessionStart additionally accepts terminalSequence — an OSC 0 that
# names the window itself; kept from the inline hook this script replaced.
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // "UserPromptSubmit"' 2>/dev/null)
if [ "$EVENT" = "SessionStart" ]; then
    jq -nc --arg t "$TITLE" --arg p "$(printf '%s' "$CWD" | sed "s|^$HOME|~|")" \
        '{hookSpecificOutput:{hookEventName:"SessionStart",
          terminalSequence:("\u001b]0;Claude Code: "+$p+"\u0007"),
          sessionTitle:$t}}'
else
    jq -nc --arg t "$TITLE" --arg e "$EVENT" \
        '{hookSpecificOutput:{hookEventName:$e,sessionTitle:$t}}'
fi
exit 0
```

---

*Maintained by Victor. The canonical script is global (`~/.claude/`); this file
documents it **and embeds verbatim copies** of it and of the title hook
(above), so the whole thing ships
with the repo. Keep them in lockstep — a behaviour change must update the script,
this documentation, and the embedded copy in the same change (see the rule in the
script header).*
