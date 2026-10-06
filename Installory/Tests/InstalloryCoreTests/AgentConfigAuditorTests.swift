import Foundation
import Testing
@testable import InstalloryCore

/// Shared fake environment for the AI-setup audit tests.
enum AgentConfigFixture {
    static let home = URL(fileURLWithPath: "/Users/tester")
    static let project = URL(fileURLWithPath: "/Users/tester/code/app")
    static let homebrewBin = URL(fileURLWithPath: "/opt/homebrew/bin")

    /// Every raw secret or private value planted in the fixtures. None may
    /// appear anywhere in an audit result.
    static let plantedSecrets = [
        "SUPERSECRETOAUTHVALUE",
        "fake.person@example.com",
        "fake-account-uuid-1234",
        "FAKEPRIMARYKEYDONOTSURFACE",
        "FAKEAPPROVEDKEYSUFFIX",
        "fake-user-id-0f3c9a7e5d",
        "PRIVATE PROMPT TEXT",
        "ANOTHER PRIVATE PROMPT",
        "fake-session-id-xyz",
        "FAKEGITHUBTOKEN",
        "hunter2hunter2",
        "XYZSECRETQUERYVALUE",
        "CODEXFAKETOKEN",
        "literal-secret-value",
        "supersecretvalue99",
        "FAKEOPENAIKEY",
        "FAKESTRIPEKEY",
        "FAKEHOOKTOKEN",
        "FAKEQUERYTOKEN",
    ]

    static func data(_ name: String) throws -> Data {
        try FixtureResource.data("agent-config/\(name)")
    }

    /// The full fake home + one project, built from fixture files.
    static func fullProvider(
        extra: (inout InMemoryDirectoryAccessProvider.Builder) -> Void = { _ in }
    ) throws -> InMemoryDirectoryAccessProvider {
        let files: [(String, URL)] = [
            ("claude.json", home.appendingPathComponent(".claude.json")),
            ("claude_desktop_config.json", home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")),
            ("cursor-mcp.json", home.appendingPathComponent(".cursor/mcp.json")),
            ("vscode-mcp.json", home.appendingPathComponent("Library/Application Support/Code/User/mcp.json")),
            ("codex-config.toml", home.appendingPathComponent(".codex/config.toml")),
            ("opencode.jsonc", home.appendingPathComponent(".config/opencode/opencode.jsonc")),
            ("user-settings.json", home.appendingPathComponent(".claude/settings.json")),
            ("project-mcp.json", project.appendingPathComponent(".mcp.json")),
            ("project-settings.json", project.appendingPathComponent(".claude/settings.json")),
            ("project-settings-local.json", project.appendingPathComponent(".claude/settings.local.json")),
        ]
        var loaded: [(Data, URL)] = []
        for (name, url) in files { loaded.append((try data(name), url)) }
        return InMemoryDirectoryAccessProvider.make { builder in
            for (data, url) in loaded { builder.addFile(at: url, data: data) }
            builder.addFile(at: homebrewBin.appendingPathComponent("npx"), data: Data())
            builder.addFile(at: homebrewBin.appendingPathComponent("node"), data: Data())
            builder.addFile(at: homebrewBin.appendingPathComponent("docker"), data: Data())
            builder.addFile(at: project.appendingPathComponent("bin/helper"), data: Data())
            extra(&builder)
        }
    }

    static func audit(
        provider: InMemoryDirectoryAccessProvider,
        projects: [URL] = [project],
        binaries: [URL]? = [homebrewBin],
        limits: AgentConfigAuditor.Limits = .default
    ) -> AgentConfigAudit {
        AgentConfigAuditor(
            homeDirectory: home,
            projectRoots: projects,
            fileAccess: provider,
            binarySearchDirectories: binaries,
            limits: limits
        ).audit()
    }
}

@Suite("AgentConfigAuditor – MCP servers")
struct AgentConfigAuditorTests {
    private typealias F = AgentConfigFixture

