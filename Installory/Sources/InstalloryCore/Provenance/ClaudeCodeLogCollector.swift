import Foundation

/// Walks ~/.claude/projects, reads Claude Code session JSONL transcripts,
/// and returns every package install command found inside a Bash tool_use.
public struct ClaudeCodeLogCollector: Sendable {
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

    /// Walks ~/.claude/projects, parses every session, and returns every
    /// install command found inside a Bash tool_use, with full session
    /// context attached.
    public func collect() -> [InstalledByClaudeCode] {
        guard !Task.isCancelled else { return [] }
        let projectsURL = homeDirectory
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")

        guard let projectDirs = try? directoryAccess.contentsOfDirectory(at: projectsURL) else {
            return []
        }

        var results: [InstalledByClaudeCode] = []
        for projectDir in projectDirs.sorted(by: { $0.path < $1.path }).prefix(maximumClaudeProjects) {
            guard !Task.isCancelled, results.count < maximumClaudeInstallRecords else { break }
            let remaining = maximumClaudeInstallRecords - results.count
            results.append(contentsOf: collectFromProject(projectDir).prefix(remaining))
        }
        return results
    }

    // MARK: - Per-project

    private func collectFromProject(_ projectDir: URL) -> [InstalledByClaudeCode] {
        // Build an initial project path from the dashed directory name.
        // This is lossy when the real path contains hyphens (e.g. my-app → my/app).
        // The cwd field in each JSONL event overrides this guess — see parseSession.
        let dirName = projectDir.lastPathComponent
        let initialProjectPath = "/" + dirName.replacingOccurrences(of: "-", with: "/")

        let summaries = loadSessionSummaries(from: projectDir)

        guard !Task.isCancelled else { return [] }
        let children = ((try? directoryAccess.contentsOfDirectory(at: projectDir)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.path < $1.path }

        var results: [InstalledByClaudeCode] = []
        for fileURL in children.prefix(maximumClaudeSessionsPerProject) {
            guard !Task.isCancelled, results.count < maximumClaudeInstallRecords else { break }
            let sessionId = fileURL.deletingPathExtension().lastPathComponent
            let remaining = maximumClaudeInstallRecords - results.count
            results.append(contentsOf: parseSession(
                at: fileURL,
                sessionIdFromFile: sessionId,
                initialProjectPath: initialProjectPath,
                sessionSummary: summaries[sessionId]
            ).prefix(remaining))
        }
        return results
    }

    private func loadSessionSummaries(from projectDir: URL) -> [String: String] {
        let indexURL = projectDir.appendingPathComponent("sessions-index.json")
        guard !Task.isCancelled,
              let data = try? directoryAccess.data(
                  contentsOf: indexURL,
                  maximumBytes: maximumClaudeIndexBytes,
                  from: .prefix
              ),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = obj["sessions"] as? [[String: Any]] else { return [:] }

        var result: [String: String] = [:]
        for session in sessions.prefix(maximumClaudeSessionsPerProject) {
            guard !Task.isCancelled else { break }
            if let id = session["id"] as? String,
               let summary = session["summary"] as? String,
               !summary.isEmpty {
                result[id] = summary
            }
        }
        return result
    }

    // MARK: - Per-session parsing

    private func parseSession(
        at url: URL,
        sessionIdFromFile: String,
        initialProjectPath: String,
        sessionSummary: String?
    ) -> [InstalledByClaudeCode] {
        guard !Task.isCancelled,
              let data = try? directoryAccess.data(
                  contentsOf: url,
                  maximumBytes: maximumClaudeSessionBytes,
                  from: .suffix
              ) else { return [] }

        let formatter = makeTimestampFormatter()

        // First pass: find the chronologically first user message (sorted by timestamp,
        // not file position — events can arrive out of order in long sessions).
        let firstUserMessage = findFirstUserMessage(in: data, formatter: formatter)

        // Second pass: extract Bash tool_use install commands.
        // projectPath is refined in-place from the cwd field as events are processed.
        var projectPath = initialProjectPath
        var results: [InstalledByClaudeCode] = []

        UTF8LineReader.forEachLine(in: data) { rawLine in
            guard results.count < maximumClaudeInstallRecords else { return false }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return true }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return true
            }

            // cwd is the ground-truth project path; override the dashed-name guess.
            if let cwd = obj["cwd"] as? String, cwd.hasPrefix("/") {
                projectPath = cwd
            }

            guard let message = obj["message"] as? [String: Any],
                  message["role"] as? String == "assistant",
                  let contentArray = message["content"] as? [[String: Any]] else { return true }

            let sessionId = obj["sessionId"] as? String ?? sessionIdFromFile
            let tsStr = obj["timestamp"] as? String ?? ""
            let timestamp = formatter.date(from: tsStr)

            for block in contentArray {
                guard results.count < maximumClaudeInstallRecords else { break }
                guard block["type"] as? String == "tool_use",
                      block["name"] as? String == "Bash",
                      let input = block["input"] as? [String: Any],
                      let command = input["command"] as? String else { continue }

                let detections = detector.detect(command)
                guard !detections.isEmpty else { continue }

                let context = ProvenanceEvidence.ClaudeCodeContext(
                    sessionId: sessionId,
                    projectPath: projectPath,
                    sessionSummary: sessionSummary,
                    firstUserMessage: firstUserMessage,
                    bashInvocation: command,
                    timestamp: timestamp
                )

                for (pkgName, manager) in detections {
                    results.append(InstalledByClaudeCode(
                        packageName: pkgName,
                        manager: manager,
                        context: context
                    ))
                    if results.count == maximumClaudeInstallRecords { break }
                }
            }
            return results.count < maximumClaudeInstallRecords
        }

        return results
    }

    // MARK: - First-pass helpers

    /// Returns the text of the user message with the earliest timestamp in the session.
    ///
    /// Walks the bounded data buffer directly to avoid retaining an intermediate
    /// line array or a second full-file string.
    /// Only user-role events with non-empty text content are considered.
    private func findFirstUserMessage(in data: Data, formatter: ISO8601DateFormatter) -> String? {
        var earliest: (ts: TimeInterval, text: String)? = nil

        UTF8LineReader.forEachLine(in: data) { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  message["role"] as? String == "user",
                  let tsStr = obj["timestamp"] as? String,
                  let ts = formatter.date(from: tsStr),
                  let text = extractFirstText(from: message["content"]),
                  !text.isEmpty else { return true }

            let tsValue = ts.timeIntervalSince1970
            if earliest == nil || tsValue < earliest!.ts {
                earliest = (ts: tsValue, text: text)
            }
            return true
        }

        return earliest?.text
    }

    /// Extracts the first non-empty text string from a message content value.
    ///
    /// Handles both array-of-blocks (standard) and plain-string (some user messages) forms.
    private func extractFirstText(from content: Any?) -> String? {
        if let str = content as? String, !str.isEmpty {
            return str
        }
        if let blocks = content as? [[String: Any]] {
            for block in blocks {
                if block["type"] as? String == "text",
                   let text = block["text"] as? String,
                   !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private func makeTimestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

private let maximumClaudeIndexBytes = 2 * 1_024 * 1_024
private let maximumClaudeSessionBytes = 16 * 1_024 * 1_024
private let maximumClaudeProjects = 1_024
private let maximumClaudeSessionsPerProject = 2_000
private let maximumClaudeInstallRecords = 50_000

// MARK: - Public types

/// A package install command detected inside a Claude Code Bash tool_use.
public struct InstalledByClaudeCode: Sendable, Equatable {
    public let packageName: String
    public let manager: PackageManager
    public let context: ProvenanceEvidence.ClaudeCodeContext
}
