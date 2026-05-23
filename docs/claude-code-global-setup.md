# Claude Code Global Setup

## Purpose

A small set of Claude Code permissions and MCP toggles are safe to apply across every
SmartInventory worktree on a given developer machine. Putting them in the per-user
global config at `~/.claude/settings.json` keeps the repo-tracked `.claude/settings.json`
focused on project policy, and keeps the gitignored `.claude/settings.local.json`
focused on truly local one-offs. This avoids re-approving the same prompts on every
fresh clone or worktree.

## Recommended global settings

Merge the following into `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(~/.claude/statusline.sh)",
      "Bash(brew install *)"
    ]
  },
  "enableAllProjectMcpServers": true,
  "enabledMcpjsonServers": ["github"]
}
```

## What NOT to migrate

Keep the following in the gitignored `.claude/settings.local.json` rather than promoting
them to the global file:

- Absolute paths to specific worktrees (e.g. `Bash(cd /tmp/smartinventory-123:*)`).
- One-shot `sed`, `rm`, or `mv` commands generated for a single task.
- Permissions tied to a feature branch's transient files or scripts.
- Anything you would not want silently auto-approved in an unrelated repo.

## Setup instructions

1. Open `~/.claude/settings.json` in your editor (create it if it does not exist).
2. Merge the JSON block above into the existing object, preserving any keys you already
   have. Restart Claude Code so it picks up the new config.

## Risk notes

- `Bash(brew install *)` runs without `sudo` and only writes to the Homebrew prefix
  owned by the current user; it cannot modify system directories.
- `Bash(~/.claude/statusline.sh)` targets a user-owned script in the home directory;
  review the script before enabling it.
- `enabledMcpjsonServers: ["github"]` only activates the GitHub MCP server declared in
  the repo's tracked `.mcp.json`; the read/write surface is whatever the repo's
  existing allowlist permits, so no new capability is granted globally.
- `enableAllProjectMcpServers: true` trusts MCP servers declared in any project you
  open with Claude Code — only enable this if you vet the projects you work in.
