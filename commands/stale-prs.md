---
description: Find open PRs with no recent activity or develop-drift and propose/apply refresh actions
allowed-tools: Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(grep:*), Bash(awk:*), Bash(date:*), Read, Agent, mcp__github__list_pull_requests, mcp__github__pull_request_read, mcp__github__add_issue_comment, mcp__github__search_pull_requests
argument-hint: [days] [--merge-develop] [--dry-run]
---

You are running an on-demand triage of open pull requests for SmartInventory that have either gone quiet or drifted out of sync with `develop`.

The command is **read-only on PR code by default**: it never modifies a PR's diff, never closes a PR, never re-triggers CI manually, and never merges a PR into `develop`. Without `--merge-develop` the only write is one triage comment per stale PR. With `--merge-develop` the additional write is `git merge --no-ff origin/develop` plus a push for each PR in the drift bucket that is not a draft — that push organically retriggers CI, which is the only intended CI side-effect. Repeated runs of `/stale-prs` MUST NOT spam duplicate comments on the same PR within the same UTC date — the Step 4 idempotency check is load-bearing.

## Language

All committed/published artifacts (commits, branch names, PR/issue titles and bodies, comments, file contents, slash command definitions) MUST be written in English. Free-form chat with the user may stay in any language. See `AGENTS.md` § "Language Policy". The per-PR triage comment this command posts is a published artifact and MUST be English.

## Step 0 — Parse arguments

Argument grammar:

- Positional, optional: a single positive integer `[days]` — the staleness threshold in calendar days. Default: `7`. Reject `0` or negative integers, non-integers, and more than one positional.
- `--merge-develop` — boolean; when set, actually merge `origin/develop` into each drift-bucket PR's branch and push. Without this flag, the command is comment-only.
- `--dry-run` — boolean; print the intended actions to stdout but make **no** API calls and **no** `git push`. Under `--dry-run`, every state-changing call (comment post, branch checkout, merge, push) MUST be redirected to stdout as a `would …: …` line and skipped. The session lock file (if any) is NOT touched under `--dry-run`.
- Reject unknown flags (anything starting with `--` not in the list above).

`--merge-develop` and `--dry-run` may be combined; the combination prints `would merge develop into branch <head> for #<N>` per drift-bucket PR and posts no comments and runs no `git push`.

Worked examples:

```
/stale-prs                       → DAYS=7   MERGE_DEVELOP=false  DRY_RUN=false
/stale-prs 14                    → DAYS=14  MERGE_DEVELOP=false  DRY_RUN=false
/stale-prs 7 --merge-develop     → DAYS=7   MERGE_DEVELOP=true   DRY_RUN=false
/stale-prs --dry-run             → DAYS=7   MERGE_DEVELOP=false  DRY_RUN=true
/stale-prs 14 --merge-develop --dry-run → DAYS=14 MERGE_DEVELOP=true DRY_RUN=true
```

## Step 1 — List open PRs targeting `develop`

Enumerate every open PR with base `develop`:

```
mcp__github__list_pull_requests
  owner: berkayturanci
  repo:  smartinventory
  state: OPEN
  base:  develop
  perPage: 100
```

Paginate until all open PRs are collected. For each PR capture:

