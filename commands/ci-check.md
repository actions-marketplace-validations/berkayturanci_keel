---
description: Check latest CI run status; analyze failures and propose fix
allowed-tools: Bash(gh:*), Bash(command:*), Read, Grep
argument-hint: (no args)
---

## Language

All committed/published artifacts (commits, branch names, PR/issue titles and bodies, comments, file contents, slash command definitions) MUST be written in English. Free-form chat with the user may stay in any language. See `AGENTS.md` § "Language Policy".

## Step 0 — Detect environment

Run via the Bash tool:

```bash
if command -v gh >/dev/null 2>&1; then echo cli; else echo mcp; fi
```

- Output `cli` ⇒ `GH_MODE=cli`. Continue to Step 1.
- Output `mcp` ⇒ `GH_MODE=mcp`. See the runtime-availability gate below.

IMPORTANT: Do NOT embed bare bang-backtick `gh` markdown placeholders (the form `<bang><backtick>gh ...<backtick>`) in this file — the preprocessor expands them before Step 0 runs, defeating the GH_MODE gate. Always issue `gh` calls through the Bash tool, gated by the detected `GH_MODE`.

**Runtime-availability gate.** The GitHub Actions APIs (`gh run list`, `gh run view`) have no MCP equivalent today, so this command fundamentally requires `gh`. If `GH_MODE=mcp`, exit cleanly with a single line:

```
/ci-check unavailable in this runtime — GitHub Actions data requires the gh CLI, which is not installed in this sandbox. Re-run from a local checkout with gh installed, or use the GitHub web UI Actions tab.
```

Do NOT error or partial-run. Steps 1–3 below execute only when `GH_MODE=cli`.

## Step 1 — Latest run

If `GH_MODE=cli`, run via the Bash tool:

- `gh run list --limit 3 --json databaseId,status,conclusion,name,headBranch,createdAt`

## Step 2 — If the latest run failed

If `GH_MODE=cli`, run via the Bash tool:

- `gh run view <id> --log-failed | tail -200`
- Identify the failing job and step name
- Read the relevant source file that caused the failure
- Diagnose root cause in 2–4 sentences
- Propose ONE specific fix (describe it, do NOT apply automatically)

## Step 3 — If all runs passed
Print: `✅ CI green. Last run: <name> on <branch> at <time>`

## Step 4 — After fix is applied (mandatory — AGENTS.md step 6 + 9b)
This command only proposes the fix; it does not apply it. After the fix is applied and pushed:
1. Run `/pr-loop` — triggers self-review (AGENTS.md step 6) + 3 independent code-reviewer agents (step 9b).
2. The fix is not "done" until every reviewer is LGTM (no blockers) AND CI is green.
