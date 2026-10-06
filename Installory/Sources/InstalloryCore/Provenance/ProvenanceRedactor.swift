import Foundation

/// Removes common credentials and unnecessary personal path detail from provenance
/// before it crosses a persistence or presentation boundary.
///
/// Redaction intentionally preserves the package-manager command and target so the
/// evidence remains useful. Free-form fields are bounded after redaction to prevent
/// shell history or transcript records from creating unbounded database/UI payloads.
public struct ProvenanceRedactor: Sendable {
    private let homePath: String

    public init(homeDirectory: URL = UserHome.directory) {
        self.homePath = homeDirectory.standardizedFileURL.path
    }

    public func redact(_ evidence: ProvenanceEvidence) -> ProvenanceEvidence {
        ProvenanceEvidence(
            packageId: evidence.packageId,
            fsInstallTime: evidence.fsInstallTime,
            fsInstallTimeSource: evidence.fsInstallTimeSource.map {
                redactText($0, maximumLength: 256)
            },
            installCommand: evidence.installCommand.map(redact),
            claudeCodeContext: evidence.claudeCodeContext.map(redact),
            codexContext: evidence.codexContext.map(redact),
            opencodeContext: evidence.opencodeContext.map(redact),
            nearbyProjects: evidence.nearbyProjects.map {
                ProvenanceEvidence.NearbyProject(
                    path: redactPath($0.path),
                    modifiedFileCount: $0.modifiedFileCount,
                    gitCommitsThatDay: $0.gitCommitsThatDay
                )
            },
            coInstalledWithin1h: evidence.coInstalledWithin1h,
            coInstalledWithin1hTotalCount: evidence.coInstalledWithin1hTotalCount,
            overallConfidence: evidence.overallConfidence,
            collectedAt: evidence.collectedAt
        )
    }

    public func redact(
        _ record: ProvenanceEvidence.InstallCommandRecord
    ) -> ProvenanceEvidence.InstallCommandRecord {
        ProvenanceEvidence.InstallCommandRecord(
            timestamp: record.timestamp,
            command: redactText(record.command, maximumLength: 2_048),
            shell: record.shell,
            cwd: record.cwd.map(redactPath)
        )
    }

    public func redact(
        _ context: ProvenanceEvidence.ClaudeCodeContext
    ) -> ProvenanceEvidence.ClaudeCodeContext {
        ProvenanceEvidence.ClaudeCodeContext(
            sessionId: bounded(context.sessionId, maximumLength: 128),
            projectPath: redactPath(context.projectPath),
            sessionSummary: context.sessionSummary.map {
                redactText($0, maximumLength: 512)
            },
            firstUserMessage: context.firstUserMessage.map {
                redactText($0, maximumLength: 512)
            },
            bashInvocation: redactText(context.bashInvocation, maximumLength: 2_048),
            timestamp: context.timestamp
        )
    }

    public func redact(
        _ context: ProvenanceEvidence.CodexContext
    ) -> ProvenanceEvidence.CodexContext {
        ProvenanceEvidence.CodexContext(
            sessionId: bounded(context.sessionId, maximumLength: 128),
            projectPath: redactPath(context.projectPath),
            sessionSummary: context.sessionSummary.map {
                redactText($0, maximumLength: 512)
            },
            firstUserMessage: context.firstUserMessage.map {
                redactText($0, maximumLength: 512)
            },
            bashInvocation: redactText(context.bashInvocation, maximumLength: 2_048),
            timestamp: context.timestamp
        )
    }

    public func redact(
        _ context: ProvenanceEvidence.OpenCodeContext
    ) -> ProvenanceEvidence.OpenCodeContext {
        ProvenanceEvidence.OpenCodeContext(
            sessionId: bounded(context.sessionId, maximumLength: 128),
            projectPath: redactPath(context.projectPath),
            sessionSummary: context.sessionSummary.map {
                redactText($0, maximumLength: 512)
            },
            firstUserMessage: context.firstUserMessage.map {
                redactText($0, maximumLength: 512)
            },
            bashInvocation: redactText(context.bashInvocation, maximumLength: 2_048),
            timestamp: context.timestamp
        )
    }

