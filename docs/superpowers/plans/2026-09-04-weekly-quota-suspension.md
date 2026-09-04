# Weekly Quota Suspension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pause every Claude Code request when the weekly quota has 1% or less remaining, while preserving the existing 5-hour gate.

**Architecture:** Extend `quota-gate.sh` to evaluate the existing machine-wide five-hour and seven-day records independently, selecting the latest reset among exhausted windows because work can resume only after every limiting window clears. Store the selected window beside the wake epoch so the status line can attach its sleep indicator to the quota that caused the pause. Keep the five-hour threshold and freshness behavior unchanged; the weekly rule uses its own 1% threshold and trusts a low cached reading until its reset because usage cannot decrease inside that window.

**Tech Stack:** POSIX-style shell, `jq`, `awk`, Claude Code hooks, shell regression harnesses.

---

### Task 1: Capture weekly gating as a regression

**Files:**
- Create: `claude/test-quota-gate.sh`
- Modify: `claude/test-statusline.sh`

- [ ] **Step 1: Write a failing gate test**

Create a temporary Claude home and quota JSON with five-hour usage below its existing threshold and seven-day usage at 99%. Start the real gate in the background, assert that it creates `<wake> seven_day`, then terminate the test-owned sleeper. Add a companion case proving 98% weekly usage does not park.

- [ ] **Step 2: Run the gate test to verify RED**

Run: `./claude/test-quota-gate.sh`

Expected: FAIL because the current hook calls only `quota-state.sh read` and creates no weekly park marker.

- [ ] **Step 3: Write a failing status-line test**

Feed the real status-line script a payload with a `seven_day` park marker and assert that `💤` is glued to the weekly percentage, not the five-hour percentage, and that the weekly wake time includes weekday plus local clock.

- [ ] **Step 4: Run the status-line test to verify RED**

Run: `./claude/test-statusline.sh`

Expected: FAIL because the current renderer treats every marker as a bare five-hour wake epoch.

### Task 2: Implement window-aware suspension

**Files:**
- Modify: `claude/hooks/quota-gate.sh`
- Modify: `/Users/victorrentea/.claude/hooks/quota-gate.sh`
- Modify: `claude/statusline-command.sh`
- Modify: `/Users/victorrentea/.claude/settings.json`

- [ ] **Step 1: Select the limiting exhausted window**

Keep the existing five-hour eligibility predicate unchanged. Add a seven-day predicate using `quota-state.sh read7` and `(100 - used) <= CLAUDE_WEEKLY_QUOTA_MIN_PCT`, defaulting to 1. If both windows qualify, choose the later reset.

- [ ] **Step 2: Persist the window and allow a weekly sleep**

Write markers as `<wake> <five_hour|seven_day>`, raise `CLAUDE_QUOTA_MAX_SLEEP` to 604920 seconds, and include the window in gate log records.

- [ ] **Step 3: Render the pause on the matching segment**

Read the marker once. Treat old one-field markers as `five_hour`. Preserve the current five-hour shape; for `seven_day`, render `💤 → Mon 00:00` beside the weekly percentage.

- [ ] **Step 4: Raise the three live Claude hook timeouts**

Change each quota-gate hook timeout from 21600 to 605040 (two minutes above the script's maximum sleep) and make its status message window-neutral: `💤 quota exhausted — waiting for it to reset`.

- [ ] **Step 5: Run focused tests to verify GREEN**

Run: `./claude/test-quota-gate.sh && ./claude/test-statusline.sh`

Expected: both harnesses exit 0 with no failed assertions.

### Task 3: Synchronize documentation and verify the live installation

**Files:**
- Modify: `claude/victor-claude-statusline.md`

- [ ] **Step 1: Document weekly suspension behavior**

Rewrite the parked-quota and weekly-quota prose to distinguish five-hour and weekly markers, explain the 1% weekly threshold, and explain why the weekly reset can require a multi-day hook timeout.

- [ ] **Step 2: Synchronize the embedded full script**

Apply the same renderer changes to the fenced script under `## The full script`.

- [ ] **Step 3: Verify all copies and syntax**

Run: `sh -n claude/hooks/quota-gate.sh claude/statusline-command.sh claude/test-quota-gate.sh claude/test-statusline.sh && cmp claude/hooks/quota-gate.sh "$HOME/.claude/hooks/quota-gate.sh" && jq empty "$HOME/.claude/settings.json" && ./check-sync.sh && ./claude/test-quota-gate.sh && ./claude/test-statusline.sh`

Expected: exit 0, all sync checks report `ok`, and both test summaries report zero failures.

- [ ] **Step 4: Commit and push**

Run: `git add docs/superpowers/plans/2026-09-04-weekly-quota-suspension.md claude/hooks/quota-gate.sh claude/statusline-command.sh claude/test-quota-gate.sh claude/test-statusline.sh claude/victor-claude-statusline.md && git commit -m "Pause Claude sessions on weekly quota exhaustion" && git push`

Expected: commit succeeds and `master` is synchronized with `origin/master`.
