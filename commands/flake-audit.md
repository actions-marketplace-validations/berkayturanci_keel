---
description: Detect intermittently failing tests across recent CI runs; open a tracking issue per flaky test
allowed-tools: Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(grep:*), Bash(sed:*), Bash(awk:*), Bash(sort:*), Bash(uniq:*), Bash(find:*), Bash(date:*), Bash(command:*), Read, Agent, mcp__github__issue_read, mcp__github__issue_write, mcp__github__add_issue_comment, mcp__github__list_issues, mcp__github__search_issues, mcp__github__get_file_contents, mcp__github__list_commits, mcp__github__pull_request_read
argument-hint: [days] [--threshold P] [--dry-run]
---

You are running an on-demand flaky-test audit for SmartInventory.

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

Do NOT error or partial-run. The Steps below execute only under `GH_MODE=cli`. The dedup pre-pass (`gh issue list --label flaky` etc.) and issue creation (`gh issue create`) DO have MCP equivalents (`mcp__github__list_issues`, `mcp__github__issue_write`), but they are useless without the Actions data path — surfacing zero findings does not advance the workflow. Exit cleanly is the right behaviour.

The command is **read-only on test code**: it never modifies test sources, never auto-disables tests (no `@Ignore`, no `.skip`, no `test.only`), never reruns a test to "confirm" flakiness, and never closes existing flake issues. It looks at recent CI history on `develop`, aggregates per-test pass/fail counts where the data is available, classifies tests whose failure rate crosses the threshold, deduplicates against open flake issues, and opens one new tracking issue per newly-detected flake. Repeated runs of `/flake-audit` MUST NOT spam duplicates — the Step 4 dedupe is load-bearing.

## Language

All committed/published artifacts (commits, branch names, PR/issue titles and bodies, comments, file contents, slash command definitions) MUST be written in English. Free-form chat with the user may stay in any language. See `AGENTS.md` § "Language Policy". The flake-audit report printed to stdout and the per-flake issue bodies opened by this command are published artifacts and MUST be English.

## Step 0 — Parse arguments

Argument grammar:

- Positional, optional: a single positive integer `[days]` — the lookback window in calendar days. Default: `14`. Reject `0` or negative integers, non-integers, and more than one positional.
- `--threshold <P>` — minimum failure rate to flag, as a decimal float in the closed interval `[0, 1]`. Default: `0.10` (10%). Reject anything outside `[0, 1]`, non-numeric values, and a missing value immediately after the flag.
- `--dry-run` — boolean; compute the report and print the findings to stdout, but skip every `mcp__github__issue_write` (issue create) mutation. Under `--dry-run`, print `would create: <title>` per skipped issue.
- Reject unknown flags (anything starting with `--` not in the list above).

Worked examples:

```
/flake-audit                          → DAYS=14 THRESHOLD=0.10
/flake-audit 7                        → DAYS=7  THRESHOLD=0.10
/flake-audit 30 --threshold 0.05      → DAYS=30 THRESHOLD=0.05
/flake-audit --dry-run                → DAYS=14 THRESHOLD=0.10 DRY_RUN=true
```

## Step 1 — Fetch recent CI runs

Target workflows: `Android CI` and `Web CI` on the `develop` branch, within the last `<DAYS>` calendar days (UTC).

The current GitHub MCP toolset does not expose a direct "list workflow runs by date range" endpoint. Use the closest reachable substitute and document the gap honestly:

1. Enumerate commits on `develop` within the window:

   ```
   mcp__github__list_commits
     owner: berkayturanci
     repo:  smartinventory
     sha:   develop
     since: <ISO-8601 timestamp DAYS ago>
   ```

   Paginate (`perPage: 100`) until the window is covered.

2. For each commit, resolve any merged PR via the `gh` CLI fallback when needed, then pull the head-commit check runs:

   ```
   mcp__github__pull_request_read
     method:     get_check_runs
     pullNumber: <PR for the commit, if any>
   ```

   For commits not associated with a PR (direct push to `develop`), record the commit SHA and continue; check-run data may still be reachable via `gh api repos/berkayturanci/smartinventory/commits/<SHA>/check-runs` — invoke it under the allowed `Bash(gh:*)` tool when MCP coverage is insufficient.

