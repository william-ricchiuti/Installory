import Foundation
import InstalloryCore

/// Pure wording and grouping for the AI Setup screen and the Home checkup.
/// Everything here works on audit values that were masked at parse time.
enum AISetupPresentation {
    // MARK: - Scope wording

    /// Where a setting applies, in plain words.
    static func scopeLabel(_ scope: AgentConfigScope) -> String {
        let project = scope.projectPath?.lastPathComponent ?? "this project"
        switch scope.kind {
        case .user: return "All your projects"
        case .project: return "Shared in \u{201C}\(project)\u{201D}"
        case .local: return "Just you, in \u{201C}\(project)\u{201D}"
        }
    }

    /// One-line explanation of a scope for tooltips and VoiceOver.
    static func scopeHelp(_ scope: AgentConfigScope) -> String {
        switch scope.kind {
        case .user:
            return "Saved in your home folder, so it applies in every project you open."
        case .project:
            return "Saved inside the project folder, so anyone you share the project with (for example through git) gets it too."
        case .local:
            return "Applies only to this project and is kept private to you on this Mac."
        }
    }

    // MARK: - MCP servers

    /// Servers that share a name (ignoring case) across apps and scopes.
    struct ServerGroup: Identifiable, Equatable {
        let name: String
        let entries: [MCPServerEntry]

        var id: String { name.lowercased() }

        /// Apps that declare this server, in first-seen order.
        var clients: [AIClient] {
            var seen: Set<AIClient> = []
            return entries.map(\.client).filter { seen.insert($0).inserted }
        }

        var clientNames: String { clients.map(\.displayName).joined(separator: ", ") }

        /// True when the copies don't start the same way.
        var hasDifferentDefinitions: Bool {
            Set(entries.map(AISetupPresentation.runDescription)).count > 1
        }
    }

