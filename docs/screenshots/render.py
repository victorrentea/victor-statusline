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
    "#000000", "#cc0000", "#4e9a06", "#c4a000", "#3465a4", "#75507b", "#06989a", "#d3d7cf",
    "#555753", "#ef2929", "#8ae234", "#fce94f", "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec",
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
    (r"\d+K/1M", "model",
     "context tokens used / window size. The used half is blue while healthy and "
     "blinks when it is not; on windows smaller than 1M the segment also gains a "
     "<code>• N%</code>, orange ≥65%, red ≥95%."),
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
     "combinations), so a given folder always looks the same."),
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
             "burning it faster than it drains. The figure turns orange under 15%, red "
             "under 5%."),
            (r"\d+h\d+(?= \|)", "5h",
             "time until the 5-hour window resets. A duration (<code>3h19</code>), never "
             "a clock time — the segment already contains a wall clock when parked, and "
             "<code>3:19</code> would be ambiguous."),
        ] + CLAUDE_SPEND + CLAUDE_LOC + [
            (r"\([+-]?\d+\)", "week",
             "weekly pace, in <b>percentage points</b> off a straight line "
             "(<code>elapsed% − used%</code>). Positive means you are ahead of schedule. "
             "Bracketed and glued to the figure it qualifies rather than given a cell of "
             "its own."),
            (r"(?<=\))\d+%", "week",
             "quota left in the rolling <b>7-day</b> window, same thresholds as the 5h "
             "figure."),
            (r"\d+wd\d+h", "week",
             "<b>working</b> time until the weekly window resets: <code>wd</code> is "
             "weekdays, with Saturday and Sunday subtracted, because a weekend burns no "
             "quota and flattered the number every Monday."),
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
            (r"\d+wd\d+h", "week",
             "working days and hours until the monthly credit quota resets, weekends "
             "again excluded."),
        ],
    ),
]

CSS = """
* { box-sizing: border-box; }
body { margin: 0; background: #ffffff; }
.card { width: 1500px; padding: 34px 40px 34px; background: #0d1117; color: #c9d1d9;
        font-family: -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif; }
h1 { font-size: 25px; margin: 0 0 6px; color: #f0f6fc; font-weight: 600; letter-spacing: -.01em; }
.sub { font-size: 16px; line-height: 1.5; margin: 0; color: #8b949e; max-width: 1180px; }
.term { margin: 46px 0 10px; padding: 18px 22px; background: #010409;
        border: 1px solid #21262d; border-radius: 8px; overflow: visible; }
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
    raw = (LINES / f"{spec['src']}.ansi").read_text()
    cells = parse_ansi(raw)
    plain = "".join(c[0] for c in cells)

    # Locate every annotated field, then check the marks do not overlap: a bad
    # regex silently swallowing a neighbour is the one failure mode that would
    # produce a wrong-but-plausible picture.
    marks = []
    for idx, (pat, group, desc) in enumerate(spec["fields"], 1):
        m = re.search(pat, plain)
        if not m:
            sys.exit(f"{spec['src']}: no match for /{pat}/ in {plain!r}")
        marks.append([m.start(), m.end(), idx, GROUPS[group], desc, m.group(0)])
    marks.sort()
    for a, b in zip(marks, marks[1:]):
        if a[1] > b[0]:
            sys.exit(f"{spec['src']}: fields {a[2]} and {b[2]} overlap")

    # Render the cells, opening a field wrapper at its start index and closing
    # it at its end, and coalescing runs of identical colour inside.
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

    for i, (ch, fg, bg) in enumerate(cells):
        if i in ends:
            flush(); out.append("</span>")
        if i in starts:
            flush()
            _, _, n, colour, _, _ = starts[i]
            out.append(f'<span class="fld" style="--c:{colour}">'
                       f'<i class="badge">{n}</i>')
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

    legend = "".join(
        f'<li style="--c:{c}"><span class="n">{n}</span>'
        f'<span class="k">{html.escape(txt)}</span> — {desc}</li>'
        for _, _, n, c, desc, txt in sorted(marks, key=lambda m: m[2])
    )
    note = f'<p class="note">{spec["note"]}</p>' if spec.get("note") else ""
    return f"""<!doctype html><meta charset="utf-8"><style>{CSS}</style>
<div class="card">
  <h1>{spec['title']}</h1>
  <p class="sub">{spec['subtitle']}</p>
  <div class="term"><div class="line">{''.join(out)}</div></div>
  {note}
  <ol class="legend">{legend}</ol>
  <p class="foot">github.com/victorrentea/victor-statusline — figures are synthetic;
     regenerate with docs/screenshots/make-lines.sh + render.py</p>
</div>"""


def main():
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome")
        page = browser.new_page(viewport={"width": 1500, "height": 900},
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
