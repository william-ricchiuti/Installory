import Foundation

/// Turns collected servers, instruction files and permission profiles into
/// plain-English findings for people new to AI coding tools.
struct AgentConfigFindingRules {
    let homeDirectory: URL
    let binarySearchDirectories: [URL]
    let access: any DirectoryAccessProvider

    static let largeInstructionCharacterThreshold = 40_000

    // MARK: - MCP servers

    func mcpFindings(for servers: [MCPServerEntry]) -> [AgentConfigFinding] {
        var findings: [AgentConfigFinding] = []
        let byName = Dictionary(grouping: servers) { $0.name.lowercased() }

        for key in byName.keys.sorted() {
            let group = byName[key] ?? []
            let displayName = group.first?.name ?? key

            // 1. Same name, different definitions.
            let signatures = Set(group.map(\.definitionSignature))
            if signatures.count > 1 {
                let lines = group.map { "• \(Self.place(of: $0)): \(Self.summary(of: $0))" }
                findings.append(AgentConfigFinding(
                    id: "mcpConflictingDefinitions:\(key)",
                    kind: .mcpConflictingDefinitions,
                    category: .mcpServers,
                    severity: .warning,
                    title: "“\(displayName)” is set up differently in different places",
                    explanation: """
                    The MCP server named “\(displayName)” doesn't start the same way everywhere it's configured:
                    \(lines.joined(separator: "\n"))
                    Depending on which app or project you're in, you may get a different version or even a \
                    different server under the same name, which can be confusing when something works in one \
                    place and not another.
                    """,
                    suggestedFix: "Make the settings match, or remove the copies you no longer use.",
                    affectedServers: group,
                    affectedFiles: Self.uniqueFiles(group.map(\.configFile))
                ))
            }

            // 2. Same server in several apps.
            let clients = Self.orderedUnique(group.map(\.client))
            if clients.count > 1 {
                let names = Self.list(clients.map(\.displayName))
                findings.append(AgentConfigFinding(
                    id: "mcpSharedAcrossApps:\(key)",
                    kind: .mcpSharedAcrossApps,
                    category: .mcpServers,
                    severity: .info,
                    title: "“\(displayName)” is installed in \(clients.count) apps",
                    explanation: """
                    \(names) each have their own copy of the “\(displayName)” MCP server (a plug-in that gives \
                    the AI extra tools). That's normal, but each app keeps its own settings: when you update, \
                    change a key, or remove it, remember to do it in every app.
                    """,
                    affectedServers: group,
                    affectedFiles: Self.uniqueFiles(group.map(\.configFile))
                ))
            }
        }

        // 3. Command not found.
        findings += commandNotFoundFindings(servers)

        // 4. Literal secrets.
        for server in servers {
            let secrets = (server.maskedEnv + server.maskedHeaders).filter(\.isLiteralSecret)
            guard !secrets.isEmpty || server.hasInlineSecret else { continue }
            var shown = secrets.map { "\($0.key) = \($0.maskedValue)" }
            if server.hasInlineSecret {
                shown.append(server.transport == .remote ? "a key inside the server address" : "a command-line argument")
            }
            let fix: String
            if let firstKey = secrets.first?.key {
                fix = """
                Keep the real value out of the file. Where the app supports it, store the key as an \
                environment variable and reference it instead, for example "\(firstKey)": "${\(firstKey)}".
                """
            } else {
                fix = """
                Take the key out of the \(server.transport == .remote ? "server address" : "command line"). \
                Most servers can read it from an environment variable or a header instead; check the server's \
                instructions.
                """
            }
            let sharedNote = server.scope.kind == .project
                ? " This file is inside a project folder, so if the project is shared with git the key may already be public — replace (rotate) the key with the service that issued it."
                : ""
            findings.append(AgentConfigFinding(
                id: "mcpLiteralSecret:\(server.id)",
                kind: .mcpLiteralSecret,
                category: .mcpServers,
                severity: .critical,
                title: "A password or API key is written directly in “\(server.name)”'s settings",
                explanation: """
                \(server.client.displayName)'s settings for “\(server.name)” contain what looks like a real \
                secret (shown here only partially): \(shown.joined(separator: ", ")). Anyone or anything that \
                can read \(Self.tildePath(server.configFile, home: homeDirectory)) — a backup, a screen share, another app, or a \
                git commit — can copy and use it.\(sharedNote)
                """,
                suggestedFix: fix,
                affectedServers: [server],
                affectedFiles: [server.configFile]
            ))
        }

        // 5. Remote servers, grouped by host.
        // Servers on this Mac (localhost) don't cross the internet, so they're skipped.
        let remote = servers.filter {
            $0.transport == .remote && $0.enabled && !Self.isLocalHost($0.urlHost)
        }
        let byHost = Dictionary(grouping: remote) { $0.urlHost ?? "an unknown address" }
        for host in byHost.keys.sorted() {
            let group = byHost[host] ?? []
            let uniqueNames = Self.orderedUnique(group.map { "“\($0.name)”" })
            let names = Self.list(uniqueNames)
            let single = uniqueNames.count == 1
            findings.append(AgentConfigFinding(
                id: "mcpRemoteServer:\(host)",
                kind: .mcpRemoteServer,
                category: .mcpServers,
                severity: .info,
                title: "Connects to \(host) over the internet",
                explanation: """
                \(names) \(single ? "is a remote server" : "are remote servers"): instead of \
                running on your Mac, \(single ? "it talks" : "they talk") to \(host). Parts of your \
                conversations and files the AI chooses to share may be sent there, so keep it only if you \
                trust whoever runs that service.
                """,
                affectedServers: group,
                affectedFiles: Self.uniqueFiles(group.map(\.configFile))
            ))
        }

        // 6. Disabled servers.
        for server in servers where !server.enabled {
            findings.append(AgentConfigFinding(
                id: "mcpDisabled:\(server.id)",
                kind: .mcpDisabled,
                category: .mcpServers,
                severity: .info,
                title: "“\(server.name)” is turned off in \(server.client.displayName)",
                explanation: """
                It's still listed in \(Self.tildePath(server.configFile, home: homeDirectory)) but won't run. You can delete it \
                to tidy up, or leave it if you plan to turn it back on.
                """,
                affectedServers: [server],
                affectedFiles: [server.configFile]
            ))
        }
        return findings
    }

