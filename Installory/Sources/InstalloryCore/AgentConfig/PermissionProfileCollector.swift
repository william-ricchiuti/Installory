import Foundation

/// Reads permission-related settings for Claude Code and Codex.
struct PermissionProfileCollector {
    let homeDirectory: URL
    let projectRoots: [URL]
    let limits: AgentConfigAuditor.Limits

    func collect(
        reader: inout AgentConfigFileReader,
        codexConfig: (url: URL, root: [String: TOMLValue])?
    ) -> [PermissionProfile] {
        var profiles: [PermissionProfile] = []
        let userSettings = homeDirectory.appendingPathComponent(".claude/settings.json")
        if let profile = claudeProfile(at: userSettings, scope: .user, reader: &reader) {
            profiles.append(profile)
        }
        for project in projectRoots {
            let root = project.standardizedFileURL
            let shared = root.appendingPathComponent(".claude/settings.json")
            if let profile = claudeProfile(at: shared, scope: .project(root), reader: &reader) {
                profiles.append(profile)
            }
            let local = root.appendingPathComponent(".claude/settings.local.json")
            if let profile = claudeProfile(at: local, scope: .local(root), reader: &reader) {
                profiles.append(profile)
            }
        }
        if let codexConfig {
            profiles.append(Self.codexProfile(url: codexConfig.url, root: codexConfig.root))
        }
        return profiles
    }

    private func claudeProfile(
        at url: URL,
        scope: AgentConfigScope,
        reader: inout AgentConfigFileReader
    ) -> PermissionProfile? {
        guard let object = reader.readJSONObject(url, maximumBytes: limits.maximumConfigBytes) else {
            return nil
        }
        return Self.claudeProfile(from: object, url: url, scope: scope, limits: limits)
    }

    static func claudeProfile(
        from object: [String: Any],
        url: URL,
        scope: AgentConfigScope,
        limits: AgentConfigAuditor.Limits
    ) -> PermissionProfile {
        let permissions = object["permissions"] as? [String: Any] ?? [:]
        let cap = limits.maximumRulesPerList
        let skipPrompt = AgentConfigJSON.bool(object["skipDangerousModePermissionPrompt"])
            ?? AgentConfigJSON.bool(permissions["skipDangerousModePermissionPrompt"])
        return PermissionProfile(
            tool: .claudeCode,
            scope: scope,
            configFile: url,
            allow: Array(AgentConfigJSON.stringArray(permissions["allow"]).prefix(cap)).map(redactRule),
            ask: Array(AgentConfigJSON.stringArray(permissions["ask"]).prefix(cap)).map(redactRule),
            deny: Array(AgentConfigJSON.stringArray(permissions["deny"]).prefix(cap)).map(redactRule),
            defaultMode: AgentConfigJSON.string(permissions["defaultMode"]),
            hooks: hooks(from: object["hooks"], limit: limits.maximumHooks),
            maskedEnv: AgentConfigJSON.stringPairs(object["env"]).map {
                AgentConfigSecretMasker.maskedPair(key: $0.0, value: $0.1)
            },
            enableAllProjectMcpServers: AgentConfigJSON.bool(object["enableAllProjectMcpServers"]),
            skipDangerousModePermissionPrompt: skipPrompt
        )
    }

    /// Permission rules are usually short patterns, but "don't ask again"
    /// approvals can capture full command lines that include tokens.
    private static func redactRule(_ rule: String) -> String {
        AgentConfigSecretMasker.redactCommand(rule, maximumLength: 512)
    }

    /// Parses `hooks: { Event: [ { matcher, hooks: [ { type, command } ] } ] }`.
    static func hooks(from value: Any?, limit: Int) -> [AgentHook] {
        guard let events = value as? [String: Any] else { return [] }
        var result: [AgentHook] = []
        for event in events.keys.sorted() {
            guard let groups = events[event] as? [Any] else { continue }
            for case let group as [String: Any] in groups {
                let matcher = AgentConfigJSON.string(group["matcher"]).flatMap { $0.isEmpty ? nil : $0 }
                var commands: [String] = []
                if let hooks = group["hooks"] as? [Any] {
                    for case let hook as [String: Any] in hooks {
                        if let command = AgentConfigJSON.string(hook["command"]) {
                            commands.append(AgentConfigSecretMasker.redactCommand(command))
                        } else if let type = AgentConfigJSON.string(hook["type"]) {
                            commands.append("(\(type) hook)")
                        }
                    }
                } else if let command = AgentConfigJSON.string(group["command"]) {
                    commands.append(AgentConfigSecretMasker.redactCommand(command))
                }
                guard !commands.isEmpty else { continue }
                result.append(AgentHook(event: event, matcher: matcher, commands: commands))
                if result.count >= limit { return result }
            }
        }
        return result
    }

    static func codexProfile(url: URL, root: [String: TOMLValue]) -> PermissionProfile {
        PermissionProfile(
            tool: .codex,
            scope: .user,
            configFile: url,
            approvalPolicy: root["approval_policy"]?.stringValue,
            sandboxMode: root["sandbox_mode"]?.stringValue
        )
    }
}
