import Foundation
import Testing
@testable import InstalloryCore

/// Regression tests for the false "safe to remove" verdicts found in the
/// November 2026 review (CL-1, CL-2, CL-7). Each scenario models a real layout
/// seen on a Mac: modern `Requires-Dist` metadata, Homebrew runtimes that other
/// managers' packages run on, and pip packages Homebrew installs itself.
@Suite("Removal verdict regressions (2026-11 review)")
struct RemovalVerdictRegressionTests {
    // MARK: - Helpers

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let longAgo = Date(timeIntervalSince1970: 1_700_000_000)

    private func package(
        _ manager: PackageManager,
        _ name: String,
        qualifier: String? = nil,
        installPath: String? = nil,
        explicit: Bool = true,
        readOnly: Bool = false,
        dependencies: [String] = [],
        size: Int64 = 50_000_000
    ) -> Package {
        Package(
            id: "\(manager.rawValue):\(qualifier ?? ""):\(name)",
            manager: manager,
            qualifier: qualifier,
            name: name,
            version: "1.0.0",
            installPath: installPath.map { URL(fileURLWithPath: $0) },
            installedAt: Self.longAgo,
            installedAtConfidence: .high,
            sizeBytes: size,
            isExplicit: explicit,
            isReadOnly: readOnly,
            dependencies: dependencies,
            lastSeen: Self.now
        )
    }

    private func brew(_ name: String, prefix: String = "/opt/homebrew") -> Package {
        package(.brew, name, installPath: "\(prefix)/Cellar/\(name)/1.0.0")
    }

    private func verdict(of target: Package, in packages: [Package]) -> RemovalSafety {
        let index = ReverseDependencyIndex(packages: packages)
        let orphans = Set(packages.orphanedPackages().map(\.id))
        return RemovalSafetyAnalysis.verdict(
            for: target,
            reverseDependencyIndex: index,
            orphanedIDs: orphans
        ).safety
    }

    private func bundleIDs(_ packages: [Package]) -> Set<String> {
        let bundle = FreeUpSpace.bundle(
            packages: packages,
            now: Self.now,
            reverseDependencyIndex: ReverseDependencyIndex(packages: packages),
            limit: 50
        )
        return Set(bundle.candidates.map(\.package.id))
    }

    // MARK: - CL-1: PEP 508 names

    @Test(
        "Requires-Dist yields the bare PEP 508 distribution name",
        arguments: [
            ("charset_normalizer<4,>=2", "charset_normalizer"),
            ("numpy>=1.26.0; python_version >= '3.9'", "numpy"),
            ("requests[socks]>=2.26.0", "requests"),
            ("httpx[http2] >= 0.27", "httpx"),
            ("idna (>=2.5,<4)", "idna"),
            ("zope.interface>=5", "zope.interface"),
            ("typing-extensions; python_version < '3.11'", "typing-extensions"),
            ("urllib3!=2.0.0,>=1.26", "urllib3"),
            ("pkg@ https://example.invalid/pkg.whl", "pkg"),
            ("   ", ""),
        ]
    )
    func pep508Names(_ requirement: String, _ expected: String) {
        #expect(PythonRequirement.distributionName(from: requirement) == expected)
    }

    @Test("a library listed with a modern specifier is not safe to remove")
    func modernSpecifierKeepsDependency() {
        let python = "/opt/homebrew/opt/python@3.14/bin/python3.14"
        let requires = [
            "numpy>=1.26.0; python_version >= '3.9'",
            "charset_normalizer<4,>=2",
            "requests[socks]>=2.26.0",
        ].map(PythonRequirement.distributionName)
        let pandas = package(.pip, "pandas", qualifier: python, dependencies: requires)
        let numpy = package(.pip, "numpy", qualifier: python)
        let charset = package(.pip, "charset-normalizer", qualifier: python)
        let requests = package(.pip, "requests", qualifier: python)
        let all = [pandas, numpy, charset, requests]

        for library in [numpy, charset, requests] {
            #expect(verdict(of: library, in: all) == .caution, "\(library.name)")
            #expect(!bundleIDs(all).contains(library.id), "\(library.name)")
        }
        #expect(verdict(of: pandas, in: all) == .safe)
    }

    // MARK: - CL-2: runtimes other managers run on

    @Test("node@22 with npm globals in its prefix is not safe")
    func versionedNodeHostsNpmGlobals() {
        let node = brew("node@22")
        let eslint = package(.npm, "eslint", qualifier: "/opt/homebrew/lib/node_modules")
        let all = [node, eslint]
        #expect(verdict(of: node, in: all) != .safe)
        #expect(!bundleIDs(all).contains(node.id))
    }

    @Test("Homebrew ruby with gems in its prefix is not safe")
    func rubyHostsGems() {
        let ruby = brew("ruby")
        let gem = package(.gem, "rails", qualifier: "/opt/homebrew/lib/ruby/gems/3.4.0/specifications")
        let all = [ruby, gem]
        #expect(verdict(of: ruby, in: all) == .caution)
        #expect(!bundleIDs(all).contains(ruby.id))
    }

    @Test("pyenv with packages in its Pythons is not safe")
    func pyenvHostsPip() {
        let pyenv = brew("pyenv")
        let pip = package(.pip, "black", qualifier: "/Users/demo/.pyenv/versions/3.12.1/bin/python3.12")
        let all = [pyenv, pip]
        #expect(verdict(of: pyenv, in: all) == .caution)
        #expect(!bundleIDs(all).contains(pyenv.id))
    }