    private func commandNotFoundFindings(_ servers: [MCPServerEntry]) -> [AgentConfigFinding] {
        var missingAbsolute: [String: [MCPServerEntry]] = [:]
        var missingBare: [String: [MCPServerEntry]] = [:]
        for server in servers where server.transport == .stdio && server.enabled {
            guard let command = server.command else { continue }
            switch resolve(command: command, for: server) {
            case .found, .unknown: continue
            case .missingPath(let path): missingAbsolute[path, default: []].append(server)
            case .missingBare(let name): missingBare[name, default: []].append(server)
            }
        }
        var findings: [AgentConfigFinding] = []
        for path in missingAbsolute.keys.sorted() {
            let group = missingAbsolute[path] ?? []
            let names = Self.list(Self.orderedUnique(group.map { "“\($0.name)”" }))
            findings.append(AgentConfigFinding(
                id: "mcpCommandNotFound:path:\(path)",
                kind: .mcpCommandNotFound,
                category: .mcpServers,
                severity: .warning,
                title: "The program for \(names) is missing",
                explanation: """
                The settings say to start \(path), but nothing exists at that location. The server will \
                fail to start until the program is reinstalled or the path in the settings is corrected. \
                (This often happens after a tool is upgraded or moved.)
                """,
                suggestedFix: "Reinstall the server, or update the path in its settings, then restart the app.",
                affectedServers: group,
                affectedFiles: Self.uniqueFiles(group.map(\.configFile))
            ))
        }
        for name in missingBare.keys.sorted() {
            let group = missingBare[name] ?? []
            let uniqueNames = Self.orderedUnique(group.map { "“\($0.name)”" })
            let names = Self.list(uniqueNames)
            findings.append(AgentConfigFinding(
                id: "mcpCommandNotFound:bare:\(name)",
                kind: .mcpCommandNotFound,
                category: .mcpServers,
                severity: .warning,
                title: "Couldn't find “\(name)”; \(names) may fail to start",
                explanation: """
                \(names) \(uniqueNames.count == 1 ? "needs" : "need") a program called “\(name)”. Installory \
                looked in the usual places programs are installed (Homebrew, /usr/local/bin, /usr/bin, \
                ~/.local/bin, Cargo, Bun, Volta and nvm) and didn't find it, so the server may fail to start. \
                If it already works for you, the program is probably installed somewhere Installory can't \
                see and you can ignore this.
                """,
                suggestedFix: Self.installHint(for: name),
                affectedServers: group,
                affectedFiles: Self.uniqueFiles(group.map(\.configFile))
            ))
        }
        return findings
    }

