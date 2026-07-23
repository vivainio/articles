# Codex for Claude Code Users

*2026-07-24*

If you already use Claude Code, Codex feels familiar within a few minutes: start it in a repository, describe what you want, review what it changes, and keep steering until the job is done. The interesting differences are not in the basic chat loop. They are in how Codex organizes configuration, reusable workflows, permissions, and long-running work.

This guide covers the differences that matter when moving between the two.

## Permissions have two dimensions

This is the difference most worth understanding early.

The approval policy controls when Codex asks before running something. The sandbox controls what the process can access. A permissive approval policy does not automatically give a command unrestricted filesystem or network access, and a permissive sandbox does not necessarily mean Codex will stop asking.

In normal repository work, `workspace-write` is a good default: Codex can edit the current workspace while access outside it remains constrained. When a task needs to install dependencies, write elsewhere, open a GUI, or reach a restricted network resource, Codex can request a scoped escalation.

On Linux, both Claude Code and Codex use Bubblewrap. The difference is how they use it. Claude's sandbox is a separately enabled feature for Bash commands and their subprocesses; its built-in Read, Edit, and Write tools remain behind Claude's permission system. Codex uses Bubblewrap as the normal command-execution boundary whenever its sandbox mode is `read-only` or `workspace-write`. It prefers the system `bwrap`, but ships its own fallback.

Codex does not normally expand the session's sandbox every time you approve something. The writable roots come from the selected policy, workspace roots, and configuration. If one command needs more access, Codex requests an escalation for that command. Once approved, that invocation runs outside the normal sandbox; subsequent commands return to the original boundary. `danger-full-access` disables the sandbox altogether.

There is an experimental Codex facility for requesting additional per-command permissions while remaining sandboxed, but it is still marked under development and disabled by default. It is not something to build a normal setup around yet.

## Auto mode is configured, not toggled with Shift+Tab

In Claude Code you can press `Shift+Tab` to cycle permission modes, including an auto-accepting mode. Codex does not use that interaction for its auto mode. Configure automatic approval review in `~/.codex/config.toml`:

```toml
approval_policy = "on-request"
approvals_reviewer = "auto_review"
```

`approval_policy = "on-request"` lets Codex request an escalation when a command needs capabilities outside the active sandbox. `approvals_reviewer = "auto_review"` sends those requests through Codex's automatic reviewer instead of stopping for you to approve every one.

This is deliberately narrower than turning off safety checks. The reviewer can reject an escalation, and the sandbox still defines what an un-escalated command may access. In other words, auto mode removes routine confirmation clicks; it does not mean that every command automatically receives unrestricted access.

Because this is a persistent config setting, it applies when you start a new
Codex session. There is no need to press `Shift+Tab` after launching Codex in
each repository. I always use this auto mode; I prefer letting the reviewer
handle routine escalation decisions instead of interrupting the session for
manual confirmation.

## Command rules and the automatic reviewer are separate

Claude Code lets you whitelist or blacklist commands. The closest Codex
equivalent is a set of prefix rules in `~/.codex/rules/default.rules`. Each rule
can allow a matching command to run outside the sandbox without prompting,
require a prompt, or forbid it entirely:

```python
prefix_rule(
    pattern = ["git", "push"],
    decision = "allow",
)

prefix_rule(
    pattern = ["rm"],
    decision = "forbidden",
    justification = "Do not delete files automatically.",
)
```

Codex applies the most restrictive matching decision: `forbidden`, then
`prompt`, then `allow`. You can test the result before relying on it:

```bash
codex execpolicy check --pretty \
  --rules ~/.codex/rules/default.rules \
  -- git push
```

This is distinct from the automatic reviewer. Prefix rules make deterministic
decisions about known command prefixes; the reviewer classifies approval
requests that still reach it. Both mechanisms are active at the same time. When
a command needs to cross the sandbox boundary, an `allow` rule lets it proceed
without review, a `forbidden` rule blocks it, and a `prompt` decision—or a
request without a decisive rule—continues to the automatic reviewer. Commands
already permitted inside the sandbox need neither.

You can also replace the reviewer's local policy:

```toml
approvals_reviewer = "auto_review"

[auto_review]
policy = """
...custom reviewer policy...
"""
```

