import Foundation

/// Scans globally installed npm packages by reading `package.json` files
/// from each known global `node_modules` directory.
///
/// No `npm` or `node` invocation is made. All data comes from reading
/// `package.json` files directly from known on-disk locations.
///
/// Each node_modules root is treated as a separate installation, so the
/// same package name across different Node installations (brew, nvm, Volta)
/// produces distinct `Package` rows tagged with the node_modules path as
/// `qualifier`.
public struct NpmScanner: PackageScanner, Sendable {
    public let manager: PackageManager = .npm

    private let directoryAccess: any DirectoryAccessProvider
    private let homeDirectory: URL
    private let environment: PackageManagerEnvironment

    public init(
        directoryAccess: any DirectoryAccessProvider = SystemDirectoryAccessProvider(),
        homeDirectory: URL = UserHome.directory,
        environment: PackageManagerEnvironment = .current
    ) {
        self.directoryAccess = directoryAccess
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    // MARK: - PackageScanner

    public func isAvailable() async -> Bool {
        guard !Task.isCancelled, let directories = try? nodeModulesDirs() else {
            return false
        }
        for directory in directories {
            guard !Task.isCancelled else { return false }
            let exists = directoryAccess.fileExists(at: directory)
            guard !Task.isCancelled else { return false }
            if exists { return true }
        }
        return false
    }

    public func scan() async throws -> [Package] {
        try Task.checkCancellation()
        let candidates = try nodeModulesDirs()
        let nodeModulesDirectories = try deduplicatedNodeModulesDirs(candidates)
        var sizer = BoundedDirectorySizer(directoryAccess: directoryAccess)
        var seenIDs: Set<String> = []
        var packages: [Package] = []

        for directory in nodeModulesDirectories {
            try Task.checkCancellation()
            for package in try await packagesIn(nodeModulesDir: directory, sizer: &sizer) {
                try Task.checkCancellation()
                if seenIDs.insert(package.id).inserted {
                    packages.append(package)
                }
            }
        }
        let sortedPackages = packages.sorted { $0.id < $1.id }
        try Task.checkCancellation()
        return sortedPackages
    }

    // MARK: - Private

    /// Returns candidate global node_modules directories from all known Node
    /// installation roots, with nvm and Volta version directories sorted for
    /// deterministic ordering across runs.
    private func nodeModulesDirs() throws -> [URL] {
        try Task.checkCancellation()
        var dirs: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules"),
        ]

        // nvm: $NVM_DIR/versions/node/*/lib/node_modules (default ~/.nvm) — sorted for stability
        let nvmDirectory = environment.nvmDirectory(
            fallback: homeDirectory.appendingPathComponent(".nvm")
        )
        let nvmRoot = nvmDirectory.appendingPathComponent("versions/node")
        let nvmVersions = directoryAccess.directoryContentsOrEmpty(at: nvmRoot)
            .sorted(by: { $0.path < $1.path })
        try Task.checkCancellation()
        for version in nvmVersions {
            try Task.checkCancellation()
            dirs.append(version.appendingPathComponent("lib/node_modules"))
        }

        // Volta: ~/.volta/tools/image/node/*/lib/node_modules — sorted for stable qualifier assignment
        let voltaRoot = homeDirectory.appendingPathComponent(".volta/tools/image/node")
        let voltaVersions = directoryAccess.directoryContentsOrEmpty(at: voltaRoot)
            .sorted(by: { $0.path < $1.path })
        try Task.checkCancellation()
        for version in voltaVersions {
            try Task.checkCancellation()
            dirs.append(version.appendingPathComponent("lib/node_modules"))
        }

        try Task.checkCancellation()
        return dirs
    }

    /// Returns the candidate directories with duplicates removed by resolved symlink path.
    /// The first candidate whose resolved path is unseen is kept; its pre-resolution
    /// URL is preserved so Package IDs remain stable across runs.
    private func deduplicatedNodeModulesDirs(_ candidates: [URL]) throws -> [URL] {
        var seenResolved: Set<String> = []
        var result: [URL] = []
        for dir in candidates {
            try Task.checkCancellation()
            let resolved = directoryAccess.resolvingSymlinks(at: dir).path
            guard seenResolved.insert(resolved).inserted else { continue }
            result.append(dir)
        }
        try Task.checkCancellation()
        return result
    }

    private func packagesIn(
        nodeModulesDir: URL,
        sizer: inout BoundedDirectorySizer
    ) async throws -> [Package] {
        try Task.checkCancellation()
        let entries = directoryAccess.directoryContentsOrEmpty(at: nodeModulesDir)
        try Task.checkCancellation()
        var packages: [Package] = []
        var seenResolvedPaths: Set<String> = []

        for entry in entries.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let entryName = entry.lastPathComponent
            guard !entryName.hasPrefix(".") else { continue }

            if entryName.hasPrefix("@") {
                // Scoped directory — each immediate child is a package
                let children = directoryAccess.directoryContentsOrEmpty(at: entry)
                try Task.checkCancellation()
                for child in children.sorted(by: { $0.path < $1.path }) {
                    try Task.checkCancellation()
                    let childName = child.lastPathComponent
                    guard !childName.hasPrefix(".") else { continue }
                    let resolved = directoryAccess.resolvingSymlinks(at: child).path
                    guard seenResolvedPaths.insert(resolved).inserted else { continue }
                    let fullName = "\(entryName)/\(childName)"
                    if let pkg = try await makePackage(
                        packageDir: child,
                        packageName: fullName,
                        nodeModulesDir: nodeModulesDir,
                        sizer: &sizer
                    ) {
                        packages.append(pkg)
                    }
                }
            } else {
                let resolved = directoryAccess.resolvingSymlinks(at: entry).path
                guard seenResolvedPaths.insert(resolved).inserted else { continue }
                if let pkg = try await makePackage(
                    packageDir: entry,
                    packageName: entryName,
                    nodeModulesDir: nodeModulesDir,
                    sizer: &sizer
                ) {
                    packages.append(pkg)
                }
            }
        }
        try Task.checkCancellation()
        return packages
    }

    private func makePackage(
        packageDir: URL,
        packageName: String,
        nodeModulesDir: URL,
        sizer: inout BoundedDirectorySizer
    ) async throws -> Package? {
        let packageJsonURL = packageDir.appendingPathComponent("package.json")
        guard let data = try? directoryAccess.data(contentsOf: packageJsonURL),
              let json = try? npmJSONDecoder.decode(PackageJSON.self, from: data),
              let version = json.version
        else { return nil }
        try Task.checkCancellation()

        // JSON object key order is non-deterministic; sort for snapshot stability.
        let deps = json.dependencies.map { $0.keys.sorted() } ?? []
        let sizeBytes = try await sizer.measure(
            [.tree(packageDir)],
            constrainedTo: nodeModulesDir
        ).sizeBytes

        return Package(
            id: "npm:\(nodeModulesDir.path):\(packageName)",
            manager: .npm,
            qualifier: nodeModulesDir.path,
            name: json.name ?? packageName,
            version: version,
            installPath: packageDir,
            installedAt: directoryAccess.modificationDate(at: packageJsonURL),
            installedAtConfidence: .low,
            sizeBytes: sizeBytes,
            isExplicit: true,
            isReadOnly: false,
            dependencies: deps,
            lastSeen: Date()
        )
    }
}

// MARK: - package.json format

private let npmJSONDecoder = JSONDecoder()

private struct PackageJSON: Decodable, Sendable {
    let name: String?
    let version: String?
    let dependencies: [String: String]?
}
