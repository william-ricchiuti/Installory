import Foundation
import Testing
@testable import InstalloryCore

/// Casks as Homebrew 4.x actually lays them out (review findings SC-1, CL-3):
/// the receipt lives in `Caskroom/<token>/.metadata/INSTALL_RECEIPT.json`,
/// the version folder holds only the staged app or pkg, `runtime_dependencies`
/// is a dictionary, and artifacts are under `uninstall_artifacts` with mixed
/// string and object values.
@Suite("BrewScanner casks (real Homebrew layout)")
struct BrewCaskLayoutTests {
    private let prefix = URL(fileURLWithPath: "/opt/homebrew")

    private func scanner(_ build: (inout InMemoryDirectoryAccessProvider.Builder) -> Void) -> BrewScanner {
        let provider = InMemoryDirectoryAccessProvider.make(build)
        return BrewScanner(
            pathDiscovery: PathDiscovery(checkExists: { $0 == "/opt/homebrew" }),
            directoryAccess: provider,
            applicationDirectories: [URL(fileURLWithPath: "/Applications")]
        )
    }

    private func caskroom(_ path: String) -> URL {
        prefix.appendingPathComponent("Caskroom/\(path)")
    }

    private func cellar(_ path: String) -> URL {
        prefix.appendingPathComponent("Cellar/\(path)")
    }

    private func json(_ text: String) -> Data { Data(text.utf8) }

    @Test("a cask with its receipt in .metadata is listed with the version folder's name")
    func metadataReceiptIsRead() async throws {
        let scanner = scanner { (b: inout InMemoryDirectoryAccessProvider.Builder) in
            b.addFile(at: caskroom("aerospace/.metadata/INSTALL_RECEIPT.json"), data: json("""
            {"installed_on_request": true, "time": 1760000000, "runtime_dependencies": {},
             "source": {"tap": "nikitabobko/tap", "version": "0.20.3-Beta"},
             "uninstall_artifacts": [
               {"app": ["AeroSpace-v0.20.3-Beta/AeroSpace.app"]},
               {"binary": ["AeroSpace-v0.20.3-Beta/bin/aerospace", {"target": "aerospace"}]},
               {"zap": [{"trash": "~/.aerospace.toml"}]}
             ]}
            """))
            b.addFile(at: caskroom("aerospace/.metadata/config.json"), data: json("{}"))
            b.addFile(at: caskroom("aerospace/0.20.3-Beta/AeroSpace.app/Contents/Info.plist"), data: Data())
        }
        let packages = try await scanner.scan()
        let cask = try #require(packages.first { $0.manager == .brewCask })
        #expect(cask.name == "aerospace")
        #expect(cask.version == "0.20.3-Beta")
        #expect(cask.isExplicit)
        #expect(cask.installedAt == Date(timeIntervalSince1970: 1_760_000_000))
        let paths = try #require(cask.artifactPaths)
        #expect(paths.contains("AeroSpace.app"))
        #expect(paths.contains("~/.aerospace.toml"))
    }

    @Test("the newest version folder wins when several are present")
    func newestVersionFolderWins() async throws {
        let scanner = scanner { (b: inout InMemoryDirectoryAccessProvider.Builder) in
            b.addFile(at: caskroom("tool/.metadata/INSTALL_RECEIPT.json"), data: json(
                #"{"installed_on_request": true, "uninstall_artifacts": [{"app": ["Tool.app"]}]}"#
            ))
            b.addFile(at: caskroom("tool/1.9.0/Tool.app/x"), data: Data())
            b.addFile(at: caskroom("tool/1.10.0/Tool.app/x"), data: Data())
        }
        let cask = try #require(try await scanner.scan().first { $0.manager == .brewCask })
        #expect(cask.version == "1.10.0")
    }

    @Test("an app with a target name is recorded under that name")
    func appTargetIsUsed() async throws {
        let scanner = scanner { (b: inout InMemoryDirectoryAccessProvider.Builder) in
            b.addFile(at: caskroom("renamed/.metadata/INSTALL_RECEIPT.json"), data: json(
                #"{"uninstall_artifacts": [{"app": ["Original.app", {"target": "Renamed.app"}]}]}"#
            ))
            b.addFile(at: caskroom("renamed/2.0/Original.app/x"), data: Data())
        }
        let cask = try #require(try await scanner.scan().first { $0.manager == .brewCask })
        #expect(cask.artifactPaths?.contains("Renamed.app") == true)
    }

