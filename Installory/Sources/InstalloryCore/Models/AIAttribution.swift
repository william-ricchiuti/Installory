import Foundation

/// Returns `true` when `evidence` indicates the package was installed during an AI assistant
/// coding session.
///
/// **Absence of evidence ≠ not AI-installed.** History may be truncated, provenance may be
/// off, or the package may predate collection. Only call this with evidence that was
/// actively collected; a `nil` argument simply means "unknown."
///
/// Claude Code, Codex, and opencode are the tracked sources today. The predicate
/// is named for the concept ("AI assistant") rather than any specific tool so
/// that future sources (e.g., Cursor, Copilot agents) can map in without a
/// user-visible rename.
///
/// Pure: no I/O, no side effects, deterministic.
public func wasInstalledByAIAssistant(_ evidence: ProvenanceEvidence?) -> Bool {
    evidence?.claudeCodeContext != nil
        || evidence?.codexContext != nil
        || evidence?.opencodeContext != nil
}

/// Agent-agnostic view of the AI coding session that installed a package.
///
/// Claude Code, Codex, and opencode each record their own context type on
/// ``ProvenanceEvidence``; this flattens whichever one is present into the
/// fields a UI needs, so callers never have to branch on the agent.
public struct AgentAttribution: Sendable, Equatable {
    /// The coding agent whose session ran the install command.
    public enum Agent: String, Sendable, Equatable, CaseIterable {
        case claudeCode
        case codex
        case opencode

        /// User-facing agent name, e.g. "Claude Code", "Codex", "opencode".
        public var displayName: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            case .opencode: return "opencode"
            }
        }
    }

    public let agent: Agent
    public let sessionId: String
    /// Working directory of the session (already redacted to `~/…` by the collector).
    public let projectPath: String
    /// Session summary or title, when the agent records one.
    public let sessionSummary: String?
    /// First user message in the session, truncated, when recoverable.
    public let firstUserMessage: String?
    /// When the install command ran, if known.
    public let timestamp: Date?
    /// The exact shell command the agent ran.
    public let command: String

    /// User-facing agent name, e.g. "Claude Code", "Codex", "opencode".
    public var agentName: String { agent.displayName }

    public init(
        agent: Agent,
        sessionId: String,
        projectPath: String,
        sessionSummary: String?,
        firstUserMessage: String?,
        timestamp: Date?,
        command: String
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.projectPath = projectPath
        self.sessionSummary = sessionSummary
        self.firstUserMessage = firstUserMessage
        self.timestamp = timestamp
        self.command = command
    }
}

extension ProvenanceEvidence {
    /// Every agent session context recorded on this evidence, in a fixed order:
    /// Claude Code, then Codex, then opencode.
    public var agentAttributions: [AgentAttribution] {
        var result: [AgentAttribution] = []
        if let c = claudeCodeContext {
            result.append(AgentAttribution(
                agent: .claudeCode, sessionId: c.sessionId, projectPath: c.projectPath,
                sessionSummary: c.sessionSummary, firstUserMessage: c.firstUserMessage,
                timestamp: c.timestamp, command: c.bashInvocation
            ))
        }
        if let c = codexContext {
            result.append(AgentAttribution(
                agent: .codex, sessionId: c.sessionId, projectPath: c.projectPath,
                sessionSummary: c.sessionSummary, firstUserMessage: c.firstUserMessage,
                timestamp: c.timestamp, command: c.bashInvocation
            ))
        }
        if let c = opencodeContext {
            result.append(AgentAttribution(
                agent: .opencode, sessionId: c.sessionId, projectPath: c.projectPath,
                sessionSummary: c.sessionSummary, firstUserMessage: c.firstUserMessage,
                timestamp: c.timestamp, command: c.bashInvocation
            ))
        }
        return result
    }

    /// The primary agent session that installed this package, or nil when no
    /// agent context was recorded. Uses the same precedence as
    /// ``agentAttributions`` (Claude Code, Codex, opencode).
    public var agentAttribution: AgentAttribution? {
        agentAttributions.first
    }
}
