#!/bin/sh
# Minimal regression harness for claude/statusline-command.sh: feeds sample
# JSON payloads (what Claude Code hands the script on stdin) and asserts
# substrings in the rendered line, so the quota/park rendering is checked by
# an assertion instead of by eye. Not a general test framework -- just enough
# to keep the paused-on-quota segment (and the plain 5h segment next to it)
# from silently regressing.
#
# Runs in a throwaway $HOME so it never touches the real quota-park/cwd state
# under ~/.claude, and cleans up its /tmp state files (those are keyed by
# session_id and hardcoded to /tmp inside the script itself, HOME override or
# not -- see the "why /tmp and not $HOME" note in the script for cost/turn
# caching).
#
#   ./claude/test-statusline.sh
cd "$(dirname "$0")/.." || exit 2
SCRIPT="$PWD/claude/statusline-command.sh"

TMP=$(mktemp -d)
cleanup() {
  rm -rf "$TMP"
  rm -f /tmp/claude-statusline-*-statusline-test-*.txt 2>/dev/null
  rm -f /tmp/claude-turn-statusline-test-*.state 2>/dev/null
}
trap cleanup EXIT INT TERM
export HOME="$TMP"
mkdir -p "$HOME/.claude"

pass=0
fail=0

# strip_ansi + assert_contains "<label>" "<haystack>" "<needle>"
assert_contains() {
  label=$1; haystack=$2; needle=$3
  plain=$(printf '%s' "$haystack" | sed 's/\x1b\[[0-9;]*m//g')
  case "$plain" in
    *"$needle"*) pass=$((pass + 1)); printf 'ok    %s\n' "$label" ;;
    *)
      fail=$((fail + 1))
      printf 'FAIL  %s\n      expected to find: %s\n      got:              %s\n' \
        "$label" "$needle" "$plain"
      ;;
  esac
}

assert_not_contains() {
  label=$1; haystack=$2; needle=$3
  plain=$(printf '%s' "$haystack" | sed 's/\x1b\[[0-9;]*m//g')
  case "$plain" in
    *"$needle"*)
      fail=$((fail + 1))
      printf 'FAIL  %s\n      expected NOT to find: %s\n      got:                  %s\n' \
        "$label" "$needle" "$plain"
      ;;
    *) pass=$((pass + 1)); printf 'ok    %s\n' "$label" ;;
  esac
}

# Expected wall clock for an epoch, on whichever `date` this machine has: BSD/macOS
# spells it `-r EPOCH`, GNU/Linux `-d @EPOCH` (see fmt_epoch in the script;
# claude/test-date-fallback.sh is what tests the script's own fallback).
clock_of() { date -r "$1" "$2" 2>/dev/null || date -d "@$1" "$2"; }

now=$(date +%s)
reset=$((now + 3 * 3600 + 23 * 60))   # 3h23m from now

