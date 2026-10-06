import Foundation
import InstalloryCore
import Testing

@Suite("Guidance: agent prompts")
struct GuidanceAgentPromptTests {

    private static let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    private static let ref = Date(timeIntervalSince1970: 1_710_000_000)

    private func pkg(
        _ name: String,
        manager: PackageManager = .brew,
        version: String = "1.0.0",
        path: String? = nil
    ) -> Package {
        Package(
            id: "\(manager.rawValue)::\(name)",
            manager: manager,
            qualifier: nil,
            name: name,
            version: version,
            installPath: path.map { URL(fileURLWithPath: $0) },
            installedAt: Self.ref,
            installedAtConfidence: .high,
            sizeBytes: 1_000,
            isExplicit: true,
            isReadOnly: false,
            dependencies: [],
            artifactPaths: nil,
            lastSeen: Self.ref
        )
    }

    private func builder(_ agent: PromptAgent = .claudeCode) -> AgentPromptBuilder {
        AgentPromptBuilder(agent: agent, homeDirectory: Self.home)
    }

    private func assertGuardrails(_ prompt: AgentPrompt) {
        #expect(prompt.body.hasSuffix(AgentPromptBuilder.guardrails))
        #expect(prompt.body.contains("wait for my OK"))
        #expect(prompt.body.contains("sudo"))
        #expect(prompt.body.contains("--break-system-packages"))
        #expect(prompt.body.contains("rm -rf"))
        #expect(prompt.body.contains("undo"))
        #expect(!prompt.body.contains("/Users/tester"))
    }

    // MARK: Single package

    @Test("Removal prompt includes facts, redacts home, and ends with guardrails")
    func removalPrompt() {
        let package = pkg("ripgrep", manager: .cargo, version: "14.1.0", path: "/Users/tester/.cargo/registry/ripgrep")
        let prompt = builder().removalPrompt(
            for: package,
            dependentsCount: 2,
            verdict: RemovalSafetyVerdict(safety: .caution, reasons: ["Depended on by foo, bar"]),
            installedBy: "Claude Code (an AI agent session)"
        )
        #expect(prompt.targetAgent == .claudeCode)
        #expect(prompt.title.contains("ripgrep"))
        #expect(prompt.body.hasPrefix("Hi Claude Code."))
        #expect(prompt.body.contains("Cargo"))
        #expect(prompt.body.contains("14.1.0"))
        #expect(prompt.body.contains("~/.cargo/registry/ripgrep"))
        #expect(prompt.body.contains("depend on it: 2"))
        #expect(prompt.body.contains("remove with care (Depended on by foo, bar)"))
        #expect(prompt.body.contains("Installed by: Claude Code"))
        #expect(prompt.body.contains("Check whether anything I use still needs it"))
        #expect(prompt.body.contains("explain it before running"))
        #expect(prompt.body.count < AgentPromptBuilder.targetMaxCharacters)
        assertGuardrails(prompt)
    }

    @Test("Agent wording changes only the greeting")
    func agentWording() {
        let package = pkg("jq")
        let claude = builder(.claudeCode).removalPrompt(for: package, dependentsCount: 0, verdict: nil)
        let codex = builder(.codex).removalPrompt(for: package, dependentsCount: 0, verdict: nil)
        let generic = builder(.generic).removalPrompt(for: package, dependentsCount: 0, verdict: nil)
        #expect(claude.body.hasPrefix("Hi Claude Code. Please"))
        #expect(codex.body.hasPrefix("Hi Codex. Please"))
        #expect(generic.body.hasPrefix("Please help me decide"))
        #expect(claude.body.replacingOccurrences(of: "Hi Claude Code. ", with: "") == generic.body)
        #expect(!generic.body.contains("Installed by"))
        #expect(!generic.body.contains("safety check"))
    }

    @Test("Installer label never leaks the raw command")
    func installerLabel() {
        #expect(AgentPromptBuilder.installerLabel(from: nil) == nil)
        let evidence = ProvenanceEvidence(
            packageId: "x",
            fsInstallTime: nil,
            fsInstallTimeSource: nil,
            installCommand: .init(timestamp: nil, command: "pip install x --token=abc", shell: .zsh, cwd: nil),
            claudeCodeContext: nil,
            nearbyProjects: [],
            coInstalledWithin1h: [],
            overallConfidence: .medium,
            collectedAt: Self.ref
        )
        let label = AgentPromptBuilder.installerLabel(from: evidence)
        #expect(label == "me, from the terminal")
        #expect(label?.contains("abc") == false)
    }

    // MARK: Duplicates

