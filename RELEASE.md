# Installory releases

## Next release (unreleased; proposed 1.6.0)

Status: in development on `claude/installory-audit-features-33686e`. Not
submitted. The version and build number in `project.yml` are still `1.5.0` /
`11`; bumping them is an owner step (see the checklist).

Do not upload a local unsigned or ad-hoc QA archive. Create a fresh distribution
archive from the merged, clean `main` branch.

### What's New (draft for App Store Connect)

Paste the text between the rules. 1,809 characters; the App Store limit
is 4,000.

---

Installory is now a read-only checkup for a Mac you code on with AI.

• New Home checkup: four plain rows for installed tools, AI tools, secrets in AI tool settings, and space. Each says whether it looks good, needs a look, or hasn't been checked yet.
• New AI Setup screen: see the MCP servers set up in Claude Code, Claude Desktop, Cursor, VS Code, Codex and opencode, plus your CLAUDE.md, AGENTS.md and rules files, and your agent permissions and hooks. Each finding explains the problem in plain English and suggests a fix.
• Finds API keys and passwords written in plain text in AI tool settings. Installory shows only the key name and file, never the value.
• Ask your AI assistant: copy a ready-made prompt for Claude Code, Codex or any assistant about a package, a duplicate, a cleanup, or a finding. Prompts ask the assistant to explain each step and wait for your OK.
• Copy My Setup for My AI Assistant: give your assistant a short summary of your tools so its advice fits your Mac.
• New first-run guide that explains which folders Installory opens and which it doesn't, and asks for your home folder (read only).
• Install History (formerly provenance) shows which tools you installed and which Claude Code, Codex or opencode installed. Still optional and off by default.
• Clearer names: Possibly Unused, Saved Setup, Size on disk, and "Runs first" / "Hidden by another copy" for duplicates.
• Safer cleanup scripts: commands run in a subshell so they can't change your Terminal session, and each script explains how to run it.
• Fixes: tools in your home folder are found correctly in the sandbox, Command-F focuses search, and several layout and VoiceOver fixes.

Installory still only reads. It never changes your Mac, never runs commands, and never connects to the internet.

---

### App Review note (draft)

Installory is a fully offline, read-only inventory app. It scans only folders
explicitly granted by the user through read-only security-scoped bookmarks. It
never executes generated cleanup or reinstall scripts. The user-selected
read-write entitlement is used only when the user explicitly chooses an export
or generated-script destination through a Save panel. The app contains no
networking code and runs no subprocesses.

New in this version: the AI Setup check reads configuration files of AI coding
tools (for example `~/.claude.json`, `~/.claude/settings.json`,
`~/.codex/config.toml`, `~/.cursor/mcp.json`, and project `.mcp.json` and
`CLAUDE.md` / `AGENTS.md` files), only inside folders the user has granted.
From `~/.claude.json` it keeps only the MCP server entries; it never keeps or
displays sign-in or account data from that file. Secret-looking values (API
keys, tokens, passwords) are masked as soon as a file is read and are never
stored, exported, or included in copied text. Nothing is transmitted.

"Ask your AI assistant" and "Copy My Setup" only place text on the clipboard
for the user to paste. Installory does not contact any AI service.

Install history is off by default and requires the home-folder grant. When
enabled, it reads shell history and local agent-session logs (Claude Code,
Codex, and opencode) on-device, and every record is redacted before it is
stored.

Project-workspace scanning walks only folders the user has explicitly granted
read-only access to and never modifies them.

Reviewers can choose "Explore with Sample Data" during onboarding to evaluate
the app without granting filesystem access.

### Release checklist

1. Owner step: choose the version (proposed `1.6.0`) and bump
   `CFBundleShortVersionString` and `CFBundleVersion` in `project.yml`. The
   build number must be greater than `11`; build numbers cannot be reused.
   Confirm bundle identifier `app.installory.mac` and
   `ITSAppUsesNonExemptEncryption: false`, then regenerate the Xcode project.
2. Refresh the description corpus from fresh API responses using its
   [runbook](scripts/generate-descriptions/README.md). If it changes, rerun every
   verification gate.
