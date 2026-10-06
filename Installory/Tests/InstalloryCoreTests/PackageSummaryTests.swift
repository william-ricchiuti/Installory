import Foundation
import GRDB
import Testing
@testable import InstalloryCore

private func row(
    _ manager: PackageManager,
    _ name: String,
    summary: String? = nil
) -> Package {
    Package(
        id: "\(manager.rawValue)::\(name)",
        manager: manager,
        qualifier: nil,
        name: name,
        version: "1.0.0",
        installPath: nil,
        installedAt: nil,
        installedAtConfidence: .unknown,
        sizeBytes: nil,
        isExplicit: true,
        isReadOnly: false,
        dependencies: [],
        lastSeen: Date(timeIntervalSince1970: 1_710_000_000),
        summary: summary
    )
}

@Suite("Package summaries and description resolution (F6)")
struct PackageSummaryTests {

    // MARK: - DescriptionStore

    @Test("pipx lookups fall back to the shared pip: corpus key")
    func pipxUsesPipKeys() {
        let store = DescriptionStore(raw: ["pip:black": "The uncompromising code formatter"])
        #expect(store.description(for: .pipx, name: "Black") == "The uncompromising code formatter")
        #expect(store.description(for: .pipx, name: "black") == "The uncompromising code formatter")
    }

    @Test("A pipx-specific key still wins over the pip key")
    func pipxSpecificKeyWins() {
        let store = DescriptionStore(raw: ["pip:tool": "pip text", "pipx:tool": "pipx text"])
        #expect(store.description(for: .pipx, name: "tool") == "pipx text")
    }

