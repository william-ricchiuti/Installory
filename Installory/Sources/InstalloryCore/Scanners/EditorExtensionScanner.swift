import Foundation

/// Discovers the extensions roots of installed editors.
///
/// Each candidate is the per-editor extensions directory in the user's home
/// directory. Discovery is purely additive: candidates that do not exist as
/// directories are ignored, and duplicates are removed.
struct EditorExtensionDiscovery {
    static func extensionRoots(
        homeDirectory: URL,
        directoryAccess: any DirectoryAccessProvider
    ) -> [URL] {
        var candidates: [URL] = []
        for relative in [".vscode/extensions", ".cursor/extensions"] {
            candidates.append(homeDirectory.appendingPathComponent(relative, isDirectory: true))
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

/// Inventories editor extensions — directories under an editor's extensions
/// root that each describe one installed extension.
///
/// The scanner is filesystem-only and never launches an editor CLI. Every
/// extension becomes a `.editorExtension` package row whose qualifier is the
/// owning extensions root. Extension identity and version come from each
/// extension's `package.json` when readable, falling back to the directory
/// name and an embedded version suffix.
public struct EditorExtensionScanner: PackageScanner, Sendable {
    public struct Limits: Sendable, Equatable {
        public let maximumExtensionRoots: Int
        public let maximumExtensionsPerRoot: Int
        public let maximumPackageJSONBytes: Int

        public init(
            maximumExtensionRoots: Int = 16,
            maximumExtensionsPerRoot: Int = 20_000,
            maximumPackageJSONBytes: Int = 512 * 1_024
        ) {
            self.maximumExtensionRoots = maximumExtensionRoots
            self.maximumExtensionsPerRoot = maximumExtensionsPerRoot
            self.maximumPackageJSONBytes = maximumPackageJSONBytes
        }

        public static let `default` = Limits()
    }

    public let manager: PackageManager = .editorExtension

    private let extensionRoots: [URL]
    private let directoryAccess: any DirectoryAccessProvider
    private let limits: Limits
    private let directorySizeLimits: DirectorySizeLimits
    private let now: @Sendable () -> Date

    /// Discovers and uses every existing editor extensions root under the
    /// user's home directory.
    public init(
        homeDirectory: URL,
        environment: PackageManagerEnvironment = .current,
        grantedURLs: [URL] = [],
        directoryAccess: any DirectoryAccessProvider = SystemDirectoryAccessProvider(),
        limits: Limits = .default,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        let roots = EditorExtensionDiscovery.extensionRoots(
            homeDirectory: homeDirectory,
            directoryAccess: directoryAccess
        )
        self.init(
            extensionRoots: roots,
            directoryAccess: directoryAccess,
            limits: limits,
            directorySizeLimits: .default,
            now: now
        )
    }

    /// Uses exactly the given extensions roots (no discovery).
    public init(
        extensionRoots: [URL],
        directoryAccess: any DirectoryAccessProvider = SystemDirectoryAccessProvider(),
        limits: Limits = .default,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.init(
            extensionRoots: extensionRoots,
            directoryAccess: directoryAccess,
            limits: limits,
            directorySizeLimits: .default,
            now: now
        )
    }

    init(
        extensionRoots: [URL],
        directoryAccess: any DirectoryAccessProvider,
        limits: Limits,
        directorySizeLimits: DirectorySizeLimits,
        now: @Sendable @escaping () -> Date
    ) {
        self.extensionRoots = extensionRoots
        self.directoryAccess = directoryAccess
        self.limits = limits
        self.directorySizeLimits = directorySizeLimits
        self.now = now
    }

    public func isAvailable() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard !extensionRoots.isEmpty, extensionRoots.count <= limits.maximumExtensionRoots else {
            return false
        }
        for root in extensionRoots {
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
        "No editor extensions directory found or granted"
    }

    public func scan() async throws -> [Package] {
        try Task.checkCancellation()
        guard extensionRoots.count <= limits.maximumExtensionRoots else {
            throw EditorExtensionScannerError.tooManyExtensionRoots(extensionRoots.count)
        }

        let observationDate = now()
        var sizer = BoundedDirectorySizer(
            directoryAccess: directoryAccess,
            limits: directorySizeLimits
        )
        var packages: [Package] = []
        var seenExtensionPaths: Set<String> = []

        for (rootIndex, root) in extensionRoots.enumerated() {
            try await checkpoint(rootIndex)
            let rootChildren = try directoryAccess.contentsOfDirectory(at: root)
            try Task.checkCancellation()
            guard rootChildren.count <= limits.maximumExtensionsPerRoot else {
                throw EditorExtensionScannerError.tooManyExtensionsPerRoot(root)
            }

            for (index, child) in rootChildren
                .sorted(by: { $0.standardizedFileURL.path < $1.standardizedFileURL.path })
                .enumerated() {
                try await checkpoint(index)
                let candidate = child.standardizedFileURL
                guard Self.isDirectChild(candidate, of: root) else {
                    throw EditorExtensionScannerError.unsafePath(candidate)
                }
                let name = candidate.lastPathComponent
                // Skip hidden entries (e.g. .obsolete, .install files).
                guard !name.hasPrefix(".") else { continue }

                let metadata = try directoryAccess.metadata(at: candidate)
                try Task.checkCancellation()
                switch metadata.kind {
                case .regularFile, .other, .symbolicLink:
                    continue
                case .directory:
                    let extensionDirectory = try realDirectory(
                        at: candidate,
                        containedIn: root,
                        directChildOf: root
                    )
                    guard seenExtensionPaths.insert(extensionDirectory.path).inserted else {
                        throw EditorExtensionScannerError.unsafePath(extensionDirectory)
                    }
                    packages.append(
                        try await extensionPackage(
                            for: extensionDirectory,
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

    /// Builds a row for a single extension directory.
    ///
    /// Identity and version come from the extension's `package.json` when it is
    /// readable. Otherwise the directory name is used, stripping a trailing
    /// version suffix like `-1.2.3` when present.
    private func extensionPackage(
        for extensionDirectory: URL,
        in root: URL,
        observationDate: Date,
        sizer: inout BoundedDirectorySizer
    ) async throws -> Package {
        try Task.checkCancellation()
        let packageJSONURL = extensionDirectory.appendingPathComponent("package.json")
        let metadata = try? boundedRegularFile(
            at: packageJSONURL,
            maximumBytes: limits.maximumPackageJSONBytes,
            containedIn: root
        )
        try Task.checkCancellation()

        let parsed: ExtensionIdentity?
        if let data = metadata,
           let identity = ExtensionIdentityParser.parse(data) {
            parsed = identity
        } else {
            parsed = nil
        }

        // VS Code manifests often localize `displayName`/`description` as
        // `%key%` placeholders resolved from `package.nls.json`. Read that file
        // (bounded, same containment rules) only when a placeholder needs it.
        var localizedStrings: [String: String] = [:]
        if parsed?.needsLocalization == true {
            let nlsURL = extensionDirectory.appendingPathComponent("package.nls.json")
            if let nlsData = try? boundedRegularFile(
                at: nlsURL,
                maximumBytes: limits.maximumPackageJSONBytes,
                containedIn: root
            ) {
                localizedStrings = ExtensionIdentityParser.parseLocalizedStrings(nlsData)
            }
            try Task.checkCancellation()
        }

        let measuredSize = try await sizer.measure(
            [.tree(extensionDirectory)],
            constrainedTo: root
        ).sizeBytes

        let directoryName = extensionDirectory.lastPathComponent
        let identity = parsed ?? ExtensionIdentity.fromDirectoryName(directoryName)

        return Package(
            id: id(root: root, name: identity.name),
            manager: .editorExtension,
            qualifier: root.path,
            name: identity.name,
            version: identity.version,
            installPath: extensionDirectory,
            installedAt: directoryAccess.modificationDate(at: extensionDirectory),
            installedAtConfidence: .medium,
            sizeBytes: measuredSize,
            isExplicit: true,
            isReadOnly: false,
            dependencies: [],
            artifactPaths: nil,
            lastSeen: observationDate,
            summary: parsed?.summary(localizedStrings: localizedStrings)
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
            throw EditorExtensionScannerError.unsafePath(standardized)
        }

        let metadata = try directoryAccess.metadata(at: standardized)
        guard metadata.kind == .regularFile,
              let logicalSize = metadata.logicalSizeBytes,
              logicalSize >= 0,
              maximumBytes >= 0,
              logicalSize <= Int64(maximumBytes) else {
            throw EditorExtensionScannerError.packageJSONExceedsLimit(standardized)
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
            throw EditorExtensionScannerError.packageJSONExceedsLimit(standardized)
        }
        try Task.checkCancellation()
        guard data.count <= maximumBytes, Int64(data.count) == logicalSize else {
            throw EditorExtensionScannerError.packageJSONExceedsLimit(standardized)
        }
        return data
    }

    private func realDirectory(
        at url: URL,
        containedIn root: URL,
        directChildOf expectedParent: URL
    ) throws -> URL {
        try Task.checkCancellation()
        let standardized = url.standardizedFileURL
        guard Self.isDirectChild(standardized, of: expectedParent.standardizedFileURL) else {
            throw EditorExtensionScannerError.unsafePath(standardized)
        }

        let metadata = try directoryAccess.metadata(at: standardized)
        guard metadata.kind == .directory else {
            throw EditorExtensionScannerError.unsafePath(standardized)
        }
        let resolved = directoryAccess
            .resolvingSymlinks(at: standardized)
            .standardizedFileURL
        guard Self.isContained(resolved, in: root) else {
            throw EditorExtensionScannerError.unsafePath(standardized)
        }
        if !Self.isDirectChild(resolved, of: expectedParent.standardizedFileURL) {
            throw EditorExtensionScannerError.unsafePath(standardized)
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

enum EditorExtensionScannerError: Swift.Error, Equatable, Sendable {
    case unsafePath(URL)
    case packageJSONExceedsLimit(URL)
    case tooManyExtensionRoots(Int)
    case tooManyExtensionsPerRoot(URL)
}

/// The identity of an editor extension: its `name` (publisher.name) and version.
struct ExtensionIdentity: Sendable, Equatable {
    let name: String
    let version: String
    /// `package.json` `displayName`, possibly a `%key%` localization placeholder.
    var displayName: String? = nil
    /// `package.json` `description`, possibly a `%key%` localization placeholder.
    var description: String? = nil
    /// `package.json` `publisher`.
    var publisher: String? = nil

    /// True when `displayName` or `description` is a `%key%` placeholder.
    var needsLocalization: Bool {
        [displayName, description].contains { $0.map(Self.isPlaceholder) ?? false }
    }

    /// A one-line summary for display: the description when present, otherwise
    /// the display name. Placeholders are resolved through `localizedStrings`
    /// and dropped when unresolved.
    func summary(localizedStrings: [String: String] = [:]) -> String? {
        let resolvedDescription = Self.resolve(description, in: localizedStrings)
        let resolvedDisplayName = Self.resolve(displayName, in: localizedStrings)
        let chosen = resolvedDescription ?? resolvedDisplayName
        guard let chosen else { return nil }
        let collapsed = chosen
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count > 500 {
            return String(collapsed.prefix(499)) + "…"
        }
        return collapsed
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        value.count >= 3 && value.hasPrefix("%") && value.hasSuffix("%")
    }

    private static func resolve(_ value: String?, in strings: [String: String]) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard isPlaceholder(trimmed) else { return trimmed }
        let key = String(trimmed.dropFirst().dropLast())
        guard let localized = strings[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !localized.isEmpty,
              !isPlaceholder(localized) else {
            return nil
        }
        return localized
    }

    /// Falls back to the directory name, stripping a trailing `-version` suffix
    /// like `-1.2.3` or `-1.2.3-beta` when present.
    static func fromDirectoryName(_ directoryName: String) -> ExtensionIdentity {
        let stripped = Self.stripVersionSuffix(from: directoryName)
        return ExtensionIdentity(name: stripped, version: "")
    }

    private static func stripVersionSuffix(from name: String) -> String {
        guard let dash = name.lastIndex(of: "-") else { return name }
        let suffix = name[name.index(after: dash)...]
        // A version suffix starts with a digit; keep publisher.name otherwise.
        guard let first = suffix.first, first.isNumber else { return name }
        return String(name[..<dash])
    }
}

/// Minimal `package.json` reader for extension identity.
///
/// Only the `name`, `version`, `displayName`, `description`, and `publisher`
/// string fields are extracted via Foundation's JSON parser; nothing else is
/// interpreted.
enum ExtensionIdentityParser {
    static func parse(_ data: Data) -> ExtensionIdentity? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let name = object["name"] as? String, !name.isEmpty else { return nil }
        let version = (object["version"] as? String) ?? ""
        return ExtensionIdentity(
            name: name,
            version: version,
            displayName: object["displayName"] as? String,
            description: object["description"] as? String,
            publisher: object["publisher"] as? String
        )
    }

    /// Reads the flat string table from `package.nls.json`. Non-string values
    /// (VS Code also allows `{ "message": …, "comment": … }`) use `message`.
    static func parseLocalizedStrings(_ data: Data) -> [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in object {
            if let string = value as? String {
                result[key] = string
            } else if let nested = value as? [String: Any], let message = nested["message"] as? String {
                result[key] = message
            }
        }
        return result
    }
}
