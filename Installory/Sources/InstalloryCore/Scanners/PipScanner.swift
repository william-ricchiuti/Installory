import Foundation

/// Scans Python packages by walking `*.dist-info` directories inside each
/// interpreter's `site-packages` directories.
///
/// No Python or `pip` invocation is made. All data comes from reading
/// `METADATA`, `RECORD`, `INSTALLER`, and `REQUESTED` files directly.
///
/// Each interpreter's packages are tagged with the interpreter's executable
/// path as `qualifier`, so `requests` installed under pyenv 3.11 and
/// `requests` installed under Homebrew 3.12 are two distinct `Package` rows.
public struct PipScanner: PackageScanner, Sendable {
    public let manager: PackageManager = .pip

    private let discovery: PythonInterpreterDiscovery
    private let denials = PermissionDenialRecorder()
    private let parser: DistInfoParser
    private let directoryAccess: any DirectoryAccessProvider

    public init(
        discovery: PythonInterpreterDiscovery = PythonInterpreterDiscovery(),
        parser: DistInfoParser = DistInfoParser(),
        directoryAccess: any DirectoryAccessProvider = SystemDirectoryAccessProvider()
    ) {
        self.discovery = discovery
        self.parser = parser
        self.directoryAccess = directoryAccess
    }

    // MARK: - PackageScanner

    public func isAvailable() async -> Bool {
        guard !Task.isCancelled else { return false }
        let isAvailable = !discovery.discover().isEmpty
        return !Task.isCancelled && isAvailable
    }

    public func scan() async throws -> [Package] {
        try Task.checkCancellation()
        denials.reset()
        var seen: Set<String> = []
        var packages: [Package] = []
        var sizer = BoundedDirectorySizer(directoryAccess: directoryAccess)
        let interpreters = discovery.discover()
        try Task.checkCancellation()
        for interpreter in interpreters {
            try Task.checkCancellation()
            let found = try await packagesFor(interpreter: interpreter, sizer: &sizer)
            packages += found.filter { seen.insert($0.id).inserted }
        }
        try Task.checkCancellation()
        if packages.isEmpty, discovery.sawPermissionDenial {
            denials.recordDenial()
        }
        try denials.throwIfNothingFoundBecauseDenied(foundNothing: packages.isEmpty)
        return packages
    }

    // MARK: - Private

