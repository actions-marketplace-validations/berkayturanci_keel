#!/usr/bin/env bash
#
# compound-learning.sh — agent-neutral PR context bundler for the /ship
# compound-learning step (issue #529).
#
# Reads a merged PR, gathers diff summary + review comments + CI status +
# files changed + commit subjects, and emits a structured context bundle to
# stdout. The calling agent (Claude or Codex) then asks its model "What did
# we learn?" and classifies the result per docs/development/
# compound-learning-spec.md.
#
# Output formats: JSON (default) or markdown (--format=markdown). Pass
# --dry-run to tag the bundle "classification: deferred" so callers know
# not to act on it.
#
# Exit codes:
#   0 — success
#   1 — usage / dependency error
#   2 — PR not found
#   3 — PR not merged
#
# This script is agent-neutral by design: it MUST run standalone from a
# shell and never assume Claude/Codex is in the environment.

set -euo pipefail

# ---- usage --------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: compound-learning.sh <PR_NUMBER> [--format=json|markdown] [--dry-run]

Arguments:
  <PR_NUMBER>       Positive integer. The merged PR to bundle context for.

Options:
  --format=json     (default) Emit a single JSON object to stdout.
  --format=markdown Emit a human-readable markdown bundle.
  --dry-run         Tag the bundle "classification": "deferred" so the
                    calling agent knows not to act on it; otherwise no
                    behavioural change. The bundle content is identical.
  -h, --help        Show this help.

Exit codes:
  0 success | 1 usage/deps | 2 PR not found | 3 PR not merged

Prerequisites:
  gh (GitHub CLI) must be installed and authenticated.
EOF
}

# ---- argument parsing ---------------------------------------------------

PR_NUMBER=""
FORMAT="json"
DRY_RUN="false"

while (( $# > 0 )); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --format=json)
      FORMAT="json"
      shift
      ;;
    --format=markdown)
      FORMAT="markdown"
      shift
      ;;
    --format=*)
      echo "ERROR: unknown --format value: ${1#--format=}" >&2
      usage >&2
      exit 1
      ;;
    --*)
      echo "ERROR: unknown flag: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$PR_NUMBER" ]]; then
        echo "ERROR: too many positional arguments (already have PR_NUMBER=$PR_NUMBER, got '$1')" >&2
        usage >&2
        exit 1
      fi
      PR_NUMBER="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR_NUMBER" ]]; then
  echo "ERROR: PR_NUMBER is required" >&2
  usage >&2
  exit 1
fi

