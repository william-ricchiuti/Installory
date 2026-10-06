import Foundation

/// Scans Homebrew formulae and casks by reading `INSTALL_RECEIPT.json` files
/// directly from the Cellar and Caskroom directories under each Homebrew prefix.
///
/// No `brew` invocation is made. The receipt files are the authoritative source
/// of truth for install time, explicit/dependency status, and runtime dependencies.
public struct BrewScanner: PackageScanner, Sendable {
    public let manager: PackageManager = .brew
    public let managedPackageManagers: Set<PackageManager> = [.brew, .brewCask]

    private let pathDiscovery: PathDiscovery
    private let directoryAccess: any DirectoryAccessProvider
    private let applicationDirectories: [URL]

    public init(
        pathDiscovery: PathDiscovery = PathDiscovery(),
        directoryAccess: any DirectoryAccessProvider = SystemDirectoryAccessProvider(),
        applicationDirectories: [URL]? = nil
    ) {
        self.pathDiscovery = pathDiscovery
        self.directoryAccess = directoryAccess
        self.applicationDirectories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            UserHome.directory
                .appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    // MARK: - PackageScanner

    public func isAvailable() async -> Bool {
        guard !Task.isCancelled else { return false }
        let isAvailable = !pathDiscovery.homebrewPrefixes.isEmpty
        return !Task.isCancelled && isAvailable
    }

    public func scan() async throws -> [Package] {
        try Task.checkCancellation()
        let prefixes = pathDiscovery.homebrewPrefixes
        try Task.checkCancellation()
        // `Package.id` carries no prefix component, so a formula installed under
        // both `/opt/homebrew` and `/usr/local` (common on Apple Silicon Macs
        // running Rosetta workloads) would otherwise yield two packages sharing
        // one id — and `PackageDAO.replaceAll` would fail the UNIQUE constraint.
        // Prefixes are ordered Apple Silicon first, so first-wins is correct.
        var seen: Set<String> = []
        var packages: [Package] = []
        var sizer = BoundedDirectorySizer(directoryAccess: directoryAccess)
        for prefix in prefixes {
            try Task.checkCancellation()
            let formulae = try await packagesIn(
                subdirectory: "Cellar",
                of: prefix,
                manager: .brew,
                sizer: &sizer
            )
            let casks = try await packagesIn(
                subdirectory: "Caskroom",
                of: prefix,
                manager: .brewCask,
                sizer: &sizer
            )
            let found = formulae + casks
            packages += found.filter { seen.insert($0.id).inserted }
        }
        try Task.checkCancellation()
        return packages
    }

    // MARK: - Private

    private func packagesIn(
        subdirectory: String,
        of prefix: URL,
        manager: PackageManager,
        sizer: inout BoundedDirectorySizer
    ) async throws -> [Package] {
        try Task.checkCancellation()
        let root = prefix.appendingPathComponent(subdirectory)
        let nameDirs: [URL]
        do {
            nameDirs = try directoryAccess.contentsOfDirectory(at: root)
        } catch {
            try Task.checkCancellation()
            // Cellar or Caskroom doesn't exist under this prefix — not an error.
            return []
        }
        try Task.checkCancellation()

        var packages: [Package] = []
        for nameDir in nameDirs.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let pkgName = nameDir.lastPathComponent
            guard !pkgName.hasPrefix(".") else { continue }

            let versionDirs: [URL]
            do {
                versionDirs = try directoryAccess.contentsOfDirectory(at: nameDir)
            } catch {
                try Task.checkCancellation()
                continue
            }
            try Task.checkCancellation()

            // Collect all valid (versionDir, receipt) pairs, then pick the latest.
            // Multiple version directories arise when Homebrew retains old keg links;
            // emitting one Package per name prevents duplicate SwiftUI List IDs.
            var candidates: [(versionDir: URL, receipt: InstallReceipt)] = []
            for versionDir in versionDirs.sorted(by: { $0.path < $1.path }) {
                try Task.checkCancellation()
                let version = versionDir.lastPathComponent
                guard !version.hasPrefix(".") else { continue }
                let receiptURL = versionDir.appendingPathComponent("INSTALL_RECEIPT.json")
                guard let receiptData = try? directoryAccess.data(contentsOf: receiptURL),
                      let receipt = try? receiptDecoder.decode(InstallReceipt.self, from: receiptData) else {
                    continue
                }
                candidates.append((versionDir: versionDir, receipt: receipt))
            }

            guard let best = pickLatest(candidates) else { continue }
            packages.append(try await makePackage(
                name: pkgName,
                version: best.versionDir.lastPathComponent,
                installPath: best.versionDir,
                receipt: best.receipt,
                manager: manager,
                scannerRoot: root,
                sizer: &sizer
            ))
        }
        try Task.checkCancellation()
        return packages
    }

    /// Returns the candidate with the highest version string, falling back to
    /// newest INSTALL_RECEIPT.json mtime when version strings cannot be compared
    /// numerically (e.g. `1.0.0-alpha` vs `1.0.0-beta`).
    private func pickLatest(
        _ candidates: [(versionDir: URL, receipt: InstallReceipt)]
    ) -> (versionDir: URL, receipt: InstallReceipt)? {
        guard !candidates.isEmpty else { return nil }
        return candidates.dropFirst().reduce(candidates[0]) { best, candidate in
            let bestVer = best.versionDir.lastPathComponent
            let candVer = candidate.versionDir.lastPathComponent
            switch compareVersionStrings(bestVer, candVer) {
            case .orderedAscending:
                return candidate
            case .orderedDescending, .orderedSame:
                return best
            case nil:
                // Non-numeric components differ — fall back to mtime.
                let bestMtime = directoryAccess.modificationDate(
                    at: best.versionDir.appendingPathComponent("INSTALL_RECEIPT.json")
                ) ?? .distantPast
                let candMtime = directoryAccess.modificationDate(
                    at: candidate.versionDir.appendingPathComponent("INSTALL_RECEIPT.json")
                ) ?? .distantPast
                return candMtime > bestMtime ? candidate : best
            }
        }
    }

