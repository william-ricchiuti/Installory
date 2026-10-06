import InstalloryCore
import Foundation
import Testing

@Suite("Free-up-space bundle")
struct FreeUpSpaceTests {

    private static let ref = Date(timeIntervalSince1970: 1_710_000_000)

    private func pkg(
        _ name: String,
        manager: PackageManager = .brew,
        qualifier: String? = nil,
        deps: [String] = [],
        isExplicit: Bool = true,
        isReadOnly: Bool = false,
        sizeBytes: Int64? = 1_000_000,
        installPath: URL? = nil,
        artifactPaths: [String]? = nil
    ) -> Package {
        let id = "\(manager.rawValue):\(qualifier ?? ""):\(name)"
        return Package(
            id: id,
            manager: manager,
            qualifier: qualifier,
            name: name,
            version: "1.0.0",
            installPath: installPath,
            installedAt: Self.ref,
            installedAtConfidence: .high,
            sizeBytes: sizeBytes,
            isExplicit: isExplicit,
            isReadOnly: isReadOnly,
            dependencies: deps,
            artifactPaths: artifactPaths,
            lastSeen: Self.ref
        )
    }

    private func bundle(for packages: [Package], limit: Int = 5) -> FreeUpSpaceBundle {
        FreeUpSpace.bundle(
            packages: packages,
            now: Self.ref,
            reverseDependencyIndex: ReverseDependencyIndex(packages: packages),
            limit: limit
        )
    }

    @Test("Empty inventory produces an empty bundle")
    func emptyInventory() {
        let result = bundle(for: [])
        #expect(result.isEmpty)
        #expect(result.candidates.isEmpty)
        #expect(result.totalReclaimableBytes == 0)
    }

    @Test("Denylisted packages are excluded")
    func denylistedExcluded() {
        let result = bundle(for: [pkg("git")])
        #expect(result.isEmpty)
    }

    @Test("Packages with dependents are excluded")
    func dependentsExcluded() {
        let lib = pkg("mylib")
        let app = pkg("myapp", deps: ["mylib"])
        let result = bundle(for: [lib, app])
        #expect(result.candidates.count == 1)
        #expect(result.candidates[0].package.name == "myapp")
    }

    @Test("Read-only packages are excluded")
    func readOnlyExcluded() {
        let result = bundle(for: [pkg("system-tool", isReadOnly: true)])
        #expect(result.isEmpty)
    }

    @Test("Packages with unknown or zero size are excluded")
    func zeroSizeExcluded() {
        let zero = pkg("empty-tool", sizeBytes: nil)
        let alsoZero = pkg("other-tool", sizeBytes: 0)
        let real = pkg("real-tool", sizeBytes: 500)
        let result = bundle(for: [zero, alsoZero, real])
        #expect(result.candidates.count == 1)
        #expect(result.candidates[0].package.name == "real-tool")
    }

    @Test("Total reclaimable bytes is the sum of candidate sizes")
    func totalIsSum() {
        let a = pkg("a", sizeBytes: 100)
        let b = pkg("b", sizeBytes: 250)
        let result = bundle(for: [a, b])
        #expect(result.totalReclaimableBytes == 350)
    }

    @Test("Limit caps the candidate count")
    func limitCapsCount() {
        let packages = (0..<10).map { pkg("tool-\($0)") }
        let result = bundle(for: packages, limit: 3)
        #expect(result.candidates.count == 3)
    }

    // MARK: - Removal-safety gating (F3)

    @Test("Implicitly installed packages (caution verdict) are excluded")
    func implicitExcluded() {
        let implicit = pkg("transitive-lib", isExplicit: false)
        let explicit = pkg("my-tool")
        let result = bundle(for: [implicit, explicit])
        #expect(result.candidates.map(\.package.name) == ["my-tool"])
    }

    @Test("Agent CLIs, real skill directories and editor extensions are excluded")
    func agentRowsExcluded() {
        let cli = pkg("claude", manager: .agentCli, qualifier: "/Users/x/.claude",
                      installPath: URL(fileURLWithPath: "/Users/x/.claude"))
        let skill = pkg("app-design", manager: .agentSkill, qualifier: "/Users/x/.claude/skills",
                        installPath: URL(fileURLWithPath: "/Users/x/.claude/skills/app-design"))
        let ext = pkg("prettier-vscode", manager: .editorExtension, qualifier: "/Users/x/.vscode/extensions",
                      installPath: URL(fileURLWithPath: "/Users/x/.vscode/extensions/prettier"))
        let brew = pkg("ripgrep")
        let result = bundle(for: [cli, skill, ext, brew])
        #expect(result.candidates.map(\.package.name) == ["ripgrep"])
    }

    @Test("Every candidate has a .safe removal-safety verdict and a runnable command")
    func everyCandidateIsSafe() {
        let packages = [
            pkg("a"), pkg("b", isExplicit: false), pkg("c", deps: ["a"]),
            pkg("uvtool", manager: .uv, qualifier: "relative/not-safe"),
            pkg("claude", manager: .agentCli, qualifier: "/Users/x/.claude"),
        ]
        let index = ReverseDependencyIndex(packages: packages)
        let orphans = Set(packages.orphanedPackages().map(\.id))
        let result = FreeUpSpace.bundle(packages: packages, now: Self.ref, reverseDependencyIndex: index)
        #expect(!result.isEmpty)
        for candidate in result.candidates {
            let verdict = RemovalSafetyAnalysis.verdict(
                for: candidate.package, reverseDependencyIndex: index, orphanedIDs: orphans
            )
            #expect(verdict.safety == .safe)
            #expect(candidate.package.isRemovalScriptEligible(strategy: .uninstall))
        }
    }

    @Test("Hidden package ids are excluded and the slot goes to the next candidate")
    func hiddenIDsExcluded() {
        let a = pkg("alpha", sizeBytes: 900)
        let b = pkg("beta", sizeBytes: 800)
        let packages = [a, b]
        let result = FreeUpSpace.bundle(
            packages: packages,
            now: Self.ref,
            reverseDependencyIndex: ReverseDependencyIndex(packages: packages),
            excludingPackageIDs: [a.id],
            limit: 1
        )
        #expect(result.candidates.map(\.package.id) == [b.id])
        #expect(result.totalReclaimableBytes == 800)
    }

    @Test("A precomputed orphan set is honoured")
    func precomputedOrphanSet() {
        let a = pkg("alpha")
        let packages = [a]
        let withoutOrphans = FreeUpSpace.bundle(
            packages: packages,
            now: Self.ref,
            reverseDependencyIndex: ReverseDependencyIndex(packages: packages),
            orphanedIDs: []
        )
        // Not an orphan candidate → brew falls through to a caution verdict.
        #expect(withoutOrphans.isEmpty)

        let withOrphans = FreeUpSpace.bundle(
            packages: packages,
            now: Self.ref,
            reverseDependencyIndex: ReverseDependencyIndex(packages: packages),
            orphanedIDs: [a.id]
        )
        #expect(withOrphans.candidates.map(\.package.id) == [a.id])
    }
}