    @Test("Scanner summary wins for agent skills and editor extensions")
    func summaryPreferredForAgentRows() {
        let store = DescriptionStore(raw: [
            "agentSkill:app-design": "corpus skill text",
            "editorExtension:prettier-vscode": "corpus ext text",
        ])
        #expect(store.descriptionOrFallback(for: row(.agentSkill, "app-design", summary: "Apple-style UI guidance"))
            == "Apple-style UI guidance")
        #expect(store.descriptionOrFallback(for: row(.editorExtension, "prettier-vscode", summary: "Code formatter"))
            == "Code formatter")
        // Without a summary, the corpus is used.
        #expect(store.descriptionOrFallback(for: row(.agentSkill, "app-design")) == "corpus skill text")
        // Blank summaries are ignored.
        #expect(store.descriptionOrFallback(for: row(.agentSkill, "app-design", summary: "  ")) == "corpus skill text")
    }

    @Test("Corpus wins over a summary for package-manager rows; summary beats the fallback")
    func corpusPreferredForManagers() {
        let store = DescriptionStore(raw: ["brew:jq": "JSON processor"])
        #expect(store.descriptionOrFallback(for: row(.brew, "jq", summary: "other")) == "JSON processor")
        #expect(store.descriptionOrFallback(for: row(.brew, "zz", summary: "own text")) == "own text")
        #expect(store.descriptionOrFallback(for: row(.brew, "zz")) == DescriptionStore.fallback(for: .brew))
    }

    @Test("Well-known agent CLIs have corpus-independent descriptions")
    func knownAgentClis() {
        let store = DescriptionStore()
        for name in ["claude", "codex", "opencode", "cursor"] {
            let text = store.descriptionOrFallback(for: row(.agentCli, name))
            #expect(text != DescriptionStore.fallback(for: .agentCli), "\(name)")
        }
        #expect(store.description(for: .agentCli, name: "claude")?.contains("Claude Code") == true)
        #expect(store.description(for: .agentCli, name: "unknown-agent") == nil)
        #expect(store.descriptionOrFallback(for: .agentCli, name: "unknown-agent")
            == DescriptionStore.fallback(for: .agentCli))
    }

    // MARK: - Skill frontmatter

    @Test("SKILL.md description becomes the package summary")
    func skillSummaryFromFrontmatter() async throws {
        let root = URL(fileURLWithPath: "/Users/tester/.claude/skills")
        let skill = root.appendingPathComponent("app-design")
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            builder.addFile(
                at: skill.appendingPathComponent("SKILL.md"),
                data: Data("---\nname: app-design\ndescription: \"Apple-style interface guidance\"\n---\n# Body\n".utf8)
            )
        }
        let packages = try await AgentSkillScanner(skillRoots: [root], directoryAccess: provider).scan()
        #expect(packages.first?.summary == "Apple-style interface guidance")
    }

    @Test("Folded block-scalar descriptions are joined into one line")
    func blockScalarDescription() {
        let manifest = SkillManifestParser.parse("""
        ---
        name: pdf
        description: >
          Extract text and tables
          from PDF files.
        version: 1.0
        ---
        """)
        #expect(manifest.summary == "Extract text and tables from PDF files.")
        #expect(manifest.version == "1.0")
    }

    @Test("Skills without a description have no summary")
    func skillWithoutDescription() {
        #expect(SkillManifestParser.parse("---\nname: x\n---\n").summary == nil)
    }

    // MARK: - Editor extension package.json

    @Test("Editor extension description and displayName are captured")
    func extensionSummary() async throws {
        let root = URL(fileURLWithPath: "/Users/tester/.vscode/extensions")
        let dir = root.appendingPathComponent("esbenp.prettier-vscode-10.1.0")
        let other = root.appendingPathComponent("acme.only-name-1.0.0")
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            builder.addFile(
                at: dir.appendingPathComponent("package.json"),
                data: Data(#"{"name":"prettier-vscode","version":"10.1.0","publisher":"esbenp","displayName":"Prettier - Code formatter","description":"Code formatter using prettier"}"#.utf8)
            )
            builder.addFile(
                at: other.appendingPathComponent("package.json"),
                data: Data(#"{"name":"only-name","version":"1.0.0","displayName":"Only Name"}"#.utf8)
            )
        }
        let packages = try await EditorExtensionScanner(extensionRoots: [root], directoryAccess: provider).scan()
        let byName = Dictionary(uniqueKeysWithValues: packages.map { ($0.name, $0) })
        #expect(byName["prettier-vscode"]?.summary == "Code formatter using prettier")
        #expect(byName["only-name"]?.summary == "Only Name")
    }

    @Test("Localized %placeholders% resolve through package.nls.json")
    func extensionLocalizedSummary() async throws {
        let root = URL(fileURLWithPath: "/Users/tester/.vscode/extensions")
        let dir = root.appendingPathComponent("ms-python.python-2024.4.1")
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            builder.addFile(
                at: dir.appendingPathComponent("package.json"),
                data: Data(#"{"name":"python","version":"2024.4.1","publisher":"ms-python","displayName":"%extension.displayName%","description":"%extension.description%"}"#.utf8)
            )
            builder.addFile(
                at: dir.appendingPathComponent("package.nls.json"),
                data: Data(#"{"extension.displayName":"Python","extension.description":"Python language support"}"#.utf8)
            )
        }
        let packages = try await EditorExtensionScanner(extensionRoots: [root], directoryAccess: provider).scan()
        #expect(packages.first?.summary == "Python language support")
    }

    @Test("Unresolved placeholders are dropped rather than shown")
    func unresolvedPlaceholder() {
        let identity = ExtensionIdentity(
            name: "x", version: "1", displayName: "%dn%", description: "%desc%", publisher: "p"
        )
        #expect(identity.needsLocalization)
        #expect(identity.summary() == nil)
        #expect(identity.summary(localizedStrings: ["dn": "Display"]) == "Display")
    }

    // MARK: - Persistence & Codable compatibility

    @Test("Summary round-trips through the database")
    func databaseRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("installory-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try Migrations.run(pool)

        let with = row(.agentSkill, "s", summary: "Does things")
        let without = row(.brew, "jq")
        try pool.write { db in
            try with.save(db)
            try without.save(db)
        }
        let fetched = try pool.read { db in try Package.fetchAll(db).sorted { $0.id < $1.id } }
        #expect(fetched == [with, without].sorted { $0.id < $1.id })
        #expect(fetched.first { $0.id == with.id }?.summary == "Does things")

        let columns = try pool.read { db in try db.columns(in: "packages").map(\.name) }
        #expect(columns.contains("summary"))
    }

    @Test("A v3 database upgrades to v4 keeping rows with a nil summary")
    func v3UpgradesToV4() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("installory-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try Migrations.makeMigrator().migrate(pool, upTo: "v3_package_user_state")
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO packages (
                        id, manager, qualifier, name, version, install_path,
                        installed_at, installed_at_confidence, size_bytes,
                        is_explicit, is_read_only, dependencies, last_seen, artifact_paths
                    ) VALUES ('brew::jq', 'brew', NULL, 'jq', '1.7', NULL, NULL, 'unknown',
                              NULL, 1, 0, '[]', 1710000000, NULL)
                    """
            )
        }
        try Migrations.run(pool)
        let fetched = try pool.read { db in try Package.fetchOne(db, key: "brew::jq") }
        #expect(fetched?.name == "jq")
        #expect(fetched?.summary == nil)
    }

    @Test("Old JSON without summary decodes; nil summary is not encoded")
    func codableBackwardCompatible() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]

        let legacy = try encoder.encode(row(.brew, "jq"))
        let legacyText = String(decoding: legacy, as: UTF8.self)
        #expect(!legacyText.contains("summary"))
        let decoded = try decoder.decode(Package.self, from: legacy)
        #expect(decoded.summary == nil)

        let withSummary = row(.agentSkill, "s", summary: "Does things")
        let roundTripped = try decoder.decode(Package.self, from: encoder.encode(withSummary))
        #expect(roundTripped == withSummary)
    }
}