# Validate PR_NUMBER is a positive integer. Anchored regex — anything else
# (including shell-injection attempts like '1; rm -rf /') is rejected.
if ! [[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: PR_NUMBER must be a positive integer (got '$PR_NUMBER')" >&2
  exit 1
fi

# ---- dependency check ---------------------------------------------------

if ! command -v gh >/dev/null 2>&1; then
  cat >&2 <<EOF
ERROR: gh (GitHub CLI) is required but not installed.

Install:
  macOS:  brew install gh
  Linux:  https://github.com/cli/cli/blob/trunk/docs/install_linux.md
  Then:   gh auth login

The script is agent-neutral and never assumes Claude/Codex is present, but
it does rely on gh to read PR metadata. There is no fallback because every
calling environment (Claude Code, Codex, plain shell) already has gh on the
project's runner.
EOF
  exit 1
fi

# Validate gh is authenticated. `gh auth status` returns 0 when logged in.
if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh is installed but not authenticated. Run: gh auth login" >&2
  exit 1
fi

# jq is required for safe JSON construction. It is a transitive dep of gh
# on most distros, but check explicitly.
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for JSON construction. Install: brew install jq (or apt-get install jq)" >&2
  exit 1
fi

# ---- gather context -----------------------------------------------------

# Single gh call for all PR metadata we need. Fields list intentionally
# matches the issue #529 spec.
META_JSON="$(gh pr view "$PR_NUMBER" \
  --json mergedAt,state,number,title,baseRefName,headRefName,additions,deletions,changedFiles,files,reviews,commits 2>/dev/null || true)"

if [[ -z "$META_JSON" || "$META_JSON" == "null" ]]; then
  echo "ERROR: PR #$PR_NUMBER not found (gh pr view returned nothing)" >&2
  exit 2
fi

# Refuse to bundle a PR that did not merge — compound learning only applies
# post-merge.
MERGED_AT="$(printf '%s' "$META_JSON" | jq -r '.mergedAt // empty')"
STATE="$(printf '%s' "$META_JSON" | jq -r '.state // empty')"

if [[ -z "$MERGED_AT" || "$MERGED_AT" == "null" ]]; then
  echo "ERROR: PR #$PR_NUMBER is not merged (state=$STATE). Compound learning runs post-merge only." >&2
  exit 3
fi

# Diff — truncate to 500 lines so the bundle stays inside a single
# model-prompt budget. We capture both the truncated diff and a note when
# truncation occurred so the calling agent knows the picture is partial.
DIFF_RAW="$(gh pr diff "$PR_NUMBER" 2>/dev/null || true)"
DIFF_TOTAL_LINES=$(printf '%s\n' "$DIFF_RAW" | wc -l | tr -d ' ')
DIFF_TRUNCATED="false"
DIFF_TEXT="$DIFF_RAW"
if (( DIFF_TOTAL_LINES > 500 )); then
  DIFF_TEXT="$(printf '%s\n' "$DIFF_RAW" | head -n 500)"
  DIFF_TRUNCATED="true"
fi

# Review comments — issue spec says pick the simpler of the two options.
# `gh pr view --comments` returns a single text blob of issue-style
# comments (NOT the inline review comments on individual lines). We
# additionally pull inline review comments via the REST API because they
# are the higher-signal source for compound learning.
ISSUE_COMMENTS_RAW="$(gh pr view "$PR_NUMBER" --comments 2>/dev/null || true)"

# REST API call for inline review comments. {owner}/{repo} placeholder is
# expanded by gh based on the current repo context.
REVIEW_COMMENTS_JSON="$(gh api "repos/{owner}/{repo}/pulls/$PR_NUMBER/comments" 2>/dev/null || echo "[]")"

# CI status — get the combined commit status of the head ref.
CI_STATUS_JSON="$(gh pr view "$PR_NUMBER" --json statusCheckRollup 2>/dev/null || echo '{"statusCheckRollup":[]}')"

# Classification field — every bundle carries it. Defaults to "pending"
# meaning the calling agent should classify it. --dry-run overrides to
# "deferred" so the agent knows not to act.
CLASSIFICATION="pending"
if [[ "$DRY_RUN" == "true" ]]; then
  CLASSIFICATION="deferred"
fi

SCHEMA_VERSION="1"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- emit bundle --------------------------------------------------------

if [[ "$FORMAT" == "json" ]]; then
  # Compose the bundle via jq so all string fields are correctly escaped.
  # We pass raw strings through --arg / --rawfile-equivalent (jq -R -s on
  # stdin redirected from a temp blob would also work; we use --arg for
  # explicitness because the diff is already capped at 500 lines).
  jq -n \
    --arg schema_version "$SCHEMA_VERSION" \
    --arg generated_at "$GENERATED_AT" \
    --arg classification "$CLASSIFICATION" \
    --arg dry_run "$DRY_RUN" \
    --argjson meta "$META_JSON" \
    --arg diff "$DIFF_TEXT" \
    --arg diff_truncated "$DIFF_TRUNCATED" \
    --argjson diff_total_lines "$DIFF_TOTAL_LINES" \
    --arg issue_comments "$ISSUE_COMMENTS_RAW" \
    --argjson review_comments "$REVIEW_COMMENTS_JSON" \
    --argjson ci_status "$CI_STATUS_JSON" \
    '{
      schema_version: $schema_version,
      generated_at: $generated_at,
      classification: $classification,
      dry_run: ($dry_run == "true"),
      pr: {
        number: $meta.number,
        title: $meta.title,
        state: $meta.state,
        merged_at: $meta.mergedAt,
        base_ref: $meta.baseRefName,
        head_ref: $meta.headRefName,
        additions: $meta.additions,
        deletions: $meta.deletions,
        changed_files: $meta.changedFiles,
        files: ($meta.files // []),
        commit_subjects: [ ($meta.commits // [])[] | .messageHeadline ],
        reviews: ($meta.reviews // [])
      },
      diff: {
        text: $diff,
        truncated: ($diff_truncated == "true"),
        total_lines: $diff_total_lines,
        max_lines: 500
      },
      comments: {
        issue: $issue_comments,
        review_inline: $review_comments
      },
      ci: $ci_status
    }'
  exit 0
fi

# ---- markdown format ----------------------------------------------------

PR_TITLE="$(printf '%s' "$META_JSON" | jq -r '.title // ""')"
PR_BASE="$(printf '%s' "$META_JSON" | jq -r '.baseRefName // ""')"
PR_HEAD="$(printf '%s' "$META_JSON" | jq -r '.headRefName // ""')"
PR_ADD="$(printf '%s' "$META_JSON" | jq -r '.additions // 0')"
PR_DEL="$(printf '%s' "$META_JSON" | jq -r '.deletions // 0')"
PR_CHANGED="$(printf '%s' "$META_JSON" | jq -r '.changedFiles // 0')"

cat <<EOF
# Compound learning bundle — PR #$PR_NUMBER

- **Schema:** $SCHEMA_VERSION
- **Generated:** $GENERATED_AT
- **Classification:** $CLASSIFICATION (dry_run=$DRY_RUN)
- **Title:** $PR_TITLE
- **Merged at:** $MERGED_AT
- **Base / head:** $PR_BASE … $PR_HEAD
- **Diff size:** +$PR_ADD / -$PR_DEL across $PR_CHANGED file(s)

## Files changed

EOF

printf '%s' "$META_JSON" | jq -r '(.files // [])[] | "- \(.path) (+\(.additions // 0)/-\(.deletions // 0))"'

cat <<EOF

## Commit subjects

EOF

printf '%s' "$META_JSON" | jq -r '(.commits // [])[] | "- \(.messageHeadline)"'

cat <<EOF

## CI status

\`\`\`json
$(printf '%s' "$CI_STATUS_JSON" | jq '.')
\`\`\`

## Diff (truncated=$DIFF_TRUNCATED, total_lines=$DIFF_TOTAL_LINES, max=500)

\`\`\`diff
$DIFF_TEXT
\`\`\`

## Inline review comments

\`\`\`json
$(printf '%s' "$REVIEW_COMMENTS_JSON" | jq '.')
\`\`\`

## Issue-style PR comments

\`\`\`
$ISSUE_COMMENTS_RAW
\`\`\`
EOF
