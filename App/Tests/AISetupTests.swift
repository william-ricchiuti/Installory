import Foundation
import InstalloryCore
import Testing
@testable import Installory

@Suite("AI Setup screen: wording, grouping, prompts and checkup mapping", .serialized)
@MainActor
struct AISetupTests {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    private var project: URL { home.appendingPathComponent("Projects/app", isDirectory: true) }

    private func server(
        _ name: String,
        client: AIClient = .claudeCode,
        scope: AgentConfigScope = .user,
        command: String? = "npx",
        args: [String] = [],
        env: [MaskedValue] = [],
        enabled: Bool = true,
        remoteHost: String? = nil
    ) -> MCPServerEntry {
        MCPServerEntry(
            name: name,
            client: client,
            scope: scope,
            transport: remoteHost == nil ? .stdio : .remote,
            command: remoteHost == nil ? command : nil,
            args: args,
            maskedEnv: env,
            urlHost: remoteHost,
            configFile: home.appendingPathComponent(".claude.json"),
            enabled: enabled
        )
    }

    private func finding(
        _ kind: AgentConfigFindingKind,
        _ severity: AgentConfigSeverity,
        id: String? = nil,
        servers: [MCPServerEntry] = [],
        explanation: String = "Explained."
    ) -> AgentConfigFinding {
        AgentConfigFinding(
            id: id ?? "\(kind.rawValue):\(UUID().uuidString)",
            kind: kind,
            category: .mcpServers,
            severity: severity,
            title: "Title \(kind.rawValue)",
            explanation: explanation,
            suggestedFix: "Do the fix.",
            affectedServers: servers,
            affectedFiles: servers.map(\.configFile)
        )
    }

    private func audit(servers: [MCPServerEntry] = [], findings: [AgentConfigFinding]) -> AgentConfigAudit {
        AgentConfigAudit(
            servers: servers,
            instructionFiles: [],
            permissionProfiles: [],
            findings: findings,
            unreadableFiles: []
        )
    }

    // MARK: - Wording

    @Test("Scopes read in plain words")
    func scopeWording() {
        #expect(AISetupPresentation.scopeLabel(.user) == "All your projects")
        #expect(AISetupPresentation.scopeLabel(.project(project)) == "Shared in \u{201C}app\u{201D}")
        #expect(AISetupPresentation.scopeLabel(.local(project)) == "Just you, in \u{201C}app\u{201D}")
        #expect(AISetupPresentation.scopeHelp(.project(project)).contains("share"))
    }

    @Test("Servers group by name across apps and describe how they run")
    func serverGrouping() {
        let servers = [
            server("GitHub", client: .claudeCode, args: ["-y", "server-github"]),
            server("playwright", client: .claudeCode, scope: .project(project)),
            server("github", client: .cursor, command: "docker", args: ["run", "github"]),
            server("linear", client: .cursor, remoteHost: "mcp.linear.app"),
        ]
        let groups = AISetupPresentation.serverGroups(servers)
        #expect(groups.map(\.id) == ["github", "linear", "playwright"])
        let github = groups[0]
        #expect(github.entries.count == 2)
        #expect(github.clients == [.claudeCode, .cursor])
        #expect(github.clientNames == "Claude Code, Cursor")
        #expect(github.hasDifferentDefinitions)
        #expect(!groups[2].hasDifferentDefinitions)

        #expect(AISetupPresentation.runDescription(servers[0]) == "npx -y server-github")
        #expect(AISetupPresentation.runDescription(servers[3]) == "Online service at mcp.linear.app")
    }

    @Test("Server status chips: turned off, program not found, key in settings")
    func serverStatuses() {
        let secret = MaskedValue(key: "API_KEY", maskedValue: "sk-a\u{2026}", isLiteralSecret: true)
        let off = server("a", enabled: false)
        let missing = server("b", command: "uvx")
        let keyed = server("c", env: [secret])
        let audit = audit(
            servers: [off, missing, keyed],
            findings: [finding(.mcpCommandNotFound, .warning, servers: [missing])]
        )
        #expect(AISetupPresentation.statuses(for: off, in: audit) == [.disabled])
        #expect(AISetupPresentation.statuses(for: missing, in: audit) == [.missingCommand])
        #expect(AISetupPresentation.statuses(for: keyed, in: audit) == [.inlineSecret])
    }

