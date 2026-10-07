import GRDB

/// Append-only migration definitions for the Installory SQLite database.
///
/// **Never modify a registered migration after it has been shipped.**
/// Add a new `registerMigration` call for every schema change.
/// `DatabaseMigrator` guarantees each migration runs exactly once.
public enum Migrations {

    /// Applies all pending migrations to `writer`.
    ///
    /// Safe to call multiple times — already-applied migrations are skipped.
    public static func run(_ writer: some DatabaseWriter) throws {
        try makeMigrator().migrate(writer)
    }

    /// Builds the complete ordered migration chain.
    ///
    /// Kept internal so upgrade-path tests can migrate a database to an exact
    /// previously shipped boundary before applying the remaining migrations.
    /// Production callers should use ``run(_:)``.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial", migrate: v1Initial)
        migrator.registerMigration("v2_package_artifact_paths", migrate: v2PackageArtifactPaths)
        migrator.registerMigration("v3_package_user_state", migrate: v3PackageUserState)
        migrator.registerMigration("v4_package_summary", migrate: v4PackageSummary)
        migrator.registerMigration("v5_provenance_file_cache", migrate: v5ProvenanceFileCache)
        return migrator
    }

    // MARK: - Migration bodies

    private static func v1Initial(_ db: GRDB.Database) throws {
        // packages — current inventory
        try db.execute(sql: """
            CREATE TABLE packages (
                id                      TEXT PRIMARY KEY,
                manager                 TEXT NOT NULL,
                qualifier               TEXT,
                name                    TEXT NOT NULL,
                version                 TEXT NOT NULL,
                install_path            TEXT,
                installed_at            REAL,
                installed_at_confidence TEXT NOT NULL,
                size_bytes              INTEGER,
                is_explicit             INTEGER NOT NULL DEFAULT 0,
                is_read_only            INTEGER NOT NULL DEFAULT 0,
                dependencies            TEXT NOT NULL DEFAULT '[]',
                last_seen               REAL NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_packages_manager ON packages(manager)")
        try db.execute(sql: "CREATE INDEX idx_packages_name ON packages(name)")

        // provenance_evidence — structured signals, stored as JSON payload
        // collected_at and overall_confidence are extracted as columns
        // so queries can filter by confidence without deserializing the blob.
        try db.execute(sql: """
            CREATE TABLE provenance_evidence (
                package_id         TEXT PRIMARY KEY,
                payload            TEXT NOT NULL,
                collected_at       REAL NOT NULL,
                overall_confidence TEXT NOT NULL,
                FOREIGN KEY (package_id) REFERENCES packages(id) ON DELETE CASCADE
            )
            """)

        // snapshots — point-in-time export manifests
        try db.execute(sql: """
            CREATE TABLE snapshots (
                id         TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                reason     TEXT NOT NULL,
                note       TEXT,
                payload    TEXT NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_snapshots_created ON snapshots(created_at DESC)")

        // scan_runs — diagnostic log of scanner invocations
        try db.execute(sql: """
            CREATE TABLE scan_runs (
                id                  TEXT PRIMARY KEY,
                started_at          REAL NOT NULL,
                completed_at        REAL,
                per_manager_results TEXT NOT NULL
            )
            """)
    }

    private static func v2PackageArtifactPaths(_ db: GRDB.Database) throws {
        try db.execute(sql: "ALTER TABLE packages ADD COLUMN artifact_paths TEXT")
    }

    /// Per-package user annotations: hide/pin flags and a free-form note.
    ///
    /// No foreign key is declared on purpose: user state must survive a
    /// package disappearing from the inventory (the rows it references are
    /// reconciled, not preserved), and the note/pin flags have no meaning for
    /// a package the user has never seen. Orphaned rows are harmless and
    /// cleaned up opportunistically when a package row is recreated.
    private static func v3PackageUserState(_ db: GRDB.Database) throws {
        try db.execute(sql: """
            CREATE TABLE package_user_state (
                package_id TEXT PRIMARY KEY,
                is_hidden  INTEGER NOT NULL DEFAULT 0,
                is_pinned  INTEGER NOT NULL DEFAULT 0,
                note       TEXT,
                updated_at REAL NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_package_user_state_pinned ON package_user_state(is_pinned)")
    }

    /// Scanner-supplied one-line package summary (skill frontmatter or editor
    /// extension `package.json` description). Nullable so existing rows and
    /// managers without such metadata are unaffected.
    private static func v4PackageSummary(_ db: GRDB.Database) throws {
        try db.execute(sql: "ALTER TABLE packages ADD COLUMN summary TEXT")
    }

    /// Per-session-file cache of extracted install records so unchanged agent
    /// logs are not re-parsed every scan. `payload` holds JSON of records whose
    /// text was already redacted — never raw log lines. Keyed by collector
    /// source and file path; `size` + `modified_at` identify the file version.
    /// Cleared together with `provenance_evidence` by ProvenanceDAO.deleteAll.
    private static func v5ProvenanceFileCache(_ db: GRDB.Database) throws {
        try db.execute(sql: """
            CREATE TABLE provenance_file_cache (
                source      TEXT NOT NULL,
                path        TEXT NOT NULL,
                size        INTEGER NOT NULL,
                modified_at REAL NOT NULL,
                payload     BLOB NOT NULL,
                PRIMARY KEY (source, path)
            )
            """)
    }
}
