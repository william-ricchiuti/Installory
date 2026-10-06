import Foundation

/// The "AI setup audit": reviews MCP servers across AI apps (Claude Code,
/// Claude Desktop, Cursor, VS Code, Codex, opencode) plus agent instruction
/// files and permission settings.
///
/// Pure, synchronous and read-only: it only reads local files through the
/// injected ``DirectoryAccessProvider`` with a size bound on every read, never
/// runs a process, never touches the network, and never writes. Secret-looking
/// values are masked at parse time; raw values are never stored in the result.
/// Run it off the main thread.
public struct AgentConfigAuditor: Sendable {
    public struct Limits: Sendable, Equatable {
        /// Per-file read limit for ordinary JSON/TOML config files.
        public let maximumConfigBytes: Int
        /// Read limit for `~/.claude.json`, which also holds project history and
        /// grows much larger than other config files.
        public let maximumClaudeStateBytes: Int
        /// Read limit for each instruction (CLAUDE.md, AGENTS.md…) file.
        public let maximumInstructionBytes: Int
        public let maximumProjectRoots: Int
        public let maximumServersPerFile: Int
        public let maximumCursorRuleFiles: Int
        public let maximumRulesPerList: Int
        public let maximumHooks: Int
        public let maximumNodeVersions: Int

        public init(
            maximumConfigBytes: Int = 2 * 1_048_576,
            maximumClaudeStateBytes: Int = 16 * 1_048_576,
            maximumInstructionBytes: Int = 2 * 1_048_576,
            maximumProjectRoots: Int = 500,
            maximumServersPerFile: Int = 500,
            maximumCursorRuleFiles: Int = 200,
            maximumRulesPerList: Int = 2_000,
            maximumHooks: Int = 200,
            maximumNodeVersions: Int = 50
        ) {
            self.maximumConfigBytes = maximumConfigBytes
            self.maximumClaudeStateBytes = maximumClaudeStateBytes
            self.maximumInstructionBytes = maximumInstructionBytes
            self.maximumProjectRoots = maximumProjectRoots
            self.maximumServersPerFile = maximumServersPerFile
            self.maximumCursorRuleFiles = maximumCursorRuleFiles
            self.maximumRulesPerList = maximumRulesPerList
            self.maximumHooks = maximumHooks
            self.maximumNodeVersions = maximumNodeVersions
        }

        public static let `default` = Limits()
    }

    private let homeDirectory: URL
    private let projectRoots: [URL]
    private let fileAccess: any DirectoryAccessProvider
    private let explicitBinaryDirectories: [URL]?
    private let limits: Limits

    /// - Parameters:
    ///   - homeDirectory: The user's real home directory (injected; never looked up here).
    ///   - projectRoots: Project folders the user granted access to.
    ///   - fileAccess: Filesystem abstraction; inject a fake in tests.
    ///   - binarySearchDirectories: Where to look for bare commands such as
    ///     `npx`. Defaults to Homebrew, /usr/local/bin, /usr/bin, /bin,
    ///     ~/.local/bin, ~/.cargo/bin, ~/.bun/bin, ~/.volta/bin and every
    ///     ~/.nvm/versions/node/*/bin. When provided, used exactly as given.
    public init(
        homeDirectory: URL,
        projectRoots: [URL],
        fileAccess: any DirectoryAccessProvider = SystemDirectoryAccessProvider(),
        binarySearchDirectories: [URL]? = nil,
        limits: Limits = .default
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        var seen: Set<String> = []
        self.projectRoots = projectRoots
            .map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
            .prefix(limits.maximumProjectRoots)
            .map { $0 }
        self.fileAccess = fileAccess
        self.explicitBinaryDirectories = binarySearchDirectories
        self.limits = limits
    }

    public func audit() -> AgentConfigAudit {
        var configReader = AgentConfigFileReader(access: fileAccess)
        var instructionReader = AgentConfigFileReader(access: fileAccess)

        // Codex config.toml feeds both MCP servers and permissions; read it once.
        let codexURL = homeDirectory.appendingPathComponent(".codex/config.toml")
        var codexConfig: (url: URL, root: [String: TOMLValue])?
        if let text = configReader.readText(codexURL, maximumBytes: limits.maximumConfigBytes) {
            codexConfig = (codexURL, MiniTOMLParser.parse(text).root)
        }

        let servers = MCPServerCollector(
            homeDirectory: homeDirectory,
            projectRoots: projectRoots,
            limits: limits
        ).collect(reader: &configReader, codexConfig: codexConfig)

        let permissionProfiles = PermissionProfileCollector(
            homeDirectory: homeDirectory,
            projectRoots: projectRoots,
            limits: limits
        ).collect(reader: &configReader, codexConfig: codexConfig)

        let instructionFiles = InstructionFileCollector(
            homeDirectory: homeDirectory,
            projectRoots: projectRoots,
            limits: limits
        ).collect(reader: &instructionReader)

        let rules = AgentConfigFindingRules(
            homeDirectory: homeDirectory,
            binarySearchDirectories: explicitBinaryDirectories ?? defaultBinaryDirectories(),
            access: fileAccess
        )
        var findings: [AgentConfigFinding] = []
        findings += rules.mcpFindings(for: servers)
        findings += rules.unreadableFindings(configReader.unreadable, maximumBytes: limits.maximumConfigBytes)
        findings += rules.instructionFindings(instructionFiles, projectRoots: projectRoots)
        findings += rules.permissionFindings(permissionProfiles)

        var seenIDs: Set<String> = []
        findings = findings.filter { seenIDs.insert($0.id).inserted }
        findings.sort(by: Self.findingOrder)

        var unreadable = configReader.unreadable
        for entry in instructionReader.unreadable where !unreadable.contains(entry) {
            unreadable.append(entry)
        }

        return AgentConfigAudit(
            servers: servers,
            instructionFiles: instructionFiles,
            permissionProfiles: permissionProfiles,
            findings: findings,
            unreadableFiles: unreadable
        )
    }

    /// Most severe first; then by category and title for a stable order.
    static func findingOrder(_ lhs: AgentConfigFinding, _ rhs: AgentConfigFinding) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
        let categories = AgentConfigFindingCategory.allCases
        let lhsCategory = categories.firstIndex(of: lhs.category) ?? 0
        let rhsCategory = categories.firstIndex(of: rhs.category) ?? 0
        if lhsCategory != rhsCategory { return lhsCategory < rhsCategory }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        return lhs.id < rhs.id
    }

    /// The common places command-line programs are installed on a Mac.
    public static func defaultBinaryDirectories(homeDirectory: URL) -> [URL] {
        let home = homeDirectory.standardizedFileURL
        return [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/usr/bin"),
            URL(fileURLWithPath: "/bin"),
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent(".cargo/bin"),
            home.appendingPathComponent(".bun/bin"),
            home.appendingPathComponent(".volta/bin"),
        ]
    }

    private func defaultBinaryDirectories() -> [URL] {
        var directories = Self.defaultBinaryDirectories(homeDirectory: homeDirectory)
        let nvmVersions = homeDirectory.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let versions = fileAccess.directoryContentsOrEmpty(at: nvmVersions)
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limits.maximumNodeVersions)
        for version in versions {
            directories.append(
                nvmVersions
                    .appendingPathComponent(version.lastPathComponent)
                    .appendingPathComponent("bin")
            )
        }
        return directories
    }
}
