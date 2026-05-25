---
description: Post per-PR coverage delta as a single PR comment (flutter test --coverage for mobile, deno test for Supabase edge functions)
allowed-tools: Bash(flutter:*), Bash(dart:*), Bash(deno:*), Bash(npm:*), Bash(node:*), Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(find:*), Bash(grep:*), Bash(command:*), Read, Agent, mcp__github__pull_request_read, mcp__github__list_pull_requests, mcp__github__add_issue_comment, mcp__github__issue_read, mcp__github__get_file_contents
argument-hint: [PR] [--base <branch>] [--dry-run]
---

You are computing and posting the per-PR test-coverage delta for ingreview.

The command is **read-only on PR code**: it never modifies the PR diff, never closes the PR, and never merges. It runs coverage twice (base + head), produces a markdown delta table, and posts (or updates) exactly one PR comment. Repeated runs find the existing codename-prefixed comment and edit it in place so the timeline does not stack duplicates.

## Runtime detection (gh vs GitHub MCP)

```bash
if command -v gh >/dev/null 2>&1; then
  GH_MODE=cli
else
  GH_MODE=mcp
fi
```

State the mode in the first user-facing line. Mapping for the gh call sites in this command:

| gh CLI | GitHub MCP equivalent |
|---|---|
| `gh pr view --json number --jq '.number'` (auto-detect current PR) | `mcp__github__list_pull_requests` (state=`open`, head=`<current branch>`); take the first match. |
| `gh pr view "$PR" --json files --jq '.files[].path'` (Step 2 file list) | `mcp__github__pull_request_read` (method=`get_files`); flatten to a list of paths. |
| `gh pr view "$PR" --json comments` (Step 5 dedupe pre-pass) | `mcp__github__pull_request_read` (method=`get_comments`); search the same codename prefix on each comment body. |
| `gh pr comment "$PR" --body "$BODY"` (Step 5 post new) | `mcp__github__add_issue_comment` (issue_number=`$PR`). |
| `gh pr edit "$PR" --add-label coverage-regression` / `--remove-label coverage-regression` (Step 5 label edits) | Read current labels via `mcp__github__pull_request_read` → `labels[]`, compute the new full label set, then `mcp__github__update_pull_request` (labels=`[<new full set>]`). MCP overwrites; compute the union/difference explicitly. |

### In-place comment update gap (`gh api -X PATCH`) — MCP-mode behaviour

`gh api -X PATCH /repos/<owner>/<repo>/issues/comments/$EXISTING_ID -f body=...` (Step 5 update an existing coverage comment in place) has **no MCP equivalent today**. Behaviour in `GH_MODE=mcp` when an existing coverage comment is found:

1. Compute and log the delta locally as usual.
2. Do NOT post a new comment (that would duplicate the codename-prefixed entry).
3. Emit: `coverage delta computed but not posted — existing coverage comment found and in-place update is unavailable in MCP mode. Re-run locally with gh installed, or delete the prior comment manually first.`
4. Continue with the label-edit step normally.

First-time runs (no existing coverage comment) work normally in MCP mode.

## Language

All committed/published artifacts MUST be written in English. The PR comment this command posts is a published artifact and MUST be English.

## Step 0 — Parse arguments

- Bare positive integer ⇒ explicit `PR` number. At most one positional integer. Default: derive from current branch.
- `--base <branch>` ⇒ consumes exactly one branch name immediately after the flag. Default: `main`.
- `--dry-run` ⇒ boolean; compute the report and log the would-be comment body to stdout but skip every mutation.

Reject unknown flags, `--base` without a value, more than one positional integer, negative or zero integers.

## Step 1 — Detect platforms touched

Get the PR's file list via `gh pr view "$PR" --json files --jq '.files[].path'`.

Classify:
- `FLUTTER_TOUCHED=true` if any file matches `^apps/mobile/` or `^packages/`.
- `SUPABASE_TOUCHED=true` if any file matches `^supabase/functions/`.

Both flags can be true simultaneously. If neither is set, post a short comment and exit:

```
COVERAGE-<PR>-<UTC_TIMESTAMP>
No coverage signal — PR touches no instrumented code (no files under `apps/mobile/`, `packages/`, or `supabase/functions/`).
```

## Step 2 — Compute baseline (base branch HEAD)

Use a worktree so the PR checkout is not disturbed:

```bash
git fetch origin "$BASE" --quiet
git worktree add /tmp/coverage-base "origin/$BASE"
```

### Flutter baseline (only if `FLUTTER_TOUCHED=true`)

```bash
cd /tmp/coverage-base/apps/mobile
flutter test --coverage
```

Parse `apps/mobile/coverage/lcov.info`. Extract per-package + overall LINE coverage as a percentage:

```
covered_lines / (covered_lines + missed_lines) * 100
```

Cache results keyed by `<commit-sha>:flutter:<package>`.

