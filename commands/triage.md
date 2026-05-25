---
description: Auto-classify open GitHub issues missing a status:* label by spawning a classifier subagent and applying platform/priority/status labels from the existing label set
allowed-tools: Bash(gh:*), Bash(jq:*), Bash(grep:*), Bash(sort:*), Bash(command:*), Read, Agent, mcp__github__list_issues, mcp__github__issue_read, mcp__github__issue_write, mcp__github__add_issue_comment
argument-hint: [--dry-run]
---

You are auto-triaging open GitHub issues for SmartInventory.

The command scans open issues that are missing any `status:*` label, spawns a classifier subagent per issue that proposes a `platform:*` + `priority:*` + `status:*` label triple drawn **only from the existing repo label set**, and then applies those labels and posts a one-line audit comment. The command is **advisory and label-only**: it never modifies titles or bodies, never closes or assigns issues, and never invents new labels.

## Language

All committed/published artifacts (commits, branch names, PR/issue titles and bodies, comments, file contents, slash command definitions) MUST be written in English. Free-form chat with the user may stay in any language. See `AGENTS.md` § "Language Policy". The per-issue audit comment this command posts is a published artifact and MUST be English.

## Step 0 — Parse arguments

Argument grammar:

- `--dry-run` — boolean; perform every read but skip every `gh issue edit` (label add) and `gh issue comment` (comment post) mutation. Each would-be mutation is redirected to stdout as `DRY-RUN: <command>`.

No positional arguments. Reject:

- Any positional value.
- Unknown flags (anything starting with `--` other than `--dry-run`).

Worked examples:

```
/triage             → DRY_RUN=false
/triage --dry-run   → DRY_RUN=true
```

## Step 0 — Runtime detection (gh vs GitHub MCP)

```bash
if command -v gh >/dev/null 2>&1; then
  GH_MODE=cli
else
  GH_MODE=mcp
fi
```

State the detected mode in the first user-facing line. Mappings used below — apply whenever the prose names a `gh` call:

| gh CLI | GitHub MCP equivalent |
|---|---|
| `gh issue list --state open --json ...` (Step 1) | `mcp__github__list_issues` (state=`open`, perPage=100). Apply the same client-side jq filter (drop issues whose existing labels include any `status:*` prefix) on the JSON returned by MCP. |
| `gh issue view <N>` / `gh issue view <N> --comments` (subagent prose at Step 2) | `mcp__github__issue_read` (method=`get` or `get_comments`). Subagents in MCP mode use the MCP read tools; they remain read-only. |
| `gh issue comment <N> --body "..."` (Step 4) | `mcp__github__add_issue_comment` |
| `gh issue edit <N> --add-label "<X>,<Y>,<Z>"` (Step 4) | `mcp__github__issue_write` (method=`update`, `labels=[<union of existing + new>]`). MCP overwrites the label set — compute the union explicitly before calling. |

`--dry-run` semantics are unchanged; both modes redirect would-be mutations to `DRY-RUN:` stdout lines.

## Step 1 — Find issues missing a status:* label

List open issues and filter to those without any `status:` prefixed label:

```bash
gh issue list \
  --state open \
  --json number,title,labels,body \
  --limit 100 \
  | jq -c '.[] | select((.labels | map(.name) | map(select(startswith("status:"))) | length) == 0)'
```

Each emitted JSON object is one candidate issue. Capture `number`, `title`, `body`, and the existing `labels` array (you will not strip any pre-existing labels — you only **add** the missing platform / priority / status triple, and only where each component is currently absent).

If the result is empty, print `No untriaged issues — nothing to do.` and exit 0.

## Step 2 — Classify each issue via a subagent

For every candidate issue from Step 1, spawn one `general-purpose` agent (the `Agent` tool — that agent has read access to `gh` for any follow-up context lookup it wants). The agent's task is purely classification; it MUST NOT mutate anything (no `gh issue edit`, no `gh issue comment`). Propagate `DRY_RUN` into the prompt so the agent knows it is in read-only mode even when the flag is off — classification is always read-only.

### Allowed label set (closed vocabulary — do NOT invent new labels)

- Platform: one of `platform:android`, `platform:web`, `platform:shared`.
- Priority: one of `priority:critical`, `priority:high`, `priority:medium`, `priority:low`.
- Status: one of `status:backlog`, `status:in-progress`, `status:needs-review`, `status:needs-test`, `status:needs-fix`, `status:done`, `status:blocked`.

If the agent cannot confidently pick a platform from the issue body, default to `platform:shared`.

### Classifier subagent prompt (template)