    /// Redacts secrets in arbitrary provenance text while retaining surrounding
    /// command syntax and package names.
    public func redactText(_ text: String, maximumLength: Int = 2_048) -> String {
        var value = boundedForProcessing(text)
        value = minimizeHomePaths(in: value)

        // PEM blocks sometimes reach transcripts through pasted commands/prompts.
        value = replacing(
            #"(?is)-----BEGIN [^-\r\n]+ PRIVATE KEY-----.*?-----END [^-\r\n]+ PRIVATE KEY-----"#,
            in: value,
            with: "[REDACTED PRIVATE KEY]"
        )

        // Strip both username and password from credential-bearing URLs while
        // retaining scheme, host, and path as useful installation context.
        value = replacing(
            #"(?i)([a-z][a-z0-9+.-]*://)([^\s/@:]+):([^\s/@]+)@"#,
            in: value,
            with: "$1[REDACTED]@"
        )

        // Handle complete Authorization schemes before the generic key/value
        // rule can consume only the scheme name and leave the credential.
        value = replacing(
            #"(?i)(\b(?:Bearer|Basic)\s+)[A-Za-z0-9._~+/-]{4,}={0,2}"#,
            in: value,
            with: "$1[REDACTED]"
        )

        // Optional namespace prefixes cover common environment names such as
        // OPENAI_API_KEY, AWS_SECRET_ACCESS_KEY, and NPM_TOKEN.
        let secretKey = #"(?:[a-z0-9]+[_-])*(?:api[_-]?key|secret[_-]?access[_-]?key|client[_-]?secret|access[_-]?token|session[_-]?token|refresh[_-]?token|private[_-]?token|authorization|password|passwd|pwd|secret|token)"#
        let boundary = #"(?:^|[\s,;{?&])"#

        // Quoted values first, so spaces inside a quoted secret are removed too.
        value = replacing(
            "(?i)(\(boundary)(?:--?)?[\"']?\(secretKey)[\"']?\\s*(?::|=|\\s+)\\s*)[\"'][^\"'\\r\\n]*[\"']",
            in: value,
            with: "$1[REDACTED]"
        )
        value = replacing(
            "(?i)(\(boundary)(?:--?)?[\"']?\(secretKey)[\"']?\\s*(?::|=|\\s+)\\s*)[^\\s,;&|}]+",
            in: value,
            with: "$1[REDACTED]"
        )
        // Common standalone token formats that can appear without a key label.
        value = replacing(
            #"\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|xox[baprs]-[A-Za-z0-9-]{16,}|AKIA[0-9A-Z]{16})\b"#,
            in: value,
            with: "[REDACTED]"
        )
        value = replacing(
            #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
            in: value,
            with: "[REDACTED]"
        )

        return bounded(value, maximumLength: maximumLength)
    }

    public func redactPath(_ path: String) -> String {
        redactText(path, maximumLength: 512)
    }

    private func minimizeHomePaths(in text: String) -> String {
        var value = text
        if homePath != "/" && !homePath.isEmpty {
            let escapedHome = NSRegularExpression.escapedPattern(for: homePath)
            value = replacing("\(escapedHome)(?=/|$)", in: value, with: "~")
        }
        // Also protect evidence imported from another account or an older Mac.
        return replacing(
            #"(?<![A-Za-z0-9._-])/(?:Users|home)/[^/\s\"']+(?=/|$)"#,
            in: value,
            with: "~"
        )
    }

    private func replacing(_ pattern: String, in value: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: template
        )
    }

    /// Caps regex work while preserving both the command prefix and its target.
    private func boundedForProcessing(_ value: String) -> String {
        let limit = 16_384
        guard value.count > limit else { return value }
        return String(value.prefix(12_288)) + " … " + String(value.suffix(4_096))
    }

    private func bounded(_ value: String, maximumLength: Int) -> String {
        guard maximumLength > 0 else { return "" }
        guard value.count > maximumLength else { return value }
        if maximumLength == 1 { return "…" }
        return String(value.prefix(maximumLength - 1)) + "…"
    }
}
