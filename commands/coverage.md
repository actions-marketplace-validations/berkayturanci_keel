---
description: Post per-PR coverage delta as a single PR comment (Kover for Android, web equivalent for Web)
allowed-tools: Bash(./gradlew:*), Bash(npm:*), Bash(node:*), Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(find:*), Bash(grep:*), Bash(command:*), Read, Agent, mcp__github__pull_request_read, mcp__github__list_pull_requests, mcp__github__add_issue_comment, mcp__github__issue_read, mcp__github__get_file_contents
argument-hint: [PR] [--base <branch>] [--dry-run]
---

You are computing and posting the per-PR test-coverage delta for SmartInventory.

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
| `gh pr view --json number --jq '.number'` (auto-detect current PR) | `mcp__github__list_pull_requests` (state=`open`, head=`<current branch>`); take the first match. If the branch is not tied to an open PR, fail the same way the cli path does. |
| `gh pr view "$PR" --json files --jq '.files[].path'` (Step 2 file list) | `mcp__github__pull_request_read` (method=`get_files`); flatten to a list of paths. |
| `gh pr view "$PR" --json comments` (Step 5 dedupe pre-pass) | `mcp__github__pull_request_read` (method=`get_comments`); search the same codename prefix on each comment body. |
| `gh pr comment "$PR" --body "$BODY"` (Step 5 post new) | `mcp__github__add_issue_comment` (issue_number=`$PR`). |
| `gh pr edit "$PR" --add-label coverage-regression` / `--remove-label coverage-regression` (Step 5 label edits) | Read current labels via `mcp__github__pull_request_read` (method=`get`) → `labels[]`, compute the new full label set (add or remove `coverage-regression`), then `mcp__github__update_pull_request` (labels=`[<new full set>]`). MCP overwrites; compute the union/difference explicitly. |

### In-place comment update gap (`gh api -X PATCH`) — MCP-mode behaviour

`gh api -X PATCH /repos/<owner>/<repo>/issues/comments/$EXISTING_ID -f body=...` (Step 5 update an existing coverage comment in place) has **no MCP equivalent today** — the MCP server exposes `add_issue_comment` (create) and `add_reply_to_pull_request_comment` (reply to a review comment), but not a `update_issue_comment`. Behaviour in `GH_MODE=mcp` when an existing coverage comment is found:

1. Compute and log the delta locally as usual.
2. Do NOT post a new comment (that would duplicate the codename-prefixed entry the dedupe pass was designed to prevent).
3. Emit a one-line note: `coverage delta computed but not posted — existing coverage comment found and in-place update is unavailable in MCP mode. Re-run locally with gh installed, or delete the prior comment manually first.`
4. Continue with the label-edit step normally (the label uses MCP `update_pull_request` and works in both modes).

First-time runs (no existing coverage comment) work normally in MCP mode: the comment is posted via `mcp__github__add_issue_comment`.

## Language

All committed/published artifacts (commits, branch names, PR/issue titles and bodies, comments, file contents, slash command definitions) MUST be written in English. Free-form chat with the user may stay in any language. See `AGENTS.md` § "Language Policy". The PR comment this command posts is a published artifact and MUST be English.

## Step 0 — Parse arguments

Argument grammar:

- Bare positive integer ⇒ explicit `PR` number. At most one positional integer. Default: derive from current branch:
  ```bash
  PR=$(gh pr view --json number --jq '.number' 2>/dev/null)
  ```
  If no PR is open for the current branch and no positional was supplied, exit non-zero with `no PR for current branch — pass an explicit PR number`.
- `--base <branch>` ⇒ consumes exactly one branch name immediately after the flag. Default: `develop`.
- `--dry-run` ⇒ boolean; compute the report and log the would-be comment body to stdout but skip every `gh pr comment` / `gh api -X PATCH` / `gh label` mutation.

Reject:

- Unknown flags (anything starting with `--` not in the list above).
- `--base` without a value immediately after.
- More than one positional integer.
- Negative or zero positional integers.

Worked examples:

```
/coverage             → PR=<current-branch PR>   BASE=develop
/coverage 421         → PR=421                    BASE=develop
/coverage 421 --base release/v2.4.0 → PR=421     BASE=release/v2.4.0
/coverage --dry-run   → PR=<current-branch PR>   BASE=develop   DRY_RUN=true
```

## Step 1 — Detect platforms touched

Get the PR's file list:

```bash
PR_FILES=$(gh pr view "$PR" --json files --jq '.files[].path')
```

Classify:

- `ANDROID_TOUCHED=true` if any file matches `^android/`.
- `WEB_TOUCHED=true` if any file matches `^web/`.

