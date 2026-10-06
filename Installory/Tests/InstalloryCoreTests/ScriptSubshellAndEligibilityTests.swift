import Foundation
import Testing
@testable import InstalloryCore

private func package(
    _ manager: PackageManager,
    _ name: String,
    qualifier: String? = nil,
    installPath: String? = nil,
    artifactPaths: [String]? = nil,
    isReadOnly: Bool = false
) -> Package {
    Package(
        id: "\(manager.rawValue):\(qualifier ?? ""):\(name)",
        manager: manager,
        qualifier: qualifier,
        name: name,
        version: "1.0.0",
        installPath: installPath.map { URL(fileURLWithPath: $0) },
        installedAt: nil,
        installedAtConfidence: .unknown,
        sizeBytes: nil,
        isExplicit: true,
        isReadOnly: isReadOnly,
        dependencies: [],
        artifactPaths: artifactPaths,
        lastSeen: Date(timeIntervalSince1970: 1_710_000_000)
    )
}

private func scriptLines(_ text: String) -> [String] {
    text.components(separatedBy: "\n")
}

/// Asserts the F4 shape: header comments at top level, then exactly one
/// `( … )` subshell whose first line enables strict mode, and nothing
/// executable outside it.
private func expectSubshellShape(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(text.hasPrefix("#!/usr/bin/env bash\n"), sourceLocation: sourceLocation)
    #expect(text.hasSuffix(")\n"), sourceLocation: sourceLocation)
    let lines = scriptLines(text).dropLast() // trailing "" after final newline
    guard let open = lines.firstIndex(of: "(") else {
        Issue.record("no subshell opener", sourceLocation: sourceLocation)
        return
    }
    // Everything before the opener is a comment.
    for line in lines[..<open] {
        #expect(line.hasPrefix("#"), "executable line outside subshell: \(line)", sourceLocation: sourceLocation)
    }
    #expect(lines[open + 1] == "set -euo pipefail", sourceLocation: sourceLocation)
    #expect(lines.last == ")", sourceLocation: sourceLocation)
    // Strict mode appears exactly once, inside the subshell.
    #expect(lines.filter { $0 == "set -euo pipefail" }.count == 1, sourceLocation: sourceLocation)
    #expect(lines.filter { $0 == "(" }.count == 1, sourceLocation: sourceLocation)
}

@Suite("Generated scripts are paste-safe (subshell)")
struct ScriptSubshellTests {
    @Test("Empty cleanup script is header plus an empty strict subshell")
    func emptyCleanupScript() {
        let text = ScriptGenerator().generate(packages: []).scriptText
        expectSubshellShape(text)
        #expect(text.contains("strict mode (set -euo pipefail)"))
    }

    @Test("Cleanup commands, snapshot header and denylist section stay in their places")
    func cleanupScriptShape() {
        let snapshot = SnapshotContext(id: UUID(), createdAt: Date(timeIntervalSince1970: 1_710_000_000))
        let text = ScriptGenerator().generate(
            packages: [package(.brew, "jq"), package(.brew, "git")],
            snapshot: snapshot
        ).scriptText
        expectSubshellShape(text)

        let lines = scriptLines(text)
        let open = lines.firstIndex(of: "(")!
        let snapshotLine = lines.firstIndex { $0.contains(snapshot.id.uuidString) }!
        let command = lines.firstIndex(of: "brew uninstall jq")!
        let denylistBanner = lines.firstIndex { $0.contains("commonly depended on") }!
        #expect(snapshotLine < open)
        #expect(command > open)
        #expect(denylistBanner > open)
    }

    @Test("Trash-mode mkdir runs inside the subshell")
    func trashModeMkdirInsideSubshell() {
        let skill = package(
            .agentSkill, "app-design",
            qualifier: "/Users/x/.claude/skills",
            installPath: "/Users/x/.claude/skills/app-design"
        )
        let text = ScriptGenerator().generate(packages: [skill], strategy: .trash).scriptText
        expectSubshellShape(text)
        let lines = scriptLines(text)
        let open = lines.firstIndex(of: "(")!
        let mkdir = lines.firstIndex { $0.hasPrefix("mkdir -p $HOME/.Trash/installory-") }!
        #expect(mkdir > open)
    }

    @Test("Reinstall and restore scripts use the same subshell shape")
    func reinstallScriptShape() {
        let generator = ReinstallScriptGenerator()
        expectSubshellShape(generator.generate(missing: []).scriptText)
        let restore = generator.generate(removing: [package(.brew, "jq")]).scriptText
        expectSubshellShape(restore)
        let lines = scriptLines(restore)
        let open = lines.firstIndex(of: "(")!
        let install = lines.firstIndex { $0.hasPrefix("brew install jq") }
        #expect(install.map { $0 > open } == true)
    }
}

@Suite("Removal-script eligibility (F4)")
struct RemovalScriptEligibilityTests {
    private let generator = ScriptGenerator()

