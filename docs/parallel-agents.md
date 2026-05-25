# Parallel-Agents Setup (iTerm2 + tmux)

Two tiers of local terminal layout for running multiple ingreview agents (flutter-developer, supabase-developer, code-reviewer, watcher) in parallel.

## Goal

Keep several agent sessions visible side by side on one Mac without committing to a full multiplexer. Start with iTerm2 splits; upgrade to tmux only when persistence across iTerm2 restarts (or remote access) actually matters.

---

## Tier 1 — iTerm2 split panes (zero-config local Mac)

### Why

- No extra install, no config file, no prefix keys to memorise.
- Each pane gets its own shell, working directory, and scrollback.
- Pairs naturally with `git worktree` — one pane per worktree.

### Setup

1. Open iTerm2.
2. Split panes:
   - `Cmd+D` — split vertically (pane on the right).
   - `Cmd+Shift+D` — split horizontally (pane below).
   - `Cmd+Alt+Arrow` — move focus between panes.
3. In each new pane, `cd` into the matching worktree before starting the agent.

### Worktree pairing

One pane corresponds to one worktree corresponds to one issue. Naming convention:

```sh
# from the main checkout
git worktree add -b feat/<issue#>-<slug> ../ingreview-<issue#> origin/main
```

Then in the new iTerm2 pane:

```sh
cd ../ingreview-<issue#>
```

### Per-pane command snippets

```sh
# Flutter pane
cd ../ingreview-42 && flutter run

# Supabase pane
cd ../ingreview-42 && supabase start

# Test pane
cd ../ingreview-42 && cd apps/mobile && flutter test --watch
```

### Limitations

- Closing the iTerm2 window kills every pane and every running agent.
- No detach/reattach — you cannot resume the same layout from another terminal or after a reboot.
- No remote access (ssh in and you start from scratch).

If any of those bite you, move to Tier 2.

---

## Tier 2 — iTerm2 + tmux (persistent sessions)

### When to upgrade

- You leave long-running agents (watcher, `supabase start`, `flutter run`) running overnight.
- You want to detach the session, close iTerm2, reboot, and reattach with everything still alive.
- You ssh into the Mac from a second machine and want the same view.

### Install

```sh
brew install tmux
```

Drop the sample config at [`dotfiles/.tmux.conf`](./dotfiles/.tmux.conf) into `~/.tmux.conf` (or symlink it) for a sane prefix and mouse support.

### Session model

One tmux session per logical workspace (e.g. `ir` for ingreview). Inside the session, one window per role (control, flutter, supabase, review, watcher, ci).

### Cheat sheet

The sample config rebinds the prefix from `Ctrl+b` to `Ctrl+a`. Adjust accordingly if you keep the default.

```sh
tmux new -s ir            # create session "ir"
tmux attach -t ir         # reattach later (after closing iTerm2, ssh, reboot)
tmux ls                   # list sessions
tmux kill-session -t ir   # nuke session
```

Inside tmux (prefix = `Ctrl+a` with sample config, `Ctrl+b` by default):

| Keys | Action |
|------|--------|
| `prefix c` | Create new window |
| `prefix d` | Detach session (leave it running) |
| `prefix "` | Split current pane horizontally |
| `prefix %` | Split current pane vertically |
| `prefix <number>` | Switch to window N |
| `prefix h/j/k/l` | Move between panes (with sample config) |

### iTerm2 + tmux integration

Run tmux in control-mode so iTerm2 renders tmux windows/panes as native iTerm2 tabs/splits:

```sh
tmux -CC new -s ir
tmux -CC attach -t ir
```

This gives you native iTerm2 UI (Cmd+T for new window, Cmd+D for split) while tmux owns the underlying session. Detaching with `prefix d` (or closing the iTerm2 window) leaves the session alive.

---

## Decision tree

- Single-Mac, work fits in one iTerm2 window, no overnight agents -> **Tier 1**.
- Long-running agents, need detach/reattach, or want ssh access -> **Tier 2**.
- Already on Tier 1 and adding a third worktree or first overnight watcher -> upgrade to Tier 2 now.

---

## Cross-references

- [`../../AGENTS.md`](../../AGENTS.md) — agent roles, issue lifecycle, review loop (the source of truth for who does what in each pane).
- [`./dotfiles/.tmux.conf`](./dotfiles/.tmux.conf) — sample minimal tmux config used by this guide.

## Screenshots

Screenshots are optional. If added later, place them under `docs/development/parallel-agents/` and link from the relevant tier. No empty directory or placeholder image is shipped with this guide.