# --- Case 1: normal 5h quota, this terminal NOT parked -----------------------
payload=$(cat <<JSON
{"session_id":"statusline-test-normal","model":{"display_name":"Claude Opus"},
 "context_window":{},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains    "normal: quota-left percentage"     "$out" "60%"
assert_contains    "normal: window countdown"           "$out" "3h2"
assert_not_contains "normal: no pause glyph when awake" "$out" "💤"

# --- Case 2: quota exhausted AND parked by quota-gate.sh ---------------------
session="statusline-test-parked"
wake=$((now + 45 * 60 + 12))          # 45m12s from now
mkdir -p "$HOME/.claude/quota-park"
printf '%s' "$wake" > "$HOME/.claude/quota-park/$session"
back=$(clock_of "$wake" +%H:%M)
payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Claude Opus"},
 "context_window":{},
 "rate_limits":{"five_hour":{"used_percentage":98,"resets_at":$reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "parked: pause glyph present"        "$out" "💤"
assert_contains "parked: absolute local wake clock"  "$out" "$back"
assert_contains "parked: glyph glued to the percentage" "$out" "%💤"
assert_contains "parked: next probe precedes the reset countdown" "$out" "%💤 → $back /"
assert_not_contains "parked: no second sleep countdown"  "$out" "45m"

# --- Case 3: a park marker whose wake time has ALREADY passed (stale/woken) --
# quota-gate.sh's own trap removes this file on exit, but the render must not
# show a pause state, whether the file lingers or not.
session="statusline-test-woken"
mkdir -p "$HOME/.claude/quota-park"
printf '%s' "$((now - 60))" > "$HOME/.claude/quota-park/$session"
payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Claude Opus"},
 "context_window":{},
 "rate_limits":{"five_hour":{"used_percentage":98,"resets_at":$reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_not_contains "woken: no pause glyph once wake time has passed" "$out" "💤"

# --- Case 4: weekly quota exhausted and parked by quota-gate.sh -------------
# Window-aware markers put the sleep state on the quota that caused it. The
# weekly probe clock includes a weekday so an hour crossing midnight is clear.
session="statusline-test-weekly-parked"
week_reset=$((now + 2 * 86400 + 47 * 60))
wake=$((week_reset + 12))
mkdir -p "$HOME/.claude/quota-park"
printf '%s seven_day' "$wake" > "$HOME/.claude/quota-park/$session"
back=$(clock_of "$wake" '+%a %H:%M')
payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Claude Opus"},
 "context_window":{},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset},
                "seven_day":{"used_percentage":100,"resets_at":$week_reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "weekly parked: glyph glued to weekly percentage" "$out" "0%💤"
assert_contains "weekly parked: wake clock includes weekday"      "$out" "→ $back"
assert_not_contains "weekly parked: five-hour percentage stays awake" "$out" "60%💤"

# --- Case 5: a probe reading outranks a frozen session payload --------------
# The plan-switch bug of 2026-09-11 (Max 5x -> 20x): an idle terminal keeps
# re-publishing the payload it was handed before the allowance grew, and by
# value that old, higher figure wins the merge on every render. quota-probe.sh
# writes the account's real number with source=probe, and quota-state.sh must
# refuse to let a NON-fresh session reading displace it. Needs the real
# quota-state.sh under this throwaway HOME; quota-probe.sh is deliberately
# absent, so the render never fires a network request from a test.
STATE="$PWD/claude/hooks/quota-state.sh"
mkdir -p "$HOME/.claude/hooks"
ln -s "$STATE" "$HOME/.claude/hooks/quota-state.sh"
session="statusline-test-weekly-probe"
rm -f "/tmp/claude-statusline-rl-$session.txt"
payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Claude Opus"},
 "context_window":{},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset},
                "seven_day":{"used_percentage":94,"resets_at":$week_reset}}}
JSON
)
# First render: nothing stored and a payload never seen -> fresh, and 94 lands.
# This is the pre-upgrade state every terminal was in.
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "probe: the frozen payload paints the old plan's number first" "$out" "6% /"
# The probe arrives with the account's real figure.
"$STATE" set -1 0 9 "$week_reset" >/dev/null
# Same bytes again -> non-fresh -> the measurement holds, whatever the cache says.
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "probe: the measured 9% used replaces the frozen 94%" "$out" "91% /"
assert_not_contains "probe: the old plan's number is gone" "$out" "6% /"

# Protection lasts two probe intervals (the probe runs every one). Past that the
# probe reading is as old as anything else and value order resumes -- the
# deliberate fallback when the probe keeps failing.
jq '.seven_day.measured_at -= 601' "$HOME/.claude/quota.json" > "$HOME/.claude/quota.json.new" \
  && mv "$HOME/.claude/quota.json.new" "$HOME/.claude/quota.json"
out=$(printf '%s' "$payload" | env -u CLAUDE_QUOTA_PROBE_SECS -u CLAUDE_WEEKLY_QUOTA_PROBE_SECS sh "$SCRIPT")
assert_contains "probe: an aged-out probe reading yields to value order again" "$out" "6% /"
rm -f "$HOME/.claude/hooks/quota-state.sh" "$HOME/.claude/quota.json"

# --- Case 6: the per-model weekly cap rides beside the account weekly -------
# An account can hold two weekly budgets: the account-wide one and a per-model
# cap with its own allowance (Fable's, since 2026-09). quota-probe.sh used to
# write whichever was TIGHTER into `seven_day`, so on 2026-09-21 the bar read
# "86% left" while /usage said 92% -- Fable's budget wearing the account's
# label, with nothing on screen to tell them apart. The account figure is the
# weekly number now; the scoped cap is a chip carrying the model's initial.
STATE="$PWD/claude/hooks/quota-state.sh"
mkdir -p "$HOME/.claude/hooks"
ln -s "$STATE" "$HOME/.claude/hooks/quota-state.sh"
session="statusline-test-weekly-scoped"
rm -f "/tmp/claude-statusline-rl-$session.txt"
payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Claude Opus"},
 "context_window":{},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset},
                "seven_day":{"used_percentage":8,"resets_at":$week_reset}}}
