---
description: Detect intermittently failing tests across recent CI runs; open a tracking issue per flaky test
allowed-tools: Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(grep:*), Bash(sed:*), Bash(awk:*), Bash(sort:*), Bash(uniq:*), Bash(find:*), Bash(date:*), Bash(command:*), Read, Agent, mcp__github__issue_read, mcp__github__issue_write, mcp__github__add_issue_comment, mcp__github__list_issues, mcp__github__search_issues, mcp__github__get_file_contents, mcp__github__list_commits, mcp__github__pull_request_read
argument-hint: [days] [--threshold P] [--dry-run]
---

You are running an on-demand flaky-test audit for ingreview.

## Runtime detection (gh vs GitHub MCP)

```bash
if command -v gh >/dev/null 2>&1; then
  GH_MODE=cli
else
  GH_MODE=mcp
fi
```

State the mode in the first user-facing line. **Runtime-availability gate.** This command fundamentally requires GitHub Actions APIs (`gh api repos/.../commits/<SHA>/check-runs`, `gh run download` for test-level artifact analysis) — none of which have an MCP equivalent today. Under `GH_MODE=mcp`, exit cleanly with one line:

```
/flake-audit unavailable in this runtime — flake detection requires GitHub Actions check-run and artifact APIs, which require the gh CLI (no MCP equivalent today). Re-run from a local checkout with gh installed.
```

Do NOT error or partial-run. The Steps below execute only under `GH_MODE=cli`.

The command is **read-only on test code**: it never modifies test sources, never auto-disables tests (no `@Skip`, no `skip:`, no test modifier), never reruns a test to "confirm" flakiness, and never closes existing flake issues. It looks at recent CI history on `main`, aggregates per-test pass/fail counts where the data is available, classifies tests whose failure rate crosses the threshold, deduplicates against open flake issues, and opens one new tracking issue per newly-detected flake.

## Language

All committed/published artifacts MUST be written in English.

## Step 0 — Parse arguments

Argument grammar:

- Positional, optional: a single positive integer `[days]` — the lookback window in calendar days. Default: `14`. Reject `0` or negative integers, non-integers, and more than one positional.
- `--threshold <P>` — minimum failure rate to flag, as a decimal float in the closed interval `[0, 1]`. Default: `0.10` (10%). Reject anything outside `[0, 1]`, non-numeric values, and a missing value immediately after the flag.
- `--dry-run` — boolean; compute the report and print the findings to stdout, but skip every `mcp__github__issue_write` mutation.
- Reject unknown flags.

Worked examples:

```
/flake-audit                          → DAYS=14 THRESHOLD=0.10
/flake-audit 7                        → DAYS=7  THRESHOLD=0.10
/flake-audit 30 --threshold 0.05      → DAYS=30 THRESHOLD=0.05
/flake-audit --dry-run                → DAYS=14 THRESHOLD=0.10 DRY_RUN=true
```

## Step 1 — Fetch recent CI runs

Target workflows: `Flutter CI` and `Supabase CI` on the `main` branch, within the last `<DAYS>` calendar days (UTC).

1. Enumerate commits on `main` within the window:

   ```
   mcp__github__list_commits
     owner: berkayturanci
     repo:  ingreview
     sha:   main
     since: <ISO-8601 timestamp DAYS ago>
   ```

   Paginate (`perPage: 100`) until the window is covered.

2. For each commit, resolve any merged PR via the `gh` CLI fallback when needed, then pull the head-commit check runs:

   ```
   mcp__github__pull_request_read
     method:     get_check_runs
     pullNumber: <PR for the commit, if any>
   ```

   For commits not associated with a PR, use `gh api repos/berkayturanci/ingreview/commits/<SHA>/check-runs` when MCP coverage is insufficient.

3. For each check run keep: `conclusion`, `name`, `started_at`, `details_url`, `archive_download_url`.

### Limitations

The MCP surface does not let us enumerate workflow runs directly by date range or download artifact archives. Step 2 has two operating modes. Print which mode was used at the top of the "Limitations" section of the report.

## Step 2 — Parse test reports

For each check run with `conclusion = failure`, attempt to fetch the test-report artifact:

