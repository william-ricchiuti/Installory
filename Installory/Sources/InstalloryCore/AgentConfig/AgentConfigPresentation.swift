import Foundation

// Read-only helpers the app uses to present an audit. They only look at values
// that were already masked at parse time; none of them expose a secret value.

extension AgentHook {
    /// Plain-English trigger, e.g. "After the agent uses a tool".
    public var triggerDescription: String {
        AgentConfigFindingRules.eventDescription(event)
    }
}

extension PermissionProfile {
    /// Why an auto-approved rule is broad enough to be risky, or nil when the
    /// rule is narrow (e.g. `Bash(npm run test:*)`).
    public static func broadAllowRuleExplanation(_ rule: String) -> String? {
        AgentConfigFindingRules.broadRuleExplanation(rule)
    }

    /// Auto-approved rules that are broad enough to be risky.
    public var broadAllowRules: [String] {
        allow.filter { Self.broadAllowRuleExplanation($0) != nil }
    }
}

extension MCPServerEntry {
    /// Names of environment variables and headers that hold a literal secret.
    /// Key names only; values are never returned.
    public var literalSecretKeyNames: [String] {
        (maskedEnv + maskedHeaders).filter(\.isLiteralSecret).map(\.key)
    }

    /// True when any env value, header or argument holds a literal secret.
    public var hasLiteralSecret: Bool {
        hasInlineSecret || maskedEnv.contains(where: \.isLiteralSecret)
            || maskedHeaders.contains(where: \.isLiteralSecret)
    }
}

extension AgentConfigAudit {
    /// How many secrets are written directly into AI tool settings: each
    /// literal MCP env value or header, each server with a key in its command
    /// line or address, and each literal value in an agent settings `env`.
    public var literalSecretCount: Int {
        let serverSecrets = servers.reduce(0) { total, server in
            total + server.literalSecretKeyNames.count + (server.hasInlineSecret ? 1 : 0)
        }
        let settingsSecrets = permissionProfiles.reduce(0) { total, profile in
            total + profile.maskedEnv.filter(\.isLiteralSecret).count
        }
        return serverSecrets + settingsSecrets
    }

    /// The variable or field name behind a secret finding (never the value),
    /// or nil for findings that aren't about a written-down secret, or when the
    /// secret has no name (a key inside a command line or server address).
    public func secretKeyName(for finding: AgentConfigFinding) -> String? {
        switch finding.kind {
        case .mcpLiteralSecret:
            return finding.affectedServers.lazy.flatMap(\.literalSecretKeyNames).first
        case .settingsLiteralSecret:
            let files = Set(finding.affectedFiles.map(\.standardizedFileURL.path))
            return permissionProfiles
                .filter { files.contains($0.configFile.path) }
                .lazy
                .flatMap { $0.maskedEnv.filter(\.isLiteralSecret).map(\.key) }
                .first
        default:
            return nil
        }
    }
}

extension AgentConfigFinding {
    /// True for findings about a password or API key written in a config file.
    /// Their explanations contain partially masked values, so they must never
    /// be copied into a prompt.
    public var isLiteralSecret: Bool {
        kind == .mcpLiteralSecret || kind == .settingsLiteralSecret
    }
}
