import Foundation
import Testing
@testable import InstalloryCore

@Suite("AgentConfig – TOML subset parser")
struct AgentConfigTOMLTests {
    @Test("tables, dotted headers, quoted keys and inline tables")
    func tables() {
        let toml = """
        top = "level"
        [a.b]
        c = 1
        d.e = true
        [a."quoted key"]
        x = { y = "z", n = { deep = 2 } }
        ['literal key']
        v = 'raw \\n stays'
        """
        let root = MiniTOMLParser.parse(toml).root
        #expect(root["top"] == .string("level"))
        let b = root["a"]?.tableValue?["b"]?.tableValue
        #expect(b?["c"] == .integer(1))
        #expect(b?["d"]?.tableValue?["e"] == .bool(true))
        let quoted = root["a"]?.tableValue?["quoted key"]?.tableValue?["x"]?.tableValue
        #expect(quoted?["y"] == .string("z"))
        #expect(quoted?["n"]?.tableValue?["deep"] == .integer(2))
        #expect(root["literal key"]?.tableValue?["v"] == .string(#"raw \n stays"#))
    }

    @Test("string escapes and multi-line strings")
    func strings() {
        let toml = #"""
        basic = "tab\tquote\"backslash\\unicode\u00e9"
        multi = """
        line one
        line "two"\
           continued"""
        literal = '''
        C:\path\no-escapes'''
        quotes = """she said ""hi"""""
        """#
        let root = MiniTOMLParser.parse(toml).root
        #expect(root["basic"] == .string("tab\tquote\"backslash\\unicodeé"))
        #expect(root["multi"] == .string("line one\nline \"two\"continued"))
        #expect(root["literal"] == .string(#"C:\path\no-escapes"#))
        #expect(root["quotes"] == .string(#"she said ""hi"""#))
    }

    @Test("arrays, numbers, comments and arrays of tables")
    func arraysAndNumbers() {
        let toml = """
        # comment
        list = [ "a", # inline comment
          "b",
        ]
        nested = [[1, 2], ["x"]]
        hex = 0xFF
        big = 1_000
        pi = 3.14
        when = 2024-01-01T00:00:00Z
        [[servers]]
        name = "one"
        [[servers]]
        name = "two"
        [servers.env]
        K = "v"
        """
        let result = MiniTOMLParser.parse(toml)
        #expect(result.issues == 0)
        let root = result.root
        #expect(root["list"] == .array([.string("a"), .string("b")]))
        #expect(root["nested"] == .array([.array([.integer(1), .integer(2)]), .array([.string("x")])]))
        #expect(root["hex"] == .integer(255))
        #expect(root["big"] == .integer(1000))
        #expect(root["pi"] == .double(3.14))
        #expect(root["when"] == .other("2024-01-01T00:00:00Z"))
        let servers = root["servers"]?.arrayValue
        #expect(servers?.count == 2)
        #expect(servers?.first?.tableValue?["name"] == .string("one"))
        #expect(servers?.last?.tableValue?["name"] == .string("two"))
        #expect(servers?.last?.tableValue?["env"]?.tableValue?["K"] == .string("v"))
    }

    @Test("garbage lines are skipped without losing the rest")
    func forgiving() {
        let toml = """
        good = 1
        this is not toml
        [broken
        also_good = "yes"
        unterminated = "oops
        [mcp_servers.x]
        command = "npx"
        """
        let result = MiniTOMLParser.parse(toml)
        #expect(result.issues == 3)
        #expect(result.root["good"] == .integer(1))
        #expect(result.root["also_good"] == .string("yes"))
        #expect(result.root["mcp_servers"]?.tableValue?["x"]?.tableValue?["command"] == .string("npx"))
    }
}

