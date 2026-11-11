# What is Herdr Desktop?

*2026-11-11*

Herdr Desktop is a desktop workspace for terminals and coding agents. You organize work into spaces, tabs and split panes, while an agent sidebar shows which tasks are working, waiting for input or finished. The window is a client of **herdr-core**, which owns the running terminals. Closing the window leaves those terminals running in the core. See the [official project](https://github.com/herdrdev/herdr-app) for installation and platform support.

The part that interests me most is how the interface is built: **a native Rust application renders GPUI elements composed in JavaScript, inside a window described by JSON.** That makes the interface itself something you can work on as files.

## GPUI supplies the native UI

[GPUI](https://gpui.rs/) is the GPU-accelerated Rust UI framework from the creators of Zed. Its API builds element trees with methods such as `div()`, `.flex()`, and `.child()`. It combines immediate and retained mode techniques.

Those names can look familiar to web developers, but they describe GPUI's own elements. The useful distinction is between the language used to describe an interface and the system that renders it: JavaScript can describe a native interface just as Rust can.

[GPUI Kit](https://gpui-kit.com/) adds components and tooling on top of GPUI. Its **gpui-shell** layer lets a Rust host expose capabilities to JavaScript and lets scripts build interface elements in the same process. This is the bridge behind Herdr's mod interface; Herdr carries its own copy and documents its available API in bundled type declarations.

The JavaScript runs in an embedded **QuickJS-based runtime**. More specifically, the current source uses `quickjs-jit`: its [Cargo manifest](https://github.com/herdrdev/herdr-app/blob/master/Cargo.toml) patches in a vendored `quickjs-jit-runtime` and notes that gpui-shell and its LLRT modules share that VM. QuickJS executes the mod code, gpui-shell connects it to the Rust host, and GPUI renders the resulting native elements.

## JSON arranges the window; JavaScript fills it

Herdr's [interface guide](https://github.com/herdrdev/herdr-app/blob/master/defaults/AGENTS.md) describes two composition levels. Layout JSON arranges rows, columns, stacks and content blocks. Blocks can contain a mod or terminal content. JavaScript mods implement panels, menus and dialogs using GPUI elements. The shipped interface uses these same building blocks.

A simplified layout illustrates the division:

```json
{
  "id": "root",
  "type": "row",
  "children": [
    {
      "id": "sidebar",
      "type": "block",
      "size": { "px": 240 },
      "content": { "mod": "spaces" }
    },
    {
      "id": "work",
      "type": "block",
      "content": { "tab": "active" }
    }
  ]
}
```

The layout chooses where the sidebar goes. The `spaces` mod decides what appears inside it. Native terminal rendering remains the host's responsibility.

A more useful example is an agent attention panel: filter the live agent
list, put blocked agents first, and click a row to focus its terminal.
This illustrative `main.js` uses the APIs documented in Herdr's bundled
`AGENTS.md` and type declarations:

```javascript
import { View, div } from "gpui-kit";
import { h_flex, v_flex } from "gpui-base";
import { agents, run, theme } from "herdr";

const priority = { blocked: 0, done: 1, working: 2, idle: 3 };

export default class AttentionPanel extends View {
  init() {
    this.onlyAttention = true;
  }

  render() {
    const colors = theme();
    const all = agents();
    const needsAttention = (a) =>
      a.status === "blocked" || a.status === "done";
    const waiting = all.filter(needsAttention).length;
    const visible = all
      .filter((a) => !this.onlyAttention || needsAttention(a))
      .sort((a, b) => priority[a.status] - priority[b.status]);

    const panel = v_flex()
      .gap(8)
      .p(12)
      .child(
        h_flex()
          .items_center()
          .justify_between()
          .child(`Needs you: ${waiting}`)
          .child(
            div()
              .id("toggle-attention")
              .px(8)
              .py(4)
              .rounded(4)
              .bg(colors.surface)
              .child(this.onlyAttention ? "Show all" : "Attention only")
              .on_click((_event, cx) => {
                this.onlyAttention = !this.onlyAttention;
                cx.notify();
              })
          )
      );

    for (const agent of visible) {
      panel.child(
        h_flex()
          .id(`agent-${agent.address}`)
          .gap(8)
          .p(8)
          .rounded(4)
          .hover((style) => style.bg(colors.surface))
          .child(div().flex_1().child(
            `${agent.space_name}: ${agent.title || agent.app || agent.address}`
          ))
          .child(agent.status)
          .on_click(() => run("agent.focus", {
            terminal: agent.address
          }))
      );
    }

    if (!visible.length) panel.child("No agents in this view.");
    return panel;
  }
}
```

This combines ordinary JavaScript filtering and sorting with native UI
composition. `v_flex()` stacks elements; `h_flex()` arranges a row. Chained
builders set spacing, colors and hover behavior, and stable element IDs
identify interactive controls.

The filter is instance state on the `View`. Clicking the toggle changes
that state and calls `cx.notify()` to request a render. Herdr also renders
mods again when its live data changes, so `agents()` needs no polling loop.
Clicking an agent invokes `agent.focus` through the host's command API,
using the same command mechanism as a keybinding.

The snippet illustrates the panel code; installing it also requires a mod
manifest and a layout block referencing the mod. It has been checked
against the installed API documentation, but has not been run in Herdr.

There is no browser DOM, HTML or CSS here, and the runtime does not provide Node APIs. The JavaScript describes GPUI elements; Rust draws them. Host APIs supply application data and commands.

Personal layout and mod edits reload while the app runs. Duplicate shipped layouts and mods before changing them, since Herdr maintains the shipped copies. Mods are trusted code with access to capabilities such as running programs, rather than sandboxed extensions. These details are covered in the [mod guide](https://github.com/herdrdev/herdr-app/blob/master/defaults/AGENTS.md).

## How panels communicate

A layout describes composition; the mods inside it implement behavior.
Mods can coordinate through `shared(key)` and `setShared(key, value)` from
`herdr`. Every mod can read these values, and changing one causes all mods
to render again. For example, a toolbar can set a filter that a separate
agent panel reads:

```javascript
// In a toolbar's click handler:
setShared("my-dashboard.attention-only", true);

// In the agent panel's render method:
const onlyAttention = shared("my-dashboard.attention-only") ?? false;
```

Each mod imports the functions it uses from `herdr`. Namespacing the key
keeps unrelated mods from accidentally sharing a setting. This is shared
application state, rather than a direct call from one layout to another.
`localStorage` provides a separate persistence mechanism per mod copy.

The host API goes further than drawing. Mods can read live spaces, agents,
terminals, focus and theme; invoke app commands with `run()`; open other
mods as dialogs or popups with `openOverlay()` and pass them `props`; and
post notifications. They can also run programs with `exec()`, access
terminal operations through `hc()`, read files, watch folders and use
`fetch()`. Mod commands arrive through `nextCommand()`, allowing a
keybinding to trigger custom mod behavior. The bundled `herdr.d.ts` and
[interface guide](https://github.com/herdrdev/herdr-app/blob/master/defaults/AGENTS.md#the-herdr-module)
describe the available surface.

### Open a dialog and pass context

One mod can open another with explicit props. For example, a panel's
click handler could open an `agent-details` mod for a selected agent:

```javascript
import { openOverlay } from "herdr";

// Inside a click handler, where agent is the selected row:
openOverlay({
  mod: "agent-details",
  kind: "dialog",
  width: 420,
  height: 180,
  props: { terminal: agent.address, title: agent.title }
});
```

The receiving mod reads those props and can act on the selected terminal:

```javascript
import { View, div } from "gpui-kit";
import { v_flex } from "gpui-base";
import { props, run, closeOverlay } from "herdr";

export default class AgentDetails extends View {
  render() {
    const { terminal, title, overlay } = props();
    return v_flex().gap(12).p(16)
      .child(title || terminal)
      .child(
        div().id("focus-agent").child("Go to agent")
          .on_click(() => {
            closeOverlay(overlay);
            run("agent.focus", { terminal });
          })
      );
  }
}
```

Herdr supplies the `overlay` ID so the dialog can close itself. The props
carry the specific terminal address, so the action targets the selected
agent even if focus changes. As with the panel example, the receiving mod
also needs its own manifest.

### Send a keyboard command to a mod

A keybinding can invoke custom mod behavior. Add a binding to the relevant
section of your existing `keys.json`:

```json
{
  "global": {
    "cmd-shift-j": "attention-panel.toggle"
  }
}
```

Here `attention-panel` is the mod's name and `toggle` is the command it
receives. To handle it, replace the attention panel's earlier `init()`
with this version:

```javascript
// Also import nextCommand from "herdr".
init(_props, cx) {
  this.onlyAttention = true;
  cx.spawn(async (cx) => {
    for (;;) {
      const command = await nextCommand();
      if (command === "toggle") {
        this.onlyAttention = !this.onlyAttention;
        cx.notify();
      }
    }
  });
}
```

`nextCommand()` waits asynchronously for a command. It does not poll.
This lets the keyboard and the panel's button change the same view state.
The mod must be loaded for its command handler to be running. These are
illustrative API examples, checked against the installed declarations;
they have not been exercised in the running app.

## Configure it by giving your agent AGENTS.md

On my Mac, Herdr's interface files live in `~/.config/herdr-app`. That directory includes an `AGENTS.md` explaining
how to configure the app: layouts, settings, keybindings, mods and the APIs
available to them.

The workflow is to ask your coding agent to read that file, then ask it
to make changes to your config. You describe what you want in plain
language, and the agent edits the appropriate files. For example:

```text
Read ~/.config/herdr-app/AGENTS.md so you know how to
configure my Herdr Desktop.
```

Then ask for changes:

```text
Change my config to move the agents sidebar to the right. Make a
personal copy of the layout first.
```

You can keep asking for adjustments in the same conversation: change a
keybinding, make the sidebar narrower, or add a panel for your workflow.
The agent uses those instructions to edit the configuration and mod files;
Herdr reloads the changes in the running window. `AGENTS.md` is the guide
for making those edits, rather than the configuration itself. Herdr
regenerates it on startup, so put customizations in the files it describes.

## Keybindings: my Option+Arrow navigation

Keybindings live in `~/.config/herdr-app/keys.json`. Each entry maps a
key combination to an app command. On macOS, `alt` in this file means
Option. My configuration includes these bindings in both the `global`
and `terminal` sections:

```json
{
  "global": {
    "alt-left": "tab.prev",
    "alt-right": "tab.next",
    "alt-up": "space.prev",
    "alt-down": "space.next"
  },
  "terminal": {
    "alt-left": "tab.prev",
    "alt-right": "tab.next",
    "alt-up": "space.prev",
    "alt-down": "space.next"
  }
}
```

This is an excerpt of my file, rather than a replacement for the complete
configuration. Option+Left/Right switches tabs; Option+Up/Down switches
spaces. There is no prefix key to press first.

The sections set the context: `global` provides general bindings, while
`terminal` applies when a terminal has focus and takes precedence. My file
repeats these four mappings in both, keeping the navigation explicit in
each context. Layout-specific and mod-specific sections are also supported.

These bindings invoke Herdr commands directly in the desktop app. Unlike
my [TUI setup](herdr.md#mac-bindings), they do not require Ghostty to send
particular escape sequences. The desktop app handles the keypress itself,
so these combinations navigate Herdr instead of reaching the program in
the terminal. Saving `keys.json` reloads the bindings live.

The same command system serves keys, menus and JavaScript mods:
`tab.next` is a command a key can invoke or a mod can run. Bindings can also
send literal text to a terminal (`send:<text>`) or explicitly pass a key
through to its program (`terminal`). See the [keybinding reference](https://github.com/herdrdev/herdr-app/blob/master/defaults/AGENTS.md#keys-keysjson)
for contexts and command arguments.

## Why this composition model is interesting

My reading of this design is that it lowers the cost of changing the workspace around your terminals. Moving a sidebar is a layout edit. Adding a purpose-built panel is a JavaScript task. Rendering and terminal infrastructure remain in the native host.

It also gives a coding agent a concrete surface to edit: ordinary files describing the interface you want. That suggests a useful workflow: ask for a panel, inspect the result in the running application, and refine it. The same mechanism can serve both small personal adjustments and substantially different layouts.

For terminal navigation and the older multiplexer workflow, see my [Herdr Tutorial](herdr.md). This article concerns the separate `herdr-app` desktop project and its GPUI-plus-JavaScript interface.
