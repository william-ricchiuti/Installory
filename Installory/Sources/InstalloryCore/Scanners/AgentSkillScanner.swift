import Foundation

/// Discovers the directories that may contain agent skills.
///
/// Skill roots are tool-specific (Claude Code, opencode, shared `~/.agents`)
/// plus project-level `.claude/skills` and `.agents/skills` directories inside
/// directories the user has granted access to. Discovery is purely additive:
/// candidates that do not exist as directories are ignored, and duplicates are
/// removed.
struct AgentSkillDiscovery {
    static func skillRoots(
        homeDirectory: URL,
        grantedURLs: [URL],
        directoryAccess: any DirectoryAccessProvider
    ) -> [URL] {
        var candidates: [URL] = []
        for relative in [".claude/skills", ".agents/skills", ".config/opencode/skills", ".opencode/skills"] {
            candidates.append(homeDirectory.appendingPathComponent(relative, isDirectory: true))
        }
        for granted in grantedURLs {
            candidates.append(granted.appendingPathComponent(".claude/skills", isDirectory: true))
            candidates.append(granted.appendingPathComponent(".agents/skills", isDirectory: true))
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
}

/// Inventories agent skills — directories and symlinks under an agent's skills
/// root that describe reusable capabilities.
///
/// The scanner is filesystem-only and never executes an agent CLI or shell
/// command. Every skill becomes a `.agentSkill` package row whose qualifier is
/// the owning tool root. Skills are plain leaf entries, so no dependency
/// parsing is performed; see ``AgentStackAnalysis`` for review aggregation.
public struct AgentSkillScanner: PackageScanner, Sendable {
    public struct Limits: Sendable, Equatable {
        public let maximumSkillRoots: Int
        public let maximumSkillsPerRoot: Int
        public let maximumManifestBytes: Int

        public init(
            maximumSkillRoots: Int = 64,
            maximumSkillsPerRoot: Int = 5_000,
            maximumManifestBytes: Int = 64 * 1_024
        ) {
            self.maximumSkillRoots = maximumSkillRoots
            self.maximumSkillsPerRoot = maximumSkillsPerRoot
            self.maximumManifestBytes = maximumManifestBytes
        }

        public static let `default` = Limits()
    }

    public let manager: PackageManager = .agentSkill

    private let skillRoots: [URL]
    private let directoryAccess: any DirectoryAccessProvider
    private let limits: Limits
    private let directorySizeLimits: DirectorySizeLimits
    private let now: @Sendable () -> Date

    /// Discovers and uses every granted/existing agent skills root under the
    /// user's home directory plus project-level skills roots inside granted URLs.
    public init(
        homeDirectory: URL,
        environment: PackageManagerEnvironment = .current,
        grantedURLs: [URL] = [],
        directoryAccess: any DirectoryAccessProvider = SystemDirectoryAccessProvider(),
        limits: Limits = .default,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        let roots = AgentSkillDiscovery.skillRoots(
            homeDirectory: homeDirectory,
            grantedURLs: grantedURLs,
            directoryAccess: directoryAccess
        )
        self.init(
            skillRoots: roots,
            directoryAccess: directoryAccess,
            limits: limits,
            directorySizeLimits: .default,
            now: now
        )
    }

    /// Uses exactly the given skill roots (no discovery).
    public init(
        skillRoots: [URL],
        directoryAccess: any DirectoryAccessProvider = SystemDirectoryAccessProvider(),
        limits: Limits = .default,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.init(
            skillRoots: skillRoots,
            directoryAccess: directoryAccess,
            limits: limits,
            directorySizeLimits: .default,
            now: now
        )
    }

    init(
        skillRoots: [URL],
        directoryAccess: any DirectoryAccessProvider,
        limits: Limits,
        directorySizeLimits: DirectorySizeLimits,
        now: @Sendable @escaping () -> Date
    ) {
        self.skillRoots = skillRoots
        self.directoryAccess = directoryAccess
        self.limits = limits
        self.directorySizeLimits = directorySizeLimits
        self.now = now
    }

    public func isAvailable() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard !skillRoots.isEmpty, skillRoots.count <= limits.maximumSkillRoots else {
            return false
        }
        for root in skillRoots {
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
        "No agent skills directory found or granted"
    }

    public func scan() async throws -> [Package] {
        try Task.checkCancellation()
        guard skillRoots.count <= limits.maximumSkillRoots else {
            throw AgentSkillScannerError.tooManySkillRoots(skillRoots.count)
        }

        let observationDate = now()
        var sizer = BoundedDirectorySizer(
            directoryAccess: directoryAccess,
            limits: directorySizeLimits
        )
        var packages: [Package] = []
        var seenSkillPaths: Set<String> = []

        for (rootIndex, root) in skillRoots.enumerated() {
            try await checkpoint(rootIndex)
            let rootChildren = try directoryAccess.contentsOfDirectory(at: root)
            try Task.checkCancellation()
            guard rootChildren.count <= limits.maximumSkillsPerRoot else {
                throw AgentSkillScannerError.tooManySkillsPerRoot(root)
            }

            for (index, child) in rootChildren
                .sorted(by: { $0.standardizedFileURL.path < $1.standardizedFileURL.path })
                .enumerated() {
                try await checkpoint(index)
                let candidate = child.standardizedFileURL
                guard Self.isDirectChild(candidate, of: root) else {
                    throw AgentSkillScannerError.unsafePath(candidate)
                }
                let name = candidate.lastPathComponent
                // Skip hidden entries and the conventional "skills.disabled" bucket.
                guard !name.hasPrefix("."), name != "skills.disabled" else { continue }

                let metadata = try directoryAccess.metadata(at: candidate)
                try Task.checkCancellation()
                switch metadata.kind {
                case .regularFile, .other:
                    continue
                case .symbolicLink:
                    packages.append(symlinkPackage(
                        link: candidate,
                        in: root,
                        observationDate: observationDate
                    ))
                case .directory:
                    let skillDirectory = try realDirectory(
                        at: candidate,
                        containedIn: root,
                        directChildOf: root
                    )
                    guard seenSkillPaths.insert(skillDirectory.path).inserted else {
                        throw AgentSkillScannerError.unsafePath(skillDirectory)
                    }
                    packages.append(
                        try await directoryPackage(
                            for: skillDirectory,
                            in: root,
                            observationDate: observationDate,
                            sizer: &sizer
                        )
                    )
                }
            }
        }

        try Task.checkCancellation()
        return packages
    }

    /// Builds a row for a symbolic-link skill entry.
    ///
    /// The link itself is the inventory path. Its resolved target is recorded
    /// in `artifactPaths` so the UI can show where it points.
    private func symlinkPackage(
        link: URL,
        in root: URL,
        observationDate: Date
    ) -> Package {
        let resolved = directoryAccess
            .resolvingSymlinks(at: link)
            .standardizedFileURL
        let targetIsReachable = directoryAccess.fileExists(at: link)
        let artifactPaths = [resolved.path]

        // A dangling symlink cannot be reached through `installPath` (the target
        // is missing), so `installPath` is nil while `artifactPaths` still
        // records where the link points. `AgentStackAnalysis` flags the row as
        // broken by the combination of nil `installPath` and non-empty
        // `artifactPaths`.
        return Package(
            id: id(root: root, name: link.lastPathComponent),
            manager: .agentSkill,
            qualifier: root.path,
            name: link.lastPathComponent,
            version: "",
            installPath: targetIsReachable ? link : nil,
            installedAt: directoryAccess.modificationDate(at: link),
            installedAtConfidence: .medium,
            sizeBytes: nil,
            isExplicit: true,
            isReadOnly: false,
            dependencies: [],
            artifactPaths: artifactPaths,
            lastSeen: observationDate
        )
    }

    /// Builds a row for a real skill directory.
    ///
    /// A directory with a readable `SKILL.md` becomes a full row. A directory
    /// without a manifest is still inventoried (so it shows up for review) with
    /// a nil `installPath`, which ``AgentStackAnalysis`` classifies as missing
    /// a manifest.
    private func directoryPackage(
        for skillDirectory: URL,
        in root: URL,
        observationDate: Date,
        sizer: inout BoundedDirectorySizer
    ) async throws -> Package {
        try Task.checkCancellation()
        let manifestURL = skillDirectory.appendingPathComponent("SKILL.md")
        let manifest = try? boundedRegularFile(
            at: manifestURL,
            maximumBytes: limits.maximumManifestBytes,
            containedIn: root
        )
        try Task.checkCancellation()

        let measuredSize = try await sizer.measure(
            [.tree(skillDirectory)],
            constrainedTo: root
        ).sizeBytes

        let frontmatter = manifest.map(SkillManifestParser.parse)
        return Package(
            id: id(root: root, name: skillDirectory.lastPathComponent),
            manager: .agentSkill,
            qualifier: root.path,
            name: skillDirectory.lastPathComponent,
            version: frontmatter?.version ?? "",
            installPath: manifest == nil ? nil : skillDirectory,
            installedAt: directoryAccess.modificationDate(at: skillDirectory),
            installedAtConfidence: .medium,
            sizeBytes: measuredSize,
            isExplicit: true,
            isReadOnly: false,
            dependencies: [],
            artifactPaths: nil,
            lastSeen: observationDate,
            summary: frontmatter?.summary
        )
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
            throw AgentSkillScannerError.unsafePath(standardized)
        }

        let metadata = try directoryAccess.metadata(at: standardized)
        guard metadata.kind == .regularFile,
              let logicalSize = metadata.logicalSizeBytes,
              logicalSize >= 0,
              maximumBytes >= 0,
              logicalSize <= Int64(maximumBytes) else {
            throw AgentSkillScannerError.manifestExceedsLimit(standardized)
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
            throw AgentSkillScannerError.manifestExceedsLimit(standardized)
        }
        try Task.checkCancellation()
        guard data.count <= maximumBytes, Int64(data.count) == logicalSize else {
            throw AgentSkillScannerError.manifestExceedsLimit(standardized)
        }
        return data
    }

    private func realDirectory(
        at url: URL,
        containedIn root: URL,
        directChildOf expectedParent: URL? = nil
    ) throws -> URL {
        try Task.checkCancellation()
        let standardized = url.standardizedFileURL
        if let expectedParent,
           !Self.isDirectChild(standardized, of: expectedParent.standardizedFileURL) {
            throw AgentSkillScannerError.unsafePath(standardized)
        }

        let metadata = try directoryAccess.metadata(at: standardized)
        guard metadata.kind == .directory else {
            throw AgentSkillScannerError.unsafePath(standardized)
        }
        let resolved = directoryAccess
            .resolvingSymlinks(at: standardized)
            .standardizedFileURL
        guard Self.isContained(resolved, in: root) else {
            throw AgentSkillScannerError.unsafePath(standardized)
        }
        if let expectedParent,
           !Self.isDirectChild(resolved, of: expectedParent.standardizedFileURL) {
            throw AgentSkillScannerError.unsafePath(standardized)
        }
        return resolved
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

    private static func isDirectChild(_ candidate: URL, of parent: URL) -> Bool {
        candidate.standardizedFileURL.deletingLastPathComponent().standardizedFileURL.path
            == parent.standardizedFileURL.path
    }
}

enum AgentSkillScannerError: Swift.Error, Equatable, Sendable {
    case unsafePath(URL)
    case manifestExceedsLimit(URL)
    case tooManySkillRoots(Int)
    case tooManySkillsPerRoot(URL)
}

/// Minimal YAML frontmatter parser for `SKILL.md` manifests.
///
/// Only the `name`, `description`, and `version` scalar keys in the opening
/// `---` block are extracted. Values may be bare or single/double-quoted, or a
/// folded/literal block scalar (`>` / `|`) whose indented lines are joined
/// with spaces; lists are ignored.
enum SkillManifestParser {
    /// Upper bound on a stored skill summary, so a runaway frontmatter value
    /// cannot bloat the inventory row.
    static let maximumSummaryCharacters = 500

    struct Manifest: Sendable, Equatable {
        var name: String?
        var description: String?
        var version: String?

        /// The description as a single trimmed line suitable for display, or
        /// nil when absent or blank.
        var summary: String? {
            guard let description else { return nil }
            let collapsed = description
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !collapsed.isEmpty else { return nil }
            if collapsed.count > SkillManifestParser.maximumSummaryCharacters {
                return String(collapsed.prefix(SkillManifestParser.maximumSummaryCharacters - 1)) + "…"
            }
            return collapsed
        }
    }

    static func parse(_ data: Data) -> Manifest {
        guard let text = String(data: data, encoding: .utf8) else { return Manifest() }
        return parse(text)
    }

    static func parse(_ text: String) -> Manifest {
        var lines = text.components(separatedBy: .newlines)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return Manifest()
        }
        lines.removeFirst()

        var manifest = Manifest()
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            var value = trimmed[trimmed.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if let comment = value.range(of: " #") {
                value = String(value[..<comment.lowerBound])
            }
            value = value.trimmingCharacters(in: .whitespaces)

            if ["|", ">", "|-", ">-", "|+", ">+"].contains(value) {
                // Block scalar: consume the following indented lines.
                var parts: [String] = []
                while index < lines.count {
                    let next = lines[index]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.isEmpty { index += 1; continue }
                    guard next.first == " " || next.first == "\t" else { break }
                    parts.append(nextTrimmed)
                    index += 1
                }
                value = parts.joined(separator: " ")
            }

            switch key {
            case "name": manifest.name = value
            case "description": manifest.description = value
            case "version": manifest.version = value
            default: continue
            }
        }
        return manifest
    }
}
