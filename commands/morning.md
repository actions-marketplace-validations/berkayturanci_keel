---
description: Daily morning briefing — CI status, open issues/PRs, priorities
allowed-tools: Bash(gh:*), Bash(date:*), Bash(command:*), Bash(test:*), Bash(stat:*), Bash(ls:*), Bash(sort:*), Bash(tail:*), Read, Grep, Write, PushNotification, mcp__github__list_issues, mcp__github__list_pull_requests
argument-hint: (no args)
---

You are running the morning briefing for ingreview. Output one structured report. Be terse.

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

### Step 1a — Persistent deferral queue

Read `.claude/deferrals.json` if it exists — this is the canonical cross-session deferral queue written by `/ship` when issues are deferred outside the UTC+3 07:00–01:30 merge window. Surface any entries at the **top** of the morning brief as "🌙 Overnight /ship deferrals". After surfacing the entries, clear the file by writing `[]` to it (the entries are now visible to the operator and will be picked up by the next `/ship` run).

Fall back to the legacy `docs/reports/morning-merge-queue-<DATE>.md` file for backward compatibility (where `<DATE>` is today in UTC+3). Use the Bash tool to resolve the date (`TZ='Etc/GMT-3' date +%Y-%m-%d`) and to test for existence (`test -f …`). If the legacy file exists and is non-empty, surface its contents in the same "🌙 Overnight /ship deferrals" section and append `(legacy queue — .claude/deferrals.json not present)`.

Read `.claude/priorities.md` and the last entry in `.claude/sessions.md`. If `priorities.md` hasn't been updated in 5+ days, flag it as stale.

### Step 1.5 — Completed-work summary

Query GitHub for issues closed and PRs merged since the last morning brief. Determine the cutoff timestamp:
- Find the most recent file matching `docs/reports/*-morning.md` via Bash: `ls docs/reports/*-morning.md 2>/dev/null | sort | tail -1`. Use its name (the date portion) as the cutoff.
- If no previous brief exists, default to 24h ago.

If `GH_MODE=cli`, run:
- `gh issue list --state closed --json number,title,closedAt --limit 20 --repo berkayturanci/ingreview` — filter client-side to issues closed after cutoff
- `gh pr list --state merged --json number,title,mergedAt --limit 20 --repo berkayturanci/ingreview` — filter client-side to PRs merged after cutoff

If `GH_MODE=mcp`, call:
- `mcp__github__list_issues` with `owner=berkayturanci`, `repo=ingreview`, `state=closed`, `perPage=20`
- `mcp__github__list_pull_requests` with `owner=berkayturanci`, `repo=ingreview`, `state=closed`, `perPage=20`

Surface a "✅ Shipped since last brief" section in the report. If nothing was shipped, omit the section.

## Step 2 — Pull live signals (run in parallel)

Issue every call below through a tool — Bash for `gh ...`, the named MCP tool otherwise. Make all calls for a given mode in parallel.

### GitHub Status

If `GH_MODE=cli`, run via Bash:
- `gh issue list --state=open --label=bug --limit=10 --repo berkayturanci/ingreview`
- `gh pr list --state=open --repo berkayturanci/ingreview`
- `gh run list --limit=5 --json status,conclusion,name,headBranch,createdAt --repo berkayturanci/ingreview`

If `GH_MODE=mcp`, call:
- `mcp__github__list_issues` with `owner=berkayturanci`, `repo=ingreview`, `state=open`, `labels=["bug"]`, `perPage=10`.
- `mcp__github__list_pull_requests` with `owner=berkayturanci`, `repo=ingreview`, `state=open`.
- GitHub Actions runs: unavailable — note in CI Health section below.

### Active Fires (run in parallel)

If `GH_MODE=cli`, run via Bash:
- `gh issue list --state open --label severity:blocker --repo berkayturanci/ingreview`
- `gh issue list --state open --label alert:crash --repo berkayturanci/ingreview`
- `gh issue list --state open --label alert:review --repo berkayturanci/ingreview`

If `GH_MODE=mcp`, call:
- `mcp__github__list_issues` with `owner=berkayturanci`, `repo=ingreview`, `labels=["severity:blocker"]`, `state=open`.
- `mcp__github__list_issues` with `owner=berkayturanci`, `repo=ingreview`, `labels=["alert:crash"]`, `state=open`.
- `mcp__github__list_issues` with `owner=berkayturanci`, `repo=ingreview`, `labels=["alert:review"]`, `state=open`.

