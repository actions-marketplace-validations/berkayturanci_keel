---
description: Daily morning briefing — CI status, open issues/PRs, priorities
allowed-tools: Bash(gh:*), Bash(python3:*), Bash(date:*), Bash(command:*), Bash(test:*), Read, Grep, mcp__github__list_issues, mcp__github__list_pull_requests
argument-hint: (no args)
---

You are running the morning briefing for SmartInventory. Output one structured report. Be terse.

## Language

The morning brief itself is written to `docs/reports/<DATE>-morning.md` and surfaces overnight `/ship` deferrals — write everything in English (see `AGENTS.md` § "Language Policy"). Free-form chat with the user may stay in any language.

## Step 0 — Detect environment

The signal-pulling step below has two code paths: a local path that uses the `gh` CLI, and a web/sandbox path that uses the GitHub MCP server tools. Detect once at the top via the Bash tool and remember the result for every signal:

```bash
if command -v gh >/dev/null 2>&1; then echo cli; else echo mcp; fi
```

- Output `cli` ⇒ `GH_MODE=cli`. Run the `gh ...` commands in Step 2 via the Bash tool as listed.
- Output `mcp` ⇒ `GH_MODE=mcp`. Run the GitHub MCP tool calls in Step 2 instead. State `Data source: GitHub MCP (no gh CLI in this runtime)` as a one-line note in the brief so the operator knows which path produced the data.

IMPORTANT: Do NOT embed bare bang-backtick `gh` markdown placeholders (the form `<bang><backtick>gh ...<backtick>`) in this file — the preprocessor expands them before Step 0 runs, defeating the GH_MODE gate. Always issue `gh` calls through the Bash tool, gated by the detected `GH_MODE`.

GitHub Actions runs are not available via the MCP server tools we have today. In `GH_MODE=mcp`, the **CI Health** section degrades to a one-line note: `CI Health unavailable in this runtime (no gh CLI, no MCP equivalent for Actions runs).` Do NOT error.

## Step 1 — Read priorities, last session, and overnight `/ship` deferrals
- Read `.claude/priorities.md` and the last entry in `.claude/sessions.md`
- If priorities.md hasn't been updated in 5+ days, flag it as stale.
- Read `docs/reports/morning-merge-queue-<DATE>.md` (where `<DATE>` is today in UTC+3, e.g. `morning-merge-queue-2026-05-19.md`) if it exists. This file is written by `/ship` when issues are deferred outside the UTC+3 09:00–23:59 merge window. Surface its contents at the **top** of the morning brief so deferred work is visible before anything else. Use the Bash tool to resolve the date (`TZ='Etc/GMT-3' date +%Y-%m-%d`) and to test for existence (`test -f …`).

## Step 2 — Pull live signals (run in parallel)

Issue every call below through a tool — Bash for `gh ...`, the named MCP tool otherwise. Make all calls for a given mode in parallel.

### GitHub Status

If `GH_MODE=cli`, run via Bash:
- `gh issue list --state=open --label=bug --limit=10`
- `gh pr list --state=open`
- `gh run list --limit=5 --json status,conclusion,name,headBranch,createdAt`

If `GH_MODE=mcp`, call:
- `mcp__github__list_issues` with `owner=berkayturanci`, `repo=smartinventory`, `state=open`, `labels=["bug"]`, `perPage=10`.
- `mcp__github__list_pull_requests` with `owner=berkayturanci`, `repo=smartinventory`, `state=open`.
- GitHub Actions runs: unavailable — note in CI Health section below.

### Active Fires (run in parallel)

If `GH_MODE=cli`, run via Bash:
- `gh issue list --state open --label severity:blocker`
- `gh issue list --state open --label alert:crash`
- `gh issue list --state open --label alert:review`
- `gh run list --workflow="Monitor — Firebase Analytics & Play Console" --limit=1 --json status,conclusion,createdAt,url`

If `GH_MODE=mcp`, call:
- `mcp__github__list_issues` with `owner=berkayturanci`, `repo=smartinventory`, `labels=["severity:blocker"]`, `state=open`.
- `mcp__github__list_issues` with `owner=berkayturanci`, `repo=smartinventory`, `labels=["alert:crash"]`, `state=open`.
- `mcp__github__list_issues` with `owner=berkayturanci`, `repo=smartinventory`, `labels=["alert:review"]`, `state=open`.
- Monitor workflow run: unavailable — note in CI Health section below.

