import Foundation
import GRDB

/// Reads and writes ``ProvenanceEvidence`` rows in the `provenance_evidence` table.
///
/// **FK prerequisite:** `provenance_evidence.package_id` has a
/// `FOREIGN KEY … REFERENCES packages(id)` constraint. Call ``upsert(_:)`` or
/// ``upsertAll(_:)`` only
/// after the corresponding ``Package`` row has been persisted. The app shell
/// sequences this correctly: scan → persist packages → collect provenance →
/// persist evidence. The FK violation is the runtime signal for a mis-sequenced call.
public actor ProvenanceDAO {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Inserts or updates the evidence for a package.
    ///
    /// Uses GRDB's `save` which updates if the `package_id` row exists,
    /// then inserts if no rows were changed.
    ///
    /// - Precondition: the `packages` row for `evidence.packageId` must exist.
    public func upsert(_ evidence: ProvenanceEvidence) throws {
        try upsertAll([evidence])
    }

    /// Inserts or updates a batch of evidence in one transaction.
    ///
    /// The operation is atomic: if any evidence fails to persist (including a
    /// foreign-key violation), none of the batch is committed. Input order is
    /// preserved, so when the batch repeats a package ID, the final occurrence
    /// supplies the stored values.
    ///
    /// - Precondition: a `packages` row must exist for every evidence package ID.
    public func upsertAll(_ evidenceList: [ProvenanceEvidence]) throws {
        try database.pool.write { db in
            for evidence in evidenceList {
                try evidence.save(db)
            }
        }
    }

    /// Returns the evidence for `packageId`, or `nil` if no row exists.
    public func fetch(packageId: String) throws -> ProvenanceEvidence? {
        try database.pool.read { db in
            try ProvenanceEvidence.fetchOne(db, key: packageId)
        }
    }

    /// Returns all persisted evidence ordered by package ID.
    ///
    /// The explicit ordering keeps startup cache hydration and tests
    /// deterministic instead of depending on SQLite's table traversal order.
    public func fetchAll() throws -> [ProvenanceEvidence] {
        try database.pool.read { db in
            try ProvenanceEvidence.fetchAll(
                db,
                sql: "SELECT * FROM provenance_evidence ORDER BY package_id"
            )
        }
    }

    /// Removes the evidence for `packageId`. No-op if no row exists.
    public func delete(packageId: String) throws {
        try database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM provenance_evidence WHERE package_id = ?",
                arguments: [packageId]
            )
        }
    }

    /// Removes all rows from `provenance_evidence` and the per-file session-log
    /// cache (`provenance_file_cache`) in one transaction, so "Clear History"
    /// leaves no extracted install records behind.
    public func deleteAll() throws {
        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM provenance_evidence")
            try db.execute(sql: "DELETE FROM provenance_file_cache")
        }
    }
}