    @Test("sign-in, session and history data in ~/.claude.json never reach the result")
    func claudeStateIsPlucked() throws {
        let audit = F.audit(provider: try F.fullProvider())
        let dump = String(reflecting: audit)
        for secret in F.plantedSecrets {
            #expect(!dump.contains(secret), "leaked \(secret)")
        }
        // Projects without MCP data are not surfaced either.
        #expect(!dump.contains("/Users/tester/code/other"))
    }

    @Test("reads every client and scope")
    func readsAllClients() throws {
        let audit = F.audit(provider: try F.fullProvider())
        let names = Set(audit.servers.map { "\($0.client.rawValue):\($0.name)" })
        #expect(names == [
            "claudeCode:github", "claudeCode:filesystem", "claudeCode:linear", "claudeCode:postgres",
            "claudeCode:notes", "claudeCode:helper",
            "claudeDesktop:github", "claudeDesktop:docs",
            "cursor:github", "cursor:playwright",
            "vscode:context7", "vscode:github",
            "codex:github", "codex:brave", "codex:remote docs",
            "opencode:sentry", "opencode:local-tool",
        ])
        #expect(audit.unreadableFiles.isEmpty)
    }

    @Test("Claude Code scopes: user, local (from ~/.claude.json) and project (.mcp.json)")
    func claudeScopes() throws {
        let audit = F.audit(provider: try F.fullProvider())
        let claude = audit.servers.filter { $0.client == .claudeCode }
        let github = try #require(claude.first { $0.name == "github" })
        #expect(github.scope == .user)
        #expect(github.configFile.path == "/Users/tester/.claude.json")

        let postgresLocal = try #require(claude.first { $0.name == "postgres" && $0.scope.kind == .local })
        #expect(postgresLocal.scope.projectPath == F.project)
        #expect(postgresLocal.args == ["mcp-server-postgres", "--password", "hunt…"])
        #expect(postgresLocal.hasInlineSecret)
        #expect(postgresLocal.maskedEnv == [MaskedValue(key: "DATABASE_URL", maskedValue: "${DATABASE_URL}", isLiteralSecret: false)])

        let postgresProject = try #require(claude.first { $0.name == "postgres" && $0.scope.kind == .project })
        #expect(postgresProject.configFile.path == "/Users/tester/code/app/.mcp.json")

        // disabledMcpjsonServers in ~/.claude.json turns off the project's "notes" server.
        let notes = try #require(claude.first { $0.name == "notes" })
        #expect(!notes.enabled)
    }

    @Test("secrets are masked: first 4 chars + … or •••• when short")
    func secretsMasked() throws {
        let audit = F.audit(provider: try F.fullProvider())
        let github = try #require(audit.servers.first { $0.client == .claudeCode && $0.name == "github" })
        #expect(github.maskedEnv == [
            MaskedValue(key: "GITHUB_PERSONAL_ACCESS_TOKEN", maskedValue: "ghp_…", isLiteralSecret: true),
        ])

        let cursorGithub = try #require(audit.servers.first { $0.client == .cursor && $0.name == "github" })
        #expect(cursorGithub.maskedEnv.first?.maskedValue == "${env:GITHUB_TOKEN}")
        #expect(cursorGithub.maskedEnv.first?.isLiteralSecret == false)

        let desktopGithub = try #require(audit.servers.first { $0.client == .claudeDesktop && $0.name == "github" })
        #expect(desktopGithub.maskedEnv.first == MaskedValue(key: "GITHUB_PERSONAL_ACCESS_TOKEN", maskedValue: "", isLiteralSecret: false))

        let settings = try #require(audit.permissionProfiles.first { $0.scope.kind == .user && $0.tool == .claudeCode })
        #expect(settings.maskedEnv == [MaskedValue(key: "DISABLE_TELEMETRY", maskedValue: "••••", isLiteralSecret: false)])
    }

    @Test("remote servers keep only the URL host")
    func remoteHostOnly() throws {
        let audit = F.audit(provider: try F.fullProvider())
        let docs = try #require(audit.servers.first { $0.name == "docs" })
        #expect(docs.transport == .remote)
        #expect(docs.urlHost == "mcp.docs.example.com")
        let linear = try #require(audit.servers.first { $0.name == "linear" })
        #expect(linear.transport == .remote)
        #expect(linear.urlHost == "mcp.linear.app")
        let context7 = try #require(audit.servers.first { $0.name == "context7" })
        #expect(context7.transport == .remote)
        #expect(context7.maskedHeaders == [
            MaskedValue(key: "Authorization", maskedValue: "Bearer ${input:context7-key}", isLiteralSecret: false),
        ])
    }

    @Test("Codex TOML: inline env, [x.env] sub-table, quoted names, enabled = false")
    func codexServers() throws {
        let audit = F.audit(provider: try F.fullProvider())
        let codex = audit.servers.filter { $0.client == .codex }
        let github = try #require(codex.first { $0.name == "github" })
        #expect(github.command == "npx")
        #expect(github.args == ["-y", "@modelcontextprotocol/server-github"])
        #expect(github.maskedEnv == [MaskedValue(key: "GITHUB_PERSONAL_ACCESS_TOKEN", maskedValue: "ghp_…", isLiteralSecret: true)])
        #expect(github.configFile.path == "/Users/tester/.codex/config.toml")

        let brave = try #require(codex.first { $0.name == "brave" })
        #expect(brave.command == "bunx")
        #expect(brave.args == ["brave-search-mcp", "--verbose"])
        #expect(brave.maskedEnv == [
            MaskedValue(key: "BRAVE_API_KEY", maskedValue: "BSA-…", isLiteralSecret: true),
            MaskedValue(key: "LOG_LEVEL", maskedValue: "••••", isLiteralSecret: false),
        ])

        let docs = try #require(codex.first { $0.name == "remote docs" })
        #expect(docs.transport == .remote)
        #expect(docs.urlHost == "docs.mcp.example.org")
        #expect(!docs.enabled)
    }

    @Test("opencode JSONC: command array, environment, enabled false, remote type")
    func opencodeServers() throws {
        let audit = F.audit(provider: try F.fullProvider())
        let tool = try #require(audit.servers.first { $0.client == .opencode && $0.name == "local-tool" })
        #expect(tool.transport == .stdio)
        #expect(tool.command == "docker")
        #expect(tool.args == ["run", "-i", "-e", "API_TOKEN=supe…", "example/tool"])
        #expect(tool.hasInlineSecret)
        #expect(tool.maskedEnv == [MaskedValue(key: "OPENAI_API_KEY", maskedValue: "sk-p…", isLiteralSecret: true)])
        #expect(!tool.enabled)

        let sentry = try #require(audit.servers.first { $0.client == .opencode && $0.name == "sentry" })
        #expect(sentry.transport == .remote)
        #expect(sentry.urlHost == "mcp.sentry.dev")
        #expect(sentry.maskedHeaders.first?.isLiteralSecret == false)
    }

    @Test("finding 1+2: same name configured differently, and installed in several apps")
    func duplicateFindings() throws {
        let audit = F.audit(provider: try F.fullProvider())
        let conflict = try #require(audit.findings.first { $0.id == "mcpConflictingDefinitions:github" })
        #expect(conflict.severity == .warning)
        #expect(conflict.explanation.contains("server-github@0.5.0"))
        #expect(!conflict.explanation.contains("FAKEGITHUBTOKEN"))

        let shared = try #require(audit.findings.first { $0.id == "mcpSharedAcrossApps:github" })
        #expect(shared.severity == .info)
        #expect(shared.title == "“github” is installed in 5 apps")
        #expect(shared.affectedServers.count == 5)

        // postgres: same app (Claude Code), two scopes, different args → conflict but not "several apps".
        #expect(audit.findings.contains { $0.id == "mcpConflictingDefinitions:postgres" })
        #expect(!audit.findings.contains { $0.id == "mcpSharedAcrossApps:postgres" })
    }

    @Test("finding 3: missing absolute path, missing bare command, relative path, found commands")
    func commandNotFound() throws {
        let audit = F.audit(provider: try F.fullProvider())
        let missing = audit.findings.filter { $0.kind == .mcpCommandNotFound }

        let absolute = try #require(missing.first { $0.id == "mcpCommandNotFound:path:/opt/missing/bin/fs-server" })
        #expect(absolute.severity == .warning)
        #expect(absolute.affectedServers.map(\.name) == ["filesystem"])

        let uvx = try #require(missing.first { $0.id == "mcpCommandNotFound:bare:uvx" })
        #expect(uvx.title.contains("Couldn't find “uvx”"))
        #expect(uvx.explanation.contains("may fail to start"))
        #expect(uvx.suggestedFix?.contains("uv") == true)
        #expect(uvx.affectedServers.count == 2)

        // bunx is missing too; npx and node are in the injected bin dir; ./bin/helper exists in the project.
        #expect(missing.contains { $0.id == "mcpCommandNotFound:bare:bunx" })
        #expect(!missing.contains { $0.id.hasSuffix(":npx") || $0.id.hasSuffix(":node") })
        #expect(!missing.contains { $0.id.contains("helper") })
        // Disabled servers are not checked (docker server is disabled, playwright too).
        #expect(!missing.contains { $0.id.hasSuffix(":docker") })
    }

    @Test("default search dirs include nvm versions")
    func nvmSearch() throws {
        let nvmBin = F.home.appendingPathComponent(".nvm/versions/node/v22.3.0/bin")
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            builder.addFile(
                at: F.home.appendingPathComponent(".cursor/mcp.json"),
                data: Data(#"{"mcpServers":{"x":{"command":"npx","args":["x"]},"y":{"command":"definitely-not-installed-cmd"}}}"#.utf8)
            )
            builder.addFile(at: nvmBin.appendingPathComponent("npx"), data: Data())
        }
        let audit = F.audit(provider: provider, projects: [], binaries: nil)
        let missing = audit.findings.filter { $0.kind == .mcpCommandNotFound }.map(\.id)
        #expect(missing == ["mcpCommandNotFound:bare:definitely-not-installed-cmd"])
    }

    @Test("finding 4: literal secrets are critical and show only masked values")
    func literalSecretFindings() throws {
        let audit = F.audit(provider: try F.fullProvider())
        let secrets = audit.findings.filter { $0.kind == .mcpLiteralSecret }
        #expect(secrets.allSatisfy { $0.severity == .critical })
        let names = Set(secrets.flatMap { $0.affectedServers.map { "\($0.client.rawValue):\($0.name)" } })
        #expect(names == [
            "claudeCode:github", "claudeCode:postgres", "codex:github", "codex:brave",
            "opencode:local-tool", "claudeDesktop:docs",
        ])
        let github = try #require(secrets.first { $0.affectedServers.first?.client == .claudeCode && $0.affectedServers.first?.name == "github" })
        #expect(github.explanation.contains("GITHUB_PERSONAL_ACCESS_TOKEN = ghp_…"))
        #expect(github.suggestedFix?.contains("${GITHUB_PERSONAL_ACCESS_TOKEN}") == true)
        // References and empty values are not secrets.
        #expect(!secrets.contains { $0.affectedServers.first?.client == .cursor })
        #expect(!secrets.contains { $0.affectedServers.first?.name == "context7" })
    }

    @Test("finding 5+6: remote hosts and disabled servers are info")
    func remoteAndDisabled() throws {
        let audit = F.audit(provider: try F.fullProvider())
        let remote = audit.findings.filter { $0.kind == .mcpRemoteServer }
        #expect(Set(remote.map(\.title)) == [
            "Connects to mcp.linear.app over the internet",
            "Connects to mcp.docs.example.com over the internet",
            "Connects to mcp.context7.com over the internet",
            "Connects to mcp.sentry.dev over the internet",
        ])
        #expect(remote.allSatisfy { $0.severity == .info })

        let disabled = audit.findings.filter { $0.kind == .mcpDisabled }
        #expect(Set(disabled.flatMap { $0.affectedServers.map(\.name) }) == ["playwright", "remote docs", "local-tool", "notes"])
        #expect(disabled.allSatisfy { $0.severity == .info })
        let playwright = try #require(disabled.first { $0.affectedServers.first?.name == "playwright" })
        #expect(playwright.title == "“playwright” is turned off in Cursor")
    }

    @Test("finding 7: invalid JSON and oversize files are reported with their path")
    func unreadableConfig() throws {
        let cursor = F.home.appendingPathComponent(".cursor/mcp.json")
        let desktop = F.home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        let trace = DirectoryAccessTrace()
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            builder.addFile(at: cursor, data: Data(#"{"mcpServers": { "x": { "command": "npx" "#.utf8))
            builder.addFile(at: desktop, data: Data("{}".utf8), logicalSizeBytes: 50 * 1_048_576)
        }
        let audit = AgentConfigAuditor(
            homeDirectory: F.home,
            projectRoots: [],
            fileAccess: TracingDirectoryAccessProvider(base: provider, trace: trace),
            binarySearchDirectories: []
        ).audit()

        #expect(audit.servers.isEmpty)
        #expect(Set(audit.unreadableFiles) == [
            UnreadableConfigFile(path: cursor, reason: .invalidFormat),
            UnreadableConfigFile(path: desktop, reason: .tooLarge),
        ])
        let findings = audit.findings.filter { $0.kind == .configFileUnreadable }
        #expect(findings.count == 2)
        #expect(findings.allSatisfy { $0.severity == .warning })
        #expect(findings.contains { $0.title == "Couldn't read ~/.cursor/mcp.json" && $0.explanation.contains("isn't valid JSON") })
        // The oversize file was never loaded.
        #expect(!trace.entries.contains { $0.operation == .data && $0.url.path == desktop.path })
    }

    @Test("servers on localhost are remote but not reported as internet connections")
    func localhostNotInternet() {
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            builder.addFile(
                at: F.home.appendingPathComponent(".cursor/mcp.json"),
                data: Data(#"{"mcpServers":{"dev":{"url":"http://localhost:3000/mcp"},"ip":{"url":"http://127.0.0.1:8080/sse"}}}"#.utf8)
            )
        }
        let audit = F.audit(provider: provider, projects: [])
        #expect(audit.servers.map(\.urlHost) == ["localhost:3000", "127.0.0.1:8080"])
        #expect(audit.servers.allSatisfy { $0.transport == .remote })
        #expect(!audit.findings.contains { $0.kind == .mcpRemoteServer })
    }

    @Test("an empty home produces an empty audit")
    func emptyHome() {
        let audit = F.audit(provider: InMemoryDirectoryAccessProvider.make { _ in }, projects: [F.project])
        #expect(audit == AgentConfigAudit(servers: [], instructionFiles: [], permissionProfiles: [], findings: [], unreadableFiles: []))
    }

    @Test("findings are sorted most severe first")
    func sortedBySeverity() throws {
        let audit = F.audit(provider: try F.fullProvider())
        let severities = audit.findings.map(\.severity.rawValue)
        #expect(severities == severities.sorted(by: >))
        #expect(audit.findings.first?.severity == .critical)
        #expect(Set(audit.findings.map(\.id)).count == audit.findings.count)
    }
}
