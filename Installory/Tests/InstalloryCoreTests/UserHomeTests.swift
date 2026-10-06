import Darwin
import Foundation
import Testing
@testable import InstalloryCore

/// Regression suite for the sandbox home-directory bug: inside the App Sandbox
/// `FileManager.homeDirectoryForCurrentUser` is the app container, so every
/// Core default that derives `~/.claude`, `~/.cargo`, … must use `UserHome`.
@Suite("UserHome")
struct UserHomeTests {
    private static let containerMarker = "/Library/Containers/"

    @Test("UserHome.directory is the passwd home, never an app container")
    func directoryIsRealHome() throws {
        let path = UserHome.directory.path
        #expect(!path.isEmpty)
        #expect(path.hasPrefix("/"))
        #expect(!path.contains(Self.containerMarker))

        let entry = try #require(getpwuid(getuid()))
        let passwdHome = String(cString: try #require(entry.pointee.pw_dir))
        #expect(UserHome.directory.standardizedFileURL.path
            == URL(fileURLWithPath: passwdHome).standardizedFileURL.path)
    }

    /// Reads a stored property by name, including private ones.
    private func storedValue(named name: String, in value: Any) -> Any? {
        Mirror(reflecting: value).children.first { $0.label == name }?.value
    }

    private func expectNotContainer(_ url: URL?, _ label: String) {
        guard let url else {
            Issue.record("\(label): stored home-derived URL not found")
            return
        }
        #expect(!url.path.contains(Self.containerMarker), "\(label) uses a container path")
        #expect(url.path.hasPrefix(UserHome.directory.path), "\(label) is not under UserHome.directory")
    }

    @Test("Default-constructed scanners and collectors derive paths from UserHome")
    func defaultsUseUserHome() {
        let homeBearing: [(String, Any)] = [
            ("PathDiscovery", PathDiscovery()),
            ("PythonInterpreterDiscovery", PythonInterpreterDiscovery()),
            ("CargoScanner", CargoScanner()),
            ("PipxScanner", PipxScanner()),
            ("NpmScanner", NpmScanner()),
            ("GemScanner", GemScanner()),
            ("MasScanner", MasScanner()),
            ("ClaudeCodeLogCollector", ClaudeCodeLogCollector()),
            ("CodexLogCollector", CodexLogCollector()),
            ("ShellHistoryCollector", ShellHistoryCollector()),
        ]
        for (label, value) in homeBearing {
            let home = storedValue(named: "homeDirectory", in: value) as? URL
            expectNotContainer(home, label)
            #expect(home?.standardizedFileURL.path == UserHome.directory.standardizedFileURL.path, "\(label)")
        }

        let openCode = storedValue(named: "databasePath", in: OpenCodeLogCollector()) as? URL
        expectNotContainer(openCode, "OpenCodeLogCollector")

        let brewApps = storedValue(named: "applicationDirectories", in: BrewScanner()) as? [URL]
        #expect(brewApps?.contains(UserHome.directory.appendingPathComponent("Applications", isDirectory: true)) == true)
        #expect(brewApps?.allSatisfy { !$0.path.contains(Self.containerMarker) } == true)

        let redactorHome = storedValue(named: "homePath", in: ProvenanceRedactor()) as? String
        #expect(redactorHome == UserHome.directory.standardizedFileURL.path)
    }

    @Test("ProvenanceRedactor default collapses the real home to ~")
    func redactorDefaultCollapsesRealHome() {
        let path = UserHome.directory.appendingPathComponent("projects/demo").path
        let evidence = ProvenanceEvidence(
            packageId: "brew::jq",
            fsInstallTime: nil,
            fsInstallTimeSource: nil,
            installCommand: nil,
            claudeCodeContext: ProvenanceEvidence.ClaudeCodeContext(
                sessionId: "s",
                projectPath: path,
                sessionSummary: nil,
                firstUserMessage: nil,
                bashInvocation: "brew install jq",
                timestamp: nil
            ),
            nearbyProjects: [],
            coInstalledWithin1h: [],
            overallConfidence: .low,
            collectedAt: Date(timeIntervalSince1970: 0)
        )
        let redacted = ProvenanceRedactor().redact(evidence)
        #expect(redacted.claudeCodeContext?.projectPath == "~/projects/demo")
    }

    /// Source-level guard: Core must not reintroduce the container-home API
    /// anywhere except `UserHome`'s own last-resort fallback.
    @Test("Core sources only reference homeDirectoryForCurrentUser inside UserHome")
    func noContainerHomeInCoreSources() throws {
        let sourcesRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // InstalloryCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Installory
            .appendingPathComponent("Sources/InstalloryCore", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: nil
        ))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            guard url.lastPathComponent != "UserHome.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if trimmed.contains("homeDirectoryForCurrentUser") || trimmed.contains("NSHomeDirectory(") {
                    offenders.append("\(url.lastPathComponent): \(trimmed)")
                }
            }
        }
        #expect(scanned > 20)
        #expect(offenders.isEmpty, "Use UserHome.directory instead: \(offenders)")
    }

    // MARK: - AgentCliScanner granted roots

    @Test("AgentCli discovery uses a granted folder that is itself an agent config root")
    func agentCliHonoursGrantedConfigRoot() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let grantedCodex = URL(fileURLWithPath: "/Volumes/Other/tester/.codex")
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            builder.addDirectory(at: home.appendingPathComponent(".claude"))
            builder.addDirectory(at: grantedCodex)
        }

        let roots = AgentCliDiscovery.cliRoots(
            homeDirectory: home,
            grantedURLs: [grantedCodex],
            directoryAccess: provider
        )

        #expect(roots.map(\.path) == [
            grantedCodex.path,
            home.appendingPathComponent(".claude").path,
        ].sorted())
    }

    @Test("AgentCli discovery ignores project folders that merely contain .claude")
    func agentCliIgnoresProjectDotClaude() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let project = URL(fileURLWithPath: "/Users/tester/code/app")
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            builder.addDirectory(at: project.appendingPathComponent(".claude"))
        }

        let roots = AgentCliDiscovery.cliRoots(
            homeDirectory: home,
            grantedURLs: [project],
            directoryAccess: provider
        )

        #expect(roots.isEmpty)
    }

    @Test("AgentCliScanner public init forwards grantedURLs to discovery")
    func agentCliScannerForwardsGrantedURLs() async throws {
        let home = URL(fileURLWithPath: "/Users/tester")
        let grantedCursor = URL(fileURLWithPath: "/Volumes/Other/tester/.cursor")
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            builder.addFile(
                at: grantedCursor.appendingPathComponent("argv.json"),
                data: Data("{}".utf8),
                logicalSizeBytes: 2
            )
        }

        let scanner = AgentCliScanner(
            homeDirectory: home,
            grantedURLs: [grantedCursor],
            directoryAccess: provider
        )
        let packages = try await scanner.scan()

        #expect(packages.map(\.name) == ["cursor"])
        #expect(packages.first?.qualifier == grantedCursor.path)
    }
}