    static func serverGroups(_ servers: [MCPServerEntry]) -> [ServerGroup] {
        var order: [String] = []
        var byKey: [String: [MCPServerEntry]] = [:]
        for server in servers {
            let key = server.name.lowercased()
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(server)
        }
        return order
            .compactMap { key in
                byKey[key].flatMap { entries in
                    entries.first.map { ServerGroup(name: $0.name, entries: entries) }
                }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// How the server runs: the program and its (already masked) arguments, or
    /// the host of an online service. Never includes env values or headers.
    static func runDescription(_ server: MCPServerEntry) -> String {
        switch server.transport {
        case .stdio:
            let parts = [server.command ?? "(no program set)"] + server.args
            return parts.joined(separator: " ")
        case .remote:
            return "Online service at \(server.urlHost ?? "an unknown address")"
        }
    }

    enum ServerStatus: String, CaseIterable, Identifiable {
        case disabled
        case missingCommand
        case inlineSecret

        var id: String { rawValue }

        var title: String {
            switch self {
            case .disabled: "Turned off"
            case .missingCommand: "Program not found"
            case .inlineSecret: "Key in settings"
            }
        }

        var help: String {
            switch self {
            case .disabled: "This server is switched off in the app's settings, so it doesn't run."
            case .missingCommand: "Installory couldn't find the program this server starts, so it may fail to start."
            case .inlineSecret: "A password or API key is written directly in this server's settings."
            }
        }

        var systemImage: String {
            switch self {
            case .disabled: "pause.circle"
            case .missingCommand: "questionmark.app.dashed"
            case .inlineSecret: "key.fill"
            }
        }
    }

    static func statuses(for server: MCPServerEntry, in audit: AgentConfigAudit) -> [ServerStatus] {
        var result: [ServerStatus] = []
        if !server.enabled { result.append(.disabled) }
        let missing = audit.findings.contains { finding in
            finding.kind == .mcpCommandNotFound && finding.affectedServers.contains { $0.id == server.id }
        }
        if missing { result.append(.missingCommand) }
        if server.hasLiteralSecret { result.append(.inlineSecret) }
        return result
    }

    // MARK: - Instruction files

    struct InstructionGroup: Identifiable, Equatable {
        /// nil for files that apply to every project.
        let projectPath: URL?
        let files: [InstructionFile]

        var id: String { projectPath?.path ?? "~" }

        var title: String {
            projectPath.map { "\u{201C}\($0.lastPathComponent)\u{201D}" } ?? "All your projects"
        }
    }

    /// Files grouped by project; files that apply everywhere come first.
    static func instructionGroups(_ files: [InstructionFile]) -> [InstructionGroup] {
        let grouped = Dictionary(grouping: files) { $0.scope.projectPath?.path ?? "" }
        return grouped.keys
            .sorted { lhs, rhs in
                if lhs.isEmpty != rhs.isEmpty { return lhs.isEmpty }
                let lhsName = URL(fileURLWithPath: lhs).lastPathComponent
                let rhsName = URL(fileURLWithPath: rhs).lastPathComponent
                return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
            }
            .map { key in
                let files = (grouped[key] ?? []).sorted { $0.path.path < $1.path.path }
                return InstructionGroup(
                    projectPath: key.isEmpty ? nil : URL(fileURLWithPath: key, isDirectory: true),
                    files: files
                )
            }
    }

    static func sizeLabel(_ file: InstructionFile) -> String {
        if file.isBrokenSymlink { return "Broken shortcut" }
        guard let bytes = file.byteSize else { return "Size unknown" }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        if let lines = file.lineCount {
            return "\(size) \u{00B7} \(lines) \(lines == 1 ? "line" : "lines")"
        }
        return size
    }

    // MARK: - Permissions

    /// The default permission behavior in plain English, plus whether it is risky.
    static func modeDescription(_ profile: PermissionProfile) -> (text: String, isRisky: Bool)? {
        switch profile.tool {
        case .claudeCode:
            guard let mode = profile.defaultMode else { return nil }
            switch mode.lowercased() {
            case "default":
                return ("Asks before editing files or running commands", false)
            case "acceptedits":
                return ("Edits files without asking; asks before running commands", false)
            case "plan":
                return ("Plans first and changes nothing until you approve", false)
            case "bypasspermissions":
                return ("Never asks \u{2014} runs any command and edits any file on its own", true)
            case "dontask":
                return ("Doesn't ask; anything not pre-approved is refused", false)
            default:
                return ("Mode \u{201C}\(mode)\u{201D}", false)
            }
        case .codex:
            var parts: [String] = []
            var risky = false
            switch profile.approvalPolicy?.lowercased() {
            case "untrusted"?: parts.append("Asks before running most commands")
            case "on-request"?: parts.append("Asks when it needs more access")
            case "on-failure"?: parts.append("Asks only after a command fails")
            case "never"?: parts.append("Never asks")
            case let other?: parts.append("Approval \u{201C}\(other)\u{201D}")
            case nil: break
            }
            switch profile.sandboxMode?.lowercased() {
            case "read-only"?: parts.append("can only read files")
            case "workspace-write"?: parts.append("can change files in the project")
            case "danger-full-access"?:
                parts.append("has full access to your Mac")
                risky = true
            case let other?: parts.append("sandbox \u{201C}\(other)\u{201D}")
            case nil: break
            }
            guard !parts.isEmpty else { return nil }
            let text = parts.joined(separator: "; ")
            return (text.prefix(1).uppercased() + text.dropFirst(), risky)
        }
    }

    // MARK: - Findings

    static func severityTitle(_ severity: AgentConfigSeverity) -> String {
        switch severity {
        case .critical: "Fix soon"
        case .warning: "Worth a look"
        case .info: "Good to know"
        }
    }

    static func severitySymbol(_ severity: AgentConfigSeverity) -> String {
        switch severity {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    /// The prompt input for "Ask your AI assistant". Secret findings use
    /// `.exposedSecret` with the key name only: their explanations contain
    /// partially masked values, which must never reach a prompt.
    static func promptFinding(for finding: AgentConfigFinding, in audit: AgentConfigAudit) -> PromptFinding {
        if finding.isLiteralSecret {
            return PromptFinding(
                kind: .exposedSecret(keyName: audit.secretKeyName(for: finding) ?? ""),
                title: finding.title,
                explanation: "",
                filePaths: finding.affectedFiles
            )
        }
        var explanation = finding.explanation
        if let fix = finding.suggestedFix {
            explanation += "\n\nInstallory suggested: \(fix)"
        }
        return PromptFinding(
            kind: .general,
            title: finding.title,
            explanation: explanation,
            filePaths: finding.affectedFiles
        )
    }

    /// Home checkup counts: critical → high, warning → medium, info → low.
    static func checkupCounts(_ audit: AgentConfigAudit) -> CheckupFindingCounts {
        var high = 0, medium = 0, low = 0
        for finding in audit.findings {
            switch finding.severity {
            case .critical: high += 1
            case .warning: medium += 1
            case .info: low += 1
            }
        }
        return CheckupFindingCounts(high: high, medium: medium, low: low)
    }

    /// Sidebar badge: findings that are warnings or worse.
    static func attentionCount(_ audit: AgentConfigAudit) -> Int {
        audit.findings(atLeast: .warning).count
    }

    // MARK: - Project roots

    /// Project folders to audit: discovered workspaces first, then granted
    /// folders, deduplicated and capped. The home folder and its ancestors are
    /// excluded because the audit already reads home-level settings.
    static func projectRoots(
        workspaces: [URL],
        grantedFolders: [URL],
        homeDirectory: URL,
        limit: Int = 200
    ) -> [URL] {
        let homePath = homeDirectory.standardizedFileURL.path
        var seen: Set<String> = []
        var roots: [URL] = []
        for url in workspaces + grantedFolders {
            let standardized = url.standardizedFileURL
            let path = standardized.path
            let isHomeOrAncestor = path == homePath || path == "/" || homePath.hasPrefix(path + "/")
            guard !isHomeOrAncestor, seen.insert(path).inserted else { continue }
            roots.append(standardized)
            if roots.count >= limit { break }
        }
        return roots
    }
}

// MARK: - Sandbox adjustment

/// Installory runs in the App Sandbox and can only see folders the user
/// granted (plus system folders such as /usr/bin). A program "not found" in a
/// folder it cannot see is a guess, not a fact, so those findings are softened
/// to "Good to know" with an honest note instead of a warning.
enum AISetupSandboxAdjustment {
    static let systemPrefixes = ["/usr/", "/bin/", "/sbin/", "/System/"]

    static let uncertaintyNote = " Installory can only look inside folders you've allowed, so it may simply not be able to see this program."

    static func adjust(
        _ audit: AgentConfigAudit,
        visibleRoots: [URL],
        homeDirectory: URL
    ) -> AgentConfigAudit {
        let rootPaths = visibleRoots.map { $0.standardizedFileURL.path }
        func isVisible(_ path: String) -> Bool {
            let path = URL(fileURLWithPath: path).standardizedFileURL.path
            if systemPrefixes.contains(where: { path.hasPrefix($0) || path + "/" == $0 }) { return true }
            return rootPaths.contains { root in
                root == "/" || path == root || path.hasPrefix(root + "/")
            }
        }
        let searchedDirectoriesVisible = AgentConfigAuditor
            .defaultBinaryDirectories(homeDirectory: homeDirectory)
            .allSatisfy { isVisible($0.path) }

        let adjusted = audit.findings.map { finding -> AgentConfigFinding in
            guard finding.kind == .mcpCommandNotFound, finding.severity > .info else { return finding }
            let certain: Bool
            if finding.id.hasPrefix("mcpCommandNotFound:path:") {
                certain = isVisible(String(finding.id.dropFirst("mcpCommandNotFound:path:".count)))
            } else {
                certain = searchedDirectoriesVisible
            }
            guard !certain else { return finding }
            return AgentConfigFinding(
                id: finding.id,
                kind: finding.kind,
                category: finding.category,
                severity: .info,
                title: finding.title,
                explanation: finding.explanation + uncertaintyNote,
                suggestedFix: finding.suggestedFix,
                affectedServers: finding.affectedServers,
                affectedFiles: finding.affectedFiles
            )
        }
        // Stable re-sort: most severe first, original order within a severity.
        let sorted = adjusted.enumerated()
            .sorted { lhs, rhs in
                lhs.element.severity != rhs.element.severity
                    ? lhs.element.severity > rhs.element.severity
                    : lhs.offset < rhs.offset
            }
            .map(\.element)

        return AgentConfigAudit(
            servers: audit.servers,
            instructionFiles: audit.instructionFiles,
            permissionProfiles: audit.permissionProfiles,
            findings: sorted,
            unreadableFiles: audit.unreadableFiles
        )
    }
}