Both flags can be true simultaneously. If neither is set, post a short comment and exit:

```
COVERAGE-<PR>-<UTC_TIMESTAMP>
No coverage signal — PR touches no instrumented code (no files under `android/` or `web/`).
```

Under `--dry-run`, log the would-be body and skip the post.

## Step 2 — Compute baseline (base branch HEAD)

Use a worktree so the PR checkout is not disturbed:

```bash
git fetch origin "$BASE" --quiet
git worktree add /tmp/coverage-base "origin/$BASE"
```

### Android baseline (only if `ANDROID_TOUCHED=true`)

Discover the canonical Kover task — name varies by Kover version (`koverXmlReport`, `koverXmlReportDebug`, `:smartinventory:koverXmlReport`):

```bash
cd /tmp/coverage-base/android
./gradlew tasks --all 2>/dev/null | grep -iE '^\s*kover.*xml.*report' | head -1
```

If no Kover task is found, see **Prerequisites** below: skip Android coverage and add a note to the report (`Android coverage skipped: Kover not wired up`). Continue with web baseline if applicable.

Otherwise run the discovered task and parse the JaCoCo-compatible XML at `android/smartinventory/build/reports/kover/report.xml` (or the per-module equivalent under `android/<module>/build/reports/kover/`). Extract per-module + overall LINE coverage as a percentage:

```
covered_lines / (covered_lines + missed_lines) * 100
```

Cache results keyed by `<commit-sha>:android:<module>` so a re-run on the same head SHA does not recompute.

### Web baseline (only if `WEB_TOUCHED=true`)

```bash
cd /tmp/coverage-base/web
npm ci --silent
npm test -- --coverage --coverageReporters=json-summary
```

Parse `web/coverage/coverage-summary.json`. Use the `total.lines.pct` field for overall LINE coverage and the per-file entries for per-directory aggregates.

## Step 3 — Compute head (PR head)

Same commands against the PR head checkout (the current working tree if it is on the PR head, otherwise create a second worktree at `/tmp/coverage-head`). Reuse the Kover task name discovered in Step 2.

Cache results keyed by `<head-sha>:android:<module>` and `<head-sha>:web:<dir>`.

## Step 4 — Build the delta report

Format as a single markdown body. The first line MUST be the codename so Step 5 can find it on re-run.

**Codename pin (load-bearing invariant):** the codename line `COVERAGE-<PR>-<UTC_TIMESTAMP>` MUST be the literal first line of the comment body — no blank line above it, no leading whitespace, no quoting, no Markdown prefix (no `#`, no `>`, no list marker), and no surrounding formatting (no backticks, no bold). Step 5's `startswith("COVERAGE-<PR>-")` search depends on this exact invariant to locate the existing comment and edit it in place on re-runs; any deviation (e.g. wrapping the codename in a heading or preceding it with a blank line) will cause Step 5 to miss the prior comment and post a duplicate instead of updating.

```
COVERAGE-<PR>-<UTC_TIMESTAMP>

## Coverage delta — base `<BASE>@<base-sha-short>` → head `<head-sha-short>`

### Android
| Module | base % | head % | Δ | Files in PR diff |
|---|---|---|---|---|
| smartinventory | … | … | +1.2% | 4 |
| smartinventory-shared | … | … | -0.3% | 1 |
| **Android overall** | … | … | **+0.8%** | 5 |

### Web
| Path | base % | head % | Δ | Files in PR diff |
|---|---|---|---|---|
| web/functions | … | … | +0.0% | 0 |
| web/public | … | … | -0.6% | 3 |
| **Web overall** | … | … | **-0.4%** | 3 |

Reports:
- Android HTML: `android/smartinventory/build/reports/kover/html/index.html` (local)
- Web LCOV: `web/coverage/lcov-report/index.html` (local)
```

Formatting rules:

- One row per Android module (`smartinventory`, `smartinventory-shared`, plus any future modules detected from `android/settings.gradle.kts`).
- One row per top-level web directory touched (`web/functions`, `web/public`, etc.).
- Always add a bold summary row `Android overall` / `Web overall` for each section that ran.
- Show absolute delta with sign: `+1.2%`, `-0.3%`, `+0.0%`.
- **Bold the entire row** when `|Δ| >= 0.5%` (regression or improvement) so reviewers' eyes catch it.
- Omit an entire section if its platform was not touched (do not render an empty Android table for a web-only PR).
- If Kover was missing, render the Android section as a single italic line: `_Android coverage skipped: Kover not wired up (see issue #468)._`

