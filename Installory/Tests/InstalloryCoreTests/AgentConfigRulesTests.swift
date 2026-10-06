import Foundation
import Testing
@testable import InstalloryCore

@Suite("AgentConfigAuditor – instruction files")
struct AgentConfigInstructionTests {
    private typealias F = AgentConfigFixture
    private let project = AgentConfigFixture.project

    private func audit(_ populate: (inout InMemoryDirectoryAccessProvider.Builder) -> Void) -> AgentConfigAudit {
        F.audit(provider: InMemoryDirectoryAccessProvider.make(populate), binaries: [])
    }

    private func text(_ value: String) -> Data { Data(value.utf8) }

    @Test("discovers global and project instruction files with sizes, lines and imports")
    func discoversFiles() throws {
        let result = audit { builder in
            builder.addFile(at: F.home.appendingPathComponent(".claude/CLAUDE.md"), data: text("# Me\n@~/.agents/AGENTS.md\n"))
            builder.addFile(at: F.home.appendingPathComponent(".codex/AGENTS.md"), data: text("codex"))
            builder.addFile(at: F.home.appendingPathComponent(".config/opencode/AGENTS.md"), data: text("oc"))
            builder.addFile(at: F.home.appendingPathComponent(".gemini/GEMINI.md"), data: text("gem"))
            builder.addFile(at: project.appendingPathComponent("CLAUDE.md"), data: text("line one\nsee @docs/style.md and `@not/an/import.md`\n```\n@also/not.md\n```\nmail me@example.com or ping @alice\n"))
            builder.addFile(at: project.appendingPathComponent("CLAUDE.local.md"), data: text("local"))
            builder.addFile(at: project.appendingPathComponent(".claude/CLAUDE.md"), data: text("nested"))
            builder.addFile(at: project.appendingPathComponent("GEMINI.md"), data: text("g"))
            builder.addFile(at: project.appendingPathComponent(".github/copilot-instructions.md"), data: text("c"))
            builder.addFile(at: project.appendingPathComponent(".windsurfrules"), data: text("w"))
            builder.addFile(at: project.appendingPathComponent(".cursor/rules/style.mdc"), data: text("---\ndescription: x\n---\nrule"))
            builder.addFile(at: project.appendingPathComponent(".cursor/rules/notes.md"), data: text("note"))
            builder.addFile(at: project.appendingPathComponent(".cursor/rules/image.png"), data: text("png"))
        }
        let files = result.instructionFiles
        #expect(files.count == 12)
        let projectClaude = try #require(files.first { $0.path.path == "/Users/tester/code/app/CLAUDE.md" })
        #expect(projectClaude.kind == .claudeMd)
        #expect(projectClaude.tool == .claudeCode)
        #expect(projectClaude.scope == .project(project))
        #expect(projectClaude.lineCount == 6)
        #expect(projectClaude.imports == ["docs/style.md"])
        #expect(projectClaude.byteSize == Int64(projectClaude.characterCount ?? 0))
        #expect(!projectClaude.isSymlink)

        let global = try #require(files.first { $0.path.path == "/Users/tester/.claude/CLAUDE.md" })
        #expect(global.scope == .user)
        #expect(global.imports == ["~/.agents/AGENTS.md"])

        #expect(files.filter { $0.kind == .cursorRule }.map(\.path.lastPathComponent) == ["notes.md", "style.mdc"])
        #expect(files.contains { $0.tool == .codex && $0.kind == .agentsMd })
        #expect(files.contains { $0.tool == .opencode && $0.kind == .agentsMd })
        #expect(files.contains { $0.tool == .gemini && $0.scope == .user })
        #expect(files.contains { $0.kind == .copilotInstructions })
        #expect(files.contains { $0.kind == .windsurfRules })
    }

    @Test("AGENTS.md with no CLAUDE.md → info telling the user to create one")
    func agentsWithoutClaude() throws {
        let result = audit { builder in
            builder.addFile(at: project.appendingPathComponent("AGENTS.md"), data: text("rules"))
        }
        let finding = try #require(result.findings.first { $0.kind == .agentsMdNotReadByClaude })
        #expect(finding.severity == .info)
        #expect(finding.title == "Claude Code doesn't read this project's AGENTS.md")
        #expect(finding.suggestedFix == "Create a file named CLAUDE.md next to AGENTS.md containing the single line `@AGENTS.md`.")
    }

