# Compound-learning step — specification

Issue: [#529](https://github.com/berkayturanci/smartinventory/issues/529).
Inspired by BattleTabs' use of Every's `/ce-compound` plugin.

## Execution gate (per #655 — mandatory)

Step 5g is **mandatory** when at least one classifier path (plugin or inline-prompt) is available in the runtime. The earlier "best-effort, never blocks" framing is superseded by #655 (operator clarification 2026-05-16). Silent skips are structurally impossible: the closure-comment template at `/ship` Step 5f.1 point 4 has a mandatory `Compound learning:` placeholder, followed by a post-Step-5g audit comment with the actual result. The absence of the audit comment in the per-issue lifecycle is the silent-skip signal — orchestrator MUST log it loudly.

Legitimate non-execution states (all 5):

| State | Closure-line value | Audit-comment requirement |
|-------|-------------------|---------------------------|
| `--dry-run` set | `n/a — dry-run mode` | optional |
| Merge deferred to morning queue | `deferred — next /ship session captures at merge` | required (single line, no audit-comment follow-up) |
| `gh pr merge` failed | `n/a — merge did not succeed` | optional |
| Compound-of-compound recursion guard | `skipped — compound-of-compound recursion guard` | optional |
| Runtime-availability skip (no plugin AND no inline-prompt) | `skipped — no classifier available in this runtime` | required + stdout warning |

For every other state (plugin available OR inline-prompt available, no precondition fires), Step 5g MUST execute and post the audit comment with `Compound learning: <classification> — <apply summary>`. See `/ship` Step 5g for the post-comment mechanism and Step 5f.1 point 4 for the closure-template integration.

## Overview

After a `/ship` session merges and closes an issue, the orchestrator runs a
"compound-learning" step that turns the freshly merged PR into durable
knowledge. The step is intentionally split in two halves:

1. **`scripts/compound-learning.sh`** — an agent-neutral shell script that
   bundles PR context (diff summary, review comments, CI status, files
   changed, commit subjects) into a structured payload on stdout. It must run
   standalone from any shell and never assumes Claude / Codex is in the
   environment.
2. **Agent-side classification** — the calling agent (Claude inside
   `/ship`, Codex inside the parity command) hands the bundle to its model
   and asks "What did we learn that future work should know?". The model
   answers with one of four classifications, and the agent applies the
   classification per § "Agent-side flow" below.

The step is implemented as the **`Step 5g`** subsection inside
`.claude/commands/ship.md`, immediately after `Step 5f.1` point 7 (the merge
lock release) and before `Step 6` (session report). The implementation is
called once per successfully merged PR.

The slash-command file lives at `.claude/commands/ship.md`. Issue #529's
prose uses the word "skill" loosely; the actual artefact is a slash command,
so this spec and the ship.md step both refer to it as the `/ship` command.

## CLI contract

```
compound-learning.sh <PR_NUMBER> [--format=json|markdown] [--dry-run]
```

### Arguments

| Position | Name        | Required | Validation                          |
|----------|-------------|----------|-------------------------------------|
| 1        | `PR_NUMBER` | yes      | Anchored regex `^[1-9][0-9]*$` — any other value (negatives, zero, hex, shell metacharacters) is rejected with exit 1. This is the only user-supplied input, so this validation is the script's primary injection defence. |

### Flags

| Flag              | Default     | Behaviour |
|-------------------|-------------|-----------|
| `--format=json`     | json (default) | Emit a single JSON object to stdout. |
| `--format=markdown` | —              | Emit a human-readable markdown bundle (same content, different shape). |
| `--dry-run`         | false          | Tag the bundle `"classification": "deferred"` so the calling agent knows NOT to act on it. The bundle content is otherwise identical. Used by `/ship --dry-run` and for operator inspection. |
| `-h`, `--help`      | —              | Show usage and exit 0. |

Unknown flags or values exit 1 with usage.

### Exit codes

| Code | Meaning              |
|------|----------------------|
| 0    | Success.             |
| 1    | Usage / dependency error (bad args, missing `gh`, missing `jq`, gh not authenticated). |
| 2    | PR not found (`gh pr view` returned nothing). |
| 3    | PR not merged. Compound learning only runs post-merge; the script refuses to bundle an open or closed-but-not-merged PR so callers cannot accidentally classify draft work. |

### Stdout (JSON shape, schema_version 1)

```json
{
  "schema_version": "1",
  "generated_at": "2026-05-13T15:47:33Z",
  "classification": "pending",
  "dry_run": false,
  "pr": {
    "number": 536,
    "title": "...",
    "state": "MERGED",
    "merged_at": "2026-05-13T15:18:27Z",
    "base_ref": "develop",
    "head_ref": "feature/...",
    "additions": 42,
    "deletions": 7,
    "changed_files": 3,
    "files": [ { "path": "...", "additions": 10, "deletions": 0 } ],
    "commit_subjects": [ "docs: ..." ],
    "reviews": [ { "author": { "login": "..." }, "state": "APPROVED" } ]
  },
  "diff": {
    "text": "<truncated unified diff>",
    "truncated": false,
    "total_lines": 142,
    "max_lines": 500
  },
  "comments": {
    "issue": "<text of `gh pr view --comments`>",
    "review_inline": [ /* `gh api repos/{owner}/{repo}/pulls/{N}/comments` array */ ]
  },
  "ci": { "statusCheckRollup": [ /* gh statusCheckRollup payload */ ] }
}
```

`classification` is always present:

- `"pending"` — bundle is ready for the calling agent to classify (normal
  invocation).
- `"deferred"` — `--dry-run` was set; the calling agent must log the bundle
  but MUST NOT act on it.

### Stdout (markdown shape)

Same content as JSON but rendered as a single markdown document with
sections: header / Files changed / Commit subjects / CI status / Diff /
Inline review comments / Issue-style PR comments. Suitable for operator
inspection via `compound-learning.sh 536 --format=markdown | less`.

### Truncation

The unified diff is capped at **500 lines** to keep the bundle inside a
single model-prompt budget. When truncation occurs, `diff.truncated` is
`true` and `diff.total_lines` records the un-truncated size so the agent
knows the picture is partial.

### Prerequisites

`gh` (GitHub CLI) and `jq` must be installed and `gh` must be authenticated.
If either is missing, the script exits 1 with a clear install hint on
stderr. There is no fallback — every supported calling environment (Claude
Code, Codex, plain shell) already has `gh` on the project's runner.

The script must NEVER perform any `cd` that permanently changes the caller's
working directory; it reads from the GitHub API only.

## Classification taxonomy

The model answers with **exactly one** of the four classifications below.
Multi-classification is not supported — if a PR truly produced two distinct
learnings, the agent runs Step 5g twice on the same bundle (idempotency is
guaranteed by the doc/issue dedupe at the apply step).

### 1. Rule

The PR exposed a **process / policy / non-negotiable** that future work
needs to follow.

- Examples: "Always run `./gradlew koverVerifyDebug` before pushing
  Android changes"; "Never commit credential JSON to `web/functions/`"; "Use
  `mkdir`-based locks, not `flock`, on this runner".
- Apply by: opening a **follow-up PR** that edits `AGENTS.md § Rules` (for
  cross-platform) or `android/CLAUDE.md` / `web/CLAUDE.md` (for
  platform-specific). The source PR is already closed; rules are never
  amended onto the closed PR.
- Branch name: `chore/compound-<PR>-rule` (where `<PR>` is the merged PR
  number).
- The compound Rule PR is **opened ready (not draft) AND merged inline
  within the same `/ship` cycle** that produced it. Reviewer fan-out and
  tester gate are skipped by design (`/ship.md` Step 5g Rule path); the
  classifier itself is the policy gate, and the implementer subagent is
  constrained to the Step 5b docs-only allowlist (`^\.claude/`, `^\.codex/`,
  `^docs/`, `.*\.md$`, `^AGENTS\.md$`, `^CLAUDE\.md$`) so the PR cannot
  silently land code changes. The merge bypasses the UTC+3 09:00–23:59
  window check (`BLOCKER=true` for the defensive re-check in Step 5f.1)
  so the rule lands atomically with the parent merge that produced it.
- **Failure path:** if the implementer rejects an out-of-allowlist payload,
  CI fails on the compound PR, mergeStateStatus is BEHIND/DIRTY and cannot
  be resolved in one iteration, the merge lock is unobtainable, or
  `gh pr merge` errors inside the lock — the compound PR is flipped back
  to draft and labelled `compound-followup` for operator follow-up. The
  main `/ship` cycle is NOT aborted.

### 2. Pattern doc

The PR demonstrated a **reusable pattern** — code shape, debug technique,
gotcha worth remembering — that does not rise to the level of a rule.

- Examples: "Realm migrations require a no-op chain when bumping schema
  version with no new fields"; "Firebase Functions tests must mock
  `request-promise` to stay offline".
- Apply by: opening and **inline-merging a follow-up PR** named
  `chore/compound-<PR_NUMBER>-pattern`, mirroring the Rule path. The PR
  adds `docs/<platform>/learnings/<short-slug>.md` and is merged in the
  same `/ship` cycle as the parent PR. Direct commits to `develop` are
  not used — `develop` is a protected branch and every change MUST go
  through a PR (see #642 for the migration rationale).
- File path examples: `docs/android/learnings/realm-noop-migration.md`,
  `docs/web/learnings/offline-test-mocking.md`. Platform sub-directory MUST
  exist; create it on first use.
- The slug is short (kebab-case, ≤6 words) and the file is ≤200 lines.
- Window bypass: the compound Pattern PR inherits the same window-bypass
  carve-out as the compound Rule PR — Step 5f.1's defensive window
  re-check treats it as `BLOCKER=true` so it lands atomically with the
  parent merge.
- Review/tester skip: like the Rule path, the compound Pattern PR is
  opened ready (not draft) and bypasses Step 5c–5e reviewer fan-out and
  Step 5e.bis tester gate. The trust trade-off is bounded by the
  docs-only allowlist constraint and the compound-of-compound recursion
  guard.
- Failure path: same as the Rule path — flip the compound PR back to
  draft and label `compound-followup` for operator follow-up. The main
  `/ship` cycle is NOT aborted.

### 3. Regression risk

The PR fixed something that could plausibly **regress without a test**, and
no test was added in the source PR.

- Examples: a Firebase rules edge case fixed by tightening a path; a
  Kotlin null-handling bug fixed without a unit test for the null branch.
- Apply by: opening a **new GitHub issue** via
  `mcp__github__issue_write` with labels `type:testing`,
  `priority:medium`, `status:backlog`. The body references the source
  PR (e.g. `Source: PR #536`) and describes the regression scenario the
  test should cover.
- The orchestrator's normal `Create GitHub issues = ✗` permission does
  NOT apply here; see § "Carve-out for issue creation".

### 4. Nothing

The PR was a chore, a typo fix, a docs-only restructure, or otherwise
produced no compoundable signal.

- Apply by: logging `no compoundable learning, skipping` into the session
  report's `## Compound learning` row. The bundle is discarded.
- This is the expected outcome for most docs / chore PRs.

## Agent-side flow

Inside `/ship` Step 5g:

```
1. Skip preconditions:
   - --dry-run set                     → log "would invoke compound-learning.sh <PR>" and exit 5g.
   - merge was deferred                → log "merge deferred to morning; learning runs next session" and exit 5g.
   - source PR's head branch matches `chore/compound-*`
                                       → log "compound-of-compound, skipping recursive learning capture" and exit 5g.
                                         Prevents runaway chains; a docs-only edit to AGENTS.md / CLAUDE.md
                                         does not itself yield further compoundable signal.

2. Invoke `scripts/compound-learning.sh <PR>` and capture stdout to a variable.
   If the script exits non-zero, log the error to the session report and exit 5g
   (a failed bundle is not worth blocking the report on).

3. Classify the bundle. Two paths exist (see `§ Codex parity > Dual
   classifier path (issue #547)`):

   a. **Claude Code with `/ce-compound` plugin available** ⇒ invoke the
      plugin with the bundle as input. The plugin returns a
      `{classification, payload}`-shaped object (parsing layer adapts the
      plugin's native schema if it differs — see TODO in § Codex parity).
   b. **Codex / Claude Code without the plugin / plugin invocation
      failure** ⇒ fall back to the inline prompt below. This is the only
      path Codex ever takes.

   Inline-prompt fallback text (parity-locked — do NOT paraphrase):

   "Below is a structured context bundle for a PR that just merged into
    develop. Classify the durable learning this PR represents into exactly
    one of: Rule, Pattern doc, Regression risk, Nothing. If Rule or Pattern
    doc, write the proposed text. If Regression risk, write the issue title
    and one-paragraph body. Return as JSON: {classification, payload}."

   The bundle goes in verbatim (it is already capped at a sensible size).

4. Switch on the returned classification:
   - Rule           → open follow-up PR (branch chore/compound-<PR>-rule)
                      AND merge it inline in the same /ship cycle: Step 5b CI gate
                      (docs-only allowlist), SKIP Step 5c–5e + Step 5e.bis,
                      minimal Step 5f.0 (one BEHIND/DIRTY resolution pass),
                      Step 5f.1 with window-bypass (BLOCKER=true for the
                      defensive re-check). Failure ⇒ flip PR to draft + add
                      `compound-followup` label + log + skip.
   - Pattern doc    → open + inline-merge `chore/compound-<PR>-pattern`
                      PR (same shape as the Rule path: opened ready, no
                      reviewer/tester fan-out, mini Step 5b, minimal Step
                      5f.0, Step 5f.1 with window-bypass). Failure ⇒ flip
                      PR to draft + add `compound-followup` label + log
                      + skip.
   - Regression risk → mcp__github__issue_write with type:testing + priority:medium + status:backlog.
   - Nothing        → log skip line.

5. Append a `## Compound learning` row to the session report:
   `# | PR | Classification | Classifier | Apply action`. The
   `Classifier` column records which path produced the row (`plugin` or
   `inline`) — see § "Dual classifier path (issue #547)".
```

The fixed-prompt-text invariant is what makes Codex parity possible on
the inline-prompt path: both agents see the same bundle shape and the
same instruction, so the output distribution converges. The Claude-Code
plugin path (issue #547) bypasses the inline prompt entirely but is
required to return the same `{classification, payload}` shape, so points
3–5 above dispatch identically regardless of which classifier ran.

## Codex parity

Codex's `/ship` equivalent calls `scripts/compound-learning.sh` with the
same CLI contract and the same model prompt. The script is intentionally
agent-neutral — there are no Claude-only assumptions, no `mcp__*` calls in
the script, no environment variables peculiar to Claude Code. The Codex
playbook for `/ship` MUST reuse this script verbatim; if Codex adds an
adapter step (e.g. piping the bundle into a different model harness), the
adapter happens **after** the script returns.

Codex-side files are NOT modified in this PR (out of scope per
issue #529). When Codex's `/ship` is updated to include compound learning,
its spec MUST link back to this document as the canonical contract.

### Dual classifier path (issue #547)

Issue #547 introduced **agent-conditional** invocation of Every's
`/ce-compound` plugin in Step 5g. The bundler script
`scripts/compound-learning.sh` is **unchanged** and remains the single
source of truth for the context bundle in BOTH paths. Only the
classification step diverges:

| Runtime | Classifier path | Notes |
|---------|------------------|-------|
| Claude Code with `/ce-compound` plugin available | Plugin invocation | Pass `$BUNDLE_JSON` to the plugin; capture `{classification, payload}`-shaped output. |
| Codex (any version) | Inline prompt | Plugin is a Claude Code plugin and is not loaded by Codex; the inline prompt is the only path. |
| Claude Code without the plugin | Inline prompt (via fallback) | Detection mechanism (below) lands here on any plugin failure. |

**Detection mechanism (chosen):** try the plugin invocation first; on any
non-success exit code (including `command not found`-style errors,
plugin-runtime errors, or empty / unparseable plugin output), fall back to
the inline-prompt path. This is the simplest agent-neutral pattern — it
requires no global slash-command registry probe, no
`--ce-compound` / `--no-ce-compound` flag, and degrades gracefully on
Codex (which always hits the fallback because the plugin is not loaded).

Rejected alternatives, with reasons:

- **Probe the slash-command registry up front.** Would require a
  Claude-Code-specific API and would not generalise to Codex, defeating
  the parity invariant.
- **Explicit `--ce-compound` / `--no-ce-compound` flags.** Pushes the
  decision to the operator and adds a flag matrix; the runtime check is
  zero-config and equivalent in outcome.
- **Hard-require the plugin on Claude Code.** Breaks Step 5g entirely if
  the plugin is uninstalled or fails to load — unacceptable now that
  Step 5g is **mandatory** per #655 (operator clarification 2026-05-16);
  the inline-prompt fallback exists precisely so Step 5g can always run
  when at least one classifier path is available.

**Fallback path:** plugin failure ⇒ inline prompt. The session-report
`## Compound learning` table carries a `Classifier` column (`plugin`,
`inline`, or `inline-sonnet`) so the operator can audit whether the
plugin path is actually being exercised in practice. Silent fallbacks
would mask plugin regressions.

**Sonnet-by-default routing for /ship Step 5g (per #776):** When the
inline-prompt path is reached from `/ship`'s automated Step 5g, the
orchestrator MUST dispatch the classification via an Agent call with
`model: sonnet`. The task is template-following 4-class classification
(Rule / Pattern doc / Regression risk / Nothing) — Sonnet is sufficient
and Opus is overkill. Markers emitted from this path use
`classifier=inline-sonnet` so audit logs distinguish it from the bare
`inline` value, which is reserved for manual / interactive `/ce-compound`
invocations outside `/ship`'s automated path (the carve-out preserves
operator control over model choice for ad-hoc classification work).

**Bundler invariance:** the bundler script's CLI contract,
JSON shape, exit codes, and dependencies (`gh` + `jq`) are all unchanged
by issue #547. Both classifier paths consume the SAME `$BUNDLE_JSON`. If
the plugin requires a different input encoding, the encoding adapter
happens at the call site in `ship.md` Step 5g — not inside the bundler
script.

**TODO(invocation):** confirm `/ce-compound` plugin invocation contract.
Current `ship.md` Step 5g pseudocode assumes the plugin accepts
`$BUNDLE_JSON` as input and returns a `{classification, payload}`-shaped
object on stdout. The exact invocation syntax (slash command nested
inside another slash command, MCP tool call, plain shell exec, etc.) and
the exact output schema are owned by the plugin and could not be
inspected from this repository at the time issue #547 was implemented
(no readable plugin manifest under `~/.claude/plugins/ce-compound/` or
similar). When the plugin's contract is confirmed, reconcile the
pseudocode in `ship.md` Step 5g point 2, the worked-example "plugin
output" columns below, and this TODO marker — in a single follow-up
commit. The agent-conditional STRUCTURE, the detection mechanism, and
the fallback path are durable design decisions that are NOT blocked on
this reconciliation.

## Commit vs PR decision rule

| Classification          | Apply mechanism                                              | Why |
|-------------------------|--------------------------------------------------------------|-----|
| Rule                    | Follow-up PR, opened ready AND merged inline (no review/tester, window-bypass) | The classifier is the policy gate; the implementer is constrained to the docs-only allowlist; the PR exists as audit trail (`Source: PR #<N>` + squash subject), not as a review checkpoint. Inline merge keeps the rule atomic with the parent that produced it — no operator follow-up required for the happy path. |
| Pattern doc             | Follow-up PR, opened ready AND merged inline (no review/tester, window-bypass) | Same four-constraint safety model as Rule: classifier gate, path allowlist (docs-only), recursion guard, failure fallback. `develop` is a protected branch — direct commits are not used. Per #642. |
| Regression risk         | New issue (no commit)                                        | The fix lives elsewhere; this is process artefact only. |
| Nothing                 | Session-report log only                                      | No on-repo change. |

Rationale (Rule path, revised after the autonomous-mode redesign): the
earlier design opened a draft PR and stopped, on the assumption that an
operator was in the loop and would drive the follow-up PR through its own
`/ship` cycle. That assumption breaks for autonomous drain modes
(`/overnight`, batched `/ship`), where the draft PR just accumulates as
debt. The revised design merges the compound Rule PR inline, bounded by
four safety constraints that together replace the deleted reviewer/tester
gates:

1. **Classifier gate.** The Step 5g classifier (plugin or inline-prompt
   path) is the policy gate: only when the model returns `Rule` does this
   branch fire. The classifier saw the full bundle (diff, comments, CI
   status) and judged that the learning rises to a durable rule.
2. **Path allowlist.** The implementer subagent is constrained to the
   Step 5b docs-only allowlist (`^\.claude/`, `^\.codex/`, `^docs/`,
   `.*\.md$`, `^AGENTS\.md$`, `^CLAUDE\.md$`). The implementer prompt
   tells it to reject and return without pushing if the payload would
   touch a non-docs path. This means the path cannot silently land code.
3. **Recursion guard.** Step 5g hard-skips when the merged PR's branch
   matches `chore/compound-*`, so a compound Rule PR cannot trigger
   further compound learning on itself. This prevents any chain of
   trust-bypass merges from forming.
4. **Failure fallback.** Any failure in the inline-merge sub-flow (CI
   accidentally fails, BEHIND/DIRTY resolution exceeds one pass, merge
   lock unobtainable, `gh pr merge` errors, implementer rejects payload)
   flips the PR back to draft and labels it `compound-followup` for
   operator follow-up. The hatch into operator-driven review is always
   one label-search away.

Rationale (Pattern doc, revised by #642): the original design used a
direct commit to `develop` on the theory that "additive ≤200-line docs
files are low-risk and a PR cycle is wasted overhead." That theory fails
once `develop` is a protected branch — `git push origin develop` returns
HTTP 403 for any non-PR push regardless of content. The revised design
uses the same inline-merged PR pattern as the Rule path so the
compound-learning step keeps working under branch protection without
sacrificing velocity. The four safety constraints (classifier gate, path
allowlist, recursion guard, failure fallback) plus the
"additive, ≤200 lines, new file only" constraint encoded in Step 5g all
carry over to the Pattern PR path unchanged.

## Carve-out for issue creation

`AGENTS.md § Tool Permissions` lists the orchestrator (`/ship`) as
**✗ for `Create GitHub issues`** by default, with a single existing
carve-out for `/review-all-day` (footnote ³).

The compound-learning step adds a **second carve-out**:

> Orchestrator MAY create GitHub issues via `mcp__github__issue_write`
> when (and only when) Step 5g's classification is `Regression risk`.
> The created issue MUST be labelled `type:testing`, `priority:medium`,
> `status:backlog`, and its body MUST reference the source PR
> (`Source: PR #<N>`).

Justification: this is post-merge automated **knowledge capture**, not
human-loop blocker handling. The `Create GitHub issues = ✗` rule exists to
prevent the orchestrator from silently spawning blocker tickets when an
issue gets stuck; compound learning happens AFTER successful merge, so
there is no blocker-handling pathway to abuse. The carve-out is documented
in three places by design:

1. This spec (canonical).
2. `.claude/commands/ship.md` Step 5g (operational).
3. `AGENTS.md § Tool Permissions` footnote (governance) — to be added in a
   follow-up rule-update PR if this spec lands first; until then the
   reference in Step 5g points back to this document.

## Worked examples

The four worked examples below show the **inline-prompt path output**
(JSON contract `{classification, payload}`). The `/ce-compound` plugin
path (issue #547) is expected to produce equivalent output, but the
plugin's exact output schema has not been confirmed from this repository
yet — see `§ Codex parity > TODO(invocation)`. Until that reconciliation
lands, treat the examples below as canonical for the inline path and as
the **target** shape the plugin's output must be adapted to (in
`ship.md` Step 5g point 2's parsing layer) so points 3–5 dispatch
identically regardless of classifier path.

> TODO: confirm `/ce-compound` plugin output schema vs the
> `{classification, payload}` JSON contract below and reconcile —
> if the plugin's native shape differs, document BOTH expected outputs
> side-by-side in each example.

### Example A — Rule

**Source PR:** #258 (hypothetical) — fixed a merge-lock leak where the
`trap` did not fire because Step 5f.1 was split across two Bash tool calls.

Bundle excerpt:

```
"commit_subjects": [
  "fix(ship): keep Step 5f.1 in a single bash -c block so trap covers the merge"
],
"files": [ { "path": ".claude/commands/ship.md", "additions": 12, "deletions": 4 } ]
```

Model output:

```json
{
  "classification": "Rule",
  "payload": {
    "text": "Step 5f.1 in `/ship.md` MUST be emitted as a single `bash -c '...'` invocation so the release trap covers the entire merge sequence."
  }
}
```

Apply: open `chore/compound-258-rule` → edit `AGENTS.md § Non-Negotiable
Rules` (or `ship.md`'s Known limitations) → open PR ready (not draft) →
inline-merge via Step 5b CI gate + skipped 5c–5e/5e.bis + minimal 5f.0 +
window-bypass 5f.1 in the same `/ship` cycle. Session-report row:
`| <issue-#> | <parent-PR-#> | Rule | <classifier> | merged inline PR #<compound-PR-#> |`.

### Example B — Pattern doc

**Source PR:** #47 (real) — added Jest offline tests for Firebase Functions
by mocking `firebase-admin`, `request-promise`, and `jsonwebtoken`.

Bundle excerpt:

```
"files": [
  { "path": "web/functions/__tests__/playStoreHelper.test.js", "additions": 110 },
  { "path": "web/functions/jest.config.js", "additions": 6 }
],
"diff.text": "... jest.mock('firebase-admin') ... jest.mock('request-promise') ..."
```

Model output:

```json
{
  "classification": "Pattern doc",
  "payload": {
    "path": "docs/web/learnings/offline-jest-mocking.md",
    "text": "## Offline Jest mocking for Firebase Functions\n\nMock `firebase-admin`, `request-promise`, and `jsonwebtoken` at the top of each test file ... (full note)"
  }
}
```

Apply: open `chore/compound-47-pattern` → add
`docs/web/learnings/offline-jest-mocking.md` (≤200 lines, additive) →
open PR ready (not draft) → inline-merge via Step 5b CI gate +
skipped 5c–5e/5e.bis + minimal 5f.0 + window-bypass 5f.1 in the same
`/ship` cycle. Session-report row:
`| <issue-#> | <parent-PR-#> | Pattern doc | <classifier> | merged inline PR #<compound-PR-#> (pattern) |`.

### Example C — Regression risk

**Source PR:** #503 (real-ish) — bumped Realm Java to 10.19.0 for 16 KB
page-size alignment. No test was added for the alignment scenario (the
existing migration tests are local/manual only).

Bundle excerpt:

```
"commit_subjects": [
  "chore(android): bump Realm Java to 10.19.0 for 16 KB page-size alignment"
],
"files": [
  { "path": "android/.../build.gradle.kts", "additions": 1, "deletions": 1 }
]
```

Model output:

```json
{
  "classification": "Regression risk",
  "payload": {
    "title": "Add Paparazzi or instrumented test asserting Realm opens on 16 KB page-size devices",
    "body": "Source: PR #503. The Realm 10.19.0 bump aligns the native lib to 16 KB pages but no CI test asserts open-on-Pixel-8 (16 KB). Add a smoke test that opens a freshly migrated Realm on a 16 KB emulator config and writes/reads a row. Labels: type:testing, priority:medium, status:backlog."
  }
}
```

Apply: `mcp__github__issue_write` with the labels above. Source PR is
referenced; no commit.

### Example D — Nothing

**Source PR:** #534 (real) — `docs: add docs/README.md folder map`.

Bundle: a single new markdown file, no behavioural change, no regression
risk. Model output: `{"classification": "Nothing"}`. Apply: session-report
row only.

## Session report

`docs/reports/ship-<DATE>-<HHMM>.md` (gitignored, local-only) gains a new
top-level section:

```markdown
## Compound learning
| # | PR | Classification | Classifier | Apply action |
|---|----|----------------|------------|--------------|
| 1 | #536 | Pattern doc | plugin | merged inline PR #537 (pattern) |
| 2 | #503 | Regression risk | plugin | opened issue #654 (type:testing, priority:medium) |
| 3 | #534 | Nothing | inline | skipped |
| 4 | #621 | Rule | plugin | merged inline PR #622 (rule) |
| 5 | #644 | Rule | inline | compound rule merge failed: CI fail — see compound-followup label |
| 6 | #650 | Pattern doc | plugin | compound pattern merge failed: BEHIND/DIRTY — see compound-followup label |
```

Rows 1 and 4 illustrate the happy path: a successful inline merge records
`merged inline PR #<N> (rule|pattern)`. Rows 5 and 6 illustrate the
failure path: the row records the reason and the `compound-followup`
label that the operator can search on to drive the PR through a regular
`/ship` invocation later. Post-#642, the Rule and Pattern paths share
the same inline-merge / failure-handling shape.

The `Classifier` column was added in issue #547 to record which
classification path produced the row: `plugin` for `/ce-compound`,
`inline` for the inline-prompt fallback. See `§ Codex parity > Dual
classifier path (issue #547)`.

`docs/reports/README.md` (the directory's static README) does NOT need
updating — it already documents the directory as local-only operator
scratch space, and the new section is just one more row inside that
already-described file. This spec carries the note instead.

## Structural enforcement (silent-skip prevention)

Cross-references: issue #655 (mandatory Step 5g policy, closure-comment
field), issue #691 (this section — marker contract + session-end
verifier).

The closure-comment `Compound learning:` field introduced by #655 is
the per-PR audit trail in the GitHub timeline. That alone is not enough
to prevent a silent skip: the orchestrator can still write
`Compound learning: n/a — ...` to the closure comment without ever
invoking the bundler or the classifier. Issue #691 adds a second,
machine-checkable audit trail — canonical marker lines on stdout — and a
Step 6 session-end verifier that fails the session if any merged PR is
missing its markers. The two trails together make a silent Step 5g skip
structurally impossible.

### Closed skip vocabulary

`Nothing` is a **classifier outcome**, not a skip. Any session report
row that records `Nothing` MUST be backed by both a `bundler_exit`
marker and a `classifier` marker; the row alone does not survive the
Step 6 verifier.

The only legitimate skip strings (verbatim, no paraphrases) are:

- `dry-run` — `--dry-run` flag set; bundler + classifier deliberately
  not invoked (Step 5g precondition 1).
- `deferred` — merge was deferred to the morning queue; the next
  `/ship` session captures the learning when that PR actually merges
  (Step 5g precondition 2).
- `merge-failed` — `gh pr merge` did not return success (Step 5g
  precondition 3).
- `compound-of-compound` — recursion guard fired on a
  `chore/compound-*` head branch (Step 5g precondition 4).
- `no-classifier-available` — runtime-availability skip: both the
  plugin path and the inline-prompt fallback are unusable in the
  current runtime. This is the ONLY operator-chosen skip per #655; on
  Claude Code with the plugin loaded, or on Codex with the inline
  prompt available, Step 5g MUST run.

Any other skip string (paraphrase, capitalisation drift, extra
qualifier) is non-conformant and trips the Step 6 verifier.

### Canonical marker shape

The **human-readable shape is canonical** for the verifier (it is what
the grep pattern matches). The JSON-line shape is OPTIONAL and may be
emitted in parallel for downstream tooling (CI assertions, morning
brief feeds, Slack bridges).

**Success-path marker set (3 lines, one per PR):**

```
compound-learning: pr=<N> bundler_exit=<int>
compound-learning: pr=<N> classifier=<plugin|inline> classification=<Rule|Pattern doc|Regression risk|Nothing>
compound-learning: pr=<N> apply=<one-line apply summary>
```

Valid `apply` values (closed set): `merged inline PR #<M> (rule)`,
`merged inline PR #<M> (pattern)`, `opened issue #<M>`, `skipped`
(only valid when `classification=Nothing`),
`compound <rule|pattern> merge failed: <reason> — see compound-followup label`.

**Skip-path marker (1 line, one per PR, exactly one canonical string):**

```
compound-learning: pr=<N> skipped=<dry-run | deferred | merge-failed | compound-of-compound | no-classifier-available>
```

**Optional JSON-line shape (parallel emission only — NOT a substitute for the canonical lines):**

```json
{"compound-learning":{"pr":672,"bundler_exit":0,"classifier":"plugin","classification":"Pattern doc","apply":"merged inline PR #690 (pattern)"}}
```

Why the human-readable shape is canonical: it survives stdout
re-ordering and partial-line truncation better than a single JSON line,
the per-PR `pr=<N>` key makes multi-PR sessions trivially greppable,
and the verifier in `.claude/commands/ship.md` § "Step 6" can be
implemented with one `grep -qE` call against the session log. JSON
lines are nicer for tooling but harder for an at-a-glance operator
audit during a live `/ship` run, so they remain optional.

### Step 6 verifier behaviour

`/ship` and `/ship-v2` BOTH run a session-end verifier after the Step 5
loop exits and BEFORE the final user-facing summary. The verifier
iterates the list of merged PRs in this session and asserts that each
one has emitted at least one marker line matching the canonical shape.
The bash:

```bash
for PR in ${MERGED_PRS[@]}; do
  if ! grep -qE "^compound-learning: pr=$PR (bundler_exit|skipped)=" "$SESSION_LOG"; then
    echo "FAIL: Step 5g markers missing for PR #$PR — silent skip detected" >&2
    SESSION_STATUS=blocked
    break
  fi
done
```

On failure: the session flips to `status:blocked`, the missing-marker
PR is appended to the session report's "Skipped / blocked" log entry
with reason `compound-learning markers missing — silent Step 5g skip
detected (#691)`, and the final user-facing line surfaces the failure
banner. The orchestrator MUST NOT silently complete a session with
missing markers.

The grep is anchored to start-of-line (`^`) so PR-body or comment text
that quotes the marker shape verbatim does NOT spoof the verifier.

### Negative examples

**WRONG — silent skip (verifier MUST reject):**

```
| 671 | #690 | Nothing | inline | skipped |
# (no compound-learning: pr=671 lines emitted to stdout for PR #671)
```

The session report row LOOKS like a normal `Nothing` outcome. The
problem is that no `bundler_exit` or `classifier` marker for PR #671
appears anywhere in the session's stdout — the orchestrator wrote the
row without ever invoking either component. This is the failure mode
that occurred on PRs #671 and #673 on 2026-05-16 and that this whole
section exists to make impossible. The Step 6 verifier MUST reject
this session and flip it to `status:blocked`.

**RIGHT — `Nothing` is a legitimate classifier outcome:**

```
compound-learning: pr=671 bundler_exit=0
compound-learning: pr=671 classifier=inline classification=Nothing
compound-learning: pr=671 apply=skipped
| 671 | #690 | Nothing | inline | skipped |
```

Same session report row, but backed by the full 3-line marker set.
The bundler ran (`bundler_exit=0`), the classifier ran (inline path),
and the classifier returned `Nothing` — there genuinely was no
compoundable signal in this PR. The verifier accepts.

**RIGHT — legitimate skip:**

```
compound-learning: pr=672 skipped=deferred
| 672 | #690 | n/a | n/a | deferred — next /ship session captures |
```

PR #672 was deferred to the morning queue; the bundler and classifier
were not invoked because no merge happened in this session. The
single canonical `skipped=deferred` marker is sufficient. The verifier
accepts. The next session's Step 5g picks this PR up when it actually
merges.

The first and second blocks render identically in the session report
table. The marker line is the ONLY thing distinguishing a silent skip
from a legitimate `Nothing` outcome. That is the whole design point.

## Stop conditions

- `gh` missing → exit 1 from the script; Step 5g logs the error and moves
  on. This is a fail-soft path **during** Step 5g execution (Step 5g did
  run, the bundler errored) — the audit comment still records
  `Compound learning: failed: bundler exit non-zero — see compound-followup label`,
  so the silent-skip detection from #655 still passes. Compound learning
  itself is now **mandatory** per #655; only the 4 technical no-ops and 1
  runtime-availability skip are legitimate non-execution states.
- Model returns unparseable JSON → log raw output to session report; treat
  as `Nothing`.
- Classification `Rule` and the follow-up PR fails to open → log + skip;
  the operator can read the bundle from the session report and replay
  manually.
- Classification `Rule` and the inline-merge sub-flow fails after the PR
  was opened (CI fail, BEHIND/DIRTY persists past one resolution pass,
  merge lock unobtainable, `gh pr merge` errors, or implementer rejects an
  out-of-allowlist payload) → flip the compound PR to draft via
  `gh pr ready --undo <PR>`, add label `compound-followup`, log the
  failure reason to the session report, exit Step 5g. Operator can pick
  up the labelled PR in a subsequent `/ship` run.
- Classification `Regression risk` and `mcp__github__issue_write` fails →
  same fallback as above.
- Source PR is itself a compound PR (head branch matches
  `chore/compound-*`) → recursion guard fires before any classifier or
  sub-flow runs; log and exit Step 5g.

## Security notes

- The script's only user-supplied input is `PR_NUMBER`. It is validated by
  the anchored regex `^[1-9][0-9]*$` BEFORE any subprocess receives it.
  Attempts like `1; rm -rf /`, `--; gh auth logout`, `$(curl evil)`, etc.
  all fail the regex and exit 1.
- `gh pr diff` and `gh pr view` are read-only operations; no write path
  exists in the script.
- The bundle is emitted to stdout. The caller is responsible for not
  leaking it (e.g. by piping into a public log).

## Future work (NOT in this PR)

- Codex `/ship` parity update (lives in `.codex/` — separate PR).
- Periodic dedupe pass over `docs/<platform>/learnings/` to merge near-duplicate notes.
- A `--since=<date>` mode for batch compound learning across a sprint of
  merges, useful for retros.
