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

            // Homebrew 4.x keeps a cask's single receipt in
            // `Caskroom/<token>/.metadata/INSTALL_RECEIPT.json`; the version
            // folder only holds the staged app or pkg. Formulae keep one
            // receipt per keg. A per-version receipt still wins when present.
            let sharedReceipt = manager == .brewCask
                ? readReceipt(at: nameDir
                    .appendingPathComponent(".metadata", isDirectory: true)
                    .appendingPathComponent("INSTALL_RECEIPT.json"))
                : nil

            // Collect all valid (versionDir, receipt) pairs, then pick the latest.
            // Multiple version directories arise when Homebrew retains old keg links;
            // emitting one Package per name prevents duplicate SwiftUI List IDs.
            var candidates: [(versionDir: URL, receipt: InstallReceipt)] = []
            for versionDir in versionDirs.sorted(by: { $0.path < $1.path }) {
                try Task.checkCancellation()
                let version = versionDir.lastPathComponent
                guard !version.hasPrefix(".") else { continue }
                let receiptURL = versionDir.appendingPathComponent("INSTALL_RECEIPT.json")
                guard let receipt = readReceipt(at: receiptURL) ?? sharedReceipt else {
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
                let bestMtime = versionDate(best.versionDir)
                let candMtime = versionDate(candidate.versionDir)
                return candMtime > bestMtime ? candidate : best
            }
        }
    }

    /// A version folder's age for tie-breaking: its receipt's mtime when it
    /// has one (formulae), otherwise the folder's own mtime (casks).
    private func versionDate(_ versionDir: URL) -> Date {
        directoryAccess.modificationDate(at: versionDir.appendingPathComponent("INSTALL_RECEIPT.json"))
            ?? directoryAccess.modificationDate(at: versionDir)
            ?? .distantPast
    }

    /// Reads and parses a receipt with a size bound. Returns nil when the file
    /// is missing, too large, not a regular file, or not a JSON object.
    private func readReceipt(at url: URL) -> InstallReceipt? {
        guard let data = try? directoryAccess.data(
            contentsOf: url,
            maximumBytes: InstallReceipt.maximumBytes,
            from: .prefix
        ) else { return nil }
        return InstallReceipt.parse(data)
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
        let deps = receipt.dependencyNames
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

/// The fields Installory uses from a Homebrew `INSTALL_RECEIPT.json`.
///
/// Parsed leniently with `JSONSerialization` because receipt shapes vary by
/// Homebrew version and by formula vs cask: `runtime_dependencies` is an array
/// for formulae and a `{"formula": [...], "cask": [...]}` dictionary for casks,
/// and cask artifacts mix strings with option objects such as
/// `{"target": "Name.app"}`. Unknown or unexpected values are skipped rather
/// than failing the whole receipt.
struct InstallReceipt {
    /// Receipts are a few kilobytes; anything far larger isn't a receipt.
    static let maximumBytes = 4 * 1024 * 1024

    let time: Double?
    let installedOnRequest: Bool?
    let installedAsDependency: Bool?
    /// Formula (and, for casks, cask) dependency names, tap prefixes removed.
    let dependencyNames: [String]
    /// App bundle names a cask installs (the `target` when one is given).
    let appPaths: [String]
    /// User-data paths a cask's `zap` stanza would trash.
    let zapTrashPaths: [String]

    var artifactPaths: [String]? {
        let paths = appPaths + zapTrashPaths
        return paths.isEmpty ? nil : paths
    }

    static func parse(_ data: Data) -> InstallReceipt? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return nil }

        let artifacts = (root["uninstall_artifacts"] as? [Any]) ?? (root["artifacts"] as? [Any]) ?? []
        var apps: [String] = []
        var zap: [String] = []
        for case let artifact as [String: Any] in artifacts {
            if let values = artifact["app"] as? [Any] {
                if let app = appName(from: values) { apps.append(app) }
            }
            if let stanzas = artifact["zap"] as? [Any] {
                for case let stanza as [String: Any] in stanzas {
                    zap += strings(stanza["trash"])
                }
            }
        }

        return InstallReceipt(
            time: (root["time"] as? NSNumber)?.doubleValue,
            installedOnRequest: bool(root["installed_on_request"]),
            installedAsDependency: bool(root["installed_as_dependency"]),
            dependencyNames: dependencyNames(root["runtime_dependencies"]),
            appPaths: apps,
            zapTrashPaths: zap
        )
    }

    /// `[{"full_name": "homebrew/core/zlib"}, …]` or
    /// `{"formula": [{"full_name": …}], "cask": [{"full_name": …}]}`.
    private static func dependencyNames(_ value: Any?) -> [String] {
        var entries: [Any] = []
        if let array = value as? [Any] {
            entries = array
        } else if let dictionary = value as? [String: Any] {
            entries = (dictionary["formula"] as? [Any] ?? []) + (dictionary["cask"] as? [Any] ?? [])
        }
        var names: [String] = []
        for case let entry as [String: Any] in entries {
            guard let fullName = entry["full_name"] as? String, !fullName.isEmpty else { continue }
            let name = fullName.components(separatedBy: "/").last ?? fullName
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// An `app` artifact is `["Source.app"]` or `["Source.app", {"target": "Name.app"}]`.
    /// The app lands in /Applications under the target name, or under the
    /// source's last path component (`AeroSpace-v1/AeroSpace.app` → `AeroSpace.app`).
    private static func appName(from values: [Any]) -> String? {
        for case let options as [String: Any] in values {
            if let target = options["target"] as? String, !target.isEmpty {
                return (target as NSString).lastPathComponent
            }
        }
        for case let source as String in values where !source.isEmpty {
            return (source as NSString).lastPathComponent
        }
        return nil
    }

    private static func strings(_ value: Any?) -> [String] {
        if let string = value as? String { return [string] }
        if let array = value as? [Any] { return array.compactMap { $0 as? String } }
        return []
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
