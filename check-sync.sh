#!/bin/sh
# Verify every script in this repo matches the copy embedded in its companion
# doc. Both forms have to exist — the runnable file is what you install, the
# embedded copy is what makes each doc self-contained enough to hand to someone
# (or paste into an agent) on its own — and two copies of anything drift. This
# script is the thing that notices. Exits non-zero on the first mismatch.
#
#   ./check-sync.sh
cd "$(dirname "$0")" || exit 2
python3 - "$@" <<'PY'
import pathlib, sys

# (doc, heading that precedes the fenced block, fence language, script file)
PAIRS = [
    ("claude/victor-claude-statusline.md",  "## The full script", "sh",   "claude/statusline-command.sh"),
    ("copilot/victor-copilot-statusline.md", "## File 1",         "bash", "copilot/statusline.sh"),
    ("copilot/victor-copilot-statusline.md", "## File 2",         "bash", "copilot/quota-refresh.sh"),
]

bad = 0
for doc, heading, lang, script in PAIRS:
    text = pathlib.Path(doc).read_text()
    try:
        i = text.index(heading)
        start = text.index("```" + lang + "\n", i) + len(lang) + 4
        end = text.index("\n```\n", start)
    except ValueError:
        print(f"FAIL  {doc}: no ```{lang} block under '{heading}'")
        bad += 1
        continue
    embedded = text[start:end]
    live = pathlib.Path(script).read_text().rstrip("\n")
    if embedded == live:
        print(f"ok    {script} == '{heading}' in {doc}")
    else:
        print(f"FAIL  {script} differs from the copy under '{heading}' in {doc}")
        bad += 1

sys.exit(1 if bad else 0)
PY