JSON
)
"$STATE" set -1 0 8 "$week_reset" 14 "$week_reset" Fable >/dev/null
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "scoped cap: the weekly figure is the ACCOUNT's"    "$out" "92%"
# Fable's cap is not an Opus session's business: no chip there.
assert_not_contains "scoped cap: another model's cap stays off the bar" "$out" "(F86%)"
fable_payload=$(printf '%s' "$payload" | sed 's/"Claude Opus"/"Claude Fable"/')
out=$(printf '%s' "$fable_payload" | sh "$SCRIPT")
assert_contains "scoped cap: the model's own budget rides beside it" "$out" "(F86%)"

# The chip belongs to the model, so the park it causes belongs to the chip --
# hanging the glyph on the account figure would name the wrong budget.
mkdir -p "$HOME/.claude/quota-park"
printf '%s weekly_scoped' "$((week_reset + 12))" > "$HOME/.claude/quota-park/$session"
"$STATE" set -1 0 8 "$week_reset" 100 "$week_reset" Fable >/dev/null
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "scoped cap: the park glyph sits inside the chip" "$out" "F0%💤"
assert_not_contains "scoped cap: the account weekly stays awake"  "$out" "92%💤"
rm -f "$HOME/.claude/quota-park/$session"

# A reading whose weekly window has already turned over is last week's budget.
"$STATE" set -1 0 8 "$week_reset" 14 "$((now - 60))" Fable >/dev/null
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_not_contains "scoped cap: a reading past its reset is dropped" "$out" "(F"

# An account with no per-model cap shows exactly the cell it always had.
rm -f "$HOME/.claude/quota.json"
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_not_contains "scoped cap: no cap, no chip" "$out" "(F"
rm -f "$HOME/.claude/hooks/quota-state.sh" "$HOME/.claude/quota.json"

# --- Case: subagents in flight ----------------------------------------------
# Builds a session directory shaped like the one Claude Code writes -- a parent
# transcript plus <sid>/subagents/agent-<id>.{meta.json,jsonl} -- and checks the
# three judgements the chip has to make: who is still running, what each one is
# running on, and how the groups collapse.
session="statusline-test-subagents"
proj="$HOME/.claude/projects/test"
sub="$proj/$session/subagents"
mkdir -p "$sub"
tp="$proj/$session.jsonl"

# Every line carries a UTC stamp: an agent counts as stopped only when its
# newest stop-marker is at least as recent as the last line it wrote itself.
# Agents write at 10:00; markers land from 10:05 on; a wake writes later still.
T0='"timestamp":"2026-09-20T10:00:00.000Z",'
# A line the agent itself writes when something wakes it, stamped at 10:MM.
wake() {
  printf '{"type":"assistant","timestamp":"2026-09-20T10:%s:00.000Z","agentId":"%s","message":{"role":"assistant"}}\n' "$2" "$1" >> "$sub/agent-$1.jsonl"
}

# id / model / effort ("-" = none, as Haiku writes it) / requested-alias
mk_agent() {
  printf '{"agentType":"general-purpose","description":"t","toolUseId":"toolu_%s","spawnDepth":1,"model":"%s"}' \
    "$1" "$4" > "$sub/agent-$1.meta.json"
  eff=",\"effort\":\"$3\""
  [ "$3" = "-" ] && eff=""
  printf '{"type":"user",%s"isSidechain":true,"agentId":"%s","message":{"role":"user"}}\n{"type":"assistant",%s"agentId":"%s"%s,"message":{"role":"assistant","model":"%s"}}\n' \
    "$T0" "$1" "$T0" "$1" "$eff" "$2" > "$sub/agent-$1.jsonl"
}
mk_agent A claude-opus-5              high   opus
mk_agent B claude-opus-5              high   opus
mk_agent C claude-sonnet-5            medium sonnet
mk_agent D claude-opus-5              high   opus
mk_agent E claude-haiku-4-5-20251001  -      haiku
mk_agent F claude-fable-5-1           high   fable
mk_agent G claude-opus-5              high   opus

