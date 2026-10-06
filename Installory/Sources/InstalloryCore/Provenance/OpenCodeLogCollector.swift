import Foundation
import GRDB

/// Reads opencode's local `opencode.db` SQLite database (read-only) and returns
/// every package install command found inside a `bash` tool part.
///
/// opencode stores transcripts in SQLite rather than JSONL. Tool invocations
/// live in the `part` table's `data` JSON column as `{"type":"tool","tool":"bash",
/// "state":{"input":{"command":"…"}}}`. Session context (directory, title) comes
/// from the joined `session` row. `part.time_created` is unix *milliseconds*.
///
/// The database schema is owned by opencode and may evolve (drizzle migrations),
/// so reads stay defensive: schema drift simply yields no records this run.
public struct OpenCodeLogCollector: Sendable {
    private let databasePath: URL
    private let detector: InstallCommandDetector

    public init(
        databasePath: URL = UserHome.directory
            .appendingPathComponent(".local/share/opencode/opencode.db"),
        detector: InstallCommandDetector = InstallCommandDetector()
    ) {
        self.databasePath = databasePath
        self.detector = detector
    }

    /// Reads bash tool invocations from the opencode database and returns every
    /// install command found, with session context attached.
    public func collect() -> [InstalledByOpenCode] {
        guard !Task.isCancelled,
              FileManager.default.fileExists(atPath: databasePath.path) else { return [] }

        var configuration = Configuration()
        configuration.readonly = true

        guard let queue = try? DatabaseQueue(
            path: databasePath.path,
            configuration: configuration
        ) else { return [] }

        var results: [InstalledByOpenCode] = []
        do {
            try queue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT p.session_id, p.time_created, p.data,
                           s.directory, s.title
                    FROM part p
                    JOIN session s ON s.id = p.session_id
                    WHERE p.data LIKE '%"tool":"bash"%'
                    ORDER BY p.time_created DESC
                    LIMIT ?
                    """, arguments: [maximumOpenCodePartRows])
                for row in rows {
                    guard !Task.isCancelled, results.count < maximumOpenCodeInstallRecords else { break }
                    results.append(contentsOf: record(from: row))
                }
            }
        } catch {
            return []
        }
        return results
    }

    // MARK: - Per-row parsing

    private func record(from row: Row) -> [InstalledByOpenCode] {
        guard let dataJSON = row["data"] as? String,
              let data = dataJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "tool",
              obj["tool"] as? String == "bash",
              let state = obj["state"] as? [String: Any],
              let input = state["input"] as? [String: Any],
              let command = input["command"] as? String,
              !command.isEmpty else { return [] }

        let detections = detector.detect(command)
        guard !detections.isEmpty else { return [] }

        let context = ProvenanceEvidence.OpenCodeContext(
            sessionId: row["session_id"] as? String ?? "",
            projectPath: row["directory"] as? String ?? "",
            sessionSummary: row["title"] as? String,
            firstUserMessage: nil,
            bashInvocation: command,
            timestamp: opencodeTimestamp(from: row)
        )

        return detections.map {
            InstalledByOpenCode(packageName: $0.name, manager: $0.manager, context: context)
        }
    }

    /// opencode stores `time_created` as unix milliseconds; convert to seconds.
    private func opencodeTimestamp(from row: Row) -> Date? {
        guard let milliseconds = row["time_created"] as? Int64 else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

private let maximumOpenCodePartRows = 50_000
private let maximumOpenCodeInstallRecords = 50_000

// MARK: - Public types

/// A package install command detected inside an opencode bash tool part.
public struct InstalledByOpenCode: Sendable, Equatable {
    public let packageName: String
    public let manager: PackageManager
    public let context: ProvenanceEvidence.OpenCodeContext

    public init(
        packageName: String,
        manager: PackageManager,
        context: ProvenanceEvidence.OpenCodeContext
    ) {
        self.packageName = packageName
        self.manager = manager
        self.context = context
    }
}
