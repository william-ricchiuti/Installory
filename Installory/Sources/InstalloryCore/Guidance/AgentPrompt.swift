import Foundation

/// The AI coding agent a copyable prompt is written for.
///
/// Only affects light wording (the greeting). The substance and the
/// guardrails are identical for every agent.
public enum PromptAgent: String, Sendable, Equatable, Hashable, CaseIterable {
    case claudeCode
    case codex
    case generic

    /// Human-readable agent name, or nil for `.generic`.
    public var displayName: String? {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .generic: nil
        }
    }
}

/// A ready-to-copy prompt the user can paste into their AI coding agent.
///
/// Installory is read-only and never runs fixes itself; instead it hands the
/// user a prompt that asks their agent to investigate, explain, and only then
/// act — with the user's explicit OK.
public struct AgentPrompt: Sendable, Equatable, Hashable {
    /// Short label for the UI (button tooltip, sheet title). Not part of the prompt text.
    public let title: String
    /// The text to copy to the clipboard.
    public let body: String
    public let targetAgent: PromptAgent

    public init(title: String, body: String, targetAgent: PromptAgent) {
        self.title = title
        self.body = body
        self.targetAgent = targetAgent
    }
}

/// A generic finding a prompt can be attached to (MCP-server problems,
/// exposed secrets, broken config, and future checks).
///
/// For `.exposedSecret` there is deliberately no field for the secret value:
/// the prompt only ever names the file(s) and the key name.
public struct PromptFinding: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        /// Any non-secret finding; `explanation` is included in the prompt.
        case general
        /// An API key or token stored in plain text. `keyName` is the variable
        /// or field name (e.g. `OPENAI_API_KEY`), never the value. The
        /// caller-supplied `explanation` is NOT copied into this prompt, so a
        /// value that slipped into it cannot leak.
        case exposedSecret(keyName: String)
    }

    public let kind: Kind
    public let title: String
    public let explanation: String
    public let filePaths: [URL]

    public init(kind: Kind = .general, title: String, explanation: String, filePaths: [URL]) {
        self.kind = kind
        self.title = title
        self.explanation = explanation
        self.filePaths = filePaths
    }
}
