import Foundation
import Testing
@testable import InstalloryCore

/// Review finding SC-2: a folder Installory can't read must not look like a
/// successful scan that found nothing. Otherwise the reconciler replaces that
/// manager's packages with nothing and their Install History evidence is
/// deleted with them. A scanner that finds nothing because a folder refused
/// access now reports "access needed" (skipped), which keeps the last-known
/// rows. A scanner that can read some folders keeps returning what it found.
@Suite("Permission-denied folders are not empty scans")
struct PermissionDeniedScanTests {
    private let home = URL(fileURLWithPath: "/Users/demo")

    private func provider(_ build: (inout InMemoryDirectoryAccessProvider.Builder) -> Void) -> InMemoryDirectoryAccessProvider {
        InMemoryDirectoryAccessProvider.make(build)
    }

    private func expectAccessNeeded(_ scan: () async throws -> [Package]) async {
        do {
            let packages = try await scan()
            Issue.record("expected an access-needed error, got \(packages.count) packages")
        } catch {
            #expect(ScanCoordinator.isPermissionDenied(error))
        }
    }

    // MARK: - Each scanner

    @Test("Homebrew: an unreadable Cellar is access needed, not 0 packages")
    func brewUnreadableCellar() async {
        let provider = provider { b in
            b.addDirectory(at: URL(fileURLWithPath: "/opt/homebrew/Cellar"))
            b.makeUnreadable(at: URL(fileURLWithPath: "/opt/homebrew/Cellar"))
        }
        let scanner = BrewScanner(
            pathDiscovery: PathDiscovery(checkExists: { $0 == "/opt/homebrew" }),
            directoryAccess: provider
        )
        await expectAccessNeeded { try await scanner.scan() }
    }

    @Test("Homebrew: a missing Cellar and Caskroom is a real empty result")
    func brewMissingFoldersAreEmpty() async throws {
        let provider = provider { b in b.addDirectory(at: URL(fileURLWithPath: "/opt/homebrew/bin")) }
        let scanner = BrewScanner(
            pathDiscovery: PathDiscovery(checkExists: { $0 == "/opt/homebrew" }),
            directoryAccess: provider
        )
        #expect(try await scanner.scan().isEmpty)
    }

