# Everyday Shortcuts

*2026-09-21*

The Mac keyboard has the same keys as everyone else's, but they are used
differently. Once the modifier keys make sense, the rest of macOS gets much
easier to learn.

## The modifier keys

| Symbol | Key | Roughly equivalent to | Used for |
|--------|-----|-----------------------|----------|
| ⌘ | Command (`cmd`) | `Ctrl` on Windows | App shortcuts: copy, paste, save, new tab |
| ⌥ | Option (`alt`) | `Alt` | Typing special characters, word-wise navigation, alternate menu actions |
| ⌃ | Control (`ctrl`) | (none really) | Terminal shortcuts, Mission Control, some text editing |
| ⇧ | Shift | `Shift` | Same as everywhere |
| fn / 🌐 | Function / Globe | `Fn` | Function keys, emoji picker, dictation |

The big shift: **⌘ is the main shortcut key, not Control.** Copy is
++cmd+c++, paste is ++cmd+v++, and it is the same in almost every app. Because
Control is not busy doing that job, terminals can keep ++ctrl+c++ for
interrupting a process.

### Option is for words and symbols

- ++option+left++ / ++option+right++ moves the cursor by one word.
- ++option+backspace++ deletes the previous word.
- Holding ++option++ while typing produces special characters, for example
  ++option+2++ gives ™ on a US layout.
- On European keyboard layouts ++option++ also works as **AltGr**: it is the
  key for `@`, brackets, braces, backslash, and `|`. On a Finnish layout, for
  example, `@` is ++option+2++, `[` and `]` are ++option+8++ and ++option+9++,
  and `{` `}` add ++shift++. The exact keys differ per layout, so check the
  Keyboard Viewer (enable *Show Input menu in menu bar* in *Keyboard → Text
  Input → Input Sources*) to see what Option and ++option+shift++ produce.
- Holding ++option++ while clicking a menu often reveals a hidden alternate
  item (for example, "Save As…" instead of "Save").
- In a terminal you often want Option to act as Meta/Alt. In Terminal.app
  it is under *Settings → Profiles → Keyboard → Use Option as Meta key*; iTerm2
  has an equivalent setting.

### Cursor movement without Home and End

Mac keyboards have no Home/End keys. Combine arrows with modifiers instead:

| Shortcut | Action |
|----------|--------|
| ++cmd+left++ / ++cmd+right++ | Start / end of line |
| ++cmd+up++ / ++cmd+down++ | Start / end of document |
| ++option+left++ / ++option+right++ | Previous / next word |
| ++fn+up++ / ++fn+down++ | Page up / page down |
| ++fn+left++ / ++fn+right++ | Home / End (scroll to top / bottom of the view in many apps) |
| ++fn+backspace++ | Forward delete (the Delete key on Windows) |
| Add ++shift++ to any of the above | Select while moving |

Emacs-style shortcuts also work in most native text fields: ++ctrl+a++ (line
start), ++ctrl+e++ (line end), ++ctrl+k++ (kill to end of line).

## Shortcuts worth learning first

### Everyday

These are the same as on Windows, with ++cmd++ in place of ++ctrl++. Your
muscle memory carries over; only the finger changes. The ones without a
Windows equivalent are ++cmd+q++ (quit) and ++cmd+comma++ (settings).

| Shortcut | Action |
|----------|--------|
| ++cmd+c++ / ++cmd+x++ / ++cmd+v++ | Copy / cut / paste |
| ++cmd+z++ / ++cmd+shift+z++ | Undo / redo |
| ++cmd+a++ | Select all |
| ++cmd+f++ | Find |
| ++cmd+s++ | Save |
| ++cmd+n++ / ++cmd+t++ | New window / new tab |
| ++cmd+w++ | Close window or tab |
| ++cmd+q++ | Quit the app (closing the last window does *not* quit it) |
| ++cmd+comma++ | Open the app's Settings |
| ++cmd+shift+t++ | Reopen last closed tab (browsers) |

### Switching and finding your way around

| Shortcut | Action |
|----------|--------|
| ++cmd+tab++ | Switch between apps (hold ++cmd++, tap ++tab++ to cycle) |
| ++cmd+grave++ | Switch between windows of the *current* app |
| ++cmd+h++ | Hide the current app |
| ++cmd+m++ | Minimize the window |
| ++ctrl+up++ | Mission Control: overview of all windows and desktops |
| ++ctrl+left++ / ++ctrl+right++ | Move between desktops (Spaces) |
| ++cmd+space++ | Spotlight |

### Screenshots

| Shortcut | Action |
|----------|--------|
| ++cmd+shift+3++ | Screenshot of the whole screen |
| ++cmd+shift+4++ | Screenshot of a selected area |
| ++cmd+shift+5++ | Screenshot and screen recording toolbar |

Add ++ctrl++ to the first two to copy the screenshot to the clipboard instead
of saving a file.

### Finder

| Shortcut | Action |
|----------|--------|
| ++return++ | *Rename* the selected file (not open it!) |
| ++cmd+o++ or ++cmd+down++ | Open the selected item |
| ++space++ | Quick Look: preview the file without opening it |
| ++cmd+backspace++ | Move to Trash |
| ++cmd+shift+period++ | Show/hide hidden files |
| ++cmd+shift+g++ | Go to a folder by typing its path |
| ++cmd+up++ | Go to the enclosing folder |

