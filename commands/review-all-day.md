---
description: Time-window diff review — scan commits in a configurable UTC+3 window, classify findings via parallel code-reviewer agents, open one GitHub issue per serious finding.
allowed-tools: Bash(gh:*), Bash(git:*), Bash(date:*), Bash(grep:*), Bash(sed:*), Bash(awk:*), Bash(printf:*), Bash(echo:*), Bash(test:*), Bash(seq:*), Bash(command:*), Read, Agent, mcp__github__issue_write
argument-hint: [days]
---

You are running the SmartInventory time-window code review. Scan every commit in a chosen window across `main` plus active feature/fix branches, classify each diff for bug-insert / regression / security / config drift / test-coverage gaps, and open one GitHub issue per serious finding.

This command reuses the `code-reviewer` subagent definition — it does NOT redefine review heuristics. Read `AGENTS.md` § "code-reviewer" first; that file is the source of truth for severity vocabulary and review focus areas.

## Runtime model (read this first)

`/review-all-day` runs as a single Claude Code (or Codex) turn loop. Commit collection is sequential; the per-commit classification is delegated to `code-reviewer` subagents that may run **batched** (single agent reviews several small diffs) or **fanned out** (one agent per commit, parallel) depending on the commit count — see Step 3 for the exact rule. Issue creation runs sequentially after classification completes so the orchestrator can deduplicate findings before posting to GitHub.

This command never pushes code, never opens PRs, never comments on existing PRs. Its only state-changing action is opening a GitHub issue per finding (`gh issue create` in CLI mode, `mcp__github__issue_write` in MCP mode).

## Runtime detection (gh vs GitHub MCP)

```bash
if command -v gh >/dev/null 2>&1; then
  GH_MODE=cli
else
  GH_MODE=mcp
fi
```

State the mode in the first user-facing line. Mapping for Step 5:

| gh CLI | GitHub MCP equivalent |
|---|---|
| `gh issue create --title "$TITLE" --label "$LABELS" --body "..."` | `mcp__github__issue_write` (method=`create`, owner=`berkayturanci`, repo=`smartinventory`, title=`$TITLE`, body=the same body string, labels=`$LABELS` split into an array — e.g. `"review-finding,bug"` becomes `["review-finding", "bug"]`). |

Per the orchestrator's `AGENTS.md § Tool Permissions` carve-out for `/review-all-day`, calling `mcp__github__issue_write` (method=`create`) here is the permitted state-changing action. Failure handling (rate-limit, network, auth) is the same as the CLI path: record the failure, continue with the rest, report the count in Step 6.

## Step 0 — Parse arguments

Argument grammar:

- **No argument** ⇒ window is `today 00:00 (UTC+3) → now`.
- **Single positive integer `N`** ⇒ window is the last `N+1` calendar days, each day inclusive `00:00 — 23:59`. The issue body's contract: "covers every commit made over that many calendar days going back (each day's 00:00–23:59 inclusive)." So `1` = yesterday + today; `7` = today plus the 7 prior calendar days.

Reject:

- Negative integers.
- Non-integer arguments (anything that does not match `^[0-9]+$`).
- More than one positional argument.

State the parsed `DAYS` value and the resolved `[SINCE, UNTIL]` ISO-8601 timestamps in your first user-facing line.

## Step 1 — Resolve the time window

```bash
# Etc/GMT-3 = UTC+3 (POSIX TZ uses inverted sign — do NOT "correct" to Etc/GMT+3,
# same caveat as /ship Step 1).
TZ_ZONE='Etc/GMT-3'

# Prefer GNU date; on macOS, install via `brew install coreutils` to get
# `gdate` (same prerequisite as /ship Step 5b's `gtimeout`).
if command -v gdate >/dev/null 2>&1; then
  DATE_BIN=gdate
elif date -d "1 day ago" >/dev/null 2>&1; then
  DATE_BIN=date
else
  DATE_BIN=
fi

if [[ -z "$DAYS" ]]; then
  # No arg: today 00:00 UTC+3 → now.
  SINCE=$(TZ="$TZ_ZONE" "${DATE_BIN:-date}" +'%Y-%m-%dT00:00:00%z')
  UNTIL=$(TZ="$TZ_ZONE" "${DATE_BIN:-date}" +'%Y-%m-%dT%H:%M:%S%z')
else
  if [[ -n "$DATE_BIN" ]]; then
    SINCE=$(TZ="$TZ_ZONE" "$DATE_BIN" -d "$DAYS days ago" +'%Y-%m-%dT00:00:00%z')
  else
    # BSD date fallback (macOS without coreutils)
    SINCE=$(TZ="$TZ_ZONE" date -v-"$DAYS"d +'%Y-%m-%dT00:00:00%z')
  fi
  UNTIL=$(TZ="$TZ_ZONE" "${DATE_BIN:-date}" +'%Y-%m-%dT23:59:59%z')
fi
```

