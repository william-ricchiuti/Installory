import Foundation
import Testing
@testable import InstalloryCore

@Suite("uv integration contracts")
struct UvIntegrationTests {
    private let observedAt = Date(timeIntervalSince1970: 1_721_000_000)

    private func makePackage(
        name: String = "ruff",
        version: String = "0.6.9",
        qualifier: String = "/Users/tester/.local/share/uv/tools/ruff",
        artifactPaths: [String]? = ["/Users/tester/.local/bin/ruff"]
    ) -> Package {
        Package(
            id: "uv:\(qualifier):\(PackageIdentity.normalizedName(name, manager: .uv))",
            manager: .uv,
            qualifier: qualifier,
            name: name,
            version: version,
            installPath: URL(fileURLWithPath: qualifier, isDirectory: true),
            installedAt: Date(timeIntervalSince1970: 1_720_000_000),
            installedAtConfidence: .medium,
            sizeBytes: 4_096,
            isExplicit: true,
            isReadOnly: false,
            dependencies: ["click", "platformdirs"],
            artifactPaths: artifactPaths,
            lastSeen: observedAt
        )
    }

    private func makeMissing(
        name: String = "ruff",
        version: String = "0.6.9",
        qualifier: String = "/Users/tester/.local/share/uv/tools/ruff"
    ) -> MissingPackage {
        MissingPackage(
            manager: .uv,
            package: SnapshotPackage(
                name: name,
                version: version,
                qualifier: qualifier,
                isExplicit: true
            )
        )
    }

    private func activeLines(containing needle: String, in script: String) -> [String] {
        script.split(separator: "\n").map(String.init).filter { line in
            line.contains(needle) && !line.hasPrefix("#") && !line.hasPrefix("echo ")
                && !line.hasPrefix(") || failed+=(")
        }
    }

    @Test("uv manager has a stable raw value and Codable representation")
    func packageManagerRawAndCodableExpectations() throws {
        #expect(PackageManager.uv.rawValue == "uv")
        #expect(PackageManager.allCases.contains(.uv))

        let encoded = try JSONEncoder().encode(PackageManager.uv)
        #expect(String(decoding: encoded, as: UTF8.self) == #""uv""#)
        #expect(try JSONDecoder().decode(PackageManager.self, from: encoded) == .uv)
    }

    @Test("UV_TOOL_DIR takes precedence over XDG_DATA_HOME and the default")
    func uvToolDirectoryPrecedence() {
        let fallback = URL(fileURLWithPath: "/Users/tester/.local/share/uv/tools")
        let override = PackageManagerEnvironment(values: [
            "UV_TOOL_DIR": "/Volumes/Tools/custom/../uv-tools",
            "XDG_DATA_HOME": "/Volumes/Data",
        ])
        let xdg = PackageManagerEnvironment(values: [
            "XDG_DATA_HOME": "/Volumes/Data",
        ])

        #expect(override.uvToolDirectory(fallback: fallback).path == "/Volumes/Tools/uv-tools")
        #expect(xdg.uvToolDirectory(fallback: fallback).path == "/Volumes/Data/uv/tools")
        #expect(PackageManagerEnvironment.empty.uvToolDirectory(fallback: fallback) == fallback)
    }

    @Test("UV_PYTHON_INSTALL_DIR takes precedence over XDG_DATA_HOME and the default")
    func uvPythonInstallDirectoryPrecedence() {
        let fallback = URL(fileURLWithPath: "/Users/tester/.local/share/uv/python")
        let override = PackageManagerEnvironment(values: [
            "UV_PYTHON_INSTALL_DIR": "/Volumes/Tools/python/../uv-python",
            "XDG_DATA_HOME": "/Volumes/Data",
        ])
        let xdg = PackageManagerEnvironment(values: [
            "XDG_DATA_HOME": "/Volumes/Data",
        ])

        #expect(override.uvPythonInstallDirectory(fallback: fallback).path == "/Volumes/Tools/uv-python")
        #expect(xdg.uvPythonInstallDirectory(fallback: fallback).path == "/Volumes/Data/uv/python")
        #expect(PackageManagerEnvironment.empty.uvPythonInstallDirectory(fallback: fallback) == fallback)
    }