    @Test("Permission modes read in plain English and flag the risky ones")
    func modeWording() {
        let file = home.appendingPathComponent(".claude/settings.json")
        let bypass = PermissionProfile(tool: .claudeCode, scope: .user, configFile: file, defaultMode: "bypassPermissions")
        #expect(AISetupPresentation.modeDescription(bypass)?.isRisky == true)
        let edits = PermissionProfile(tool: .claudeCode, scope: .user, configFile: file, defaultMode: "acceptEdits")
        #expect(AISetupPresentation.modeDescription(edits)?.isRisky == false)
        #expect(AISetupPresentation.modeDescription(PermissionProfile(tool: .claudeCode, scope: .user, configFile: file)) == nil)
        let codex = PermissionProfile(
            tool: .codex, scope: .user, configFile: file,
            approvalPolicy: "never", sandboxMode: "danger-full-access"
        )
        let codexMode = AISetupPresentation.modeDescription(codex)
        #expect(codexMode?.isRisky == true)
        #expect(codexMode?.text == "Never asks; has full access to your Mac")
    }

    @Test("Instruction files group by project with home-level files first")
    func instructionGrouping() {
        func file(_ path: URL, scope: AgentConfigScope) -> InstructionFile {
            InstructionFile(
                kind: .claudeMd, tool: .claudeCode, scope: scope, path: path,
                byteSize: 2_048, lineCount: 10, characterCount: 2_000,
                isSymlink: false, symlinkTarget: nil, isBrokenSymlink: false, imports: []
            )
        }
        let other = home.appendingPathComponent("Projects/zeta", isDirectory: true)
        let groups = AISetupPresentation.instructionGroups([
            file(other.appendingPathComponent("CLAUDE.md"), scope: .project(other)),
            file(project.appendingPathComponent("CLAUDE.md"), scope: .project(project)),
            file(home.appendingPathComponent(".claude/CLAUDE.md"), scope: .user),
        ])
        #expect(groups.map(\.title) == ["All your projects", "\u{201C}app\u{201D}", "\u{201C}zeta\u{201D}"])
        #expect(AISetupPresentation.sizeLabel(groups[0].files[0]).hasSuffix("10 lines"))
    }

    // MARK: - Prompts

    @Test("Secret findings build a key-name-only prompt with no masked value")
    func secretPrompt() {
        let secret = MaskedValue(key: "OPENAI_API_KEY", maskedValue: "sk-p\u{2026}", isLiteralSecret: true)
        let keyed = server("openai", env: [secret])
        let secretFinding = finding(
            .mcpLiteralSecret, .critical, servers: [keyed],
            explanation: "contains OPENAI_API_KEY = sk-p\u{2026}"
        )
        let audit = audit(servers: [keyed], findings: [secretFinding])
        let prompt = AISetupPresentation.promptFinding(for: secretFinding, in: audit)
        #expect(prompt.kind == .exposedSecret(keyName: "OPENAI_API_KEY"))
        #expect(prompt.explanation.isEmpty)

        let body = AgentPromptBuilder(agent: .claudeCode, homeDirectory: home).findingPrompt(for: prompt).body
        #expect(body.contains("OPENAI_API_KEY"))
        #expect(!body.contains("sk-p"))
        #expect(body.contains("~/.claude.json"))
    }

    @Test("Other findings carry their explanation and suggested fix")
    func generalPrompt() {
        let general = finding(.mcpConflictingDefinitions, .warning, explanation: "Two ways.")
        let prompt = AISetupPresentation.promptFinding(for: general, in: audit(findings: [general]))
        #expect(prompt.kind == .general)
        #expect(prompt.explanation.contains("Two ways."))
        #expect(prompt.explanation.contains("Do the fix."))
    }

    // MARK: - Checkup mapping

    @Test("Checkup counts map critical/warning/info to high/medium/low")
    func checkupMapping() {
        let audit = audit(findings: [
            finding(.mcpLiteralSecret, .critical),
            finding(.mcpConflictingDefinitions, .warning),
            finding(.broadAllowRule, .warning),
            finding(.hooksConfigured, .info),
        ])
        #expect(AISetupPresentation.checkupCounts(audit) == CheckupFindingCounts(high: 1, medium: 2, low: 1))
        #expect(AISetupPresentation.attentionCount(audit) == 3)
    }

