# My Vibing Flow

*2026-02-24*

This is how I use Claude Code in WSL to get things done.

## Tmux First

The first thing I do after entering bash is start [tmux](tmux-tutorial.md). Everything happens inside tmux sessions from there.

## Starting a Project Session

I `cd` to the directory I want to work on (in practice, I use [Zoxide](https://github.com/ajeetdsouza/zoxide) to jump there) and run `wss`. This creates a new tmux session in that directory with Claude Code already running on tab 1, ready to go. `wss` comes from [tmux-util.nu](https://github.com/vivainio/nu-prelude/blob/main/tmux-util.nu), a Nushell library.

## Working in a Session

From there, I open new tabs to run commands in the project directory. For quick access to common tools, I use tmux popup shortcuts:

- `Prefix + Ctrl+G` - lazygit to review diffs
- `Prefix + Ctrl+L` - lf file manager to browse files

These float over the current tab and disappear when done. See [my tmux tutorial](tmux-tutorial.md) for the full setup.

Often while working in one session, I'll branch off to start a new session with `wss` in another directory - maybe to fix something I noticed, or to work on a dependency. Switching between sessions is instant with `Alt+Up/Down`.

For complex projects, I script the whole workspace. Here's an example using `tmux-workspace` from the same Nushell library:

```nushell
use ~/nu-prelude/tmux-util.nu *

tmux-workspace "my-project" [
  ["Claude",   ".",              "claude"],
  ["Api",      "src/Api",       "dotnet run"],
  ["TestHost", "test/TestHost",  "dotnet run"],
  ["admin-ui", "ui/admin",      "npm start"],
  ["main-ui",  "ui/main",       "npm start"],
]
```

This creates a session with five tabs, each in the right directory and running its command. Claude is on tab 1, backend services on the next tabs, and frontend dev servers last.
