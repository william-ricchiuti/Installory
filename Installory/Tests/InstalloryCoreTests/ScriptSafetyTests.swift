import Foundation
import Testing
@testable import InstalloryCore

/// Review findings CL-5, CL-12, CL-13, CL-14. Scripts are only syntax-checked
/// here (`bash -n`); generated scripts are never executed by tests.
@Suite("Cleanup script safety (2026-11 review)")
struct ScriptSafetyTests {
    private func package(
        _ manager: PackageManager,
        _ name: String,
        qualifier: String? = nil,
        installPath: String? = nil
    ) -> Package {
        Package(
            id: "\(manager.rawValue):\(qualifier ?? ""):\(name):\(installPath ?? "")",
            manager: manager,
            qualifier: qualifier,
            name: name,
            version: "1.0.0",
            installPath: installPath.map { URL(fileURLWithPath: $0) },
            installedAt: nil,
            installedAtConfidence: .unknown,
            sizeBytes: nil,
            isExplicit: true,
            isReadOnly: false,
            dependencies: [],
            lastSeen: Date(timeIntervalSince1970: 1_710_000_000)
        )
    }

    private func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    /// Runs `bash -n` (parse only, nothing executes) on the script text.
    private func bashSyntaxOK(_ script: String) throws -> Bool {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("installory-syntax-\(UUID().uuidString).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", file.path]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - CL-5: Trash destination stays inside the Trash

    @Test("a name with ../ can't move an item outside the Trash")
    func trashDestinationIgnoresHostileName() {
        let hostile = package(
            .editorExtension, "../../../escaped-ext",
            qualifier: "/Users/x/.vscode/extensions",
            installPath: "/Users/x/.vscode/extensions/pub.ext-1.0.0"
        )
        let script = ScriptGenerator().generate(packages: [hostile], strategy: .trash).scriptText
        let move = try? #require(lines(script).first { $0.hasPrefix("mv ") })
        #expect(move?.contains("../") == false, "\(move ?? "")")
        #expect(move?.hasSuffix("/pub.ext-1.0.0") == true, "\(move ?? "")")
    }

    @Test("two items with the same folder name get different Trash names")
    func trashDestinationsAreUnique() {
        let a = package(.agentSkill, "review", qualifier: "/Users/x/.claude/skills", installPath: "/Users/x/.claude/skills/review")
        let b = package(.agentSkill, "review", qualifier: "/Users/x/.codex/skills", installPath: "/Users/x/.codex/skills/review")
        let script = ScriptGenerator().generate(packages: [a, b], strategy: .trash).scriptText
        let destinations = lines(script).filter { $0.hasPrefix("mv ") }.compactMap { $0.split(separator: " ").last.map(String.init) }
        #expect(destinations.count == 2)
        #expect(Set(destinations).count == 2, "\(destinations)")
    }

    // MARK: - CL-13: $HOME is quoted

    @Test("the Trash folder path is quoted, so a home folder with spaces works")
    func homeIsQuoted() {
        let skill = package(.agentSkill, "x", qualifier: "/Users/x/.claude/skills", installPath: "/Users/x/.claude/skills/x")
        let script = ScriptGenerator().generate(packages: [skill], strategy: .trash).scriptText
        let mkdir = lines(script).first { $0.contains("mkdir -p") } ?? ""
        #expect(mkdir.contains(#""$HOME/.Trash/installory-"#), "\(mkdir)")
        let move = lines(script).first { $0.hasPrefix("mv ") } ?? ""
        #expect(move.contains(#""$HOME/.Trash/installory-"#), "\(move)")
        #expect(!script.contains(" $HOME/"), "unquoted $HOME in:\n\(script)")
    }

    // MARK: - CL-14: names that look like options

    @Test("a package name starting with - is never passed to a command")
    func dashNamesAreCommentedOut() {
        let hostile = package(.brew, "-rf")
        let script = ScriptGenerator().generate(packages: [hostile]).scriptText
        #expect(!lines(script).contains { !$0.hasPrefix("#") && $0.contains("uninstall -rf") })
        #expect(script.contains("# -rf:"))
        #expect(!hostile.isRemovalScriptEligible(strategy: .uninstall))
    }

    // MARK: - CL-12: Homebrew's Python is protected

    @Test("pip packages on Homebrew's Python are commented out with an explanation")
    func homebrewPythonIsProtected() {
        let protected = package(.pip, "rich", qualifier: "/opt/homebrew/opt/python@3.14/bin/python3.14")
        let pyenv = package(.pip, "rich", qualifier: "/Users/x/.pyenv/versions/3.12.1/bin/python3.12")
        let script = ScriptGenerator().generate(packages: [protected, pyenv]).scriptText
        #expect(!lines(script).contains { !$0.hasPrefix("#") && $0.contains("python3.14 -m pip uninstall") })
        #expect(script.contains("PEP 668"))
        #expect(lines(script).contains { $0.hasPrefix("/Users/x/.pyenv/versions/3.12.1/bin/python3.12 -m pip uninstall -y rich") })
        #expect(!protected.isRemovalScriptEligible(strategy: .uninstall))
        #expect(pyenv.isRemovalScriptEligible(strategy: .uninstall))
    }

    // MARK: - One failure doesn't stop the rest

    @Test("each group runs in its own strict subshell and failures are summarised")
    func groupsAreIsolated() throws {
        let script = ScriptGenerator().generate(packages: [
            package(.brew, "jq"),
            package(.npm, "eslint", qualifier: "/opt/homebrew/lib/node_modules"),
        ]).scriptText
        let all = lines(script)
        #expect(all.filter { $0 == "set -euo pipefail" }.count == 2, "\(script)")
        #expect(all.contains { $0.hasPrefix(") || failed+=(\"Homebrew Formulae\")") })
        #expect(all.contains { $0.hasPrefix(") || failed+=(") && $0.contains("npm") })
        #expect(script.contains("failed=()"))
        #expect(script.contains(#"${#failed[@]}"#))
        // Nothing executable sits outside the outer subshell.
        let open = try #require(all.firstIndex(of: "("))
        #expect(all[..<open].allSatisfy { $0.hasPrefix("#") || $0.isEmpty })
        #expect(script.hasSuffix(")\n"))
        #expect(try bashSyntaxOK(script))
    }

    @Test("trash-mode and empty scripts are valid bash")
    func otherShapesParse() throws {
        let skill = package(.agentSkill, "x y", qualifier: "/Users/x/.claude/skills", installPath: "/Users/x/.claude/skills/x y")
        #expect(try bashSyntaxOK(ScriptGenerator().generate(packages: [skill], strategy: .trash).scriptText))
        #expect(try bashSyntaxOK(ScriptGenerator().generate(packages: []).scriptText))
        #expect(try bashSyntaxOK(ScriptGenerator().generate(packages: [package(.brew, "git"), package(.brew, "jq")]).scriptText))
    }
}
