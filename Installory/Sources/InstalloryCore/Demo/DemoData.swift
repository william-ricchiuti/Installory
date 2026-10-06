import Foundation

/// Pre-populated sample inventory used by Installory's demo mode.
///
/// Demo mode exists so the app can demonstrate its full feature set on a machine
/// that has no package managers installed (for example, a fresh review device).
/// Everything here is synthetic, lives only in memory, and never touches the
/// filesystem, the database, or the network. The data is deliberately shaped to
/// exercise every UI surface:
///
/// - packages across all twelve supported managers (`PackageManager.allCases`)
/// - explicit installs and pulled-in dependencies
/// - a read-only system package (Read-only sidebar filter)
/// - cross-manager duplicates (Duplicates view)
/// - a denylisted "common essential" (cautious removal warning)
/// - varied install dates and confidence levels
/// - sample snapshots (Snapshots sidebar + restore flow)
///
/// Kept in `InstalloryCore` (not the app target) so it is covered by the library
/// test suite and stays UI-free.
public enum DemoData {

    /// A stable reference "now" so demo dates render sensibly relative to the
    /// moment demo mode is entered.
    private static var now: Date { Date() }

    private static func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
    }

    private static func id(_ manager: PackageManager, _ qualifier: String?, _ name: String) -> String {
        "\(manager.rawValue):\(qualifier ?? ""):\(name)"
    }

    // Representative interpreter / scope qualifiers for the demo.
    private static let brewPython = "/opt/homebrew/opt/python@3.12/bin/python3.12"
    private static let pyenvPython = "/Users/demo/.pyenv/versions/3.11.7/bin/python"
    private static let systemPython = "/usr/bin/python3"
    private static let gemSpecs = "/Users/demo/.rbenv/versions/3.2.2/lib/ruby/gems/3.2.0/specifications"

    /// The full sample package inventory.
    public static func packages() -> [Package] {
        var result: [Package] = []

        func pkg(
            _ manager: PackageManager,
            _ name: String,
            version: String,
            qualifier: String? = nil,
            path: String? = nil,
            installedDaysAgo: Int?,
            confidence: Confidence = .high,
            size: Int64? = nil,
            explicit: Bool = true,
            readOnly: Bool = false,
            deps: [String] = [],
            artifacts: [String]? = nil
        ) {
            result.append(
                Package(
                    id: id(manager, qualifier, name),
                    manager: manager,
                    qualifier: qualifier,
                    name: name,
                    version: version,
                    installPath: path.map { URL(fileURLWithPath: $0) },
                    installedAt: installedDaysAgo.map { daysAgo($0) },
                    installedAtConfidence: confidence,
                    sizeBytes: size,
                    isExplicit: explicit,
                    isReadOnly: readOnly,
                    dependencies: deps,
                    artifactPaths: artifacts,
                    lastSeen: now
                )
            )
        }

        // MARK: Homebrew formulae
        pkg(.brew, "ffmpeg", version: "6.1.1", path: "/opt/homebrew/Cellar/ffmpeg/6.1.1",
            installedDaysAgo: 21, size: 223_000_000,
            deps: ["aom", "dav1d", "lame", "x264"])
        pkg(.brew, "wget", version: "1.24.5", path: "/opt/homebrew/Cellar/wget/1.24.5",
            installedDaysAgo: 96, size: 4_100_000)
        pkg(.brew, "ripgrep", version: "14.1.0", path: "/opt/homebrew/Cellar/ripgrep/14.1.0",
            installedDaysAgo: 12, size: 5_400_000)
        pkg(.brew, "cmake", version: "3.29.3", path: "/opt/homebrew/Cellar/cmake/3.29.3",
            installedDaysAgo: 60, size: 78_000_000)
        pkg(.brew, "openssl@3", version: "3.3.0", path: "/opt/homebrew/Cellar/openssl@3/3.3.0",
            installedDaysAgo: 96, confidence: .medium, size: 60_000_000,
            explicit: false, deps: ["ca-certificates"])
        pkg(.brew, "aom", version: "3.9.0", path: "/opt/homebrew/Cellar/aom/3.9.0",
            installedDaysAgo: 21, confidence: .medium, size: 12_000_000, explicit: false)

        // MARK: Homebrew casks
        pkg(.brewCask, "visual-studio-code", version: "1.89.1",
            path: "/Applications/Visual Studio Code.app",
            installedDaysAgo: 140, size: 380_000_000)
        pkg(.brewCask, "rectangle", version: "0.84",
            path: "/Applications/Rectangle.app",
            installedDaysAgo: 200, size: 14_000_000)

        // MARK: pip (Homebrew Python interpreter)
        pkg(.pip, "requests", version: "2.31.0", qualifier: brewPython,
            path: "/opt/homebrew/lib/python3.12/site-packages/requests",
            installedDaysAgo: 18, size: 480_000)
        pkg(.pip, "numpy", version: "1.26.4", qualifier: brewPython,
            path: "/opt/homebrew/lib/python3.12/site-packages/numpy",
            installedDaysAgo: 18, size: 38_000_000)
        pkg(.pip, "black", version: "24.4.2", qualifier: pyenvPython,
            path: "/Users/demo/.pyenv/versions/3.11.7/lib/python3.11/site-packages/black",
            installedDaysAgo: 33, confidence: .low, size: 1_300_000)

        // MARK: pip (system Python — read-only)
        pkg(.pip, "setuptools", version: "58.0.4", qualifier: systemPython,
            path: "/usr/lib/python3/site-packages/setuptools",
            installedDaysAgo: nil, confidence: .unknown,
            explicit: false, readOnly: true)

        // MARK: pipx
        pkg(.pipx, "black", version: "24.4.2", path: "/Users/demo/.local/pipx/venvs/black",
            installedDaysAgo: 9, size: 9_800_000)
        pkg(.pipx, "poetry", version: "1.8.3", path: "/Users/demo/.local/pipx/venvs/poetry",
            installedDaysAgo: 75, size: 22_000_000)
        pkg(.pipx, "httpie", version: "3.2.2", path: "/Users/demo/.local/pipx/venvs/httpie",
            installedDaysAgo: 4, size: 6_500_000)

        // MARK: uv persistent tools
        let uvRuffEnvironment = "/Users/demo/.local/share/uv/tools/ruff"
        pkg(.uv, "ruff", version: "0.6.9", qualifier: uvRuffEnvironment,
            path: uvRuffEnvironment, installedDaysAgo: 7, size: 31_000_000,
            deps: ["click"], artifacts: ["/Users/demo/.local/bin/ruff"])

        // MARK: npm (global)
        pkg(.npm, "typescript", version: "5.4.5", path: "/opt/homebrew/lib/node_modules/typescript",
            installedDaysAgo: 14, size: 22_000_000)
        pkg(.npm, "eslint", version: "9.2.0", path: "/opt/homebrew/lib/node_modules/eslint",
            installedDaysAgo: 14, confidence: .medium, size: 8_900_000)
        pkg(.npm, "prettier", version: "3.2.5", path: "/opt/homebrew/lib/node_modules/prettier",
            installedDaysAgo: 3, size: 7_200_000)

        // MARK: Cargo
        pkg(.cargo, "ripgrep", version: "14.1.0", path: "/Users/demo/.cargo/bin/rg",
            installedDaysAgo: 50, size: 4_800_000)
        pkg(.cargo, "bat", version: "0.24.0", path: "/Users/demo/.cargo/bin/bat",
            installedDaysAgo: 50, size: 6_100_000)
        pkg(.cargo, "eza", version: "0.18.13", path: "/Users/demo/.cargo/bin/eza",
            installedDaysAgo: 6, confidence: .low, size: 3_200_000)

        // MARK: RubyGems
        pkg(.gem, "bundler", version: "2.5.9", qualifier: gemSpecs,
            path: "/Users/demo/.rbenv/versions/3.2.2/lib/ruby/gems/3.2.0/gems/bundler-2.5.9",
            installedDaysAgo: 120, size: 1_900_000)
        pkg(.gem, "rails", version: "7.1.3", qualifier: gemSpecs,
            path: "/Users/demo/.rbenv/versions/3.2.2/lib/ruby/gems/3.2.0/gems/rails-7.1.3",
            installedDaysAgo: 88, size: 14_000_000)

        // MARK: Mac App Store
        pkg(.mas, "Xcode", version: "15.4", qualifier: "com.apple.dt.Xcode",
            path: "/Applications/Xcode.app",
            installedDaysAgo: 240, size: 7_400_000_000)
        pkg(.mas, "Things 3", version: "3.20.1", qualifier: "com.culturedcode.ThingsMac",
            path: "/Applications/Things3.app",
            installedDaysAgo: 310, size: 96_000_000)

        // MARK: Demo: spec 01/02 — cross-manager duplicates with PATH resolution & severity

        // Active conflict: brew node wins PATH, cargo node is shadowed.
        // (Assumes /opt/homebrew/bin precedes ~/.cargo/bin on PATH, which is typical.)
        pkg(.brew, "node", version: "20.0.0",
            path: "/opt/homebrew/Cellar/node/20.0.0",
            installedDaysAgo: 30, size: 84_000_000)
        pkg(.cargo, "node", version: "20.1.0",
            path: "/Users/demo/.cargo/bin/node",
            installedDaysAgo: 14, confidence: .low, size: 2_100_000)

        // Potential conflict: brew and pipx install a "python" tool under different managers.
        pkg(.brew, "python", version: "3.12.3",
            path: "/opt/homebrew/Cellar/python@3.12/3.12.3",
            installedDaysAgo: 60, size: 72_000_000)
        pkg(.pipx, "python", version: "3.11.7",
            path: "/Users/demo/.local/pipx/venvs/python",
            installedDaysAgo: 90, confidence: .medium, size: 8_000_000)

        // Benign: pip library vs Mac App Store app — same lowercased name, no real CLI conflict.
        pkg(.pip, "stripe", version: "9.0.0", qualifier: brewPython,
            path: "/opt/homebrew/lib/python3.12/site-packages/stripe",
            installedDaysAgo: 20, size: 3_500_000)
        pkg(.mas, "Stripe", version: "4.1.0", qualifier: "com.stripe.stripe-macos",
            path: "/Applications/Stripe.app",
            installedDaysAgo: 120, size: 48_000_000)

        // MARK: Demo: spec 03 — multi-location (same pip package, two interpreters)

        // Combined with the existing brewPython "requests" above, this forms a
        // two-qualifier multi-location group under the pip manager.
        pkg(.pip, "requests", version: "2.28.0", qualifier: pyenvPython,
            path: "/Users/demo/.pyenv/versions/3.11.7/lib/python3.11/site-packages/requests",
            installedDaysAgo: 40, size: 470_000)

        // MARK: Demo: spec 04 — orphan analysis

        // demo-lib is explicit but demo-app depends on it → NOT an orphan.
        // demo-app is explicit with no dependents → IS an orphan (good review candidate).
        pkg(.brew, "demo-lib", version: "1.0.0",
            path: "/opt/homebrew/Cellar/demo-lib/1.0.0",
            installedDaysAgo: 200, size: 8_000_000, explicit: true)
        pkg(.brew, "demo-app", version: "2.3.1",
            path: "/opt/homebrew/Cellar/demo-app/2.3.1",
            installedDaysAgo: 180, size: 25_000_000, explicit: true,
            deps: ["demo-lib"])

        // MARK: Demo: spec 05 — cleanup signal unknown bucket

        // nil size AND nil date → .unknown bucket in cleanup scoring.
        pkg(.cargo, "legacy-tool", version: "0.1.0",
            installedDaysAgo: nil, confidence: .unknown,
            size: nil, explicit: true)

        // MARK: Demo: spec 06 — agent skills

        let claudeSkills = "/Users/demo/.claude/skills"
        let agentsSkills = "/Users/demo/.agents/skills"
        let opencodeSkills = "/Users/demo/.config/opencode/skills"

        // Healthy skill with a versioned SKILL.md manifest.
        pkg(.agentSkill, "app-design", version: "2.1.0", qualifier: claudeSkills,
            path: "\(claudeSkills)/app-design",
            installedDaysAgo: 30, size: 120_000)
        // Healthy skill whose SKILL.md has no version field → version "".
        pkg(.agentSkill, "git-workflow", version: "", qualifier: agentsSkills,
            path: "\(agentsSkills)/git-workflow",
            installedDaysAgo: 60, size: 80_000)

        // Cross-tool duplicate: same skill name installed in two roots.
        pkg(.agentSkill, "frontend-polish", version: "1.0.0", qualifier: claudeSkills,
            path: "\(claudeSkills)/frontend-polish",
            installedDaysAgo: 20, size: 200_000)
        pkg(.agentSkill, "frontend-polish", version: "1.0.0", qualifier: opencodeSkills,
            path: "\(opencodeSkills)/frontend-polish",
            installedDaysAgo: 20, size: 200_000)

        // Broken symlink: installPath nil + artifactPaths = [target string].
        pkg(.agentSkill, "deprecated-skill", version: "", qualifier: claudeSkills,
            installedDaysAgo: 90, confidence: .medium,
            size: nil, artifacts: ["/Users/demo/skills-src/deprecated-skill"])

        // Missing SKILL.md: installPath nil + artifactPaths nil.
        pkg(.agentSkill, "half-baked-skill", version: "", qualifier: agentsSkills,
            installedDaysAgo: 45, confidence: .medium,
            size: nil)

        // MARK: Demo: spec 07 — agent CLIs and editor extensions

        // One row per discovered agent CLI config root.
        pkg(.agentCli, "claude", version: "", qualifier: "/Users/demo/.claude",
            path: "/Users/demo/.claude",
            installedDaysAgo: 120, size: 4_000_000)
        pkg(.agentCli, "codex", version: "0.42.0", qualifier: "/Users/demo/.codex",
            path: "/Users/demo/.codex",
            installedDaysAgo: 90, size: 1_500_000)
        pkg(.agentCli, "opencode", version: "", qualifier: "/Users/demo/.config/opencode",
            path: "/Users/demo/.config/opencode",
            installedDaysAgo: 60, size: 800_000)
        pkg(.agentCli, "cursor", version: "", qualifier: "/Users/demo/.cursor",
            path: "/Users/demo/.cursor",
            installedDaysAgo: 40, size: 2_000_000)

        // Editor extensions, grouped by their extensions root qualifier.
        pkg(.editorExtension, "esbenp.prettier-vscode", version: "10.1.0",
            qualifier: "/Users/demo/.vscode/extensions",
            path: "/Users/demo/.vscode/extensions/esbenp.prettier-vscode-10.1.0",
            installedDaysAgo: 70, size: 15_000_000)
        pkg(.editorExtension, "ms-python.python", version: "2024.4.1",
            qualifier: "/Users/demo/.vscode/extensions",
            path: "/Users/demo/.vscode/extensions/ms-python.python-2024.4.1",
            installedDaysAgo: 55, size: 60_000_000)
        pkg(.editorExtension, "cursor.python", version: "1.0.3",
            qualifier: "/Users/demo/.cursor/extensions",
            path: "/Users/demo/.cursor/extensions/cursor.python-1.0.3",
            installedDaysAgo: 35, size: 12_000_000)

        return result
    }

    /// Builds an in-memory snapshot payload from `Package` values.
    ///
    /// Public so the app target (which cannot use `SnapshotPackage`'s internal
    /// memberwise initializer) can build demo-mode snapshots without persisting
    /// anything to the database.
    public static func snapshotPayload(from packages: [Package]) -> SnapshotPayload {
        var managers: [PackageManager: [SnapshotPackage]] = [:]
        for p in packages {
            managers[p.manager, default: []].append(
                SnapshotPackage(
                    name: p.name,
                    version: p.version,
                    qualifier: p.qualifier,
                    isExplicit: p.isExplicit
                )
            )
        }
        return SnapshotPayload(managers: managers)
    }

    /// Creates a fresh in-memory snapshot (new id, current timestamp) from the
    /// given packages. Used by demo mode's "Snapshot Now" and pre-cleanup flows.
    public static func makeSnapshot(
        reason: SnapshotReason,
        from packages: [Package],
        note: String? = nil
    ) -> Snapshot {
        Snapshot(
            id: UUID(),
            createdAt: Date(),
            reason: reason,
            note: note,
            payload: snapshotPayload(from: packages)
        )
    }

    /// Sample provenance evidence for demo mode.
    ///
    /// Four packages are covered:
    /// - `brew::ffmpeg`: attributed to a Claude Code session (ClaudeCodeContext).
    /// - `brew::wget`: attributed to a Codex session (CodexContext).
    /// - `brew::ripgrep`: attributed to an opencode session (OpenCodeContext).
    /// - `pip:<brewPython>:requests`: attributed to a shell history command only.
    ///
    /// Keyed by the same package IDs produced by `packages()` so `PackageDetailView` can
    /// look up evidence by `package.id` without any filesystem access.
    public static func demoProvenanceByPackageId() -> [String: ProvenanceEvidence] {
        let now = Date()
        func daysAgo(_ n: Int) -> Date {
            Calendar.current.date(byAdding: .day, value: -n, to: now) ?? now
        }

        let ffmpegId   = id(.brew, nil, "ffmpeg")
        let aomId      = id(.brew, nil, "aom")
        let wgetId     = id(.brew, nil, "wget")
        let requestsId = id(.pip, brewPython, "requests")
        let numpyId    = id(.pip, brewPython, "numpy")
        let ripgrepId  = id(.brew, nil, "ripgrep")

        // ffmpeg — installed by Claude Code (primary demo for spec 09 AI-session tagging).
        let ffmpegEvidence = ProvenanceEvidence(
            packageId: ffmpegId,
            fsInstallTime: daysAgo(21),
            fsInstallTimeSource: "INSTALL_RECEIPT.json",
            installCommand: nil,
            claudeCodeContext: ProvenanceEvidence.ClaudeCodeContext(
                sessionId: "demo-session-abc123",
                projectPath: "/Users/demo/Projects/my-app",
                sessionSummary: "Setting up a video processing pipeline",
                firstUserMessage: "I need to add video transcoding to my app",
                bashInvocation: "brew install ffmpeg",
                timestamp: daysAgo(21)
            ),
            nearbyProjects: [],
            coInstalledWithin1h: [aomId],
            overallConfidence: .high,
            collectedAt: now
        )

        // requests — installed via shell history, no Claude Code context.
        let requestsEvidence = ProvenanceEvidence(
            packageId: requestsId,
            fsInstallTime: daysAgo(18),
            fsInstallTimeSource: "dist-info mtime",
            installCommand: ProvenanceEvidence.InstallCommandRecord(
                timestamp: daysAgo(18),
                command: "pip install requests",
                shell: .zsh,
                cwd: "/Users/demo/Projects/data-fetcher"
            ),
            claudeCodeContext: nil,
            nearbyProjects: [],
            coInstalledWithin1h: [numpyId],
            overallConfidence: .high,
            collectedAt: now
        )

        // wget — installed by Codex (multi-agent demo: spec 11 generalized AI attribution).
        let wgetEvidence = ProvenanceEvidence(
            packageId: wgetId,
            fsInstallTime: daysAgo(14),
            fsInstallTimeSource: "INSTALL_RECEIPT.json",
            installCommand: nil,
            claudeCodeContext: nil,
            codexContext: ProvenanceEvidence.CodexContext(
                sessionId: "demo-codex-session-xyz",
                projectPath: "/Users/demo/Projects/website-tools",
                sessionSummary: nil,
                firstUserMessage: nil,
                bashInvocation: "brew install wget",
                timestamp: daysAgo(14)
            ),
            nearbyProjects: [],
            coInstalledWithin1h: [],
            overallConfidence: .high,
            collectedAt: now
        )

        // ripgrep — installed by opencode (multi-agent demo: spec 11 generalized AI attribution).
        let ripgrepEvidence = ProvenanceEvidence(
            packageId: ripgrepId,
            fsInstallTime: daysAgo(9),
            fsInstallTimeSource: "INSTALL_RECEIPT.json",
            installCommand: nil,
            claudeCodeContext: nil,
            codexContext: nil,
            opencodeContext: ProvenanceEvidence.OpenCodeContext(
                sessionId: "demo-opencode-session-456",
                projectPath: "/Users/demo/Projects/cli-tool",
                sessionSummary: "Add ripgrep for fast search",
                firstUserMessage: nil,
                bashInvocation: "brew install ripgrep",
                timestamp: daysAgo(9)
            ),
            nearbyProjects: [],
            coInstalledWithin1h: [],
            overallConfidence: .high,
            collectedAt: now
        )

        return [
            ffmpegId:   ffmpegEvidence,
            wgetId:     wgetEvidence,
            ripgrepId:  ripgrepEvidence,
            requestsId: requestsEvidence,
        ]
    }

    /// Sample snapshots so the Snapshots sidebar section and restore flow are
    /// demonstrable. Snapshot payloads reference the full demo inventory.
    ///
    /// The 7-day snapshot is intentionally divergent from the live inventory so
    /// `snapshotChanges()` has all three categories to display in the Changes tab:
    /// - **Added:** prettier, httpie, eza (not in the snapshot)
    /// - **Removed:** jq (in the snapshot, gone from live)
    /// - **Version-changed:** ffmpeg 6.0.0 → 6.1.1
    public static func snapshots() -> [Snapshot] {
        let all = packages()

        let sevenDayPayload: SnapshotPayload = {
            let omitNames: Set<String> = ["prettier", "httpie", "eza"]
            var managers: [PackageManager: [SnapshotPackage]] = [:]
            for p in all {
                guard !omitNames.contains(p.name) else { continue }
                let version = (p.name == "ffmpeg" && p.manager == .brew) ? "6.0.0" : p.version
                managers[p.manager, default: []].append(
                    SnapshotPackage(name: p.name, version: version, qualifier: p.qualifier, isExplicit: p.isExplicit)
                )
            }
            // jq was installed 7 days ago and has since been removed
            managers[.brew, default: []].append(
                SnapshotPackage(name: "jq", version: "1.7.0", qualifier: nil, isExplicit: true)
            )
            return SnapshotPayload(managers: managers)
        }()

        return [
            Snapshot(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                createdAt: daysAgo(7),
                reason: .autoFirstScan,
                note: nil,
                payload: sevenDayPayload
            ),
            Snapshot(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                createdAt: daysAgo(2),
                reason: .manual,
                note: "Before trying a cleanup",
                payload: snapshotPayload(from: all)
            ),
        ]
    }
}