{
  # The spawn itself: tool_use blocks carry the id as "id", never as
  # "tool_use_id", so none of these may read as a finished agent.
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_A","name":"Task"},{"type":"tool_use","id":"toolu_D","name":"Task"}]}}\n'
  # D returned; E was launched async in the SAME user turn. The launch receipt
  # must not be mistaken for D's result, nor D's result for E's.
  printf '{"type":"user","timestamp":"2026-09-20T10:05:00.000Z","message":{"content":[{"tool_use_id":"toolu_D","type":"tool_result","content":"the report"},{"tool_use_id":"toolu_E","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully. agentId: E"}]}]}}\n'
  # F was launched async and has since notified that it stopped.
  printf '{"type":"user","message":{"content":[{"tool_use_id":"toolu_F","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully. agentId: F"}]}]}}\n'
  printf '{"type":"user","timestamp":"2026-09-20T10:05:00.000Z","message":{"content":"<task-notification>\\n<task-id>F</task-id>\\n<tool-use-id>toolu_F</tool-use-id>\\n<status>completed</status>\\n</task-notification>"}}\n'
} > "$tp"

# G never got a marker but has been silent for hours: a corpse, not a worker.
touch -t 202001010000 "$sub/agent-G.jsonl"

payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Opus 5 (1M context)"},
 "effort":{"level":"high"},"transcript_path":"$tp",
 "context_window":{"used_percentage":6,"context_window_size":1000000},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains     "subagents: groups by model+effort, biggest first" "$out" "+{O5h×2,H4.5,S5m}"
assert_not_contains "subagents: no effort letter is invented for Haiku" "$out" "H4.5h"
assert_contains     "subagents: chip hangs off the model segment"      "$out" "60K +{"
assert_not_contains "subagents: a returned Task is gone"               "$out" "×3"
assert_not_contains "subagents: a notified async agent is gone"        "$out" "F5.1"
assert_not_contains "subagents: a silent corpse is not counted"        "$out" "×4"

# Second render, same state: the per-agent facts now come from the cache file
# rather than from re-reading seven agent transcripts. Same answer either way.
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "subagents: cached second render is identical" "$out" "+{O5h×2,H4.5,S5m}"

# --- Case 7: a done-marker that has scrolled out of the scanned tail ---------
# Only the last $CLAUDE_SUB_TAIL bytes of the parent transcript are read, and a
# busy session writes past its own markers. Once F's notification falls outside
# that window the scan can no longer see that F ever stopped -- unless the first
# render wrote the id down. This is the bug that had a finished async agent
# sitting in the chip for a quarter of an hour (10 Sep 2026).
session="statusline-test-scrolled"
sub="$proj/$session/subagents"
mkdir -p "$sub"
tp="$proj/$session.jsonl"
mk_agent F claude-fable-5-1 high fable
{
  printf '{"type":"user","message":{"content":[{"tool_use_id":"toolu_F","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully. agentId: F"}]}]}}\n'
  printf '{"type":"user","timestamp":"2026-09-20T10:05:00.000Z","message":{"content":"<task-notification>\\n<task-id>F</task-id>\\n<tool-use-id>toolu_F</tool-use-id>\\n<status>completed</status>\\n</task-notification>"}}\n'
  # Everything after the marker: enough of it to push the marker out of a small tail.
  i=0
  while [ "$i" -lt 200 ]; do
    printf '{"type":"assistant","message":{"content":"padding padding padding padding padding padding padding padding"}}\n'
    i=$((i + 1))
  done
} > "$tp"

payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Opus 5 (1M context)"},
 "effort":{"level":"high"},"transcript_path":"$tp",
 "context_window":{"used_percentage":6,"context_window_size":1000000},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset}}}
