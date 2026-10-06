import Foundation

/// Reads MCP server declarations from every supported AI app's config files.
///
/// Only the keys that describe MCP servers are plucked from each file. In
/// particular `~/.claude.json` also stores sign-in and session data; this
/// collector reads only `mcpServers`, `projects.<path>.mcpServers`,
/// `projects.<path>.disabledMcpServers` and
/// `projects.<path>.disabledMcpjsonServers` from it and keeps nothing else.
struct MCPServerCollector {
    let homeDirectory: URL
    let projectRoots: [URL]
    let limits: AgentConfigAuditor.Limits

    func collect(
        reader: inout AgentConfigFileReader,
        codexConfig: (url: URL, root: [String: TOMLValue])?
    ) -> [MCPServerEntry] {
        var entries: [MCPServerEntry] = []

        // Claude Code: ~/.claude.json (user + local scopes).
        let claudeState = homeDirectory.appendingPathComponent(".claude.json")
        var disabledProjectJSON: [String: Set<String>] = [:]
        if let object = reader.readJSONObject(claudeState, maximumBytes: limits.maximumClaudeStateBytes) {
            let plucked = Self.pluckClaudeState(object)
            entries += servers(
                from: plucked.userServers,
                client: .claudeCode,
                scope: .user,
                file: claudeState
            )
            for project in plucked.projects.sorted(by: { $0.path < $1.path }) {
                let projectURL = URL(fileURLWithPath: project.path)
                disabledProjectJSON[projectURL.standardizedFileURL.path] = project.disabledMcpJSONServers
                entries += servers(
                    from: project.servers,
                    client: .claudeCode,
                    scope: .local(projectURL),
                    file: claudeState,
                    disabledNames: project.disabledServers
                )
            }
        }

        // Claude Desktop.
        let desktop = homeDirectory.appendingPathComponent(
            "Library/Application Support/Claude/claude_desktop_config.json"
        )
        entries += jsonServers(at: desktop, key: "mcpServers", client: .claudeDesktop, scope: .user, reader: &reader)

        // Cursor.
        entries += jsonServers(
            at: homeDirectory.appendingPathComponent(".cursor/mcp.json"),
            key: "mcpServers", client: .cursor, scope: .user, reader: &reader
        )

        // VS Code.
        entries += jsonServers(
            at: homeDirectory.appendingPathComponent("Library/Application Support/Code/User/mcp.json"),
            key: "servers", client: .vscode, scope: .user, reader: &reader
        )

        // Codex.
        if let codexConfig, let table = codexConfig.root["mcp_servers"]?.tableValue {
            let object = Self.jsonObject(from: table)
            entries += servers(from: object, client: .codex, scope: .user, file: codexConfig.url)
        }

        // opencode (user).
        for name in ["opencode.json", "opencode.jsonc"] {
            let url = homeDirectory.appendingPathComponent(".config/opencode/\(name)")
            entries += jsonServers(at: url, key: "mcp", client: .opencode, scope: .user, reader: &reader)
        }

        // Project-level files.
        for project in projectRoots {
            let standardized = project.standardizedFileURL
            let scope = AgentConfigScope.project(standardized)
            entries += jsonServers(
                at: standardized.appendingPathComponent(".mcp.json"),
                key: "mcpServers", client: .claudeCode, scope: scope, reader: &reader,
                disabledNames: disabledProjectJSON[standardized.path] ?? []
            )
            entries += jsonServers(
                at: standardized.appendingPathComponent(".cursor/mcp.json"),
                key: "mcpServers", client: .cursor, scope: scope, reader: &reader
            )
            entries += jsonServers(
                at: standardized.appendingPathComponent(".vscode/mcp.json"),
                key: "servers", client: .vscode, scope: scope, reader: &reader
            )
            for name in ["opencode.json", "opencode.jsonc"] {
                entries += jsonServers(
                    at: standardized.appendingPathComponent(name),
                    key: "mcp", client: .opencode, scope: scope, reader: &reader
                )
            }
        }
        return entries
    }

    // MARK: - ~/.claude.json

    struct ClaudeStateProject {
        let path: String
        let servers: [String: Any]
        let disabledServers: Set<String>
        let disabledMcpJSONServers: Set<String>
    }

    /// Plucks only MCP-related keys. Everything else in the object (account,
    /// tokens, history, caches) is dropped when this returns.
    static func pluckClaudeState(_ object: [String: Any]) -> (userServers: [String: Any], projects: [ClaudeStateProject]) {
        let user = object["mcpServers"] as? [String: Any] ?? [:]
        var projects: [ClaudeStateProject] = []
        if let projectMap = object["projects"] as? [String: Any] {
            for (path, raw) in projectMap {
                guard path.hasPrefix("/"), let project = raw as? [String: Any] else { continue }
                let servers = project["mcpServers"] as? [String: Any] ?? [:]
                let disabled = Set(AgentConfigJSON.stringArray(project["disabledMcpServers"]))
                let disabledJSON = Set(AgentConfigJSON.stringArray(project["disabledMcpjsonServers"]))
                guard !servers.isEmpty || !disabledJSON.isEmpty || !disabled.isEmpty else { continue }
                projects.append(ClaudeStateProject(
                    path: path,
                    servers: servers,
                    disabledServers: disabled,
                    disabledMcpJSONServers: disabledJSON
                ))
            }
        }
        return (user, projects)
    }

