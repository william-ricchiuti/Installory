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
            // The user's first prompt is free text that can hold anything they
            // pasted (keys, personal details). It isn't needed to match an
            // install, so it is never kept.
            firstUserMessage: nil,
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
            // The user's first prompt is free text that can hold anything they
            // pasted (keys, personal details). It isn't needed to match an
            // install, so it is never kept.
            firstUserMessage: nil,
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
            // The user's first prompt is free text that can hold anything they
            // pasted (keys, personal details). It isn't needed to match an
            // install, so it is never kept.
            firstUserMessage: nil,
            bashInvocation: redactText(context.bashInvocation, maximumLength: 2_048),
            timestamp: context.timestamp
        )
    }

    /// Redacts secrets in arbitrary provenance text while retaining surrounding
    /// command syntax and package names.
    public func redactText(_ text: String, maximumLength: Int = 2_048) -> String {
        var value = boundedForProcessing(text)
        value = minimizeHomePaths(in: value)

        // Shared rules with the AI Setup audit (keys, tokens, URLs with
        // credentials, credential flags, webhook URLs, private keys).
        value = SecretRedaction.redact(value, replacement: "[REDACTED]")

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
        // A user name may contain spaces (`/Users/John Smith/…`): allow up to
        // three space-separated words when a `/` follows directly.
        value = replacing(
            #"(?<![A-Za-z0-9._-])/(?:Users|home)/[^/\s\"']+(?: [^/\s\"']+){1,3}(?=/)"#,
            in: value,
            with: "~"
        )
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
