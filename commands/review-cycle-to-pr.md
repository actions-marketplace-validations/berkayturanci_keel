---
description: 3-reviewer parallel cycle for one or more PRs — code-quality / bugs+security / tests+regression. Each reviewer posts directly to the PR; orchestrator posts a consolidated summary and adds `review-cycle-complete`.
allowed-tools: Bash(gh:*), Bash(git:*), Bash(date:*), Bash(grep:*), Bash(sed:*), Bash(awk:*), Bash(printf:*), Bash(echo:*), Bash(test:*), Bash(command:*), Read, Agent, mcp__github__pull_request_read, mcp__github__add_issue_comment, mcp__github__update_pull_request, mcp__github__get_label
argument-hint: <pr_number> [pr_number ...]
---

You are running the ingreview 3-reviewer cycle for one or more pull requests. For each PR, three `code-reviewer` subagents review the same diff in parallel (same fan-out pattern as `/ship` Step 5c), each posts its own findings DIRECTLY to the PR as a review comment, and the orchestrator follows up with a consolidated summary plus a `review-cycle-complete` label.

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
| `gh pr view <PR> --json number,state,isDraft,headRefName,baseRefName,title,url` | `mcp__github__pull_request_read` (method=`get`). |
| `gh pr diff <PR>` (reviewer context) | `mcp__github__pull_request_read` (method=`get_files`) for the file list plus `mcp__github__get_file_contents` at the PR head SHA for any file the reviewer needs in full. |
| `gh pr comment <P> --body "..."` (reviewer post + consolidated summary) | `mcp__github__add_issue_comment`. When each `code-reviewer` is dispatched, pass `GH_MODE=<value>` in its prompt; in MCP mode the reviewer calls `mcp__github__add_issue_comment` directly. |
| `gh pr edit <P> --add-label review-cycle-complete` | Read current labels via `mcp__github__pull_request_read` → `labels[]`, compute the new full set (append `review-cycle-complete` if absent), then `mcp__github__update_pull_request` (labels=`[<new full set>]`). MCP overwrites; compute the union explicitly. |
| `gh label create review-cycle-complete ...` (idempotent label setup) | Detect with `mcp__github__get_label`; if 404, ask the operator to create it once via `gh label create` locally. |

This command reuses the `code-reviewer` subagent definition — it does NOT redefine review heuristics. Read `AGENTS.md` § "code-reviewer" first; that file is the source of truth for severity vocabulary and review focus areas.

## Runtime model (read this first)

`/review-cycle-to-pr` runs as a single Claude Code (or Codex) turn loop. PRs are processed **sequentially**. Within a single PR, the 3-reviewer fan-out at Step 3 is genuinely parallel (three Agent calls in a single assistant message).

Crucial divergence from `/ship` Step 5c: in `/ship`, reviewers RETURN findings to the orchestrator only. In `/review-cycle-to-pr`, **each reviewer posts its own findings directly to the PR as a review comment**. The orchestrator only posts the consolidated summary and applies the label.

This command never pushes code, never opens or closes PRs, never merges.

## Step 0 — Parse arguments

- One or more positive integers, each treated as a PR number.
- Reject empty argument list, non-integers, zero or negative integers.

State the parsed `PRS=[...]` list in your first user-facing line.

## Step 1 — Validate PRs

For each PR number, validate it exists and is open:

```bash
gh pr view <PR> --json number,state,isDraft,headRefName,baseRefName,title,url
```

Drop PRs that are already merged or closed (warn the user). Continue with remaining open or draft PRs.

## Step 2 — Per-PR loop (sequential across PRs, parallel reviewers within a PR)

For each surviving PR `P`, run Steps 3 → 4 in order.

## Step 3 — Spawn 3 reviewers in parallel (single Agent-tool message)

Spawn THREE `code-reviewer` subagents in **a single Agent tool message** so they run concurrently.

Focus map (fixed at 3):

| Reviewer | Focus |
|----------|-------|
| Reviewer 1 | **Code quality & architecture** — refactoring opportunities, naming, abstraction layers, duplication, Dart idioms, Riverpod patterns, PLAN.md product invariants |
| Reviewer 2 | **Bugs & security** — logic errors, edge cases, null/nullability, OWASP categories, RLS policy gaps, Supabase query safety, input validation, secret hygiene |
| Reviewer 3 | **Tests & regression** — coverage of new/changed logic, behavior preservation, backward compatibility, schema migration safety, product invariant regression |

Each reviewer receives the canonical reviewer template from `AGENTS.md` § [Reviewer Rubric (canonical)] with `<PR>` and `<FOCUS>` filled in, plus this command's posting-contract REVERSAL of the `/ship` Step 5c return-only rule:

```
You are reviewing PR #<P> for ingreview.
Codename: REVIEW-CYCLE-<P>-<UTC_TIMESTAMP>-<1|2|3>
Focus: <Reviewer focus from the table above>

POSTING CONTRACT (this command's divergence from /ship):
You MUST post your findings DIRECTLY to PR #<P> as a review comment via
`gh pr comment <P> --body "..."` (or equivalent in MCP mode).

Comment body format:

  ## Review (focus: <focus>) — codename `REVIEW-CYCLE-<P>-<UTC_TIMESTAMP>-<N>`

  **Verdict:** LGTM | LGTM with suggestions | Needs fixes

  **Findings**

  | Severity | File:Line | Description | Suggested fix |
  | -------- | --------- | ----------- | ------------- |
  | BLOCKER  | …         | …           | …             |
  | SUGGESTION (major) | … | …         | …             |
  | SUGGESTION (minor) | … | …         | …             |
  | NIT      | …         | …           | …             |

  You MUST emit `major` / `minor` explicitly in the SUGGESTION rows.

After posting, return to the orchestrator the SAME findings in this
machine-readable block:

  CODENAME: REVIEW-CYCLE-<P>-<UTC_TIMESTAMP>-<N>
  FOCUS: <Reviewer 1 focus | Reviewer 2 focus | Reviewer 3 focus>
  VERDICT: LGTM | LGTM with suggestions | Needs fixes
  COUNTS: blocker=<n> major=<n> minor=<n> nit=<n>
  CLEAN_AREAS: <comma-separated areas checked and found clean>
  FINDINGS:
    <severity> | <file:line> | <description> | <suggested fix>
    …

Independence: per AGENTS.md § Reviewer Rubric (canonical) "Independent-
review rule (no cross-reading)" — your review must be fully independent
of the other two reviewers on PR #<P>.

Implementation: when reading PR context, prefer `gh pr view <P> --json
title,body,commits,files,headRefName,baseRefName` (no comments) plus
`gh pr diff <P>` for the diff. If you DO read PR comments for any reason,
apply the rubric's codename-prefix isolation pin — skip every comment
whose body contains the substring `REVIEW-CYCLE-<P>-`.
```

Generate a fresh codename per reviewer (`REVIEW-CYCLE-<P>-<UTC_TIMESTAMP>-1`, `…-2`, `…-3`).

## Step 4 — Consolidated summary comment + label

After all 3 reviewers finish, build and post ONE consolidated summary comment.

Severity histogram is the column-wise sum of each reviewer's `COUNTS` line.

Merge recommendation rule:

| Condition | Recommendation |
|-----------|----------------|
| Any reviewer's `VERDICT` is `Needs fixes` OR `blocker > 0` | block |
| `blocker == 0` AND `major + minor > 0` | request changes |
| `blocker + major + minor == 0` AND any reviewer's `VERDICT` is `LGTM with suggestions` (NITs only) | approve (with cosmetic nits) |
| `blocker + major + minor == 0` AND all 3 reviewers `LGTM` (no NITs) | approve |

Post the consolidated summary:

```bash
gh pr comment <P> --body "## Review-Cycle Summary — PR #<P>

Codename: \`REVIEW-CYCLE-<P>-<UTC_TIMESTAMP>\`
Reviewers: 3 (code-quality, bugs+security, tests+regression)

### Severity histogram
| Blocker | Major | Minor | Nit |
| ------- | ----- | ----- | --- |
| \$BLOCKER | \$MAJOR | \$MINOR | \$NIT |

### Clean areas
\$CLEAN_AREAS_AGGREGATED

### Per-reviewer verdicts
- R1 (code quality): \$VERDICT_1 — \`<codename 1>\`
- R2 (bugs & security): \$VERDICT_2 — \`<codename 2>\`
- R3 (tests & regression): \$VERDICT_3 — \`<codename 3>\`

### Merge recommendation
\$RECOMMENDATION  (approve / request changes / block)

This summary was posted by \`/review-cycle-to-pr\`."
```

Then add the label:

```bash
gh pr edit <P> --add-label review-cycle-complete
```

Handle missing label creation with a `mktemp`-based log file (race-tolerant).

## Step 5 — Final report (printed to user)

```
Review cycle complete.
PRs requested: <count>
PRs reviewed:  <count - skipped - failed>
Skipped (not open): <list>
Failed (reviewer error): <list with reason>
Per-PR results:
  - #<P> — recommendation=<approve|request changes|block> — blocker=<n> major=<n> minor=<n> nit=<n>
  - …
```

## Stop conditions

- Reviewer subagent fails entirely ⇒ mark THIS PR as failed, skip Step 4, continue with next PR.
- Reviewer posted PR comment BUT failed to return machine-readable block ⇒ re-fetch the comment via `gh pr view <P> --json comments` and parse it.
- Partial reviewer failure (1 of 3 fails) ⇒ post consolidated summary with surviving outputs and a clear note. Add label only if at least 2 of 3 reviewers succeeded.
- `gh` returns `403: API rate limit exceeded` ⇒ stop processing further PRs.
- User cancels.

Always print the final report on exit, even if partial.

## Safety invariants

- This command is read-only with respect to git: never `git commit`, `git push`, `git checkout`, `git merge`, `git rebase`, or any working-tree modification.
- This command is read-only with respect to PR state: never `gh pr merge`, `gh pr close`, `gh pr ready`, `gh pr review --approve`. Reviewers post regular comments only, NOT formal `gh pr review` approvals.
- The 3-reviewer divergence from `/ship` Step 5c (reviewers post their own comments) MUST be stated explicitly in every reviewer prompt at Step 3.
- Reviewer subagents must NOT read other reviewers' output.
- The `review-cycle-complete` label is applied by the orchestrator only after Step 4 succeeds.
- The consolidated summary posts AFTER the 3 reviewer comments.
- Codename format `REVIEW-CYCLE-<PR>-<UTC_TIMESTAMP>[-<N>]` is part of the audit trail; do not abbreviate.