    private func makePackage(
        name: String,
        version: String,
        installPath: URL,
        receipt: InstallReceipt,
        manager: PackageManager,
        scannerRoot: URL,
        sizer: inout BoundedDirectorySizer
    ) async throws -> Package {
        let id = "\(manager.rawValue)::\(name)"
        let installedAt = receipt.time.map { Date(timeIntervalSince1970: $0) }
        let deps = receipt.runtimeDependencies?.map(\.name) ?? []
        let isExplicit = receipt.installedOnRequest ?? !(receipt.installedAsDependency ?? false)
        let artifactPaths = manager == .brewCask ? receipt.artifactPaths : nil
        try Task.checkCancellation()
        let sizeRoots: [SizeRoot]
        if manager == .brew {
            sizeRoots = [.tree(installPath)]
        } else {
            sizeRoots = caskApplicationRoots(receipt: receipt) ?? []
        }
        let sizeBytes: Int64?
        if sizeRoots.isEmpty {
            sizeBytes = nil
        } else if manager == .brew {
            sizeBytes = try await sizer.measure(
                sizeRoots,
                constrainedTo: scannerRoot
            ).sizeBytes
        } else {
            sizeBytes = try await sizer.measure(sizeRoots).sizeBytes
        }
        try Task.checkCancellation()

        return Package(
            id: id,
            manager: manager,
            qualifier: nil,
            name: name,
            version: version,
            installPath: installPath,
            installedAt: installedAt,
            installedAtConfidence: .high,
            sizeBytes: sizeBytes,
            isExplicit: isExplicit,
            isReadOnly: false,
            dependencies: deps,
            artifactPaths: artifactPaths,
            lastSeen: Date()
        )
    }

    /// Returns the installed app bundles named by a cask receipt. App artifacts
    /// are accepted only as plain `.app` basenames and are resolved underneath
    /// known application directories. Zap paths are intentionally never sized:
    /// they are user data, not the cask payload removed by `brew uninstall`.
    private func caskApplicationRoots(receipt: InstallReceipt) -> [SizeRoot]? {
        let appPaths = Array(Set(receipt.appPaths)).sorted()
        guard !appPaths.isEmpty else { return nil }

        var seen: Set<String> = []
        var roots: [SizeRoot] = []
        for appPath in appPaths {
            guard Self.isSafeCaskAppBasename(appPath) else { return nil }
            guard let appURL = applicationDirectories.lazy
                .map({ $0.appendingPathComponent(appPath, isDirectory: true) })
                .first(where: { directoryAccess.fileExists(at: $0) })
            else { return nil }

            let standardized = appURL.standardizedFileURL
            if seen.insert(standardized.path).inserted {
                roots.append(.tree(standardized))
            }
        }
        return roots.isEmpty ? nil : roots
    }

    private static func isSafeCaskAppBasename(_ path: String) -> Bool {
        !path.isEmpty
            && path.hasSuffix(".app")
            && !path.contains("/")
            && !path.contains("\\")
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

// MARK: - Version comparison

/// Compares two version strings by splitting on "." and comparing each
/// component numerically. Returns nil when a differing component is
/// non-numeric on either side — the caller should fall back to mtime.
private func compareVersionStrings(_ a: String, _ b: String) -> ComparisonResult? {
    let ac = a.components(separatedBy: ".")
    let bc = b.components(separatedBy: ".")
    for i in 0..<max(ac.count, bc.count) {
        let as_ = i < ac.count ? ac[i] : "0"
        let bs_ = i < bc.count ? bc[i] : "0"
        guard as_ != bs_ else { continue }
        guard let an = Int(as_), let bn = Int(bs_) else { return nil }
        return an < bn ? .orderedAscending : .orderedDescending
    }
    return .orderedSame
}

// MARK: - Receipt format

private let receiptDecoder = JSONDecoder()

private struct InstallReceipt: Decodable {
    let time: Double?
    let installedOnRequest: Bool?
    let installedAsDependency: Bool?
    let runtimeDependencies: [RuntimeDep]?
    let artifacts: [Artifact]?

    var artifactPaths: [String]? {
        let paths = artifacts?.flatMap(\.paths) ?? []
        return paths.isEmpty ? nil : paths
    }

    var appPaths: [String] {
        artifacts?.flatMap { $0.app ?? [] } ?? []
    }

    struct RuntimeDep: Decodable {
        let fullName: String

        var name: String {
            fullName.components(separatedBy: "/").last ?? fullName
        }

        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
        }
    }

    struct Artifact: Decodable {
        let app: [String]?
        let zap: [Zap]?

        var paths: [String] {
            (app ?? []) + (zap ?? []).flatMap(\.trash)
        }
    }

    struct Zap: Decodable {
        let trash: [String]
    }

    enum CodingKeys: String, CodingKey {
        case time
        case installedOnRequest = "installed_on_request"
        case installedAsDependency = "installed_as_dependency"
        case runtimeDependencies = "runtime_dependencies"
        case artifacts
    }
}