    @Test("Duplicate prompt names the PATH winner and asks how to consolidate")
    func duplicatePrompt() {
        let brew = pkg("python3", manager: .brew, version: "3.12.1", path: "/opt/homebrew/Cellar/python3/3.12.1")
        let pipx = pkg("python3", manager: .pipx, version: "3.11.0", path: "/Users/tester/.local/pipx/venvs/python3")
        let group = DuplicateGroup(name: "python3", packages: [pipx, brew])
        let prompt = builder(.codex).duplicatePrompt(
            for: group,
            standings: [brew.id: .wins, pipx.id: .shadowed(byPackageId: brew.id)]
        )
        #expect(prompt.body.hasPrefix("Hi Codex. I have python3 installed 2 times"))
        #expect(prompt.body.contains("Homebrew, version 3.12.1, at /opt/homebrew/Cellar/python3/3.12.1 (runs first on my PATH)"))
        #expect(prompt.body.contains("~/.local/pipx/venvs/python3 (hidden behind another copy on my PATH)"))
        #expect(prompt.body.contains("Confirm which copy actually runs"))
        #expect(prompt.body.contains("which -a python3"))
        #expect(prompt.body.contains("Recommend which one to keep"))
        #expect(prompt.body.contains("system Python"))
        #expect(prompt.body.count < AgentPromptBuilder.targetMaxCharacters)
        assertGuardrails(prompt)
    }

    @Test("Duplicate prompt without standings asks the agent to find the winner")
    func duplicatePromptUnknownPath() {
        let group = DuplicateGroup(name: "prettier", packages: [pkg("prettier", manager: .brew), pkg("prettier", manager: .npm)])
        let prompt = builder(.generic).duplicatePrompt(for: group)
        #expect(prompt.body.contains("Find out which copy actually runs"))
        #expect(!prompt.body.contains("runs first on my PATH"))
        #expect(!prompt.body.contains("system Python"))
        assertGuardrails(prompt)
    }

    // MARK: Cleanup list

    @Test("Cleanup prompt lists packages sorted, with verdicts, and summarises overflow")
    func cleanupPrompt() {
        let packages = (1...20).map { pkg(String(format: "tool%02d", $0)) }
        let verdicts = [packages[0].id: RemovalSafetyVerdict(safety: .safe, reasons: [])]
        let prompt = builder().cleanupPrompt(for: packages.reversed(), verdicts: verdicts, maxListed: 5)
        #expect(prompt.title == "Ask about cleaning up 20 packages")
        #expect(prompt.body.contains("clean up 20 packages"))
        #expect(prompt.body.contains("- tool01 (Homebrew 1.0.0) — looks safe to remove"))
        #expect(prompt.body.contains("- tool05"))
        #expect(!prompt.body.contains("- tool06"))
        #expect(prompt.body.contains("…and 15 more"))
        #expect(prompt.body.contains("show me the commands before running them"))
        #expect(prompt.body.count < AgentPromptBuilder.targetMaxCharacters)
        assertGuardrails(prompt)
    }

    @Test("Cleanup prompt uses singular wording for one package")
    func cleanupSingular() {
        let prompt = builder().cleanupPrompt(for: [pkg("jq")])
        #expect(prompt.body.contains("clean up 1 package on my Mac:"))
        assertGuardrails(prompt)
    }

    // MARK: Findings

    @Test("General finding includes explanation and redacted file paths")
    func generalFinding() {
        let finding = PromptFinding(
            title: "MCP server command not found",
            explanation: "The server in /Users/tester/.claude.json points to a missing binary.",
            filePaths: [URL(fileURLWithPath: "/Users/tester/.claude.json")]
        )
        let prompt = builder().findingPrompt(for: finding)
        #expect(prompt.title == "Ask about: MCP server command not found")
        #expect(prompt.body.contains("The server in ~/.claude.json points to a missing binary."))
        #expect(prompt.body.contains("- ~/.claude.json"))
        #expect(prompt.body.count < AgentPromptBuilder.targetMaxCharacters)
        assertGuardrails(prompt)
    }

    @Test("Secret finding asks to rotate and never includes the value")
    func secretFinding() {
        let secretValue = "sk-live-THISISASECRETVALUE1234567890"
        let finding = PromptFinding(
            kind: .exposedSecret(keyName: "OPENAI_API_KEY"),
            title: "Exposed key",
            explanation: "Found OPENAI_API_KEY=\(secretValue) in your shell profile.",
            filePaths: [URL(fileURLWithPath: "/Users/tester/.zshrc")]
        )
        let prompt = builder().findingPrompt(for: finding)
        #expect(!prompt.body.contains(secretValue))
        #expect(!prompt.body.contains("sk-live"))
        #expect(prompt.body.contains("OPENAI_API_KEY"))
        #expect(prompt.body.contains("~/.zshrc"))
        #expect(prompt.body.contains("rotate"))
        #expect(prompt.body.contains("revoke the old one"))
        #expect(prompt.body.contains("Don't print, copy, or paste the key's value"))
        #expect(prompt.body.count < AgentPromptBuilder.targetMaxCharacters)
        assertGuardrails(prompt)
    }

