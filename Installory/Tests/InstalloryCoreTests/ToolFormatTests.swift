import Foundation
import Testing
@testable import InstalloryCore

/// Tool formats that changed in 2026 (review findings CFG-1, CFG-2, CL-6, CL-10).
/// Fixtures copy the current shapes (structure only, synthetic values).
@Suite("Current AI tool formats")
struct ToolFormatTests {
    private let home = AgentConfigFixture.home
    private let project = AgentConfigFixture.project

    private func json(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - CFG-1: AGENTS.md

    @Test("CLAUDE.md that doesn't import AGENTS.md still gets a finding, with current wording")
    func agentsWithClaudeMdWording() throws {
        let result = AgentConfigFixture.audit(provider: InMemoryDirectoryAccessProvider.make { b in
            b.addFile(at: project.appendingPathComponent("AGENTS.md"), data: json("rules"))
            b.addFile(at: project.appendingPathComponent("CLAUDE.md"), data: json("# Project"))
        })
        let finding = try #require(result.findings.first { $0.kind == .agentsMdNotReadByClaude })
        #expect(finding.explanation.contains("only when a project has no CLAUDE.md"))
        #expect(!finding.explanation.contains("Claude Code only reads CLAUDE.md"))
    }

    // MARK: - CFG-2: opencode V2

    @Test("opencode V2 servers under mcp.servers are read; the old layout still works")
    func opencodeServers() {
        let v2 = AgentConfigFixture.audit(provider: InMemoryDirectoryAccessProvider.make { b in
            b.addFile(at: home.appendingPathComponent(".config/opencode/opencode.json"), data: json("""
            {"$schema": "https://opencode.ai/config.json",
             "mcp": {"timeout": 5000,
                     "servers": {"my-server": {"type": "local", "command": ["npx", "-y", "example-mcp-server"]},
                                 "remote-one": {"type": "remote", "url": "https://mcp.example.com/mcp"}}}}
            """))
        })
        let names = v2.servers.filter { $0.client == .opencode }.map(\.name).sorted()
        #expect(names == ["my-server", "remote-one"], "got \(names)")

        let legacy = AgentConfigFixture.audit(provider: InMemoryDirectoryAccessProvider.make { b in
            b.addFile(at: project.appendingPathComponent("opencode.json"), data: json("""
            {"mcp": {"old-server": {"type": "local", "command": ["node", "server.js"]}}}
            """))
        })
        #expect(legacy.servers.filter { $0.client == .opencode }.map(\.name) == ["old-server"])
    }

    // MARK: - CL-6: Codex

    private func codexProvider(_ files: [(String, String)]) -> InMemoryDirectoryAccessProvider {
        InMemoryDirectoryAccessProvider.make { b in
            for (path, text) in files {
                b.addFile(at: URL(fileURLWithPath: "/fake-home/.codex/\(path)"), data: Data(text.utf8))
            }
        }
    }

    @Test("current Codex exec tool calls are read")
    func codexCustomToolCallExec() {
        let jsonl = #"""
        {"timestamp":"2026-11-10T06:18:30.087Z","type":"session_meta","payload":{"id":"s-new","cwd":"/Users/will/projects/api"}}
        {"timestamp":"2026-11-10T06:19:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","status":"completed","call_id":"c1","input":"text(await tools.exec_command({cmd:\"cd /tmp && brew install wget\",max_output_tokens:24000}));\ntext(await tools.exec_command({cmd:'npm install -g typescript',yield_time_ms:1000}));\n"}}
        """#
        let records = CodexLogCollector(
            directoryAccess: codexProvider([("sessions/2026/11/10/rollout-2026-11-10T06-18-30-019ca80c-5804-7491-834e-237de100eb49.jsonl", jsonl)]),
            homeDirectory: URL(fileURLWithPath: "/fake-home")
        ).collect()
        let found = Set(records.map { "\($0.manager.rawValue):\($0.packageName)" })
        #expect(found == ["brew:wget", "npm:typescript"], "got \(found)")
        #expect(records.first { $0.packageName == "wget" }?.context.bashInvocation == "cd /tmp && brew install wget")
        #expect(records.allSatisfy { $0.context.sessionId == "s-new" })
    }

    @Test("older Codex shell calls with a command array are read")
    func codexShellCommandArray() {
        let jsonl = #"""
        {"timestamp":"2025-06-01T06:19:00.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"pipx install black\"]}"}}
        {"timestamp":"2025-06-01T06:20:00.000Z","type":"response_item","payload":{"type":"local_shell_call","status":"completed","action":{"type":"exec","command":["cargo","install","ripgrep"]}}}
        """#
        let records = CodexLogCollector(
            directoryAccess: codexProvider([("sessions/2025/06/01/rollout-2025-06-01T06-19-00-019ca80c-5804-7491-834e-237de100eb40.jsonl", jsonl)]),
            homeDirectory: URL(fileURLWithPath: "/fake-home")
        ).collect()
        let found = Set(records.map { "\($0.manager.rawValue):\($0.packageName)" })
        #expect(found == ["pipx:black", "cargo:ripgrep"], "got \(found)")
    }

    @Test("archived Codex sessions are read too")
    func codexArchivedSessions() {
        let jsonl = #"""
        {"timestamp":"2026-01-02T06:19:00.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"brew install jq\"}"}}
        """#
        let records = CodexLogCollector(
            directoryAccess: codexProvider([("archived_sessions/rollout-2026-01-02T06-19-00-019ca80c-5804-7491-834e-237de100eb41.jsonl", jsonl)]),
            homeDirectory: URL(fileURLWithPath: "/fake-home")
        ).collect()
        #expect(records.map(\.packageName) == ["jq"])
    }

    @Test("commands that aren't string literals are ignored, nothing is executed")
    func codexNonLiteralCommandsIgnored() {
        let jsonl = #"""
        {"timestamp":"2026-11-10T06:19:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const c = 'brew install evil'; text(await tools.exec_command({cmd: c}));"}}
        """#
        let records = CodexLogCollector(
            directoryAccess: codexProvider([("sessions/2026/11/10/rollout-2026-11-10T06-19-00-019ca80c-5804-7491-834e-237de100eb42.jsonl", jsonl)]),
            homeDirectory: URL(fileURLWithPath: "/fake-home")
        ).collect()
        #expect(records.isEmpty)
    }

    // MARK: - CL-10: Claude Code subagents

    @Test("Claude Code subagent transcripts are read")
    func claudeSubagents() {
        let projectDir = URL(fileURLWithPath: "/fake-home/.claude/projects/-Users-will-projects-app")
        let main = #"{"sessionId":"main-1","timestamp":"2026-11-01T10:00:00.000Z","cwd":"/Users/will/projects/app","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"brew install wget"}}]}}"#
        let sub = #"{"sessionId":"main-1","isSidechain":true,"timestamp":"2026-11-01T10:05:00.000Z","cwd":"/Users/will/projects/app","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"npm install -g eslint"}}]}}"#
        let provider = InMemoryDirectoryAccessProvider.make { b in
            b.addFile(at: projectDir.appendingPathComponent("main-1.jsonl"), data: Data(main.utf8))
            b.addFile(at: projectDir.appendingPathComponent("6a5d6ccf-3620-464c-a381-45adafc7fc20/subagents/agent-a968c9d89df0d154c.jsonl"), data: Data(sub.utf8))
            b.addFile(at: projectDir.appendingPathComponent("6a5d6ccf-3620-464c-a381-45adafc7fc20/subagents/agent-a968c9d89df0d154c.meta.json"), data: Data("{}".utf8))
        }
        let records = ClaudeCodeLogCollector(directoryAccess: provider, homeDirectory: URL(fileURLWithPath: "/fake-home")).collect()
        let names = Set(records.map(\.packageName))
        #expect(names == ["wget", "eslint"], "got \(names)")
    }
}
