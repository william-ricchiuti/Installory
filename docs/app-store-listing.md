# App Store listing draft (next release, unreleased; proposed 1.6.0)

Draft for the owner to paste into App Store Connect. Nothing here is submitted.
Character counts are Unicode characters (what App Store Connect counts),
measured with Python `len()` on the exact text, without the trailing newline.

Rules followed: plain language; no metrics, ratings, user counts or
testimonials; the read-only, offline, no-commands promise is stated as fact
only where the code enforces it.

## App name (limit 30)

| Option | Chars |
|---|---|
| `Installory` (current, recommended) | 10 |
| `Installory: AI Coding Checkup` | 29 |

Changing the name is optional. If it changes, update the website and README
together.

## Subtitle (limit 30)

| Option | Chars |
|---|---|
| `Check your AI coding setup` (recommended) | 26 |
| `See what your AI tools changed` | 30 |
| `Safe checkup for AI coding` | 26 |
| `Dev tools and AI setup checkup` | 30 |

Words in the subtitle are searchable, so keep them out of the keywords field.

## Promotional text (limit 170)

Can be changed without a new build.

> See what your AI coding tools installed and changed, check your MCP servers, rules and permissions, and find what's safe to clean up. Read-only and offline.

Chars: 156

## Description (limit 4000)

Chars: 2,394

```
See what's on the Mac you code on with AI, what your AI tools installed and changed, and what's safe to clean up. Installory only reads. It never changes your Mac, never runs commands, and never connects to the internet.

A CHECKUP IN PLAIN ENGLISH
Home shows four rows: installed tools, AI tools, secrets in AI tool settings, and space. Each one says whether it looks good, needs a look, or hasn't been checked yet, and what to do next.

CHECK YOUR AI SETUP
• MCP servers set up in Claude Code, Claude Desktop, Cursor, VS Code, Codex and opencode, in one list.
• Spot servers that are set up differently in different places, whose program is missing, or that connect over the internet.
• Review CLAUDE.md, AGENTS.md and rules files your agents read in every conversation.
• See which permissions and hooks let an agent run commands without asking.
• Find API keys and passwords written in plain text in AI tool settings. Installory shows the key name and file, never the value.

SEE WHAT YOUR AI TOOLS INSTALLED
• Homebrew, pip, pipx, uv, npm, Cargo, RubyGems and Mac App Store apps in one searchable list.
• Agent skills, agent command-line tools, and VS Code and Cursor extensions.
• Optional Install History shows which tools you installed and which Claude Code, Codex or opencode installed. Off by default; everything is redacted and stays on your Mac.

CLEAN UP WITHOUT THE FEAR
• A clear verdict for every package: safe to remove, remove with care, or leave alone.
• Find duplicates, possibly unused packages, and the safe removals that free the most space.
• Cleanup is a script you read first and run yourself. Bulk cleanup saves a restore point first.

ASK YOUR AI ASSISTANT
Copy a ready-made prompt for Claude Code, Codex or any assistant about a package, a duplicate, a cleanup or a finding. Each prompt asks the assistant to explain every step and wait for your OK. "Copy My Setup" gives your assistant a short summary of your tools so its advice fits your Mac. Installory only copies text to your clipboard.

HOW IT STAYS SAFE
• Reads only the folders you allow, with read-only access.
• Never installs, removes or changes software, and never runs commands.
• No network access. Descriptions are built in.
• No account, no tracking. App Privacy: Data Not Collected.
• Try it first with sample data, no folder access needed.

Free and open source (MIT). Requires macOS 14 or later.
```

## Keywords (limit 100, comma-separated, no spaces)

Do not repeat words already in the app name or subtitle; Apple indexes those
separately.

| Option | Chars |
|---|---|
| A (recommended): `mcp,homebrew,brew,uninstall,cleanup,developer,agent,claude,codex,cursor,npm,pip,python,packages` | 95 |
| B (no other product names): `mcp,homebrew,brew,uninstall,cleanup,developer,agent,npm,pip,python,packages,disk,space,terminal` | 95 |

Option A includes other companies' product names (Claude, Codex, Cursor).
Apple's guidelines discourage using other apps' trademarked names in keywords,
and it can cause a rejection. Option B avoids that. The description already
names those tools, where accurate description is allowed. Owner decides.

## Screenshots (6)

Capture on the new Home and AI Setup screens; the current images in
`files/screenshots/` predate them. Use a realistic but non-personal home folder
(no real account name, project names or secrets visible; sample data or a test
account). Caption text is overlaid or used as the screenshot's headline.

| # | Screen | Caption | Chars |
|---|---|---|---|
| 1 | Home checkup with all four rows, at least one "worth a look" | `A safe checkup for the Mac you code on with AI` | 46 |
| 2 | AI Setup: MCP servers list across several apps, a finding expanded | `See every MCP server your AI tools use` | 38 |
| 3 | AI Setup: a plain-text secret finding with the value masked | `Find API keys left in plain text, safely masked` | 47 |
| 4 | Package detail with Install History showing an AI-installed tool and the Ask Your AI Assistant menu open | `See what your AI assistant installed` | 36 |
| 5 | Cleanup selection with verdict badges and the script sheet with "How to run this" | `Know what's safe to remove, then you decide` | 43 |
| 6 | Onboarding "Allow your home folder" page with the Reads / Never reads list | `Read-only, offline, and never runs commands` | 43 |