    @Test("uv with uv tools or uv-managed Pythons is not safe")
    func uvHostsTools() {
        let uv = brew("uv")
        let tool = package(.uv, "ruff", qualifier: "/Users/demo/.local/share/uv/tools/ruff")
        #expect(verdict(of: uv, in: [uv, tool]) == .caution)
        let managed = package(.pip, "rich", qualifier: "/Users/demo/.local/share/uv/python/cpython-3.12.7-macos-aarch64-none/bin/python3.12")
        #expect(verdict(of: uv, in: [uv, managed]) == .caution)
        #expect(!bundleIDs([uv, tool]).contains(uv.id))
    }

    @Test("pipx with pipx apps is not safe")
    func pipxHostsApps() {
        let pipx = brew("pipx")
        let app = package(.pipx, "black", qualifier: "/Users/demo/.local/pipx/venvs/black")
        #expect(verdict(of: pipx, in: [pipx, app]) == .caution)
    }

    @Test("a runtime that hosts nothing keeps its normal verdict")
    func emptyHostStaysSafe() {
        let uv = brew("uv")
        let pyenv = brew("pyenv")
        #expect(verdict(of: uv, in: [uv, pyenv]) == .safe)
        #expect(verdict(of: pyenv, in: [uv, pyenv]) == .safe)
    }

    @Test("npm globals in another Homebrew prefix don't pin this prefix's node")
    func hostingRespectsPrefix() {
        let node = brew("node@20", prefix: "/usr/local")
        let eslint = package(.npm, "eslint", qualifier: "/opt/homebrew/lib/node_modules")
        #expect(verdict(of: node, in: [node, eslint]) == .leaveAlone || verdict(of: node, in: [node, eslint]) == .safe)
        #expect(ReverseDependencyIndex(packages: [node, eslint]).hostedPackages(of: node).isEmpty)
    }

    @Test("the hosting reason names the tools that run on it")
    func hostingReasonNamesTools() {
        let ruby = brew("ruby")
        let gem = package(.gem, "rails", qualifier: "/opt/homebrew/lib/ruby/gems/3.4.0/specifications")
        let index = ReverseDependencyIndex(packages: [ruby, gem])
        let result = RemovalSafetyAnalysis.verdict(for: ruby, reverseDependencyIndex: index, orphanedIDs: [])
        #expect(result.reasons.contains { $0.contains("rails") })
    }

    // MARK: - CL-7: pip packages Homebrew installed

    @Test("pip packages with INSTALLER=brew are read-only and left alone")
    func brewOwnedPipPackagesAreReadOnly() async throws {
        // Uses the keg-relative site-packages that discovery reads today; the
        // shared `$PREFIX/lib/pythonX.Y` location is a separate coverage fix (SC-3).
        let sitePackages = URL(fileURLWithPath: "/opt/homebrew/opt/python@3.14/lib/python3.14/site-packages")
        let certifi = sitePackages.appendingPathComponent("certifi-2026.1.4.dist-info")
        let rich = sitePackages.appendingPathComponent("rich-14.0.0.dist-info")
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            builder.addFile(at: URL(fileURLWithPath: "/opt/homebrew/opt/python@3.14/bin/python3.14"), data: Data())
            builder.addFile(
                at: certifi.appendingPathComponent("METADATA"),
                data: Data("Metadata-Version: 2.1\nName: certifi\nVersion: 2026.1.4\n".utf8)
            )
            builder.addFile(at: certifi.appendingPathComponent("INSTALLER"), data: Data("brew\n".utf8))
            builder.addFile(at: certifi.appendingPathComponent("REQUESTED"), data: Data())
            builder.addFile(
                at: rich.appendingPathComponent("METADATA"),
                data: Data("Metadata-Version: 2.1\nName: rich\nVersion: 14.0.0\n".utf8)
            )
            builder.addFile(at: rich.appendingPathComponent("INSTALLER"), data: Data("pip\n".utf8))
            builder.addFile(at: rich.appendingPathComponent("REQUESTED"), data: Data())
        }
        let discovery = PythonInterpreterDiscovery(directoryAccess: provider, homeDirectory: URL(fileURLWithPath: "/Users/demo"))
        let scanner = PipScanner(
            discovery: discovery,
            parser: DistInfoParser(directoryAccess: provider),
            directoryAccess: provider
        )
        let packages = try await scanner.scan()
        let brewOwned = try #require(packages.first { $0.name == "certifi" })
        let userInstalled = try #require(packages.first { $0.name == "rich" })
        #expect(brewOwned.isReadOnly)
        #expect(!userInstalled.isReadOnly)
        #expect(verdict(of: brewOwned, in: packages) == .leaveAlone)
    }

    // MARK: - Guard: correct verdicts stay correct

    @Test("a leaf formula nothing uses is still safe")
    func leafFormulaStaysSafe() {
        let jq = brew("jq")
        let oniguruma = package(.brew, "oniguruma", installPath: "/opt/homebrew/Cellar/oniguruma/6.9.9", explicit: false)
        let jqWithDep = package(.brew, "jq", installPath: "/opt/homebrew/Cellar/jq/1.7.1", dependencies: ["oniguruma"])
        #expect(verdict(of: jq, in: [jq]) == .safe)
        #expect(verdict(of: oniguruma, in: [jqWithDep, oniguruma]) == .caution)
    }
}
