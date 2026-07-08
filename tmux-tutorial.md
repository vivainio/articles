# Tmux Tutorial

*2026-01-12*

Tmux is a terminal multiplexer that lets you run multiple terminal sessions inside a single window.

This tutorial is based on my custom [tmux.conf](https://github.com/vivainio/dotfiles/blob/master/tmux.conf). It makes tmux more ergonomic and significantly prettier, without bloated plugins. It may not be the best conf, but it's mine.

## Why Tmux?

Tmux makes it easy to multitask across many projects in different sessions, with one or more Claude Code instances running in each session.

## Installation (Ubuntu)

```bash
sudo apt update
sudo apt install tmux
```

Check the version with `tmux -V`. If you need a newer release than what Ubuntu ships (the config below relies on reasonably recent tmux features like `display-popup`), build from source or grab a backport - see the [tmux wiki](https://github.com/tmux/tmux/wiki/Installing).

## Setting Up tmux.conf

Grab my config and drop it in as `~/.tmux.conf` before you start tmux for the first time:

```bash
curl -o ~/.tmux.conf https://raw.githubusercontent.com/vivainio/dotfiles/master/tmux.conf
```

The popups in [Level 5](#level-5-extensibility) call out to `lazygit` and `lf` - install those separately if you want those bindings to work:

```bash
sudo apt install lazygit lf
```

(Ubuntu's `apt` may only have an old `lazygit`; if so, install it from the [lazygit releases page](https://github.com/jesseduffield/lazygit/releases) instead.)

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
| Kill session | `Prefix + K` |
| Detach | `Prefix + d` |

All new tabs in a session start in the same directory where you created the session. This makes sessions ideal for grouping related work - one session per project, and every tab opens ready to go in that project's folder.

`Prefix + w` opens the tree view, showing all sessions, tabs, and panes with a preview of each:

```
  backend
  ├─ 1: claude
  ├─ 2: server
  └─ 3: tests
  frontend
  ├─ 1: claude
  └─ 2: dev
  notes
  └─ 1: claude
```

This makes it easy to peek at ongoing work and jump back to it. Type `/` to search within the tree by name.

`Prefix + d` detaches from tmux, leaving all sessions running in the background. Reattach with `tmux a`, or start a new session with `tmux new -s name`.

## Level 3: Panes

Panes let you split a tab into multiple views. I'll admit I don't use panes as much as I should - I tend to reach for new tabs instead. But they're useful when you want to see two things side by side.

| Action | Binding |
|--------|---------|
| Split vertically | `Prefix + %` |
| Split horizontally | `Prefix + "` |
| Kill pane | `Prefix + x` |
| Switch pane | `Prefix + arrow keys` |

## Level 4: Copy Mode

Scrolling up with the mouse wheel enters copy mode automatically - this can catch you off guard, so just press `q` to exit back to normal mode and scroll back to the bottom, ready to continue typing. You can also enter copy mode explicitly with `Prefix + Enter`.

| Action | Key |
|--------|-----|
| Navigate | arrow keys |
| Search | `/` (forward), `?` (backward), `n`/`N` to jump between matches |
| Start selection | `Space` |
| Copy | `Enter` |
| Paste | `Ctrl+v` |
| Exit | `q` |

## Level 5: Extensibility

Tmux is highly scriptable. My config uses `display-popup` to launch apps in floating windows that appear over your current work and close when you're done:

| Popup | Binding |
|-------|---------|
| [lazygit](https://github.com/jesseduffield/lazygit) | `Prefix + Ctrl+G` |
| [lf](https://github.com/gokcehan/lf) file manager | `Prefix + Ctrl+L` |
| Daily notes editor | `Prefix + Ctrl+N` |

Lazygit is launched with `--screen-mode half` for comfortable diff viewing, and opens in the tab's working directory.

## Q&A

**Why not Zellij?**

Tmux is more mature and a much smaller application. It's not written in Rust (yet), but it does everything it needs to do and can be extended to the rest.

**Seriously, why??**

With the advent of AI, there is growing ability to multitask. Multitasking is made much easier if you have full sessions that contain the context for one task, and can easily hop to other sessions with next steps waiting for you. In IDEs it's easy to get lost among windows and blinking lights, while terminal sessions stay very focused on an individual task.