```
You are classifying a single SmartInventory GitHub issue. Output exactly one JSON
object on stdout, nothing else:

  {"platform": "...", "priority": "...", "status": "...", "reasoning": "..."}

Constraints (closed vocabulary — picking anything outside these lists is a bug):
  platform ∈ {platform:android, platform:web, platform:shared}
  priority ∈ {priority:critical, priority:high, priority:medium, priority:low}
  status   ∈ {status:backlog, status:in-progress, status:needs-review,
              status:needs-test, status:needs-fix, status:done, status:blocked}
              OR the literal string "" (empty) if the issue body explicitly
              declares itself a meta/tracking/umbrella issue.

Priority heuristics:
  - Keywords "crash", "ANR", "alert", "security", "CVE", "data loss", "auth bypass"
    + body mentions user-visible impact or data loss ⇒ priority:critical.
  - Reproducible production bug, no data loss ⇒ priority:high.
  - Reproducible non-production bug, or a small feature ⇒ priority:medium.
  - Refactor / cleanup / docs / cosmetic / nice-to-have ⇒ priority:low.

Status:
  - Default to status:backlog for any fresh untriaged issue.
  - If the body explicitly says this is a meta/tracking/umbrella issue (e.g.
    "tracking issue for ...", "meta:" prefix, an issue body that is purely a
    checklist of other issue links), set status to "" and explain in reasoning;
    the orchestrator will post a note and skip the status label.

Platform heuristics:
  - Files / paths mentioned under android/ ⇒ platform:android.
  - Files / paths mentioned under web/ ⇒ platform:web.
  - Docs, AGENTS.md, .claude/, slash commands, shared schema ⇒ platform:shared.
  - If unclear, default to platform:shared.

reasoning MUST be a single sentence ≤ 120 chars, English.

Issue payload:
  number: <N>
  title: <TITLE>
  existing labels: <CSV of label names>
  body: <BODY>

You MAY run `gh issue view <N>` or `gh issue view <N> --comments` for extra
context but MUST NOT run any mutating gh command. You are in read-only mode
regardless of the orchestrator's --dry-run flag.
```

Parse the agent's JSON response. Validate every field is in the allowed set; if validation fails, log `skip #<N>: classifier returned out-of-vocabulary label '<value>'` and move on (do not retry, do not guess — silent fallback would let bad labels leak in).

## Step 3 — Apply labels (or print the dry-run table)

Build the proposed label set per issue:

- Only add `platform:*` if the issue currently has no `platform:*` label.
- Only add `priority:*` if the issue currently has no `priority:*` label.
- Only add `status:*` if the classifier returned a non-empty status (so meta/tracking issues stay status-less).

### Under `--dry-run`

Print a table to stdout and exit:

```
DRY-RUN — proposed classification
| # | title | proposed labels | reasoning |
|---|---|---|---|
| 512 | bug: foo crashes on resume | platform:android,priority:high,status:backlog | reproducible crash on Android resume path |
| 519 | docs: typo in AGENTS.md | platform:shared,priority:low,status:backlog | cosmetic docs fix |
```

No `gh` writes occur. Both the comment post AND the label edit are skipped — log each as `DRY-RUN: gh issue comment <N> --body "..."` and `DRY-RUN: gh issue edit <N> --add-label "..."`.

### Otherwise (live run)

For each issue, in order:

1. Post one audit comment:

   ```bash
   gh issue comment <N> --body "auto-triaged: \`<labels>\` — <reasoning>"
   ```

   where `<labels>` is the comma-joined proposed label set (only the labels actually being added — not pre-existing labels) and `<reasoning>` is the one-sentence reason from the classifier.

2. Apply the labels:

   ```bash
   gh issue edit <N> --add-label "<labels>"
   ```

   `--add-label` is additive and accepts a comma-separated list; do NOT use `--remove-label` and do NOT pass labels not in the closed vocabulary.

If either call fails for an issue, log the failure and continue with the next issue (one bad issue does not abort the run).

## Step 4 — Session summary

After the loop, print a one-screen summary to stdout:

```
Triage summary
--------------
classified: <n>
skipped (meta / out-of-vocab / api error): <n>
dry-run: <true|false>
```

Under `--dry-run`, `classified` reflects the count of would-be classifications, not actual writes.

## Stop conditions / safety invariants

- **Never invent labels.** The platform / priority / status vocabularies above are the entire allowed set. If `gh label list` ever changes, update this spec in the same commit — do not silently broaden the vocabulary at runtime.
- **Never modify titles or bodies.** This command only adds labels and posts comments.
- **Never close or assign issues.** Closure and assignment are human / `/ship` decisions.
- **`--dry-run` propagates to subagents.** Classifier subagents are read-only regardless; the prompt states this explicitly so an agent does not start running `gh issue edit` on its own.
- **One issue's failure does not abort the run.** Per-issue errors are logged and the loop continues; only Step 0 argument parsing is fatal.
- **No silent dry-run mutations.** Under `--dry-run`, every state-changing call (comment post, label edit) MUST be redirected to stdout as `DRY-RUN: <command>` and skipped.

## Prerequisites

- **`gh` CLI** authenticated with `repo` scope (issue read, issue edit, issue comment).
- **`jq`** available on PATH for filtering the issue list.
- The closed label vocabulary above must exist in the repo. Verify once via `gh label list` after editing this spec; if any label is missing, fix the repo labels (not this command) before invoking.

## Examples

```
/triage             # live: classify every untriaged open issue and apply labels
/triage --dry-run   # show the proposed classification table, make no writes
```

- `/triage` — full sweep: every open issue missing a `status:*` label gets a `platform:* + priority:* + status:backlog` triple (status omitted for meta/tracking issues), one audit comment per issue.
- `/triage --dry-run` — full computation, no GitHub writes; useful to sanity-check the classifier's choices before letting them land.