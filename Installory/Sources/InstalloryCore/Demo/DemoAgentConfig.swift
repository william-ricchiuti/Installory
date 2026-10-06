import Foundation

extension DemoData {
    /// A realistic sample AI-setup audit for demo mode.
    ///
    /// Built from hand-written servers, instruction files and permission
    /// settings, then run through the same finding rules as a real audit so the
    /// demo copy never drifts from production. No filesystem access occurs: the
    /// rules see a stand-in provider where every program "exists".
    ///
    /// Covers MCP servers across Claude Code, Cursor and Claude Desktop (one
    /// name set up two different ways), one literal secret (already masked),
    /// a project whose AGENTS.md Claude Code doesn't read, a few auto-approved
    /// commands and one hook.
    public static func agentConfigAudit() -> AgentConfigAudit {
        let home = URL(fileURLWithPath: "/Users/demo", isDirectory: true)
        let recipes = home.appendingPathComponent("Projects/recipe-app", isDirectory: true)
        let portfolio = home.appendingPathComponent("Projects/portfolio-site", isDirectory: true)
        let claudeState = home.appendingPathComponent(".claude.json")
        let cursorMCP = home.appendingPathComponent(".cursor/mcp.json")
        let desktopConfig = home.appendingPathComponent(
            "Library/Application Support/Claude/claude_desktop_config.json"
        )

        let servers: [MCPServerEntry] = [
            MCPServerEntry(
                name: "github",
                client: .claudeCode,
                scope: .user,
                transport: .stdio,
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-github"],
                maskedEnv: [
                    MaskedValue(key: "GITHUB_PERSONAL_ACCESS_TOKEN", maskedValue: "ghp_\u{2026}", isLiteralSecret: true),
                ],
                urlHost: nil,
                configFile: claudeState,
                enabled: true
            ),
            MCPServerEntry(
                name: "github",
                client: .cursor,
                scope: .user,
                transport: .stdio,
                command: "docker",
                args: ["run", "-i", "--rm", "ghcr.io/github/github-mcp-server"],
                maskedEnv: [
                    MaskedValue(key: "GITHUB_PERSONAL_ACCESS_TOKEN", maskedValue: "${GITHUB_TOKEN}", isLiteralSecret: false),
                ],
                urlHost: nil,
                configFile: cursorMCP,
                enabled: true
            ),
            MCPServerEntry(
                name: "linear",
                client: .cursor,
                scope: .user,
                transport: .remote,
                command: nil,
                args: [],
                maskedEnv: [],
                urlHost: "mcp.linear.app",
                configFile: cursorMCP,
                enabled: true
            ),
            MCPServerEntry(
                name: "filesystem",
                client: .claudeDesktop,
                scope: .user,
                transport: .stdio,
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-filesystem", "/Users/demo/Documents"],
                maskedEnv: [],
                urlHost: nil,
                configFile: desktopConfig,
                enabled: true
            ),
            MCPServerEntry(
                name: "playwright",
                client: .claudeCode,
                scope: .project(recipes),
                transport: .stdio,
                command: "npx",
                args: ["@playwright/mcp@latest"],
                maskedEnv: [],
                urlHost: nil,
                configFile: recipes.appendingPathComponent(".mcp.json"),
                enabled: true
            ),
            MCPServerEntry(
                name: "sqlite",
                client: .claudeCode,
                scope: .local(recipes),
                transport: .stdio,
                command: "uvx",
                args: ["mcp-server-sqlite", "--db-path", "./dev.db"],
                maskedEnv: [],
                urlHost: nil,
                configFile: claudeState,
                enabled: false
            ),
        ]

        let instructionFiles: [InstructionFile] = [
            InstructionFile(
                kind: .claudeMd, tool: .claudeCode, scope: .user,
                path: home.appendingPathComponent(".claude/CLAUDE.md"),
                byteSize: 3_214, lineCount: 61, characterCount: 3_190,
                isSymlink: false, symlinkTarget: nil, isBrokenSymlink: false, imports: []
            ),
            InstructionFile(
                kind: .agentsMd, tool: .agentsStandard, scope: .project(recipes),
                path: recipes.appendingPathComponent("AGENTS.md"),
                byteSize: 2_048, lineCount: 44, characterCount: 2_031,
                isSymlink: false, symlinkTarget: nil, isBrokenSymlink: false, imports: []
            ),
            InstructionFile(
                kind: .claudeMd, tool: .claudeCode, scope: .project(recipes),
                path: recipes.appendingPathComponent("CLAUDE.md"),
                byteSize: 812, lineCount: 18, characterCount: 806,
                isSymlink: false, symlinkTarget: nil, isBrokenSymlink: false, imports: []
            ),
            InstructionFile(
                kind: .claudeMd, tool: .claudeCode, scope: .project(portfolio),
                path: portfolio.appendingPathComponent("CLAUDE.md"),
                byteSize: 1_420, lineCount: 30, characterCount: 1_402,
                isSymlink: false, symlinkTarget: nil, isBrokenSymlink: false, imports: ["@docs/style.md"]
            ),
            InstructionFile(
                kind: .cursorRule, tool: .cursor, scope: .project(portfolio),
                path: portfolio.appendingPathComponent(".cursor/rules/design.mdc"),
                byteSize: 640, lineCount: 14, characterCount: 633,
                isSymlink: false, symlinkTarget: nil, isBrokenSymlink: false, imports: []
            ),
        ]

        let permissionProfiles: [PermissionProfile] = [
            PermissionProfile(
                tool: .claudeCode,
                scope: .user,
                configFile: home.appendingPathComponent(".claude/settings.json"),
                allow: ["Bash(npm run test:*)", "Bash(git status)", "Read(~/Projects/**)"],
                deny: ["Read(./.env)"],
                defaultMode: "acceptEdits",
                hooks: [
                    AgentHook(event: "PostToolUse", matcher: "Edit|Write", commands: ["npx prettier --write ."]),
                ]
            ),
            PermissionProfile(
                tool: .claudeCode,
                scope: .local(recipes),
                configFile: recipes.appendingPathComponent(".claude/settings.local.json"),
                allow: ["Bash(npm install:*)", "Bash(rm:*)", "WebFetch(domain:docs.expo.dev)"]
            ),
            PermissionProfile(
                tool: .codex,
                scope: .user,
                configFile: home.appendingPathComponent(".codex/config.toml"),
                approvalPolicy: "on-request",
                sandboxMode: "workspace-write"
            ),
        ]

        let rules = AgentConfigFindingRules(
            homeDirectory: home,
            binarySearchDirectories: [URL(fileURLWithPath: "/opt/homebrew/bin")],
            access: DemoConfigAccess()
        )
        var findings = rules.mcpFindings(for: servers)
            + rules.instructionFindings(instructionFiles, projectRoots: [recipes, portfolio])
            + rules.permissionFindings(permissionProfiles)
        findings.sort(by: AgentConfigAuditor.findingOrder)

        return AgentConfigAudit(
            servers: servers,
            instructionFiles: instructionFiles,
            permissionProfiles: permissionProfiles,
            findings: findings,
            unreadableFiles: []
        )
    }
}

/// Stand-in filesystem for the demo audit: every program exists and nothing
/// can be read, so the rules never touch the real disk.
private struct DemoConfigAccess: DirectoryAccessProvider {
    func contentsOfDirectory(at url: URL) throws -> [URL] { [] }
    func data(contentsOf url: URL) throws -> Data { throw CocoaError(.fileReadNoPermission) }
    func fileExists(at url: URL) -> Bool { true }
    func modificationDate(at url: URL) -> Date? { nil }
    func metadata(at url: URL) throws -> FileSystemItemMetadata { throw CocoaError(.fileReadNoPermission) }
    func resolvingSymlinks(at url: URL) -> URL { url }
}
