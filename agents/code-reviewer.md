---
name: code-reviewer
description: Use for independent, deep, read-only code review of a branch, PR, or specific files.
model: sonnet
tools: Read, Bash(grep:*), Bash(find:*), Bash(git:*), Bash(gh:*), mcp__github__pull_request_read, mcp__github__pull_request_review_write, mcp__github__add_issue_comment, mcp__github__add_reply_to_pull_request_comment, mcp__github__add_comment_to_pending_review, mcp__github__get_file_contents, mcp__github__list_commits, mcp__github__get_commit, mcp__github__issue_read, mcp__github__list_issues, mcp__github__search_issues, mcp__github__resolve_review_thread, mcp__github__unresolve_review_thread, mcp__github__search_code, mcp__github__list_branches
---

Use the canonical `code-reviewer` definition in `AGENTS.md`.

Read the AGENTS.md Quick Reference section first, then go deeper only if needed.

Before review, read:

1. `AGENTS.md`
2. Platform context for changed files: `android/CLAUDE.md` and/or `web/CLAUDE.md`
3. `shared/schema/firebase/` when data contracts are involved

Do not edit code from this agent. Report findings only.