    @Test("relative and control-character uv environment overrides are rejected")
    func relativeOrControlCharacterUvEnvironmentOverridesAreRejected() {
        let toolFallback = URL(fileURLWithPath: "/Users/tester/.local/share/uv/tools")
        let pythonFallback = URL(fileURLWithPath: "/Users/tester/.local/share/uv/python")
        let relativeOverridesWithValidXDG = PackageManagerEnvironment(values: [
            "UV_TOOL_DIR": "relative/uv-tools",
            "UV_PYTHON_INSTALL_DIR": "relative/uv-python",
            "XDG_DATA_HOME": "/Volumes/Data",
        ])
        let controlOverridesWithValidXDG = PackageManagerEnvironment(values: [
            "UV_TOOL_DIR": "/Volumes/Tools/uv-tools\u{0007}",
            "UV_PYTHON_INSTALL_DIR": "/Volumes/Tools/uv-python\n",
            "XDG_DATA_HOME": "/Volumes/Data",
        ])
        let allInvalid = PackageManagerEnvironment(values: [
            "UV_TOOL_DIR": "relative/uv-tools\n",
            "UV_PYTHON_INSTALL_DIR": "relative/uv-python\u{0007}",
            "XDG_DATA_HOME": "relative/xdg\u{0007}",
        ])

        #expect(
            relativeOverridesWithValidXDG.uvToolDirectory(fallback: toolFallback).path
                == "/Volumes/Data/uv/tools"
        )
        #expect(
            relativeOverridesWithValidXDG.uvPythonInstallDirectory(fallback: pythonFallback).path
                == "/Volumes/Data/uv/python"
        )
        #expect(
            controlOverridesWithValidXDG.uvToolDirectory(fallback: toolFallback).path
                == "/Volumes/Data/uv/tools"
        )
        #expect(
            controlOverridesWithValidXDG.uvPythonInstallDirectory(fallback: pythonFallback).path
                == "/Volumes/Data/uv/python"
        )
        #expect(allInvalid.uvToolDirectory(fallback: toolFallback) == toolFallback)
        #expect(allInvalid.uvPythonInstallDirectory(fallback: pythonFallback) == pythonFallback)
    }

    @Test("uv Package rows round-trip through the database")
    func uvPackageDatabaseRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UvIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try InstalloryCore.Database(directory: directory)
        let dao = PackageDAO(database: database)
        let original = makePackage()
        try dao.replaceAll(with: [original])

        let loaded = try #require(dao.loadAll().only)
        #expect(loaded.id == original.id)
        #expect(loaded.manager == .uv)
        #expect(loaded.qualifier == original.qualifier)
        #expect(loaded.name == original.name)
        #expect(loaded.version == original.version)
        #expect(loaded.installPath?.path == original.installPath?.path)
        #expect(loaded.installedAt == original.installedAt)
        #expect(loaded.installedAtConfidence == original.installedAtConfidence)
        #expect(loaded.sizeBytes == original.sizeBytes)
        #expect(loaded.isExplicit == original.isExplicit)
        #expect(loaded.isReadOnly == original.isReadOnly)
        #expect(loaded.dependencies == original.dependencies)
        #expect(loaded.artifactPaths == ["/Users/tester/.local/bin/ruff"])
        #expect(loaded.lastSeen == original.lastSeen)
    }

    @Test("uv snapshot payloads use the uv key and Codable round-trip")
    func uvSnapshotCodableRoundTrip() throws {
        let original = Snapshot(
            id: UUID(uuidString: "1F4FB73C-CC24-4987-A18C-F03DE82BB2A8")!,
            createdAt: observedAt,
            reason: .preCleanup,
            note: "uv snapshot",
            payload: SnapshotPayload(managers: [
                .uv: [
                    SnapshotPackage(
                        name: "Ruff",
                        version: "0.6.9",
                        qualifier: "/Users/tester/.local/share/uv/tools/ruff",
                        isExplicit: true
                    ),
                ],
            ])
        )

        let encoded = try JSONEncoder().encode(original)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let payload = try #require(json["payload"] as? [String: Any])
        #expect(payload["uv"] != nil)

        let decoded = try JSONDecoder().decode(Snapshot.self, from: encoded)
        let uvPackages = try #require(decoded.payload.managers[.uv])
        #expect(uvPackages.count == 1)
        #expect(uvPackages[0].name == "Ruff")
        #expect(uvPackages[0].version == "0.6.9")
        #expect(uvPackages[0].qualifier == "/Users/tester/.local/share/uv/tools/ruff")
        #expect(uvPackages[0].isExplicit)
    }

    @Test("uv descriptions reuse the PEP-503-normalized pip corpus")
    func uvDescriptionReusesPipCorpus() {
        let store = DescriptionStore(raw: [
            "pip:requests-oauthlib": "OAuth support for Requests",
            "uv:requests-oauthlib": "must not use a duplicated uv entry",
        ])

        #expect(
            store.description(for: .uv, name: "Requests__OAuthlib")
                == "OAuth support for Requests"
        )
    }

    @Test("uv removal targets the recorded root and normalized environment exactly")
    func uvRemovalUsesExactRootQualifiedTarget() {
        let qualifier = "/Users/tester/Library/Application Support/uv/tools/ruff"
        let package = makePackage(name: "Ruff Display Name", qualifier: qualifier)
        let generator = ScriptGenerator(denylist: Denylist(entries: []))

        #expect(
            generator.removalCommand(for: package)
                == "UV_TOOL_DIR='/Users/tester/Library/Application Support/uv/tools' uv tool uninstall ruff"
        )
        let script = generator.generate(packages: [package]).scriptText
        #expect(activeLines(containing: "uv tool uninstall", in: script) == [
            "UV_TOOL_DIR='/Users/tester/Library/Application Support/uv/tools' uv tool uninstall ruff",
        ])
    }

    @Test("uv removal preserves the exact safe environment basename")
    func uvRemovalPreservesExactEnvironmentBasename() {
        let package = makePackage(
            name: "Friendly Bard",
            qualifier: "/Users/tester/.local/share/uv/tools/friendly_bard"
        )

        #expect(
            ScriptGenerator(denylist: Denylist(entries: []))
                .removalCommand(for: package)
                == "UV_TOOL_DIR=/Users/tester/.local/share/uv/tools uv tool uninstall friendly_bard"
        )
    }

    @Test("a hostile uv qualifier yields only an inert manual-review comment")
    func hostileUvQualifierProducesOnlyManualReviewComment() {
        let qualifier = "../../uv/tools/ruff\nprintf QUALIFIER_PWNED"
        let package = makePackage(qualifier: qualifier)
        let generator = ScriptGenerator(denylist: Denylist(entries: []))
        let script = generator.generate(packages: [package]).scriptText

        #expect(generator.removalCommand(for: package) == nil)
        #expect(activeLines(containing: "uv tool", in: script).isEmpty)
        #expect(script.contains("# Manual review required: cannot safely target uv tool ruff"))
        #expect(!script.split(separator: "\n").contains("printf QUALIFIER_PWNED"))
    }

    @Test("bulk uv removal is deterministic by recorded root and environment name")
    func uvRemovalHasDeterministicRootAndNameOrder() {
        let packages = [
            makePackage(name: "Zulu", qualifier: "/Volumes/Zeta/uv/tools/zulu"),
            makePackage(name: "Beta", qualifier: "/Volumes/Alpha/uv/tools/beta"),
            makePackage(name: "Alpha", qualifier: "/Volumes/Alpha/uv/tools/alpha"),
        ]
        let script = ScriptGenerator(denylist: Denylist(entries: []))
            .generate(packages: packages)
            .scriptText

        #expect(activeLines(containing: "uv tool uninstall", in: script) == [
            "UV_TOOL_DIR=/Volumes/Alpha/uv/tools uv tool uninstall alpha",
            "UV_TOOL_DIR=/Volumes/Alpha/uv/tools uv tool uninstall beta",
            "UV_TOOL_DIR=/Volumes/Zeta/uv/tools uv tool uninstall zulu",
        ])
    }

    @Test("uv snapshot reinstall is manual-review-only")
    func uvReinstallEmitsNoActiveInstallCommand() {
        let script = ReinstallScriptGenerator()
            .generate(missing: [makeMissing()])
            .scriptText

        #expect(script.contains("# === uv tools ==="))
        #expect(script.contains("# Manual review required: uv tool ruff 0.6.9"))
        #expect(activeLines(containing: "uv tool", in: script).isEmpty)
        #expect(!script.contains("uv tool install"))
    }

    @Test("uv tool install detects only the primary persistent target after options")
    func installCommandDetectorFindsPrimaryUvToolTarget() throws {
        let detections = InstallCommandDetector().detect(
            "uv tool install --python 3.13 --with httpx --index-url https://example.invalid/simple "
                + "'Ruff[cli]>=0.6' --with-executables-from black"
        )

        let detection = try #require(detections.only)
        #expect(detection.name == "Ruff")
        #expect(detection.manager == .uv)
    }

    @Test("uvx, tool run, local paths, and unnameable URLs are not persistent uv installs")
    func installCommandDetectorExcludesNonPersistentUvTargets() {
        let commands = [
            "uvx ruff",
            "uv tool run ruff",
            "uv tool install .",
            "uv tool install ../ruff",
            "uv tool install /tmp/ruff",
            "uv tool install --editable local-ruff",
            "uv tool install https://example.invalid/ruff.whl",
            "uv tool install git+https://github.com/astral-sh/ruff.git",
        ]

        for command in commands {
            #expect(InstallCommandDetector().detect(command).isEmpty, "unexpected detection for \(command)")
        }
    }

    @Test("uv pip install remains pip provenance")
    func installCommandDetectorPreservesUvPipManager() throws {
        let detection = try #require(
            InstallCommandDetector().detect("uv pip install 'Requests>=2'").only
        )
        #expect(detection.name == "Requests")
        #expect(detection.manager == .pip)
    }

    @Test("uv PATH resolution uses a unanimous receipt entrypoint parent")
    func uvPathResolutionUsesUnanimousEntrypointParent() {
        let uv = makePackage(artifactPaths: [
            "/Users/tester/.local/bin/ruff",
            "/Users/tester/.local/bin/ruff-lsp",
        ])
        let brew = Package(
            id: "brew::ruff",
            manager: .brew,
            qualifier: nil,
            name: "ruff",
            version: "0.6.9",
            installPath: URL(fileURLWithPath: "/opt/homebrew/Cellar/ruff/0.6.9"),
            installedAt: nil,
            installedAtConfidence: .unknown,
            sizeBytes: nil,
            isExplicit: true,
            isReadOnly: false,
            dependencies: [],
            lastSeen: observedAt
        )
        let standings = resolvePathStandings(
            for: DuplicateGroup(name: "ruff", packages: [uv, brew]),
            path: ["/Users/tester/.local/bin", "/opt/homebrew/bin"]
        )

        #expect(standings[uv.id] == .wins)
        #expect(standings[brew.id] == .shadowed(byPackageId: uv.id))
    }

    @Test("conflicting uv receipt entrypoint parents resolve as unknown")
    func conflictingUvEntrypointParentsResolveAsUnknown() {
        let uv = makePackage(artifactPaths: [
            "/Users/tester/.local/bin/ruff",
            "/opt/custom/bin/ruff-lsp",
        ])
        let brew = Package(
            id: "brew::ruff",
            manager: .brew,
            qualifier: nil,
            name: "ruff",
            version: "0.6.9",
            installPath: URL(fileURLWithPath: "/opt/homebrew/Cellar/ruff/0.6.9"),
            installedAt: nil,
            installedAtConfidence: .unknown,
            sizeBytes: nil,
            isExplicit: true,
            isReadOnly: false,
            dependencies: [],
            lastSeen: observedAt
        )
        let standings = resolvePathStandings(
            for: DuplicateGroup(name: "ruff", packages: [uv, brew]),
            path: ["/Users/tester/.local/bin", "/opt/custom/bin", "/opt/homebrew/bin"]
        )

        #expect(standings[uv.id] == .unknown)
        #expect(standings[brew.id] == .wins)
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
