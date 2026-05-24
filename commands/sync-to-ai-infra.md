---
description: Sync portable AI workflow files from this repo to berkayturanci/ai-infra, then optionally push to all downstream projects.
allowed-tools: Bash(git:*), Bash(gh:*), Bash(find:*), Bash(diff:*), Bash(base64:*), Bash(python3:*), Bash(echo:*), Bash(cat:*), Bash(grep:*), Read
---

# /sync-to-ai-infra

You are syncing portable AI workflow infrastructure from SmartInventory to `berkayturanci/ai-infra`, then optionally propagating to downstream projects.

## Portable files (sync to ai-infra)

These files are generic enough to live in ai-infra as the canonical version:

- `.claude/commands/` — all EXCEPT `android-build.md` and `web-check.md`
- `.claude/agents/code-reviewer.md` and `tester.md`
- `.claude/hooks/session-start.sh`
- `.gemini/agents/` — all CE persona files
- `scripts/compound-learning.sh`
- `docs/development/compound-learning-spec.md`
- `docs/development/claude-code-global-setup.md`
- `docs/development/parallel-agents.md`

## Step 1 — Detect changed files

For each portable file, compare local content with the current ai-infra version:

```bash
gh api repos/berkayturanci/ai-infra/contents/<path> 2>/dev/null \
  | python3 -c "import sys,json,base64; d=json.load(sys.stdin); print(base64.b64decode(d['content']).decode())"
```

Map local paths to ai-infra paths:
- `.claude/commands/<name>.md` → `commands/<name>.md`
- `.claude/agents/<name>.md` → `agents/<name>.md`
- `.claude/hooks/session-start.sh` → `hooks/session-start.sh`
- `.gemini/agents/<name>.md` → `gemini-agents/<name>.md`
- `scripts/compound-learning.sh` → `scripts/compound-learning.sh`
- `docs/development/<name>.md` → `docs/<name>.md`

## Step 2 — Show diff summary

Before pushing anything, print a summary:

```
Files changed vs ai-infra:
  MODIFIED  commands/ship.md
  MODIFIED  commands/morning.md
  NEW       commands/some-new-command.md
  IDENTICAL gemini-agents/ce-correctness-reviewer.md  (49 more identical)
```

Ask the user: "Push these N changed files to ai-infra? [y/N]"

If user says no, exit.

## Step 3 — Push to ai-infra

For each changed/new file:

1. Get current SHA (for updates): `gh api repos/berkayturanci/ai-infra/contents/<path> --jq .sha`
2. Base64-encode local content: `base64 -i <local-path>`
3. Push:

```bash
gh api --method PUT repos/berkayturanci/ai-infra/contents/<path> \
  --field message="sync: update <path> from SmartInventory" \
  --field content="<base64>" \
  --field sha="<sha-or-empty-for-new>"
```

Report each file: `✓ PUSHED commands/ship.md` or `✗ FAILED commands/ship.md: <error>`

## Step 4 — Optionally propagate to downstream projects

After pushing to ai-infra, ask:
"Propagate to downstream projects (ingreview)? [y/N]"

If yes, for each project in `berkayturanci/ai-infra/projects/*.json`:
- Skip `smartinventory.json` (this is the source)
- For each pushed file, push the same content to the target project's corresponding path
- Use the same base64 + gh api PUT pattern, with the target project's owner/repo

Report: `✓ ingreview: 3 files updated, 0 failed`

## Step 5 — Summary

Print final table:

```
ai-infra:   N files pushed  (M failed)
ingreview:  N files updated (M failed)
```

If any failures: list them and exit 1.
If all succeeded: exit 0.
