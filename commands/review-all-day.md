---
description: Time-window diff review — scan commits in a configurable UTC+3 window, classify findings via parallel code-reviewer agents, open one GitHub issue per serious finding.
allowed-tools: Bash(gh:*), Bash(git:*), Bash(date:*), Bash(grep:*), Bash(sed:*), Bash(awk:*), Bash(printf:*), Bash(echo:*), Bash(test:*), Bash(seq:*), Bash(command:*), Read, Agent, mcp__github__issue_write
argument-hint: [days]
---

You are running the ingreview time-window code review. Scan every commit in a chosen window across `main` plus active feature/fix branches, classify each diff for bug-insert / regression / security / config drift / test-coverage gaps, and open one GitHub issue per serious finding.

This command reuses the `code-reviewer` subagent definition — it does NOT redefine review heuristics. Read `AGENTS.md` § "code-reviewer" first; that file is the source of truth for severity vocabulary and review focus areas.

## Runtime model (read this first)

`/review-all-day` runs as a single Claude Code (or Codex) turn loop. Commit collection is sequential; the per-commit classification is delegated to `code-reviewer` subagents that may run **batched** (single agent reviews several small diffs) or **fanned out** (one agent per commit, parallel) depending on the commit count — see Step 3 for the exact rule.

This command never pushes code, never opens PRs, never comments on existing PRs. Its only state-changing action is opening a GitHub issue per finding.

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
| `gh issue create --title "$TITLE" --label "$LABELS" --body "..."` | `mcp__github__issue_write` (method=`create`, owner=`berkayturanci`, repo=`ingreview`, title=`$TITLE`, body=the same body string, labels=`$LABELS` split into an array). |

## Step 0 — Parse arguments

- **No argument** ⇒ window is `today 00:00 (UTC+3) → now`.
- **Single positive integer `N`** ⇒ window is the last `N+1` calendar days, each day inclusive `00:00 — 23:59`.

Reject negative integers, non-integers, and more than one positional argument.

State the parsed `DAYS` value and the resolved `[SINCE, UNTIL]` ISO-8601 timestamps in your first user-facing line.

## Step 1 — Resolve the time window

```bash
TZ_ZONE='Etc/GMT-3'

# Prefer GNU date; on macOS, install via `brew install coreutils` to get `gdate`.
if command -v gdate >/dev/null 2>&1; then
  DATE_BIN=gdate
elif date -d "1 day ago" >/dev/null 2>&1; then
  DATE_BIN=date
else
  DATE_BIN=
fi

if [[ -z "$DAYS" ]]; then
  SINCE=$(TZ="$TZ_ZONE" "${DATE_BIN:-date}" +'%Y-%m-%dT00:00:00%z')
  UNTIL=$(TZ="$TZ_ZONE" "${DATE_BIN:-date}" +'%Y-%m-%dT%H:%M:%S%z')
else
  if [[ -n "$DATE_BIN" ]]; then
    SINCE=$(TZ="$TZ_ZONE" "$DATE_BIN" -d "$DAYS days ago" +'%Y-%m-%dT00:00:00%z')
  else
    SINCE=$(TZ="$TZ_ZONE" date -v-"$DAYS"d +'%Y-%m-%dT00:00:00%z')
  fi
  UNTIL=$(TZ="$TZ_ZONE" "${DATE_BIN:-date}" +'%Y-%m-%dT23:59:59%z')
fi
```

Print `SINCE` and `UNTIL` to the user before proceeding. Also print `Resolved span: N+1 calendar days`.

## Step 2 — Build the commit set

Default scope: `main` + active feature/fix branches. Do **not** scan every remote branch.

Default scope is **remote refs only** (`origin/main` + `origin/(feature|fix)/*`). Local-only commits that have not been pushed are NOT scanned.

```bash
if git fetch --quiet origin main \
        '+refs/heads/feature/*:refs/remotes/origin/feature/*' \
        '+refs/heads/fix/*:refs/remotes/origin/fix/*' ; then
  echo "refs refreshed"
else
  echo "WARN: git fetch failed; scanning local refs only — results may be stale" >&2
fi

mapfile -t ACTIVE_BRANCHES < <(
  git branch --list --all \
  | sed 's|^[* ]*||; s|^remotes/||' \
  | grep -E '^origin/(feature|fix)/' \
  | sort -u \
  || true
)

REFS=(origin/main "${ACTIVE_BRANCHES[@]}")

COMMIT_SHAS=$(git log --since="$SINCE" --until="$UNTIL" \
                      --pretty=format:'%H %s' \
                      "${REFS[@]}" -- 2>/dev/null \
              | awk '!seen[$1]++ {print $0}')

COMMIT_COUNT=$(printf '%s' "$COMMIT_SHAS" | grep -c .)
```

