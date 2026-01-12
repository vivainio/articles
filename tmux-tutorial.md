# Tmux Tutorial

Tmux is a terminal multiplexer that lets you run multiple terminal sessions inside a single window.

This tutorial is based on my custom [tmux.conf](https://github.com/vivainio/dotfiles/blob/master/tmux.conf).

## Why Tmux?

Tmux allows you to detach from sessions and reattach later, which is useful for long-running processes and remote work.

## Custom Prefix

The default tmux prefix `Ctrl+b` is replaced with `Ctrl+Space` for easier access.

## Key Bindings

| Binding | Action |
|---------|--------|
| `Ctrl+Space` | Prefix key |
| `Prefix + R` | Reload config |
| `Prefix + k` | Kill window |
| `Prefix + x` | Kill pane (no prompt) |
| `Prefix + Ctrl+G` | Open lazygit in popup |
| `Alt+Left/Right` | Switch windows |
| `Alt+Up/Down` | Switch sessions |

## Configuration Highlights

- **Mouse support** enabled
- **History limit** set to 50,000 lines
- **Windows and panes start at 1** (not 0)
- **Auto-renumber windows** when one is closed
- **Status bar at top** with Catppuccin-inspired colors
- **Default shell** is Nushell

## Basic Commands

```bash
tmux new -s mysession    # Create named session
tmux attach -t mysession # Attach to session
tmux ls                  # List sessions
```