    @Test("Demo mode provides an audit that feeds Home and the sidebar badge")
    func demoAuditFeedsCheckup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstalloryAISetupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let coordinator = AppCoordinator(dataDirectoryOverride: directory)
        coordinator.enterDemoMode()
        #expect(coordinator.aiSetupAccessGranted)
        let audit = try #require(coordinator.aiSetupAudit)
        #expect(coordinator.agentConfigAuditedAt != nil)
        #expect(Set(audit.servers.map(\.client)).isSuperset(of: [.claudeCode, .cursor, .claudeDesktop]))
        #expect(coordinator.aiSetupAttentionCount == audit.findings(atLeast: .warning).count)
        #expect(coordinator.aiSetupAttentionCount > 0)

        let input = coordinator.checkupInput(pathComponents: [])
        let counts = try #require(input.agentFindings)
        #expect(counts.high >= 1)
        #expect(input.exposedSecretCount == 1)

        let rows = Checkup.make(from: input)
        let aiRow = try #require(rows.first { $0.area == .aiTools })
        #expect(aiRow.status == .attention)
        #expect(aiRow.action == .reviewAITools)
        #expect(aiRow.command == .navigate(.aiSetup))
        let secretsRow = try #require(rows.first { $0.area == .secrets })
        #expect(secretsRow.headline == "1 key in AI tool settings")
        #expect(secretsRow.action == .reviewKeys)
        #expect(secretsRow.command == .navigate(.aiSetup))

        coordinator.exitDemoMode()
        #expect(coordinator.agentConfigAudit == nil)
    }

    // MARK: - Scan inputs

    @Test("Project roots dedupe, skip the home folder and its parents, and cap")
    func projectRoots() {
        let a = home.appendingPathComponent("Projects/a")
        let b = home.appendingPathComponent("Projects/b")
        let roots = AISetupPresentation.projectRoots(
            workspaces: [a, b, a],
            grantedFolders: [home, URL(fileURLWithPath: "/Users"), URL(fileURLWithPath: "/"), home.appendingPathComponent("Projects")],
            homeDirectory: home
        )
        #expect(roots.map(\.path) == [a.path, b.path, home.appendingPathComponent("Projects").path])

        let many = (0..<10).map { home.appendingPathComponent("p\($0)") }
        #expect(AISetupPresentation.projectRoots(workspaces: many, grantedFolders: [], homeDirectory: home, limit: 4).count == 4)
    }

    @Test("Missing-program findings in folders the sandbox can't see are softened")
    func sandboxAdjustment() {
        let missingBare = finding(.mcpCommandNotFound, .warning, id: "mcpCommandNotFound:bare:npx")
        let missingHidden = finding(.mcpCommandNotFound, .warning, id: "mcpCommandNotFound:path:/opt/tools/bin/x")
        let missingVisible = finding(.mcpCommandNotFound, .warning, id: "mcpCommandNotFound:path:\(home.path)/bin/x")
        let other = finding(.broadAllowRule, .warning)
        let raw = audit(findings: [missingBare, missingHidden, missingVisible, other])

        // Only the home folder is visible: /opt/homebrew/bin and friends are not.
        let adjusted = AISetupSandboxAdjustment.adjust(raw, visibleRoots: [home], homeDirectory: home)
        let byID = Dictionary(uniqueKeysWithValues: adjusted.findings.map { ($0.id, $0) })
        #expect(byID[missingBare.id]?.severity == .info)
        #expect(byID[missingBare.id]?.explanation.hasSuffix(AISetupSandboxAdjustment.uncertaintyNote) == true)
        #expect(byID[missingHidden.id]?.severity == .info)
        #expect(byID[missingVisible.id]?.severity == .warning)
        #expect(byID[other.id]?.severity == .warning)
        // Still most severe first.
        #expect(adjusted.findings.map(\.severity).prefix(2).allSatisfy { $0 == .warning })

        // With every searched folder visible, a missing program is a real warning.
        let everything = AISetupSandboxAdjustment.adjust(raw, visibleRoots: [URL(fileURLWithPath: "/")], homeDirectory: home)
        #expect(everything.findings.allSatisfy { $0.severity == .warning })
    }
}
