import Foundation

/// Builds copyable "Ask your agent" prompts from Installory's read-only findings.
///
/// Pure: no filesystem, process, or network access. The home directory is
/// injected so paths can be rendered as `~/...` without asking the system.
///
/// Every prompt ends with the same short guardrails (`AgentPromptBuilder.guardrails`).
public struct AgentPromptBuilder: Sendable, Equatable {
    public let agent: PromptAgent
    public let redactor: HomePathRedactor

    /// Rough length budget for the non-setup prompts (soft target, not enforced).
    public static let targetMaxCharacters = 1_200
    /// Default cap for the setup-context prompt.
    public static let defaultSetupMaxCharacters = 4_000

    /// Appended to every prompt.
    public static let guardrails = """
    Ground rules:
    - Explain each command before you run it, and wait for my OK.
    - Don't use sudo, --break-system-packages, or rm -rf without asking me first.
    - Make changes reversible where you can, and tell me how to undo each one.
    """

    public init(agent: PromptAgent, homeDirectory: URL) {
        self.agent = agent
        self.redactor = HomePathRedactor(homeDirectory: homeDirectory)
    }

    // MARK: - (a) Single package

    /// "Help me decide whether to remove X."
    ///
    /// - Parameters:
    ///   - dependentsCount: Number of inventory packages that depend on it.
    ///   - verdict: Installory's removal-safety verdict, if computed.
    ///   - installedBy: Plain label for who installed it (see `installerLabel(from:)`), if known.
    public func removalPrompt(
        for package: Package,
        dependentsCount: Int,
        verdict: RemovalSafetyVerdict?,
        installedBy: String? = nil
    ) -> AgentPrompt {
        var facts: [String] = [
            "- Name: \(package.name)",
            "- Installed with: \(Self.managerName(package.manager))",
            "- Version: \(package.version)",
        ]
        if let path = package.installPath {
            facts.append("- Location: \(redactor.display(path))")
        }
        facts.append("- Other installed packages that depend on it: \(dependentsCount)")
        if let verdict {
            var line = "- Installory's safety check: \(Self.safetyLabel(verdict.safety))"
            if let reason = verdict.reasons.first { line += " (\(reason))" }
            facts.append(line)
        }
        if let installedBy, !installedBy.isEmpty {
            facts.append("- Installed by: \(installedBy)")
        }

        let body = compose([
            "\(greeting)Please help me decide whether to remove \(package.name) from my Mac.",
            facts.joined(separator: "\n"),
            """
            Please:
            1. Check whether anything I use still needs it (my projects, other tools, shell config).
            2. Tell me in plain words what it does and whether removing it is a good idea.
            3. If it is, show me the exact removal command and explain it before running anything.
            """,
        ])
        return AgentPrompt(title: "Ask about removing \(package.name)", body: body, targetAgent: agent)
    }

    // MARK: - (b) Duplicate group

    /// "Same tool installed more than once — which one runs, and how do I consolidate?"
    ///
    /// - Parameter standings: PATH standings from `resolvePathStandings(for:path:)`;
    ///   pass `[:]` when unknown and the agent will be asked to check.
    public func duplicatePrompt(
        for group: DuplicateGroup,
        standings: [String: PathStanding] = [:]
    ) -> AgentPrompt {
        var lines: [String] = []
        for package in group.packages.sorted(by: { $0.id < $1.id }) {
            var line = "- \(Self.managerName(package.manager)), version \(package.version)"
            if let path = package.installPath {
                line += ", at \(redactor.display(path))"
            }
            switch standings[package.id] {
            case .wins?: line += " (runs first on my PATH)"
            case .shadowed?: line += " (hidden behind another copy on my PATH)"
            case .unknown?, nil: break
            }
            lines.append(line)
        }

        let knowsWinner = standings.values.contains(.wins)
        let pathStep = knowsWinner
            ? "1. Confirm which copy actually runs when I type \(group.name) (for example with `which -a \(group.name)`)."
            : "1. Find out which copy actually runs when I type \(group.name) (for example with `which -a \(group.name)`)."

        var steps = [
            pathStep,
            "2. Recommend which one to keep, and why, based on how I install my other tools.",
            "3. Check whether any of my projects or scripts rely on a specific copy.",
            "4. Show me how to remove the extra copies, one at a time.",
        ]
        if group.name.lowercased().hasPrefix("python") {
            steps.append("5. Leave the macOS system Python in /usr/bin alone.")
        }

        let body = compose([
            "\(greeting)I have \(group.name) installed \(group.packages.count) times, by different installers:",
            lines.joined(separator: "\n"),
            "Please:\n" + steps.joined(separator: "\n"),
        ])
        return AgentPrompt(title: "Ask about duplicate \(group.name)", body: body, targetAgent: agent)
    }