@Suite("AgentConfig – secret masking")
struct AgentConfigSecretMaskerTests {
    @Test("masking rule")
    func maskRule() {
        #expect(AgentConfigSecretMasker.mask("") == "")
        #expect(AgentConfigSecretMasker.mask("abc") == "••••")
        #expect(AgentConfigSecretMasker.mask("1234567") == "••••")
        #expect(AgentConfigSecretMasker.mask("12345678") == "1234…")
        #expect(AgentConfigSecretMasker.mask("sk-ant-api03-very-long") == "sk-a…")
    }

    @Test("references are not secrets and are kept verbatim")
    func references() {
        for value in ["${TOKEN}", "$TOKEN", "{env:TOKEN}", "${env:TOKEN}", "${input:key}", "Bearer ${TOKEN}", "{file:~/.secrets/x}"] {
            let pair = AgentConfigSecretMasker.maskedPair(key: "API_TOKEN", value: value)
            #expect(pair.maskedValue == value)
            #expect(!pair.isLiteralSecret)
        }
        let literal = AgentConfigSecretMasker.maskedPair(key: "Authorization", value: "Bearer abcdefghijkl")
        #expect(literal.isLiteralSecret)
        #expect(literal.maskedValue == "Bear…")
    }

    @Test("key names and token formats decide what counts as a secret")
    func secretDetection() {
        #expect(AgentConfigSecretMasker.maskedPair(key: "OPENAI_API_KEY", value: "x").isLiteralSecret)
        #expect(AgentConfigSecretMasker.maskedPair(key: "db_password", value: "pw").isLiteralSecret)
        #expect(AgentConfigSecretMasker.maskedPair(key: "X-Auth", value: "value").isLiteralSecret)
        #expect(!AgentConfigSecretMasker.maskedPair(key: "API_KEY", value: "").isLiteralSecret)
        #expect(!AgentConfigSecretMasker.maskedPair(key: "LOG_LEVEL", value: "debug").isLiteralSecret)
        // A recognizable token under an innocent key is still a secret.
        #expect(AgentConfigSecretMasker.maskedPair(key: "CONFIG", value: "ghp_abcdefghijklmnopqrstuvwxyz").isLiteralSecret)
    }