- **Flutter**: JUnit XML at the workflow-uploaded path (typically `apps/mobile/build/test-results/**/*.xml`).
- **Supabase functions**: Deno test output (`supabase/functions/test-results.json` or the workflow's JSON capture).

Artifact download requires the `archive_download_url`. If reachable through `Bash(gh:*)` (`gh run download <run-id> --name <artifact-name>`), proceed in **test-level mode**. If unreachable, proceed in **degraded run-level mode**:

- **Test-level mode (full fidelity):** parse each JUnit XML / Deno JSON file. Build an aggregate keyed by **fully-qualified test name**. Track `pass_count` and `fail_count`. Capture the first 5 lines of the failure stack trace for use in Step 6.

- **Degraded run-level mode:** aggregate at the **workflow-run** level only. Skip per-test classification (Step 3) and per-flake issue creation (Step 6) — produce only a Limitations-flagged summary in Step 5.

## Step 3 — Classify flakes

Only applies in test-level mode.

For each fully-qualified test name with both passes and failures observed in the window, classify as **flaky** if:

```
fail_count >= 3
AND fail_count / (pass_count + fail_count) >= <THRESHOLD>
```

Tests that have never passed in the window are deterministic failures, not flakes — do NOT classify them.

## Step 4 — Dedupe against existing flake issues

```
mcp__github__search_issues
  query: repo:berkayturanci/ingreview is:open label:flaky-test
```

Build the set of already-tracked names by stripping the `flaky test: ` prefix from each matching title. For every test classified as flaky in Step 3, skip it if its name is already in the tracked set.

## Step 5 — Build the report

Format as a single markdown body printed to stdout. The first line MUST be the codename.

**Codename pin:** `FLAKE-AUDIT-<DATE>-<UTC_TIMESTAMP>` MUST be the literal first line — no blank line, no whitespace, no Markdown prefix.

```
FLAKE-AUDIT-<DATE>-<UTC_TIMESTAMP>

## Flake audit — window `<DAYS>` days · threshold `<THRESHOLD>`

Summary: runs examined: <n> | distinct failing tests: <n> | classified flakes: <n> | newly-opened issues: <n>

### Newly-classified flakes
| Test | Fail rate | Failures | Sample run URLs | Stack trace excerpt |
|---|---|---|---|---|
| apps/mobile/test/features/ocr/ocr_service_test.dart > OCRService > scan returns ingredients | 18.2% | 4 / 22 | <url1>, <url2>, <url3> | <first 5 lines> |

### Already-tracked (deduped)
- `apps/mobile/test/features/analysis/risk_engine_test.dart > RiskEngine > computes score` — see #<existing-issue>

### Limitations
- Operated in `<test-level|run-level degraded>` mode.
- <Any per-step gap>
```

Formatting rules:
- Omit "Newly-classified flakes" table if zero new flakes; render `_no new flakes above threshold_` instead.
- Omit "Already-tracked" section if no test was deduped.
- Omit "Limitations" section if no degradation occurred.

## Step 6 — Open issues per new flake

For each test in the "Newly-classified flakes" set (test-level mode only):

- Under `--dry-run`: print `would create: flaky test: <fully.qualified.test.name>`.
- Otherwise:

  ```
  mcp__github__issue_write
    method: create
    title:  flaky test: <fully.qualified.test.name>
    body:   <see body template below>
    labels: <see label rules below>
  ```

Issue body template:

```
Detected by `FLAKE-AUDIT-<DATE>-<UTC_TIMESTAMP>` over the last <DAYS> days.

- Fail rate: <pct>% (<fail_count> / <total_runs>)
- Threshold: <THRESHOLD>

### Sample runs
- <url1>
- <url2>
- <url3>

### Stack trace excerpt (most recent failure)
```
<first 5 lines>
```

Triage:
- This test failed intermittently — do NOT auto-disable. Investigate root cause (timing, shared state, network, ordering).
- Close this issue with a fix PR, or mark `status:wontfix` if the test is being retired.
```

Label rules:
- Always apply `flaky-test`.
- Apply `area:flutter` if the test name / source path contains `apps/mobile/` or `packages/`.
- Apply `area:supabase` if the test name / source path contains `supabase/`.
- If neither matches, apply only `flaky-test` and note the platform was indeterminate.

Label prerequisites: the `flaky-test` label may not exist yet. Pre-create it once:

```bash
gh label create flaky-test --color B60205 --description "Test fails intermittently in CI"
```

If missing at runtime, retry issue creation without the label and emit a Limitations bullet.

## Step 7 — Print and log

Always print the report body from Step 5 to stdout, even when not `--dry-run`.

## Stop conditions / safety invariants

- **Never auto-disable a flaky test.** No edits to `*_test.dart`, `*.test.ts`, `*_spec.dart`.
- **Never rerun a test to "confirm" flakiness.** Only observed CI history counts.
- **One flake = one issue.** Step 4 dedupe is load-bearing.
- **On any sub-step failure, continue with what was successfully fetched.**
- **No silent dry-run mutations.**
- **Never close, edit, or comment on existing flake issues.**

## Prerequisites

- **Test artifact upload:** the `Flutter CI` and `Supabase CI` workflows must upload their test reports (JUnit XML for Flutter; Deno test JSON for Supabase) as named workflow artifacts.
- **`flaky-test` label exists** in the repository (see Step 6).
- **`gh` CLI authenticated** with `repo` scope.
- **`jq`** available on PATH.
- **GitHub MCP tools** authenticated with `repo` scope.

## Examples

```
/flake-audit                          # last 14 days, 10% threshold
/flake-audit 7                        # last 7 days
/flake-audit 30 --threshold 0.05      # last 30 days, 5% threshold (more sensitive)
/flake-audit --dry-run                # show what would be opened, no API calls
```
