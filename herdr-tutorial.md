# Herdr Tutorial

*2026-07-28*

Herdr is a terminal workspace manager built specifically for running AI coding agents. It borrows the tmux mental model - sessions, windows, panes - but is agent-aware: it tracks each pane's state (working, idle, waiting on you), lets you jump straight to the agent that needs attention, and layers on Git worktrees and plugins so an agent-heavy workflow doesn't feel bolted onto a generic multiplexer.

This tutorial is based on my custom [herdr config.toml](https://github.com/vivainio/dotfiles/blob/master/herdr/config.toml), which mirrors my [tmux.conf](https://github.com/vivainio/dotfiles/blob/master/tmux.conf) as closely as Herdr allows - same prefix, same tab/pane bindings - so muscle memory carries over between the two.

## Why Herdr?

Tmux multiplexes terminals. Herdr multiplexes *agents*. When you're running several Claude Code (or Codex, Gemini, etc.) instances across different projects, the thing you actually want to know at a glance is "which of these is stuck waiting for me?" - not just "which panes exist." Herdr's sidebar answers that directly, and its worktree integration means spinning up a new agent on a new branch is a single keystroke instead of a manual `git worktree add` dance.

Herdr is also unusually mouse-friendly for a terminal workspace manager, which makes it easier to learn than many alternatives. Most everyday operations - switching workspaces and panes, resizing, splitting, renaming, zooming, and closing - are available through clicks, dragging, and context menus. You can become productive before learning the keybindings, then adopt shortcuts gradually.

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

| Action | Binding | Mouse alternative |
|--------|---------|--------------------|
| Create new tab | `Prefix + c` | Click the `+` button in the tab bar |
| Close current tab | `Prefix + k` | - |
| Rename tab | `Prefix + Shift+T` | Right-click the tab (rare - use this) |
| Next tab | `Alt+Right` | Click the tab |
| Previous tab | `Alt+Left` | Click the tab |
| Jump to tab N | `Prefix + 1..9` | Click the tab |

No prefix needed for navigation - just hold Alt and press arrow keys, exactly like the tmux config.

Herdr captures the mouse by default (`ui.mouse_capture = true`). Note double-click does nothing here - it's right-click that renames, which is easy to get backwards if you're used to other apps.

## Level 2: Workspaces

Workspaces are Herdr's equivalent of tmux sessions - a group of tabs for one project or one line of work.

Confusingly, Herdr also has a literal "session" concept (`herdr --session <name>`, `herdr session list|attach|stop|delete`) - a separate persistent server/socket, closer to running a second tmux server than to a tmux session. It exists, but since workspaces already give you multiple project groupings inside one Herdr instance, most people never need more than the default session and can ignore this layer entirely.

| Action | Binding | Mouse alternative |
|--------|---------|--------------------|
| New workspace | `Prefix + Shift+N` | Click the "New" button in the sidebar |
| Next workspace | `Alt+Down` | Click it in the sidebar |
| Previous workspace | `Alt+Up` | Click it in the sidebar |
| Workspace picker | `Prefix + W` | Sidebar already shows this - see below |
| Goto (session navigator) | `Prefix + G` | - |
| Rename workspace | `Prefix + Shift+W` | Right-click it in the sidebar (rare - use this) |
| Close workspace | `Prefix + Shift+K` | - |
| Detach | `Prefix + Q` | - |
| Toggle sidebar | `Prefix + B` | - |

`Prefix + W` opens a picker over every workspace. In practice it duplicates what the sidebar already shows you, with no type-to-search and no extra preview - if you keep the sidebar visible, clicking there or using `Alt+Up/Down` is just as fast.

`Prefix + G` is the one that's actually equivalent to tmux's `Prefix + w` tree view: it shows workspaces and their panes together, not just a flat workspace list, so it's the better pick when you want to jump straight into a specific pane rather than just a workspace.

## Level 3: Panes

Splits work the same way they do in tmux:

| Action | Binding | Mouse alternative |
|--------|---------|--------------------|
| Split vertically | `Prefix + V` | Right-click the pane |
| Split horizontally | `Prefix + Minus` | Right-click the pane |
| Kill pane | `Prefix + X` | Right-click the pane (rare - use this) |
| Switch pane | `Prefix + arrow keys` | Click the pane |
| Cycle panes | `Prefix + Tab` / `Prefix + Shift+Tab` | Click the pane |
| Zoom pane | `Prefix + Z` | Right-click the pane |
| Resize mode | `Prefix + R` | Drag the pane border (rare - use this) |
| Rename pane | `Prefix + Shift+P` | Right-click the pane (rare - use this) |

Right-click a pane once for a menu bundling rename, split, zoom, and close, rather than four separate gestures to remember.

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

Herdr plugins are a standardized way to package and install Herdr-focused tools. They are not uniquely privileged: a normal app or script can also invoke the `herdr` CLI to query workspaces and agents or perform actions. The practical benefits of a plugin are standardized installation, packaged named actions, and convenient keybinding through `type = "plugin_action"`.

My config uses two:

- **[herdr-file-viewer](https://github.com/smarzban/herdr-file-viewer)** - a git-aware, read-only file viewer as a TUI split pane, bound to `Prefix + F` (split) and `Prefix + Shift+F` (own tab).
- **reviewr** - review agent-written diffs beside the chat and add line comments back into the agent's input, toggled with `Prefix + Ctrl+R`.

Plugins are installed with `herdr plugin install <owner>/<repo>` and bound via `type = "plugin_action"` or a `herdr plugin action invoke` shell command in `config.toml`, the same way the popups above are bound.

There is no lifecycle advantage documented here: unless Herdr provides initialization, cleanup, supervision, or workspace-specific start/stop hooks, a plugin has no special lifecycle capability compared with a normal CLI app.

## Q&A

**Why not just use tmux?**

Tmux is more mature and doesn't care what's running in its panes. Herdr trades that generality for agent-awareness: state tracking, worktree-per-task workflows, and a plugin ecosystem built around reviewing and steering AI agents specifically. If you're not running multiple coding agents at once, tmux is probably still the better default.

**Can I use both?**

Yes - the two configs here are deliberately kept in sync on prefix and core bindings, so you can run Herdr for agent-heavy projects and tmux for everything else without relearning muscle memory.