JSON
)
# First render: the marker is still inside a generous tail, so F is seen to stop.
out=$(printf '%s' "$payload" | CLAUDE_SUB_TAIL=2000000 sh "$SCRIPT")
assert_not_contains "scrolled: marker inside the tail retires the agent" "$out" "F5.1"
# Second render, tail now too small to reach the marker. Without the remembered
# id, F comes back from the dead and the chip lies until the mtime floor.
out=$(printf '%s' "$payload" | CLAUDE_SUB_TAIL=4000 sh "$SCRIPT")
assert_not_contains "scrolled: marker outside the tail stays retired" "$out" "F5.1"
assert_not_contains "scrolled: no chip left at all"                   "$out" "+{"

# --- Case 8: an async agent resumed with SendMessage ------------------------
# The first stop earns the agent a marker, and the marker is remembered. A
# SendMessage addressed to its id restarts it under the same toolUseId, so the
# remembered marker alone would hide it for the rest of the session while it
# works (13 Sep 2026: chip showed one agent, the native list two). A resume seen
# AFTER the last marker means live again; the next stop retires it once more.
session="statusline-test-resumed"
sub="$proj/$session/subagents"
mkdir -p "$sub"
tp="$proj/$session.jsonl"
mk_agent F claude-fable-5-1 high fable
{
  printf '{"type":"user","message":{"content":[{"tool_use_id":"toolu_F","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully. agentId: F"}]}]}}\n'
  printf '{"type":"user","timestamp":"2026-09-20T10:05:00.000Z","message":{"content":"<task-notification>\\n<task-id>F</task-id>\\n<tool-use-id>toolu_F</tool-use-id>\\n<status>completed</status>\\n</task-notification>"}}\n'
} > "$tp"
payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Opus 5 (1M context)"},
 "effort":{"level":"high"},"transcript_path":"$tp",
 "context_window":{"used_percentage":6,"context_window_size":1000000},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_not_contains "resumed: the first stop retires the agent" "$out" "F5.1"
# Enough traffic to push that marker out of a small tail, then the resume. The
# remembered id says done; the resume inside the window must win over it.
i=0
while [ "$i" -lt 200 ]; do
  printf '{"type":"assistant","message":{"content":"padding padding padding padding padding padding padding padding"}}\n' >> "$tp"
  i=$((i + 1))
done
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_S1","name":"SendMessage","input":{"to":"F","summary":"one more thing","message":"carry on"}}]}}\n' >> "$tp"
wake F 10
out=$(printf '%s' "$payload" | CLAUDE_SUB_TAIL=4000 sh "$SCRIPT")
assert_contains "resumed: a SendMessage after the marker brings it back" "$out" "+{F5.1h}"
# The second stop: same toolUseId, new notification, later than the resume.
printf '{"type":"user","timestamp":"2026-09-20T10:20:00.000Z","message":{"content":"<task-notification>\\n<task-id>F</task-id>\\n<tool-use-id>toolu_F</tool-use-id>\\n<status>completed</status>\\n</task-notification>"}}\n' >> "$tp"
# A message to something that is not one of our agents changes nothing.
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_S2","name":"SendMessage","input":{"to":"reviewer","message":"ping"}}]}}\n' >> "$tp"
out=$(printf '%s' "$payload" | CLAUDE_SUB_TAIL=4000 sh "$SCRIPT")
assert_not_contains "resumed: the second stop retires it again"        "$out" "F5.1"
assert_not_contains "resumed: a message to a stranger revives nothing" "$out" "+{"

# --- Case 9: a slash-command forked into the background ---------------------
# /code-review run in the background is an agent like any other -- its own
# transcript, its own line in the native list as @code-review-2 -- but its
# meta.json carries a "name" and no "toolUseId" whatsoever. A scan keyed on that
# one field dropped it before it was ever counted, and the chip stayed blank
# through an hour-long review (15 Sep 2026). Such an agent is keyed on its own
# agentId, retired on the <task-id> of its notification, and resumable by name.
session="statusline-test-forked-skill"
sub="$proj/$session/subagents"
mkdir -p "$sub"
tp="$proj/$session.jsonl"