### CI Health

If `GH_MODE=cli`, run via Bash:
- `gh run list --limit=1 --json status,conclusion,name,headBranch --repo berkayturanci/ingreview`
- If the last run failed: `gh run view --log-failed | tail -100`

If `GH_MODE=mcp`:
- Emit a single line in the report: `CI Health unavailable in this runtime (no gh CLI, no MCP equivalent for Actions runs).` Do NOT attempt to fetch run data.

## Step 2.5 — Production health (Supabase)

No Supabase MCP tool is available today. Render a fixed one-liner in the brief:

`🩺 Production health — unavailable (no Supabase MCP tool; check Supabase dashboard or run \`supabase inspect db\` manually)`

When a Supabase MCP tool becomes available, replace this step with a live fetch of key health signals (connection pool utilisation, slow queries, edge function error rates).

## Step 2.6 — Dynamic priority synthesis

Compute a ranked priority list from live GitHub state. This synthesises the dynamic data from Step 2 with the optional manual override in `priorities.md`.

Ranking order (highest priority first):
1. Open issues with label `severity:blocker` or `alert:crash`
2. Open PRs that are review-approved AND CI-green (ready to merge — check `mergeStateStatus`)
3. Open PRs with no activity in the last 3 days (stale)
4. Open issues with label `type:bug` and no assignee
5. CI failures on `main` (if `GH_MODE=cli`)

If `priorities.md` was updated in the last 24h, append its contents as a "📌 Manual focus" subsection after the dynamic list. Detect recency with:
```bash
# macOS
stat -f %m .claude/priorities.md 2>/dev/null
# Linux fallback
stat -c %Y .claude/priorities.md 2>/dev/null
```
Compare the returned epoch to `$(date -u +%s) - 86400`.

Surface the result as the "🎯 Priorities" section in the brief.

## Step 3 — Output format

```
🌅 ingreview Morning Brief — <date>
{data_source_banner}

🌙 Overnight /ship deferrals  ← only show if .claude/deferrals.json or morning-merge-queue-<date>.md has entries
- #N <title> — deferred reason — blocker? <yes|no>
- (If empty or absent, omit this section)

✅ Shipped since last brief  ← only show if issues were closed or PRs merged since cutoff
- #N <title> — merged/closed <relative time>
- (If nothing shipped, omit this section)

🚨 Active Fires  ← only show if any available query returns results
- severity:blocker — #N <title>
- alert:crash — #N <title>
- alert:review — #N <title>
- (If all available queries return empty, omit this section entirely)

{production_health_block}

🎯 Priorities
1. [dynamic — from Step 2.6]
2. ...
📌 Manual focus (from priorities.md):  ← only if priorities.md updated in last 24h
- ...

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

| Placeholder | `GH_MODE=cli` | `GH_MODE=mcp` |
|---|---|---|
| `{data_source_banner}` | omit the line entirely | `Data source: GitHub MCP (no gh CLI in this runtime)` |
| `{ci_health_line}` | `Last CI: <pass ✅ / fail ❌> on <branch>` | `CI Health unavailable in this runtime (no gh CLI, no MCP equivalent for Actions runs).` |
| `{production_health_block}` | `🩺 Production health — unavailable (no Supabase MCP tool; check Supabase dashboard or run \`supabase inspect db\` manually)` | same |

## Step 4 — Save the brief and notify

Write the report to `docs/reports/<YYYY-MM-DD>-morning.md` (create `docs/reports/` if needed). `docs/reports/` is gitignored — do NOT `git add` or commit this file.

After saving, fire a push notification summarising the brief:

```
PushNotification(
  title: "ingreview morning brief — <YYYY-MM-DD>",
  body: "<N> open PRs · <M> bugs · <fires_summary> · <deferred_summary>"
)
```

Where:
- `<fires_summary>` = `🚨 <K> fires` if any active fires, otherwise `✅ no fires`
- `<deferred_summary>` = `🌙 <K> deferred` if overnight deferrals exist, otherwise omit

## Step 5 — Scheduling note (first run only)

If no previous `docs/reports/*-morning.md` file exists (this is the first run), offer:

> Want me to schedule this as a daily 09:00 UTC+3 run? Type `/schedule daily 09:00 UTC+3 /morning` to register it.
