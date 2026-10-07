# App Store listing (1.6.0)

Final text for App Store Connect, chosen by the owner on 2026-10-07. Character
counts are what App Store Connect counts (Python `len()` on the exact text).

## Name (limit 30)

`Installory` (10). Unchanged.

## Subtitle (limit 30)

`Check your AI coding setup` (26)

Subtitle words are indexed, so they are not repeated in the keywords.

## Promotional text (limit 170)

Can be changed at any time without a new build. 160 characters.

```
Know what's on your Mac, and what your AI put there. Check your MCP servers, agent rules and permissions, find API keys left in plain text, and clean up safely.
```

## Description (limit 4000)

2,287 characters. Only the first three lines show before "more", so they
carry the pitch.

```
Know what's on your Mac, and what your AI put there.

Installory shows what your AI coding tools installed, checks their settings for problems, and tells you what's safe to clean up. It only looks. It never changes anything.

A CHECKUP IN PLAIN ENGLISH
Home sums up your Mac in four rows: installed tools, AI tools, API keys left in plain text, and space. Each row says whether it looks good or is worth a look, and what to do next.

CHECK YOUR AI SETUP
• MCP servers from Claude Code, Claude Desktop, Cursor, VS Code, Codex and opencode, in one list. See which ones are set up differently in two places, are missing their program, or connect over the internet.
• Instruction files your agents read in every conversation, like CLAUDE.md and AGENTS.md, including AGENTS.md files Claude Code won't read.
• Permissions and hooks that let an agent run commands without asking you.
• API keys and passwords written into AI tool settings. You see the key name and file, never the value.

SEE WHAT YOUR AI INSTALLED
• Homebrew, pip, pipx, uv, npm, Cargo, RubyGems, Mac App Store apps, agent skills, AI command-line tools, and VS Code and Cursor extensions in one searchable list, each with a plain-English description.
• Optional Install History matches tools to the terminal command or AI session that installed them. Off until you turn it on, and it stays on your Mac.

CLEAN UP WITHOUT THE FEAR
• Every package is marked safe to remove, remove with care, or leave alone.
• Find duplicates, tools you may not use, and the removals that free the most space.
• You get a plain script with a "How to run this" note. Read it, and run it only if you want to. A bigger cleanup saves a restore point first.

ASK YOUR AI ASSISTANT
Copy a ready-made prompt for Claude Code, Codex or any assistant about a package, a duplicate or a finding. Every prompt asks the assistant to explain each step and wait for your OK. Copy My Setup gives your assistant a short summary of your tools.

HOW IT STAYS SAFE
• Reads only the folders you allow, with read-only access.
• Never installs, removes or changes software, and never runs commands.
• No internet code of its own, no account, no tracking.
• Try it first with sample data, no folder access needed.

Free and open source (MIT). Requires macOS 14 or later.
```

## Keywords (limit 100)

`mcp,homebrew,brew,uninstall,cleanup,developer,agent,npm,pip,python,packages,disk,space,terminal` (95)

No other companies' product names (Claude, Codex, Cursor): Apple discourages
trademarks in keywords and it can cause a rejection. The description names
those tools where it describes what the app reads, which is allowed.

## What's New in 1.6.0

Same text as in [RELEASE.md](../RELEASE.md). 1,050 characters.

## Categories

- Primary: Developer Tools.
- Secondary: Utilities.

## Accessibility labels

Declare **Dark Interface** and **Reduced Motion**, which the app supports today.
Declare VoiceOver only after a full VoiceOver pass of the common tasks
(labels exist and the AI Setup accessibility crash is fixed, but no end-to-end
VoiceOver test has been done).

## Screenshots (2880×1800, in this order)

Files are in `files/screenshots/app-store/`, rendered from sample data.

| Order | File | Caption |
|---|---|---|
| 1 | `1-home.png` | Know what's on your Mac, and what your AI put there |
| 2 | `3-ai-setup-top.png` | Find API keys left in plain text, safely masked |
| 3 | `2-ai-setup-mcp.png` | See every MCP server your AI tools use |
| 4 | `4-detail.png` | See what your AI assistant installed |
| 5 | `5-safe-remove.png` | Know what's safe to remove, then you decide |

The sample-data banner is visible in some screenshots; App Review generally
accepts sample data.