    @Test("Secret key name is sanitised and length-capped")
    func secretKeyNameSanitised() {
        let longJunk = "API_KEY=" + String(repeating: "x", count: 200) + " $(rm)"
        let prompt = builder().findingPrompt(for: PromptFinding(
            kind: .exposedSecret(keyName: longJunk), title: "t", explanation: "", filePaths: []
        ))
        #expect(!prompt.body.contains("="))
        #expect(!prompt.body.contains("$("))
        #expect(!prompt.body.contains(String(repeating: "x", count: 65)))
        let empty = builder().findingPrompt(for: PromptFinding(
            kind: .exposedSecret(keyName: "!!!"), title: "t", explanation: "", filePaths: []
        ))
        #expect(empty.body.contains("(unnamed key)"))
    }

    // MARK: Setup

    @Test("Compact setup prompt lists managers, totals, and duplicates")
    func setupCompact() {
        let packages = [pkg("a"), pkg("b"), pkg("c", manager: .npm), pkg("a", manager: .npm)]
        let groups = packages.crossManagerDuplicates()
        let prompt = builder().setupPrompt(packages: packages, duplicateGroups: groups)
        #expect(prompt.title == "Share my setup")
        #expect(prompt.body.contains("Installed tools (4 total):"))
        #expect(prompt.body.contains("- Homebrew: 2"))
        #expect(prompt.body.contains("- npm (global): 2"))
        #expect(prompt.body.contains("Installed more than once (1):"))
        #expect(prompt.body.contains("- a (Homebrew, npm (global))"))
        assertGuardrails(prompt)
    }

    @Test("Setup prompt from the environment report is redacted and capped")
    func setupFromReport() {
        let packages = (0..<400).map { pkg("package-\($0)", path: "/Users/tester/lib/package-\($0)") }
        var report = EnvironmentReportRenderer().render(
            packages: packages, duplicateGroups: [], orphans: packages, now: Self.ref
        )
        report += "\nPath: /Users/tester/.npm-global\nOther: /Users/testerX/keep"
        let prompt = builder().setupPrompt(environmentReport: report, maxCharacters: 2_000)
        #expect(prompt.body.count <= 2_000)
        #expect(prompt.body.contains("…(trimmed)"))
        #expect(prompt.body.contains("# Installory Environment Report"))
        assertGuardrails(prompt)

        let short = builder().setupPrompt(environmentReport: "Path: /Users/tester/.npm-global\nOther: /Users/testerX/keep", maxCharacters: 2_000)
        #expect(short.body.contains("Path: ~/.npm-global"))
        #expect(short.body.contains("/Users/testerX/keep"))
        #expect(!short.body.contains("trimmed"))
    }

    // MARK: Redactor

    @Test("Home redactor handles exact, nested, sibling and outside paths")
    func redactor() {
        let r = HomePathRedactor(homeDirectory: URL(fileURLWithPath: "/Users/tester/"))
        #expect(r.display(path: "/Users/tester") == "~")
        #expect(r.display(path: "/Users/tester/a/b") == "~/a/b")
        #expect(r.display(path: "/Users/testerX/a") == "/Users/testerX/a")
        #expect(r.display(path: "/opt/homebrew") == "/opt/homebrew")
        #expect(r.redact(text: "see /Users/tester and /Users/tester/x, not /Users/testers")
                == "see ~ and ~/x, not /Users/testers")
    }

    @Test("free text from findings, verdicts and package fields never carries the home path")
    func freeTextIsRedacted() {
        let b = builder()
        let finding = b.findingPrompt(for: PromptFinding(
            title: "Server in /Users/tester/code/app is broken",
            explanation: "See /Users/tester/.claude.json",
            filePaths: []
        ))
        #expect(!finding.title.contains("/Users/tester"))
        #expect(!finding.body.contains("/Users/tester"))
        #expect(finding.title.contains("~/code/app"))

        let package = pkg("/Users/tester/tools/thing", version: "1.0 (/Users/tester/src)")
        let removal = b.removalPrompt(
            for: package,
            dependentsCount: 0,
            verdict: RemovalSafetyVerdict(safety: .caution, reasons: ["Used by /Users/tester/code/app"]),
            installedBy: "script at /Users/tester/bin/setup.sh"
        )
        #expect(!removal.title.contains("/Users/tester"))
        #expect(!removal.body.contains("/Users/tester"))
        #expect(removal.body.contains("~/code/app"))

        let cleanup = b.cleanupPrompt(for: [package])
        #expect(!cleanup.body.contains("/Users/tester"))

        let group = DuplicateGroup(name: "/Users/tester/bin/tool", packages: [package, pkg("tool", manager: .npm)])
        let duplicate = b.duplicatePrompt(for: group)
        #expect(!duplicate.title.contains("/Users/tester"))
        #expect(!duplicate.body.contains("/Users/tester"))
        let setup = b.setupPrompt(packages: [package], duplicateGroups: [group])
        #expect(!setup.body.contains("/Users/tester"))
    }
}
