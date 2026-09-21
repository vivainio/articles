---
icon: lucide/notebook-tabs
hide:
  - toc
---

# Ville's Field Notes

Practical notes from building software with modern tools.

This is where I write down things worth keeping: AI agents that change how I
work, terminal tools that earn a permanent keybinding, small programs that do
more than their size suggests, and infrastructure experiments that survived
contact with reality.

There is no fixed curriculum and no requirement that every article belong to
the same grand theme. The common thread is more personal: I tried something,
formed an opinion, and wanted to explain the useful part without padding it
into a conference talk.

AI is both a subject here and part of the writing process. These pieces are
written collaboratively with AI, while I choose what is worth covering, supply
the experience and opinions, check the claims, and decide what gets cut.

## Start here

<div class="field-note-grid" markdown>

[:lucide-bot: **AI & coding agents**  
How coding agents fit into real workflows, from Codex and Claude Code to the
terminal environments around them.](ai-agents/index.md)

[:lucide-terminal: **Terminal craft**  
Tools and configurations that make a terminal-centered working life more
comfortable.](terminal/index.md)

[:lucide-laptop: **Learning Mac**  
A practical guide to macOS for people whose hands still reach for the wrong
keys, starting with modifiers, shortcuts, and Spotlight.](learning-mac/index.md)

[:lucide-package-open: **Building & shipping**  
Small systems, packaging techniques, and practical ways to get software into
people's hands.](building/index.md)

[:lucide-cloud-cog: **Infrastructure experiments**  
Attempts to make cloud infrastructure smaller, clearer, and easier to
understand.](infrastructure/index.md)

</div>

## Latest notes

- [Everyday Shortcuts](learning-mac/everyday-shortcuts.md) —
  what Command and Option do, the shortcuts to learn first, and launching
  everything from Spotlight.
- [A Shared EC2 Dev Box for Coding Agents](ai-agents/shared-ec2-agent-server.md) —
  consolidating remote coding-agent work without sharing identities or active
  Git working trees.
- [Document Processing Pipeline with EventBridge Choreography](infrastructure/document-pipeline-eventbridge.md) —
  explicit service ownership, reliable event handoffs, and queryable progress.
- [Document Processing Pipeline with Lambda Durable Functions](infrastructure/document-pipeline-durable-functions.md) —
  checkpointed orchestration in code, with parallel OCR and human review.
- [Herdr Tutorial](terminal/herdr.md) — a terminal workspace manager with
  first-class awareness of coding agents.
- [What Cloudflare's Free Tier Gives Vibe Coders](building/cloudflare-free-tier.md) —
  what is actually available when shipping a small application.
- [Packaging Rust CLI Apps to PyPI](building/packaging-rust-to-pypi.md) —
  distributing a Rust binary with `pip install`, without Python bindings.