`%z` emits the numeric offset (`+0300`) which `git log --since/--until` accepts. Print `SINCE` and `UNTIL` to the user before proceeding.

Also print `Resolved span: N+1 calendar days` (where `N` is the parsed `DAYS` argument, or `0` for the no-arg case which scans only today). This makes the off-by-one explicit so the operator catches surprises before the scan starts: `/review-all-day 7` actually covers 8 calendar days (today plus the 7 prior).

## Step 2 — Build the commit set

Default scope: `main` + active feature/fix branches. Do **not** scan every remote branch — that explodes scope and produces noise on stale forks. The issue body restricts scope to active work plus the trunk.

Default scope is **remote refs only** (`origin/main` + `origin/(feature|fix)/issue-*`). Local-only commits that have not been pushed are NOT scanned — push the branch first if you want them reviewed.

Requires bash 4+ for `mapfile`. macOS users on the system bash should `brew install bash` and run via `/usr/local/bin/bash` (or homebrew arm64 path).

```bash
# Fetch refs first so newly-pushed branches are visible to the mapfile
# enumeration, then collect ACTIVE_BRANCHES from origin remotes only.
# Warn loudly on network failure rather than silently scanning stale
# local refs.
if git fetch --quiet origin main \
        '+refs/heads/feature/*:refs/remotes/origin/feature/*' \
        '+refs/heads/fix/*:refs/remotes/origin/fix/*' ; then
  echo "refs refreshed"
else
  echo "WARN: git fetch failed; scanning local refs only — results may be stale" >&2
fi

# Active branches: feature/issue-* or fix/issue-* — REMOTE refs only
# (we do not scan unpushed local commits; document this policy below).
mapfile -t ACTIVE_BRANCHES < <(
  git branch --list --all \
  | sed 's|^[* ]*||; s|^remotes/||' \
  | grep -E '^origin/(feature|fix)/issue-' \
  | sort -u \
  || true
)

# Refs we will scan. origin/main first so it dominates the dedupe step.
# IMPORTANT: if your repo's trunk is `develop` instead of `main`, replace
# `origin/main` here (this repository's trunk is `develop` — see AGENTS.md
# § Branch Rules — but the spec keeps the conventional `origin/main`
# default; the orchestrator running this command should override when
# applicable).
REFS=(origin/main "${ACTIVE_BRANCHES[@]}")

# Collect commit SHAs in the window across all refs, dedup, preserve newest-first.
COMMIT_SHAS=$(git log --since="$SINCE" --until="$UNTIL" \
                      --pretty=format:'%H %s' \
                      "${REFS[@]}" -- 2>/dev/null \
              | awk '!seen[$1]++ {print $0}')

# grep -c . avoids the trailing-newline trap that bites `echo "$X" | wc -l` on empty input.
COMMIT_COUNT=$(printf '%s' "$COMMIT_SHAS" | grep -c .)
```

Print the count and the SHA+subject lines. If `COMMIT_SHAS` is empty, write the final report (Step 6) saying "0 commits in window" and exit cleanly — no failure.

## Step 3 — Decide batch vs fan-out

Let `COMMIT_COUNT` be the number of unique SHAs collected at Step 2 — specifically the `COMMIT_COUNT=$(printf '%s' "$COMMIT_SHAS" | grep -c .)` value computed at the end of the Step 2 block (the `grep -c .` form avoids the trailing-newline trap that bites `echo "$X" | wc -l` on empty input).

