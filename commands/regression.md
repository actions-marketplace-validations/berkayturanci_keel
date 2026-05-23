---
description: Codebase-wide regression scan — fan out per-module subagents in parallel, deduplicate against existing GitHub issues, open new issues for high-confidence findings
allowed-tools: Bash(gh:*), Bash(git:*), Bash(date:*), Bash(grep:*), Bash(find:*), Bash(wc:*), Bash(printf:*), Bash(cat:*), Bash(jq:*), Bash(mkdir:*), Bash(rm:*), Bash(rmdir:*), Bash(kill:*), Bash(sleep:*), Bash(seq:*), Bash(command:*), Read, Grep, Agent, mcp__github__list_issues, mcp__github__search_issues, mcp__github__issue_write
argument-hint: (no args)
---

You are running a codebase-wide regression scan for SmartInventory. The goal is to surface real bugs and regressions as new GitHub issues — without duplicating issues that already exist.

This command composes existing pieces — read `AGENTS.md` first; it is the source of truth for branch rules, label taxonomy, do-not-touch list, and platform context. Do NOT duplicate workflow rules here.

## Runtime detection (gh vs GitHub MCP)

```bash
if command -v gh >/dev/null 2>&1; then
  GH_MODE=cli
else
  GH_MODE=mcp
fi
```

State the mode in the first user-facing line. The two state-changing call sites have MCP equivalents:

| gh CLI | GitHub MCP equivalent |
|---|---|
| `gh issue list --state all --label regression --limit 200 --json ...` (dedup pre-pass) | `mcp__github__list_issues` (state=`all`, labels=`["regression"]`, perPage=200). Apply the same field set on the returned JSON. |
| `gh search issues "is:issue (regression OR regresyon) in:title,body" --limit 200 --json ...` (dedup pre-pass, search arm) | `mcp__github__search_issues` with `owner=berkayturanci`, `repo=smartinventory` as separate parameters and `query=is:issue (regression OR regresyon) in:title,body` (do NOT add `repo:...` to the query string — repo scoping is handled by the parameters; the MCP tool would double-scope and zero-match if both are set). `perPage=200`. |
| `gh issue create --title "$TITLE" --label "$LABELS" --body "..."` (Step opening new issues) | `mcp__github__issue_write` (method=`create`, owner=`berkayturanci`, repo=`smartinventory`, title=`$TITLE`, body=same body string, labels=`$LABELS` as an array). |

In MCP mode the same union+dedup logic (`jq -s 'add | unique_by(.number)'`) runs against the JSON from the MCP calls. Failure semantics are identical (rate-limit/network → emit partial report, exit cleanly). The orchestrator's `AGENTS.md § Tool Permissions` carve-out for `/regression` permits `mcp__github__issue_write` (method=`create`) here.

Per-process tmpfile names (`${TMPDIR:-/tmp}/regression-$$-…`) are still used in both modes; the dedup pipeline is unchanged.

## Vocabulary mapping (reviewer ↔ severity ↔ outcome)

This command shares vocabulary with the standard reviewer flow (AGENTS.md step 9 + `code-reviewer` agent definition). Use the mapping below when classifying findings:

- `BLOCKER ≡ Must fix ≡ severity:blocker` — opened as an issue when high-confidence; downgraded to `severity:major` if only medium-confidence.
- `SUGGESTION ≡ Should fix ≡ severity:major` or `severity:minor` — opened as an issue.
- `NIT ≡ severity:nit` — informational, **never** opened as an issue (report-only).

## Runtime model (read this first)

`/regression` runs as a single Claude Code (or Codex) turn. The orchestrator fans out one `code-reviewer` subagent per module **in parallel** (single Agent-tool message with multiple invocations). Each module agent returns a finding list; the orchestrator does NOT let module agents post issues directly. The orchestrator then aggregates findings, runs a second-pass confidence check, deduplicates against existing GitHub issues, and opens new issues for the remaining set.

Module agents are read-only (no `gh issue create`, no `gh issue comment`, no file writes, no edits, no commits). The orchestrator owns every state-changing call.

## Step 0 — Preflight

```bash
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
CODENAME="REGRESSION-$TIMESTAMP"
```

State the codename in the first user-facing line.