    private func runnableLines(_ pkg: Package, strategy: RemovalStrategy) -> [String] {
        let text = generator.generate(packages: [pkg], strategy: strategy).scriptText
        let lines = scriptLines(text)
        guard let open = lines.firstIndex(of: "(") else { return [] }
        return lines[(open + 1)...].filter { line in
            !line.isEmpty && !line.hasPrefix("#") && line != ")"
                && line != "set -euo pipefail" && !line.hasPrefix("echo ")
                && !line.hasPrefix("mkdir -p ")
        }
    }

    private var samples: [Package] {
        [
            package(.brew, "jq"),
            package(.brewCask, "visual-studio-code"),
            package(.pip, "requests", qualifier: "/usr/local/bin/python3"),
            package(.npm, "typescript"),
            package(.pipx, "black", qualifier: "/Users/x/.local/pipx/venvs/black"),
            package(.uv, "ruff", qualifier: "/Users/x/.local/share/uv/tools/ruff"),
            package(.uv, "broken", qualifier: "relative/path"),
            package(.cargo, "ripgrep"),
            package(.gem, "rake"),
            package(.mas, "Xcode"),
            package(.brew, "python3", isReadOnly: true),
            package(.agentCli, "claude", qualifier: "/Users/x/.claude", installPath: "/Users/x/.claude"),
            package(.agentSkill, "real", qualifier: "/Users/x/.claude/skills",
                    installPath: "/Users/x/.claude/skills/real"),
            package(.agentSkill, "dangling", qualifier: "/Users/x/.claude/skills",
                    artifactPaths: ["/Users/x/gone"]),
            package(.agentSkill, "no-manifest", qualifier: "/Users/x/.claude/skills"),
            package(.editorExtension, "prettier", qualifier: "/Users/x/.vscode/extensions",
                    installPath: "/Users/x/.vscode/extensions/prettier"),
            package(.editorExtension, "mystery", qualifier: "/Users/x/custom/place",
                    installPath: "/Users/x/custom/place/mystery"),
            package(.editorExtension, "mystery-no-path", qualifier: "/Users/x/custom/place"),
        ]
    }

    @Test("Eligibility per strategy matches whether the script has a runnable command")
    func eligibilityMatchesScriptContent() {
        for strategy in [RemovalStrategy.uninstall, .trash] {
            for pkg in samples where !Denylist.default.isDenylisted(pkg) {
                let runnable = !runnableLines(pkg, strategy: strategy).isEmpty
                #expect(
                    pkg.isRemovalScriptEligible(strategy: strategy) == runnable,
                    "\(pkg.id) under \(strategy.rawValue)"
                )
            }
        }
    }

    @Test("Comment-only rows are not eligible")
    func commentOnlyRowsIneligible() {
        let cli = package(.agentCli, "claude", qualifier: "/Users/x/.claude", installPath: "/Users/x/.claude")
        #expect(!cli.isRemovalScriptEligible)
        #expect(!cli.isRemovalScriptEligible(strategy: .uninstall))
        #expect(!cli.isRemovalScriptEligible(strategy: .trash))
        // The App filters with a key path; the property must stay addressable that way.
        #expect([cli].filter(\.isRemovalScriptEligible).isEmpty)

        let realSkill = package(.agentSkill, "real", qualifier: "/Users/x/.claude/skills",
                                installPath: "/Users/x/.claude/skills/real")
        #expect(!realSkill.isRemovalScriptEligible(strategy: .uninstall))
        #expect(realSkill.isRemovalScriptEligible(strategy: .trash))
        #expect(realSkill.isRemovalScriptEligible)

        let noManifest = package(.agentSkill, "no-manifest", qualifier: "/Users/x/.claude/skills")
        #expect(!noManifest.isRemovalScriptEligible)

        let unknownEditorNoPath = package(.editorExtension, "mystery", qualifier: "/Users/x/custom/place")
        #expect(!unknownEditorNoPath.isRemovalScriptEligible)
    }

    @Test("Broken skill links and known-editor extensions are eligible for uninstall")
    func runnableAgentRowsEligible() {
        let dangling = package(.agentSkill, "dangling", qualifier: "/Users/x/.claude/skills",
                               artifactPaths: ["/Users/x/gone"])
        #expect(dangling.isRemovalScriptEligible(strategy: .uninstall))
        let ext = package(.editorExtension, "prettier", qualifier: "/Users/x/.vscode/extensions")
        #expect(ext.isRemovalScriptEligible(strategy: .uninstall))
    }

    @Test("Agent CLI keeps its tailored removal-safety reason")
    func agentCliVerdictReason() {
        let cli = package(.agentCli, "claude", qualifier: "/Users/x/.claude", installPath: "/Users/x/.claude")
        let verdict = RemovalSafetyAnalysis.verdict(
            for: cli,
            reverseDependencyIndex: ReverseDependencyIndex(packages: [cli]),
            orphanedIDs: []
        )
        #expect(verdict.safety == .caution)
        #expect(verdict.reasons == ["Remove with the installer that originally placed it"])
    }
}
