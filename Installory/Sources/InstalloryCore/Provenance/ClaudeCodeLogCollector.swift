import Foundation

/// Walks ~/.claude/projects, reads Claude Code session JSONL transcripts,
/// and returns every package install command found inside a Bash tool_use.
public struct ClaudeCodeLogCollector: Sendable {
    private let directoryAccess: any DirectoryAccessProvider
    private let homeDirectory: URL
    private let detector: InstallCommandDetector
    private let limits: ProvenanceCollectionLimits
    private let cache: (any ProvenanceFileCacheStore)?
    private let redactor = ProvenanceRedactor()

    /// - Parameters:
    ///   - limits: Byte and wall-clock budgets for one collection run.
    ///   - cache: Optional per-file cache. When set, returned records are
    ///     already redacted (cache hits and fresh parses alike) so evidence is
    ///     identical whichever path produced it.
    public init(
        directoryAccess: any DirectoryAccessProvider = SystemDirectoryAccessProvider(),
        homeDirectory: URL = UserHome.directory,
        detector: InstallCommandDetector = InstallCommandDetector(),
        limits: ProvenanceCollectionLimits = .default,
        cache: (any ProvenanceFileCacheStore)? = nil
    ) {
        self.directoryAccess = directoryAccess
        self.homeDirectory = homeDirectory
        self.detector = detector
        self.limits = limits
        self.cache = cache
    }

    /// Walks ~/.claude/projects, parses sessions newest first (by modification
    /// date), and returns every install command found inside a Bash tool_use,
    /// with full session context attached. Stops early when the byte or time
    /// budget in ``ProvenanceCollectionLimits`` is spent.
    public func collect() -> [InstalledByClaudeCode] {
        collectWithReport().records
    }

    /// Like ``collect()`` and also reports counters (no log content).
    public func collectWithReport() -> (records: [InstalledByClaudeCode], report: ProvenanceCollectionReport) {
        var report = ProvenanceCollectionReport()
        guard !Task.isCancelled else {
            report.stopReason = .cancelled
            return ([], report)
        }
        let projectsURL = homeDirectory
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")

        guard let projectDirs = try? directoryAccess.contentsOfDirectory(at: projectsURL) else {
            return ([], report)
        }

        var budget = ProvenanceScanBudget(limits: limits)
        var cacheSession = ProvenanceFileCacheSession<CachedAgentInstall<ProvenanceEvidence.ClaudeCodeContext>>(
            store: cache,
            source: .claudeCode
        )

        // Gather every session with its modification date, then visit them
        // newest first across all projects.
        var sessions: [SessionFile] = []
        for projectDir in projectDirs.sorted(by: { $0.path < $1.path }).prefix(maximumClaudeProjects) {
            if Task.isCancelled {
                report.stopReason = .cancelled
                return ([], report)
            }
            if budget.isTimeExpired { break }
            let children = ((try? directoryAccess.contentsOfDirectory(at: projectDir)) ?? [])
                .filter { $0.pathExtension == "jsonl" }
            let dated = children.map { url in
                SessionFile(url: url, projectDir: projectDir, modifiedAt: directoryAccess.modificationDate(at: url))
            }
            sessions.append(contentsOf: dated.sorted(by: SessionFile.newestFirst).prefix(maximumClaudeSessionsPerProject))
        }
        sessions.sort(by: SessionFile.newestFirst)

        var summariesByProject: [String: [String: String]] = [:]
        var results: [InstalledByClaudeCode] = []
        for session in sessions {
            if Task.isCancelled {
                report.stopReason = .cancelled
                break
            }
            if results.count >= maximumClaudeInstallRecords {
                report.stopReason = .recordLimit
                break
            }
            if budget.isTimeExpired {
                report.stopReason = .timeBudget
                break
            }
            report.filesVisited += 1
            let remaining = maximumClaudeInstallRecords - results.count

            let stamp = cacheSession.isEnabled
                ? ProvenanceFileStamp.of(session.url, using: directoryAccess)
                : nil
            if let cached = cacheSession.records(for: session.url, stamp: stamp) {
                report.cacheHits += 1
                results.append(contentsOf: cached.prefix(remaining).map(InstalledByClaudeCode.init(cached:)))
                continue
            }
            if budget.isByteBudgetSpent {
                report.stopReason = .byteBudget
                report.filesSkippedForBudget += 1
                continue
            }

            // Build an initial project path from the dashed directory name.
            // This is lossy when the real path contains hyphens (e.g. my-app → my/app).
            // The cwd field in each JSONL event overrides this guess — see parseSession.
            let dirName = session.projectDir.lastPathComponent
            let initialProjectPath = "/" + dirName.replacingOccurrences(of: "-", with: "/")
            let sessionId = session.url.deletingPathExtension().lastPathComponent
            let projectKey = session.projectDir.path

            guard let parsed = parseSession(
                at: session.url,
                sessionIdFromFile: sessionId,
                initialProjectPath: initialProjectPath,
                sessionSummary: {
                    // Loaded lazily: only sessions with install records need it.
                    if let summaries = summariesByProject[projectKey] {
                        return summaries[sessionId]
                    }
                    let summaries = loadSessionSummaries(from: session.projectDir)
                    summariesByProject[projectKey] = summaries
                    return summaries[sessionId]
                },
                budget: &budget
            ) else { continue }
            report.filesParsed += 1
            guard !Task.isCancelled else {
                report.stopReason = .cancelled
                break
            }
            if cacheSession.isEnabled {
                let cachedForm = parsed.map(cachedRecord(from:))
                cacheSession.store(cachedForm, for: session.url, stamp: stamp)
                results.append(contentsOf: cachedForm.prefix(remaining).map(InstalledByClaudeCode.init(cached:)))
            } else {
                results.append(contentsOf: parsed.prefix(remaining))
            }
        }
        report.bytesRead = budget.bytesRead
        if report.stopReason != .cancelled {
            cacheSession.finish(directoryAccess: directoryAccess)
        }
        return (results, report)
    }

