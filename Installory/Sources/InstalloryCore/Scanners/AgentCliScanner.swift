import Foundation

/// Discovers the configuration roots of installed agent CLIs.
///
/// Each candidate is the per-tool config directory a coding agent creates in
/// the user's home directory. Discovery is purely additive: candidates that do
/// not exist as directories are ignored, and duplicates are removed.
///
/// Granted URLs contribute in two ways, mirroring how skill discovery treats
/// granted roots: a granted folder that is itself a recognized agent config
/// root (for example a directly granted `~/.codex`) is used as-is, and a
/// granted folder that contains the recognized config roots at the same
/// relative locations as a home directory (for example a granted home folder)
/// contributes those children. Project-level `.claude` folders inside granted
/// project directories are deliberately not treated as CLI installs: they hold
/// per-project settings, not an installed agent.
struct AgentCliDiscovery {
    static let relativeConfigRoots = [".claude", ".codex", ".config/opencode", ".cursor"]

    static func cliRoots(
        homeDirectory: URL,
        grantedURLs: [URL] = [],
        directoryAccess: any DirectoryAccessProvider
    ) -> [URL] {
        var candidates: [URL] = []
        for relative in relativeConfigRoots {
            candidates.append(homeDirectory.appendingPathComponent(relative, isDirectory: true))
        }
        for granted in grantedURLs {
            let standardized = granted.standardizedFileURL
            if AgentCliScanner.cliName(for: standardized).isEmpty {
                if isHomeLike(standardized, comparedTo: homeDirectory) {
                    for relative in relativeConfigRoots {
                        candidates.append(standardized.appendingPathComponent(relative, isDirectory: true))
                    }
                }
            } else {
                candidates.append(standardized)
            }
        }

        var seen: Set<String> = []
        var roots: [URL] = []
        for candidate in candidates {
            let standardized = candidate.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            guard directoryAccess.fileExists(at: standardized),
                  let metadata = try? directoryAccess.metadata(at: standardized),
                  metadata.kind == .directory else { continue }
            roots.append(standardized)
        }
        return roots.sorted { $0.path < $1.path }
    }

    /// A granted folder is treated as a home directory only when it is the
    /// home directory itself (possibly reached through a different spelling,
    /// such as a symlinked volume path) — never an arbitrary project folder.
    private static func isHomeLike(_ granted: URL, comparedTo homeDirectory: URL) -> Bool {
        let home = homeDirectory.standardizedFileURL
        if granted.path == home.path { return true }
        return granted.resolvingSymlinksInPath().path == home.resolvingSymlinksInPath().path
    }
}

/// Inventories installed agent CLIs — the coding agents whose configuration
/// lives in the user's home directory.
///
/// Each discovered config root becomes a single `.agentCli` package row. The
/// scanner is filesystem-only and never executes an agent CLI or shell command.
/// Versions are best-effort: a `package.json` or plain `version` marker file in
/// the root is read when present, otherwise the row carries an empty version.
public struct AgentCliScanner: PackageScanner, Sendable {
    public struct Limits: Sendable, Equatable {
        public let maximumCliRoots: Int
        public let maximumRootEntries: Int
        public let maximumConfigBytes: Int

        public init(
            maximumCliRoots: Int = 16,
            maximumRootEntries: Int = 200_000,
            maximumConfigBytes: Int = 512 * 1_024
        ) {
            self.maximumCliRoots = maximumCliRoots
            self.maximumRootEntries = maximumRootEntries
            self.maximumConfigBytes = maximumConfigBytes
        }

        public static let `default` = Limits()
    }

    public let manager: PackageManager = .agentCli

    private let cliRoots: [URL]
    private let directoryAccess: any DirectoryAccessProvider
    private let limits: Limits
    private let directorySizeLimits: DirectorySizeLimits
    private let now: @Sendable () -> Date

    /// Discovers and uses every existing agent CLI config root under the user's
    /// home directory, plus granted folders that are themselves agent config
    /// roots (see ``AgentCliDiscovery``).
    public init(
        homeDirectory: URL,
        environment: PackageManagerEnvironment = .current,
        grantedURLs: [URL] = [],
        directoryAccess: any DirectoryAccessProvider = SystemDirectoryAccessProvider(),
        limits: Limits = .default,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        let roots = AgentCliDiscovery.cliRoots(
            homeDirectory: homeDirectory,
            grantedURLs: grantedURLs,
            directoryAccess: directoryAccess
        )
        self.init(
            cliRoots: roots,
            directoryAccess: directoryAccess,
            limits: limits,
            directorySizeLimits: .default,
            now: now
        )
    }

    /// Uses exactly the given CLI config roots (no discovery).
    public init(
        cliRoots: [URL],
        directoryAccess: any DirectoryAccessProvider = SystemDirectoryAccessProvider(),
        limits: Limits = .default,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.init(
            cliRoots: cliRoots,
            directoryAccess: directoryAccess,
            limits: limits,
            directorySizeLimits: .default,
            now: now
        )
    }