`/regression` is gated by the GitHub CLI for issue listing, search, label creation, and issue creation. Run the cheap `gh` preflight FIRST — there is no point checking the working tree if `gh` is unavailable in this environment:

```bash
command -v gh >/dev/null || { printf '/regression: gh CLI not available — aborting.\n' >&2; exit 2; }
```

Then verify the working tree is clean — a regression scan against an unstable working tree produces noise:

```bash
if [ -n "$(git status --short)" ]; then
  printf '/regression: working tree dirty; commit or stash before scanning. Aborting.\n' >&2
  exit 2
fi
```

## Step 1 — Module fan-out (parallel)

Spawn one `code-reviewer` subagent per module in **a single Agent tool message** so they run concurrently. Modules:

| Module | Path | Focus |
|--------|------|-------|
| android | `android/` | Kotlin/Java logic, Realm, billing, lifecycle, threading, deprecated SDK APIs, Paparazzi/Espresso gaps |
| web | `web/` (excluding `web/functions/` — that path belongs to the `functions` agent) | Hosting assets, JS, JSON config, secret hygiene, deprecated DOM APIs |
| functions | `web/functions/` | Cloud Functions logic, Firebase Admin usage, dependency CVEs, secret leaks, log scrubbing |
| shared | `shared/` | Schema drift vs platform models, JSON Schema correctness |

The four module paths are disjoint by construction (`web/` minus `web/functions/`, plus `web/functions/` itself, plus `android/`, plus `shared/`). No two module agents see the same path.

Each module agent receives this prompt block (substitute `<MODULE>` and `<PATH>`):

```
Task: Regression scan for SmartInventory module `<MODULE>` (path: `<PATH>`).
Agent run codename: <CODENAME>-<MODULE>

Read `AGENTS.md` and the relevant platform context (`android/CLAUDE.md`,
`web/CLAUDE.md`, or `shared/README.md`) before scanning. Honour the
do-not-touch list: report findings, but do NOT propose fixes that would
require touching files on that list without a dedicated issue.

For the `web` module ONLY: explicitly EXCLUDE `web/functions/` from your
scan — that path is owned by the `functions` agent and double-scanning
produces duplicate findings.

Scan `<PATH>` for the following classes of regression:

  1. Logic errors — off-by-one, incorrect branch, wrong operator, unreachable
     code, swapped arguments.
  2. Null-safety / NPE risks — Kotlin platform types from Java, `!!` on
     nullable, missing null guards, `lateinit` read before init.
  3. Lifecycle / threading — Activity/Fragment leaks, Realm thread confinement,
     coroutine scope leaks, blocking calls on the main thread.
  4. Deprecated API usage — Android SDK deprecations relevant to the project's
     minSdk/targetSdk, Firebase SDK deprecations, Node runtime deprecations.
  5. Security — OWASP top 10, Firebase rules over-permission, hardcoded
     secrets/keys/tokens, log statements that leak PII or credentials.
  6. Performance regressions — N+1 queries, redundant Realm reads, large
     allocations on the main thread, missing pagination.
  7. Missing tests — public methods with no coverage and no documented stub
     reason, untested error paths.
  8. Misconfiguration — Gradle/Firebase/CI config that contradicts documented
     behaviour, schema drift between `shared/schema/firebase/` and platform
     models.

DO NOT post any GitHub comment. DO NOT call `gh issue create`,
`gh issue comment`, `gh pr comment`, `gh issue edit`, `gh issue close`,
`gh pr edit`, `gh pr ready`, `gh pr merge`, `gh label create`,
`gh api` (catch-all that bypasses every named subcommand — explicitly
forbidden so the LLM cannot use it as an escape hatch), or any
other GitHub write API. DO NOT run `git commit`, `git push`, `git reset`,
or any state-changing git command. DO NOT use Edit, Write, or any
file-mutation tool. You are read-only.

Return your findings to the orchestrator as your final message in the
following YAML-style block (one finding per `- ` list entry):

  CODENAME: <CODENAME>-<MODULE>
  MODULE: <MODULE>
  SCANNED:
    files: <int>
    lines: <int>
  FINDINGS:
    - severity: <blocker|major|minor|low-confidence>
      paths: <path/to/file.ext;path/to/other.ext>   # ';' separates multi-file findings
      line: <int|range like 12-18|"">                # may be empty for cross-cutting
      type: <null-safety|lifecycle|deprecated-api|security|perf|missing-test|misconfig|logic>
      description: <one-sentence problem statement>
      suggested_fix: <concrete file/line-targeted fix>
      confidence: <high|medium|low>

SEVERITY ∈ {blocker, major, minor, low-confidence}. Do NOT return `nit`
findings — they are dropped at aggregation by design; keep the agent
return format minimal. TYPE is the short tag listed above; pick the
closest single tag (do not invent new types).

Confidence rubric:
- high   — you can quote the exact offending line and the failure mode is
           reproducible by inspection.
- medium — the smell is real but the failure mode requires runtime context
           you cannot verify from the source alone. Tiebreaker: if the
           failure requires a specific input value or call site to
           manifest, classify as `medium` even if the line itself is
           quotable.
- low    — speculative; pattern-matched but not confirmed.

Prefer fewer high-confidence findings over broad speculation.
```