# id / @name / model / effort. No toolUseId and no model alias: exactly the
# shape Claude Code writes for a forked skill.
mk_forked() {
  printf '{"agentType":"general-purpose","description":"/code-review main","name":"%s","spawnDepth":1,"requestShape":"background","requestNonInteractive":true}' \
    "$2" > "$sub/agent-$1.meta.json"
  printf '{"type":"user",%s"isSidechain":true,"agentId":"%s","message":{"role":"user"}}\n{"type":"assistant",%s"agentId":"%s","effort":"%s","message":{"role":"assistant","model":"%s"}}\n' \
    "$T0" "$1" "$T0" "$1" "$4" "$3" > "$sub/agent-$1.jsonl"
}
mk_forked P code-review   claude-opus-5   high
mk_forked Q code-review-2 claude-sonnet-5 medium
{
  # The launch receipt. It names the agent under "agentId", and its own
  # tool_use_id belongs to the Skill call, not to the agent -- so it can never
  # read as that agent stopping.
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_P","content":"Skill launched (forked execution, running in the background).\\n\\nRunning in the background as @code-review"}]},"toolUseResult":{"status":"forked","background":true,"agentId":"P"}}\n'
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_Q","content":"Skill launched (forked execution, running in the background).\\n\\nRunning in the background as @code-review-2"}]},"toolUseResult":{"status":"forked","background":true,"agentId":"Q"}}\n'
} > "$tp"

payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Opus 5 (1M context)"},
 "effort":{"level":"high"},"transcript_path":"$tp",
 "context_window":{"used_percentage":6,"context_window_size":1000000},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "forked skill: an agent with no toolUseId is still counted" "$out" "+{O5h,S5m}"

# P stops. Its notification carries the launch tool-use-id, which is NOT the key
# here, and the agent id, which is -- so this retires it only via <task-id>.
printf '{"type":"user","timestamp":"2026-09-20T10:05:00.000Z","message":{"content":"<task-notification>\\n<task-id>P</task-id>\\n<tool-use-id>toolu_P</tool-use-id>\\n<status>killed</status>\\n</task-notification>"}}\n' >> "$tp"
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_not_contains "forked skill: its notification retires it by task-id" "$out" "O5h"
assert_contains     "forked skill: the one still working stays"            "$out" "+{S5m}"

# Resumed the way Victor actually resumes one of these: by @name, not by id.
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_S3","name":"SendMessage","input":{"to":"code-review","message":"carry on"}}]}}\n' >> "$tp"
wake P 10
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains "forked skill: a SendMessage to its @name brings it back" "$out" "+{O5h,S5m}"

# A session that never spawned anything renders no chip at all.
session="statusline-test-no-subagents"
tp="$proj/$session.jsonl"
printf '{"type":"assistant","message":{"content":[]}}\n' > "$tp"
payload=$(cat <<JSON
{"session_id":"$session","model":{"display_name":"Opus 5 (1M context)"},
 "effort":{"level":"high"},"transcript_path":"$tp",
 "context_window":{"used_percentage":6,"context_window_size":1000000},
 "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":$reset}}}
JSON
)
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_not_contains "no subagents: no chip, no placeholder" "$out" "+{"
assert_not_contains "no subagents: placeholder is resolved" "$out" "@@SUB@@"

# --- Case: the prompt-cache miss is priced at the model's own rates ---------
# Recorded usage from a real Opus 5.5 turn (2026-09-30, a 1h-TTL session that
# came back after an expired cache): the request before the turn had a 227,473
# token prompt; the turn's one request read back only the 25,144-token system
# prefix and rewrote 202,810 tokens into the 1h bucket. At the pricing page's
# Opus 5.5 rates ($4 in, $8 1h-write, $0.20 read, $20 out) that request cost
#   2*4 + 216*20 + 25144*0.20 + 202810*8 = $1.632 (per 1e6)
# and the miss inside it -- the old prefix written instead of read -- was
#   (227473 - 25144) * (8 - 0.20) / 1e6 = $1.58.
# The bar used to print "$1.6(2.2⏱)": Opus at a flat $5, reads at 0.1x, and the
# whole previous prompt counted as lost -- a miss dearer than its own turn.
# usage_line <requestId> <in> <read> <write> <w1h> <w5m> <out> <stop> <HH:MM>
usage_line() {
  printf '{"type":"assistant","uuid":"a-%s","requestId":"%s","timestamp":"2026-09-20T%s:00.000Z","message":{"role":"assistant","stop_reason":"%s","content":[],"usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"cache_creation":{"ephemeral_1h_input_tokens":%s,"ephemeral_5m_input_tokens":%s},"output_tokens":%s}}}\n' \
    "$1" "$1" "$9" "$8" "$2" "$3" "$4" "$5" "$6" "$7"
}
prompt_line() {
  printf '{"type":"user","uuid":"%s","timestamp":"2026-09-20T%s:00.000Z","message":{"role":"user","content":"%s"}}\n' "$1" "$2" "$1"
}
# cache_turn <session> <model id> <display name> <prev usage...> -- <cur usage...>
# Two renders, as Claude Code does: the turn price is the delta of total_cost_usd.
render_twice() {  # 1=session 2=model-id 3=display 4=cost-before 5=cost-after 6=total_input_tokens
  rm -f /tmp/claude-statusline-*-"$1".txt /tmp/claude-turn-"$1".state 2>/dev/null
  _p='{"session_id":"%s","model":{"id":"%s","display_name":"%s"},"effort":{"level":"xhigh"},"transcript_path":"%s","context_window":{"used_percentage":23,"context_window_size":1000000,"total_input_tokens":%s},"cost":{"total_cost_usd":%s}}'
  printf "$_p" "$1" "$2" "$3" "$proj/$1.jsonl" "$6" "$4" | sh "$SCRIPT" >/dev/null
  printf "$_p" "$1" "$2" "$3" "$proj/$1.jsonl" "$6" "$5" | sh "$SCRIPT"
}

