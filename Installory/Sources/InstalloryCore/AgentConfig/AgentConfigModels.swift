import Foundation

// MARK: - Shared

/// How serious an AI-setup audit finding is. Ordered so `critical > warning > info`.
public enum AgentConfigSeverity: Int, Sendable, Equatable, Hashable, Comparable, CaseIterable {
    case info = 0
    case warning = 1
    case critical = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .info: "Info"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

/// Where a configuration applies: everywhere for this Mac user, one project
/// shared with collaborators, or one project privately on this Mac.
public enum AgentConfigScopeKind: String, Sendable, Equatable, Hashable, CaseIterable {
    /// Applies to every project for this user (files in the home directory).
    case user
    /// Lives inside a project folder and is usually checked into git.
    case project
    /// Applies to one project but is stored privately (not shared via git).
    case local
}

public struct AgentConfigScope: Sendable, Equatable, Hashable {
    public let kind: AgentConfigScopeKind
    /// The project folder for `.project` and `.local` scopes; nil for `.user`.
    public let projectPath: URL?

    public init(kind: AgentConfigScopeKind, projectPath: URL? = nil) {
        self.kind = kind
        self.projectPath = projectPath?.standardizedFileURL
    }

    public static let user = AgentConfigScope(kind: .user)

    public static func project(_ url: URL) -> AgentConfigScope {
        AgentConfigScope(kind: .project, projectPath: url)
    }

    public static func local(_ url: URL) -> AgentConfigScope {
        AgentConfigScope(kind: .local, projectPath: url)
    }

    public var displayName: String {
        switch kind {
        case .user: "All projects"
        case .project: "Project “\(projectPath?.lastPathComponent ?? "")”"
        case .local: "Project “\(projectPath?.lastPathComponent ?? "")” (private to you)"
        }
    }
}

/// A key/value pair whose value has been masked before it was ever stored.
///
/// Values that are environment-variable references such as `${GITHUB_TOKEN}`,
/// `$TOKEN`, `{env:TOKEN}` or `${input:token}` are kept verbatim because they
/// contain no secret. Every other value is masked: the first 4 characters
/// followed by "…", or "••••" when the value is shorter than 8 characters.
public struct MaskedValue: Sendable, Equatable, Hashable {
    public let key: String
    public let maskedValue: String
    /// True when the key looks like a credential (KEY/TOKEN/SECRET/PASSWORD/AUTH)
    /// or the value looks like a well-known token format, and the value is a
    /// non-empty literal rather than a reference to an environment variable.
    public let isLiteralSecret: Bool

    public init(key: String, maskedValue: String, isLiteralSecret: Bool) {
        self.key = key
        self.maskedValue = maskedValue
        self.isLiteralSecret = isLiteralSecret
    }
}

// MARK: - MCP servers (A2)

/// The AI app whose configuration declares an MCP server.
public enum AIClient: String, Sendable, Equatable, Hashable, CaseIterable {
    case claudeCode
    case claudeDesktop
    case cursor
    case vscode
    case codex
    case opencode

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .cursor: "Cursor"
        case .vscode: "VS Code"
        case .codex: "Codex"
        case .opencode: "opencode"
        }
    }
}

public enum MCPTransport: String, Sendable, Equatable, Hashable {
    /// The AI app starts a program on this Mac and talks to it directly.
    case stdio
    /// The AI app connects to a server over the network.
    case remote
}

/// One MCP server declared in one AI app's configuration file.
public struct MCPServerEntry: Sendable, Equatable, Hashable, Identifiable {
    public let name: String
    public let client: AIClient
    public let scope: AgentConfigScope
    public let transport: MCPTransport
    /// The program that is started (stdio servers). Never contains secrets that
    /// were detected; see `args` for masking rules.
    public let command: String?
    /// Command-line arguments. Arguments that look like secrets (values after
    /// `--api-key`/`--token`-style flags, `--token=…`, known token formats, or
    /// URLs with credentials/query strings) are masked.
    public let args: [String]
    public let maskedEnv: [MaskedValue]
    public let maskedHeaders: [MaskedValue]
    /// Only the host of a remote server URL (never the path or query, which can
    /// carry keys).
    public let urlHost: String?
    public let configFile: URL
    public let enabled: Bool
    /// True when a command-line argument or the server URL contained what looks
    /// like a literal secret (masked argument, credentials or a key in the URL).
    public let hasInlineSecret: Bool

    public init(
        name: String,
        client: AIClient,
        scope: AgentConfigScope,
        transport: MCPTransport,
        command: String?,
        args: [String],
        maskedEnv: [MaskedValue],
        maskedHeaders: [MaskedValue] = [],
        urlHost: String?,
        configFile: URL,
        enabled: Bool,
        hasInlineSecret: Bool = false
    ) {
        self.name = name
        self.client = client
        self.scope = scope
        self.transport = transport
        self.command = command
        self.args = args
        self.maskedEnv = maskedEnv
        self.maskedHeaders = maskedHeaders
        self.urlHost = urlHost
        self.configFile = configFile.standardizedFileURL
        self.enabled = enabled
        self.hasInlineSecret = hasInlineSecret
    }

