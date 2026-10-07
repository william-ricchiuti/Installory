import Foundation
import GRDB

// MARK: - Limits

/// Per-scan limits for the agent session-log collectors (Codex, Claude Code).
///
/// Session logs can be many gigabytes. Collectors walk them newest first and
/// stop reading new files once either budget is spent, returning what they
/// have. Files already in the ``ProvenanceFileCacheStore`` cost nothing against
/// the byte budget, so coverage grows across scans.
public struct ProvenanceCollectionLimits: Sendable {
    /// Total bytes of session data one collector may read in one scan.
    public var maximumSessionBytesPerScan: Int
    /// Wall-clock budget for one collector in one scan, in seconds.
    public var maximumDuration: TimeInterval
    /// Clock used for the wall-clock budget. Injectable for tests.
    public var now: @Sendable () -> Date

    public init(
        maximumSessionBytesPerScan: Int = 256 * 1_024 * 1_024,
        maximumDuration: TimeInterval = 20,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.maximumSessionBytesPerScan = maximumSessionBytesPerScan
        self.maximumDuration = maximumDuration
        self.now = now
    }

    public static var `default`: ProvenanceCollectionLimits { ProvenanceCollectionLimits() }
}

/// Why a collector stopped before visiting every session file.
public enum ProvenanceCollectionStopReason: String, Sendable, Equatable {
    case completed
    case byteBudget
    case timeBudget
    case recordLimit
    case cancelled
}

/// Counters describing one collector run. Contains no log content.
public struct ProvenanceCollectionReport: Sendable, Equatable {
    /// Session files considered (cache hits plus parsed plus skipped).
    public var filesVisited = 0
    /// Session files read and parsed this run.
    public var filesParsed = 0
    /// Session files whose records came from the cache without a read.
    public var cacheHits = 0
    /// Uncached files left unread because the byte budget was spent.
    public var filesSkippedForBudget = 0
    /// Bytes of session data read this run.
    public var bytesRead = 0
    public var stopReason: ProvenanceCollectionStopReason = .completed

    public init() {}
}

/// Tracks the byte and wall-clock budgets for one collector run.
struct ProvenanceScanBudget {
    let limits: ProvenanceCollectionLimits
    let startedAt: Date
    var bytesRead = 0

    init(limits: ProvenanceCollectionLimits) {
        self.limits = limits
        self.startedAt = limits.now()
    }

    var isTimeExpired: Bool {
        limits.now().timeIntervalSince(startedAt) >= limits.maximumDuration
    }

    var isByteBudgetSpent: Bool {
        bytesRead >= limits.maximumSessionBytesPerScan
    }
}

// MARK: - Line prefilter

/// Cheap byte-level check run before a JSONL line is decoded.
///
/// A line can only yield an install record when it contains the collector's
/// tool-call marker(s) and at least one package-manager token the
/// ``InstallCommandDetector`` recognizes. Every detector branch requires one of
/// these tokens literally (`pip` also covers `pip3`, `pipx` and `python -m pip`),
/// so the filter never drops a line the detector would accept.
struct ProvenanceLinePrefilter: Sendable {
    static let managerTokens: [[UInt8]] = [
        "brew", "pip", "npm", "uv", "cargo", "gem", "yarn", "mas",
    ].map { Array($0.utf8) }

    static let codexToolCall = ProvenanceLinePrefilter(markers: ["exec_command"])
    static let claudeToolCall = ProvenanceLinePrefilter(markers: ["tool_use", "Bash"])

    private let markers: [[UInt8]]

    init(markers: [String]) {
        self.markers = markers.map { Array($0.utf8) }
    }

    func mayContainInstall(_ line: UnsafeRawBufferPointer) -> Bool {
        guard markers.allSatisfy({ Self.contains(line, $0) }) else { return false }
        return Self.managerTokens.contains { Self.contains(line, $0) }
    }

    static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
        return needle.withUnsafeBytes { needleBytes in
            memmem(base, haystack.count, needleBytes.baseAddress!, needleBytes.count) != nil
        }
    }

    static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: String) -> Bool {
        contains(haystack, Array(needle.utf8))
    }
}

