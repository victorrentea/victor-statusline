#!/usr/bin/env python3
"""Turn the raw ANSI status lines under lines/ into annotated PNGs for the README.

The line itself is never retyped here: it is parsed out of the .ansi file that
`make-lines.sh` produced, so the picture always shows what the script actually
printed, in the colours it actually chose. Only the *annotations* live in this
file, and each field is located by a REGEX rather than by a literal value --
figures like "3h19" or "2wd13h" move with the wall clock at generation time, and
a legend that quoted them literally would drift away from the picture beside it.

    ./docs/screenshots/make-lines.sh && python3 docs/screenshots/render.py

Needs playwright (`pip install playwright`); it drives the system Chrome, so no
browser download is required.
"""
import html
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
LINES = HERE / "lines"

# --- palette ---------------------------------------------------------------
# The status lines address colour as xterm-256 indices; Chrome needs hex.
BASE16 = [
    "#000000", "#cd3131", "#0dbc79", "#e5e510", "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5",
    "#666666", "#f14c4c", "#23d18b", "#f5f543", "#3b8eea", "#d670d6", "#29b8db", "#ffffff",
]


def xterm(n):
    if n < 16:
        return BASE16[n]
    if n < 232:
        n -= 16
        steps = [0, 95, 135, 175, 215, 255]
        return "#%02x%02x%02x" % (steps[n // 36], steps[(n // 6) % 6], steps[n % 6])
    v = 8 + (n - 232) * 10
    return "#%02x%02x%02x" % (v, v, v)


SGR = re.compile(r"\x1b\[([0-9;]*)m")


def parse_ansi(raw):
    """-> [(char, fg_or_None, bg_or_None)], one entry per printed cell."""
    cells, fg, bg, i = [], None, None, 0
    for m in SGR.finditer(raw):
        for ch in raw[i:m.start()]:
            cells.append((ch, fg, bg))
        codes = [c for c in m.group(1).split(";") if c != ""] or ["0"]
        j = 0
        while j < len(codes):
            c = codes[j]
            if c == "0":
                fg = bg = None
            elif c == "39":
                fg = None
            elif c == "49":
                bg = None
            elif c.isdigit() and 30 <= int(c) <= 37:
                fg = BASE16[int(c) - 30]
            elif c.isdigit() and 90 <= int(c) <= 97:
                fg = BASE16[int(c) - 90 + 8]
            elif c.isdigit() and 40 <= int(c) <= 47:
                bg = BASE16[int(c) - 40]
            elif c.isdigit() and 100 <= int(c) <= 107:
                bg = BASE16[int(c) - 100 + 8]
            elif c == "38" and codes[j + 1:j + 2] == ["5"]:
                fg = xterm(int(codes[j + 2])); j += 2
            elif c == "48" and codes[j + 1:j + 2] == ["5"]:
                bg = xterm(int(codes[j + 2])); j += 2
            j += 1
        i = m.end()
    for ch in raw[i:]:
        cells.append((ch, fg, bg))
    return cells


# --- what each field means -------------------------------------------------
# (regex, colour-group, explanation). The colour group ties a field to its
# segment, so the eye can see at a glance which numbers belong together.
GROUPS = {"model": "#7aa2f7", "5h": "#9ece6a", "spend": "#e0af68",
          "loc": "#bb9af7", "week": "#7dcfff"}

CLAUDE_MODEL = [
    (r"Opus 5xh", "model",
     "model display name plus the reasoning effort, abbreviated to one or two "
     "lower-case letters and glued straight on: <b>l</b>ow, <b>m</b>edium, "
     "<b>h</b>igh, <b>xh</b>igh, <b>max</b>."),
    (r"\d+K(?= )", "model",
     "context tokens in play. Blue while healthy, blinking when it is not. On a 1M "
     "Opus window the denominator is dropped — <i>330K out of a window you already "
     "know is 1M</i> is the ratio, and a second unit would only restate it; smaller "
     "windows print <code>used/size • N%</code>, orange ≥65%, red ≥95%."),
]
CLAUDE_SPEND = [
    (r"✻[\d.]+", "spend",
     "what the <b>current turn</b> has cost, in dollars. The flower stands in for "
     "the <code>$</code> and blooms in sync with Claude Code's own spinner; once "
     "the turn ends the <code>$</code> comes back and a ticking "
     "<code>-3m</code> says how long ago that was."),
    (r"⊂ \$[\d.]+", "spend",
     "the session total. <code>⊂</code> rather than a neutral bullet because the "
     "turn price is <i>contained</i> in it — the two are not siblings."),
]
CLAUDE_LOC = [
    (r"victor-statusline", "loc",
     "the current folder, on a colour chip hashed from its full path (twenty "
     "combinations), so a given folder always looks the same. The loud chip and the "
     "quiet one on the 5h cell give the bar its <b>zebra</b>: plain, chipped, plain, "
     "chipped, plain — sorted by the eye before a glyph is read."),
    (r"@fix-cache", "loc",
     "the git branch, teal and outside the chip. Omitted on <code>main</code> / "
     "<code>master</code>, so any <code>@…</code> you do see is worth reading."),
]

SPECS = [
    dict(
        src="claude-subscription", out="claude-subscription.png",
        title="Claude Code — on a Pro / Max subscription",
        subtitle="Five segments, ordered by how fast each figure moves. The payload "
                 "carries <code>rate_limits</code>, so both quota windows are drawn.",
        fields=CLAUDE_MODEL + [
            (r"[↑↗↘↓]?\d+%(?= / \d+h)", "5h",
             "5-hour quota <b>left</b>, led by the burn-rate arrow: <code>↑</code> / "
             "<code>↗</code> green = more quota left than clock, no arrow = spending in "
             "step with the window, <code>↘</code> / <code>↓</code> orange / red = "
             "burning it faster than it drains. The whole cell sits on a <b>chip</b> — a "
             "dark blue-grey block matched to the window — and it is the <b>chip's "
             "ground</b> that warns: dark amber under 15%, dark maroon under 5%. That is "
             "also why the cell has no <code>|</code> around it."),
            (r"\d+h\d+(?= )", "5h",
             "time until the 5-hour window resets. A duration (<code>3h19</code>), never "
             "a clock time — the segment already contains a wall clock when parked, and "
             "<code>3:19</code> would be ambiguous. <code>/</code> is the only separator "
             "left inside the chip; the chip's edge is what ends the cell."),
        ] + CLAUDE_SPEND + CLAUDE_LOC + [
            (r"\([+-]?\d+\)", "week",
             "weekly pace, in <b>percentage points</b> off a straight line "
             "(<code>elapsed% − used%</code>). Positive means you are ahead of schedule. "
             "Bracketed and glued to the figure it qualifies rather than given a cell of "
             "its own."),
            (r"(?<=\))\d+%", "week",
             "quota left in the rolling <b>7-day</b> window, same thresholds as the 5h "
             "figure."),
            # The `wd` half is optional: the field drops units it does not need,
            # so late on a Friday it is a bare "13h". Anchored to the end of the
            # line because a bare \d+h would otherwise match inside "3h19".
            (r"(?:\d+wd)?\d+h$", "week",
             "<b>working</b> time until the weekly window resets: <code>wd</code> is "
             "weekdays, with Saturday and Sunday subtracted, because a weekend burns no "
             "quota and flattered the number every Monday. Units it does not need are "
             "dropped, so under a day left prints as a bare <code>13h</code>."),
        ],
    ),
    dict(
        src="claude-apikey", out="claude-apikey.png",
        title="Claude Code — on an API key",
        subtitle="Same script, same session. Claude Code omits the "
                 "<code>rate_limits</code> key entirely unless at least one window "
                 "exists, and its own schema says plan limits do not apply to an API "
                 "key — so both quota segments are not drawn.",
        note="Nothing is greyed out or zeroed: fields 3–4 and 9–11 of the subscription "
             "bar above are <b>absent</b>, and the <code>|</code> separators with them. "
             "The 2.1.263 binary is explicit about why — the payload is built as "
             "<code>…(five_hour || seven_day || spend_limit) &amp;&amp; {rate_limits}</code>, "
             "over a field documented as <i>“False when plan rate limits do not apply "
             "(API key, Bedrock, Vertex…) — rate_limits will be null.”</i> What is left is "
             "the half of the bar that is true either way — and the <code>$</code> figures "
             "stop being a proxy for quota and start being the invoice.",
        fields=CLAUDE_MODEL + CLAUDE_SPEND + CLAUDE_LOC,
    ),
    dict(
        src="claude-subagents", out="claude-subagents.png",
        title="Claude Code — a fan-out in flight",
        subtitle="The same bar again, with one chip that is only there while "
                 "subagents are running. It is glued onto the model segment because "
                 "that is where its defaults come from.",
        note="Claude Code's own agent list under the bar names the agents and shows "
             "their progress, but never says <b>which model</b> any of them got — and "
             "that is the fact that decides what a fan-out costs. The same "
             "<code>Task</code> lands on Opus, Sonnet, Fable or Haiku depending on the "
             "agent's frontmatter, a <code>model</code> override at the call site, or "
             "the configured default; none of the three is visible anywhere on screen. "
             "A 24-way fan-out on Fable and one on Opus look identical while they run "
             "and differ by an order of magnitude on the bill.",
        fields=[
            (r"Opus 5xh", "model",
             "the <b>session's</b> model and effort — and the fallback for the chip "
             "beside it: an agent inherits this session's effort level unless its own "
             "definition overrides it, which is what the bar shows for the seconds "
             "between a spawn and that agent's first completed response."),
            (r"\+\{[^}]*\}", "spend",
             "the fan-out, <b>grouped rather than listed</b>: each entry is "
             "<code>&lt;model&gt;&lt;effort&gt;</code> with <code>*N</code> when a group "
             "has more than one, biggest group first. Here: two Opus 5 at high effort "
             "and one Sonnet 5 at medium. Haiku, which has no reasoning-effort setting "
             "at all, renders bare (<code>H4.5</code>) rather than inventing a letter. "
             "One line per agent would be a roster; the bar has room for the "
             "<i>shape</i> of the fan-out, which is the part you act on — "
             "<code>+{F5.1h*21,O5h*3}</code> says “mostly Fable, three Opus stragglers” "
             "in twelve columns. The chip disappears the moment the last agent is "
             "collected."),
        ],
    ),
    dict(
        out="claude-prompt-cache.png",
        title="Claude Code — the prompt cache, and the money it quietly costs",
        subtitle="Cached input is billed at <b>0.1×</b>; rebuilding a prefix costs "
                 "<b>1.25×</b> on a 5-minute cache and <b>2.0×</b> on a 1-hour one. "
                 "Re-sending a 300K-token Opus prefix is therefore about three dollars "
                 "of pure waste — and it is <i>completely invisible</i> in the price, "
                 "because the turn simply looks expensive today. These four rows are "
                 "one session at four moments.",
        note="The two signals are <b>complements, not duplicates</b>: the orange clock "
             "is a <i>forecast</i> — you are about to lose it — and the red "
             "<code>(N⏱)</code> is a <i>post-mortem</i> — you just did. Note also "
             "which one is louder. The price is <b>stated</b> for every expired cache, "
             "however small, because it answers a question you may be asking on "
             "purpose; only a loss over $2 <b>blinks</b>, because a bar that interrupts "
             "you over forty cents stops being read at all.",
        rows=[
            dict(src="cache-warm",
                 caption="<b>warm</b>· 12 min into a 1-hour cache",
                 fields=[
                     (r"300K(?= )", "model",
                      "the live context, blue: all of this is sitting in the cache, and "
                      "every turn reads it back at <b>0.1×</b> the input price."),
                     (r"-\d+m(?= ⊂)", "spend",
                      "how long since the last response. Plain text — twelve minutes "
                      "into a one-hour cache there is nothing at stake, and a bar that "
                      "warns you when nothing is at stake trains you to stop looking."),
                 ]),
            dict(src="cache-expiring",
                 caption="<b>expiring</b>· 52 min in — past 0.8 × TTL",
                 fields=[
                     (r"300K(?= )", "model",
                      "the same counter, now orange. It and the clock share <b>one "
                      "predicate</b> (<code>cache_phase()</code>), so the two halves of "
                      "the bar can never disagree about what state the cache is in."),
                     (r"-\d+m <= 1h", "spend",
                      "last chance: send now and you still pay 0.1×. The clock prints "
                      "the <b>comparison</b>, not just the age — <code>-52m</code> alone "
                      "is a number with no conclusion attached, and you would have to "
                      "remember the TTL to draw one. The TTL is <b>read, not assumed</b>: "
                      "the API says which ephemeral bucket each cache write landed in, "
                      "so the session states its own."),
                     (r"miss\+=\$[\d.]+", "spend",
                      "<b>the loss, priced before it happens</b> — the whole live "
                      "context re-written at the cache-<b>write</b> price instead of "
                      "read at the cache-<b>read</b> price. That spread is 1.15× base "
                      "input on a 5-minute cache and <b>1.9× on a 1-hour</b> one, so "
                      "300K of Opus context is $1.7 to lose at five minutes and $2.9 at "
                      "an hour — the longer TTL is the safer setting right up until you "
                      "blow past it. Naming the price <i>while the prefix is still "
                      "alive</i> is the entire point of this phase: a deadline you "
                      "cannot price is one you cannot decide about."),
                 ]),
            dict(src="cache-expired",
                 caption="<b>expired</b>· past the hour",
                 fields=[
                     (r">1h", "spend",
                      "the prefix is gone; your next message rebuilds it at the write "
                      "price. Past an hour the exact age stops meaning anything — 2h, "
                      "16h and 3d are all “from scratch” — so it collapses to "
                      "<code>&gt;1h</code>, and the <code>&gt; 1h</code> comparison is "
                      "dropped with it: <code>&gt;1h &gt; 1h</code> is noise. Above $2, "
                      "as here, the red blinks one second on, one second off."),
                 ]),
            dict(src="cache-miss",
                 caption="<b>the post-mortem</b>· a turn that already paid",
                 fields=[
                     (r"✻[\d.]+(?=\()", "spend",
                      "the turn price, with the flower standing in for the <code>$</code> "
                      "because the turn is still running. <b>The red stops at the "
                      "parenthesis</b>: this is what the turn cost, and colouring "
                      "through it would paint the whole turn as the alarm when the alarm "
                      "is only the part inside."),
                     (r"\([\d.]+⏱\)", "spend",
                      "of this turn's $5.20, <b>$2.70 was the rebuilt prefix</b>. Glued "
                      "on with no space, because a parenthetical touching its number is "
                      "a qualifier <i>of</i> it — the $2.70 is inside the $5.20, which "
                      "is in turn inside the session's $35. The stopwatch names the "
                      "<b>cause</b>, not the severity: what kills a prompt cache is a "
                      "clock running out, and it is the same clock the row above was "
                      "counting. The verdict is deterministic, off the API's own "
                      "numbers — a miss is a prefix of ≥5000 tokens whose first request "
                      "this turn read back less than half; on real transcripts genuine "
                      "misses read back 0–7% and healthy turns 80–100%."),
                 ]),
        ],
    ),
    dict(
        src="copilot", out="copilot.png",
        title="GitHub Copilot CLI",
        subtitle="Three segments: which brain and how full, what today has cost, and "
                 "what is left of the month's AI Credits. Credit figures are a monthly "
                 "balance, so they come from a background-refreshed cache rather than "
                 "from the payload.",
        fields=[
            (r"🤖 sonnet-5/med", "model",
             "the robot is how you tell this bar from the Claude one at a glance; then "
             "the model with its <code>claude-</code> prefix stripped and the effort "
             "abbreviated after the <code>/</code>."),
            (r"\d+K/\d+K \(\d+%\)", "model",
             "context tokens used / window size. The used count goes yellow ≥65% and red "
             "≥95%; the percentage is hidden when the window is a full 1M."),
            (r"\d+%[↑↗↘↓]?(?= \()", "5h",
             "share of <b>today's</b> budget already burned, where today's budget is "
             "simply the credits left divided by the working days left until the reset. "
             "The arrow compares that share against how much of the working day "
             "(09:00–18:00) has elapsed."),
            (r"\(\$[\d.]+≈\d+/\d+ AIC\)", "5h",
             "the same thing in absolutes: credits burned today out of today's slice, "
             "each prefixed with its list price at 100 AIC to the dollar."),
            (r"[+-]\d+%(?= =)", "week",
             "the <b>reserve</b>, in percentage points: how much of the month's "
             "entitlement is still there <i>beyond</i> what the calendar says should be "
             "left by now. Signed rather than an arrow, so it reads in the same unit as "
             "the <code>%</code> beside it."),
            (r"(?<== )\d+%", "week",
             "share of the monthly AI-Credit entitlement still unspent."),
            (r"\(\$\d+≈\d+ AIC\)", "week",
             "those same credits in absolute terms, with their list-price equivalent — "
             "<code>$68</code> lands instantly where <code>6759 AIC</code> needs "
             "arithmetic first."),
            # Same shape, same anchor, as the weekly field on the Claude line.
            (r"(?:\d+wd)?\d+h$", "week",
             "working days and hours until the monthly credit quota resets, weekends "
             "again excluded; <code>wd</code> disappears once under a day is left."),
        ],
    ),
]

CSS = """
* { box-sizing: border-box; }
body { margin: 0; background: #ffffff; }
.card { width: 1560px; padding: 34px 40px 34px; background: #0d1117; color: #c9d1d9;
        font-family: -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif; }
h1 { font-size: 25px; margin: 0 0 6px; color: #f0f6fc; font-weight: 600; letter-spacing: -.01em; }
.sub { font-size: 16px; line-height: 1.5; margin: 0; color: #8b949e; max-width: 1180px; }
.term { margin: 46px 0 10px; padding: 18px 22px; background: #010409;
        border: 1px solid #21262d; border-radius: 8px; overflow: visible; }
.row + .row { margin-top: 30px; }
.cap { font-size: 13.5px; line-height: 1.4; color: #6e7681; margin: 0 0 25px;
       font-family: -apple-system, sans-serif; }
.cap b { color: #d7dde5; font-weight: 600; font-size: 14.5px; margin-right: 7px; }
.line { font-family: "SF Mono", Menlo, monospace; font-size: 20px; line-height: 1.5;
        white-space: pre; color: #c9d1d9; }
.fld { position: relative; border-radius: 3px; padding: 3px 1px;
       background: color-mix(in srgb, var(--c) 20%, transparent);
       box-shadow: inset 0 -2px 0 0 var(--c); }
.badge { position: absolute; top: -25px; left: 50%; transform: translateX(-50%);
         font-family: -apple-system, sans-serif; font-size: 12px; font-weight: 700;
         line-height: 17px; min-width: 17px; height: 17px; padding: 0 5px;
         text-align: center; border-radius: 9px; background: var(--c); color: #010409; }
.note { margin: 18px 0 0; padding: 12px 16px; border-left: 3px solid #e0af68;
        background: #16191f; border-radius: 0 6px 6px 0;
        font-size: 15.5px; line-height: 1.55; color: #adb7c2; }
ol.legend { list-style: none; margin: 28px 0 0; padding: 0;
            columns: 2; column-gap: 44px; }
ol.legend li { break-inside: avoid; margin: 0 0 15px; padding-left: 30px;
               position: relative; font-size: 15.5px; line-height: 1.5; color: #adb7c2; }
ol.legend li .n { position: absolute; left: 0; top: 2px; width: 19px; height: 19px;
                  border-radius: 10px; background: var(--c); color: #010409;
                  font-size: 12px; font-weight: 700; line-height: 19px; text-align: center; }
ol.legend li .k { font-family: "SF Mono", Menlo, monospace; font-size: 15px;
                  color: var(--c); font-weight: 600; }
ol.legend li code { font-family: "SF Mono", Menlo, monospace; font-size: .92em;
                    background: #1b2029; border-radius: 4px; padding: 1px 4px; color: #d7dde5; }
ol.legend li b { color: #e6edf3; font-weight: 600; }
.sub code { font-family: "SF Mono", Menlo, monospace; font-size: .92em;
            background: #1b2029; border-radius: 4px; padding: 1px 4px; }
.foot { margin: 26px 0 0; font-size: 13.5px; color: #565f6a; }
"""


def build(spec):
    """One figure. A spec is either a single line (`src` + `fields`) or several
    stacked `rows`, each its own .ansi with its own caption and fields — which
    is what a story about STATE CHANGE needs: the cache clock only means
    anything as four moments of one session, side by side."""
    rows = spec.get("rows") or [{"src": spec["src"], "fields": spec["fields"]}]
    n = 0
    row_html, legend_items = [], []

    for row in rows:
        raw = (LINES / f"{row['src']}.ansi").read_text()
        cells = parse_ansi(raw)
        plain = "".join(c[0] for c in cells)

        # Locate every annotated field, then check the marks do not overlap: a
        # bad regex silently swallowing a neighbour is the one failure mode
        # that would produce a wrong-but-plausible picture.
        marks = []
        for pat, group, desc in row["fields"]:
            m = re.search(pat, plain)
            if not m:
                sys.exit(f"{row['src']}: no match for /{pat}/ in {plain!r}")
            n += 1
            marks.append([m.start(), m.end(), n, GROUPS[group], desc, m.group(0)])
        marks.sort()
        for a, b in zip(marks, marks[1:]):
            if a[1] > b[0]:
                sys.exit(f"{row['src']}: fields {a[2]} and {b[2]} overlap")

        # Render the cells, opening a field wrapper at its start index and
        # closing it at its end, coalescing runs of identical colour inside.
        starts = {m[0]: m for m in marks}
        ends = {m[1] for m in marks}
        out, cur = [], None

        def flush():
            nonlocal cur
            if cur:
                style = "".join(f"{k}:{v};" for k, v in cur[0].items())
                out.append(f'<span style="{style}">{html.escape(cur[1])}</span>'
                           if style else html.escape(cur[1]))
                cur = None

        for idx, (ch, fg, bg) in enumerate(cells):
            if idx in ends:
                flush(); out.append("</span>")
            if idx in starts:
                flush()
                _, _, num, colour, _, _ = starts[idx]
                out.append(f'<span class="fld" style="--c:{colour}">'
                           f'<i class="badge">{num}</i>')
            key = {}
            if fg: key["color"] = fg
            if bg: key["background"] = bg
            if cur and cur[0] == key:
                cur = (key, cur[1] + ch)
            else:
                flush(); cur = (key, ch)
        flush()
        if len(cells) in ends:
            out.append("</span>")

        cap = (f'<div class="cap">{row["caption"]}</div>'
               if row.get("caption") else "")
        row_html.append(f'<div class="row">{cap}'
                        f'<div class="line">{"".join(out)}</div></div>')
        legend_items += sorted(marks, key=lambda m: m[2])

    legend = "".join(
        f'<li style="--c:{c}"><span class="n">{num}</span>'
        f'<span class="k">{html.escape(txt)}</span> — {desc}</li>'
        for _, _, num, c, desc, txt in legend_items
    )
    note = f'<p class="note">{spec["note"]}</p>' if spec.get("note") else ""
    cols = ' style="columns:1"' if spec.get("one_column") else ""
    return f"""<!doctype html><meta charset="utf-8"><style>{CSS}</style>
<div class="card">
  <h1>{spec['title']}</h1>
  <p class="sub">{spec['subtitle']}</p>
  <div class="term">{''.join(row_html)}</div>
  {note}
  <ol class="legend"{cols}>{legend}</ol>
  <p class="foot">github.com/victorrentea/victor-statusline — figures are synthetic;
     regenerate with docs/screenshots/make-lines.sh + render.py</p>
</div>"""


def main():
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome")
        page = browser.new_page(viewport={"width": 1560, "height": 900},
                                device_scale_factor=2)
        for spec in SPECS:
            page.set_content(build(spec))
            page.wait_for_timeout(120)
            dest = HERE / spec["out"]
            page.locator(".card").screenshot(path=str(dest))
            print(f"wrote {dest.relative_to(HERE.parent.parent)}")
        browser.close()


if __name__ == "__main__":
    main()
