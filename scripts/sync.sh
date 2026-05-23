#!/usr/bin/env bash
#
# sync.sh — propagate ai-infra files to a target project repo via the GitHub API.
#
# Usage:
#   ./scripts/sync.sh <project-name>         sync portable files to project
#   ./scripts/sync.sh <project-name> --force also push command files (adapted files)
#   ./scripts/sync.sh <project-name> --dry-run show what would be pushed, no writes
#   ./scripts/sync.sh --all [--force] [--dry-run]  sync all configured projects
#
# Exit codes: 0 success, 1 if any push failed.
#
# Prerequisites: gh (GitHub CLI, authenticated), jq

set -euo pipefail

# ---- constants ----------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECTS_DIR="$REPO_ROOT/projects"

COMMIT_MESSAGE="chore: sync from ai-infra"

# File categories — portable files are synced without --force;
# command files require --force.
PORTABLE_DIRS=("agents" "gemini-agents" "docs")
PORTABLE_SINGLES=("hooks/session-start.sh" "scripts/compound-learning.sh")
COMMANDS_DIR="commands"

# ---- argument parsing ---------------------------------------------------

usage() {
  cat <<'EOF'
Usage: sync.sh <project-name> [--force] [--dry-run]
       sync.sh --all [--force] [--dry-run]

Arguments:
  <project-name>  Name matching a file in projects/<name>.json
  --all           Sync all projects defined in projects/
  --force         Also push command files (adapted, project-specific content)
  --dry-run       Show what would be pushed; make no API calls

Examples:
  ./scripts/sync.sh smartinventory
  ./scripts/sync.sh smartinventory --force
  ./scripts/sync.sh smartinventory --dry-run
  ./scripts/sync.sh --all --force
EOF
}

PROJECT_NAME=""
FORCE=false
DRY_RUN=false
ALL=false

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --all) ALL=true; shift ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --*)
      echo "ERROR: unknown flag: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$PROJECT_NAME" ]]; then
        echo "ERROR: too many arguments (got '$1' after '$PROJECT_NAME')" >&2
        usage >&2
        exit 1
      fi
      PROJECT_NAME="$1"
      shift
      ;;
  esac
done

if [[ -z "$PROJECT_NAME" && "$ALL" == "false" ]]; then
  echo "ERROR: specify a project name or --all" >&2
  usage >&2
  exit 1
fi

if [[ -n "$PROJECT_NAME" && "$ALL" == "true" ]]; then
  echo "ERROR: cannot specify both a project name and --all" >&2
  exit 1
fi

# ---- dependency checks --------------------------------------------------

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh (GitHub CLI) is required. Install: https://cli.github.com" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh is not authenticated. Run: gh auth login" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required. Install: brew install jq" >&2
  exit 1
fi

if ! command -v base64 >/dev/null 2>&1; then
  echo "ERROR: base64 is required (should be on PATH on macOS/Linux)" >&2
  exit 1
fi

# ---- project loading ----------------------------------------------------

load_project() {
  local name="$1"
  local config_path="$PROJECTS_DIR/$name.json"
  if [[ ! -f "$config_path" ]]; then
    echo "ERROR: no project config at $config_path" >&2
    return 1
  fi
  # Validate it's well-formed JSON
  if ! jq -e '.' "$config_path" >/dev/null 2>&1; then
    echo "ERROR: $config_path is not valid JSON" >&2
    return 1
  fi
  cat "$config_path"
}

list_projects() {
  for f in "$PROJECTS_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    basename "$f" .json
  done
}

# ---- file push logic ----------------------------------------------------

CREATED=0
UPDATED=0
SKIPPED=0
FAILED=0
DRYRUN_ACTIONS=0