// MARK: - File stamps

/// Size and modification time identifying one version of a session file.
struct ProvenanceFileStamp: Equatable {
    let size: Int64
    let modifiedAt: TimeInterval

    static func of(_ url: URL, using access: any DirectoryAccessProvider) -> ProvenanceFileStamp? {
        guard let metadata = try? access.metadata(at: url),
              metadata.kind == .regularFile,
              let size = metadata.logicalSizeBytes,
              let modified = access.modificationDate(at: url) else { return nil }
        return ProvenanceFileStamp(size: size, modifiedAt: modified.timeIntervalSince1970)
    }
}

// MARK: - Cache store

/// Which collector a cache entry belongs to.
public enum ProvenanceLogSource: String, Sendable, CaseIterable {
    case codex
    case claudeCode = "claude_code"
}

/// Extracted install records for one session file version.
///
/// `payload` is JSON of records whose free-text fields were already passed
/// through ``ProvenanceRedactor``. It never holds raw log lines.
public struct ProvenanceFileCacheEntry: Sendable, Equatable {
    public let path: String
    public let size: Int64
    public let modifiedAt: TimeInterval
    public let payload: Data

    public init(path: String, size: Int64, modifiedAt: TimeInterval, payload: Data) {
        self.path = path
        self.size = size
        self.modifiedAt = modifiedAt
        self.payload = payload
    }
}

/// Persists per-file extraction results so unchanged session logs are not
/// re-parsed on later scans. Synchronous: collectors run off the main actor.
public protocol ProvenanceFileCacheStore: Sendable {
    func entries(for source: ProvenanceLogSource) throws -> [String: ProvenanceFileCacheEntry]
    func update(
        source: ProvenanceLogSource,
        upserting entries: [ProvenanceFileCacheEntry],
        removingPaths paths: [String]
    ) throws
    func removeAll() throws
}

/// Wraps a store so one collection run's writes can be shut off at once.
///
/// The app closes the gate when install history is turned off, access is
/// revoked, demo mode starts or history is cleared. `close()` waits for any
/// write in progress, and every later write is dropped, so a cancelled run
/// can never repopulate the cache afterwards.
public final class GatedProvenanceFileCacheStore: ProvenanceFileCacheStore, @unchecked Sendable {
    private let base: any ProvenanceFileCacheStore
    private let lock = NSLock()
    private var isClosed = false

    public init(base: any ProvenanceFileCacheStore) {
        self.base = base
    }

    public func close() {
        lock.withLock { isClosed = true }
    }

    public var closed: Bool { lock.withLock { isClosed } }

    public func entries(for source: ProvenanceLogSource) throws -> [String: ProvenanceFileCacheEntry] {
        try base.entries(for: source)
    }

    public func update(
        source: ProvenanceLogSource,
        upserting entries: [ProvenanceFileCacheEntry],
        removingPaths paths: [String]
    ) throws {
        try lock.withLock {
            guard !isClosed else { return }
            try base.update(source: source, upserting: entries, removingPaths: paths)
        }
    }

    public func removeAll() throws {
        try base.removeAll()
    }
}

/// In-memory store for tests and previews.
public final class InMemoryProvenanceFileCacheStore: ProvenanceFileCacheStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProvenanceLogSource: [String: ProvenanceFileCacheEntry]] = [:]

    public init() {}

    public func entries(for source: ProvenanceLogSource) throws -> [String: ProvenanceFileCacheEntry] {
        lock.withLock { storage[source] ?? [:] }
    }

    public func update(
        source: ProvenanceLogSource,
        upserting entries: [ProvenanceFileCacheEntry],
        removingPaths paths: [String]
    ) throws {
        lock.withLock {
            var current = storage[source] ?? [:]
            for path in paths { current[path] = nil }
            for entry in entries { current[entry.path] = entry }
            storage[source] = current
        }
    }

    public func removeAll() throws {
        lock.withLock { storage = [:] }
    }
}

