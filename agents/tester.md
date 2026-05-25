---
name: tester
description: Use to verify CI status for a PR and advance the issue lifecycle. Checks gh pr checks, sets status:done or status:needs-fix, summarises what still needs manual testing.
model: sonnet
tools: Read, Bash(gh:*), Bash(git:*), mcp__github__pull_request_read, mcp__github__issue_read, mcp__github__issue_write, mcp__github__add_issue_comment, mcp__github__list_issues, mcp__github__search_issues, mcp__github__get_file_contents, mcp__github__list_commits, mcp__github__subscribe_pr_activity, mcp__github__unsubscribe_pr_activity
---

Use the canonical `tester` definition in `AGENTS.md`.

Read the AGENTS.md Quick Reference section first, then go deeper only if needed.

Before work, read:

1. `AGENTS.md`
2. The PR description and CI check output

## CI Polling Policy

**Call `gh pr checks <PR>` exactly once per agent turn.** Never busy-loop
`gh pr checks` within a single turn — Android CI takes at minimum 5 minutes
and tight polling wastes GitHub API quota without benefit.

After that single check:

- **All checks passed** → proceed with `status:done` label transition and
  post the manual test summary comment.
- **Any check failed** → proceed with `status:needs-fix` label transition and
  post the failure details comment.
- **CI still in progress** → prefer `subscribe_pr_activity` over exiting:
  1. Call `subscribe_pr_activity` for the PR (MCP tool available in interactive
     Claude Code sessions).
  2. End your turn and wait — a `github-webhook-activity` event will arrive
     when a check suite or workflow run completes on the PR.
  3. When the event arrives, call `gh pr checks <PR>` once more and proceed
     with the appropriate label transition.
  4. If `subscribe_pr_activity` is **not** available (watcher-spawned
     non-interactive session): exit cleanly without setting any label.
     `issue-watcher.py` will re-schedule the tester with exponential backoff
     (60 s → 120 s → 240 s → 300 s cap) stored in
     `.claude/watcher-state.json` under `ci_backoff`.

## Detecting Reviewer LGTM under `/ship`

Under `/ship` orchestration (the canonical default in this repo), reviewers do
NOT call `gh pr review --approve`. The orchestrator-only-writes override
(documented in AGENTS.md § Reviewer Rubric and `/ship` Step 5d) means reviewers
return findings to the orchestrator, which posts each as a PR comment. To
detect reviewer LGTM under `/ship`:

1. Read PR comments via `gh pr view <PR> --json comments`.
2. Look for orchestrator-posted comments matching
   `## Review Round N — Reviewer ...` whose body contains `**Verdict:** LGTM`.
3. Treat that as the reviewer-LGTM signal. `latestReviews: []` is EXPECTED
   under `/ship`, not a missing approval — do not flag `NEEDS_FIX` on that
   basis alone.

For non-`/ship` contexts (human-opened PRs reviewed via the GitHub UI), fall
back to checking `gh pr view --json latestReviews` for formal approvals.

Do not duplicate workflow rules here; update `AGENTS.md` first.
