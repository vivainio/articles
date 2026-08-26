# Herdr Tutorial

*2026-07-28*

Herdr is a terminal multiplexer and workspace manager that treats AI coding agents as first-class terminal applications. It borrows the tmux mental model - sessions, windows, panes - and works with ordinary shells and terminal programs, while adding agent state tracking, Git worktrees, and plugins for workflows that need them.

This tutorial is based on my custom [herdr config.toml](https://github.com/vivainio/dotfiles/blob/master/herdr/config.toml), which mirrors my [tmux.conf](https://github.com/vivainio/dotfiles/blob/master/tmux.conf) as closely as Herdr allows - same prefix, same tab/pane bindings - so muscle memory carries over between the two.

## Why Herdr?

At its core, Herdr does the familiar multiplexer job: it keeps shells and terminal programs organized into persistent workspaces, tabs, and panes. You can detach, reconnect, split the screen, and use it for ordinary terminal work without running an agent at all.

Herdr is also unusually mouse-friendly for a terminal workspace manager, which makes it easier to learn than many alternatives. Most everyday operations - switching workspaces and panes, resizing, splitting, renaming, zooming, and closing - are available through clicks, dragging, and context menus. You can become productive before learning the keybindings, then adopt shortcuts gradually.

Agent awareness is the specialization on top. When you do run several Claude Code, Codex, Gemini, or other agents, the sidebar shows which are working, idle, or waiting for you. Worktree integration can create a separate checkout and workspace for another branch in one action. These features improve agent-heavy workflows without redefining Herdr's basic job as a terminal multiplexer.

For an existing tmux user, the switch can be almost frictionless. Herdr does not read `tmux.conf`, but you can assign your familiar prefix and navigation, tab, split, resize, and workspace bindings to their Herdr equivalents. The underlying model and everyday gestures remain close enough that most muscle memory carries over. The major addition is the extremely useful left sidebar, which keeps workspaces and agent states visible instead of making you recall or open a separate session list, and lets you jump between them directly with the mouse.

## Windows Installation

First try the Windows installation instructions on the [Herdr website](https://herdr.dev/docs/install/). If the website installer does not work, open PowerShell and install [Zipget](https://github.com/vivainio/zipget-rs):

```powershell
iwr https://github.com/vivainio/zipget-rs/releases/latest/download/zipget-windows-x64.exe -OutFile ~/.local/bin/zipget.exe
```

Then use Zipget to install Herdr:

```powershell
zipget install herdrdev/herdr --exe herdr.exe
```

Both commands install into `~/.local/bin`. That directory is usually already on your `PATH`, especially if you use tools such as [uv](https://docs.astral.sh/uv/). If PowerShell cannot find `zipget` or `herdr`, add `~/.local/bin` to your user `PATH` and open a new terminal.

## Setting Up config.toml

My config is entirely optional. If you prefer to navigate mostly with the mouse, start with Herdr's defaults. The custom config both preserves my tmux muscle memory and adds ergonomic choices that I prefer, most notably prefix-free `Alt+Arrow` navigation and a comfortable `Ctrl+Space` prefix.

Grab my config and save it as `~/.config/herdr/config.toml` on Linux or macOS, mirroring the way `~/dotfiles/tmux.conf` is linked as `~/.tmux.conf`:

```bash
curl -o ~/.config/herdr/config.toml https://raw.githubusercontent.com/vivainio/dotfiles/master/herdr/config.toml
```

On Windows, Herdr reads the config from `%APPDATA%\herdr\config.toml`. Download it from PowerShell with:

```powershell
New-Item -ItemType Directory -Force "$env:APPDATA\herdr" | Out-Null
iwr https://raw.githubusercontent.com/vivainio/dotfiles/master/herdr/config.toml -OutFile "$env:APPDATA\herdr\config.toml"
```

Reload it from inside Herdr with `Prefix + Shift+R` instead of restarting.

The popups and plugin actions below call out to `lazygit`, `lf`, and the `herdr-file-viewer`/`reviewr` plugins - install those separately (`sudo apt install lazygit lf`, `herdr plugin install ...`) if you want those bindings to work.

## Custom Prefix

Like the tmux config, the default prefix is replaced with `Ctrl+Space`. Since both configs share the same prefix and the same tab/workspace/pane bindings, you can hop between a tmux session and a Herdr session without your fingers noticing the difference.

The two changes that matter most in my tmux config compared with the defaults are this `Ctrl+Space` prefix and prefix-free `Alt+Arrow` navigation. Mirroring those in Herdr preserves most of the muscle memory; the remaining bindings are much closer to what either multiplexer already provides.

## Level 1: Tabs

Herdr calls tabs "tabs" (tmux calls them "windows" - same thing):

| Action | Binding | Mouse alternative |
|--------|---------|--------------------|
| Create new tab | `Prefix + c` | Click the `+` button in the tab bar |
| Close current tab | `Prefix + k` | - |
| Rename tab | `Prefix + Shift+T` | Right-click the tab, then choose **Rename** |
| Next tab | `Alt+Right` | Click the tab |
| Previous tab | `Alt+Left` | Click the tab |
| Jump to tab N | `Prefix + 1..9` | Click the tab |

No prefix needed for navigation - just hold Alt and press arrow keys, exactly like the tmux config.

Herdr captures the mouse by default (`ui.mouse_capture = true`). Right-click opens the tab's context menu; choose **Rename** from there. Double-click does nothing, which is easy to get backwards if you're used to other apps.

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
| Rename workspace | `Prefix + Shift+W` | Right-click it in the sidebar, then choose **Rename** |
| Close workspace | `Prefix + Shift+K` | - |
| Detach | `Prefix + Q` | - |
| Toggle sidebar | `Prefix + B` | - |

`Prefix + W` opens a picker over every workspace. In practice it duplicates what the sidebar already shows you, with no type-to-search and no extra preview - if you keep the sidebar visible, clicking there or using `Alt+Up/Down` is just as fast.

`Prefix + G` is the one that's actually equivalent to tmux's `Prefix + w` tree view: it shows workspaces and their panes together, not just a flat workspace list, so it's the better pick when you want to jump straight into a specific pane rather than just a workspace. Press `/` inside the Goto dialog to search and filter the list.

## Level 3: Panes

Splits work the same way they do in tmux:

| Action | Binding | Mouse alternative |
|--------|---------|--------------------|
| Split vertically | `Prefix + V` | Right-click the pane, then choose the split |
| Split horizontally | `Prefix + Minus` | Right-click the pane, then choose the split |
| Kill pane | `Prefix + X` | Right-click the pane, then choose **Close** |
| Switch pane | `Prefix + arrow keys` | Click the pane |
| Cycle panes | `Prefix + Tab` / `Prefix + Shift+Tab` | Click the pane |
| Zoom pane | `Prefix + Z` | Right-click the pane, then choose **Zoom** |
| Resize mode | `Prefix + R` | Drag the pane border (rare - use this) |
| Rename pane | `Prefix + Shift+P` | Right-click the pane, then choose **Rename** |

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

My config binds `Alt+Shift+Up` and `Alt+Shift+Down` to the previous and next agent, respectively. Unlike `Alt+Up/Down`, which moves between workspaces, these shortcuts follow the agent list directly, making it quick to cycle through active agents without reaching for the mouse:

```toml
[keys]
previous_agent = "alt+shift+up"
next_agent = "alt+shift+down"
```

```bash
herdr agent list                  # every agent pane and its state
herdr agent wait <id> --state idle  # block until an agent needs you
herdr agent prompt <id> "..."      # submit a prompt without focusing it
```

Worktrees take this further: `Prefix + Shift+G` creates a new Git worktree-backed workspace, so kicking off a second agent on a separate branch doesn't mean juggling a manual `git worktree add` and a new terminal - it's one keystroke, and the workspace is already checked out and ready. Worktree-backed workspaces appear in the workspace pane alongside your other workspaces, so their relationship to the running agents stays visible. When you're finished, right-click the workspace and choose **Delete** to remove the worktree checkout without dropping back to the command line.

Herdr generates a random branch name for each new worktree, such as `worktree/calm-forest-c059`, and checks it out below `~/.herdr/worktrees/<repository>/`, for example `~/.herdr/worktrees/articles/worktree-calm-forest-c059`.

> **Claude Code note:** I tested Herdr-managed worktree workspaces with Claude Code, and they work great together. Claude Code also offers its own worktree management, especially in agents mode, but you do not need to use it: launch Claude Code inside the workspace Herdr creates, and it works normally in that checkout.

```bash
herdr worktree list
herdr worktree create <branch>
herdr worktree remove <path>
```

## Level 7: Plugins

Herdr plugins are executable workflow tools packaged around a `herdr-plugin.toml` manifest. A normal app or script can invoke the `herdr` CLI too, so plugins do not get an entirely separate control API. What the plugin system adds is standardized installation, named actions, managed panes, convenient keybindings, and declarative hooks into Herdr's lifecycle.

My config uses two:

- **[herdr-file-viewer](https://github.com/smarzban/herdr-file-viewer)** - a git-aware, read-only file viewer as a TUI split pane, bound to `Prefix + F` (split) and `Prefix + Shift+F` (own tab).
- **reviewr** - review agent-written diffs beside the chat and add line comments back into the agent's input, toggled with `Prefix + Ctrl+R`.

### Install and invoke a plugin

Install a plugin directly from GitHub:

```bash
herdr plugin install <owner>/<repo>
herdr plugin list
```

A manifest can expose `[[actions]]`, which are commands Herdr runs with the current pane or workspace context. They can be invoked from the CLI or bound directly in `config.toml`:

```toml
[[keys.command]]
key = "prefix+ctrl+r"
type = "plugin_action"
command = "persiyanov.reviewr.toggle"
```

The command is `<plugin-id>.<action-id>`. Reviewr declares that action like this:

```toml
[[actions]]
id = "toggle"
title = "reviewr: toggle sidebar"
contexts = ["pane", "workspace"]
command = ["bash", "herdr/sidebar.sh", "toggle"]
```

Here, `toggle` is an ordinary argument to Reviewr's script, selecting its toggle behavior; it is not special Herdr syntax.

### Plugin panes

A plugin can declare a terminal UI as a managed pane entrypoint. Herdr controls where the pane is placed and supplies the plugin environment when it launches the command:

```toml
[[panes]]
id = "sidebar"
title = "reviewr"
placement = "split"
command = ["sh", "-c", "exec \"$HERDR_PLUGIN_ROOT/bin/herdr-reviewr\""]
```

Actions and event hooks can then open or close that entrypoint through `herdr plugin pane`. This is how a tool such as Reviewr can live beside an agent instead of behaving like an unrelated popup process.

### Lifecycle event hooks

An `[[events]]` entry tells Herdr to run a command whenever a matching lifecycle event occurs. For example, Reviewr automatically opens its review pane when Herdr creates a new worktree-backed workspace, provided Reviewr's `auto_open` setting is enabled:

```toml
# Auto-open the sidebar for a freshly created worktree.
[[events]]
on = "worktree.created"
command = ["bash", "herdr/sidebar.sh", "auto-open"]
```

`auto-open` is Reviewr's event-specific script mode. Unlike a manual `open`, it reads the newly created workspace and checkout path from the event payload, respects the `auto_open` setting, avoids stealing focus, and quietly does nothing when opening would be inappropriate or the pane already exists.

Plugin manifests can subscribe to these events:

| Area | Events |
|------|--------|
| Workspace | `workspace.created`, `workspace.updated`, `workspace.closed`, `workspace.renamed`, `workspace.moved`, `workspace.focused` |
| Worktree | `worktree.created`, `worktree.opened`, `worktree.removed` |
| Tab | `tab.created`, `tab.closed`, `tab.renamed`, `tab.moved`, `tab.focused` |
| Pane | `pane.created`, `pane.closed`, `pane.focused`, `pane.moved`, `pane.exited`, `pane.agent_detected`, `pane.agent_status_changed` |

Event commands receive the event name in `HERDR_PLUGIN_EVENT` and its full JSON envelope in `HERDR_PLUGIN_EVENT_JSON`. Herdr also supplies plugin paths and whatever workspace, tab, and pane context is available. That lets one script handle several events or inspect details such as the created worktree, closed pane, or new agent state.

High-volume and display-only events such as `pane.output_changed`, `pane.updated`, `layout.updated`, and `workspace.metadata_updated` are deliberately not available as manifest hooks. Tools that need those use Herdr's socket event-subscription API instead.

Lifecycle hooks are the clearest capability plugins add over a normal launched app: Herdr invokes the tool at the relevant moment without the tool polling for changes. A standalone app could reproduce the behavior with its own event subscriber or glue code, but merely calling the CLI does not give it a declarative subscription.

### Long-running plugin processes

A `[[panes]]` command can be a long-running TUI or service. It follows the same lifetime rules as any other process running in a Herdr pane:

| Action | What happens to the process |
|--------|-----------------------------|
| Detach with `Prefix + Q` or close the terminal client | Keeps running in the background Herdr server |
| Close its pane or workspace | Terminates |
| Stop or normally restart the Herdr server | Terminates |
| Force-kill or crash the server | Must not be expected to survive |
| Replace the server with a successful experimental live handoff | May keep running |

After a normal server restart, Herdr restores the saved workspace and pane layout, not arbitrary processes that previously ran inside it. A plugin can declare a one-shot `[[startup]]` hook to reconstruct plugin-owned state after restore when the API is ready, but startup hooks should not be treated as a supervised daemon facility. Native agent session restore is a separate mechanism for supported coding agents and does not automatically restore arbitrary plugin processes.

### Compared with tmux and Zellij

Herdr is not the only terminal multiplexer with hooks or plugins, but the three systems make different tradeoffs:

| | tmux | Zellij | Herdr |
|---|---|---|---|
| Plugin model | Shell scripts and configuration, often installed with TPM | First-class WASM/WASI modules hosted by Zellij | Manifest plus out-of-process executables |
| Implementation | Anything callable from a shell | Languages that compile to WebAssembly | Any executable or script |
| User interface | Usually status-line changes, keybindings, popups, or normal panes | Plugins render native UI and act as first-class panes | Programs run in Herdr-managed terminal panes |
| Events | tmux hooks invoke commands or scripts | Persistent plugins subscribe to a rich event stream | Manifest hooks launch commands; socket clients can subscribe continuously |
| Security | Scripts run with the user's normal permissions | WASM isolation with explicit requested permissions | Executables run with the user's normal permissions; GitHub installation shows a trust preview |
| Emphasis | General terminal automation | General terminal UI extensions | Agent-, workspace-, and worktree-oriented workflows |

Herdr resembles tmux in building on ordinary external programs, but formalizes their packaging, actions, panes, and event hooks in a manifest. Zellij has the deeper native plugin runtime, including persistent components, rendered UI, subscriptions, and permissions, but requiring WebAssembly is also a meaningful constraint: languages and libraries must support WASM/WASI, OS and subprocess access goes through Zellij's APIs and permissions, and an existing TUI or CLI cannot simply be packaged unchanged as a native plugin.

Herdr makes the opposite tradeoff. An existing shell script, binary, or terminal application can become a plugin without being ported to a specialized runtime - Reviewr remains a normal Rust TUI executable, for example. Herdr gives up Zellij's WASM isolation and native rendered UI in exchange for compatibility with the existing Unix and terminal ecosystem. Its advantage is lower implementation friction and agent-specific context, not a more powerful general plugin system than Zellij.

## Q&A

**Why not just use tmux?**

Tmux is more mature and doesn't care what's running in its panes. Herdr trades that generality for agent-awareness: state tracking, worktree-per-task workflows, and a plugin ecosystem built around reviewing and steering AI agents specifically. If you're not running multiple coding agents at once, tmux is probably still the better default.

**Can I use both?**

Yes - the two configs here are deliberately kept in sync on prefix and core bindings, so you can run Herdr for agent-heavy projects and tmux for everything else without relearning muscle memory.

## Related writing

- [Tmux Tutorial](tmux.md) covers the mature, general-purpose alternative whose
  mental model and keybindings shaped this setup.
- [My Vibing Flow](../ai-agents/my-vibing-flow.md) shows how persistent terminal
  workspaces fit into daily agent-assisted development.