    private func packagesFor(
        interpreter: PythonInterpreter,
        sizer: inout BoundedDirectorySizer
    ) async throws -> [Package] {
        try Task.checkCancellation()
        var packages: [Package] = []
        for sitePackages in interpreter.sitePackages.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            packages += try await packagesIn(
                sitePackages: sitePackages,
                interpreter: interpreter,
                sizer: &sizer
            )
        }
        try Task.checkCancellation()
        return packages
    }

    private func packagesIn(
        sitePackages: URL,
        interpreter: PythonInterpreter,
        sizer: inout BoundedDirectorySizer
    ) async throws -> [Package] {
        try Task.checkCancellation()
        let entries = denials.contents(of: sitePackages, using: directoryAccess)
        try Task.checkCancellation()
        var packages: [Package] = []
        for entry in entries.sorted(by: { $0.path < $1.path })
            where entry.lastPathComponent.hasSuffix(".dist-info") {
            try Task.checkCancellation()
            if let package = try await makePackage(
                distInfoDir: entry,
                sitePackages: sitePackages,
                interpreter: interpreter,
                sizer: &sizer
            ) {
                packages.append(package)
            }
        }
        try Task.checkCancellation()
        return packages
    }

    private func makePackage(
        distInfoDir: URL,
        sitePackages: URL,
        interpreter: PythonInterpreter,
        sizer: inout BoundedDirectorySizer
    ) async throws -> Package? {
        let distInfo: DistInfo
        do {
            distInfo = try parser.parse(directory: distInfoDir)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        try Task.checkCancellation()

        let executablePath = interpreter.executable.path
        let deps = distInfo.requiresDist.map(PythonRequirement.distributionName)
        let sizeRoots = try safeRecordRoots(
            distInfo.recordPaths,
            sitePackages: sitePackages,
            interpreter: interpreter
        )
        let sizeBytes: Int64?
        if let sizeRoots, !sizeRoots.isEmpty {
            let installRoot = interpreter.executable
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            sizeBytes = try await sizer.measure(
                sizeRoots,
                constrainedTo: installRoot
            ).sizeBytes
        } else {
            sizeBytes = nil
        }

        return Package(
            id: "pip:\(executablePath):\(distInfo.name)",
            manager: .pip,
            qualifier: executablePath,
            name: distInfo.name,
            version: distInfo.version,
            installPath: distInfoDir,
            installedAt: directoryAccess.modificationDate(at: distInfoDir),
            installedAtConfidence: .medium,
            sizeBytes: sizeBytes,
            isExplicit: Self.isExplicit(distInfo),
            isReadOnly: interpreter.isSystem || Self.isOwnedByHomebrew(distInfo),
            dependencies: deps,
            lastSeen: Date()
        )
    }

    /// Converts RECORD ownership entries into bounded file measurements. Relative
    /// `..` components are allowed only while they remain inside this interpreter's
    /// installation root (for example `../../../bin/tool`). Absolute paths and any
    /// escaping entry invalidate the whole measurement before filesystem access.
    private func safeRecordRoots(
        _ recordPaths: [String],
        sitePackages: URL,
        interpreter: PythonInterpreter
    ) throws -> [SizeRoot]? {
        guard !recordPaths.isEmpty else { return nil }
        let installRoot = interpreter.executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
        let resolvedInstallRoot = directoryAccess
            .resolvingSymlinks(at: installRoot)
            .standardizedFileURL
        var seen: Set<String> = []
        var roots: [SizeRoot] = []

        for recordPath in recordPaths {
            try Task.checkCancellation()
            guard !(recordPath as NSString).isAbsolutePath,
                  !recordPath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { return nil }

            let candidate = sitePackages
                .appendingPathComponent(recordPath, isDirectory: false)
                .standardizedFileURL
            guard Self.isContained(candidate, in: installRoot) else { return nil }
            let resolvedCandidate = directoryAccess
                .resolvingSymlinks(at: candidate)
                .standardizedFileURL
            guard Self.isContained(resolvedCandidate, in: resolvedInstallRoot) else {
                return nil
            }
            if seen.insert(candidate.path).inserted {
                roots.append(.file(candidate))
            }
        }
        try Task.checkCancellation()
        return roots
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count >= rootComponents.count
            && candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    /// Homebrew installs some Python packages itself (for example `certifi`,
    /// `cffi`, `cryptography`, `pip` and `wheel` inside its Python formulae) and
    /// marks them with `INSTALLER` = `brew`. They belong to a formula, so
    /// removing them with pip would break it; treat them like system packages.
    static func isOwnedByHomebrew(_ distInfo: DistInfo) -> Bool {
        distInfo.installer?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "brew"
    }

    /// Applies pip's `REQUESTED` marker contract without turning ambiguous
    /// legacy metadata into false dependency claims.
    ///
    /// Current pip writes `REQUESTED` for user-supplied requirements and omits
    /// it for dependencies, so absence is meaningful when `INSTALLER` says
    /// `pip`. Other installers do not necessarily follow that convention, and
    /// older metadata may omit `INSTALLER` entirely. Those unknown cases stay
    /// explicit: a false positive here merely asks the user to review a package,
    /// while a false dependency classification can hide it from cleanup review.
    private static func isExplicit(_ distInfo: DistInfo) -> Bool {
        if distInfo.requestedMarkerPresent { return true }
        if distInfo.installer?.lowercased() == "pip" { return false }
        return true
    }
}