- `number`
- `title`
- `updatedAt` (GitHub's `updated_at` is the activity signal — it advances on the last commit OR comment OR review, so a PR with no recent commits but recent reviewer chatter is correctly treated as "not stale")
- `headRefName`
- `isDraft`
- `author.login`

Compute the staleness cutoff as `now - <DAYS> days` in UTC. Filter to PRs whose `updatedAt` is strictly older than the cutoff. PRs whose last activity is inside the window are skipped entirely — they are not stale by definition.

## Step 2 — Classify each stale PR

For each candidate, fetch `mergeStateStatus` (and confirm `isDraft`) via:

```
mcp__github__pull_request_read
  method: get
  pullNumber: <N>
```

Bucket assignment, in priority order (a PR that qualifies for multiple buckets goes into the highest-priority one):

1. **Drift bucket** — `mergeStateStatus` is `BEHIND` or `DIRTY`. The PR's branch is behind `develop` (BEHIND) or has merge conflicts (DIRTY); a refresh is the unblocking action.
2. **Review-stalled bucket** — `mergeStateStatus` is `CLEAN` or `HAS_HOOKS` AND no recent reviewer activity (no review, no PR-line comment, no `Reviewers requested` event inside the staleness window). The PR is technically mergeable but waiting on humans.
3. **Likely-abandoned bucket** — `isDraft: true` AND the PR's age (from creation, not last activity) is greater than `2 × <DAYS>`. This is an informational flag only; see the Stop conditions — `/stale-prs` does NOT close abandoned PRs.

Priority order is **drift > review-stalled > abandoned** — judgement call rationale: unblocking a mergeable PR (drift) returns more value than nudging humans (review-stalled), and an abandoned signal is the lowest because it is informational only. A PR that is both `BEHIND` and a stale draft goes into the drift bucket; a PR that is `CLEAN` and a stale draft goes into the abandoned bucket.

PRs whose `mergeStateStatus` cannot be classified (e.g. `UNKNOWN`, `BLOCKED`) and that do not match the abandoned criteria are dropped from this run with a one-line stdout note; do NOT post a comment for them.

## Step 3 — Build the per-PR triage report

For each PR in any bucket, build a comment body. The first line MUST be the codename so the Step 4 idempotency check can find prior runs.

**Codename pin (load-bearing invariant):** the codename line `STALE-PRS-<DATE>-<UTC_TIMESTAMP>` MUST be the literal first line of the comment body — no blank line above it, no leading whitespace, no quoting, no Markdown prefix (no `#`, no `>`, no list marker), and no surrounding formatting (no backticks, no bold). Step 4's `startswith("STALE-PRS-<DATE>-")` search depends on this exact invariant to locate today's prior comment on the PR and skip a duplicate post; any deviation (e.g. wrapping the codename in a heading or preceding it with a blank line) will cause Step 4 to miss the prior comment and post a duplicate. `<DATE>` is computed in the project timezone (UTC+3) as `YYYY-MM-DD`; `<UTC_TIMESTAMP>` is the wall-clock UTC timestamp of this run.

Body template:

```
STALE-PRS-<DATE>-<UTC_TIMESTAMP>

@<author-login> — this PR has been quiet for <age> days.

- Bucket: `<drift|review-stalled|likely-abandoned>`
- Last activity: <updatedAt> (<age> days ago)
- Merge state: `<mergeStateStatus>`
- Last review / comment: <link to the most recent review or PR comment, or `none in window`>

### Suggested action

<one of:>
- Drift: `git fetch origin develop && git merge --no-ff origin/develop` on `<headRefName>`, resolve any conflicts, push. Or re-run `/stale-prs --merge-develop` and the orchestrator will attempt the auto-merge.
- Review-stalled: ping reviewer `@<reviewer-login>` for re-review, or request a fresh reviewer if the original is unavailable.
- Likely-abandoned: no activity in <age> days on a draft — consider whether the work is still needed; this is an informational flag only, the PR will not be closed by automation.
```

Formatting rules:

- The `@<author-login>` mention is mandatory — it is how the author gets a GitHub notification.
- For the review-stalled bucket, surface the most-recent requested reviewer if available (from the PR's `requestedReviewers` / latest `review_requested` event); fall back to "ping a reviewer" if none is parseable.
- For the drift bucket under `--merge-develop`, if the auto-merge in Step 5 hits a conflict, append a final line to the same comment body: `Merge conflict detected — manual resolution needed on <headRefName>.` (See Step 5.)
- Age is computed as integer days, rounded down, in UTC.

## Step 4 — Post the per-PR triage comment (idempotent same-day)

For each PR with a built body, locate any prior comment from today's run:

```
mcp__github__pull_request_read
  method:     get_comments
  pullNumber: <N>
  perPage:    100
```

Filter comment bodies that start with `STALE-PRS-<DATE>-`. The codename header (Step 3) is the first line of every triage comment we post, so the prefix `STALE-PRS-<DATE>-` is enough to find a prior run **on the same UTC-project date** even though the timestamp suffix changes.

- If a prior comment with the prefix `STALE-PRS-<DATE>-` exists AND its date matches today's `<DATE>`: skip the post. Log `already commented today on #<N>; skipping` to stdout. This is the idempotency guarantee for same-day re-runs.
- If no prior same-day comment exists and not `--dry-run`:
  ```
  mcp__github__add_issue_comment
    owner:        berkayturanci
    repo:         smartinventory
    issue_number: <N>           # PR number — GitHub treats PRs as issues for comment APIs
    body:         <BODY>
  ```
- Under `--dry-run`: print `would comment on #<N>` followed by the indented body to stdout; no API call.

The same-day dedupe is the only reason `/stale-prs` is safe to re-run on a schedule (e.g. inside `/morning`). Do NOT skip or weaken it.

## Step 5 — `--merge-develop` action (only when the flag is set)

Skip this step entirely when `--merge-develop` is not set.

When the flag is set: for each PR in the **drift bucket** that is NOT a draft (drafts are skipped to avoid pushing work-in-progress branches that the author may be rebasing), the implementer-style helper performs the refresh.

The mechanical flow MUST mirror `/ship` Step 5f.0 — that step is the precedent for "merge `develop` into the PR branch with the same conflict heuristics" inside this codebase, and `/stale-prs` does not reinvent the conflict-resolution heuristic. Concretely, for each drift-bucket non-draft PR:

1. Fetch the PR's head branch:
   ```bash
   git fetch origin "<headRefName>" --quiet
   git checkout -B "stale-prs/<headRefName>" "origin/<headRefName>"
   ```
2. Merge `origin/develop`:
   ```bash
   git fetch origin develop --quiet
   git merge --no-ff origin/develop -m "merge: refresh <headRefName> with develop (via /stale-prs)"
   ```
3. Conflict handling — straightforward conflicts only, per `/ship` Step 5f.0:
   - If `git merge` exits 0, push:
     ```bash
     git push origin "HEAD:<headRefName>"
     ```
     Record `action: merge-pushed` for the summary table.
   - If `git merge` exits non-zero (any conflict whatsoever): **abort and skip**.
     ```bash
     git merge --abort
     ```
     Do NOT attempt to auto-resolve. Record `action: conflict-skipped` for the summary, and append the conflict note to the triage comment body before posting it in Step 4 (or as a follow-up comment if Step 4 already posted today's comment). Honest scope: arbitrary three-way conflicts are not safely auto-resolvable by automation; this command does NOT pretend otherwise.
4. Local cleanup:
   ```bash
   git checkout - --quiet
   git branch -D "stale-prs/<headRefName>" --quiet
   ```

Under `--dry-run`: print `would merge develop into branch <headRefName> for #<N>` to stdout per drift-bucket non-draft PR; perform no `git fetch`/`checkout`/`merge`/`push` mutations.

Per-PR failures (auth `403` on push, network drop on fetch, merge driver crash) MUST NOT abort the run for other PRs. Capture the failure as `action: error-skipped — <one-line reason>` in the summary and continue to the next PR.

## Step 6 — Session summary

Print the summary table to stdout AND write it locally to `docs/reports/stale-prs-<DATE>.md`. `docs/reports/*` is gitignored (see `.gitignore` line `docs/reports/*`), so the file is a local-only artefact — the same pattern `/ship` uses for its session reports.

Summary table format:

```
# Stale PRs — <DATE>

Threshold: <DAYS> days · --merge-develop: <true|false> · --dry-run: <true|false>

| PR | Title | Bucket | Action |
|---|---|---|---|
| #421 | Refactor BillingRepository | drift | merge-pushed |
| #432 | Add ItemDetail tests | drift | conflict-skipped |
| #440 | Docs: update CLAUDE.md | review-stalled | commented |
| #418 | WIP: experimental sync | likely-abandoned | commented |
| #415 | Update lockfile | drift | dry-run-noted |
```

The `Action` column uses one of: `commented`, `already-commented-today`, `merge-pushed`, `conflict-skipped`, `dry-run-noted`, `error-skipped — <reason>`.

If no open PRs are stale at the chosen threshold, write a single-line report `No stale PRs at threshold <DAYS> days.` and print the same line to stdout.

Under `--dry-run`: still write the local report file (it is local-only and informational); the `Action` column reflects the would-be actions (`dry-run-noted`).

## Stop conditions / safety invariants

- **Never close a stale PR.** The likely-abandoned bucket is an informational flag only. Closing PRs is a deliberate human decision.
- **Never re-trigger CI manually.** The only intentional CI side-effect is the natural retrigger from a `git push` after `--merge-develop` succeeds. No `gh run rerun`, no workflow_dispatch calls.
- **Never auto-resolve arbitrary merge conflicts.** Step 5 aborts on any conflict and records `conflict-skipped`. The precedent is `/ship` Step 5f.0; this command does not extend that precedent.
- **Per-PR errors must not abort the run.** Auth failures, push 403s, network drops, merge driver crashes — each is recorded in the summary as `error-skipped — <reason>` and the loop continues to the next PR.
- **Same-day idempotency.** Step 4's prefix dedupe MUST be honoured; re-running `/stale-prs` on the same UTC-project date must not post duplicate comments on the same PR.
- **No silent dry-run mutations.** Under `--dry-run`, every state-changing call (comment post, branch checkout, merge, push) MUST be redirected to stdout as a `would …: …` line and skipped. The session lock file (if any) is NOT touched.
- **Never modify the PR's tree contents** beyond the merge commit that brings in `origin/develop`. No file edits, no formatter passes, no auto-fix attempts.

## Prerequisites

- **`gh` CLI authenticated** with `repo` scope (used for any fallback when MCP coverage is insufficient — typically not needed in the happy path).
- **`git`** configured with push access to the repository for `--merge-develop` runs. Without push access the merge-push step will 403 and the PR is recorded as `error-skipped`.
- **GitHub MCP tools** authenticated with `repo` scope (PR list + PR read + comment).
- **`jq`** available on PATH for inline JSON parsing of any `gh`-shelled responses.
- `docs/reports/` exists (it does, with a `README.md`); the gitignore rule `docs/reports/*` keeps the per-run summary local-only.

## Examples

```
/stale-prs                       # default 7-day threshold, comment-only
/stale-prs 14                    # 14-day threshold, comment-only
/stale-prs 7 --merge-develop     # auto-refresh drift-bucket PRs
/stale-prs --dry-run             # show what would happen, no writes
```

- `/stale-prs` — default sweep: every open PR against `develop` whose last activity was more than 7 days ago gets bucketed and a triage comment with the author mention.
- `/stale-prs 14` — quieter sweep; useful for a fortnightly tidy when the 7-day cadence is too chatty.
- `/stale-prs 7 --merge-develop` — same triage plus an auto-`git merge --no-ff origin/develop` and push for each drift-bucket non-draft PR. Conflicts are skipped (recorded as `conflict-skipped`); the natural `git push` retriggers CI for the refreshed branch.
- `/stale-prs --dry-run` — full computation, no GitHub writes, no `git push`. Use this to sanity-check bucket assignments before letting the comment stream land on teammates' PRs.