    /// Redacts the context for persistence and keeps the scope hints derived
    /// from the original command.
    private func cachedRecord(
        from record: InstalledByClaudeCode
    ) -> CachedAgentInstall<ProvenanceEvidence.ClaudeCodeContext> {
        CachedAgentInstall(
            packageName: record.packageName,
            manager: record.manager,
            context: redactor.redact(record.context),
            qualifierHints: Array(ProvenanceCollector.agentQualifierHints(
                command: record.context.bashInvocation,
                manager: record.manager,
                packageName: record.packageName,
                detector: detector
            ))
        )
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

    /// Returns nil when the file could not be read.
    private func parseSession(
        at url: URL,
        sessionIdFromFile: String,
        initialProjectPath: String,
        sessionSummary: () -> String?,
        budget: inout ProvenanceScanBudget
    ) -> [InstalledByClaudeCode]? {
        guard !Task.isCancelled,
              let data = try? directoryAccess.data(
                  contentsOf: url,
                  maximumBytes: maximumClaudeSessionBytes,
                  from: .suffix
              ) else { return nil }
        budget.bytesRead += data.count

        let formatter = makeTimestampFormatter()

        // Extract Bash tool_use install commands. projectPath is refined
        // in-place from the cwd field as events are processed; lines that fail
        // the prefilter are not decoded, but their cwd is still tracked.
        var projectPath = initialProjectPath
        var lastRawCwd: [UInt8] = []
        var pending: [PendingInstall] = []

        UTF8LineReader.forEachLineBuffer(in: data) { buffer in
            guard pending.count < maximumClaudeInstallRecords else { return false }
            guard ProvenanceLinePrefilter.claudeToolCall.mayContainInstall(buffer) else {
                if let cwd = Self.cheapCwd(in: buffer, lastRaw: &lastRawCwd), cwd.hasPrefix("/") {
                    projectPath = cwd
                }
                return true
            }
            guard let rawLine = UTF8LineReader.decode(buffer) else { return true }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return true }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return true
            }

            // cwd is the ground-truth project path; override the dashed-name guess.
            if let cwd = obj["cwd"] as? String, cwd.hasPrefix("/") {
                projectPath = cwd
                lastRawCwd = []
            }

            guard let message = obj["message"] as? [String: Any],
                  message["role"] as? String == "assistant",
                  let contentArray = message["content"] as? [[String: Any]] else { return true }

            let sessionId = obj["sessionId"] as? String ?? sessionIdFromFile
            let tsStr = obj["timestamp"] as? String ?? ""
            let timestamp = formatter.date(from: tsStr)

            for block in contentArray {
                guard pending.count < maximumClaudeInstallRecords else { break }
                guard block["type"] as? String == "tool_use",
                      block["name"] as? String == "Bash",
                      let input = block["input"] as? [String: Any],
                      let command = input["command"] as? String else { continue }

                let detections = detector.detect(command)
                guard !detections.isEmpty else { continue }

                for (pkgName, manager) in detections {
                    pending.append(PendingInstall(
                        packageName: pkgName,
                        manager: manager,
                        sessionId: sessionId,
                        projectPath: projectPath,
                        command: command,
                        timestamp: timestamp
                    ))
                    if pending.count == maximumClaudeInstallRecords { break }
                }
            }
            return pending.count < maximumClaudeInstallRecords
        }