    @Test("unexpected receipt shapes are skipped, not fatal")
    func tolerantOfUnknownShapes() async throws {
        let scanner = scanner { (b: inout InMemoryDirectoryAccessProvider.Builder) in
            b.addFile(at: caskroom("odd/.metadata/INSTALL_RECEIPT.json"), data: json("""
            {"installed_on_request": "yes", "time": "soon", "runtime_dependencies": ["not-a-dict-entry", 7],
             "uninstall_artifacts": [42, {"app": [{"weird": true}, "Odd.app"]}, {"zap": [{"trash": [["nested"]]}]}]}
            """))
            b.addFile(at: caskroom("odd/1.0/Odd.app/x"), data: Data())
            b.addFile(at: caskroom("broken/.metadata/INSTALL_RECEIPT.json"), data: json("{not json"))
            b.addFile(at: caskroom("broken/1.0/Broken.app/x"), data: Data())
        }
        let packages = try await scanner.scan()
        let odd = try #require(packages.first { $0.name == "odd" })
        #expect(odd.artifactPaths?.contains("Odd.app") == true)
        // A receipt that isn't JSON at all can't be trusted; that cask is skipped.
        #expect(!packages.contains { $0.name == "broken" })
    }

    @Test("a formula that only a cask needs is not safe to remove")
    func caskFormulaDependencyProtectsFormula() async throws {
        let scanner = scanner { (b: inout InMemoryDirectoryAccessProvider.Builder) in
            b.addFile(at: caskroom("gcloud-cli/.metadata/INSTALL_RECEIPT.json"), data: json("""
            {"installed_on_request": true,
             "runtime_dependencies": {"formula": [{"full_name": "libyaml-runtime", "version": "1.0", "declared_directly": true}]},
             "uninstall_artifacts": []}
            """))
            b.addFile(at: caskroom("gcloud-cli/550.0.0/google-cloud-sdk/x"), data: Data())
            b.addFile(at: cellar("libyaml-runtime/1.0/INSTALL_RECEIPT.json"), data: json(
                #"{"installed_on_request": true, "runtime_dependencies": []}"#
            ))
        }
        let packages = try await scanner.scan()
        let cask = try #require(packages.first { $0.name == "gcloud-cli" })
        #expect(cask.dependencies == ["libyaml-runtime"])
        let formula = try #require(packages.first { $0.name == "libyaml-runtime" && $0.manager == .brew })

        let index = ReverseDependencyIndex(packages: packages)
        #expect(index.dependents(of: formula).map(\.id) == [cask.id])
        #expect(!packages.orphanedPackages().contains { $0.id == formula.id })
        let verdict = RemovalSafetyAnalysis.verdict(
            for: formula,
            reverseDependencyIndex: index,
            orphanedIDs: Set(packages.orphanedPackages().map(\.id))
        )
        #expect(verdict.safety == .caution)
    }

    @Test("a cask that needs another cask protects that cask")
    func caskCaskDependency() async throws {
        let scanner = scanner { (b: inout InMemoryDirectoryAccessProvider.Builder) in
            b.addFile(at: caskroom("plugin/.metadata/INSTALL_RECEIPT.json"), data: json(
                #"{"installed_on_request": true, "runtime_dependencies": {"cask": [{"full_name": "host-app"}]}}"#
            ))
            b.addFile(at: caskroom("plugin/1.0/x"), data: Data())
            b.addFile(at: caskroom("host-app/.metadata/INSTALL_RECEIPT.json"), data: json(
                #"{"installed_on_request": true}"#
            ))
            b.addFile(at: caskroom("host-app/3.0/x"), data: Data())
        }
        let packages = try await scanner.scan()
        let host = try #require(packages.first { $0.name == "host-app" })
        #expect(!ReverseDependencyIndex(packages: packages).dependents(of: host).isEmpty)
    }

    @Test("a formula receipt with dictionary-shaped dependencies is still read")
    func formulaWithDictionaryDependencies() async throws {
        let scanner = scanner { (b: inout InMemoryDirectoryAccessProvider.Builder) in
            b.addFile(at: cellar("tool/1.0/INSTALL_RECEIPT.json"), data: json(
                #"{"installed_on_request": true, "runtime_dependencies": {"formula": [{"full_name": "homebrew/core/zlib"}]}}"#
            ))
        }
        let formula = try #require(try await scanner.scan().first)
        #expect(formula.dependencies == ["zlib"])
    }
}
