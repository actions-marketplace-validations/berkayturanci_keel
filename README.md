# ai-infra

Portable Claude Code AI workflow infrastructure, extracted from [SmartInventory](https://github.com/berkayturanci/smartinventory).

This repository is the shared source of truth for slash commands, agents, Gemini CE personas, hooks, scripts, and docs that travel across multiple projects. Each project maintains its own adaptations in its own repo; `ai-infra` holds the canonical upstream versions.

## Directory structure

```
ai-infra/
  commands/          Portable slash commands for Claude Code (/ship, /implement, /pr-loop, etc.)
  agents/            Generic Claude Code subagent definitions (code-reviewer, tester)
  gemini-agents/     49 compound-engineering persona files for Gemini Code Assist
  hooks/
    session-start.sh Bootstrap hook for Claude Code Web sandbox sessions
  scripts/
    compound-learning.sh  PR context bundler for the /ship compound-learning step
    sync.sh               Propagate ai-infra files to a target project repo
  docs/
    compound-learning-spec.md    Spec for the compound-learning step in /ship
    claude-code-global-setup.md  Recommended global Claude Code settings
    parallel-agents.md           iTerm2 + tmux setup for running parallel agents
  projects/
    smartinventory.json  Project config for berkayturanci/smartinventory
    ingreview.json       Project config for berkayturanci/ingreview
```

## File categories

### Portable (safe to sync as-is)

These files are genuinely project-neutral and can be pushed verbatim to any project repo:

- `gemini-agents/` — CE persona definitions; contain no project-specific references
- `hooks/session-start.sh` — bootstraps the compound-engineering plugin in Claude Code Web; idempotent
- `scripts/compound-learning.sh` — reads a merged PR and emits a structured learning bundle; uses `gh` with `{owner}/{repo}` expansion so it works in any repo
- `docs/` — conceptual documentation; project-neutral

### Adapted (review before syncing)

These files have project-specific content and should be reviewed before propagating:

- `commands/` — slash commands reference specific repo names, branch conventions (`develop`), platform toolchains (Gradle, npm), and label taxonomies. Each project should maintain its own version. `sync.sh` requires `--force` to push command files, prompting manual review.
- `agents/` — agent definitions reference `AGENTS.md` and platform context files (`android/CLAUDE.md`, `web/CLAUDE.md`). Review before syncing to a project with a different structure.

## How to use sync.sh

`scripts/sync.sh` propagates files from `ai-infra` to a target project repo via the GitHub API.

```bash
# Sync all portable files to smartinventory (dry run first)
./scripts/sync.sh smartinventory --dry-run

# Sync for real
./scripts/sync.sh smartinventory

# Sync commands too (requires --force since commands have project-specific content)
./scripts/sync.sh smartinventory --force

# Sync all configured projects
./scripts/sync.sh --all

# Sync all projects including commands
./scripts/sync.sh --all --force
```

The script reads project config from `projects/<name>.json`, fetches each file's current content from the target repo, compares with the local version, and pushes only changed files.

Output:
- `CREATED  <path>` — file did not exist in target repo; created
- `UPDATED  <path>` — file differed from local; pushed update
- `SKIPPED  <path>` — file identical to local; no action
- `DRY-RUN  <path>` — would create/update (only in --dry-run mode)
- `FAILED   <path>` — API call failed; check output for details

Exit code: `0` on success, `1` if any push failed.

## How to add a new project

1. Create `projects/<name>.json` following the schema in `projects/smartinventory.json`.
2. Run `./scripts/sync.sh <name> --dry-run` to preview what would be pushed.
3. Run `./scripts/sync.sh <name>` to push portable files.
4. Manually adapt `commands/` for the new project's toolchain and push them separately.

### projects/<name>.json schema

```json
{
  "owner": "github-username",
  "repo": "repo-name",
  "default_branch": "main",
  "platform": "description of platform stack",
  "build_test": "shell command to run tests",
  "build_lint": "shell command to run linter",
  "platform_agents": ["agent-name-1", "agent-name-2"],
  "substitutions": {
    "REPO": "repo-name",
    "OWNER": "github-username",
    "DEFAULT_BRANCH": "main"
  },
  "skip_commands": ["command-names-to-exclude-from-sync"]
}
```

`skip_commands` lists command filenames (without `.md`) that should never be synced to this project (e.g. platform-specific commands that don't apply).

## Sync behavior for commands

By default, `sync.sh` runs command files in **dry-run mode**: it reports what would change but does not push. Pass `--force` to actually push command files.

This is intentional: commands often contain project-specific tool invocations, branch names, label taxonomies, and repo coordinates. The operator should diff the local `commands/` against the project's current versions and decide which changes to propagate.

Gemini agents, hooks, scripts, and docs do **not** require `--force` — they are treated as portable and pushed on every sync.

## Relationship to SmartInventory

The canonical source for most files in this repo is `berkayturanci/smartinventory`. When SmartInventory updates a portable file (e.g. a new CE persona, an improved hook), the change should be:

1. Committed to SmartInventory as usual.
2. Copied into this repo manually (or via a future pull-from-source script).
3. Propagated to other projects via `./scripts/sync.sh --all`.

This repo does **not** auto-pull from SmartInventory; it is a manually-curated snapshot. The operator decides when to absorb upstream changes.