    @Test("AGENTS.md with a CLAUDE.md that doesn't import it → info with the exact line to add")
    func agentsWithUnrelatedClaude() throws {
        let result = audit { builder in
            builder.addFile(at: project.appendingPathComponent("AGENTS.md"), data: text("rules"))
            builder.addFile(at: project.appendingPathComponent("CLAUDE.md"), data: text("# Project\nNothing imported."))
        }
        let finding = try #require(result.findings.first { $0.kind == .agentsMdNotReadByClaude })
        #expect(finding.suggestedFix == "Add a line `@AGENTS.md` to CLAUDE.md. Claude Code will then load AGENTS.md too.")
        #expect(finding.affectedFiles.map(\.lastPathComponent) == ["AGENTS.md", "CLAUDE.md"])
    }

    @Test("no AGENTS.md finding when CLAUDE.md imports it, or is a symlink to it")
    func agentsCovered() {
        let imported = audit { builder in
            builder.addFile(at: project.appendingPathComponent("AGENTS.md"), data: text("rules"))
            builder.addFile(at: project.appendingPathComponent("CLAUDE.md"), data: text("Read these:\n@./AGENTS.md\n"))
        }
        #expect(!imported.findings.contains { $0.kind == .agentsMdNotReadByClaude })

        let nestedImport = audit { builder in
            builder.addFile(at: project.appendingPathComponent("AGENTS.md"), data: text("rules"))
            builder.addFile(at: project.appendingPathComponent(".claude/CLAUDE.md"), data: text("@../AGENTS.md"))
        }
        #expect(!nestedImport.findings.contains { $0.kind == .agentsMdNotReadByClaude })

        let linked = audit { builder in
            builder.addFile(at: project.appendingPathComponent("AGENTS.md"), data: text("rules"))
            builder.addSymlink(at: project.appendingPathComponent("CLAUDE.md"), target: project.appendingPathComponent("AGENTS.md"))
        }
        #expect(!linked.findings.contains { $0.kind == .agentsMdNotReadByClaude })
        let claude = linked.instructionFiles.first { $0.kind == .claudeMd }
        #expect(claude?.isSymlink == true)
        #expect(claude?.symlinkTarget?.lastPathComponent == "AGENTS.md")
        #expect(claude?.characterCount == 5)

        let reverse = audit { builder in
            builder.addFile(at: project.appendingPathComponent("CLAUDE.md"), data: text("rules"))
            builder.addSymlink(at: project.appendingPathComponent("AGENTS.md"), target: project.appendingPathComponent("CLAUDE.md"))
        }
        #expect(!reverse.findings.contains { $0.kind == .agentsMdNotReadByClaude })
    }

    @Test("very large instruction file → warning about context cost")
    func largeFile() throws {
        let big = String(repeating: "Follow the rule. ", count: 3_000) // 51,000 characters
        let result = audit { builder in
            builder.addFile(at: project.appendingPathComponent("CLAUDE.md"), data: text(big))
            builder.addFile(at: project.appendingPathComponent("GEMINI.md"), data: text("short"))
            builder.addFile(at: project.appendingPathComponent(".windsurfrules"), data: text("x"), logicalSizeBytes: 5 * 1_048_576)
        }
        let large = result.findings.filter { $0.kind == .instructionFileTooLarge }
        #expect(Set(large.flatMap(\.affectedFiles).map(\.lastPathComponent)) == ["CLAUDE.md", ".windsurfrules"])
        let claude = try #require(large.first { $0.affectedFiles.first?.lastPathComponent == "CLAUDE.md" })
        #expect(claude.severity == .warning)
        #expect(claude.title == "CLAUDE.md is very large (51,000 characters)")
        #expect(claude.explanation.contains("loaded into every conversation"))
        // The oversize file is listed as unreadable but does not produce a config-file warning.
        #expect(result.unreadableFiles.contains { $0.reason == .tooLarge && $0.path.lastPathComponent == ".windsurfrules" })
        #expect(!result.findings.contains { $0.kind == .configFileUnreadable })
    }

