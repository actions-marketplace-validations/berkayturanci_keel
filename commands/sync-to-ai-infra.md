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

## Step 3 — Push to ai-infra (sequential per branch)

**Writes MUST be sequential per target branch.** The GitHub Contents API requires the `sha` field to match the file's current SHA on the target branch; every successful PUT advances the branch tip, which invalidates any other in-flight PUT's pre-fetched SHA. Parallel PUTs to the same branch race on the branch tip and the late-arriving ones return HTTP 409 (`is at <new> but expected <stale>`). Step 1 reads stay parallel; Step 3 writes do not.

For each changed/new file, in a sequential loop:

1. Get current SHA fresh, immediately before each PUT (do NOT reuse the SHA fetched during Step 1's diff scan — even a few seconds of latency between scan and push can be enough for a third party to update the file):
   ```bash
   sha=$(gh api repos/berkayturanci/ai-infra/contents/<path> --jq .sha 2>/dev/null)
   ```
2. Base64-encode local content: `base64 -i <local-path>`.
3. Push. Use `${sha:+--field sha="$sha"}` so the `sha` field is omitted entirely for new files — passing `--field sha=""` (an empty string) is rejected by the GitHub API with HTTP 422, the `sha` field must be ABSENT (not empty) when creating a file:
   ```bash
   gh api --method PUT repos/berkayturanci/ai-infra/contents/<path> \
     --field message="sync: update <path> from SmartInventory" \
     --field content="<base64>" \
     ${sha:+--field sha="$sha"}
   ```

Reference Python pattern (mirrors the Step 1 async snippet but runs serially):

```python
# `*_` swallows any extra tuple elements — Step 1's async fetch returns
# 4-tuples (local, remote, content, sha) while the older diff list shape
# is 3-tuples (local, remote, sha). Either works without arity drift.
for local, remote, *_ in modified:
    sha = subprocess.run(
        ["gh", "api", f"repos/berkayturanci/ai-infra/contents/{remote}", "--jq", ".sha"],
        capture_output=True, text=True
    ).stdout.strip()
    content = subprocess.check_output(["git", "show", f"origin/develop:{local}"])
    args = ["gh", "api", "--method", "PUT",
            f"repos/berkayturanci/ai-infra/contents/{remote}",
            "--field", f"message=sync: update {remote} from SmartInventory",
            "--field", f"content={base64.b64encode(content).decode()}"]
    if sha:
        args += ["--field", f"sha={sha}"]
    subprocess.run(args, check=True)
```

Report each file: `✓ PUSHED commands/ship.md` or `✗ FAILED commands/ship.md: <error>`.

## Step 4 — Optionally propagate to downstream projects (sequential per repo)

After pushing to ai-infra, ask:
"Propagate to downstream projects (ingreview)? [y/N]"

If yes, for each project in `berkayturanci/ai-infra/projects/*.json`:
- Skip `smartinventory.json` (this is the source).
- For each pushed file, push the same content to the target project's corresponding path.
- Use the same base64 + `gh api` PUT pattern, with the target project's owner/repo.

**Same sequential-per-branch rule as Step 3 applies inside each downstream repo** — writes inside one repo's branch must be sequential and re-fetch the SHA immediately before each PUT. Different repos may be processed in parallel across each other (e.g. `ingreview` and a future `foo` can run concurrently as long as their internal loops are sequential), but inside one repo's main branch the PUTs must serialise.

Report: `✓ ingreview: 3 files updated, 0 failed`.

## Step 5 — Summary

Print final table:

```
ai-infra:   N files pushed  (M failed)
ingreview:  N files updated (M failed)
```

If any failures: list them and exit 1.
If all succeeded: exit 0.
