import Foundation
import GRDB
import Testing
@testable import InstalloryCore

@Suite("Migration v6: redact stored Install History")
struct HistoryRedactionMigrationTests {
    @Test("a v5 database loses stored first prompts and old-rule secrets, and its file cache is cleared")
    func v5UpgradesToV6() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("installory-v6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try Migrations.makeMigrator().migrate(pool, upTo: "v5_provenance_file_cache")

        // Written as 1.6.0 would have stored it: a first prompt, and a token
        // shape the old rules missed. Assembled at runtime (push protection).
        let oldRuleMiss = "h" + "f_" + "abcdefghijklmnopqrstuvwxyz0123456789"
        let payload = """
        {"packageId":"pip:/usr/bin/python3:transformers","fsInstallTime":null,"fsInstallTimeSource":null,
         "installCommand":null,
         "claudeCodeContext":{"sessionId":"s1","projectPath":"~/app","sessionSummary":"Add a model",
           "firstUserMessage":"PRIVATE PROMPT TEXT","bashInvocation":"HF=\(oldRuleMiss) pip install transformers",
           "timestamp":1700000000},
         "nearbyProjects":[],"coInstalledWithin1h":[],"overallConfidence":"high","collectedAt":1700000000}
        """
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO packages (id, manager, qualifier, name, version, install_path, installed_at,
                    installed_at_confidence, size_bytes, is_explicit, is_read_only, dependencies, last_seen, artifact_paths)
                VALUES ('pip:/usr/bin/python3:transformers', 'pip', '/usr/bin/python3', 'transformers', '4.0',
                    NULL, NULL, 'unknown', NULL, 1, 0, '[]', 1700000000, NULL)
                """)
            try db.execute(
                sql: "INSERT INTO provenance_evidence (package_id, payload, collected_at, overall_confidence) VALUES (?, ?, ?, ?)",
                arguments: ["pip:/usr/bin/python3:transformers", payload, 1_700_000_000, "high"]
            )
            try db.execute(
                sql: "INSERT INTO provenance_file_cache (source, path, size, modified_at, payload) VALUES (?, ?, ?, ?, ?)",
                arguments: ["claudeCode", "/Users/x/.claude/projects/a.jsonl", 10, 1.0, Data("[]".utf8)]
            )
        }

        try Migrations.run(pool)

        try pool.read { db in
            let stored = try String.fetchOne(db, sql: "SELECT payload FROM provenance_evidence") ?? ""
            #expect(!stored.contains("PRIVATE PROMPT TEXT"))
            #expect(!stored.contains(oldRuleMiss))
            #expect(stored.contains("pip install transformers"))
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM provenance_file_cache") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM provenance_evidence") == 1)
        }
    }
}