    @Test("legacy .cursorrules → info; broken symlink → warning")
    func legacyAndBroken() throws {
        let result = audit { builder in
            builder.addFile(at: project.appendingPathComponent(".cursorrules"), data: text("rules"))
            builder.addSymlink(at: project.appendingPathComponent("AGENTS.md"), target: URL(fileURLWithPath: "/Users/tester/shared/gone.md"))
        }
        let legacy = try #require(result.findings.first { $0.kind == .legacyCursorRules })
        #expect(legacy.severity == .info)
        #expect(legacy.suggestedFix?.contains(".cursor/rules") == true)

        let broken = try #require(result.findings.first { $0.kind == .brokenInstructionSymlink })
        #expect(broken.severity == .warning)
        #expect(broken.explanation.contains("~/shared/gone.md"))
        let file = try #require(result.instructionFiles.first { $0.kind == .agentsMd })
        #expect(file.isBrokenSymlink)
        #expect(file.byteSize == nil)
        // A broken AGENTS.md does not also trigger the "Claude doesn't read it" tip.
        #expect(!result.findings.contains { $0.kind == .agentsMdNotReadByClaude })
    }
}

@Suite("AgentConfigAuditor – permissions")
struct AgentConfigPermissionTests {
    private typealias F = AgentConfigFixture