    public var id: String {
        "\(client.rawValue)|\(scope.kind.rawValue)|\(scope.projectPath?.path ?? "")|\(configFile.path)|\(name)"
    }

    /// The parts that decide what actually runs; used to detect conflicting
    /// definitions of the same server name.
    var definitionSignature: String {
        switch transport {
        case .stdio:
            "stdio|\(command ?? "")|\(args.joined(separator: "\u{1F}"))"
        case .remote:
            "remote|\(urlHost ?? "")"
        }
    }
}

// MARK: - Instruction files (A3)

/// Which AI tool reads an instruction file.
public enum InstructionTool: String, Sendable, Equatable, Hashable, CaseIterable {
    case claudeCode
    case codex
    case opencode
    case gemini
    case cursor
    case githubCopilot
    case windsurf
    /// `AGENTS.md` in a project: the shared format read by Codex, opencode,
    /// Cursor and others (but not by Claude Code on its own).
    case agentsStandard

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .opencode: "opencode"
        case .gemini: "Gemini CLI"
        case .cursor: "Cursor"
        case .githubCopilot: "GitHub Copilot"
        case .windsurf: "Windsurf"
        case .agentsStandard: "AGENTS.md tools (Codex, opencode, Cursor…)"
        }
    }
}

public enum InstructionFileKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case claudeMd
    case claudeLocalMd
    case agentsMd
    case geminiMd
    case cursorRulesLegacy
    case cursorRule
    case copilotInstructions
    case windsurfRules
}

public struct InstructionFile: Sendable, Equatable, Hashable, Identifiable {
    public let kind: InstructionFileKind
    public let tool: InstructionTool
    public let scope: AgentConfigScope
    public let path: URL
    /// File size in bytes, when known (nil for a broken symlink).
    public let byteSize: Int64?
    public let lineCount: Int?
    public let characterCount: Int?
    public let isSymlink: Bool
    /// Where the symlink points, when resolvable.
    public let symlinkTarget: URL?
    public let isBrokenSymlink: Bool
    /// `@path` imports found in Claude-style instruction files, as written.
    public let imports: [String]

    public init(
        kind: InstructionFileKind,
        tool: InstructionTool,
        scope: AgentConfigScope,
        path: URL,
        byteSize: Int64?,
        lineCount: Int?,
        characterCount: Int?,
        isSymlink: Bool,
        symlinkTarget: URL?,
        isBrokenSymlink: Bool,
        imports: [String]
    ) {
        self.kind = kind
        self.tool = tool
        self.scope = scope
        self.path = path.standardizedFileURL
        self.byteSize = byteSize
        self.lineCount = lineCount
        self.characterCount = characterCount
        self.isSymlink = isSymlink
        self.symlinkTarget = symlinkTarget
        self.isBrokenSymlink = isBrokenSymlink
        self.imports = imports
    }

    public var id: String { path.path }
}

// MARK: - Permissions (A3)

public enum PermissionTool: String, Sendable, Equatable, Hashable {
    case claudeCode
    case codex

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// One automatic hook: a shell command an agent runs on an event.
public struct AgentHook: Sendable, Equatable, Hashable {
    public let event: String
    /// Tool-name matcher such as `Bash` or `Edit|Write`; nil when it applies to all.
    public let matcher: String?
    /// Commands with anything secret-looking redacted.
    public let commands: [String]

    public init(event: String, matcher: String?, commands: [String]) {
        self.event = event
        self.matcher = matcher
        self.commands = commands
    }
}

/// Permission-related settings read from one settings file.
public struct PermissionProfile: Sendable, Equatable, Hashable, Identifiable {
    public let tool: PermissionTool
    public let scope: AgentConfigScope
    public let configFile: URL
    public let allow: [String]
    public let ask: [String]
    public let deny: [String]
    /// Claude Code `permissions.defaultMode` (e.g. `default`, `acceptEdits`,
    /// `plan`, `bypassPermissions`).
    public let defaultMode: String?
    public let hooks: [AgentHook]
    public let maskedEnv: [MaskedValue]
    public let enableAllProjectMcpServers: Bool?
    public let skipDangerousModePermissionPrompt: Bool?
    /// Codex `approval_policy` (e.g. `untrusted`, `on-request`, `never`).
    public let approvalPolicy: String?
    /// Codex `sandbox_mode` (e.g. `read-only`, `workspace-write`, `danger-full-access`).
    public let sandboxMode: String?

