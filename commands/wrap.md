---
description: Finish current work — run tests, commit, push, open PR
allowed-tools: Bash(git:*), Bash(gh:*), Bash(flutter:*), Bash(dart:*), Bash(supabase:*), Bash(deno:*), Bash(command:*), Bash(cd:*), Read, Edit, mcp__github__create_pull_request
argument-hint: [optional PR title override]
---

You are wrapping up the current work session for ingreview.

## Language

All committed/published artifacts (commits, branch names, PR/issue titles and bodies, comments, file contents, slash command definitions) MUST be written in English. Free-form chat with the user may stay in any language. See `AGENTS.md` § "Language Policy".

## Step 0 — Detect environment

Run via the Bash tool:

```bash
if command -v gh >/dev/null 2>&1; then echo cli; else echo mcp; fi
```

- Output `cli` ⇒ `GH_MODE=cli`. Step 4 runs the `gh pr create ...` line via the Bash tool.
- Output `mcp` ⇒ `GH_MODE=mcp`. Step 4 substitutes `mcp__github__create_pull_request` (owner=`berkayturanci`, repo=`ingreview`, base=current PR target, head=current branch, title=resolved title, body=the same body string). The PR is opened ready (not draft) in both modes.

IMPORTANT: Do NOT embed bare bang-backtick `gh` markdown placeholders (the form `<bang><backtick>gh ...<backtick>`) in this file — the preprocessor expands them before Step 0 runs, defeating the GH_MODE gate. Always issue `gh` calls through the Bash tool, gated by the detected `GH_MODE`.

## Step 1 — Sanity check
1. !`git status --short`
2. If on `main`, ABORT — tell the user to switch to a feature branch.
3. !`git diff --stat HEAD`
4. **Workspace isolation check** (`AGENTS.md` § "Workspace Isolation (AI agents)"): `/wrap` MUST run from a linked worktree, not the main worktree (which is the user's primary checkout). Detect with `git rev-parse --git-dir`: the main worktree returns the literal `.git`, every linked worktree returns an absolute path containing `/.git/worktrees/<name>`. If the value is `.git`, ABORT and tell the user to re-run from a linked worktree (list candidates with `git worktree list`). This check is portable across OSes/home directories and immune to symlink trickery (`.git` resolution is performed by git, not by shell-level path matching).

## Step 2 — Quality gates (do NOT skip)
Run all that apply based on what changed:
- If `apps/mobile/**` changed: !`cd apps/mobile && dart format --set-exit-if-changed . 2>&1 | tail -20`
- If `apps/mobile/**` changed: !`cd apps/mobile && flutter analyze 2>&1 | tail -50`
- If `apps/mobile/**` changed: !`cd apps/mobile && flutter test 2>&1 | tail -50`
- If `supabase/functions/**` changed: !`deno fmt --check supabase/functions && deno lint supabase/functions 2>&1 | tail -30`
- If `supabase/migrations/**` changed: ensure every new file matches `<timestamp>_<snake_case>.sql` and runs cleanly against `supabase db reset` locally.

If any gate FAILS — STOP. Report the failure. Do not commit broken code.

## Step 3 — Commit
- !`git add -A`
- Write a commit message in Conventional Commits format (feat/fix/chore/docs/refactor/test)
- Include "Closes #N" if this implements a GitHub issue
- !`git commit -m "<message>"`

## Step 4 — Push + PR
- !`git push -u origin HEAD`
- If $ARGUMENTS provided, use as PR title. Otherwise derive from commit message.
- Include `Agent run codename: <CODENAME>` in the PR body when the branch was produced by an agent run.
- `GH_MODE=cli`: run via the Bash tool: `gh pr create --title "<title>" --body "Closes #N\n\n## Summary\n[what changed]\n\n## Agent run\nCodename: <CODENAME or none>\n\n## Docs impact\n[files to update or 'none']\n\n## Test plan\n[how to verify]"`
- `GH_MODE=mcp`: call `mcp__github__create_pull_request` with `owner=berkayturanci`, `repo=ingreview`, `base=<PR target, typically develop>`, `head=<current branch from git rev-parse --abbrev-ref HEAD>`, `title=<resolved title>`, `body=<same body string used in the cli branch>`. Do NOT pass `draft=true`; this command opens PRs ready by design.

## Step 5 — Update sessions.md
Append a session recap to `.claude/sessions.md`:
- What was accomplished
- What's still open
- What to pick up next session
