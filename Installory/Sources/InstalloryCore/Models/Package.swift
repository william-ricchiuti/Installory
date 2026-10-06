import Foundation
import GRDB

/// A single installed package, normally identified by `(manager, qualifier, name)`.
///
/// Most IDs use `"{manager}:{qualifier}:{name}"`; managers may append another
/// stable component when their installation model requires it.
/// The qualifier disambiguates package-manager scopes such as pip interpreters,
/// npm global roots, or Ruby gem specification directories. RubyGems additionally
/// includes version because several versions can coexist in one specification root.
///
/// Examples:
/// - `brew::ffmpeg`
/// - `brewCask::visual-studio-code`
/// - `pip:/Users/x/.pyenv/versions/3.11.7/bin/python:requests`
/// - `pipx:/Users/x/.local/share/pipx/venvs/black:black`
/// - `uv:/Users/x/.local/share/uv/tools/ruff:ruff`
/// - `cargo::ripgrep`
/// - `gem:/Users/x/.rbenv/versions/3.2.2/lib/ruby/gems/3.2.0/specifications:bundler:2.5.6`
/// - `mas::com.apple.dt.Xcode`
public struct Package: Identifiable, Codable, Equatable, Hashable, Sendable {
    /// Stable row identity, with manager-specific disambiguation where required.
    public let id: String
    public let manager: PackageManager
    /// Manager-specific scope, such as a pip interpreter or Ruby specifications directory.
    public let qualifier: String?
    public let name: String
    public let version: String
    /// Absolute path to the package's installation directory, if known.
    public let installPath: URL?
    /// Best-effort install timestamp. See `installedAtConfidence` for reliability.
    public let installedAt: Date?
    public let installedAtConfidence: Confidence
    /// Best-effort logical installed payload size; nil when measurement is incomplete.
    public let sizeBytes: Int64?
    /// True when the package was installed explicitly by the user, not pulled in as a dependency.
    public let isExplicit: Bool
    /// True for system-managed packages (system Python, Xcode CLT) that must not appear in cleanup scripts.
    public let isReadOnly: Bool
    /// Names of direct dependencies within the same manager.
    public let dependencies: [String]
    /// Paths named by package-manager artifacts, including Homebrew cask files and uv entrypoints.
    public let artifactPaths: [String]?
    /// Timestamp of the most recent scan that observed this package.
    public let lastSeen: Date
    /// One-line description supplied by the package itself, when its scanner
    /// can read one (a skill's `SKILL.md` frontmatter `description`, an editor
    /// extension's `package.json` `description`/`displayName`). Nil for
    /// managers without such metadata and for rows persisted by older versions;
    /// encoded only when present, so the JSON shape is unchanged otherwise.
    /// Prefer ``DescriptionStore/descriptionOrFallback(for:)`` for display.
    public let summary: String?

    public init(
        id: String,
        manager: PackageManager,
        qualifier: String?,
        name: String,
        version: String,
        installPath: URL?,
        installedAt: Date?,
        installedAtConfidence: Confidence,
        sizeBytes: Int64?,
        isExplicit: Bool,
        isReadOnly: Bool,
        dependencies: [String],
        artifactPaths: [String]? = nil,
        lastSeen: Date,
        summary: String? = nil
    ) {
        self.id = id
        self.manager = manager
        self.qualifier = qualifier
        self.name = name
        self.version = version
        self.installPath = installPath
        self.installedAt = installedAt
        self.installedAtConfidence = installedAtConfidence
        self.sizeBytes = sizeBytes
        self.isExplicit = isExplicit
        self.isReadOnly = isReadOnly
        self.dependencies = dependencies
        self.artifactPaths = artifactPaths
        self.lastSeen = lastSeen
        self.summary = summary
    }
}

// MARK: - GRDB

extension Package: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "packages"

    public init(row: Row) throws {
        id = row["id"]

        let managerRaw: String = row["manager"]
        guard let mgr = PackageManager(rawValue: managerRaw) else {
            throw DatabaseError(message: "Unknown PackageManager raw value '\(managerRaw)' in packages row")
        }
        manager = mgr

        qualifier = row["qualifier"]
        name = row["name"]
        version = row["version"]

        if let pathStr: String = row["install_path"] {
            installPath = URL(fileURLWithPath: pathStr)
        } else {
            installPath = nil
        }

        if let ts: Double = row["installed_at"] {
            installedAt = Date(timeIntervalSince1970: ts)
        } else {
            installedAt = nil
        }

        let confidenceRaw: String = row["installed_at_confidence"]
        guard let confidence = Confidence(rawValue: confidenceRaw) else {
            throw DatabaseError(message: "Unknown Confidence raw value '\(confidenceRaw)' in packages row")
        }
        installedAtConfidence = confidence

        sizeBytes = row["size_bytes"]
        isExplicit = row["is_explicit"]
        isReadOnly = row["is_read_only"]

        let depsJSON: String = row["dependencies"]
        dependencies = try JSONDecoder().decode([String].self, from: Data(depsJSON.utf8))

        if let artifactPathsJSON: String = row["artifact_paths"] {
            artifactPaths = try JSONDecoder().decode([String].self, from: Data(artifactPathsJSON.utf8))
        } else {
            artifactPaths = nil
        }

        let lastSeenTs: Double = row["last_seen"]
        lastSeen = Date(timeIntervalSince1970: lastSeenTs)
        summary = row.hasColumn("summary") ? row["summary"] : nil
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["manager"] = manager.rawValue
        container["qualifier"] = qualifier
        container["name"] = name
        container["version"] = version
        container["install_path"] = installPath?.path
        container["installed_at"] = installedAt.map { $0.timeIntervalSince1970 }
        container["installed_at_confidence"] = installedAtConfidence.rawValue
        container["size_bytes"] = sizeBytes
        container["is_explicit"] = isExplicit ? 1 : 0
        container["is_read_only"] = isReadOnly ? 1 : 0
        let depsData = try JSONEncoder().encode(dependencies)
        container["dependencies"] = String(data: depsData, encoding: .utf8) ?? "[]"
        if let artifactPaths {
            let artifactPathsData = try JSONEncoder().encode(artifactPaths)
            container["artifact_paths"] = String(data: artifactPathsData, encoding: .utf8) ?? "[]"
        } else {
            container["artifact_paths"] = nil
        }
        container["last_seen"] = lastSeen.timeIntervalSince1970
        container["summary"] = summary
    }
}