    @Test("Homebrew: an unreadable Caskroom doesn't hide readable formulae")
    func brewPartialAccessKeepsWhatItCanRead() async throws {
        let provider = provider { b in
            b.addFile(
                at: URL(fileURLWithPath: "/opt/homebrew/Cellar/jq/1.7.1/INSTALL_RECEIPT.json"),
                data: Data(#"{"installed_on_request": true}"#.utf8)
            )
            b.addDirectory(at: URL(fileURLWithPath: "/opt/homebrew/Caskroom"))
            b.makeUnreadable(at: URL(fileURLWithPath: "/opt/homebrew/Caskroom"))
        }
        let scanner = BrewScanner(
            pathDiscovery: PathDiscovery(checkExists: { $0 == "/opt/homebrew" }),
            directoryAccess: provider
        )
        #expect(try await scanner.scan().map(\.name) == ["jq"])
    }

    @Test("npm: an unreadable global folder is access needed")
    func npmUnreadableGlobals() async {
        let provider = provider { b in
            b.addDirectory(at: URL(fileURLWithPath: "/opt/homebrew/lib/node_modules"))
            b.makeUnreadable(at: URL(fileURLWithPath: "/opt/homebrew/lib/node_modules"))
        }
        let scanner = NpmScanner(directoryAccess: provider, homeDirectory: home, environment: .empty)
        await expectAccessNeeded { try await scanner.scan() }
    }

    @Test("npm: an unreadable nvm folder doesn't hide Homebrew globals")
    func npmPartialAccess() async throws {
        let provider = provider { b in
            b.addFile(
                at: URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/eslint/package.json"),
                data: Data(#"{"name": "eslint", "version": "9.0.0"}"#.utf8)
            )
            b.addDirectory(at: home.appendingPathComponent(".nvm/versions/node"))
            b.makeUnreadable(at: home.appendingPathComponent(".nvm/versions/node"))
        }
        let scanner = NpmScanner(directoryAccess: provider, homeDirectory: home, environment: .empty)
        #expect(try await scanner.scan().map(\.name) == ["eslint"])
    }

    @Test("pip: an unreadable site-packages is access needed")
    func pipUnreadableSitePackages() async {
        let sitePackages = URL(fileURLWithPath: "/opt/homebrew/opt/python@3.14/lib/python3.14/site-packages")
        let provider = provider { b in
            b.addFile(at: URL(fileURLWithPath: "/opt/homebrew/opt/python@3.14/bin/python3.14"), data: Data())
            b.addDirectory(at: sitePackages)
            b.makeUnreadable(at: sitePackages)
        }
        let scanner = PipScanner(
            discovery: PythonInterpreterDiscovery(directoryAccess: provider, homeDirectory: home, environment: .empty),
            parser: DistInfoParser(directoryAccess: provider),
            directoryAccess: provider
        )
        await expectAccessNeeded { try await scanner.scan() }
    }

    @Test("pipx: an unreadable venvs folder is access needed")
    func pipxUnreadableVenvs() async {
        let venvs = home.appendingPathComponent(".local/share/pipx/venvs")
        let provider = provider { b in
            b.addDirectory(at: venvs)
            b.makeUnreadable(at: venvs)
        }
        let scanner = PipxScanner(directoryAccess: provider, homeDirectory: home, environment: .empty)
        await expectAccessNeeded { try await scanner.scan() }
    }

    @Test("RubyGems: an unreadable gems folder is access needed")
    func gemUnreadableRoot() async {
        let gems = URL(fileURLWithPath: "/opt/homebrew/lib/ruby/gems")
        let provider = provider { b in
            b.addDirectory(at: gems)
            b.makeUnreadable(at: gems)
        }
        let scanner = GemScanner(directoryAccess: provider, homeDirectory: home, environment: .empty)
        await expectAccessNeeded { try await scanner.scan() }
    }

    // MARK: - End to end: rows and history survive

    @Test("an unreadable Cellar keeps last-known Homebrew rows")
    func reconcilerKeepsRowsWhenAccessIsDenied() async {
        let provider = provider { b in
            b.addDirectory(at: URL(fileURLWithPath: "/opt/homebrew/Cellar"))
            b.makeUnreadable(at: URL(fileURLWithPath: "/opt/homebrew/Cellar"))
        }
        let scanner = BrewScanner(
            pathDiscovery: PathDiscovery(checkExists: { $0 == "/opt/homebrew" }),
            directoryAccess: provider
        )
        let coordinator = ScanCoordinator(scanners: [scanner])
        var status: ScannerStatus?
        for await event in await coordinator.scan() {
            if case let .scannerFinished(_, finished, _) = event { status = finished }
        }
        let skippedForAccess: Bool
        if case let .skipped(reason) = status {
            skippedForAccess = reason == ScanCoordinator.accessNeededReason
        } else {
            skippedForAccess = false
        }
        #expect(skippedForAccess, "status was \(String(describing: status))")

        let existing = [Package(
            id: "brew::jq", manager: .brew, qualifier: nil, name: "jq", version: "1.7.1",
            installPath: nil, installedAt: nil, installedAtConfidence: .high, sizeBytes: nil,
            isExplicit: true, isReadOnly: false, dependencies: [], lastSeen: Date()
        )]
        let reconciled = ScanInventoryReconciler.reconcile(
            existing: existing,
            scanned: [],
            managedManagers: [.brew, .brewCask],
            status: status ?? .succeeded(count: 0, durationMs: 0)
        )
        #expect(reconciled.map(\.id) == ["brew::jq"])
    }
}