## Step 2 — Aggregate + second-pass confidence check

Collect every module agent's findings into a single list. For each finding:

1. **Drop low-confidence findings from the issue-creation set.** They are still surfaced in the final report (Step 6) under "Low-confidence — review-only", but no GitHub issue is opened for them.
2. **Within-agent dedup.** If a single module agent reports the same `(path, line, type)` triple twice, collapse to one finding. If a single agent reports the same `(path, type)` on different lines, keep both — they may be different defects in the same file.
3. **Closed-issue cross-validation (replaces a cross-agent promotion rule that was unreachable by construction — module paths are disjoint, so two agents can never flag the same `(path, type)` pair).** A medium-confidence finding whose `(path, type)` matches a CLOSED existing issue under the Step 3 dedup rule is **promoted to high-confidence** and opened as a regression-of issue (see Step 3 for title format and `regression-of: #N` body cross-reference). This converts what would otherwise silently swallow legitimate regressions into an explicit signal.
4. **Severity sanity** — `blocker` requires high-confidence; downgrade `blocker` to `major` if confidence is medium. Module agents are instructed in Step 1 not to return `nit` findings; if one slips through, drop it at aggregation (report-only).

The remaining set is the **issue-creation candidate set**.

## Step 3 — Deduplicate against existing GitHub issues

Pull both labelled and search-matched candidate issues, then dedup by `.number`. Both calls cap at the canonical 200-row window; the union covers labelled issues that the search would miss and search hits that lack the label:

Use per-process tmpfile names (`${TMPDIR:-/tmp}/regression-$$-…`) so two concurrent `/regression` invocations on the same host cannot stomp each other's intermediate JSON. Capture the exit code of each `gh` call and bail with the partial report if either hits 403 / rate-limit; validate the JSON with `jq -e` before union so a truncated file does not feed garbage into the dedup pass:

```bash
TMP="${TMPDIR:-/tmp}"
LABELLED_JSON="$TMP/regression-$$-labelled.json"
SEARCH_JSON="$TMP/regression-$$-search.json"
EXISTING_JSON="$TMP/regression-$$-existing.json"

# Labelled set (any state):
if ! gh issue list --state all --label regression --limit 200 \
    --json number,title,body,state,labels > "$LABELLED_JSON"; then
  printf '/regression: gh issue list failed (rate limit / network) — printing partial report and exiting.\n' >&2
  # Fall through to Step 6 final-report block; do NOT call jq -s on incomplete data.
  exit 2
fi

# Search set: parenthesise the OR group, scope to issues only, default to local repo.
# The OR form below retains the legacy token for one release of backward-compat
# dedup so issues opened under the previous command name are still matched.
if ! gh search issues "is:issue (regression OR regresyon) in:title,body" \
    --limit 200 \
    --json number,title,body,state,labels > "$SEARCH_JSON"; then
  printf '/regression: gh search issues failed (rate limit / network) — printing partial report and exiting.\n' >&2
  exit 2
fi

# Validate both files are well-formed JSON before union (truncated payloads on
# rate-limit can pass the exit-code check on some gh versions).
jq -e '.' "$LABELLED_JSON" >/dev/null || { printf '/regression: labelled JSON malformed — aborting before union.\n' >&2; exit 2; }
jq -e '.' "$SEARCH_JSON"   >/dev/null || { printf '/regression: search JSON malformed — aborting before union.\n' >&2; exit 2; }

# Union, deduped by .number:
jq -s 'add | unique_by(.number)' "$LABELLED_JSON" "$SEARCH_JSON" > "$EXISTING_JSON"
```