Print the count and the SHA+subject lines. If `COMMIT_SHAS` is empty, write the final report saying "0 commits in window" and exit cleanly.

## Step 3 — Decide batch vs fan-out

| `COMMIT_COUNT` | Strategy |
|----------------|----------|
| `0` | Skip Steps 4–5; jump to Step 6. |
| `1 ≤ count ≤ 5` | **Batch mode** — single `code-reviewer` agent, all diffs concatenated. |
| `count > 5` | **Fan-out mode** — one `code-reviewer` agent per commit, all spawned in a single Agent-tool message. |

Document this choice: `STRATEGY=batch|fan-out, COMMIT_COUNT=<n>`.

## Step 4 — Classify each commit (delegate to code-reviewer)

For every commit, pre-fetch the diff:

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

### 4a. Batch mode (≤ 5 commits)

Spawn ONE `code-reviewer` agent with this prompt:

```
Time-window code review for ingreview.
Codename: REVIEW-WINDOW-<UTC_TIMESTAMP>-BATCH

Window: <SINCE> .. <UNTIL>
Commits: <count>

For each commit below, classify the diff for:
  - Bug-insert (logic error, null deref, incorrect branching)
  - Regression risk (breaks existing flow, Supabase RLS/schema/auth, product invariants per PLAN.md §10/§14/§21/§24)
  - Security (secrets, injection, OWASP, race condition)
  - Config drift (CI, build, pubspec, migration, Supabase config)
  - Test-coverage gap (new logic without test, stub-only test)

For every serious finding, output ONE block in this exact format:

  FINDING:
    SHA: <full SHA>
    SEVERITY: blocker | major | minor
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

In a single Agent-tool message, spawn `COMMIT_COUNT` `code-reviewer` agents concurrently, each receiving exactly one commit's diff with a per-commit codename `REVIEW-WINDOW-<UTC_TIMESTAMP>-<SHORT_SHA>`.

Each fan-out reviewer prompt MUST include: "Do NOT read the other reviewers' output — your review must be fully independent."

## Step 5 — Open one GitHub issue per serious finding

Aggregate all `FINDING:` blocks from Step 4. Skip any with `SEVERITY=minor` unless the category is `security`. Deduplicate findings that share the same `(FILE, CATEGORY, DESCRIPTION)` tuple — keep the one with the highest severity.

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

Title prefix is `[review-all-day] ` exactly (with the trailing space).

## Step 6 — Final report (printed to user)

```
Review window: <SINCE> .. <UNTIL>
Commits scanned: ${COMMIT_COUNT}
Strategy: <batch|fan-out>
Findings (serious): <N>
Issues opened: <opened>/<N>  (failed: <failed>)
Clean commits: $((COMMIT_COUNT - findings_with_distinct_shas))
```

If at least one issue was opened, list the new issue numbers and titles below the summary.

## Stop conditions

- `git log` returns no commits in the window ⇒ exit cleanly with the "0 commits" report.
- `gh` returns `403: API rate limit exceeded` during issue creation ⇒ stop creating new issues, list the unfiled findings.
- A `code-reviewer` subagent fails to return findings ⇒ note the SHA(s) under "Findings not filed (review failed)".
- User cancels.

Always print the final report on exit, even if partial.

## Safety invariants

- This command is read-only with respect to git: never `git commit`, `git push`, `git checkout`, `git merge`, `git rebase`, or any working-tree modification.
- No PR comments, no PR reviews, no branch creation. Only `gh issue create` is permitted as a state-changing call.
- The `[review-all-day] ` title prefix MUST be preserved character-for-character.
- Reviewer subagents must NOT read other reviewers' output (fan-out mode) and must NOT call any GitHub write API.
- Default branch scope is `origin/main` + active `feature/*` and `fix/*` refs only.
- Time zone is `Etc/GMT-3` (POSIX inverted sign for UTC+3).
