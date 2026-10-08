# Installory releases

## 1.6.0 (build 12) — in App Review

Status: merged to `main` (PR #5), versioned 1.6.0 (12), and submitted to App
Review (October 2026). The App Store serves 1.5 until it is approved.

Website: installory.app was rebuilt for 1.6 and deployed on 2026-10-07
(installory-website PR #2). Its copy already describes 1.6, so no website
change is needed at release unless the app's wording changes.

Do not upload a local unsigned or ad-hoc QA archive. Create a fresh distribution
archive from the merged, clean `main` branch.

### What's New (paste into App Store Connect)

Paste the text between the rules. 1,050 characters; the App Store limit
is 4,000.

---

Know what's on your Mac, and what your AI put there.

• Home checkup: four plain rows for installed tools, AI tools, API keys left in plain text, and space.
• AI Setup: your MCP servers across Claude Code, Claude Desktop, Cursor, VS Code, Codex and opencode, your CLAUDE.md, AGENTS.md and rules files, and agent permissions and hooks, with plain-English fixes.
• Finds API keys written in plain text in AI tool settings. Shows the key name and file, never the value.
• Ask your AI assistant: copy a ready-made prompt about a package, duplicate, cleanup or finding. Copy My Setup gives your assistant a summary of your tools.
• A new first-run guide that asks for your home folder (read only) and explains what Installory opens.
• Install History is much faster with large AI session histories.
• Safer cleanup scripts with a "How to run this" note.
• Fixes: tools in your home folder are now found correctly, Command-F focuses search, plus layout and VoiceOver fixes.

If you used Install History before, Installory may ask once for your home folder.

---

### App Review note (draft)

Installory is a read-only inventory app with no networking code of its own. It scans only folders
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

1. Done: version `1.6.0`, build `12` in `project.yml` and `App/Info.plist`
   (build numbers cannot be reused). Bundle identifier `app.installory.mac` and
   `ITSAppUsesNonExemptEncryption: false` unchanged. Run
   `./scripts/regenerate-xcode.sh` after pulling.
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
5. Upload the five 2880×1800 screenshots in `files/screenshots/app-store/`
   (rendered from sample data; the sample-data banner is visible). Pick the
   subtitle, promotional text and keywords from
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
release, and move this section under "Shipped". The website already describes
1.6. Change it only through the website repository's own reviewed deploy.
The homepage reproduces app text (checkup rows, AI Setup findings, the copied
prompt, cleanup script format) and the privacy policy lists every file the app
reads, so update the website whenever those change in the app.

### Known advisories

- **Check the home-folder fix in a signed, sandboxed build.** 1.5.0 built
  `~/.claude`, `~/.cargo`, `~/.nvm` and similar paths from the sandbox
  container instead of the real home folder, so those scanners likely found
  nothing for App Store users. This release resolves the real home folder
  (`UserHome`). Unit tests cover it, but the end-to-end path (grant the home
  folder in onboarding, then confirm Agent CLIs, Skills, Editor Extensions,
  Cargo, pipx and AI Setup populate) has only been exercised in unsigned
  local builds. Do this before submitting.
- **Upgraders with Install History on may be asked for the home folder once.**
  1.5.0 checked the home grant against the sandbox container, so a 1.5.0
  grant may not cover the real home folder. The stored toggle is left on;
  Settings → Privacy shows "Paused: Installory needs read access to your home
  folder" with a Grant button, and AI Installed / package details say access
  is needed, until the user allows the real home folder.
- **Scans take longer with a home grant.** The AI setup audit runs inside the
  scan, before install history, so the scanning indicator stays on while it
  reads AI tool settings. Fine for typical setups; revisit if reports say
  scans feel slow.
- **Command-F search focus: fixed, verify by hand.** 1.5.0 shipped with
  Command-F not focusing the SwiftUI search field. This release adds an
  Edit → Find Packages command (Command-F) that focuses the visible search
  field. Confirm it in the Release build on List, Table, and the other
  searchable screens before submitting.
- **App Store rating prompt.** The app now asks for a rating after a positive
  scan, at most once per version, never in sample-data mode or during
  onboarding, and only after a scan the user started (never the automatic
  launch scan) in which no package manager failed. This uses the system
  `requestReview` API, which may contact the App Store; Installory itself
  makes no network calls. This is why copy says "never sends your data
  anywhere" rather than "never connects to the internet".

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