### CI Health

If `GH_MODE=cli`, run via Bash:
- `gh run list --limit=1 --json status,conclusion,name,headBranch`
- If the last run failed: `gh run view --log-failed | tail -100`

If `GH_MODE=mcp`:
- Emit a single line in the report: `CI Health unavailable in this runtime (no gh CLI, no MCP equivalent for Actions runs).` Do NOT attempt to fetch run data.

## Step 2.5 — Production health cache (Crashlytics + Vitals, issue #783)

The daily prefetch jobs installed by `scripts/install-launchd-jobs.sh` write
two JSON files at 08:55 local:

- `docs/reports/cache/production-health-crashlytics-<YYYY-MM-DD>.json`
- `docs/reports/cache/production-health-vitals-<YYYY-MM-DD>.json`

Read both for **today's** UTC date. Treat the cache as **fresh** when the
file exists and its `generated_at` is within the last 24h.

- **Fresh cache** → render the `🩺 Production health` block per the ASCII
  mock in `docs/research/crashlytics-vitals-ingestion.md` §4, using the
  threshold table in §5 to assign `ok` / `⚠ watch` / `🚨 alert` badges.
  Deltas are computed against the 7-day mean of the Vitals timeline rows
  and against the Crashlytics report baseline. Surface cache age in minutes
  in the section header (`Source: ... (cache age: Nm)`).
- **Stale or missing cache** (file absent, or `generated_at` >24h old, or
  the file contains `{"dry_run": true}`) → render exactly one line:
  `🩺 Production health — no data — run scripts/fetch-crashlytics.sh and scripts/fetch-vitals.sh (see docs/operations/crashlytics-vitals-setup.md)`.
  Do NOT attempt a live fetch from inside `/morning`; the prefetch path is
  the contract.

Setup, IAM, and rotation are documented in
`docs/operations/crashlytics-vitals-setup.md`. Design rationale lives in
`docs/research/crashlytics-vitals-ingestion.md` — do not redesign here.

## Step 3 — Output format

```
🌅 SmartInventory Morning Brief — <date>
{data_source_banner}

🌙 Overnight /ship deferrals  ← only show if morning-merge-queue-<date>.md exists
- #N <title> — deferred reason — blocker? <yes|no>
- (If empty file or none deferred, omit this section)

🚨 Active Fires  ← only show if any available query returns results
- severity:blocker — #N <title>
- alert:crash — #N <title>
- alert:review — #N <title>
- {monitor_row}
- (If all available queries return empty, omit this section entirely)

{production_health_block}

📌 Top Priorities (from priorities.md)
1. ...
2. ...
3. ...

🛠 GitHub Status
• Open bugs: N | Open PRs: M
• {ci_health_line}
• (If failed: one-line failure summary)

📋 Open PRs
- #N <title> — <author> — <status>

🎯 Suggested focus today
- (one specific suggestion based on priorities + CI state)
```

### Conditional substitutions (apply based on `GH_MODE`)

Substitute the placeholders above with the row matching the detected mode. "Available queries" in the Active Fires omit-rule means the queries that actually executed under the current mode (4 in CLI mode, 3 in MCP mode because the Monitor workflow row has no MCP equivalent).

| Placeholder | `GH_MODE=cli` | `GH_MODE=mcp` |
|---|---|---|
| `{data_source_banner}` | omit the line entirely | `Data source: GitHub MCP (no gh CLI in this runtime)` |
| `{monitor_row}` | `Last Monitor — Firebase Analytics & Play Console run: ❌ failure on <createdAt> — <url>` (only if the run failed; otherwise omit) | `Monitor workflow status unavailable in MCP mode` |
| `{ci_health_line}` | `Last CI: <pass ✅ / fail ❌> on <branch>` | `CI Health unavailable in this runtime (no gh CLI, no MCP equivalent for Actions runs).` |
| `{production_health_block}` | rendered per Step 2.5 (full block on fresh cache; one-line `no data` notice on stale/missing cache) | same — independent of `GH_MODE` |

## Step 4 — Save the brief
Write the report to `docs/reports/<YYYY-MM-DD>-morning.md` (create docs/reports/ if needed). `docs/reports/` is gitignored (see `docs/reports/README.md`) — do NOT `git add` or commit this file.