### Force quit

If an app hangs, use ++cmd+option+esc++ to open the Force Quit window.

!!! tip "Discover shortcuts from the menu bar"
    Every menu item that has a shortcut shows it next to the name. The **Help**
    menu in any app has a search box that finds menu items by name and shows
    you where they live, which is a quick way to learn shortcuts as you go.

## Mouse and trackpad

### Right click

- **Trackpad:** click with two fingers. If that does nothing, enable it in
  *System Settings → Trackpad → Point & Click → Secondary click*.
- **Any pointing device:** hold ++ctrl++ and click. This works everywhere,
  including with a one-button mouse or a laptop with the trackpad set to
  single-finger clicks.
- **Mouse:** a mouse with two buttons works as expected once *Secondary click*
  is set to the right side in *System Settings → Mouse*.

### Modifier clicks

Like the everyday shortcuts, most of these match Windows with ++cmd++ in place
of ++ctrl++: ++cmd++ + click toggles a single item and ++shift++ + click
selects a range. The Mac-specific one is ++ctrl++ + click, which is right
click, not multi-select.

| Action | Result |
|--------|--------|
| ++cmd++ + click on a link | Open in a new tab (browsers) |
| ++cmd++ + click on files | Add or remove a single item from the selection |
| ++shift++ + click on files | Select a range |
| ++option++ + drag a file | Copy it instead of moving it |
| ++cmd+option++ + drag a file | Create an alias (a shortcut) |
| ++cmd++ + drag a window | Move a background window without focusing it |
| ++option++ + click the green window button | Maximize the window (without fullscreen) |
| ++option++ + click a menu | Show alternate menu items |

Double-clicking a window's title bar zooms or maximizes it, depending on the
setting in *Desktop & Dock*.

### Gestures worth knowing

| Gesture | Action |
|---------|--------|
| Two-finger scroll | Scroll |
| Two-finger swipe left/right | Back / forward in browsers and many apps |
| Pinch, or double-tap with two fingers | Zoom |
| Three-finger tap (or force click) | Look up the word under the pointer |
| Three or four fingers up | Mission Control |
| Three or four fingers left/right | Switch desktops |

!!! tip "Turn on tap to click and three-finger drag"
    Tap to click is off by default: *System Settings → Trackpad → Point &
    Click*. Three-finger drag, which moves windows and selects text without
    pressing down, is in *Accessibility → Pointer Control → Trackpad
    Options → Use trackpad for dragging*.

!!! note "Scroll direction"
    "Natural" scrolling moves the content like a touch screen, and it is on
    by default. If a mouse feels backwards, turn it off in *System Settings →
    Mouse*. The trackpad has its own separate switch.

## Spotlight

Spotlight is the launcher, calculator, unit converter, and search box for the
whole Mac. Open it with ++cmd+space++ and start typing.

### Launching apps

Type a few letters of an app's name and press ++return++. After a few days
Spotlight learns your habits, so `saf` is enough for Safari and `term` is
enough for Terminal. You will rarely need the Dock or Launchpad again.

### What else it does

- **Calculator:** type `18% of 240` or `(12 + 7) * 3` and the answer appears
  immediately.
- **Unit and currency conversion:** `5 miles in km`, `100 usd in eur`.
- **Files and folders:** search by name; press ++cmd+return++ to reveal the
  selected result in Finder.
- **Definitions and quick facts:** type a word to see its dictionary entry.
- **Settings:** type "bluetooth" or "display" to jump straight to the
  relevant System Settings page.
- **Shortcuts and actions:** in recent macOS versions Spotlight can run
  Shortcuts and app actions, such as creating a note or starting a timer.
- **Clipboard history:** recent macOS versions can browse recently copied
  items from Spotlight. Check *Spotlight* in System Settings for the exact
  shortcut on your version.

### Filtering results

Use the filter buttons at the top of the Spotlight window, or type a kind
keyword such as `kind:pdf` or `kind:folder` in the query. Specific queries
like `kind:pdf invoice` narrow results fast.

### Tune it

Under *System Settings → Spotlight* you can turn off result categories you
never use, so the list stays relevant. Add folders to the *Search Privacy*
list to exclude them (large build output or `node_modules` directories are
good candidates).

!!! note "Not happy with Spotlight?"
    Third-party launchers such as Raycast and Alfred build on the same idea
    with plugins, snippets, and clipboard history. They are worth trying once
    the Spotlight habit is in place, and they can take over ++cmd+space++.

## Make the keyboard fit you

- **Swap or remap modifiers:** *System Settings → Keyboard → Keyboard
  Shortcuts → Modifier Keys* lets you, for example, turn Caps Lock into
  Control or Escape.
- **Faster key repeat:** *System Settings → Keyboard* has sliders for key
  repeat rate and delay; turning both up makes text editing feel much snappier.
- **Full keyboard access:** in the same place you can enable Tab navigation
  across all controls in dialogs.
- **Custom app shortcuts:** *Keyboard Shortcuts → App Shortcuts* lets you
  assign a shortcut to any menu item by its exact name.

## Where next

1. Pick five shortcuts from above and use them for a week.
2. Make Spotlight the *only* way you launch apps.
3. Next in this series: window management, Finder tricks, and the terminal.