    @Test("parses Claude Code settings at user, project and local scope plus Codex")
    func parsesProfiles() throws {
        let audit = F.audit(provider: try F.fullProvider())
        let profiles = audit.permissionProfiles
        #expect(profiles.count == 4)

        let project = try #require(profiles.first { $0.scope.kind == .project })
        #expect(project.defaultMode == "bypassPermissions")
        #expect(project.allow.count == 6)
        #expect(project.deny == ["Read(./.env)"])
        #expect(project.enableAllProjectMcpServers == true)
        #expect(project.maskedEnv == [
            MaskedValue(key: "NODE_ENV", maskedValue: "deve…", isLiteralSecret: false),
            MaskedValue(key: "STRIPE_SECRET_KEY", maskedValue: "sk_l…", isLiteralSecret: true),
        ])
        #expect(project.hooks.count == 2)
        let post = try #require(project.hooks.first { $0.event == "PostToolUse" })
        #expect(post.matcher == "Edit|Write")
        #expect(post.commands == [#"npx prettier --write "$CLAUDE_FILE_PATHS""#])
        let stop = try #require(project.hooks.first { $0.event == "Stop" })
        #expect(stop.matcher == nil)
        #expect(stop.commands.first?.contains("https://hooks.example.com/notify?token=••••") == true)

        let local = try #require(profiles.first { $0.scope.kind == .local })
        #expect(local.allow.count == 3)

        let user = try #require(profiles.first { $0.scope == .user && $0.tool == .claudeCode })
        #expect(user.defaultMode == "acceptEdits")
        #expect(user.skipDangerousModePermissionPrompt == true)

        let codex = try #require(profiles.first { $0.tool == .codex })
        #expect(codex.approvalPolicy == "never")
        #expect(codex.sandboxMode == "danger-full-access")
    }

    @Test("bypassPermissions and Codex never + full access are critical")
    func criticalModes() throws {
        let audit = F.audit(provider: try F.fullProvider())
        let bypass = try #require(audit.findings.first { $0.kind == .bypassPermissions })
        #expect(bypass.severity == .critical)
        #expect(bypass.title == "Your agent can run any command without asking")
        let codex = try #require(audit.findings.first { $0.kind == .codexFullAccess })
        #expect(codex.severity == .critical)
        #expect(codex.title == "Your agent can run any command without asking")
        let skip = try #require(audit.findings.first { $0.kind == .dangerousModePromptSkipped })
        #expect(skip.severity == .warning)
    }

    @Test("Codex danger-full-access with approvals on is a warning")
    func codexSandboxOnly() throws {
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            builder.addFile(
                at: F.home.appendingPathComponent(".codex/config.toml"),
                data: Data("approval_policy = \"on-request\"\nsandbox_mode = \"danger-full-access\"\n".utf8)
            )
        }
        let audit = F.audit(provider: provider, projects: [])
        let finding = try #require(audit.findings.first { $0.kind == .codexFullAccess })
        #expect(finding.severity == .warning)
    }

    @Test("broad allow rules are warnings with plain-English explanations; narrow ones are ignored")
    func broadRules() throws {
        let audit = F.audit(provider: try F.fullProvider())
        let broad = audit.findings.filter { $0.kind == .broadAllowRule }
        #expect(Set(broad.map(\.title)) == [
            "Broad permission: Bash",
            "Broad permission: Bash(rm:*)",
            "Broad permission: WebFetch",
            "Broad permission: Bash(curl *)",
            "Broad permission: Bash(sudo:*)",
        ])
        #expect(broad.allSatisfy { $0.severity == .warning })
        let rm = try #require(broad.first { $0.title.hasSuffix("Bash(rm:*)") })
        #expect(rm.explanation.contains("delete any file"))
    }

    @Test("repeated permission rules are de-duplicated in order, so finding ids stay unique")
    func duplicateRules() throws {
        let json = """
        {"permissions": {"allow": ["Bash", "Read", "Bash", "WebFetch", "Read"],
                         "deny": ["Read(./.env)", "Read(./.env)"]},
         "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"},
                                       {"type": "command", "command": "say done"}]}]}}
        """
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            builder.addFile(at: F.home.appendingPathComponent(".claude/settings.json"), data: Data(json.utf8))
        }
        let audit = F.audit(provider: provider, projects: [])
        let profile = try #require(audit.permissionProfiles.first { $0.tool == .claudeCode })
        #expect(profile.allow == ["Bash", "Read", "WebFetch"])
        #expect(profile.deny == ["Read(./.env)"])
        #expect(profile.hooks.first?.commands == ["say done"])
        let ids = audit.findings.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(audit.findings.filter { $0.kind == .broadAllowRule }.count == 2)
    }

    @Test("broad-rule classifier")
    func classifier() {
        let broad = ["Bash", "Bash(*)", "Bash(:*)", "Bash(rm:*)", "Bash(rm *)", "Bash(sudo:*)", "Bash(curl:*)",
                     "WebFetch", "WebFetch(*)", "Bash(python3:*)", "Bash(git push:*)"]
        let narrow = ["Bash(npm run test:*)", "Bash(rm build/tmp.txt)", "WebFetch(domain:example.com)",
                      "Read(~/notes/**)", "Edit", "Bash(git status:*)"]
        for rule in broad { #expect(AgentConfigFindingRules.broadRuleExplanation(rule) != nil, "\(rule)") }
        for rule in narrow { #expect(AgentConfigFindingRules.broadRuleExplanation(rule) == nil, "\(rule)") }
    }

    @Test("remembered approvals, hooks, enableAllProjectMcpServers and env secrets")
    func otherPermissionFindings() throws {
        let audit = F.audit(provider: try F.fullProvider())
        let remembered = try #require(audit.findings.first { $0.kind == .rememberedApprovals })
        #expect(remembered.title == "3 commands you approved with “don't ask again”")
        #expect(remembered.severity == .info)

        let hooks = try #require(audit.findings.first { $0.kind == .hooksConfigured })
        #expect(hooks.severity == .info)
        #expect(hooks.title == "2 commands run automatically")
        #expect(hooks.explanation.contains("After the agent uses a tool (Edit|Write): npx prettier"))
        #expect(!hooks.explanation.contains("FAKEHOOKTOKEN"))

        let all = try #require(audit.findings.first { $0.kind == .allProjectMcpServersEnabled })
        #expect(all.severity == .warning)

        let secret = try #require(audit.findings.first { $0.kind == .settingsLiteralSecret })
        #expect(secret.severity == .critical)
        #expect(secret.explanation.contains("STRIPE_SECRET_KEY = sk_l…"))
    }
}