3. For each check run keep:

   - `conclusion` (`success`, `failure`, `cancelled`, …)
   - `name` (e.g. `Android CI / unit-tests`, `Web CI / vitest`)
   - `started_at`
   - `details_url` (link to the workflow-run page; used in the report's "sample run URLs")
   - `archive_download_url` for the run's test-report artifact, **if** it can be extracted from `details_url` via the workflow-run API

### Limitations

The MCP surface does not let us enumerate workflow runs directly by date range, and it does not let us download artifact archives. Step 2 therefore has two operating modes depending on what the runtime can actually reach. The command MUST honestly print, at the top of the "Limitations" section of its report, which mode it operated in. Do not silently fall back without disclosure.

## Step 2 — Parse test reports

For each check run with `conclusion = failure`, attempt to fetch the test-report artifact:

- **Android**: JUnit XML at the workflow-uploaded path (typically `android/**/build/test-results/test*UnitTest/*.xml`).
- **Web**: Vitest or Jest JSON output (`web/coverage/test-results.json` or the workflow's `--reporter=json` capture).

Artifact download requires the `archive_download_url` exposed by the workflow-run API. If that URL is reachable through `Bash(gh:*)` (`gh run download <run-id> --name <artifact-name>`), proceed in **test-level mode**. If it cannot be reached at all from this runtime, proceed in **degraded run-level mode**:

- **Test-level mode (full fidelity):**
  - Parse each JUnit XML / Jest JSON file. For every test case across every run in the window, build an aggregate keyed by **fully-qualified test name** (e.g. `com.berkay.smartinventory.BillingRepositoryTest#refreshEntitlement_revokesOnExpiry` for Android, or `src/lib/inventory.test.ts > inventory > addItem` for Web). Track `pass_count` and `fail_count`.
  - Capture, per failing test, the first 5 lines of the failure stack trace / error message from the most recent failing run for use in Step 6.

- **Degraded run-level mode (no test-level granularity):**
  - Aggregate at the **workflow-run** level only: which runs failed, on which commit, with what `details_url`.
  - Skip the per-test classification (Step 3) entirely and skip the per-flake issue creation (Step 6) — produce only a Limitations-flagged summary in Step 5.

## Step 3 — Classify flakes

Only applies in test-level mode. In degraded run-level mode, skip this step.

For each fully-qualified test name with both passes and failures observed in the window, classify as **flaky** if:

```
fail_count >= 3
AND fail_count / (pass_count + fail_count) >= <THRESHOLD>
```

The `fail_count >= 3` floor is load-bearing: it prevents a single transient infrastructure blip from being labelled flaky. Tests that have never passed in the window are deterministic failures, not flakes — they belong to `/ci-check` and human triage, not here. Do NOT classify them.

## Step 4 — Dedupe against existing flake issues

Search for already-tracked flakes:

```
mcp__github__search_issues
  query: repo:berkayturanci/smartinventory is:open label:flaky-test
```

Read each issue's title. Open flake issues use the canonical title shape `flaky test: <fully.qualified.test.name>` (Step 6). Build the set of already-tracked names by stripping the `flaky test: ` prefix from each matching title.

For every test classified as flaky in Step 3, skip it if its name is already in the tracked set. Carry only **newly-classified** flakes forward to Steps 5 and 6.

The dedupe is the only reason this command is safe to re-run on a schedule. Do NOT skip or weaken it.

## Step 5 — Build the report

Format as a single markdown body printed to stdout. The first line MUST be the codename so future cross-references (`/morning`, ad-hoc searches in chat history) can locate this run.

**Codename pin (load-bearing invariant):** the codename line `FLAKE-AUDIT-<DATE>-<UTC_TIMESTAMP>` MUST be the literal first line of the report body — no blank line above it, no leading whitespace, no quoting, no Markdown prefix (no `#`, no `>`, no list marker), and no surrounding formatting (no backticks, no bold). Downstream consumers (morning briefing, future `/flake-audit` invocations cross-checking prior runs, ad-hoc grep) depend on this exact invariant to locate the run anchor; any deviation (e.g. wrapping the codename in a heading or preceding it with a blank line) will cause them to miss the report.

```
FLAKE-AUDIT-<DATE>-<UTC_TIMESTAMP>

## Flake audit — window `<DAYS>` days · threshold `<THRESHOLD>`

Summary: runs examined: <n> | distinct failing tests: <n> | classified flakes: <n> | newly-opened issues: <n>

### Newly-classified flakes
| Test | Fail rate | Failures | Sample run URLs | Stack trace excerpt |
|---|---|---|---|---|
| com.berkay.smartinventory.BillingRepositoryTest#refreshEntitlement_revokesOnExpiry | 18.2% | 4 / 22 | <url1>, <url2>, <url3> | <first 5 lines, fenced inline> |
| src/lib/inventory.test.ts > inventory > addItem | 12.5% | 3 / 24 | <url1>, <url2>, <url3> | <first 5 lines, fenced inline> |

### Already-tracked (deduped)
- `com.berkay.smartinventory.SyncManagerTest#syncOnce_retriesAfterTimeout` — see #<existing-issue>

### Limitations
- Operated in `<test-level|run-level degraded>` mode.
- <Any per-step gap: failed artifact download for run X, MCP could not enumerate workflow runs directly so commit-driven enumeration was used, etc.>
```

Formatting rules:

- "Sample run URLs" lists up to 3 distinct `details_url` values from the failing runs for that test, most-recent first.
- "Stack trace excerpt" is the first 5 lines of the failure message / stack from the most recent failing run, rendered as a fenced inline snippet (use a single backtick row if 5 lines fit on one logical line, or a fenced block in the table cell with `<br>` separators if the renderer requires it).
- Omit the "Newly-classified flakes" table entirely if there are zero new flakes; render the line `_no new flakes above threshold_` instead.
- Omit the "Already-tracked" section entirely if no test was deduped.
- Omit the "Limitations" section entirely if no degradation occurred; otherwise include it with every honest caveat from Step 1 and Step 2.
- In degraded run-level mode, replace the "Newly-classified flakes" table with a short list of failing runs (commit SHA, workflow name, `details_url`) and add a Limitations bullet `Test-level classification skipped — artifact download not reachable from the current runtime; see Prerequisites.`

## Step 6 — Open issues per new flake

For each test in the "Newly-classified flakes" set (test-level mode only; degraded run-level mode skips this step):

- Under `--dry-run`: print `would create: flaky test: <fully.qualified.test.name>` to stdout. No API call.
- Otherwise, create the issue:

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
- Apply `area:android` if the test name / source path contains `android/` or the JUnit class FQN starts with `com.berkay.smartinventory`.
- Apply `area:web` if the test name / source path contains `web/` or matches a Vitest/Jest file pattern (`*.test.ts`, `*.test.tsx`, `*.spec.ts`).
- If neither matches (rare — e.g. shared/functions), apply only `flaky-test` and add a comment in the issue body noting the platform was indeterminate.

Label prerequisites:

- The `flaky-test` label may not exist yet. The operator should pre-create it once with:

  ```bash
  gh label create flaky-test --color B60205 --description "Test fails intermittently in CI"
  ```

  Colour `B60205` (red) is a judgement call — it signals "this needs human attention" without being a CI-gating colour. If the label is missing at runtime, `mcp__github__issue_write` will fail to apply it; the command MUST detect that failure, retry the issue creation without the label, and emit a Limitations bullet recommending the operator create the label.

## Step 7 — Print and log

Always print the report body from Step 5 to stdout, even when not `--dry-run`. The in-session printout is how the operator confirms what happened — silent runs would force them to spelunk the issue tracker after the fact.

## Stop conditions / safety invariants

- **Never auto-disable a flaky test.** No edits to `*Test.kt`, `*.test.ts`, `*.spec.ts`. Adding `@Ignore`, `.skip`, or `test.only` to suppress a flaky test is a deliberate human decision, not an automation outcome.
- **Never rerun a test to "confirm" flakiness.** Only observed CI history counts. Reruns would invalidate the very signal we are measuring.
- **One flake = one issue.** Step 4 dedupe is load-bearing. Re-runs of `/flake-audit` against the same window MUST NOT open duplicates of already-tracked flakes.
- **On any sub-step failure (network, artifact download, MCP timeout), continue with what was successfully fetched.** Each gap is documented in the report's "Limitations" section. The only fatal case is argument-parse failure in Step 0.
- **No silent dry-run mutations.** Under `--dry-run`, every state-changing call (`issue create`) MUST be redirected to stdout as `would create: <title>` and skipped.
- **Never close, edit, or comment on existing flake issues.** Triage of open `flaky-test` issues is a human decision; this command only opens new ones.

## Prerequisites

- **Test artifact upload:** the `Android CI` and `Web CI` workflows must upload their test reports (JUnit XML for Android; Vitest/Jest JSON for Web) as named workflow artifacts. Inspect `.github/workflows/android-ci.yml` and `.github/workflows/web-ci.yml`. If the artifacts are not currently uploaded, the command **degrades gracefully** to run-level mode (Step 2) and emits a Limitations bullet noting that test-level classification requires a follow-up workflow change to publish test results as artifacts.
- **`flaky-test` label exists** in the repository (see Step 6). If missing, the command degrades by retrying issue creation without the label and emitting a Limitations bullet.
- **`gh` CLI authenticated** with `repo` scope (used as the fallback path for `archive_download_url` enumeration when MCP cannot reach workflow-run artifacts).
- **`jq`** available on PATH for JSON parsing of Jest output and `gh api` responses.
- **GitHub MCP tools** authenticated with `repo` scope (issue search + issue create + commit list + check-run read).

## Examples

```
/flake-audit                          # last 14 days, 10% threshold
/flake-audit 7                        # last 7 days
/flake-audit 30 --threshold 0.05      # last 30 days, 5% threshold (more sensitive)
/flake-audit --dry-run                # show what would be opened, no API calls
```

- `/flake-audit` — default sweep: last 14 days of `develop` CI, 10% failure-rate threshold, opens one issue per newly-detected flake.
- `/flake-audit 7` — shorter window for a weekly review; reduces noise from older history at the cost of needing 3 failures inside a smaller pool.
- `/flake-audit 30 --threshold 0.05` — longer window, more sensitive threshold; good for surfacing slow-burn flakes the default sweep misses.
- `/flake-audit --dry-run` — full computation, no GitHub writes; the rendered report is logged to stdout. Use this to sanity-check the would-be issue set before letting it land on the tracker.
