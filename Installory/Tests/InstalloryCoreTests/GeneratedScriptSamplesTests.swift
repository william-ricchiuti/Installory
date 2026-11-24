import Foundation
import Testing
@testable import InstalloryCore

/// Writes representative generated scripts to a folder so CI can lint them
/// with shellcheck. Runs only when `INSTALLORY_SCRIPT_SAMPLES_DIR` is set; the
/// scripts are written, never executed.
@Suite("Generated script samples for shellcheck")
struct GeneratedScriptSamplesTests {
    private static let outputDirectory = ProcessInfo.processInfo.environment["INSTALLORY_SCRIPT_SAMPLES_DIR"]

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

    /// Every manager, plus names and paths with spaces, quotes and `$`.
    private var samples: [Package] {
        [
            package(.brew, "jq"),
            package(.brew, "-rf"),
            package(.brewCask, "visual-studio-code"),
            package(.pip, "rich", qualifier: "/Users/x/.pyenv/versions/3.12.1/bin/python3.12"),
            package(.pip, "black", qualifier: "/Users/x/My Tools/venv/bin/python3"),
            package(.pip, "certifi", qualifier: "/opt/homebrew/opt/python@3.14/bin/python3.14"),
            package(.npm, "eslint", qualifier: "/opt/homebrew/lib/node_modules"),
            package(.pipx, "black", qualifier: "/Users/x/.local/share/pipx/venvs/black"),
            package(.uv, "ruff", qualifier: "/Users/x/.local/share/uv/tools/ruff"),
            package(.cargo, "ripgrep"),
            package(.gem, "rails", qualifier: "/Users/x/.rbenv/versions/3.3.0/lib/ruby/gems/3.3.0/specifications"),
            package(.mas, "Xcode"),
            package(.agentSkill, "it's \"quoted\" $(x)", qualifier: "/Users/x/.claude/skills", installPath: "/Users/x/.claude/skills/it's $(x)"),
            package(.editorExtension, "prettier-vscode", qualifier: "/Users/x/.vscode/extensions", installPath: "/Users/x/.vscode/extensions/esbenp.prettier-vscode-11.0.0"),
        ]
    }

    @Test(.enabled(if: Self.outputDirectory != nil))
    func writeSamples() throws {
        let directory = URL(fileURLWithPath: try #require(Self.outputDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let generator = ScriptGenerator(denylist: Denylist(entries: []))
        let scripts: [(String, String)] = [
            ("uninstall.sh", generator.generate(packages: samples).scriptText),
            ("trash.sh", generator.generate(packages: samples, strategy: .trash).scriptText),
            ("uninstall-with-denylist.sh", ScriptGenerator().generate(packages: samples).scriptText),
            ("empty.sh", generator.generate(packages: []).scriptText),
        ]
        for (name, text) in scripts {
            try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count >= scripts.count)
    }
}