The Step 3 dedup pass reads `$EXISTING_JSON` (the union, deduped by `.number`).

For each candidate finding, mark as duplicate when **ALL** of the following hold:

1. **Path match (token boundary, two-step tokenisation).** The candidate `paths` field is FIRST split on `;` to obtain individual paths (single path ⇒ list of one). Each individual path is THEN tokenised on `/`, `:`, whitespace, backticks, and quote characters; the existing issue's title and the first 200 characters of its body are tokenised the same way. A path matches when **EVERY** token from that path appears as a whole token in the search corpus (substring matches inside longer tokens like candidate `User.kt` matching `MainUser.kt`, `UserAdapter.kt`, or `User.kt.bak` do **NOT** count). For multi-file findings, **EVERY** path in the candidate must match — any-match is not sufficient.
2. **Type match.** The TYPE tag from Step 1 (e.g. `null-safety`, `lifecycle`, `security`) appears in the existing issue's labels (e.g. `severity:major`, or a future per-type label) OR in the first 200 characters of the body as a whole token (same tokenisation as above).
3. **Near-text match (Jaccard ≥ 0.6).** Compute token Jaccard similarity `|A ∩ B| / |A ∪ B|` between:
   - **A** = the first sentence of the candidate `description` field, normalised to lowercase ASCII (strip diacritics), with stop-words removed, and non-alphanumeric characters replaced by spaces. The stop-word list MUST cover both languages the corpus uses (legacy issue bodies opened under the previous command name were Turkish; new `/regression` finding descriptions are English, but the Turkish stop-words are retained so backward-compat dedup against pre-existing Turkish issues still works): English — `a, an, the, of, in, on, at, to, for, and, or, is, are, was, were, be, been, being, this, that, these, those, with, from, by, as, it, its`; Turkish — `ve, için, bu, bir, ile, da, de, ki, mi, mu, ya, veya, ama, çünkü, gibi, kadar, daha, en, çok, az, var, yok, olan, olarak`.
   - **B** = the existing issue's title PLUS the first 200 characters of its body, normalised the same way.
   The candidate matches the existing issue when `Jaccard(A, B) ≥ 0.6`. **Edge case:** if `|A ∪ B| = 0` (both sides reduce to the empty set after stop-word removal), define `Jaccard := 0` (no match) — never `0/0` and never an automatic match.

"**Body opening**" is defined as the first 200 characters of the issue body, after stripping leading whitespace and any leading `## …` heading lines (skip heading lines, then take the first 200 characters of the remainder).

Outcome by existing-issue state:

- **Match against an OPEN issue** ⇒ **drop** the candidate from the issue-creation set; record under "Duplicates skipped" with the matching issue number.
- **Match against a CLOSED issue** ⇒ **promote** (per Step 2 rule 3): open a NEW issue titled `[regression] Possible regression of #N — <one-line summary>` and include `regression-of: #N` on a line of its own at the bottom of the body so the cross-reference is grep-able and renders as a GitHub auto-link. Do NOT silently swallow.

## Step 4 — Open new issues (orchestrator only)

For each remaining candidate, open a GitHub issue.

Required shell variables for this step (the orchestrator must populate every one before invoking the block below — these are substituted by the un-quoted HEREDOC and any literal `$` in the body MUST be escaped as `\$`):