    // MARK: - Generic parsing

    private func jsonServers(
        at url: URL,
        key: String,
        client: AIClient,
        scope: AgentConfigScope,
        reader: inout AgentConfigFileReader,
        disabledNames: Set<String> = []
    ) -> [MCPServerEntry] {
        guard let object = reader.readJSONObject(url, maximumBytes: limits.maximumConfigBytes) else { return [] }
        let servers = object[key] as? [String: Any] ?? [:]
        return self.servers(from: servers, client: client, scope: scope, file: url, disabledNames: disabledNames)
    }

    func servers(
        from object: [String: Any],
        client: AIClient,
        scope: AgentConfigScope,
        file: URL,
        disabledNames: Set<String> = []
    ) -> [MCPServerEntry] {
        object.keys.sorted().prefix(limits.maximumServersPerFile).compactMap { name in
            guard let definition = object[name] as? [String: Any] else { return nil }
            return Self.entry(
                name: name,
                definition: definition,
                client: client,
                scope: scope,
                file: file,
                forcedDisabled: disabledNames.contains(name)
            )
        }
    }

    static func entry(
        name: String,
        definition: [String: Any],
        client: AIClient,
        scope: AgentConfigScope,
        file: URL,
        forcedDisabled: Bool = false
    ) -> MCPServerEntry {
        // command may be a string ("npx") or, for opencode, an array (["npx", "-y", "pkg"]).
        var command: String?
        var args: [String] = []
        if let commandArray = definition["command"] as? [Any] {
            let parts = commandArray.compactMap { AgentConfigJSON.string($0) }
            command = parts.first
            args = Array(parts.dropFirst())
        } else {
            command = AgentConfigJSON.string(definition["command"])
        }
        args += AgentConfigJSON.stringArray(definition["args"])
        if command?.isEmpty == true { command = nil }

        let urlString = AgentConfigJSON.string(definition["url"])
            ?? AgentConfigJSON.string(definition["serverUrl"])
            ?? AgentConfigJSON.string(definition["httpUrl"])
        let type = AgentConfigJSON.string(definition["type"])?.lowercased()
        let remoteTypes: Set<String> = ["sse", "http", "streamable-http", "streamablehttp", "remote", "ws", "websocket"]
        let transport: MCPTransport
        if let type, remoteTypes.contains(type) {
            transport = .remote
        } else if command == nil, urlString != nil {
            transport = .remote
        } else {
            transport = .stdio
        }

        let envSource = definition["env"] ?? definition["environment"]
        let maskedEnv = AgentConfigJSON.stringPairs(envSource).map {
            AgentConfigSecretMasker.maskedPair(key: $0.0, value: $0.1)
        }
        let headerSource = definition["headers"] ?? definition["http_headers"]
        let maskedHeaders = AgentConfigJSON.stringPairs(headerSource).map {
            AgentConfigSecretMasker.maskedPair(key: $0.0, value: $0.1)
        }
        let maskedArgs = AgentConfigSecretMasker.maskArguments(args)

        var enabled = true
        if AgentConfigJSON.bool(definition["disabled"]) == true { enabled = false }
        if AgentConfigJSON.bool(definition["enabled"]) == false { enabled = false }
        if forcedDisabled { enabled = false }

        return MCPServerEntry(
            name: name,
            client: client,
            scope: scope,
            transport: transport,
            command: command.map { maskCommand($0) },
            args: maskedArgs.args,
            maskedEnv: maskedEnv,
            maskedHeaders: maskedHeaders,
            urlHost: urlString.flatMap(AgentConfigSecretMasker.host(of:)),
            configFile: file,
            enabled: enabled,
            hasInlineSecret: maskedArgs.foundSecret
                || urlString.map(AgentConfigSecretMasker.urlContainsSecret) == true
        )
    }

    /// A `command` string can occasionally hold a whole command line.
    private static func maskCommand(_ command: String) -> String {
        guard command.contains(" ") else { return command }
        return AgentConfigSecretMasker.redactCommand(command, maximumLength: 512)
    }

    // MARK: - TOML bridging

    /// Converts TOML values to the Foundation shapes the JSON path understands.
    static func jsonObject(from table: [String: TOMLValue]) -> [String: Any] {
        table.mapValues(jsonValue(from:))
    }

    private static func jsonValue(from value: TOMLValue) -> Any {
        switch value {
        case .string(let text): text
        case .integer(let number): NSNumber(value: number)
        case .double(let number): NSNumber(value: number)
        case .bool(let flag): NSNumber(value: flag)
        case .array(let items): items.map(jsonValue(from:))
        case .table(let inner): jsonObject(from: inner)
        case .other(let raw): raw
        }
    }
}
