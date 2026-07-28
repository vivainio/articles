# Herdr Tutorial

*2026-07-28*

Herdr is a terminal workspace manager built specifically for running AI coding agents. It borrows the tmux mental model - sessions, windows, panes - but is agent-aware: it tracks each pane's state (working, idle, waiting on you), lets you jump straight to the agent that needs attention, and layers on Git worktrees and plugins so an agent-heavy workflow doesn't feel bolted onto a generic multiplexer.

This tutorial is based on my custom [herdr config.toml](https://github.com/vivainio/dotfiles/blob/master/herdr/config.toml), which mirrors my [tmux.conf](https://github.com/vivainio/dotfiles/blob/master/tmux.conf) as closely as Herdr allows - same prefix, same tab/pane bindings - so muscle memory carries over between the two.

## Why Herdr?

Tmux multiplexes terminals. Herdr multiplexes *agents*. When you're running several Claude Code (or Codex, Gemini, etc.) instances across different projects, the thing you actually want to know at a glance is "which of these is stuck waiting for me?" - not just "which panes exist." Herdr's sidebar answers that directly, and its worktree integration means spinning up a new agent on a new branch is a single keystroke instead of a manual `git worktree add` dance.

## Setting Up config.toml

Grab my config and drop it in as `~/.config/herdr/config.toml`, mirroring the way `~/dotfiles/tmux.conf` is linked as `~/.tmux.conf`:

```bash
curl -o ~/.config/herdr/config.toml https://raw.githubusercontent.com/vivainio/dotfiles/master/herdr/config.toml
```

Reload it from inside Herdr with `Prefix + Shift+R` instead of restarting.

The popups and plugin actions below call out to `lazygit`, `lf`, and the `herdr-file-viewer`/`reviewr` plugins - install those separately (`sudo apt install lazygit lf`, `herdr plugin install ...`) if you want those bindings to work.

## Custom Prefix

Like the tmux config, the default prefix is replaced with `Ctrl+Space`. Since both configs share the same prefix and the same tab/workspace/pane bindings, you can hop between a tmux session and a Herdr session without your fingers noticing the difference.

## Level 1: Tabs

Herdr calls tabs "tabs" (tmux calls them "windows" - same thing):

| Action | Binding |
|--------|---------|
| Create new tab | `Prefix + c` |
| Close current tab | `Prefix + k` |
| Rename tab | `Prefix + Shift+T` |
| Next tab | `Alt+Right` |
| Previous tab | `Alt+Left` |
| Jump to tab N | `Prefix + 1..9` |

No prefix needed for navigation - just hold Alt and press arrow keys, exactly like the tmux config.

Herdr also captures the mouse by default (`ui.mouse_capture = true`): click a tab or workspace in the sidebar to switch to it directly, and right-click one to rename it (double-click does nothing here). That makes the `Rename tab` / `Rename workspace` keybindings below more of a fallback than something you'll reach for.

## Level 2: Workspaces

Workspaces are Herdr's equivalent of tmux sessions - a group of tabs for one project or one line of work.

| Action | Binding |
|--------|---------|
| New workspace | `Prefix + Shift+N` |
| Next workspace | `Alt+Down` |
| Previous workspace | `Alt+Up` |
| Workspace picker | `Prefix + W` |
| Rename workspace | `Prefix + Shift+W` |
| Close workspace | `Prefix + Shift+K` |
| Detach | `Prefix + Q` |
| Toggle sidebar | `Prefix + B` |

`Prefix + W` opens a picker over every workspace. In practice it duplicates what the sidebar already shows you, with no type-to-search and no extra preview - if you keep the sidebar visible, clicking there or using `Alt+Up/Down` is just as fast. Unlike tmux's `Prefix + w` tree view, it's not clearly pulling its weight.

The sidebar itself can be hidden with `Prefix + B` if you want the full terminal width back. With the sidebar visible, click to switch and right-click to rename a workspace - rename is rare enough that reaching for the mouse once in a while is no hardship, so `Rename workspace` and the workspace picker are both mostly optional.

## Level 3: Panes

Splits work the same way they do in tmux:

| Action | Binding |
|--------|---------|
| Split vertically | `Prefix + V` |
| Split horizontally | `Prefix + Minus` |
| Kill pane | `Prefix + X` |
| Switch pane | `Prefix + arrow keys` |
| Cycle panes | `Prefix + Tab` / `Prefix + Shift+Tab` |
| Zoom pane | `Prefix + Z` |
| Resize mode | `Prefix + R` |

## Level 4: Scrollback

Herdr skips tmux's modal vi-style copy mode in favor of two simpler tools: mouse-drag selection copies automatically as you drag, and `Prefix + E` opens the full pane scrollback in your editor, so you can search and copy with normal editor tools instead of a special mode.

| Action | Binding |
|--------|---------|
| Edit scrollback in `$EDITOR` | `Prefix + E` |
| Copy via mouse drag | just select, no keybinding needed |

## Level 5: Extensibility

Like the tmux config's popups, Herdr's custom commands launch tools in floating windows over your current work:

| Popup | Binding |
|-------|---------|
| [lazygit](https://github.com/jesseduffield/lazygit) | `Prefix + Ctrl+G` |
| [lf](https://github.com/gokcehan/lf) file manager | `Prefix + Ctrl+L` |
| Daily notes editor | `Prefix + Ctrl+N` |
| [menyy](https://github.com/vivainio/menyy) floating menu | `Prefix + M` |

These are `type = "popup"` or `type = "shell"` commands under `[[keys.command]]` in `config.toml` - any shell command can become a keybinding.

## Level 6: Agents and Worktrees

This is where Herdr stops being "just tmux." The sidebar shows every agent pane's state at a glance - working, idle, or waiting on you - and you can act on that state without leaving the keyboard:

```bash
herdr agent list                  # every agent pane and its state
herdr agent wait <id> --state idle  # block until an agent needs you
herdr agent prompt <id> "..."      # submit a prompt without focusing it
```

Worktrees take this further: `Prefix + Shift+G` creates a new Git worktree-backed workspace, so kicking off a second agent on a separate branch doesn't mean juggling a manual `git worktree add` and a new terminal - it's one keystroke, and the workspace is already checked out and ready.

```bash
herdr worktree list
herdr worktree create <branch>
herdr worktree remove <path>
```

## Level 7: Plugins

Herdr has a plugin system for functionality that goes beyond a single popup command. My config uses two:

- **[herdr-file-viewer](https://github.com/smarzban/herdr-file-viewer)** - a git-aware, read-only file viewer as a TUI split pane, bound to `Prefix + F` (split) and `Prefix + Shift+F` (own tab).
- **reviewr** - review agent-written diffs beside the chat and add line comments back into the agent's input, toggled with `Prefix + Ctrl+R`.

Plugins are installed with `herdr plugin install <owner>/<repo>` and bound via `type = "plugin_action"` or a `herdr plugin action invoke` shell command in `config.toml`, the same way the popups above are bound.

## Q&A

**Why not just use tmux?**

Tmux is more mature and doesn't care what's running in its panes. Herdr trades that generality for agent-awareness: state tracking, worktree-per-task workflows, and a plugin ecosystem built around reviewing and steering AI agents specifically. If you're not running multiple coding agents at once, tmux is probably still the better default.

**Can I use both?**

Yes - the two configs here are deliberately kept in sync on prefix and core bindings, so you can run Herdr for agent-heavy projects and tmux for everything else without relearning muscle memory.
