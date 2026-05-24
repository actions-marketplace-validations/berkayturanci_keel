# Claude Code Global Setup

## Purpose

A small set of Claude Code permissions and MCP toggles are safe to apply across every
SmartInventory worktree on a given developer machine. Putting them in the per-user
global config at `~/.claude/settings.json` keeps the repo-tracked `.claude/settings.json`
focused on project policy, and keeps the gitignored `.claude/settings.local.json`
focused on truly local one-offs. This avoids re-approving the same prompts on every
fresh clone or worktree.

## Recommended global settings

### Claude Code — `~/.claude/settings.json`

Merge the following into `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(~/.claude/statusline.sh)",
      "Bash(brew install *)",
      "Bash(codex *)",
      "Bash(codex)",
      "Bash(agy *)",
      "Bash(agy)"
    ]
  },
  "enableAllProjectMcpServers": true,
  "enabledMcpjsonServers": ["github"]
}
```

The `codex *` and `agy *` rules allow Claude Code to invoke Codex CLI and Antigravity
CLI without a permission prompt in any project. The project-level deny list in
`.claude/settings.json` still guards destructive operations regardless of this global
allow.

### Codex CLI — `~/.codex/config.toml`

Add the following top-level keys to your existing `~/.codex/config.toml`. These set
auto-approve mode and a shell-level deny list that mirrors the Claude Code guard:

```toml
approval = "never"
sandbox  = "workspace-write"

block_commands = [
  "git push --force",
  "git push -f ",
  "git push --force-with-lease",
  "git push origin :",
  "git push origin --delete",
  "git push --delete",
  "git reset --hard",
  "git clean -fdx",
  "git filter-branch",
  "git branch -D develop",
  "git branch -D main",
  "rm -rf /",
  "rm -rf ~",
  "rm -rf $HOME",
  "rm -rf --no-preserve-root",
  "sudo rm",
  # The trailing space is intentional: it prefix-matches all "sudo <anything>" invocations.
  "sudo ",
  "gh repo delete",
  "gh release delete",
  "gh secret delete",
  "gh secret set",
  "gh auth logout",
  "npm publish",
  "npm unpublish",
  "firebase deploy",
  "firebase projects:delete",
  "firebase database:remove",
  "firebase functions:delete",
  "firebase hosting:disable",
  "curl | sh",
  "curl | bash",
  "wget | sh",
  "wget | bash",
  "eval ",
  "dd if=",
  "mkfs",
  "shred",
  "chmod -R 777 /",
  "chown -R "
]
```

`approval = "never"` makes Codex auto-approve all model-generated commands.

**Security layers (verified 2026-05-25):**

| Layer | Mechanism | Status |
|-------|-----------|--------|
| `sandbox = "workspace-write"` | Filesystem-level: Codex cannot write outside project dir + `/tmp` | ✅ Verified — blocked `git reset --hard` at the OS level when no hook fired |
| `.codex/hooks.json` PreToolUse | Reads the project's `.claude/settings.json` deny list and blocks matching commands before execution | ✅ Verified — fires before the sandbox, shows explicit deny-pattern message |
| `block_commands` | Config-level blocklist in `~/.codex/config.toml` | ⚠️ Unverified — Codex silently ignored this key during testing; do not rely on it as the sole guard |

The **primary** defence is the project hook + sandbox combination. `block_commands` is
kept as a best-effort declaration in case a future Codex version honours it.

### Antigravity CLI (agy) — `~/.gemini/antigravity-cli/settings.json`

> Note: verify this path against the version of agy installed on your machine — the
> settings location may differ across CLI versions.

Add a `permissions.deny` block to your existing settings. agy does not support a
config-level bypass flag, so also add a shell alias (see next section).

Replace `[]` in the `"allow"` field below with your existing allow entries from your
current `settings.json` before saving.

```json
{
  "permissions": {
    "allow": [],
    "deny": [
      "command(git push --force)",
      "command(git push -f )",
      "command(git push --force-with-lease)",
      "command(git push origin :)",
      "command(git push origin --delete)",
      "command(git push --delete)",
      "command(git reset --hard)",
      "command(git clean -fdx)",
      "command(git filter-branch)",
      "command(git branch -D develop)",
      "command(git branch -D main)",
      "command(rm -rf /)",
      "command(rm -rf ~)",
      "command(sudo rm)",
      "command(sudo )",
      "command(gh repo delete)",
      "command(gh release delete)",
      "command(gh secret delete)",
      "command(gh secret set)",
      "command(gh auth logout)",
      "command(npm publish)",
      "command(npm unpublish)",
      "command(firebase deploy)",
      "command(firebase projects:delete)",
      "command(firebase database:remove)",
      "command(firebase functions:delete)",
      "command(firebase hosting:disable)",
      "command(eval )",
      "command(dd if=)",
      "command(mkfs)",
      "command(shred)",
      "command(chmod -R 777 /)",
      "command(chown -R )"
    ]
  }
}
```

### Shell alias for agy — `~/.zshrc`

agy has no config-level permission bypass. Add this alias so the flag is always applied:

```zsh
# agy: always skip permission prompts (security guard is in settings.json deny list)
alias agy='~/.local/bin/agy --dangerously-skip-permissions'
```

Verify the path with `which agy` on your machine before applying.

After editing `~/.zshrc`, run `source ~/.zshrc` to activate.

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
3. Restart Codex CLI and agy sessions to pick up config changes.

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