/// GRDB-backed store over the `provenance_file_cache` table (migration
/// `v5_provenance_file_cache`). ``ProvenanceDAO/deleteAll()`` also clears it,
/// so "Clear History" erases cached records along with evidence.
public struct ProvenanceFileCacheDAO: ProvenanceFileCacheStore {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func entries(for source: ProvenanceLogSource) throws -> [String: ProvenanceFileCacheEntry] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT path, size, modified_at, payload FROM provenance_file_cache WHERE source = ?",
                arguments: [source.rawValue]
            )
            var result: [String: ProvenanceFileCacheEntry] = [:]
            for row in rows {
                let path: String = row["path"]
                result[path] = ProvenanceFileCacheEntry(
                    path: path,
                    size: row["size"],
                    modifiedAt: row["modified_at"],
                    payload: row["payload"]
                )
            }
            return result
        }
    }

    public func update(
        source: ProvenanceLogSource,
        upserting entries: [ProvenanceFileCacheEntry],
        removingPaths paths: [String]
    ) throws {
        guard !entries.isEmpty || !paths.isEmpty else { return }
        try database.pool.write { db in
            for path in paths {
                try db.execute(
                    sql: "DELETE FROM provenance_file_cache WHERE source = ? AND path = ?",
                    arguments: [source.rawValue, path]
                )
            }
            for entry in entries {
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO provenance_file_cache
                            (source, path, size, modified_at, payload)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [source.rawValue, entry.path, entry.size, entry.modifiedAt, entry.payload]
                )
            }
        }
    }

    public func removeAll() throws {
        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM provenance_file_cache")
        }
    }
}

// MARK: - Per-run cache session

/// One collector run's view of the cache: serves hits, gathers new entries,
/// and on ``finish(directoryAccess:)`` evicts entries for deleted files.
struct ProvenanceFileCacheSession<Record: Codable> {
    private let store: (any ProvenanceFileCacheStore)?
    private let source: ProvenanceLogSource
    private var existing: [String: ProvenanceFileCacheEntry] = [:]
    private var visited: Set<String> = []
    private var upserts: [ProvenanceFileCacheEntry] = []

    init(store: (any ProvenanceFileCacheStore)?, source: ProvenanceLogSource) {
        self.store = store
        self.source = source
        self.existing = (try? store?.entries(for: source)) ?? [:]
    }

    var isEnabled: Bool { store != nil }

    /// Returns cached records when the entry matches `stamp` exactly.
    mutating func records(for url: URL, stamp: ProvenanceFileStamp?) -> [Record]? {
        visited.insert(url.path)
        guard let stamp,
              let entry = existing[url.path],
              entry.size == stamp.size,
              entry.modifiedAt == stamp.modifiedAt else { return nil }
        return try? JSONDecoder().decode([Record].self, from: entry.payload)
    }

    mutating func store(_ records: [Record], for url: URL, stamp: ProvenanceFileStamp?) {
        guard store != nil, let stamp,
              let payload = try? JSONEncoder().encode(records) else { return }
        upserts.append(ProvenanceFileCacheEntry(
            path: url.path,
            size: stamp.size,
            modifiedAt: stamp.modifiedAt,
            payload: payload
        ))
    }

    /// Persists new entries and evicts entries whose files no longer exist.
    /// Entries not visited this run (budget stop) are kept while the file exists.
    func finish(directoryAccess: any DirectoryAccessProvider, evictMissingFiles: Bool = true) {
        guard let store else { return }
        let removed = evictMissingFiles ? existing.keys.filter { path in
            !visited.contains(path)
                && !directoryAccess.fileExists(at: URL(fileURLWithPath: path))
        } : []
        try? store.update(source: source, upserting: upserts, removingPaths: removed)
    }
}

// MARK: - Cached record shapes

/// Cached form of an agent install record. The context is already redacted;
/// `qualifierHints` were derived from the original command before redaction
/// so scope matching is unchanged.
struct CachedAgentInstall<Context: Codable & Sendable>: Codable, Sendable {
    let packageName: String
    let manager: PackageManager
    let context: Context
    let qualifierHints: [InstallQualifierHint?]
}