    // MARK: - (c) Cleanup selection

    /// "I've picked these packages for cleanup — help me do it safely."
    ///
    /// - Parameters:
    ///   - verdicts: Optional removal-safety verdicts keyed by `Package.id`.
    ///   - maxListed: Packages listed individually before summarising the rest.
    public func cleanupPrompt(
        for packages: [Package],
        verdicts: [String: RemovalSafetyVerdict] = [:],
        maxListed: Int = 15
    ) -> AgentPrompt {
        let sorted = packages.sorted {
            let lhs = $0.name.lowercased(), rhs = $1.name.lowercased()
            return lhs != rhs ? lhs < rhs : $0.id < $1.id
        }
        let limit = max(0, maxListed)
        var lines = sorted.prefix(limit).map { package -> String in
            var line = "- \(package.name) (\(Self.managerName(package.manager)) \(package.version))"
            if let verdict = verdicts[package.id] {
                line += " — \(Self.safetyLabel(verdict.safety))"
            }
            return line
        }
        if sorted.count > limit {
            lines.append("- …and \(sorted.count - limit) more")
        }

        let count = sorted.count
        let noun = count == 1 ? "package" : "packages"
        let body = compose([
            "\(greeting)I'd like to clean up \(count) \(noun) on my Mac:",
            lines.isEmpty ? "- (none selected)" : lines.joined(separator: "\n"),
            """
            Please:
            1. Check each one for anything that still uses it, and tell me which to skip.
            2. Group the removals by installer and show me the commands before running them.
            3. Go one group at a time so I can stop if something looks wrong.
            """,
        ])
        return AgentPrompt(title: "Ask about cleaning up \(count) \(noun)", body: body, targetAgent: agent)
    }

    // MARK: - (d) Generic finding

    /// Prompt for a finding such as an MCP-server problem or an exposed secret.
    ///
    /// For `.exposedSecret` the prompt names only the file(s) and the key
    /// name, asks the agent to rotate the key, and never includes a value.
    public func findingPrompt(for finding: PromptFinding) -> AgentPrompt {
        let files = finding.filePaths.map { "- \(redactor.display($0))" }
        let fileBlock = files.isEmpty ? nil : files.joined(separator: "\n")

        switch finding.kind {
        case .general:
            let body = compose([
                "\(greeting)Installory flagged something on my Mac: \(finding.title).",
                redactor.redact(text: finding.explanation),
                fileBlock.map { "Files involved:\n\($0)" },
                """
                Please:
                1. Look at it and tell me in plain words whether it's a real problem.
                2. If it is, suggest the smallest fix and explain it before changing anything.
                """,
            ])
            return AgentPrompt(title: "Ask about: \(finding.title)", body: body, targetAgent: agent)

        case .exposedSecret(let rawKeyName):
            let keyName = Self.sanitizedKeyName(rawKeyName)
            let body = compose([
                "\(greeting)A secret key named \(keyName) is saved in plain text on my Mac.",
                fileBlock.map { "Where it was found:\n\($0)" },
                """
                Please:
                1. Don't print, copy, or paste the key's value anywhere, including this chat.
                2. Help me rotate it: create a new key with the provider and revoke the old one.
                3. Help me move the new key somewhere safer (for example the macOS Keychain or an untracked .env file).
                4. Check whether the file is tracked by git or was ever pushed, and tell me what to do if so.
                """,
            ])
            return AgentPrompt(title: "Ask about exposed key \(keyName)", body: body, targetAgent: agent)
        }
    }

    // MARK: - (e) Setup context

