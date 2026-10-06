import Foundation
import Testing
@testable import InstalloryCore

@Suite("AI setup presentation helpers and demo audit")
struct AgentConfigPresentationTests {
    @Test("Demo audit covers several apps and the headline findings")
    func demoAuditShape() {
        let audit = DemoData.agentConfigAudit()
        let clients = Set(audit.servers.map(\.client))
        #expect(clients.isSuperset(of: [.claudeCode, .cursor, .claudeDesktop]))

        let kinds = Set(audit.findings.map(\.kind))
        #expect(kinds.contains(.mcpConflictingDefinitions))
        #expect(kinds.contains(.mcpLiteralSecret))
        #expect(kinds.contains(.agentsMdNotReadByClaude))
        #expect(kinds.contains(.hooksConfigured))
        #expect(kinds.contains(.broadAllowRule))
        // No program is reported missing in the demo.
        #expect(!kinds.contains(.mcpCommandNotFound))

        // Sorted most severe first.
        let severities = audit.findings.map(\.severity.rawValue)
        #expect(severities == severities.sorted(by: >))
        #expect(audit.findings.first?.severity == .critical)

        #expect(audit.permissionProfiles.contains { !$0.hooks.isEmpty })
        #expect(audit.permissionProfiles.contains { $0.allow.count >= 3 })
    }

    @Test("Literal secrets are counted per key and named without values")
    func literalSecrets() throws {
        let audit = DemoData.agentConfigAudit()
        #expect(audit.literalSecretCount == 1)
        let secretFinding = try #require(audit.findings.first { $0.isLiteralSecret })
        #expect(audit.secretKeyName(for: secretFinding) == "GITHUB_PERSONAL_ACCESS_TOKEN")
        let other = try #require(audit.findings.first { !$0.isLiteralSecret })
        #expect(audit.secretKeyName(for: other) == nil)
    }

    @Test("Settings secrets resolve their key name from the matching profile")
    func settingsSecretKeyName() {
        let file = URL(fileURLWithPath: "/Users/x/.claude/settings.json")
        let profile = PermissionProfile(
            tool: .claudeCode,
            scope: .user,
            configFile: file,
            maskedEnv: [
                MaskedValue(key: "PATH_EXTRA", maskedValue: "/opt\u{2026}", isLiteralSecret: false),
                MaskedValue(key: "OPENAI_API_KEY", maskedValue: "sk-p\u{2026}", isLiteralSecret: true),
            ]
        )
        let finding = AgentConfigFinding(
            id: "settingsLiteralSecret:\(file.path)",
            kind: .settingsLiteralSecret,
            category: .permissions,
            severity: .critical,
            title: "t",
            explanation: "e",
            affectedFiles: [file]
        )
        let audit = AgentConfigAudit(
            servers: [],
            instructionFiles: [],
            permissionProfiles: [profile],
            findings: [finding],
            unreadableFiles: []
        )
        #expect(audit.secretKeyName(for: finding) == "OPENAI_API_KEY")
        #expect(audit.literalSecretCount == 1)
    }

    @Test("Broad allow rules and hook triggers read in plain English")
    func permissionWording() {
        let profile = PermissionProfile(
            tool: .claudeCode,
            scope: .user,
            configFile: URL(fileURLWithPath: "/tmp/settings.json"),
            allow: ["Bash(npm run test:*)", "Bash(rm:*)", "WebFetch"]
        )
        #expect(profile.broadAllowRules == ["Bash(rm:*)", "WebFetch"])
        #expect(PermissionProfile.broadAllowRuleExplanation("Bash(git status)") == nil)
        #expect(AgentHook(event: "PostToolUse", matcher: nil, commands: []).triggerDescription
            == "After the agent uses a tool")
        #expect(AgentHook(event: "CustomEvent", matcher: nil, commands: []).triggerDescription == "CustomEvent")
    }

    @Test("AI Setup selection round-trips and skips row filtering")
    func aiSetupSelection() {
        #expect(SidebarSelection.aiSetup.userDefaultsKey == "aiSetup")
        #expect(SidebarSelection(userDefaultsKey: "aiSetup") == .aiSetup)
        #expect([Package]().filtered(by: .aiSetup, query: "").isEmpty)
    }
}