If you do this, start with Codex's complete
[default reviewer policy](https://github.com/openai/codex/blob/main/codex-rs/core/src/guardian/policy.md)
and modify it. The setting replaces the local policy rather than adding a small
preference to it, and an organization-managed policy can take precedence.

Since I always use auto mode, prefix rules are useful mainly for the decisions I
want to make deterministic before they reach the reviewer. I would use them for
concrete allow-or-deny choices and customize the reviewer only for broader risk
judgments. Rules are predictable; the reviewer is still model-based.

## The status line is worth configuring

Run:

```text
/statusline
```

Codex lets you select built-in fields such as the model and reasoning level, current directory, Git branch, context use, and usage limits. The selection is persisted under `[tui]` in `~/.codex/config.toml`:

```toml
[tui]
status_line = [
  "model-with-reasoning",
  "current-dir",
  "git-branch",
  "context-used",
  "five-hour-limit",
  "weekly-limit",
]
status_line_use_colors = true
```

Unlike Claude Code's command-backed status line, Codex currently limits this to
its built-in fields. You cannot yet pipe arbitrary JSON into your own formatter
script. In Claude Code I use
[cship](https://cship.dev/), which turns that flexibility into a polished,
highly customizable status line.

Even so, I prefer Codex's approach. The built-in fields cover the information I
actually want, and configuring them directly is simpler than maintaining another
formatter process, input protocol, and configuration file. Claude Code offers
more freedom here; Codex gives me the better default experience.

## Skills, plugins, and MCP

Skills do not become `/skill-name` commands in Codex. Slash commands are reserved for built-in TUI actions. In the Codex UI you can discover a skill through the `@` mention menu; the canonical explicit invocation in a prompt is `$skill-name`:

```text
$github-release publish the current version
```

This deviates from the convention established by Claude Code and GitHub Copilot, where user-defined agent workflows commonly become `/commands`. Codex used to support custom prompts under `~/.codex/prompts`, but removed them in favor of skills. There is currently no supported way to create a custom slash command:

```text
Claude Code / GitHub Copilot: /kiss
Codex:                       $agent-skills:kiss
```

Packaging the skill in a plugin adds a namespace and makes it installable, but does not restore the slash command.

Codex can also select a skill automatically when your request matches its description. This makes skills feel less like a directory of custom commands and more like attachable task instructions. Typing `/github-release`, as you might in Claude Code, is intentionally unsupported.

The `@` picker can include more than skills, such as apps and other mentionable context, so it is useful for discovery. Once you know the name, `$skill-name` is the unambiguous way to request that skill explicitly.

In normal Codex CLI use, `$` effectively means “attach this skill.” OpenAI-managed apps and connectors can also use `$`, but they are uncommon and cannot be created locally by inventing an app manifest. MCP servers work differently: after you configure one, Codex exposes its tools to the model and selects them from a natural-language request. There is no `$mcp-server` invocation syntax.

```text
$name   skill invocation
/name   built-in Codex command
MCP     selected by the model from your request
```

For a custom CLI integration, build an MCP server. A plugin can distribute its MCP configuration together with related skills and hooks; the plugin's `apps` field only references OpenAI-registered connector IDs.

## One plugin repository can support both

Claude Code and Codex do not use the same marketplace manifest, but they can share the actual plugin contents. Keep one copy of each skill and add thin client-specific manifests around it:

```text
my-plugins/
├── .claude-plugin/marketplace.json
├── .agents/plugins/marketplace.json
└── plugins/
    └── team-tools/
        ├── .claude-plugin/plugin.json
        ├── .codex-plugin/plugin.json
        └── skills/
            ├── release/SKILL.md
            └── jira-check/SKILL.md
```

The `skills/`, scripts, references, and often `.mcp.json` can be shared. Marketplace files and plugin manifests remain separate because their paths and schemas differ. Hooks need compatibility testing because Codex supports fewer events and output fields.

The installed skills also use different invocation syntax:

```text
Claude Code: /team-tools:release
Codex:       $team-tools:release
```

This makes skills a practical cross-agent format even though plugin packaging is not yet portable as a single manifest.

## Hooks are less capable

Codex uses the same general `hooks.json` shape as Claude Code, but its hook implementation is younger and currently does less. The useful core is there: hooks can run at session start, prompt submission, before and after supported tool calls, during permission requests, and when the agent stops. A `PreToolUse` hook can block an operation, so common policy and formatting workflows carry over.

Claude Code has substantially broader lifecycle coverage, including tool failures and batches, subagents, compaction, worktrees, notifications, and configuration changes. It also supports more handler types, including commands, HTTP endpoints, MCP tools, LLM prompts, and agentic verifiers. Its hooks can modify tool inputs and outputs, update permission rules, and inject context at more points.

Codex still has compatibility gaps. Tool hooks do not fire consistently for every tool, and `PreToolUse` cannot inject `additionalContext`. Codex does require explicit trust for hook commands because they execute outside its normal sandbox. That is a useful safety check, but not extra automation power.

For now, port simple enforcement, logging, and post-edit hooks. Do not assume a sophisticated Claude Code hook setup is drop-in compatible without testing each event and output field.

## Sessions and long-running work

TODO: Cover resume/fork, background work, goals, and how Codex sessions fit into a tmux workflow.

## My practical migration checklist

TODO: Add a short checklist for converting an existing `.claude` setup:

1. Configure automatic approval review.
2. Configure `/statusline`.
3. Recreate any MCP servers that are actually useful.
4. Test the repository's commands in the sandbox.

## Other practical differences

TODO: Finish with opinionated observations after using both tools on real projects: where Codex feels better, where Claude Code still feels smoother, and which differences are merely muscle memory.