        guard !pending.isEmpty else { return [] }

        // Only sessions with installs pay for the first-user-message pass and
        // the summary index read. The chronologically first user message is
        // chosen by timestamp, not file position — events can arrive out of
        // order in long sessions.
        let firstUserMessage = findFirstUserMessage(in: data, formatter: formatter)
        let summary = sessionSummary()

        return pending.map { install in
            InstalledByClaudeCode(
                packageName: install.packageName,
                manager: install.manager,
                context: ProvenanceEvidence.ClaudeCodeContext(
                    sessionId: install.sessionId,
                    projectPath: install.projectPath,
                    sessionSummary: summary,
                    firstUserMessage: firstUserMessage,
                    bashInvocation: install.command,
                    timestamp: install.timestamp
                )
            )
        }
    }

    /// Reads the first `"cwd":"…"` value from a line without decoding the
    /// whole event. Claude Code writes the top-level `cwd` before `message`,
    /// so the first occurrence is the event's own. Returns nil when absent or
    /// unchanged since the previous line.
    private static func cheapCwd(in buffer: UnsafeRawBufferPointer, lastRaw: inout [UInt8]) -> String? {
        guard let base = buffer.baseAddress else { return nil }
        let key = cwdKey
        let found = key.withUnsafeBytes { keyBytes in
            memmem(base, buffer.count, keyBytes.baseAddress!, keyBytes.count)
        }
        guard let found else { return nil }
        let valueStart = UnsafeRawPointer(found) - base + key.count
        var index = valueStart
        var escaped = false
        while index < buffer.count {
            let byte = buffer[index]
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                break
            }
            index += 1
        }
        guard index < buffer.count else { return nil }
        let raw = Array(buffer[valueStart..<index])
        guard raw != lastRaw else { return nil }
        lastRaw = raw
        let quoted = Data([0x22] + raw + [0x22])
        return (try? JSONSerialization.jsonObject(with: quoted, options: .fragmentsAllowed)) as? String
    }

    private static let cwdKey = Array(#""cwd":""#.utf8)

    // MARK: - First-pass helpers

    /// Returns the text of the user message with the earliest timestamp in the session.
    ///
    /// Walks the bounded data buffer directly to avoid retaining an intermediate
    /// line array or a second full-file string.
    /// Only user-role events with non-empty text content are considered.
    private func findFirstUserMessage(in data: Data, formatter: ISO8601DateFormatter) -> String? {
        var earliest: (ts: TimeInterval, text: String)? = nil

        UTF8LineReader.forEachLineBuffer(in: data) { buffer in
            guard ProvenanceLinePrefilter.contains(buffer, "user"),
                  let rawLine = UTF8LineReader.decode(buffer) else { return true }
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
    /// Scope hints from the original command; set only for cached (redacted)
    /// records, whose command text can no longer be re-classified exactly.
    var qualifierHints: Set<InstallQualifierHint?>? = nil

    init(
        packageName: String,
        manager: PackageManager,
        context: ProvenanceEvidence.ClaudeCodeContext,
        qualifierHints: Set<InstallQualifierHint?>? = nil
    ) {
        self.packageName = packageName
        self.manager = manager
        self.context = context
        self.qualifierHints = qualifierHints
    }

    init(cached: CachedAgentInstall<ProvenanceEvidence.ClaudeCodeContext>) {
        self.init(
            packageName: cached.packageName,
            manager: cached.manager,
            context: cached.context,
            qualifierHints: Set(cached.qualifierHints)
        )
    }
}

/// An install found while walking a session, before session-wide context
/// (first user message, summary) is attached.
private struct PendingInstall {
    let packageName: String
    let manager: PackageManager
    let sessionId: String
    let projectPath: String
    let command: String
    let timestamp: Date?
}

/// A session transcript and the project directory it belongs to.
private struct SessionFile {
    let url: URL
    let projectDir: URL
    let modifiedAt: Date?

    /// Most recently modified first; undated files last; path as tie-breaker.
    static func newestFirst(_ lhs: SessionFile, _ rhs: SessionFile) -> Bool {
        switch (lhs.modifiedAt, rhs.modifiedAt) {
        case let (l?, r?) where l != r:
            return l > r
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            return lhs.url.path < rhs.url.path
        }
    }
}