session="statusline-test-miss-opus55"
{
  prompt_line u0 09:00
  usage_line r0 2 25144 202327 202327 0 400 end_turn 09:01
  prompt_line u1 10:00
  usage_line r1 2 25144 202810 202810 0 216 end_turn 10:01
} > "$proj/$session.jsonl"
out=$(render_twice "$session" "claude-opus-5-5[1m]" "Opus 5.5 (1M context)" 12.000 13.632 227956)
assert_contains     "miss, Opus 5.5: turn price is Claude Code's own delta" "$out" '$1.6('
assert_contains     "miss, Opus 5.5: the rebuild is priced at \$4 x (2 - 0.05)" "$out" '(1.6⏱)'
assert_not_contains "miss, Opus 5.5: not the old flat \$5 x 1.9 over the whole prompt" "$out" '(2.2⏱)'
# The idle forecast: 227,956 live minus the 25,144 a cold start still reads.
assert_contains     "miss, Opus 5.5: forecast excludes the prefix that survives" "$out" '⇒+=$1.6)'

# A session resumed inside the TTL opens with a WARM read of the whole prefix.
# That is not what survives an expiry, so it must not be subtracted: with no
# cold request seen, the forecast prices the whole 201K prompt ($1.57).
session="statusline-test-warm-resume"
{
  prompt_line u0 09:00
  usage_line r0 2 200000 1000 1000 0 300 end_turn 09:01
} > "$proj/$session.jsonl"
out=$(render_twice "$session" "claude-opus-5-5[1m]" "Opus 5.5 (1M context)" 2.000 2.100 201002)
assert_contains     "warm resume: a warm first read is not the survivor" "$out" '⇒+=$1.6)'

# The same usage on Opus 5 must price at Opus 5's $5 and 0.1x reads: the
# "opus-5" pattern is a prefix of "opus-5-5", so the order of the cases matters.
session="statusline-test-miss-opus5"
cp "$proj/statusline-test-miss-opus55.jsonl" "$proj/$session.jsonl"
out=$(render_twice "$session" "claude-opus-5[1m]" "Opus 5 (1M context)" 12.000 14.000 227956)
assert_contains     "miss, Opus 5: 202,329 x \$5 x (2 - 0.1) = \$1.92" "$out" '(1.9⏱)'

# A 5m-bucket rebuild on Sonnet 5.5 ($2, 1.25x write, 0.1x read), capped at what
# was cached before: 100,000 x 2 x 1.15 = $0.23, not the 100,500 it wrote.
session="statusline-test-miss-sonnet-5m"
{
  prompt_line u0 09:00
  usage_line r0 0 99000 1000 0 1000 300 end_turn 09:01
  prompt_line u1 10:00
  usage_line r1 0 0 100500 0 100500 300 end_turn 10:01
} > "$proj/$session.jsonl"
out=$(render_twice "$session" "claude-sonnet-5-5" "Sonnet 5.5" 1.000 1.300 100500)
assert_contains     "miss, 5m bucket: priced at the 5m write, capped at the old prefix" "$out" '(0.2⏱)'

