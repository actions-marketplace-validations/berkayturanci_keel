---
description: Autonomous work block — time-aware mode (night UTC+3 01:30–07:00 = no merges; day 07:00–01:30 = merge-as-you-go). Picks from priority queue, team review loop, morning/session report.
allowed-tools: Bash, Read, Edit, Write, Grep, Agent, mcp__github__issue_read, mcp__github__issue_write, mcp__github__list_issues, mcp__github__search_issues, mcp__github__add_issue_comment, mcp__github__pull_request_read, mcp__github__list_pull_requests, mcp__github__search_pull_requests, mcp__github__get_file_contents, mcp__github__list_commits, mcp__github__get_commit, mcp__github__list_branches, mcp__github__create_branch, mcp__github__get_label, mcp__github__search_code, mcp__github__create_pull_request, mcp__github__update_pull_request, mcp__github__push_files, mcp__github__add_reply_to_pull_request_comment
argument-hint: [hours] (optional, default 8)
---

## Language

All committed/published artifacts (commits, branch names, PR/issue titles and bodies, PR/issue comments, file contents, the overnight/session report) MUST be written in English. Free-form chat with the user may stay in any language. See `AGENTS.md` § "Language Policy".

## Step 0 — Detect mode (run this first)

```bash
TZ='Etc/GMT-3' date +%H%M
```

The mode boundary is keyed on the UTC+3 wall-clock `HHMM` (not just the hour),
so the cutover happens at `01:30` exactly:

| Current UTC+3 time | Mode | Merge rule |
|---|---|---|
| 01:30 – 06:59 | **Night** | No merges — except blockers. Write morning report at end. |
| 07:00 – 01:29 (next day) | **Day** | Merge CI-green + fully-reviewed PRs as you go. Write brief session summary at end. |

Set `MODE=night` or `MODE=day` in your reasoning and apply the correct merge rule throughout. The boundary matches `/ship`'s merge window (07:00–01:30) so both commands defer or merge the same PR at the same wall-clock minute.

---

## Two non-negotiable rules

1. **Night mode — no auto-merge except blockers.** Every PR stays open for the user to review and merge in the morning. The one exception: a PR may be merged at night if it is a **blocker** (see below) AND the full review loop in AGENTS.md step 9 is complete with CI green. The morning report must list it explicitly under "Merged at night — reason:".

   **Day mode** — merge each PR immediately once review loop is complete and CI is green.

2. **Work until `hours` runs out** (default 8h). If the primary queue empties early, expand test coverage, open modernisation issues, or improve CI infrastructure — never stop early.

### What counts as a blocker?

A PR qualifies for a night merge **only** if it is one of:

- A CI fix that is currently red on `develop` and is blocking every other queued PR.
- A foundational doc/process update that every subsequent overnight PR must read before starting.
- A data-safety or security fix that cannot wait until morning.

A regular feature PR, a Kotlin conversion, a test-only PR, or a docs cleanup is **not** a blocker — it stays unmerged in night mode.

**For everything else** — review protocol, issue lifecycle, branch naming, docs gate, do-not-touch list, code quality checklist — follow **AGENTS.md** exactly.

---

## Pre-flight

**Workspace isolation check** (`AGENTS.md` § "Workspace Isolation (AI agents)"): `/overnight` performs state mutations (creates PRs, merges PRs in day mode, spawns implementer subagents), so it MUST be invoked from a linked worktree, not the user's primary checkout. Detect with `git rev-parse --git-dir`: main worktree returns `.git`; linked worktrees return an absolute path containing `/.git/worktrees/<name>`. If the value is `.git`, ABORT and tell the user to re-run from a session worktree (create one via `git worktree add -b overnight/<date> worktrees/overnight-<date> origin/develop` per #931 — nested under repo root). When `/overnight` spawns implementer subagents, each subagent MUST also receive its own worktree under `worktrees/issue-<N>` (per `/implement` Step 5 and `/ship` Step 5a).

```bash
git fetch origin
git status          # if dirty → stop and ask the user
```

Scan open PRs and issues to build the session queue.

## Priority queue (refresh each session)

| Tier | Scope |
|------|-------|
| T0 | Blocker: CI red on develop → fix first |
| T1 | Open PRs with pending review rounds |
| T2 | Test coverage — util/ JVM batch, Espresso smoke, web Jest |
| T3 | CI/quality infrastructure — lint rules, threshold gate, workflow improvements |
| T4 | Kotlin conversion — small utility classes (do-not-touch list excluded) |
| T5 | Docs / backlog issues — AGENTS.md, CLAUDE.md, open new issues |

**Skip:** `#16` (Hilt), `#102` (ViewPager2) — too large for one session.

If a plan file exists under `/root/.claude/plans/`, use it as the queue instead.

## Session report (mandatory)

The report is written to the local filesystem only. `docs/reports/` is gitignored (see `docs/reports/README.md`) — do NOT `git add` / `git commit` the file.

**Night mode** → write `docs/reports/overnight-<YYYY-MM-DD>.md`
**Day mode** → write `docs/reports/session-<YYYY-MM-DD>-<HH>.md`

```markdown
# [Overnight / Session] Report — <DATE> <HH:MM>

## PRs Created
| # | Title | Issue | CI | Notes |

## PRs Touched (existing)
| # | Action | Result |

## Skipped / Deferred
- bullet list with reason

## Time Budget
| Tier | Planned | Actual | Notes |

## Open Questions
- bullets

## Next Steps
- 1-3 concrete actions
```

Output the file path when done.

## Stop conditions

- Time budget exceeded.
- Hard blocker (network, missing credentials, ambiguous requirement).
- Three consecutive PRs hit CI failures the agent cannot resolve.
- User cancels.

When stopped, write the session report immediately, even if partial.
