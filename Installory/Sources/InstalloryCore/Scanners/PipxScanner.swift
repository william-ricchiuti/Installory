import Foundation

/// Scans pipx-managed command-line tools by reading each venv under
/// `~/.local/share/pipx/venvs`.
///
/// pipx keeps one tool per virtual environment. Installory reports the main
/// package for each venv, not every dependency inside that venv.
public struct PipxScanner: PackageScanner, Sendable {
    public let manager: PackageManager = .pipx

    private let directoryAccess: any DirectoryAccessProvider
    private let parser: DistInfoParser
    private let homeDirectory: URL
    private let environment: PackageManagerEnvironment

    public init(
        directoryAccess: any DirectoryAccessProvider = SystemDirectoryAccessProvider(),
        parser: DistInfoParser? = nil,
        homeDirectory: URL = UserHome.directory,
        environment: PackageManagerEnvironment = .current
    ) {
        self.directoryAccess = directoryAccess
        self.parser = parser ?? DistInfoParser(directoryAccess: directoryAccess)
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    public func isAvailable() async -> Bool {
        guard !Task.isCancelled else { return false }
        let isAvailable = directoryAccess.fileExists(at: venvsRoot)
        return !Task.isCancelled && isAvailable
    }

    public var unavailableReason: String {
        "pipx venv directory not granted or not found"
    }

    public func scan() async throws -> [Package] {
        try Task.checkCancellation()
        var sizer = BoundedDirectorySizer(directoryAccess: directoryAccess)
        var packages: [Package] = []
        for venv in directoryAccess.directoryContentsOrEmpty(at: venvsRoot)
            .sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            if let package = try await packageForToolVenv(venv, sizer: &sizer) {
                packages.append(package)
            }
        }
        try Task.checkCancellation()
        return packages
    }

    private var venvsRoot: URL {
        environment.pipxHome(
            fallback: homeDirectory
                .appendingPathComponent(".local")
                .appendingPathComponent("share")
                .appendingPathComponent("pipx")
        )
            .appendingPathComponent("venvs")
    }

    private func packageForToolVenv(
        _ venvDir: URL,
        sizer: inout BoundedDirectorySizer
    ) async throws -> Package? {
        try Task.checkCancellation()
        let toolName = venvDir.lastPathComponent
        guard !toolName.hasPrefix(".") else { return nil }

        var distInfos: [(directory: URL, info: DistInfo)] = []
        for sitePackages in try sitePackagesDirs(in: venvDir) {
            try Task.checkCancellation()
            distInfos.append(contentsOf: try parsedDistInfos(in: sitePackages))
        }

        let metadata = pipxMetadata(in: venvDir)
        try Task.checkCancellation()
        let selected = selectMainPackage(
            from: distInfos,
            toolName: toolName,
            metadataName: metadata?.packageName
        )

        if let selected {
            return try await makePackage(
                name: selected.info.name,
                version: selected.info.version,
                dependencies: selected.info.requiresDist.map(PythonRequirement.distributionName),
                distInfoDir: selected.directory,
                venvDir: venvDir,
                sizer: &sizer
            )
        }

        guard let metadata, let packageName = metadata.packageName, let version = metadata.packageVersion else {
            return nil
        }

        return try await makePackage(
            name: packageName,
            version: version,
            dependencies: [],
            distInfoDir: nil,
            venvDir: venvDir,
            sizer: &sizer
        )
    }

    private func sitePackagesDirs(in venvDir: URL) throws -> [URL] {
        try Task.checkCancellation()
        let lib = venvDir.appendingPathComponent("lib")
        var result: [URL] = []
        let children = directoryAccess.directoryContentsOrEmpty(at: lib)
            .sorted(by: { $0.path < $1.path })
        try Task.checkCancellation()
        for child in children {
            try Task.checkCancellation()
            guard child.lastPathComponent.hasPrefix("python") else { continue }
            let sitePackages = child.appendingPathComponent("site-packages")
            if directoryAccess.fileExists(at: sitePackages) {
                result.append(sitePackages)
            }
        }
        try Task.checkCancellation()
        return result
    }

    private func parsedDistInfos(
        in sitePackages: URL
    ) throws -> [(directory: URL, info: DistInfo)] {
        try Task.checkCancellation()
        var result: [(directory: URL, info: DistInfo)] = []
        let directories = directoryAccess.directoryContentsOrEmpty(at: sitePackages)
            .sorted(by: { $0.path < $1.path })
        try Task.checkCancellation()
        for directory in directories {
            try Task.checkCancellation()
            guard directory.lastPathComponent.hasSuffix(".dist-info") else { continue }
            do {
                let info = try parser.parseMetadataOnly(directory: directory)
                result.append((directory, info))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        try Task.checkCancellation()
        return result
    }

    private func selectMainPackage(
        from distInfos: [(directory: URL, info: DistInfo)],
        toolName: String,
        metadataName: String?
    ) -> (directory: URL, info: DistInfo)? {
        if let metadataName {
            let normalized = Self.normalizePackageName(metadataName)
            if let match = distInfos.first(where: { Self.normalizePackageName($0.info.name) == normalized }) {
                return match
            }
        }

        let normalizedTool = Self.normalizePackageName(toolName)
        if let match = distInfos.first(where: { Self.normalizePackageName($0.info.name) == normalizedTool }) {
            return match
        }

        return distInfos.count == 1 ? distInfos[0] : nil
    }

    private func makePackage(
        name: String,
        version: String,
        dependencies: [String],
        distInfoDir: URL?,
        venvDir: URL,
        sizer: inout BoundedDirectorySizer
    ) async throws -> Package {
        // `pipx --suffix` creates multiple environment directories whose main
        // distribution metadata can have the same name and version. Preserve
        // the full discovered environment path as the qualifier so identity is
        // unique across both suffixes and pipx homes, while `name` remains the
        // human-facing distribution name.
        let qualifier = venvDir.path
        let sizeBytes = try await sizer.measure(
            [.tree(venvDir)],
            constrainedTo: venvsRoot
        ).sizeBytes
        return Package(
            id: "pipx:\(qualifier):\(name)",
            manager: .pipx,
            qualifier: qualifier,
            name: name,
            version: version,
            installPath: venvDir,
            installedAt: directoryAccess.modificationDate(at: distInfoDir ?? venvDir),
            installedAtConfidence: .medium,
            sizeBytes: sizeBytes,
            isExplicit: true,
            isReadOnly: false,
            dependencies: dependencies,
            lastSeen: Date()
        )
    }

    private func pipxMetadata(in venvDir: URL) -> PipxMetadata? {
        let url = venvDir.appendingPathComponent("pipx_metadata.json")
        guard let data = try? directoryAccess.data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PipxMetadata.self, from: data)
    }

    private static func normalizePackageName(_ name: String) -> String {
        var out = ""
        var previousWasSeparator = false
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                out.append("-")
                previousWasSeparator = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

private struct PipxMetadata: Decodable, Sendable {
    let mainPackage: MainPackage?

    var packageName: String? {
        mainPackage?.package?.nilIfBlank ?? mainPackage?.packageOrURL?.nilIfBlank
    }

    var packageVersion: String? {
        mainPackage?.packageVersion?.nilIfBlank
    }

    enum CodingKeys: String, CodingKey {
        case mainPackage = "main_package"
    }

    struct MainPackage: Decodable, Sendable {
        let package: String?
        let packageOrURL: String?
        let packageVersion: String?

        enum CodingKeys: String, CodingKey {
            case package
            case packageOrURL = "package_or_url"
            case packageVersion = "package_version"
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