| `COMMIT_COUNT` | Strategy |
|----------------|----------|
| `0` | Skip Steps 4–5; jump to Step 6. |
| `1 ≤ count ≤ 5` | **Batch mode** — single `code-reviewer` agent, one Agent-tool call, all diffs concatenated in the prompt. |
| `count > 5` | **Fan-out mode** — one `code-reviewer` agent per commit, all spawned in a single Agent-tool message so they run concurrently in Claude Code (same parallelism pattern as `/ship` Step 5c). |

The threshold is 5 because the median per-commit diff sits well under the agent context budget; below 5 the per-agent overhead dominates and batching is faster. Above 5, single-agent attention degrades and fan-out's parallelism wins.

Document this choice in the user-facing log line: `STRATEGY=batch|fan-out, COMMIT_COUNT=<n>`.

## Step 4 — Classify each commit (delegate to code-reviewer)

For every commit, the orchestrator pre-fetches the diff so the subagent does not re-shell into git:

```bash
git show --no-color --stat --patch "$SHA"
```

Truncate to ~200KB per commit if the diff is enormous, BUT do not cut mid-hunk — a malformed diff confuses the reviewer. Use awk to track byte count and stop at the next `^diff --git ` header line after the threshold, then emit a synthetic trailing line:

  --- diff truncated at <N> bytes; <M> bytes remaining ---

so the reviewer can flag "diff too large for full review" rather than guess from a half-hunk.

Concrete recipe (truncates at the next `^diff --git ` boundary past the
200 000-byte threshold; the boundary granularity is per-file, which is
sufficient to avoid mid-hunk cuts since file boundaries fall between
hunks):

```bash
THRESHOLD=200000
TRUNCATED=$(git show --no-color --stat --patch "$SHA" | awk -v limit="$THRESHOLD" '
  BEGIN { acc = 0; over = 0; remaining = 0 }
  /^diff --git / && acc > limit { over = 1 }
  over { remaining += length($0) + 1; next }
  { acc += length($0) + 1; print }
  END {
    if (over) {
      printf "\n--- diff truncated at %d bytes; %d bytes remaining ---\n", acc, remaining
    }
  }
')
```

`length($0) + 1` accounts for the trailing newline `awk` strips. The
`over` flag flips at the FIRST `^diff --git ` header past the threshold
and accumulates the remaining byte count without printing the body.

### 4a. Batch mode (≤ 5 commits)

Spawn ONE `code-reviewer` agent in a single Agent-tool message with this prompt:

```
Time-window code review for SmartInventory.
Codename: REVIEW-WINDOW-<UTC_TIMESTAMP>-BATCH

Window: <SINCE> .. <UNTIL>
Commits: <count>

For each commit below, classify the diff for:
  - Bug-insert (logic error, null deref, incorrect branching)
  - Regression risk (breaks existing flow, billing/Realm/lifecycle/auth)
  - Security (secrets, injection, OWASP, race condition)
  - Config drift (CI, build, gradle, dependency, manifest, Firebase rules)
  - Test-coverage gap (new logic without test, stub-only test)

For every serious finding, output ONE block in this exact format:

  FINDING:
    SHA: <full SHA>
    SEVERITY: blocker | major | minor
      (Reconciliation with code-reviewer's canonical vocabulary
       per AGENTS.md step 9 vocabulary note: BLOCKER ≡ Must fix → blocker;
       SUGGESTION ≡ Should fix that materially harms maintainability → major;
       SUGGESTION ≡ Should fix cosmetic → minor; NIT → drop, do not emit
       FINDING blocks for NITs — they are informational only and do not get
       a GitHub issue.)
    CATEGORY: bug-insert | regression | security | config | test-coverage
    FILE: <path>:<line-or-range>
    DESCRIPTION: <one paragraph>
    SUGGESTED_FIX: <one paragraph>

If a commit is clean, output:

  CLEAN: <SHA>

Do NOT post anywhere — return findings as your final message.

----- COMMIT 1 -----
<git show output>

----- COMMIT 2 -----
<git show output>
…
```

