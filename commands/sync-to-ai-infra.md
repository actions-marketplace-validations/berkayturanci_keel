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

## Step 1 — Detect changed files (parallel)

For each portable file, compare local content with the current ai-infra version. The list contains ~74 files; **running `gh api` sequentially is too slow** (4-5 minutes and often times out — observed during the #1127 sync). Parallelise the reads.

Recommended pattern — Python `asyncio.gather` with bounded concurrency (8 workers is a sensible default):

```python
import asyncio, subprocess, base64, json

async def fetch(local, remote):
    proc = await asyncio.create_subprocess_exec(
        "gh", "api", f"repos/berkayturanci/ai-infra/contents/{remote}",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
    )
    out, _ = await proc.communicate()
    if proc.returncode != 0:
        return local, remote, None, None  # NEW (file not on ai-infra)
    data = json.loads(out)
    return local, remote, base64.b64decode(data["content"]), data["sha"]

async def main(pairs, concurrency=8):
    # `pairs` is a list of (local_path, remote_path) tuples; we thread BOTH
    # through the return value so the caller can correlate each result back
    # to the local file without re-deriving from the remote path.
    sem = asyncio.Semaphore(concurrency)
    async def guarded(p):
        async with sem:
            return await fetch(p[0], p[1])
    return await asyncio.gather(*[guarded(p) for p in pairs])
```

Alternative — `xargs -P 8` if you prefer pure shell. `mkdir -p` the output dir first; BSD xargs on macOS does not surface per-child exit codes, so a missing directory would fail every worker silently:

```bash
mkdir -p /tmp/sync
printf '%s\n' "${REMOTE_PATHS[@]}" | xargs -P 8 -I {} sh -c \
  'gh api "repos/berkayturanci/ai-infra/contents/{}" > "/tmp/sync/$(echo {} | tr / _).json"'
```

The diff scan MUST complete in under 60 seconds for the full 74-file list. If it takes longer, the parallelism is wrong — diagnose before pushing.

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