## Step 5 — Post or update the PR comment

Find the existing coverage comment via its codename prefix:

```bash
EXISTING=$(gh pr view "$PR" --json comments --jq \
  ".comments[] | select(.body | startswith(\"COVERAGE-$PR-\")) | .id" | head -1)
```

The codename header `COVERAGE-<PR>-<UTC_TIMESTAMP>` is the first line of every coverage comment we post, so the prefix `COVERAGE-<PR>-` is enough to find prior runs even though the timestamp changes. **Pin**: the prefix used here MUST match the literal first-line format emitted in Step 4 — change them together or the find-and-update logic silently breaks.

Then:

- If `EXISTING` is non-empty and not `--dry-run`:
  ```bash
  gh api -X PATCH "/repos/<owner>/<repo>/issues/comments/$EXISTING" -f body="$BODY"
  ```
- If `EXISTING` is empty and not `--dry-run`:
  ```bash
  gh pr comment "$PR" --body "$BODY"
  ```
- Under `--dry-run`: log `$BODY` to stdout, no API call.

Only one coverage comment per PR ever exists after the first run.

## Step 6 — Label

Compute `MAX_REGRESSION = min(android_overall_delta, web_overall_delta)` across whichever platforms ran.

- If `MAX_REGRESSION <= -0.5%` (i.e. at least one platform regressed by ≥0.5%):
  - Ensure the label exists (idempotent; ignore "already exists" errors):
    ```bash
    gh label create coverage-regression --color FFA500 \
      --description "PR reduces test coverage by ≥0.5%" 2>/dev/null || true
    ```
  - Add the label: `gh pr edit "$PR" --add-label coverage-regression`.
- Else (overall delta is positive or neutral on every platform that ran):
  - Remove the label if a prior run added it: `gh pr edit "$PR" --remove-label coverage-regression` (ignore "label not present" errors).

Under `--dry-run`: log the would-be label transition, skip the `gh` calls.

Label colour `FFA500` (orange) is a judgement call — it sits between informational blue and blocking red, matching the "informational, not gating" stance from issue #513.

## Stop conditions / safety invariants

- **Never modify the PR's code.** This command is read-only on the PR diff. The only writes are: one PR comment (created or edited) and one PR label edit.
- **Never close or merge the PR.** No `gh pr merge`, no `gh pr close`, no `gh issue close`. Gating is `/ship`'s job.
- **On any test/build failure during coverage computation, fail loudly.** Print the failing command (Kover task, npm test, jq parse) and exit non-zero. Do NOT post a partial comment — a half-formed table is worse than no comment, because reviewers will treat it as authoritative.
- **Worktree cleanup.** Always `git worktree remove /tmp/coverage-base --force` (and `/tmp/coverage-head` if created) in a trap on EXIT so a failure mid-run does not leak worktrees.
- **No silent dry-run mutations.** Under `--dry-run`, every state-changing call (comment post, comment patch, label add/remove, label create) MUST be redirected to stdout as `DRY-RUN: <command>` and skipped.

## Prerequisites

- **Android (Kover):** the smartinventory module must have the Kover plugin (or an equivalent JaCoCo XML reporter) wired up in `android/smartinventory/build.gradle.kts`. As of writing, Kover is NOT wired up — this command requires the Kover phase referenced by issue #468 to be complete before Android coverage works. Until then, the command **degrades gracefully**: it skips Android coverage and renders the section as `_Android coverage skipped: Kover not wired up (see issue #468)._` rather than failing. Web coverage still runs.
- **Web:** `npm test` in `web/` must support `--coverage --coverageReporters=json-summary`. Default Vitest and Jest setups both do; if `web/coverage/coverage-summary.json` is missing after `npm test`, fail per the Stop conditions above.
- **gh CLI authenticated** with `repo` scope (PR read + comment + label edit).
- **jq** available on PATH for JSON parsing.

## Examples

```
/coverage             # current branch's PR vs develop
/coverage 421         # PR #421 vs develop
/coverage 421 --base release/v2.4.0
/coverage --dry-run   # show would-be report without posting
```

- `/coverage` — derives the PR from the current branch, diffs against `develop`, posts (or updates) the single coverage comment on that PR.
- `/coverage 421` — explicit PR; useful when on a different branch.
- `/coverage 421 --base release/v2.4.0` — diff against a release branch instead of `develop` (e.g. checking whether a backport regresses coverage relative to the release line).
- `/coverage --dry-run` — full computation but no PR write; the rendered body is printed to stdout. Use this to sanity-check the table before letting it land on a teammate's PR.