### 4b. Fan-out mode (> 5 commits)

In a single Agent-tool message, spawn `COMMIT_COUNT` `code-reviewer` agents concurrently, each receiving exactly one commit's diff and the same finding-output contract as 4a, but with a per-commit codename `REVIEW-WINDOW-<UTC_TIMESTAMP>-<SHORT_SHA>`. The orchestrator collects every agent's `FINDING:` / `CLEAN:` output before proceeding to Step 5.

Each fan-out reviewer prompt MUST include: "Do NOT read the other reviewers' output — your review must be fully independent." (Same isolation invariant as `/ship` Step 5c.)

## Step 5 — Open one GitHub issue per serious finding

Aggregate all `FINDING:` blocks from Step 4. Skip any with `SEVERITY=minor` unless the category is `security` (security minors still get an issue — never silently drop security findings) (this filter assumes the reconciled vocabulary above; reviewers emitting the canonical Must-fix/Should-fix instead must be normalised by the orchestrator before this filter runs). Deduplicate findings that share the same `(FILE, CATEGORY, DESCRIPTION)` tuple — keep the one with the highest severity.

For each surviving finding:

```bash
TITLE="[review-all-day] <short description>"   # keep the [review-all-day] prefix exactly
LABELS="review-finding"
[[ "$CATEGORY" == "bug-insert" || "$CATEGORY" == "regression" ]] && LABELS="$LABELS,bug"
[[ "$CATEGORY" == "security" ]] && LABELS="$LABELS,bug"

gh issue create \
  --title "$TITLE" \
  --label "$LABELS" \
  --body "$(cat <<EOF
## Source commit
- SHA: \`$SHA\`
- Branch(es): $BRANCHES
- Authored: $AUTHOR_DATE

## Location
$FILE_REFS

## Problem
$DESCRIPTION

## Suggested fix
$SUGGESTED_FIX

## Detection
Opened by \`/review-all-day\` (codename \`$CODENAME\`).
Window: $SINCE .. $UNTIL
EOF
)"
```

Title prefix is `[review-all-day] ` exactly (with the trailing space), per the issue body spec — downstream watchers regex on this prefix.

If `gh issue create` fails (rate limit, network, auth), record the failure, continue with the rest, and report the count of failed issue creations in Step 6. Do NOT abort the whole run on a single rate-limit hit.

## Step 6 — Final report (printed to user)

Emit a terse report on the last user-facing line:

```
Review window: <SINCE> .. <UNTIL>
Commits scanned: ${COMMIT_COUNT}
Strategy: <batch|fan-out>
Findings (serious): <N>
Issues opened: <opened>/<N>  (failed: <failed>)
Clean commits: $((COMMIT_COUNT - findings_with_distinct_shas))
```

If at least one issue was opened, list the new issue numbers and titles below the summary so the user can click through.

## Stop conditions

- `git log` returns no commits in the window ⇒ exit cleanly with the "0 commits" report.
- `gh` returns `403: API rate limit exceeded` during issue creation ⇒ stop creating new issues, list the unfiled findings in the final report under "Findings not filed (rate-limited)".
- A `code-reviewer` subagent fails to return findings (timeout, error) ⇒ note the SHA(s) under "Findings not filed (review failed)" and continue with the others.
- User cancels.

Always print the final report on exit, even if partial.

## Safety invariants

- This command is read-only with respect to git: never `git commit`, `git push`, `git checkout`, `git merge`, `git rebase`, or any working-tree modification.
- No PR comments, no PR reviews, no branch creation. Only `gh issue create` is permitted as a state-changing call.
- The `[review-all-day] ` title prefix MUST be preserved character-for-character; downstream tooling matches on it.
- Reviewer subagents must NOT read other reviewers' output (fan-out mode) and must NOT call any GitHub write API.
- Default branch scope is `origin/main` + active `feature/issue-*` and `fix/issue-*` refs only — do NOT widen to all remote branches.
- Time zone is `Etc/GMT-3` (POSIX inverted sign for UTC+3); do NOT change this without updating `/ship` Step 1 in lockstep.