# push_one_file OWNER REPO LOCAL_PATH TARGET_PATH
# Compares local file content with the current file in the repo.
# Creates or updates as needed.
push_one_file() {
  local owner="$1"
  local repo="$2"
  local local_path="$3"
  local target_path="$4"

  if [[ ! -f "$local_path" ]]; then
    echo "  WARN     $target_path  (local file missing: $local_path)" >&2
    return 0
  fi

  # Encode local content
  local local_b64
  local_b64=$(base64 < "$local_path" | tr -d '\n')

  # Fetch current file from target repo (may not exist)
  local existing_json
  existing_json=$(gh api "repos/$owner/$repo/contents/$target_path" 2>/dev/null || echo "")

  local existing_sha=""
  local existing_b64=""

  if [[ -n "$existing_json" && "$existing_json" != "null" ]]; then
    existing_sha=$(printf '%s' "$existing_json" | jq -r '.sha // ""')
    # GitHub returns content with line-folded base64; normalize for comparison
    existing_b64=$(printf '%s' "$existing_json" | jq -r '.content // ""' | tr -d '\n')
  fi

  # Compare: identical content → skip
  if [[ -n "$existing_b64" && "$existing_b64" == "$local_b64" ]]; then
    echo "  SKIPPED  $target_path"
    (( SKIPPED++ )) || true
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ -z "$existing_sha" ]]; then
      echo "  DRY-RUN  CREATE  $target_path"
    else
      echo "  DRY-RUN  UPDATE  $target_path"
    fi
    (( DRYRUN_ACTIONS++ )) || true
    return 0
  fi

  # Build the API payload
  local api_args=()
  api_args+=(-f "message=$COMMIT_MESSAGE")
  api_args+=(-f "content=$local_b64")
  if [[ -n "$existing_sha" ]]; then
    api_args+=(-f "sha=$existing_sha")
  fi

  local result
  if result=$(gh api --method PUT "repos/$owner/$repo/contents/$target_path" \
      "${api_args[@]}" --jq '.content.name' 2>&1); then
    if [[ -z "$existing_sha" ]]; then
      echo "  CREATED  $target_path"
      (( CREATED++ )) || true
    else
      echo "  UPDATED  $target_path"
      (( UPDATED++ )) || true
    fi
  else
    echo "  FAILED   $target_path  ($result)" >&2
    (( FAILED++ )) || true
  fi
}

# sync_project CONFIG_JSON
sync_project() {
  local config="$1"
  local owner repo skip_commands_json

  owner=$(printf '%s' "$config" | jq -r '.owner')
  repo=$(printf '%s' "$config" | jq -r '.repo')
  skip_commands_json=$(printf '%s' "$config" | jq -r '.skip_commands // [] | @json')

  echo ""
  echo "=== Syncing to $owner/$repo ==="
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    (dry-run — no API calls)"
  fi
  if [[ "$FORCE" == "true" ]]; then
    echo "    (--force — command files will be pushed)"
  fi

  # ---- portable directories ----
  for dir in "${PORTABLE_DIRS[@]}"; do
    local local_dir="$REPO_ROOT/$dir"
    [[ -d "$local_dir" ]] || continue
    while IFS= read -r -d '' local_file; do
      local rel="${local_file#$REPO_ROOT/}"
      push_one_file "$owner" "$repo" "$local_file" "$rel"
    done < <(find "$local_dir" -type f -print0)
  done

  # ---- portable singles ----
  for rel_path in "${PORTABLE_SINGLES[@]}"; do
    local local_file="$REPO_ROOT/$rel_path"
    push_one_file "$owner" "$repo" "$local_file" "$rel_path"
  done

  # ---- commands (requires --force) ----
  local commands_dir="$REPO_ROOT/$COMMANDS_DIR"
  if [[ "$FORCE" == "true" && -d "$commands_dir" ]]; then
    while IFS= read -r -d '' local_file; do
      local basename
      basename=$(basename "$local_file" .md)
      # Check if this command is in skip_commands
      if printf '%s' "$skip_commands_json" | jq -e --arg n "$basename" '. | index($n) != null' >/dev/null 2>&1; then
        echo "  SKIPPED  commands/$basename.md  (in skip_commands)"
        (( SKIPPED++ )) || true
        continue
      fi
      push_one_file "$owner" "$repo" "$local_file" "commands/$(basename "$local_file")"
    done < <(find "$commands_dir" -name '*.md' -type f -print0)
  elif [[ "$FORCE" == "false" ]]; then
    local cmd_count
    cmd_count=$(find "$commands_dir" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
    echo ""
    echo "  NOTE: $cmd_count command file(s) skipped — pass --force to push commands/"
    echo "        (commands have project-specific content; review diffs before pushing)"
  fi
}

# ---- main ---------------------------------------------------------------

echo "ai-infra sync"
echo "  repo root: $REPO_ROOT"
echo "  dry-run: $DRY_RUN"
echo "  force: $FORCE"

if [[ "$ALL" == "true" ]]; then
  while IFS= read -r project; do
    config=$(load_project "$project") || continue
    sync_project "$config"
  done < <(list_projects)
else
  config=$(load_project "$PROJECT_NAME")
  sync_project "$config"
fi

echo ""
echo "=== Summary ==="
if [[ "$DRY_RUN" == "true" ]]; then
  echo "  would create/update: $DRYRUN_ACTIONS"
  echo "  skipped (identical): $SKIPPED"
else
  echo "  created: $CREATED"
  echo "  updated: $UPDATED"
  echo "  skipped: $SKIPPED"
  echo "  failed:  $FAILED"
fi

if (( FAILED > 0 )); then
  echo "  ERROR: $FAILED file(s) failed to push" >&2
  exit 1
fi
exit 0
