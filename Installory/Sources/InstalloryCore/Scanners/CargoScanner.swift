import Foundation

/// Scans binaries installed by `cargo install` by reading Cargo's
/// `$CARGO_HOME/.crates2.json` metadata file (falling back to `~/.cargo`).
///
/// No `cargo` invocation is made.
public struct CargoScanner: PackageScanner, Sendable {
    public let manager: PackageManager = .cargo

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

    public func isAvailable() async -> Bool {
        guard !Task.isCancelled else { return false }
        let isAvailable = directoryAccess.fileExists(at: cratesFile)
        return !Task.isCancelled && isAvailable
    }

    public var unavailableReason: String {
        "Cargo install metadata not granted or not found"
    }

    public func scan() async throws -> [Package] {
        try Task.checkCancellation()
        let data = try directoryAccess.data(contentsOf: cratesFile)
        try Task.checkCancellation()
        let metadata = try JSONDecoder().decode(CargoCratesMetadata.self, from: data)
        try Task.checkCancellation()
        var sizer = BoundedDirectorySizer(directoryAccess: directoryAccess)
        var packages: [Package] = []

        // Dictionary order is unspecified. A stable key order makes both package
        // output and consumption of the scan-wide size budget deterministic.
        for key in metadata.installs.keys.sorted() {
            try Task.checkCancellation()
            guard let install = metadata.installs[key],
                  let package = try await makePackage(key: key, install: install, sizer: &sizer)
            else { continue }
            packages.append(package)
        }

        let sortedPackages = packages.sorted { $0.name < $1.name }
        try Task.checkCancellation()
        return sortedPackages
    }

    private var cargoHome: URL {
        environment.cargoHome(
            fallback: homeDirectory.appendingPathComponent(".cargo")
        )
    }

    private var cratesFile: URL {
        cargoHome.appendingPathComponent(".crates2.json")
    }

    private func makePackage(
        key: String,
        install: CargoInstall,
        sizer: inout BoundedDirectorySizer
    ) async throws -> Package? {
        try Task.checkCancellation()
        guard let parsed = parseInstallKey(key) else { return nil }
        let binPaths = try validatedBinPaths(install.bins)
        let binPath = binPaths?.first
        let sizeBytes: Int64?
        if let binPaths, !binPaths.isEmpty {
            sizeBytes = (try await sizer.measure(
                binPaths
                    .sorted { $0.path < $1.path }
                    .map(SizeRoot.file),
                constrainedTo: cargoHome
            )).sizeBytes
        } else {
            sizeBytes = nil
        }
        try Task.checkCancellation()

        return Package(
            id: "cargo::\(parsed.name)",
            manager: .cargo,
            // Cargo records the source in the install key. Reusing the existing
            // qualifier field carries it through persistence and snapshots without
            // a schema change so restore scripts can reproduce the source.
            qualifier: parsed.source,
            name: parsed.name,
            version: parsed.version,
            installPath: binPath ?? cargoHome,
            installedAt: binPath.flatMap { directoryAccess.modificationDate(at: $0) }
                ?? directoryAccess.modificationDate(at: cratesFile),
            installedAtConfidence: .medium,
            sizeBytes: sizeBytes,
            isExplicit: true,
            isReadOnly: false,
            dependencies: [],
            lastSeen: Date()
        )
    }

    /// Returns every declared binary below `<cargo-home>/bin`, or nil when any
    /// declaration is not a basename. Validation completes before filesystem
    /// access so one hostile entry cannot escape the owned Cargo directory.
    private func validatedBinPaths(_ bins: [String]?) throws -> [URL]? {
        guard let bins else { return [] }
        let binDirectory = cargoHome.appendingPathComponent("bin")
        var paths: [URL] = []
        paths.reserveCapacity(bins.count)

        for bin in bins {
            try Task.checkCancellation()
            guard isSafeBinBasename(bin) else { return nil }
            paths.append(binDirectory.appendingPathComponent(bin))
        }
        return paths
    }

    private func isSafeBinBasename(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.unicodeScalars.contains(where: { $0.value == 0 })
            && NSString(string: name).lastPathComponent == name
    }

    /// Cargo install keys look like:
    /// `ripgrep 14.1.0 (registry+https://github.com/rust-lang/crates.io-index)`.
    private func parseInstallKey(
        _ key: String
    ) -> (name: String, version: String, source: String?)? {
        let packageAndVersion: String
        let source: String?
        if key.hasSuffix(")"),
           let sourceRange = key.range(of: " (", options: .backwards) {
            packageAndVersion = String(key[..<sourceRange.lowerBound])
            let sourceStart = sourceRange.upperBound
            let sourceEnd = key.index(before: key.endIndex)
            let parsedSource = String(key[sourceStart..<sourceEnd])
            guard !parsedSource.isEmpty else { return nil }
            source = parsedSource
        } else if key.contains(" (") {
            return nil
        } else {
            packageAndVersion = key
            source = nil
        }

        let parts = packageAndVersion.split(separator: " ")
        guard parts.count >= 2, let version = parts.last else { return nil }
        let name = parts.dropLast().joined(separator: " ")
        guard !name.isEmpty else { return nil }
        return (name, String(version), source)
    }
}

private struct CargoCratesMetadata: Decodable, Sendable {
    let installs: [String: CargoInstall]
}

private struct CargoInstall: Decodable, Sendable {
    let bins: [String]?
}