### Supabase functions baseline (only if `SUPABASE_TOUCHED=true`)

```bash
cd /tmp/coverage-base/supabase/functions
deno test --coverage=coverage_data
deno coverage coverage_data --lcov > coverage.lcov
```

Parse `coverage.lcov`. Use overall LINE coverage and per-function file coverage.

Cache results keyed by `<commit-sha>:supabase:<function>`.

## Step 3 — Compute head (PR head)

Same commands against the PR head checkout (the current working tree if it is on the PR head, otherwise create a second worktree at `/tmp/coverage-head`).

Cache results keyed by `<head-sha>:flutter:<package>` and `<head-sha>:supabase:<function>`.

## Step 4 — Build the delta report

Format as a single markdown body. The first line MUST be the codename.

**Codename pin (load-bearing invariant):** the codename line `COVERAGE-<PR>-<UTC_TIMESTAMP>` MUST be the literal first line of the comment body — no blank line above it, no leading whitespace, no quoting, no Markdown prefix, and no surrounding formatting. Step 5's `startswith("COVERAGE-<PR>-")` search depends on this exact invariant.

```
COVERAGE-<PR>-<UTC_TIMESTAMP>

## Coverage delta — base `<BASE>@<base-sha-short>` → head `<head-sha-short>`

### Flutter (apps/mobile + packages)
| Package | base % | head % | Δ | Files in PR diff |
|---|---|---|---|---|
| apps/mobile | … | … | +1.2% | 4 |
| packages/risk_engine | … | … | -0.3% | 1 |
| **Flutter overall** | … | … | **+0.8%** | 5 |

### Supabase Edge Functions
| Function | base % | head % | Δ | Files in PR diff |
|---|---|---|---|---|
| analyze-ingredients | … | … | +0.0% | 0 |
| **Supabase overall** | … | … | **-0.4%** | 1 |

Reports:
- Flutter HTML: `apps/mobile/coverage/html/index.html` (local)
- Supabase LCOV: `supabase/functions/coverage.lcov` (local)
```

Formatting rules:
- One row per Flutter package (apps/mobile, packages/*).
- One row per Supabase edge function touched.
- Always add a bold summary row for each section that ran.
- Show absolute delta with sign: `+1.2%`, `-0.3%`, `+0.0%`.
- **Bold the entire row** when `|Δ| >= 0.5%`.
- Omit an entire section if its platform was not touched.

## Step 5 — Post or update the PR comment

Find the existing coverage comment via its codename prefix:

```bash
EXISTING=$(gh pr view "$PR" --json comments --jq \
  ".comments[] | select(.body | startswith(\"COVERAGE-$PR-\")) | .id" | head -1)
```

Then:
- If `EXISTING` is non-empty and not `--dry-run`:
  ```bash
  gh api -X PATCH "/repos/berkayturanci/ingreview/issues/comments/$EXISTING" -f body="$BODY"
  ```
- If `EXISTING` is empty and not `--dry-run`:
  ```bash
  gh pr comment "$PR" --body "$BODY"
  ```
- Under `--dry-run`: log `$BODY` to stdout, no API call.

Only one coverage comment per PR ever exists after the first run.

## Step 6 — Label

Compute `MAX_REGRESSION = min(flutter_overall_delta, supabase_overall_delta)` across whichever platforms ran.

- If `MAX_REGRESSION <= -0.5%`:
  - Ensure label exists: `gh label create coverage-regression --color FFA500 --description "PR reduces test coverage by ≥0.5%" 2>/dev/null || true`
  - Add label: `gh pr edit "$PR" --add-label coverage-regression`.
- Else:
  - Remove label if present: `gh pr edit "$PR" --remove-label coverage-regression` (ignore "label not present" errors).

Under `--dry-run`: log the would-be label transition, skip the `gh` calls.

## Stop conditions / safety invariants

- **Never modify the PR's code.** This command is read-only on the PR diff. The only writes are: one PR comment (created or edited) and one PR label edit.
- **Never close or merge the PR.**
- **On any test/build failure during coverage computation, fail loudly.** Print the failing command and exit non-zero. Do NOT post a partial comment.
- **Worktree cleanup.** Always `git worktree remove /tmp/coverage-base --force` (and `/tmp/coverage-head` if created) in a trap on EXIT.
- **No silent dry-run mutations.**

## Prerequisites

- **Flutter:** `flutter test --coverage` must be runnable from `apps/mobile/`. Requires Flutter SDK on PATH.
- **Supabase functions:** `deno` must be on PATH and functions must support `deno test`.
- **gh CLI authenticated** with `repo` scope.
- **jq** available on PATH for JSON parsing.

## Examples

```
/coverage             # current branch's PR vs main
/coverage 421         # PR #421 vs main
/coverage 421 --base release/v2.4.0
/coverage --dry-run   # show would-be report without posting
```
