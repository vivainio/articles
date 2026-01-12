# Tmux Tutorial

Tmux is a terminal multiplexer that lets you run multiple terminal sessions inside a single window.

This tutorial is based on my custom [tmux.conf](https://github.com/vivainio/dotfiles/blob/master/tmux.conf). It makes tmux more ergonomic and significantly prettier, without bloated plugins.

## Why Tmux?

Tmux makes it easy to multitask across many projects in different sessions, with one or more Claude Code instances running in each session.

## Custom Prefix

The default tmux prefix `Ctrl+b` is replaced with `Ctrl+Space`. This is more ergonomic and allows you to execute all chords quickly. Combined with Alt+arrow navigation, everything becomes even easier.

## Level 1: Tabs

Tmux calls tabs "windows". Here's the essentials:

| Action | Binding |
|--------|---------|
| Create new tab | `Prefix + c` |
| Kill current tab | `Prefix + k` |
| Next tab | `Alt+Right` |
| Previous tab | `Alt+Left` |

No prefix needed for navigation - just hold Alt and press arrow keys.

## Level 2: Sessions

Sessions let you group tabs for different projects. Switch between entire sessions instantly.

| Action | Binding |
|--------|---------|
| New session | `tmux new -s name` |
| Next session | `Alt+Down` |
| Previous session | `Alt+Up` |
| List sessions | `Prefix + w` |
| Detach | `Prefix + d` |

All new tabs in a session start in the same directory where you created the session. This makes sessions ideal for grouping related work - one session per project, and every tab opens ready to go in that project's folder.

## All Key Bindings

| Binding | Action |
|---------|--------|
| `Ctrl+Space` | Prefix key |
| `Prefix + c` | New window |
| `Prefix + k` | Kill window |
| `Prefix + x` | Kill pane (no prompt) |
| `Prefix + R` | Reload config |
| `Prefix + Ctrl+G` | Open lazygit in popup |
| `Alt+Left/Right` | Switch windows |
| `Alt+Up/Down` | Switch sessions |