    @Test("argument masking")
    func arguments() {
        let (args, found) = AgentConfigSecretMasker.maskArguments([
            "--api-key", "abcdefghijk",
            "--token=zyxwvutsrqp",
            "--token", "${TOKEN}",
            "-e", "GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxxxx",
            "https://user:pw@example.com/path?key=1",
            "sk-proj-abcdefghijklmnopqrstu",
            "--verbose", "plain",
        ])
        #expect(found)
        #expect(args == [
            "--api-key", "abcd…",
            "--token=zyxw…",
            "--token", "${TOKEN}",
            "-e", "GITHUB_TOKEN=ghp_…",
            "https://example.com/…?…",
            "sk-p…",
            "--verbose", "plain",
        ])
        let clean = AgentConfigSecretMasker.maskArguments(["-y", "@modelcontextprotocol/server-github"])
        #expect(!clean.foundSecret)
        #expect(clean.args == ["-y", "@modelcontextprotocol/server-github"])
    }

    @Test("free-form command redaction")
    func commands() {
        let redacted = AgentConfigSecretMasker.redactCommand(
            "API_KEY=abc123 curl -H 'Authorization: Bearer tok_abcdef' https://u:p@x.io/?token=qq --password hunter2"
        )
        #expect(!redacted.contains("abc123"))
        #expect(!redacted.contains("tok_abcdef"))
        #expect(!redacted.contains("u:p@"))
        #expect(!redacted.contains("token=qq"))
        #expect(!redacted.contains("hunter2"))
        #expect(redacted.contains("curl"))
    }

    @Test("a value that merely contains a reference is still a literal secret")
    func partialReferencesAreLiteral() {
        for value in ["hunter2pa$word", "mypassword${X}", "Basic dXNlcjpwYXNz$x", "abc{env:X}def", "${A}secret"] {
            #expect(!AgentConfigSecretMasker.isReference(value), "\(value) treated as a reference")
            let pair = AgentConfigSecretMasker.maskedPair(key: "DB_PASSWORD", value: value)
            #expect(pair.isLiteralSecret)
            #expect(pair.maskedValue != value)
        }
        // Pure references, with or without a scheme or separators, stay verbatim.
        for value in ["${A}", "$A", "Bearer ${A}", "basic $A", "Token {env:A}", "${USER}:${PASS}", " ${input:x} "] {
            #expect(AgentConfigSecretMasker.isReference(value), "\(value) not treated as a reference")
        }
        #expect(!AgentConfigSecretMasker.isReference("Bearer"))
        // Argument paths use the same rule.
        let args = AgentConfigSecretMasker.maskArguments(["--token", "mypassword${X}", "--api-key=hunter2pa$word"])
        #expect(args.foundSecret)
        #expect(args.args == ["--token", "mypa…", "--api-key=hunt…"])
    }

    @Test("credential-carrying flags are masked even without a secret-looking name")
    func credentialFlags() {
        let (args, found) = AgentConfigSecretMasker.maskArguments([
            "-H", "Authorization: Bearer abcdefghijklmnop",
            "--header", "X-Api-Key: plainvalue123",
            "--header=Cookie: session=abcdef123",
            "-H", "Content-Type: application/json",
            "-H", "Authorization: Bearer ${TOKEN}",
            "-u", "alice:s3cretpass",
            "--user=bob:hunter22",
            "--password", "hunter2hunter2",
            "-p", "letmein99",
        ])
        #expect(found)
        #expect(args == [
            "-H", "Authorization: Bearer ••••",
            "--header", "X-Api-Key: plai…",
            "--header=Cookie: sess…",
            "-H", "Content-Type: application/json",
            "-H", "Authorization: Bearer ${TOKEN}",
            "-u", "alice:••••",
            "--user=bob:••••",
            "--password", "hunt…",
            "-p", "letm…",
        ])
        let joined = args.joined(separator: " ")
        for secret in ["abcdefghijklmnop", "plainvalue123", "abcdef123", "s3cretpass", "hunter22", "hunter2hunter2", "letmein99"] {
            #expect(!joined.contains(secret), "leaked \(secret)")
        }
        // Ports, docker uid:gid and docker -H hosts are not credentials.
        let benign = AgentConfigSecretMasker.maskArguments([
            "-p", "8080", "-p", "127.0.0.1:8080:80/tcp", "-u", "1000:1000", "-H", "unix:///var/run/docker.sock",
        ])
        #expect(!benign.foundSecret)
        #expect(benign.args == ["-p", "8080", "-p", "127.0.0.1:8080:80/tcp", "-u", "1000:1000", "-H", "unix:///var/run/docker.sock"])
    }

    @Test("free-text arguments with auth schemes or user:pass@ are redacted")
    func freeTextArguments() {
        let (args, found) = AgentConfigSecretMasker.maskArguments([
            "curl -H 'Authorization: Basic dXNlcjpwYXNzd29yZA=='",
            "alice:hunter2@db.internal:5432/app",
            "a description with spaces",
        ])
        #expect(found)
        #expect(!args[0].contains("dXNlcjpwYXNzd29yZA"))
        #expect(args[0].contains("Basic ••••"))
        #expect(args[1] == "alice:••••@db.internal:5432/app")
        #expect(args[2] == "a description with spaces")
    }

    @Test("conflicting-definition explanations only show masked arguments")
    func conflictExplanationIsMasked() throws {
        let home = URL(fileURLWithPath: "/Users/tester")
        let file = home.appendingPathComponent(".claude.json")
        let first = MCPServerCollector.entry(
            name: "db",
            definition: ["command": "db-mcp", "args": ["-H", "Authorization: Bearer abcdefghijklmnop", "-u", "alice:s3cretpass"]],
            client: .claudeCode,
            scope: .user,
            file: file
        )
        let second = MCPServerCollector.entry(
            name: "db",
            definition: ["command": "db-mcp", "args": ["--password", "hunter2hunter2"]],
            client: .cursor,
            scope: .user,
            file: home.appendingPathComponent(".cursor/mcp.json")
        )
        let rules = AgentConfigFindingRules(
            homeDirectory: home,
            binarySearchDirectories: [],
            access: InMemoryDirectoryAccessProvider.make { _ in }
        )
        let conflict = try #require(rules.mcpFindings(for: [first, second]).first { $0.kind == .mcpConflictingDefinitions })
        for secret in ["abcdefghijklmnop", "s3cretpass", "hunter2hunter2"] {
            #expect(!conflict.explanation.contains(secret), "leaked \(secret)")
        }
        #expect(conflict.explanation.contains("Bearer ••••"))
    }

    @Test("URL host extraction keeps nothing but the host")
    func hosts() {
        #expect(AgentConfigSecretMasker.host(of: "https://mcp.example.com/sse?key=abc") == "mcp.example.com")
        #expect(AgentConfigSecretMasker.host(of: "http://localhost:3000/mcp") == "localhost:3000")
        #expect(AgentConfigSecretMasker.host(of: "not a url") == nil)
        #expect(AgentConfigSecretMasker.urlContainsSecret("https://x.com/sse?api_key=abc"))
        #expect(!AgentConfigSecretMasker.urlContainsSecret("https://x.com/sse?api_key=${KEY}"))
        #expect(!AgentConfigSecretMasker.urlContainsSecret("https://x.com/sse"))
    }
}