    init(
        cliRoots: [URL],
        directoryAccess: any DirectoryAccessProvider,
        limits: Limits,
        directorySizeLimits: DirectorySizeLimits,
        now: @Sendable @escaping () -> Date
    ) {
        self.cliRoots = cliRoots
        self.directoryAccess = directoryAccess
        self.limits = limits
        self.directorySizeLimits = directorySizeLimits
        self.now = now
    }

    public func isAvailable() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard !cliRoots.isEmpty, cliRoots.count <= limits.maximumCliRoots else {
            return false
        }
        for root in cliRoots {
            guard !Task.isCancelled else { return false }
            guard directoryAccess.fileExists(at: root),
                  let metadata = try? directoryAccess.metadata(at: root),
                  metadata.kind == .directory else {
                continue
            }
            return !Task.isCancelled
        }
        return false
    }

    public var unavailableReason: String {
        "No agent CLI config directory found or granted"
    }

    public func scan() async throws -> [Package] {
        try Task.checkCancellation()
        guard cliRoots.count <= limits.maximumCliRoots else {
            throw AgentCliScannerError.tooManyCliRoots(cliRoots.count)
        }

        let observationDate = now()
        var sizer = BoundedDirectorySizer(
            directoryAccess: directoryAccess,
            limits: directorySizeLimits
        )
        var packages: [Package] = []

        for (rootIndex, root) in cliRoots.enumerated() {
            try await checkpoint(rootIndex)
            let cliName = Self.cliName(for: root)
            guard !cliName.isEmpty else { continue }

            let measuredSize = try await sizer.measure(
                [.tree(root)],
                constrainedTo: root
            ).sizeBytes
            let version = try? bestEffortVersion(for: root)

            packages.append(Package(
                id: id(root: root, name: cliName),
                manager: .agentCli,
                qualifier: root.path,
                name: cliName,
                version: version ?? "",
                installPath: root,
                installedAt: directoryAccess.modificationDate(at: root),
                installedAtConfidence: .medium,
                sizeBytes: measuredSize,
                isExplicit: true,
                isReadOnly: false,
                dependencies: [],
                artifactPaths: nil,
                lastSeen: observationDate
            ))
        }

        try Task.checkCancellation()
        return packages
    }

    /// Maps a config root path to the canonical CLI name, or nil when the root
    /// is not a recognized agent config directory.
    static func cliName(for root: URL) -> String {
        let path = root.standardizedFileURL.path
        if path.hasSuffix("/.claude") { return "claude" }
        if path.hasSuffix("/.codex") { return "codex" }
        if path.hasSuffix("/.config/opencode") { return "opencode" }
        if path.hasSuffix("/.cursor") { return "cursor" }
        return ""
    }

    /// Best-effort version: reads `package.json` (the `version` field) or a
    /// plain `version` marker file in the config root, both bounded.
    private func bestEffortVersion(for root: URL) throws -> String? {
        let packageJSON = root.appendingPathComponent("package.json")
        if directoryAccess.fileExists(at: packageJSON),
           let data = try? boundedRegularFile(
               at: packageJSON,
               maximumBytes: limits.maximumConfigBytes,
               containedIn: root
           ),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = object["version"] as? String, !version.isEmpty {
            return version
        }

        let versionMarker = root.appendingPathComponent("version")
        if directoryAccess.fileExists(at: versionMarker),
           let data = try? boundedRegularFile(
               at: versionMarker,
               maximumBytes: 4 * 1_024,
               containedIn: root
           ),
           let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private func id(root: URL, name: String) -> String {
        "\(manager.rawValue):\(root.path):\(name)"
    }

    private func boundedRegularFile(
        at url: URL,
        maximumBytes: Int,
        containedIn root: URL
    ) throws -> Data {
        try Task.checkCancellation()
        let standardized = url.standardizedFileURL
        let resolved = directoryAccess
            .resolvingSymlinks(at: standardized)
            .standardizedFileURL
        guard Self.isContained(resolved, in: root) else {
            throw AgentCliScannerError.unsafePath(standardized)
        }

        let metadata = try directoryAccess.metadata(at: standardized)
        guard metadata.kind == .regularFile,
              let logicalSize = metadata.logicalSizeBytes,
              logicalSize >= 0,
              maximumBytes >= 0,
              logicalSize <= Int64(maximumBytes) else {
            throw AgentCliScannerError.configExceedsLimit(standardized)
        }

        let data: Data
        do {
            data = try directoryAccess.data(
                contentsOf: standardized,
                maximumBytes: maximumBytes,
                from: .prefix
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AgentCliScannerError.configExceedsLimit(standardized)
        }
        try Task.checkCancellation()
        guard data.count <= maximumBytes, Int64(data.count) == logicalSize else {
            throw AgentCliScannerError.configExceedsLimit(standardized)
        }
        return data
    }

    private func checkpoint(_ index: Int) async throws {
        try Task.checkCancellation()
        if index > 0, index.isMultiple(of: 32) {
            await Task.yield()
            try Task.checkCancellation()
        }
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count >= rootComponents.count
            && candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }
}

enum AgentCliScannerError: Swift.Error, Equatable, Sendable {
    case unsafePath(URL)
    case configExceedsLimit(URL)
    case tooManyCliRoots(Int)
}