    enum CommandResolution: Equatable {
        case found
        case unknown
        case missingPath(String)
        case missingBare(String)
    }

    func resolve(command rawCommand: String, for server: MCPServerEntry) -> CommandResolution {
        var command = rawCommand.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return .unknown }
        // A whole command line in `command` ("npx -y pkg"): judge the first word,
        // unless the full string is itself an existing path with spaces.
        if command.contains(" ") {
            if command.hasPrefix("/") || command.hasPrefix("~"),
               access.fileExists(at: expand(command)) {
                return .found
            }
            command = String(command.split(separator: " ").first ?? "")
        }
        // Variable references (e.g. ${workspaceFolder}/bin/x) can't be judged.
        if command.contains("$") || command.contains("{") { return .unknown }
        if command.hasPrefix("/") || command.hasPrefix("~/") {
            let url = expand(command)
            return access.fileExists(at: url) ? .found : .missingPath(url.path)
        }
        if command.contains("/") {
            guard let project = server.scope.projectPath else { return .unknown }
            let url = project.appendingPathComponent(command).standardizedFileURL
            return access.fileExists(at: url) ? .found : .missingPath(url.path)
        }
        for directory in binarySearchDirectories {
            if access.fileExists(at: directory.appendingPathComponent(command)) { return .found }
        }
        return .missingBare(command)
    }

    private func expand(_ path: String) -> URL {
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func installHint(for command: String) -> String {
        switch command {
        case "npx", "node", "npm":
            "“\(command)” comes with Node.js. Install Node.js (for example from nodejs.org or with Homebrew: brew install node), then restart the app."
        case "uvx", "uv":
            "“\(command)” comes with uv, a Python tool runner. Install it (for example with Homebrew: brew install uv), then restart the app."
        case "bunx", "bun":
            "“\(command)” comes with Bun. Install it from bun.sh, then restart the app."
        case "docker":
            "“docker” comes with Docker Desktop. Install and open Docker Desktop, then restart the app."
        case "python", "python3", "pip", "pip3":
            "Install Python (for example with Homebrew: brew install python), then restart the app."
        case "deno":
            "Install Deno from deno.com, then restart the app."
        default:
            "Install the program that provides “\(command)”, or replace it in the settings with the program's full path."
        }
    }

    // MARK: - Unreadable config files

    func unreadableFindings(_ files: [UnreadableConfigFile], maximumBytes: Int) -> [AgentConfigFinding] {
        files.map { file in
            let explanation: String
            let fix: String
            switch file.reason {
            case .tooLarge:
                explanation = """
                This file is bigger than Installory reads (\(Self.megabytes(maximumBytes))), so the servers \
                and settings inside it weren't checked.
                """
                fix = "Nothing is necessarily wrong; just keep in mind this file wasn't reviewed."
            case .unreadable:
                explanation = """
                Installory couldn't open this file, so the servers and settings inside it weren't checked. \
                This usually means Installory hasn't been given access to that folder.
                """
                fix = "To include it, grant Installory access to the folder that contains it."
            case .invalidFormat:
                explanation = """
                This settings file couldn't be understood — it isn't valid JSON (or text). The app that owns \
                it probably can't read it either, so the servers or settings in it may silently not work. A \
                missing comma, quote or bracket is the most common cause.
                """
                fix = "Open the file in a code editor that highlights JSON mistakes and fix the error it points to."
            }
            return AgentConfigFinding(
                id: "configFileUnreadable:\(file.path.path)",
                kind: .configFileUnreadable,
                category: .configFiles,
                severity: .warning,
                title: "Couldn't read \(Self.tildePath(file.path, home: homeDirectory))",
                explanation: explanation,
                suggestedFix: fix,
                affectedFiles: [file.path]
            )
        }
    }

    // MARK: - Instruction files

    func instructionFindings(_ files: [InstructionFile], projectRoots: [URL]) -> [AgentConfigFinding] {
        var findings: [AgentConfigFinding] = []

        for file in files {
            let shownPath = Self.tildePath(file.path, home: homeDirectory)
            if file.isBrokenSymlink {
                let target = file.symlinkTarget.map { " It points to \(Self.tildePath($0, home: homeDirectory)), which doesn't exist." } ?? ""
                findings.append(AgentConfigFinding(
                    id: "brokenInstructionSymlink:\(file.path.path)",
                    kind: .brokenInstructionSymlink,
                    category: .instructions,
                    severity: .warning,
                    title: "\(file.path.lastPathComponent) is a broken shortcut",
                    explanation: """
                    \(shownPath) is a symbolic link (a shortcut to another file), but the file it points to is \
                    gone.\(target) \(file.tool.displayName) will behave as if you had no instructions here.
                    """,
                    suggestedFix: "Recreate the file it points to, or replace the shortcut with a regular file.",
                    affectedFiles: [file.path]
                ))
                continue
            }

            let isLarge: Bool
            if let characters = file.characterCount {
                isLarge = characters > Self.largeInstructionCharacterThreshold
            } else if let bytes = file.byteSize {
                // Unread because of size: UTF-8 has at most 4 bytes per character.
                isLarge = bytes > Int64(Self.largeInstructionCharacterThreshold * 4)
            } else {
                isLarge = false
            }
            if isLarge {
                let size = file.characterCount.map { "\(Self.formatted($0)) characters" }
                    ?? file.byteSize.map { "\(Self.formatted(Int($0))) bytes" } ?? "very large"
                findings.append(AgentConfigFinding(
                    id: "instructionFileTooLarge:\(file.path.path)",
                    kind: .instructionFileTooLarge,
                    category: .instructions,
                    severity: .warning,
                    title: "\(file.path.lastPathComponent) is very large (\(size))",
                    explanation: """
                    \(shownPath) is loaded into every conversation with \(file.tool.displayName). A long \
                    instruction file uses up the AI's limited memory (its “context”) before you've typed \
                    anything, which can make it slower, more expensive and more likely to forget or ignore \
                    instructions.
                    """,
                    suggestedFix: "Trim it to the rules that matter most (aim for well under 40,000 characters) and move reference material into separate files the AI can open when needed.",
                    affectedFiles: [file.path]
                ))
            }

            if file.kind == .cursorRulesLegacy {
                findings.append(AgentConfigFinding(
                    id: "legacyCursorRules:\(file.path.path)",
                    kind: .legacyCursorRules,
                    category: .instructions,
                    severity: .info,
                    title: "This project uses the older .cursorrules file",
                    explanation: """
                    \(shownPath) is Cursor's original rules file. Cursor still reads it for now, but newer \
                    versions prefer rule files inside a .cursor/rules folder, which can be split by topic and \
                    applied only where they're relevant.
                    """,
                    suggestedFix: "When convenient, move the contents into a file such as .cursor/rules/project.mdc and delete .cursorrules.",
                    affectedFiles: [file.path]
                ))
            }
        }

        findings += agentsMdFindings(files, projectRoots: projectRoots)
        return findings
    }

    private func agentsMdFindings(_ files: [InstructionFile], projectRoots: [URL]) -> [AgentConfigFinding] {
        var findings: [AgentConfigFinding] = []
        for project in projectRoots.map(\.standardizedFileURL) {
            let projectFiles = files.filter { $0.scope.projectPath == project && !$0.isBrokenSymlink }
            guard let agents = projectFiles.first(where: { $0.kind == .agentsMd }) else { continue }
            let agentsPaths: Set<String> = [
                agents.path.standardizedFileURL.path,
                access.resolvingSymlinks(at: agents.path).standardizedFileURL.path,
            ]
            let claudeFiles = projectFiles.filter { [.claudeMd, .claudeLocalMd].contains($0.kind) }

            // AGENTS.md that is itself a shortcut to a Claude file is already read.
            if let target = agents.symlinkTarget,
               claudeFiles.contains(where: { access.resolvingSymlinks(at: $0.path).standardizedFileURL.path == target.path }) {
                continue
            }

            let covered = claudeFiles.contains { claude in
                if let target = claude.symlinkTarget, agentsPaths.contains(target.path) { return true }
                return claude.imports.contains { path in
                    let resolved = InstructionFileCollector.resolveImport(path, from: claude.path, homeDirectory: homeDirectory)
                    return agentsPaths.contains(resolved.path)
                        || agentsPaths.contains(access.resolvingSymlinks(at: resolved).standardizedFileURL.path)
                }
            }
            guard !covered else { continue }

            let projectName = project.lastPathComponent
            let explanation: String
            let fix: String
            let mainClaude = claudeFiles.first { $0.kind == .claudeMd }
            if let mainClaude {
                let claudeName = mainClaude.path.path.hasSuffix(".claude/CLAUDE.md") ? ".claude/CLAUDE.md" : "CLAUDE.md"
                let importLine = claudeName == "CLAUDE.md" ? "@AGENTS.md" : "@../AGENTS.md"
                explanation = """
                “\(projectName)” has an AGENTS.md file with instructions for AI agents. Codex, opencode, \
                Cursor and others read it, but Claude Code only reads CLAUDE.md — and this project's \
                \(claudeName) doesn't include AGENTS.md. So Claude Code isn't following those instructions.
                """
                fix = "Add a line `\(importLine)` to \(claudeName). Claude Code will then load AGENTS.md too."
            } else {
                explanation = """
                “\(projectName)” has an AGENTS.md file with instructions for AI agents. Codex, opencode, \
                Cursor and others read it, but Claude Code only reads CLAUDE.md, which this project doesn't \
                have. So Claude Code isn't following those instructions.
                """
                fix = "Create a file named CLAUDE.md next to AGENTS.md containing the single line `@AGENTS.md`."
            }
            findings.append(AgentConfigFinding(
                id: "agentsMdNotReadByClaude:\(project.path)",
                kind: .agentsMdNotReadByClaude,
                category: .instructions,
                severity: .info,
                title: "Claude Code doesn't read this project's AGENTS.md",
                explanation: explanation,
                suggestedFix: fix,
                affectedFiles: [agents.path] + claudeFiles.map(\.path)
            ))
        }
        return findings
    }

    // MARK: - Permissions

    func permissionFindings(_ profiles: [PermissionProfile]) -> [AgentConfigFinding] {
        var findings: [AgentConfigFinding] = []
        for profile in profiles {
            let file = profile.configFile
            let shownPath = Self.tildePath(file, home: homeDirectory)
            let whereText = profile.scope.kind == .user
                ? "for all your projects"
                : "in “\(profile.scope.projectPath?.lastPathComponent ?? "this project")”"

            switch profile.tool {
            case .claudeCode:
                if profile.defaultMode?.lowercased() == "bypasspermissions" {
                    findings.append(AgentConfigFinding(
                        id: "bypassPermissions:\(file.path)",
                        kind: .bypassPermissions,
                        category: .permissions,
                        severity: .critical,
                        title: "Your agent can run any command without asking",
                        explanation: """
                        \(shownPath) turns on “bypass permissions” mode \(whereText). Claude Code will edit and \
                        delete files, run terminal commands and fetch web pages without ever stopping to ask \
                        you. One mistake — or a malicious instruction hidden in a web page or file it reads — \
                        could delete your work or leak private data before you notice.
                        """,
                        suggestedFix: """
                        Remove "defaultMode": "bypassPermissions" from the file, or change it to "acceptEdits" \
                        (auto-approves file edits but still asks before running commands).
                        """,
                        affectedFiles: [file]
                    ))
                }
                if profile.skipDangerousModePermissionPrompt == true {
                    findings.append(AgentConfigFinding(
                        id: "dangerousModePromptSkipped:\(file.path)",
                        kind: .dangerousModePromptSkipped,
                        category: .permissions,
                        severity: .warning,
                        title: "The warning before “skip permissions” mode is turned off",
                        explanation: """
                        \(shownPath) hides the confirmation Claude Code normally shows before entering a mode \
                        where it runs everything without asking. That makes it easy to switch it on by habit.
                        """,
                        suggestedFix: "Remove \"skipDangerousModePermissionPrompt\": true from the file.",
                        affectedFiles: [file]
                    ))
                }
                for rule in profile.allow {
                    guard let explanation = Self.broadRuleExplanation(rule) else { continue }
                    findings.append(AgentConfigFinding(
                        id: "broadAllowRule:\(file.path):\(rule)",
                        kind: .broadAllowRule,
                        category: .permissions,
                        severity: .warning,
                        title: "Broad permission: \(rule)",
                        explanation: """
                        \(shownPath) pre-approves \(rule) \(whereText). \(explanation)
                        """,
                        suggestedFix: "Remove this rule from the \"allow\" list, or replace it with narrower rules for the exact commands you use (for example Bash(npm run test:*)).",
                        affectedFiles: [file]
                    ))
                }
                if profile.scope.kind == .local, !profile.allow.isEmpty {
                    let count = profile.allow.count
                    findings.append(AgentConfigFinding(
                        id: "rememberedApprovals:\(file.path)",
                        kind: .rememberedApprovals,
                        category: .permissions,
                        severity: .info,
                        title: "\(count) \(count == 1 ? "command" : "commands") you approved with “don't ask again”",
                        explanation: """
                        Each time you chose “Yes, and don't ask again” in Claude Code \(whereText), the \
                        approval was saved in \(shownPath). These add up over time; it's worth skimming the \
                        list now and then and removing anything you wouldn't approve today.
                        """,
                        suggestedFix: "Open the file and delete entries from the \"allow\" list you no longer want auto-approved.",
                        affectedFiles: [file]
                    ))
                }
                if !profile.hooks.isEmpty {
                    let lines = profile.hooks.flatMap { hook in
                        hook.commands.map { command in
                            "• \(Self.eventDescription(hook.event))\(hook.matcher.map { " (\($0))" } ?? ""): \(command)"
                        }
                    }
                    findings.append(AgentConfigFinding(
                        id: "hooksConfigured:\(file.path)",
                        kind: .hooksConfigured,
                        category: .permissions,
                        severity: .info,
                        title: "\(lines.count) \(lines.count == 1 ? "command runs" : "commands run") automatically",
                        explanation: """
                        \(shownPath) sets up “hooks”: commands Claude Code runs on its own when certain things \
                        happen, without asking you each time:
                        \(lines.joined(separator: "\n"))
                        Make sure you recognize each one.
                        """,
                        affectedFiles: [file]
                    ))
                }
                if profile.enableAllProjectMcpServers == true {
                    findings.append(AgentConfigFinding(
                        id: "allProjectMcpServersEnabled:\(file.path)",
                        kind: .allProjectMcpServersEnabled,
                        category: .permissions,
                        severity: .warning,
                        title: "Projects can start their own MCP servers without asking",
                        explanation: """
                        \(shownPath) sets enableAllProjectMcpServers to true \(whereText). Any project you open \
                        — including one you just downloaded — can list MCP servers in its .mcp.json and Claude \
                        Code will start them automatically, which means running programs chosen by whoever \
                        wrote that project.
                        """,
                        suggestedFix: "Remove \"enableAllProjectMcpServers\": true so Claude Code asks before starting a project's servers.",
                        affectedFiles: [file]
                    ))
                }
                let secrets = profile.maskedEnv.filter(\.isLiteralSecret)
                if !secrets.isEmpty {
                    let shown = secrets.map { "\($0.key) = \($0.maskedValue)" }.joined(separator: ", ")
                    findings.append(AgentConfigFinding(
                        id: "settingsLiteralSecret:\(file.path)",
                        kind: .settingsLiteralSecret,
                        category: .permissions,
                        severity: .critical,
                        title: "A password or API key is written directly in \(file.lastPathComponent)",
                        explanation: """
                        The "env" section of \(shownPath) contains what looks like a real secret (shown here \
                        only partially): \(shown). Anyone or anything that can read the file — a backup, a \
                        screen share, or a git commit — can copy and use it.
                        """,
                        suggestedFix: "Move the value into your shell profile or a password manager and remove it from this file. If the file was ever committed to git, replace (rotate) the key.",
                        affectedFiles: [file]
                    ))
                }

            case .codex:
                let approval = profile.approvalPolicy?.lowercased()
                let sandbox = profile.sandboxMode?.lowercased()
                if sandbox == "danger-full-access" {
                    let neverAsks = approval == "never"
                    findings.append(AgentConfigFinding(
                        id: "codexFullAccess:\(file.path)",
                        kind: .codexFullAccess,
                        category: .permissions,
                        severity: neverAsks ? .critical : .warning,
                        title: neverAsks
                            ? "Your agent can run any command without asking"
                            : "Codex runs without its safety sandbox",
                        explanation: neverAsks
                            ? """
                            \(shownPath) sets Codex to never ask for approval (approval_policy = "never") and \
                            turns off its sandbox (sandbox_mode = "danger-full-access"). Codex can change or \
                            delete any file and use the internet without checking with you first.
                            """
                            : """
                            \(shownPath) turns off Codex's sandbox (sandbox_mode = "danger-full-access"), the \
                            protection that normally keeps it inside your project folder and off the network. \
                            It will still ask before some actions, but anything it runs can reach your whole Mac.
                            """,
                        suggestedFix: "Use sandbox_mode = \"workspace-write\" and approval_policy = \"on-request\" unless you have a specific reason not to.",
                        affectedFiles: [file]
                    ))
                }
            }
        }
        return findings
    }

    /// Returns a beginner-friendly explanation when an allow rule is broad.
    static func broadRuleExplanation(_ rawRule: String) -> String? {
        let rule = rawRule.trimmingCharacters(in: .whitespaces)
        let anyCommand = "That lets the agent run any terminal command without asking — including deleting files or sending data off your Mac."
        if ["Bash", "Bash(*)", "Bash(:*)", "Bash(**)", "Bash( *)"].contains(rule) {
            return anyCommand
        }
        if ["WebFetch", "WebFetch(*)"].contains(rule) {
            return "That lets the agent download any web page without asking. Web pages can contain hidden instructions that try to trick the AI; limiting it to specific sites, e.g. WebFetch(domain:docs.python.org), is safer."
        }
        guard rule.hasPrefix("Bash("), rule.hasSuffix(")") else { return nil }
        let inner = String(rule.dropFirst(5).dropLast())
        // Accept both the "cmd:*" and the newer "cmd *" / "cmd*" wildcard styles.
        // An exact command without a wildcard is narrow by definition.
        guard let suffix = [":*", " *", "*"].first(where: { inner.hasSuffix($0) }) else { return nil }
        let program = String(inner.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        let explanations: [String: String] = [
            "rm": "That lets the agent delete any file or folder without asking, and files removed this way don't go to the Trash.",
            "sudo": "That lets the agent run commands as an administrator without asking, which can change system settings or anything else on your Mac.",
            "curl": "That lets the agent download or upload anything on the internet without asking — including sending your files or keys somewhere.",
            "wget": "That lets the agent download anything from the internet without asking.",
            "sh": "That lets the agent run any shell script without asking, which is the same as allowing every command.",
            "bash": "That lets the agent run any shell script without asking, which is the same as allowing every command.",
            "zsh": "That lets the agent run any shell script without asking, which is the same as allowing every command.",
            "eval": "That lets the agent run any command without asking, hidden inside eval.",
            "python": "That lets the agent run any Python code without asking, which can do anything a command can.",
            "python3": "That lets the agent run any Python code without asking, which can do anything a command can.",
            "node": "That lets the agent run any JavaScript without asking, which can do anything a command can.",
            "chmod": "That lets the agent change file permissions anywhere without asking, which can make private files readable or programs runnable.",
            "git push": "That lets the agent publish code to your remote repositories without asking.",
        ]
        if program.isEmpty { return anyCommand }
        return explanations[program]
    }

    private static func eventDescription(_ event: String) -> String {
        switch event {
        case "PreToolUse": "Before the agent uses a tool"
        case "PostToolUse": "After the agent uses a tool"
        case "UserPromptSubmit": "When you send a message"
        case "SessionStart": "When a session starts"
        case "SessionEnd": "When a session ends"
        case "Stop": "When the agent finishes responding"
        case "SubagentStop": "When a helper agent finishes"
        case "Notification": "When the agent sends a notification"
        case "PreCompact": "Before the conversation is compacted"
        default: event
        }
    }

    // MARK: - Formatting helpers

    static func place(of server: MCPServerEntry) -> String {
        switch server.scope.kind {
        case .user: "\(server.client.displayName), all projects"
        case .project: "\(server.client.displayName), project “\(server.scope.projectPath?.lastPathComponent ?? "")”"
        case .local: "\(server.client.displayName), project “\(server.scope.projectPath?.lastPathComponent ?? "")” (private to you)"
        }
    }

    static func summary(of server: MCPServerEntry) -> String {
        switch server.transport {
        case .stdio:
            ([server.command ?? "(no command)"] + server.args).joined(separator: " ")
        case .remote:
            "remote server at \(server.urlHost ?? "an unknown address")"
        }
    }

    static func isLocalHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let name = host.hasPrefix("[") ? host : String(host.split(separator: ":").first ?? "")
        return ["localhost", "127.0.0.1", "0.0.0.0", "[::1]"].contains(name)
            || host.hasPrefix("[::1]")
            || name.hasSuffix(".localhost")
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    static func orderedUnique<T: Hashable>(_ items: [T]) -> [T] {
        var seen: Set<T> = []
        return items.filter { seen.insert($0).inserted }
    }

    static func uniqueFiles(_ files: [URL]) -> [URL] {
        var seen: Set<String> = []
        return files.filter { seen.insert($0.path).inserted }
    }

    static func tildePath(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }

    static func formatted(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }

    static func megabytes(_ bytes: Int) -> String {
        let value = Double(bytes) / 1_048_576
        return value == value.rounded() ? "\(Int(value)) MB" : String(format: "%.1f MB", value)
    }
}
