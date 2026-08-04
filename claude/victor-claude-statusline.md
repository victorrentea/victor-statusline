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
Opus 4.8/xhigh 50K/1M | ↗98% left / 4:47h | ✻0.5 ⊂ $25 | +24% = 70% / 1d1h
```

Idle, waiting on you (note the ticking "N ago" clock and no flower):

```
Opus 4.8/xhigh 50K/1M | 98% left / 4:47h | $0.1 3m ago ⊂ $25 | +24% = 70% / 1d1h
```

Just after you hit Enter, before the first response has billed anything — **no
turn price at all**, only the animated flower:

```
Opus 4.8/xhigh 50K/1M | 98% left / 4:47h | ✻ $25 | +24% = 70% / 1d1h
```

Four `|`-separated segments: **model/context**, **5h quota + burn-rate**,
**spend**, **7-day quota**. There is **no leading emoji** on the model segment.

**Where you are is not in the bar.** Folder, branch and worktree live in the
**session title** one line above, on the prompt box border (§5) — printing them
in both places spent columns on the screen's most static fact twice over. The
bar is for what changes; the title for where you are.

**`|` is reserved for segment boundaries — nothing else uses it.** Inside a
segment, two readings of the same window are joined with `/` (`↗98% left / 4:47h`,
`+24% = 70% / 1d1h`), which also buys back a couple of columns per join versus
the `•` it replaced.

---

## 1. Model & context — `Opus 4.8/xhigh 50K/1M`

| Piece | Meaning | Source (stdin JSON) |
|-------|---------|---------------------|
| `Opus 4.8` | model display name (with ` context)` trimmed to `)`) | `.model.display_name` |
| `/xhigh` | reasoning effort level, spliced in before any `(size)` | `.effort.level` |
| `50K` | absolute context tokens used (blue) = `used% × size` | `.context_window.used_percentage` × size |
| `/1M` | context window size | model's `(1M)` suffix, else `.context_window.context_window_size` |

- The absolute token count (`50K`) is rendered **blue** when there is nothing to
  worry about — and **pulses** when there is (§1.1).
- On the **1M window** the explicit `• N%` is **dropped** — the `used/size` pair
  (e.g. `50K/1M`) already makes the ratio obvious. On **smaller windows** the
  segment gains a trailing `• N%`, and that percentage turns **orange ≥ 65%**
  and **red ≥ 95%**.

### 1.1 The pulse

The token count breathes a coloured background — dark → full hue → dark over a
**6-second cycle**, one frame per render — in three cases, in priority order:

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

- **Slow.** A fast blink is an alarm, and an alarm in a bar you stare at all day
  is something you learn to tune out within a day. Something that *breathes* at
  the edge of vision keeps registering as movement without seizing the focus a
  strobe demands. Six steps means no frame is far from its neighbour, so it
  reads as a fade rather than a flicker.
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
| `!` | red — this turn **missed the prompt cache** (see §3.1) |
| `⊂` | subset: the turn's spend is *contained in* the session's (see below) |
| `$25` | session total, **integer-truncated** (`int($)`), authoritative |

Turn cost is rounded to **one decimal**: at this granularity the second decimal
was noise you never acted on, and dropping it keeps the segment narrow.

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
  running session total, printed as `int(cost)` — so any session under `$1`
  shows `$0` even though it's non-zero.
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
  ping-ponged over an 8-step cycle keyed off `now % 8`, so the flower blooms and
  closes in sync with the "Working…" spinner above the prompt. Every glyph is
  single-cell, so the line never shifts width; `refreshInterval: 1` is what
  advances the frame, so the animation adds zero extra work per render.

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

## 3.1 Prompt-cache miss — the red `!`

```
Opus 4.8/xhigh 200K/1M | 98% left / 4:47h | ✻1.2! ⊂ $30 | +24% = 70% / 1d1h
```

A red `!` glued to the turn price means **this turn did not reuse the cached
prompt prefix** — it paid to build it again.

Why it deserves a glyph of its own: cached input is billed at **0.1×**, a cache
*write* at **1.25×**. Re-sending a 200 K-token prefix uncached is therefore
around a dollar of pure waste on Opus, and it is **completely invisible** in the
price — the turn just looks "expensive today". The `!` names the reason.

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
  shows no price and hence no `!`.

Only the **main chain** is examined (`isSidechain != true`): a subagent has its
own cache and its own prefix, so its hits and misses say nothing about yours.

### The TTL is read, not assumed

The same `usage` blob states which bucket a cache write went into:

```json
"cache_creation": { "ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 17187 }
```

So the session **reports its own TTL** — no guessing, no configuration to keep
in sync. The most recent write with a non-zero bucket decides: `1h` if the 1-hour
bucket is the larger, else `5m`; `300 s` is the fallback when nothing has been
written yet.

That number then drives the **`N ago` clock's colour** (still only when context
≥ 100 K, where a rebuild actually costs something):

| Age since the last turn | Rendering | Meaning |
|-------------------------|-----------|---------|
| `< 0.8 × TTL` | plain | prefix is warm |
| `0.8 × TTL … TTL` | **orange pulse** | last chance — send now and you still pay 0.1× |
| `≥ TTL` | **red pulse** | prefix is gone; your next message rebuilds it at 1.25× |

The clock and the context counter share one predicate — `cache_phase()`,
returning `none` / `expiring` / `expired` — so the two can never disagree about
what state the cache is in. See §1.1 for the pulse itself.

On a 1-hour cache that reads: plain until 48 min, orange 48–60 min, red past the
hour. On a 5-minute cache: orange at 4 min, red at 5. The old hardcoded
"orange past ~5 min" is gone — it was simply wrong for a 1 h TTL, warning an hour
early, every turn.

The two signals are complements, not duplicates: the **orange clock is a
forecast** ("you are about to lose it"), the **red `!` is a post-mortem** ("you
just did").

---

### Caveats

- Current/last-turn cost is a derived delta. If the very first render of a turn
  lands *after* the model already made an API call, that turn slightly
  undercounts (it self-corrects on the next turn).
- The `!` and the TTL both need a **readable transcript**. In the newer
  per-session storage format (the cost-clock fallback branch) there is none, so
  no `!` is ever shown and the TTL falls back to 300 s.
- A **context compaction** legitimately invalidates the prefix and will be
  flagged as a miss. That is accurate — it did cost you the rebuild.
- The session total *includes* subagent/sidechain cost (it comes from
  `.cost.total_cost_usd`), even though the transcript token parse only sees the
  main transcript. Minor inconsistency by design.
- The window length is hardcoded to 5h (18000s); the status input only provides
  `resets_at`, not the window size.

---

## 4. Weekly quota — `+24% = 70% / 1d1h`

The **last** segment, tracking the rolling **7-day** (604800s) rate-limit window.
Segment 2 answers *"can I keep going right now"*; this one answers the slower
question — *am I going to run out of week before the week runs out*.

| Piece | Meaning | Source |
|-------|---------|--------|
| `+24%` | pace: **percentage points** off a straight line, `elapsed% − used%` | derived |
| `=` | reading aid separating the two percentages (see below) | — |
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

## 5. The session title — `ai@fix-cache/kind-mendeleev-f33675`

Not part of the status line, but the other half of the same display: Claude Code
draws a **session title** on the prompt box border, one line above the bar. It is
set by a sibling hook, `~/.claude/hooks/session-title.sh`, and it exists so the
bar doesn't have to carry the folder.

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
  trunk. (Same rule the location segment used before it was removed.)
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

- **Merge rule without clocks.** The readings carry no age, so freshness can't be
  compared directly. But within a window `used` only ever *increases* (quota is
  consumed, never returned), and across windows `resets_at` increases — so
  comparing `(resets_at, used)` lexicographically *is* a total "which reading is
  newer" order. A reading that loses is simply discarded.
- **Self-healing instead of locking.** Every terminal writes unlocked, so two
  writers can interleave and lose an update — but the merge is monotone and re-runs
  a second later, so a lost update heals itself. A lock would cost more than the
  race does.
- **Never blanks out knowledge.** A non-numeric or absent new reading always loses
  the merge, so a terminal that has not yet seen a single header cannot wipe what
  the others already know.
- The merged value is shown **unmarked** — which terminal measured it is
  bookkeeping, not worth spending a glyph on.
- `quota-state.sh read` still emits only the two `five_hour` fields (the sibling
  `quota-gate.sh` parses it with `${x%% *}`/`${x##* }` and parks a terminal on the
  5h window alone); the weekly pair is a separate `read7` subcommand. Extending an
  output that others parse positionally is exactly where a "harmless" change breaks
  a consumer.

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
  (`·` `✢` `✳` `✻` `✽`, ping-ponged) by deriving its frame from `now % 8` — a
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
- **`folder@branch` closes the line**, with the folder painted teal (256-colour
  80, `#5fd7d7`) to match the border Claude Code draws around the prompt and the
  session title it writes on that border — so the two read as one frame. A
  leading `🌿 ` marks a **linked worktree** (git-dir under `.git/worktrees/<name>`);
  it is *not* a separate segment, because the worktree name and the folder name
  are the same string and printing it twice was pure noise.
- **The branch is printed only when it is neither `master` nor `main`.** The
  trunk is the default state, so naming it says nothing; printing it on every
  render trains the eye to skip that part of the line — which is exactly when
  you'd miss the one time it mattered. Absence of `@branch` therefore *means*
  "on the trunk", and any `@something` you do see is worth reading.

---

## The full script — `~/.claude/statusline-command.sh`

To reproduce this exact status line: save the script below to `~/.claude/statusline-command.sh`, make it executable (`chmod +x`), and wire it up with the `statusLine` block shown at the top of this file. It is embedded here verbatim so it ships with the course materials — this copy is a snapshot and must be re-synced whenever the canonical script changes.

```sh
#!/bin/sh
# Claude Code status line:
#   "Model (ctx% of SIZE) | 5h% left | spend | folder[@branch] | 7d quota"
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
model=$(echo "$input" | jq -r '.model.display_name // "Claude"' | sed 's/ context)/)/')
effort=$(echo "$input" | jq -r '.effort.level // empty')
if [ -n "$effort" ]; then
  case "$model" in
    *" ("*) model="${model%% (*}/${effort} (${model#* (}" ;;
    *)      model="${model}/${effort}" ;;
  esac
fi
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
# them has seen. The merged value is shown unmarked: which terminal measured it
# is bookkeeping, not something worth spending a glyph on.
merged=$("$HOME/.claude/hooks/quota-state.sh" publish \
  "${five:-}" "${reset:-0}" "${week:-}" "${week_reset:-0}" 2>/dev/null)
if [ -n "$merged" ]; then
  m_five=$(printf '%s' "$merged" | cut -d' ' -f1)
  m_reset=$(printf '%s' "$merged" | cut -d' ' -f2)
  m_week=$(printf '%s' "$merged" | cut -d' ' -f3)
  m_week_reset=$(printf '%s' "$merged" | cut -d' ' -f4)
  if [ "$m_five" != "-1" ]; then
    five=$m_five
    reset=$m_reset
  fi
  if [ -n "$m_week" ] && [ "$m_week" != "-1" ]; then
    week=$m_week
    week_reset=$m_week_reset
  fi
fi

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

# --- Slow pulse -------------------------------------------------------------
# Breathes a background from near-black up to full hue and back, one frame per
# render (refreshInterval 1 => a 6-second cycle). Slow on purpose: a fast blink
# is an alarm you learn to tune out within a day, while something that *breathes*
# in the corner of your eye keeps registering as movement without demanding the
# focus a hard blink does. Six steps also means no frame is far from its
# neighbour, so it reads as a fade rather than a strobe.
#
# Background rather than foreground because the thing being flagged is a NUMBER
# you still have to read: recolouring the glyphs fights legibility exactly when
# you most need the digits, whereas a wash behind them leaves them intact.
# Bright white text is pinned on top so contrast holds at every step of the ramp.
#
#   pulse red|orange <text>
RED_RAMP="52 88 124 160 124 88"
ORANGE_RAMP="58 94 130 166 130 94"
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
  pct_part="${ind}${left}%"
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
# Only when the context is big (>=100K tokens) — below that the re-send isn't
# expensive enough to warn about. Uses globals $used_tokens/$ttl_secs/colors.
# Echoes nothing for empty/invalid input.
fmt_age() {
  _secs=$1
  case "$_secs" in ''|*[!0-9]*) return 0 ;; esac
  _mins=$((_secs / 60))
  if [ "$_mins" -lt 1 ]; then
    _rel="${_secs}s"
  elif [ "$_mins" -lt 60 ]; then
    _rel="${_mins}m"
  else
    _h=$((_mins / 60))
    if [ "$_h" -lt 24 ]; then _rel="${_h}h"; else _rel="$((_h / 24))d"; fi
  fi
  _age="${_rel} ago"
  case "$(cache_phase "$_secs")" in
    expired)   _age=$(pulse red "$_age") ;;
    expiring)  _age=$(pulse orange "$_age") ;;
  esac
  printf ' %s' "$_age"
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
| ([ $all[] | select(.type=="assistant" and (.isSidechain!=true)) | .message.usage.cache_creation
     | select(. != null and (((.ephemeral_1h_input_tokens//0)+(.ephemeral_5m_input_tokens//0)) > 0)) ] | last) as $cc
| (if $cc == null then 0 elif (($cc.ephemeral_1h_input_tokens//0) > ($cc.ephemeral_5m_input_tokens//0)) then 3600 else 300 end) as $ttl
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

  # --- Prompt-cache verdict for the CURRENT turn, rendered as a red "!" glued to
  # its cost ("$1.2! ✻ $30"). The question it answers is the one you can't see
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
    cache_bang="${RED}!${RESET}"
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
    case $((now % 8)) in
      0) flower="·" ;;
      1|7) flower="✢" ;;
      2|6) flower="✳" ;;
      3|5) flower="✻" ;;
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
  total_money=$(awk -v c="$cost" 'BEGIN{printf "$%d", int(c)}')
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

# NO location segment here — deliberately. "Which folder / which branch / which
# worktree" now lives in the SESSION TITLE, drawn by ~/.claude/hooks/session-title.sh
# on the prompt box border one line above this bar. Printing it in both places
# spent columns on the screen's most static fact twice over; the status line is
# for what CHANGES (spend, quota, context, cache), the title for where you are.

# --- Weekly quota, last segment: "+6% = 27% / 1wd1h"
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
  # The "=" between them is a reading aid, not arithmetic: without it "-18% 28%"
  # is two bare percentages jammed together with nothing saying they are
  # different quantities. It makes the pair scan as one statement -- "18% behind,
  # which leaves 27%" -- for the price of one cell.
  if [ -n "$wpace" ]; then
    week_seg="${wpace} = ${wleft_str}"
  else
    week_seg="$wleft_str"
  fi
  [ -n "$wdur" ] && week_seg="${week_seg} / ${wdur}"
  out="$out | $week_seg"
fi

# --- Resolve the context counter's placeholder, now that the cache state is known.
# Three reasons the number stops being calm blue, in priority order:
#   1. the cached prefix has EXPIRED           -> red pulse
#   2. it is about to expire                   -> orange pulse
#   3. the context is simply enormous (>300K)  -> red pulse
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
        ctx_render=$(pulse red "$abs_label")
      else
        ctx_render="${BLUE}${abs_label}${RESET}"
      fi
      ;;
  esac
  # Plain shell substitution, not sed: $ctx_render is full of ESC and & bytes
  # that sed's replacement syntax would mangle.
  out="${out%%@@CTX@@*}${ctx_render}${out#*@@CTX@@}"
fi

echo "$out"
```

## The title hook — `~/.claude/hooks/session-title.sh`

Wired in `~/.claude/settings.json` on both `SessionStart` and `UserPromptSubmit`
(see §5):

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
# is set). See ~/workspace/victor-statusline/claude/victor-claude-statusline.md §5
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