3. Run the Core and app commands in [README.md](README.md), the description-tool
   tests, `scripts/check-invariants.sh`, and an unsigned Release build. Require a
   clean worktree and green pull-request CI before merging to `main`.
4. Hands-on check of the new surfaces with a real home-folder grant in a signed,
   sandboxed build: onboarding, Home checkup, AI Setup findings (including a
   masked secret), every "Copy Prompt" menu item, Copy My Setup, and the
   "How to run this" section of a cleanup script. Check Command-F (see Known
   advisories).
5. Replace the screenshots in `files/screenshots/` and the App Store listing
   images; the current ones predate the new Home. Listing text drafts are in
   [docs/app-store-listing.md](docs/app-store-listing.md).
6. From updated `main`, select the owner Apple Developer Team with managed
   distribution signing. Do not commit a personal team identifier.
7. Select Any Mac / Generic Mac, choose Product → Archive, and confirm version,
   build, bundle identifier, `arm64` and `x86_64`, sandbox entitlements,
   `PrivacyInfo.xcprivacy`, `ThirdPartyNotices.txt`, the icon, and
   `descriptions.json` in Organizer.
8. Run Validate App, then choose Distribute App → App Store Connect → Upload.
   Resolve any signing or App Store Connect validation finding before upload.
9. In App Store Connect, create the new macOS version, attach the new build,
   paste the What's New and review note above, keep App Privacy at
   **Data Not Collected**, and answer export compliance consistently with the
   Info property-list declaration.
10. Owner step: submit for review and choose the intended manual or automatic
    release mode.

After release, tag the shipped commit, publish the same notes in the GitHub
release, move this section under "Shipped", and update the separate website
repository only through its own reviewed deploy.

### Known advisories

- **Check the home-folder fix in a signed, sandboxed build.** 1.5.0 built
  `~/.claude`, `~/.cargo`, `~/.nvm` and similar paths from the sandbox
  container instead of the real home folder, so those scanners likely found
  nothing for App Store users. This release resolves the real home folder
  (`UserHome`). Unit tests cover it, but the end-to-end path (grant the home
  folder in onboarding, then confirm Agent CLIs, Skills, Editor Extensions,
  Cargo, pipx and AI Setup populate) has only been exercised in unsigned
  local builds. Do this before submitting.
- **Scans take longer with a home grant.** The AI setup audit runs inside the
  scan, before install history, so the scanning indicator stays on while it
  reads AI tool settings. Fine for typical setups; revisit if reports say
  scans feel slow.
- **Command-F search focus: fixed, verify by hand.** 1.5.0 shipped with
  Command-F not focusing the SwiftUI search field. This release adds an
  Edit → Find Packages command (Command-F) that focuses the visible search
  field. Confirm it in the Release build on List, Table, and the other
  searchable screens before submitting.
- **Screenshots are out of date.** `files/screenshots/` and the store images
  show the 1.5.0 Home.
- **App Store rating prompt.** The app now asks for a rating after a positive
  scan, at most once per version, never in sample-data mode or during
  onboarding. This uses the system `requestReview` API; Installory itself
  makes no network calls.

## Shipped: 1.5.0 (build 11, Aug 2026)

1.5.0 mapped the AI agent setup and added cleanup with less risk:

- Home dashboard with packages tracked, measured payload, safe to free up, AI
  installs this week, review candidates, duplicates, and broken skills.
- Removal-safety verdicts per package from reverse-dependency and orphan
  analysis.
- Restore points before bulk cleanup with a restore script, and Move-to-Trash
  for file-backed items.
- Free-up-space bundle and stale project workspaces from granted folders.
- Inventory of agent skills, agent CLIs (Claude Code, Codex, opencode, Cursor),
  and VS Code and Cursor extensions.
- Provenance from Claude Code, Codex, and opencode session records.
- Reverse-dependency tree, hide/pin/annotate, baseline compare with change
  detection and reinstall scripts, and plain-English descriptions for every
  package.

Known advisory at ship time: Command-F did not focus the search field
(addressed in the next release).
