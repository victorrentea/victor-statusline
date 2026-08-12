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