    /// "Here's my setup" built from a compact summary of the inventory:
    /// managers with counts, the total, and notable duplicates.
    public func setupPrompt(
        packages: [Package],
        duplicateGroups: [DuplicateGroup],
        maxCharacters: Int = AgentPromptBuilder.defaultSetupMaxCharacters
    ) -> AgentPrompt {
        let byManager = Dictionary(grouping: packages, by: \.manager)
            .map { (manager: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.manager.rawValue < $1.manager.rawValue }
        var summary = ["Installed tools (\(packages.count) total):"]
        summary += byManager.map { "- \(Self.managerName($0.manager)): \($0.count)" }

        if !duplicateGroups.isEmpty {
            summary.append("")
            summary.append("Installed more than once (\(duplicateGroups.count)):")
            let shown = duplicateGroups.prefix(10)
            for group in shown {
                let managers = Array(Set(group.packages.map { Self.managerName($0.manager) })).sorted()
                summary.append("- \(group.name) (\(managers.joined(separator: ", ")))")
            }
            if duplicateGroups.count > shown.count {
                summary.append("- …and \(duplicateGroups.count - shown.count) more")
            }
        }
        return setupPrompt(context: summary.joined(separator: "\n"), maxCharacters: maxCharacters)
    }

    /// "Here's my setup" built from `EnvironmentReportRenderer` output.
    /// Home paths are rendered as `~` and the body is capped at `maxCharacters`.
    public func setupPrompt(
        environmentReport: String,
        maxCharacters: Int = AgentPromptBuilder.defaultSetupMaxCharacters
    ) -> AgentPrompt {
        setupPrompt(context: environmentReport, maxCharacters: maxCharacters)
    }

    private func setupPrompt(context: String, maxCharacters: Int) -> AgentPrompt {
        let intro = "\(greeting)Here's a summary of the developer tools on my Mac, for context. Use it to give advice that fits my setup, and ask me before changing anything."
        let ending = Self.guardrails
        let fixed = intro.count + ending.count + 4 // two "\n\n" separators
        let budget = max(0, maxCharacters - fixed)
        let trimmed = Self.truncate(redactor.redact(text: context), to: budget)

        let parts = trimmed.isEmpty ? [intro, ending] : [intro, trimmed, ending]
        return AgentPrompt(
            title: "Share my setup",
            body: parts.joined(separator: "\n\n"),
            targetAgent: agent
        )
    }

    // MARK: - Helpers

    /// A plain label for who installed a package, derived from provenance.
    /// Never includes the raw command or session text.
    public static func installerLabel(from evidence: ProvenanceEvidence?) -> String? {
        guard let evidence else { return nil }
        if evidence.claudeCodeContext != nil { return "Claude Code (an AI agent session)" }
        if evidence.codexContext != nil { return "Codex (an AI agent session)" }
        if evidence.opencodeContext != nil { return "opencode (an AI agent session)" }
        if evidence.installCommand != nil { return "me, from the terminal" }
        return nil
    }

    private var greeting: String {
        if let name = agent.displayName { return "Hi \(name). " }
        return ""
    }

    private func compose(_ sections: [String?]) -> String {
        (sections.compactMap { $0 }.filter { !$0.isEmpty } + [Self.guardrails])
            .joined(separator: "\n\n")
    }

    static func managerName(_ manager: PackageManager) -> String {
        switch manager {
        case .brew: "Homebrew"
        case .brewCask: "Homebrew Cask"
        case .pip: "pip"
        case .pipx: "pipx"
        case .uv: "uv"
        case .npm: "npm (global)"
        case .cargo: "Cargo"
        case .gem: "RubyGems"
        case .mas: "Mac App Store"
        case .agentSkill: "agent skill"
        case .agentCli: "agent CLI"
        case .editorExtension: "editor extension"
        }
    }

    static func safetyLabel(_ safety: RemovalSafety) -> String {
        switch safety {
        case .safe: "looks safe to remove"
        case .caution: "remove with care"
        case .leaveAlone: "leave alone"
        }
    }

    /// Keeps only characters that appear in key/variable names and caps the
    /// length, so a value accidentally passed as a name can't be pasted whole.
    static func sanitizedKeyName(_ raw: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-.")
        let cleaned = String(raw.filter { allowed.contains($0) }.prefix(64))
        return cleaned.isEmpty ? "(unnamed key)" : cleaned
    }

    /// Truncates on a line boundary when possible, appending a marker.
    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let marker = "\n…(trimmed)"
        guard limit > marker.count else { return "" }
        let head = String(text.prefix(limit - marker.count))
        if let cut = head.lastIndex(of: "\n"), cut > head.startIndex {
            return String(head[..<cut]) + marker
        }
        return head + marker
    }
}
