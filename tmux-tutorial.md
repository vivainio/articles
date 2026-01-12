# Tmux Tutorial

Tmux is a terminal multiplexer that lets you run multiple terminal sessions inside a single window.

## Why Tmux?

Tmux allows you to detach from sessions and reattach later, which is useful for long-running processes and remote work.

## Basic Commands

- `tmux new -s mysession` - Create a new named session
- `tmux attach -t mysession` - Attach to an existing session
- `tmux ls` - List all sessions

## Key Bindings

The default prefix is `Ctrl+b`, followed by:

- `c` - Create new window
- `n` - Next window
- `p` - Previous window
- `%` - Split pane vertically
- `"` - Split pane horizontally

## More to come...

This tutorial will be expanded with more advanced topics.