| Variable | Source | Example |
|----------|--------|---------|
| `CODENAME` | Step 0 | `REGRESSION-20260507-220000` |
| `MODULE` | Step 1 (the agent's module) | `android` |
| `PLATFORM_LABEL` | derived from `MODULE` (see label rules below) | `android` |
| `SEVERITY` | Step 2 (after sanity check) | `major` |
| `TITLE_SUMMARY` | Step 1 finding | `NPE in UtilPremium when User is null` |
| `PATH_LINE` | Step 1 `paths` + `line` joined as `path:line` | `android/.../UtilPremium.java:142` |
| `DESCRIPTION` | Step 1 `description` (one paragraph) | `When …` |
| `EVIDENCE` | Step 1 grep/snippet | inline snippet |
| `FIX_PROPOSAL` | Step 1 `suggested_fix` | `add explicit null guard …` |
| `WHY_SEVERITY` | one short sentence justifying severity | `crash on every cold start for free users` |

If the candidate was promoted from a closed-issue match (Step 3 outcome 2), set `TITLE_SUMMARY="Possible regression of #N — <summary>"` and append `regression-of: #N` as the last line of `$DESCRIPTION`. Note: `regression-of:` is NOT a GitHub linking keyword (unlike `closes`/`fixes`), so the closed issue receives no automatic timeline back-reference — the `#N` token still renders as a clickable auto-link in the new issue's body, which is sufficient for forensic traceability. Use the bottom-line form only; do NOT also create a separate `## Cross-reference` block (one canonical shape avoids grep ambiguity).

Idempotent label creation — label colour map fixed below. `severity:nit` is created here so it exists for cross-command use (the AGENTS.md taxonomy documents it as the active `NIT` reviewer label), but `/regression` itself never applies it: Step 2 drops `nit` from the issue-creation set. `grep -qxF` (fixed-string, full-line) is used to avoid future labels with regex metacharacters (e.g. `severity:p1.high`) being misinterpreted as basic regular expressions:

```bash
ensure_label() {
  local NAME="$1" COLOR="$2"
  gh label list --json name -q '.[].name' | grep -qxF "$NAME" \
    || gh label create "$NAME" --color "$COLOR"
}

ensure_label regression         5319E7
ensure_label bug                D73A4A
ensure_label severity:blocker   BB1818
ensure_label severity:major     E99695
ensure_label severity:minor     FBCA04
ensure_label severity:nit       BFD4F2
ensure_label android            1D76DB
ensure_label web                0E8A16
ensure_label shared             B60205
```

Open the issue. The HEREDOC opener is **un-quoted** (`<<EOF`, not `<<'EOF'`) so shell variables expand into the body; literal dollar signs elsewhere in the body MUST be escaped as `\$`. Labels are passed as a single double-quoted string so the shell does not interpret `<` / `>` as redirection:

```bash
gh issue create \
  --title "[regression] $TITLE_SUMMARY" \
  --label "regression,bug,severity:${SEVERITY},${PLATFORM_LABEL}" \
  --body "$(cat <<EOF
## Problem
$DESCRIPTION

## Location
\`$PATH_LINE\`

## Reproduction / evidence
$EVIDENCE

## Suggested fix
$FIX_PROPOSAL

## Severity
$SEVERITY — $WHY_SEVERITY

---
Discovered by \`/regression\` scan — codename \`$CODENAME\`.
Module agent: \`$CODENAME-$MODULE\`.
EOF
)"
```

Labels:

- Always: `regression`, `bug`.
- Severity: `severity:blocker`, `severity:major`, `severity:minor`. (`severity:nit` is never opened — report-only.)
- Platform: `android` for findings under `android/`; `web` for findings under `web/` or `web/functions/`; `shared` for findings under `shared/`. Apply both `web` and `shared` if a finding spans schema + Web Functions (set `PLATFORM_LABEL` to `web,shared` in that case — `gh issue create --label` accepts a comma-separated value).

Capture each opened issue's number for the final report.

### Concurrency: Step 3–4 mutex

Wrap Steps 3–4 in a `mkdir`-based mutex (mirroring `/ship`'s `merge.lock.d` pattern) so two concurrent `/regression` invocations cannot race on `gh issue create` and produce double-opens. Stale-lock recovery and the bounded retry loop mirror `/ship` Step 5f.1 (atomic `mkdir` on local POSIX filesystems; NOT safe across NFS):

```bash
cd "$(git rev-parse --show-toplevel)"
mkdir -p .claude
LOCK_DIR=".claude/regression.lock.d"

# Stale-lock recovery: dead PID owner ⇒ reclaim.
if [ -d "$LOCK_DIR" ] && [ -f "$LOCK_DIR/owner" ]; then
  STALE_PID=$(cat "$LOCK_DIR/owner" 2>/dev/null || true)
  if [ -n "$STALE_PID" ] && ! kill -0 "$STALE_PID" 2>/dev/null; then
    rm -f "$LOCK_DIR/owner"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
fi

# Acquire (atomic mkdir, retry up to ~10 min — same cadence as /ship Step 5f.1).
ACQUIRED=false
for i in $(seq 1 60); do
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    ACQUIRED=true
    printf '%s\n' "$$" > "$LOCK_DIR/owner"
    break
  fi
  sleep 10
done

if [ "$ACQUIRED" != "true" ]; then
  printf '/regression: regression.lock.d held >10 min — another scan is in progress. Aborting.\n' >&2
  exit 2
fi

# Release MUST clear `owner` first — rmdir fails on non-empty dirs.
trap 'rm -f "$LOCK_DIR/owner" 2>/dev/null; rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

# … run Step 3 dedup queries AND every per-finding Step 4 `gh issue create` here …
```

The lock spans Steps 3 and 4 only — module agents in Step 1 are read-only and do not need it.

**Trap scope — single bash invocation required.** The release `trap` above only spans the bash invocation that registered it. Run all of Step 3 (dedup queries) AND every per-finding Step 4 `gh issue create` call **inside a single `bash -c '…'` invocation** so the trap stays alive across the full issue-creation sweep. The orchestrator's Bash tool MUST emit Steps 3–4 as one block. Splitting across multiple Bash tool calls leaks the lock between calls — the trap fires after the first invocation and releases the directory; every subsequent `gh issue create` then runs unprotected, defeating the mutex and allowing concurrent `/regression` invocations to double-open issues. Use `printf '%s\n' "$$"` (NOT `echo`) for the owner file because `Bash(echo:*)` is not in `allowed-tools`; under strict tool-permission gating an `echo` redirect would silently fail and break stale-lock recovery.

**Manual recovery.** If the lock leaks (e.g. earlier process killed mid-sweep, owner file removed but `rmdir` failed, host crash), reclaim with `rm -rf .claude/regression.lock.d` from the repo root.

## Step 5 — Severity distribution

Tally the opened issues by severity:

```
blocker: <count>
major:   <count>
minor:   <count>
```

This is the at-a-glance signal for the human reading the final output.

## Step 6 — Final command output

Print this block as the last user-facing message:

```
/regression — codename <CODENAME>

Scan
  modules: android, web, functions, shared
  files scanned: <int>
  lines scanned: <int>

Findings
  raw:                <int>
  after confidence:   <int>
  duplicates skipped: <int> (refs: #<n>, #<n>, …)
  promoted regressions of closed issues: <int> (refs: #<n>, …)
  opened:             <int>

Severity distribution
  blocker: <int>
  major:   <int>
  minor:   <int>

Opened issues
  - #<n> [<severity>] <title>
  - …

Low-confidence — review-only (NOT opened as issues)
  - <module> | <path:line> | <type> | <one-line description>
  - …
```

## Stop conditions

- All four module agents returned findings (or confirmed clean) **OR** were timed out / skipped per the rules below.
- **Per-agent timeout: 10 minutes.** If a module agent does not return within 10 minutes, skip its module in the report and flag under "Open questions". The other agents' findings still proceed through Steps 2–6.
- `gh` returns `403: API rate limit exceeded` ⇒ print the partial report (raw findings, dedupe state, what would have been opened) and exit without opening further issues.
- Module agent fails to return (error, crash, refusal) ⇒ skip its module in the report and flag under "Open questions".
- User cancels.

Always print the final report on exit, even if partial.

## Safety invariants

- Module agents are read-only. Only the orchestrator calls `gh issue create` / `gh label create`. Module agent prompts explicitly forbid `gh issue create`, `gh issue edit`, `gh issue close`, `gh issue comment`, `gh pr edit`, `gh pr ready`, `gh pr merge`, `gh pr comment`, `gh label create`, `git commit`, `git push`, `git reset`, and any file-mutation tool (`Edit`, `Write`).
- Never open issues for low-confidence findings; never open issues for `nit` severity.
- Never re-open a finding that matches an existing OPEN issue under the dedup rule (path-token + type + Jaccard ≥ 0.6). CLOSED-issue matches are PROMOTED (regression-of), not silently dropped.
- Do not edit code, do not push branches, do not open PRs — `/regression` is scan-only.
- Honour the do-not-touch list when proposing fixes (see `AGENTS.md` § Work Session Continuity Rule → What NOT to do when continuing, and `android/CLAUDE.md`). The fix proposal in an issue body must not silently assume one of those files can be edited.
