# Tmux Tutorial

Tmux is a terminal multiplexer that lets you run multiple terminal sessions inside a single window.

This tutorial is based on my custom [tmux.conf](https://github.com/vivainio/dotfiles/blob/master/tmux.conf). It makes tmux more ergonomic and significantly prettier, without bloated plugins. It may not be the best conf, but it's mine.

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
| Close other tabs | `Prefix + o` |
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

`Prefix + d` detaches from tmux, leaving all sessions running in the background. Reattach with `tmux a`, or start a new session with `tmux new -s name`.

## Level 3: Panes

Panes let you split a tab into multiple views.

| Action | Binding |
|--------|---------|
| Split vertically | `Prefix + %` |
| Split horizontally | `Prefix + "` |
| Kill pane | `Prefix + x` |
| Switch pane | `Prefix + arrow keys` |

## Tip: Copy Mode

Need to scroll up or copy text? Enter copy mode with `Prefix + Enter`. Uses vim keys:

| Action | Key |
|--------|-----|
| Navigate | `h/j/k/l` |
| Start selection | `Space` |
| Copy | `Enter` |
| Paste | `Ctrl+v` |
| Exit | `q` |

## Level 4: Extensibility

Tmux is highly scriptable. My config adds `Prefix + Ctrl+G` which pops up lazygit in a floating window for easy review of current changes in the tab's working directory. The popup appears over your current work and closes when you're done.

## Q&A

**Why not Zellij?**

Tmux is more mature and a much smaller application. It's not written in Rust (yet), but it does everything it needs to do and can be extended to the rest.

**Seriously, why??**

With the advent of AI, there is growing ability to multitask. Multitasking is made much easier if you have full sessions that contain the context for one task, and can easily hop to other sessions with next steps waiting for you. In IDEs it's easy to get lost among windows and blinking lights, while terminal sessions stay very focused on an individual task.