# A /compact is not a miss: the prompt SHRANK from 976K to 77K and read back
# only the system prefix, which the old rule priced as "$1.1(9.3⏱)".
session="statusline-test-compact"
{
  prompt_line u0 09:00
  usage_line r0 2 970000 6331 6331 0 400 end_turn 09:01
  prompt_line u1 10:00
  usage_line r1 2 30026 47314 47314 0 900 end_turn 10:01
} > "$proj/$session.jsonl"
out=$(render_twice "$session" "claude-opus-5-5[1m]" "Opus 5.5 (1M context)" 40.000 41.129 77342)
assert_not_contains "compaction: a shrunken prompt is not a cache miss" "$out" '⏱'

# A healthy turn reads the prefix back and carries no tag at all.
session="statusline-test-cache-hit"
{
  prompt_line u0 09:00
  usage_line r0 2 150000 5000 5000 0 400 end_turn 09:01
  prompt_line u1 09:03
  usage_line r1 2 155000 900 900 0 300 end_turn 09:04
} > "$proj/$session.jsonl"
out=$(render_twice "$session" "claude-opus-5-5[1m]" "Opus 5.5 (1M context)" 5.000 5.200 155902)
assert_not_contains "cache hit: no miss tag" "$out" '⏱'

# --- Case: the placeholder before the turn's first cost ----------------------
# Working (the prompt is the last line, nothing answered yet) and the session
# total has not moved: exactly four stars hold the slot -- as wide as the
# "✻0.5" they stand in for, so the total does not move when the figure lands;
# never one flower, never the flower repeated to pad it.
session="statusline-test-placeholder"
{
  prompt_line u0 09:00
  usage_line r0 2 50000 1000 1000 0 300 end_turn 09:01
  prompt_line u1 09:05
} > "$proj/$session.jsonl"
out=$(render_twice "$session" "claude-opus-5-5[1m]" "Opus 5.5 (1M context)" 3.000 3.000 51002)
assert_contains     "placeholder: four stars before the turn has a cost" "$out" '★★★★ ⊂ $3.0'
assert_not_contains "placeholder: exactly four" "$out" '★★★★★'
for _g in '·' '✢' '✳' '✻' '✽'; do
  assert_not_contains "placeholder: no lone flower ($_g)" "$out" " $_g ⊂"
done
# Once the first cost lands, the figure replaces the stars.
out=$(render_twice "$session" "claude-opus-5-5[1m]" "Opus 5.5 (1M context)" 3.000 3.500 51002)
assert_not_contains "placeholder: gone once a figure exists" "$out" '★'
assert_contains     "placeholder: the live figure takes its place" "$out" '0.5 ⊂ $3.5'

# --- Case: the week's spend at API prices, read from the once-a-day cache -----
# The bar never counts: it reads ~/.claude/week-spend and prints "$N/Nd" only
# when the cache is keyed to THIS window and TODAY. A stale key (yesterday's
# line) must not print -- that would be yesterday's figure under today's label.
wreset=$((now + 3 * 86400))
payload=$(cat <<JSON
{"session_id":"statusline-test-weekspend","model":{"display_name":"Claude Opus"},
 "context_window":{},
 "rate_limits":{"seven_day":{"used_percentage":40,"resets_at":$wreset}}}
JSON
)
printf '%s %s 1839.62 4.0\n' "$((wreset - 604800))" "$(date +%F)" > "$HOME/.claude/week-spend"
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_contains     "week spend: dollars over days, last cell" "$out" ' $1840/4d'
assert_not_contains "week spend: no pipe before it" "$out" '| $1840'
printf '%s 1999-01-01 1839.62 4.0\n' "$((wreset - 604800))" > "$HOME/.claude/week-spend"
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_not_contains "week spend: a stale day prints nothing" "$out" '$1840'
printf '%s %s 0.00 0.0\n' "$((wreset - 604800))" "$(date +%F)" > "$HOME/.claude/week-spend"
out=$(printf '%s' "$payload" | sh "$SCRIPT")
assert_not_contains "week spend: no complete day yet prints nothing" "$out" '/0d'
rm -f "$HOME/.claude/week-spend"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