@Suite("AgentConfig – imports and real filesystem")
struct AgentConfigFileSystemTests {
    @Test("@import parsing")
    func imports() {
        let text = """
        @AGENTS.md
        - see @docs/a.md, and (@~/global.md).
        `@code.md` and ``` inline
        ```
        @fenced.md
        ```
        email@example.com @someone @/abs/path.md
        """
        #expect(InstructionFileCollector.imports(in: text) == ["AGENTS.md", "docs/a.md", "~/global.md", "/abs/path.md"])
    }

    @Test("works against the real filesystem with real symlinks and bounded reads")
    func realFileSystem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"a":{"command":"/nonexistent/bin/a","env":{"TOKEN":"abcdefghijkl"}}}}"#.utf8)
            .write(to: home.appendingPathComponent(".cursor/mcp.json"))
        try Data("rules".utf8).write(to: project.appendingPathComponent("AGENTS.md"))
        try fm.createSymbolicLink(at: project.appendingPathComponent("CLAUDE.md"), withDestinationURL: project.appendingPathComponent("AGENTS.md"))
        try fm.createSymbolicLink(at: project.appendingPathComponent("GEMINI.md"), withDestinationURL: project.appendingPathComponent("missing.md"))
        try Data(repeating: 0x61, count: 4_096).write(to: project.appendingPathComponent(".windsurfrules"))

        let limits = AgentConfigAuditor.Limits(maximumInstructionBytes: 1_024)
        let audit = AgentConfigAuditor(
            homeDirectory: home,
            projectRoots: [project],
            fileAccess: SystemDirectoryAccessProvider(),
            binarySearchDirectories: [],
            limits: limits
        ).audit()

        let server = try #require(audit.servers.first)
        #expect(server.maskedEnv.first?.maskedValue == "abcd…")
        #expect(audit.findings.contains { $0.kind == .mcpCommandNotFound })
        #expect(audit.findings.contains { $0.kind == .mcpLiteralSecret })

        let claude = try #require(audit.instructionFiles.first { $0.kind == .claudeMd })
        #expect(claude.isSymlink)
        #expect(!audit.findings.contains { $0.kind == .agentsMdNotReadByClaude })

        let gemini = try #require(audit.instructionFiles.first { $0.kind == .geminiMd })
        #expect(gemini.isBrokenSymlink)
        #expect(audit.findings.contains { $0.kind == .brokenInstructionSymlink })

        #expect(audit.unreadableFiles.contains { $0.reason == .tooLarge && $0.path.lastPathComponent == ".windsurfrules" })
    }
}
