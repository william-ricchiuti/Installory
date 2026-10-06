import Foundation
import Testing
@testable import InstalloryCore

@Suite("Agent attribution and multi-agent narratives (F5)")
struct AgentAttributionTests {
    private let oldDate = Date(timeIntervalSince1970: 1_723_648_991)

    private func makePackage() -> Package {
        Package(
            id: "npm::typescript",
            manager: .npm,
            qualifier: nil,
            name: "typescript",
            version: "5.4.0",
            installPath: nil,
            installedAt: nil,
            installedAtConfidence: .unknown,
            sizeBytes: nil,
            isExplicit: true,
            isReadOnly: false,
            dependencies: [],
            lastSeen: Date(timeIntervalSince1970: 1_710_000_000)
        )
    }

    private func evidence(
        claude: ProvenanceEvidence.ClaudeCodeContext? = nil,
        codex: ProvenanceEvidence.CodexContext? = nil,
        opencode: ProvenanceEvidence.OpenCodeContext? = nil
    ) -> ProvenanceEvidence {
        ProvenanceEvidence(
            packageId: "npm::typescript",
            fsInstallTime: nil,
            fsInstallTimeSource: nil,
            installCommand: nil,
            claudeCodeContext: claude,
            codexContext: codex,
            opencodeContext: opencode,
            nearbyProjects: [],
            coInstalledWithin1h: [],
            overallConfidence: .medium,
            collectedAt: Date(timeIntervalSince1970: 1_723_700_000)
        )
    }

    private var codexContext: ProvenanceEvidence.CodexContext {
        .init(
            sessionId: "codex-1",
            projectPath: "/Users/will/projects/api",
            sessionSummary: nil,
            firstUserMessage: "add type checking",
            bashInvocation: "npm install -g typescript",
            timestamp: oldDate
        )
    }

    private var opencodeContext: ProvenanceEvidence.OpenCodeContext {
        .init(
            sessionId: "oc-1",
            projectPath: "/Users/will/projects/site",
            sessionSummary: "Set up the TypeScript build",
            firstUserMessage: nil,
            bashInvocation: "npm i -g typescript",
            timestamp: oldDate
        )
    }

    private var claudeContext: ProvenanceEvidence.ClaudeCodeContext {
        .init(
            sessionId: "cc-1",
            projectPath: "/Users/will/projects/app",
            sessionSummary: "Typing the app",
            firstUserMessage: nil,
            bashInvocation: "npm install -g typescript",
            timestamp: oldDate
        )
    }

    @Test("Codex evidence renders a narrative naming Codex")
    func codexNarrative() {
        let text = NarrativeRenderer().render(evidence(codex: codexContext), package: makePackage())
        #expect(text.hasPrefix("Installed "))
        #expect(text.contains("by Codex while working in ~/projects/api."))
        #expect(text.contains("You'd asked: \"add type checking\"."))
    }

    @Test("opencode evidence renders a narrative naming opencode")
    func opencodeNarrative() {
        let text = NarrativeRenderer().render(evidence(opencode: opencodeContext), package: makePackage())
        #expect(text.contains("by opencode while working in ~/projects/site."))
        #expect(text.contains("That session was about: Set up the TypeScript build."))
    }

    @Test("Claude Code narratives name Claude Code")
    func claudeNarrative() {
        let text = NarrativeRenderer().render(evidence(claude: claudeContext), package: makePackage())
        #expect(text.contains("by Claude Code while working in ~/projects/app."))
    }

    @Test("agentAttribution is nil without agent context")
    func noAttribution() {
        #expect(evidence().agentAttribution == nil)
        #expect(evidence().agentAttributions.isEmpty)
    }

    @Test("agentAttribution flattens each agent's context")
    func flattensContexts() throws {
        let codex = try #require(evidence(codex: codexContext).agentAttribution)
        #expect(codex.agent == .codex)
        #expect(codex.agentName == "Codex")
        #expect(codex.sessionId == "codex-1")
        #expect(codex.projectPath == "/Users/will/projects/api")
        #expect(codex.firstUserMessage == "add type checking")
        #expect(codex.sessionSummary == nil)
        #expect(codex.command == "npm install -g typescript")
        #expect(codex.timestamp == oldDate)

        let oc = try #require(evidence(opencode: opencodeContext).agentAttribution)
        #expect(oc.agent == .opencode)
        #expect(oc.agentName == "opencode")
        #expect(oc.sessionSummary == "Set up the TypeScript build")
    }

    @Test("Precedence is Claude Code, then Codex, then opencode")
    func precedence() {
        let all = evidence(claude: claudeContext, codex: codexContext, opencode: opencodeContext)
        #expect(all.agentAttributions.map(\.agent) == [.claudeCode, .codex, .opencode])
        #expect(all.agentAttribution?.agent == .claudeCode)
        #expect(evidence(codex: codexContext, opencode: opencodeContext).agentAttribution?.agent == .codex)
    }
}
