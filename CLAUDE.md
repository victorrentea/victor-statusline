# victor-statusline

Published status lines for Claude Code and GitHub Copilot CLI, each as a
runnable script plus a companion doc that embeds the same script verbatim.

## Commit and push every change — no asking

**Every time you change anything in this repo, commit it and push it in the same
turn.** Do not leave the tree dirty and do not ask "shall I commit?" — the answer
is always yes. This is a standing instruction from Victor and it overrides the
default "only commit when asked" behaviour.

The reason is what this repo is *for*: it is the published copy. `~/.claude/` is
not a git repo, so the working tree here is the only version history these
scripts have, and the raw GitHub URLs are what other people install from. A
change sitting uncommitted is a change that exists on exactly one laptop.

## The live scripts are the source of truth — and each lives in THREE places

The files you actually run live outside this repo. Every one of them exists three
times, and all three must move together in one commit:

| # | Copy | Path |
|---|------|------|
| 1 | **live** (what runs) | `~/.claude/statusline-command.sh` — **symlink → copy 2**, `~/.claude/hooks/session-title.sh` |
| 2 | **repo** (what people install) | `claude/statusline-command.sh`, `claude/hooks/session-title.sh` |
| 3 | **embedded** (what makes the doc self-contained) | the fenced block under `## The full script` / `## The title hook` in `claude/victor-claude-statusline.md` |

Same rule for `copilot/statusline.sh` and `copilot/quota-refresh.sh` against
`copilot/victor-copilot-statusline.md` (`## File 1` / `## File 2`).

Editing only the live script is the failure mode this repo keeps hitting: the
flower's colour ramp shipped once with copies 2 and 3 left a whole revision
behind, so the published script and the doc both described a version that no
longer existed.

**For `statusline-command.sh`, copies 1 and 2 are now the same inode**:
`~/.claude/statusline-command.sh` is a symlink to `claude/statusline-command.sh`
here. Editing either path edits both, and the drift above is structurally
impossible rather than merely forbidden. Do **not** `cp` between the two paths —
that is now a self-copy, which errors at best and truncates the file at worst.
Edit in place, then re-sync only the embedded block (copy 3).

The remaining copies are still plain files and still need the copy-then-sync
dance: everything under `claude/hooks/` and all of `copilot/`. Symlinking those
the same way is the obvious next step and has not been done yet.

### Always run the checker before committing

```sh
./check-sync.sh          # exits non-zero on the first mismatch
```

It compares copy 2 against copy 3 for all four scripts. It cannot see copy 1 —
nothing can — so **diff the live file against the repo file yourself** as well.

Careful: `diff` here is rewritten by an rtk hook that summarises instead of
comparing, and it has reported "Files are identical" for files that differ. Use
`cmp`, `md5`, or `rtk proxy diff -u` when the answer actually matters.

## The behaviour docs are part of the change, not a follow-up

Both scripts carry a MAINTENANCE RULE in their header saying the companion doc
must be updated in the same change as any behaviour change (format, segments,
colours, thresholds, turn-state logic). The doc is written as prose that argues
*why* each choice was made, so when a decision is reversed, **rewrite the passage
that argued for the old behaviour** — don't just append the new rule underneath
it and leave the doc making both cases at once.