    public init(
        tool: PermissionTool,
        scope: AgentConfigScope,
        configFile: URL,
        allow: [String] = [],
        ask: [String] = [],
        deny: [String] = [],
        defaultMode: String? = nil,
        hooks: [AgentHook] = [],
        maskedEnv: [MaskedValue] = [],
        enableAllProjectMcpServers: Bool? = nil,
        skipDangerousModePermissionPrompt: Bool? = nil,
        approvalPolicy: String? = nil,
        sandboxMode: String? = nil
    ) {
        self.tool = tool
        self.scope = scope
        self.configFile = configFile.standardizedFileURL
        self.allow = allow
        self.ask = ask
        self.deny = deny
        self.defaultMode = defaultMode
        self.hooks = hooks
        self.maskedEnv = maskedEnv
        self.enableAllProjectMcpServers = enableAllProjectMcpServers
        self.skipDangerousModePermissionPrompt = skipDangerousModePermissionPrompt
        self.approvalPolicy = approvalPolicy
        self.sandboxMode = sandboxMode
    }

    public var id: String { configFile.path }
}

// MARK: - Unreadable files

public struct UnreadableConfigFile: Sendable, Equatable, Hashable {
    public enum Reason: String, Sendable, Equatable, Hashable {
        /// Bigger than the audit's read limit, so it was skipped.
        case tooLarge
        /// The file exists but could not be opened (permissions or sandbox).
        case unreadable
        /// The file was read but is not valid JSON/TOML/UTF-8.
        case invalidFormat
    }

    public let path: URL
    public let reason: Reason

    public init(path: URL, reason: Reason) {
        self.path = path.standardizedFileURL
        self.reason = reason
    }
}

// MARK: - Findings

public enum AgentConfigFindingCategory: String, Sendable, Equatable, Hashable, CaseIterable {
    case mcpServers
    case instructions
    case permissions
    case configFiles
}

public enum AgentConfigFindingKind: String, Sendable, Equatable, Hashable, CaseIterable {
    // MCP servers
    case mcpConflictingDefinitions
    case mcpSharedAcrossApps
    case mcpCommandNotFound
    case mcpLiteralSecret
    case mcpRemoteServer
    case mcpDisabled
    // Config files
    case configFileUnreadable
    // Instructions
    case agentsMdNotReadByClaude
    case instructionFileTooLarge
    case legacyCursorRules
    case brokenInstructionSymlink
    // Permissions
    case bypassPermissions
    case dangerousModePromptSkipped
    case codexFullAccess
    case broadAllowRule
    case rememberedApprovals
    case hooksConfigured
    case allProjectMcpServersEnabled
    case settingsLiteralSecret
}

/// One plain-English observation about the user's AI setup.
public struct AgentConfigFinding: Sendable, Equatable, Hashable, Identifiable {
    /// Stable identifier derived from the kind and the affected items.
    public let id: String
    public let kind: AgentConfigFindingKind
    public let category: AgentConfigFindingCategory
    public let severity: AgentConfigSeverity
    /// Short headline, written for someone new to AI coding tools.
    public let title: String
    /// What this means and why it matters, without unexplained jargon.
    public let explanation: String
    /// A concrete next step, when there is one.
    public let suggestedFix: String?
    public let affectedServers: [MCPServerEntry]
    public let affectedFiles: [URL]

    public init(
        id: String,
        kind: AgentConfigFindingKind,
        category: AgentConfigFindingCategory,
        severity: AgentConfigSeverity,
        title: String,
        explanation: String,
        suggestedFix: String? = nil,
        affectedServers: [MCPServerEntry] = [],
        affectedFiles: [URL] = []
    ) {
        self.id = id
        self.kind = kind
        self.category = category
        self.severity = severity
        self.title = title
        self.explanation = explanation
        self.suggestedFix = suggestedFix
        self.affectedServers = affectedServers
        self.affectedFiles = affectedFiles
    }
}

/// MCP-specific findings use the same shape as every other audit finding.
public typealias MCPFinding = AgentConfigFinding

/// The full result of an AI-setup audit.
public struct AgentConfigAudit: Sendable, Equatable {
    public let servers: [MCPServerEntry]
    public let instructionFiles: [InstructionFile]
    public let permissionProfiles: [PermissionProfile]
    /// Sorted most severe first.
    public let findings: [AgentConfigFinding]
    public let unreadableFiles: [UnreadableConfigFile]

    public init(
        servers: [MCPServerEntry],
        instructionFiles: [InstructionFile],
        permissionProfiles: [PermissionProfile],
        findings: [AgentConfigFinding],
        unreadableFiles: [UnreadableConfigFile]
    ) {
        self.servers = servers
        self.instructionFiles = instructionFiles
        self.permissionProfiles = permissionProfiles
        self.findings = findings
        self.unreadableFiles = unreadableFiles
    }

    public var mcpFindings: [AgentConfigFinding] {
        findings.filter { $0.category == .mcpServers }
    }

    public func findings(atLeast severity: AgentConfigSeverity) -> [AgentConfigFinding] {
        findings.filter { $0.severity >= severity }
    }
}
