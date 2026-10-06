import Foundation

/// Walks ~/.codex/sessions (date-bucketed JSONL transcripts), reads Codex
/// session logs, and returns every package install command found inside an
/// `exec_command` function call.
///
/// Codex stores sessions as `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-*.jsonl`.
/// Each line is an event with a top-level ISO8601 `timestamp` and a `payload`.
/// The `session_meta` event carries the authoritative session id and working
/// directory; `exec_command` calls carry shell commands in `arguments.cmd`.
public struct CodexLogCollector: Sendable {
    private let directoryAccess: any DirectoryAccessProvider
    private let homeDirectory: URL
    private let detector: InstallCommandDetector

    public init(
        directoryAccess: any DirectoryAccessProvider = SystemDirectoryAccessProvider(),
        homeDirectory: URL = UserHome.directory,
        detector: InstallCommandDetector = InstallCommandDetector()
    ) {
        self.directoryAccess = directoryAccess
        self.homeDirectory = homeDirectory
        self.detector = detector
    }

    /// Walks ~/.codex/sessions, parses every session, and returns every install
    /// command found inside an `exec_command` call, with full session context.
    public func collect() -> [InstalledByCodex] {
        guard !Task.isCancelled else { return [] }
        let sessionsURL = homeDirectory
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")

        guard let yearDirs = try? directoryAccess.contentsOfDirectory(at: sessionsURL) else {
            return []
        }

        var results: [InstalledByCodex] = []
        let years = yearDirs
            .filter { isNumericName($0) }
            .sorted { $0.path < $1.path }
            .prefix(maximumCodexYears)
        for yearDir in years {
            guard !Task.isCancelled, results.count < maximumCodexInstallRecords else { break }
            let monthDirs = ((try? directoryAccess.contentsOfDirectory(at: yearDir)) ?? [])
                .filter { isNumericName($0) }
                .sorted { $0.path < $1.path }
                .prefix(maximumCodexMonthsPerYear)
            for monthDir in monthDirs {
                guard !Task.isCancelled, results.count < maximumCodexInstallRecords else { break }
                let dayDirs = ((try? directoryAccess.contentsOfDirectory(at: monthDir)) ?? [])
                    .filter { isNumericName($0) }
                    .sorted { $0.path < $1.path }
                    .prefix(maximumCodexDaysPerMonth)
                for dayDir in dayDirs {
                    guard !Task.isCancelled, results.count < maximumCodexInstallRecords else { break }
                    let sessionFiles = ((try? directoryAccess.contentsOfDirectory(at: dayDir)) ?? [])
                        .filter { $0.pathExtension == "jsonl" }
                        .sorted { $0.path < $1.path }
                    let remaining = maximumCodexInstallRecords - results.count
                    results.append(contentsOf: collectFromSessions(sessionFiles.prefix(remaining)))
                }
            }
        }
        return results
    }

    // MARK: - Per-session parsing

    private func collectFromSessions(_ files: some Collection<URL>) -> [InstalledByCodex] {
        var results: [InstalledByCodex] = []
        for fileURL in files {
            guard !Task.isCancelled, results.count < maximumCodexInstallRecords else { break }
            let remaining = maximumCodexInstallRecords - results.count
            results.append(contentsOf: parseSession(at: fileURL).prefix(remaining))
        }
        return results
    }

    private func parseSession(at url: URL) -> [InstalledByCodex] {
        guard !Task.isCancelled,
              let data = try? directoryAccess.data(
                  contentsOf: url,
                  maximumBytes: maximumCodexSessionBytes,
                  from: .suffix
              ) else { return [] }

        let formatter = makeTimestampFormatter()

        // First pass: session_meta provides the authoritative session id + cwd.
        var sessionId = sessionIdFromFileName(url)
        var projectPath = ""
        findSessionMeta(in: data, formatter: formatter, sessionId: &sessionId, projectPath: &projectPath)

        // Second pass: extract exec_command install commands.
        var results: [InstalledByCodex] = []

        UTF8LineReader.forEachLine(in: data) { rawLine in
            guard results.count < maximumCodexInstallRecords else { return false }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return true }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return true
            }

            let timestamp = (obj["timestamp"] as? String).flatMap(formatter.date)

            guard let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "function_call",
                  payload["name"] as? String == "exec_command",
                  let command = command(from: payload["arguments"]),
                  !command.isEmpty else { return true }

            let detections = detector.detect(command)
            guard !detections.isEmpty else { return true }

            let context = ProvenanceEvidence.CodexContext(
                sessionId: sessionId,
                projectPath: projectPath,
                sessionSummary: nil,
                firstUserMessage: nil,
                bashInvocation: command,
                timestamp: timestamp
            )

            for (pkgName, manager) in detections {
                results.append(InstalledByCodex(
                    packageName: pkgName,
                    manager: manager,
                    context: context
                ))
                if results.count == maximumCodexInstallRecords { break }
            }
            return results.count < maximumCodexInstallRecords
        }

        return results
    }

    // MARK: - First-pass helpers

    /// Extracts the authoritative session id and working directory from the
    /// `session_meta` event. Stops scanning once both are found.
    private func findSessionMeta(
        in data: Data,
        formatter: ISO8601DateFormatter,
        sessionId: inout String,
        projectPath: inout String
    ) {
        UTF8LineReader.forEachLine(in: data) { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["type"] as? String == "session_meta",
                  let payload = obj["payload"] as? [String: Any] else { return true }
            if let id = payload["id"] as? String, !id.isEmpty { sessionId = id }
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { projectPath = cwd }
            return false
        }
    }

    /// Recovers the command from a Codex `arguments` value. Codex encodes the
    /// arguments as a JSON string (`{"cmd":"…"}`); handle a decoded dict too.
    private func command(from arguments: Any?) -> String? {
        if let dict = arguments as? [String: Any] {
            guard let cmd = dict["cmd"] as? String, !cmd.isEmpty else { return nil }
            return cmd
        }
        if let jsonString = arguments as? String,
           let data = jsonString.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cmd = obj["cmd"] as? String,
           !cmd.isEmpty {
            return cmd
        }
        return nil
    }

    /// Falls back to the session id encoded in the rollout filename when no
    /// `session_meta` event is present: `rollout-<timestamp>-<uuid>.jsonl`.
    /// The UUID is extracted by shape, since both the timestamp and the UUID
    /// contain dashes.
    private func sessionIdFromFileName(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("rollout-") else { return name }
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: name,
                range: NSRange(name.startIndex..., in: name)
              ),
              let range = Range(match.range, in: name) else { return name }
        return String(name[range])
    }

    private func isNumericName(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return !name.isEmpty && name.allSatisfy(\.isNumber)
    }

    private func makeTimestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

private let maximumCodexSessionBytes = 16 * 1_024 * 1_024
private let maximumCodexYears = 16
private let maximumCodexMonthsPerYear = 12
private let maximumCodexDaysPerMonth = 31
private let maximumCodexInstallRecords = 50_000

// MARK: - Public types

/// A package install command detected inside a Codex `exec_command` call.
public struct InstalledByCodex: Sendable, Equatable {
    public let packageName: String
    public let manager: PackageManager
    public let context: ProvenanceEvidence.CodexContext

    public init(
        packageName: String,
        manager: PackageManager,
        context: ProvenanceEvidence.CodexContext
    ) {
        self.packageName = packageName
        self.manager = manager
        self.context = context
    }
}
