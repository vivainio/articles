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

Modern shells and Claude Code change the tab title based on what's happening in the window. Normally this would go to the terminal window title, but tmux captures it and renders it as the tab title within the window.

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

`Prefix + w` shows you all sessions and tabs within each session, with a preview of the tab content. This makes it easy to peek at ongoing work and jump back to it.

## Level 3: Panes

Panes let you split a tab into multiple views.

| Action | Binding |
|--------|---------|
| Split vertically | `Prefix + %` |
| Split horizontally | `Prefix + "` |
| Kill pane | `Prefix + x` |
| Switch pane | `Prefix + arrow keys` |
