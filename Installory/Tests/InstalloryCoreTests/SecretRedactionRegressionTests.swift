import Foundation
import Testing
@testable import InstalloryCore

/// Regression tests for the secret-handling gaps found in the November 2026
/// review (AI-1 to AI-6, AI-14, CL-9). Every fake credential is assembled at
/// runtime so no provider-shaped literal lives in the source (GitHub push
/// protection flags those even when they're obviously fake).
private enum Fake {
    static func join(_ parts: String...) -> String { parts.joined() }
    static let body = "abcdefghijklmnopqrstuvwxyz0123456789"
    static let stripe = join("sk", "_live_", "51H", body)
    static let stripeRestricted = join("rk", "_live_", "51H", body)
    static let npm = join("np", "m_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")
    static let github = join("gh", "p_", body)
    static let gitlab = join("glp", "at-", "abcdefghijklmnopqrst")
    static let google = join("AI", "zaSyA-", body)
    static let huggingFace = join("h", "f_", body)
    static let slackWebhook = join("https://hooks.sl", "ack.com/services/", "T0000/B0000/", "XXXXXXXXXXXXXXXXXXXXXXXX")
    static let anthropic = join("sk-an", "t-api03-", body)
    static let generic = join("FAKE", "SECRET", "VALUE", "1234567")
}

@Suite("Secret redaction regressions (2026-11 review)")
struct SecretRedactionRegressionTests {
    typealias M = AgentConfigSecretMasker
    let redactor = ProvenanceRedactor(homeDirectory: URL(fileURLWithPath: "/Users/tester"))

    // MARK: - Shared core: both redactors catch the same shapes

    static let leakCases: [(String, String)] = [
        ("export STRIPE_SECRET_KEY=\(Fake.stripe)", Fake.stripe),
        ("STRIPE_KEY=\(Fake.stripeRestricted) npm i -g stripe", Fake.stripeRestricted),
        ("npm config set //registry.npmjs.org/:_authToken \(Fake.npm)", Fake.npm),
        ("pip install git+https://\(Fake.gitlab)@gitlab.com/o/r.git", Fake.gitlab),
        ("my key is \(Fake.google) please install", Fake.google),
        ("use \(Fake.huggingFace) to pip install transformers", Fake.huggingFace),
        ("export SLACK_WEBHOOK=\(Fake.slackWebhook)", "XXXXXXXXXXXXXXXXXXXXXXXX"),
        ("export GH_PAT=11ABCDEFG0123456789abcdefghijklmnop", "11ABCDEFG0123456789"),
        ("docker login -p \(Fake.generic) registry.example.com", Fake.generic),
        ("curl -H \"X-Api-Key: \(Fake.generic)\" https://api.example.com", Fake.generic),
        ("curl -H 'x-api-key: \(Fake.generic)' https://api.example.com", Fake.generic),
        ("curl -u admin:\(Fake.generic) https://api.example.com", Fake.generic),
        ("curl -d '{\"password\":\"\(Fake.generic)\"}' https://api.example.com", Fake.generic),
        ("sshpass -p \(Fake.generic) ssh host", Fake.generic),
        ("export DATABASE_URL=postgres://admin:\(Fake.generic)@db.example.com/app", Fake.generic),
        ("ANTHROPIC_AUTH=\(Fake.anthropic) npm i -g x", Fake.anthropic),
    ]

    @Test("Install History redaction removes each secret shape", arguments: Self.leakCases)
    func provenanceRedactsEveryShape(input: String, secret: String) {
        let output = redactor.redactText(input)
        #expect(!output.contains(secret), "leaked: \(output)")
    }

    @Test("hook-command redaction removes each secret shape", arguments: Self.leakCases)
    func hookCommandRedactsEveryShape(input: String, secret: String) {
        let output = M.redactCommand(input)
        #expect(!output.contains(secret), "leaked: \(output)")
    }

    @Test("redaction keeps the useful parts of a command")
    func redactionKeepsContext() {
        let output = redactor.redactText("brew install jq && npm i -g eslint")
        #expect(output == "brew install jq && npm i -g eslint")
        let hook = M.redactCommand("curl -H \"X-Api-Key: \(Fake.generic)\" https://api.example.com")
        #expect(hook.contains("curl -H"))
        #expect(hook.contains("https://api.example.com"))
        // Ports are not passwords.
        #expect(M.redactCommand("docker run -p 8080:80 nginx") == "docker run -p 8080:80 nginx")
    }

    @Test("home paths with spaces are shortened")
    func homePathWithSpaces() {
        let output = redactor.redactText("cd '/Users/John Smith/projects' && npm i -g y")
        #expect(!output.contains("Smith"), "leaked: \(output)")
        #expect(output.contains("~/projects"))
    }

    // MARK: - AI-1: shell defaults are literal secrets

    @Test("${VAR:-literal} keeps the variable name and masks the default")
    func defaultExpansionIsMasked() {
        let value = "${API_KEY:-\(Fake.generic)}"
        #expect(!M.isReference(value))
        let pair = M.maskedPair(key: "OPENAI_API_KEY", value: value)
        #expect(pair.isLiteralSecret)
        #expect(!pair.maskedValue.contains(Fake.generic))
        #expect(pair.maskedValue.hasPrefix("${API_KEY:-"))

        let args = M.maskArguments(["--token", "${TOKEN:-\(Fake.generic)}"])
        #expect(args.foundSecret)
        #expect(!args.args.joined(separator: " ").contains(Fake.generic))
    }

    @Test("plain references stay readable", arguments: ["${GITHUB_TOKEN}", "$TOKEN", "${env:TOKEN}", "{env:TOKEN}", "Bearer ${TOKEN}", "${input:token}"])
    func plainReferencesStay(value: String) {
        #expect(M.isReference(value))
        #expect(M.maskedPair(key: "API_KEY", value: value).maskedValue == value)
    }

    // MARK: - AI-6: more credential flags

    @Test("values after credential flags are masked", arguments: ["--pat", "--bearer", "--pass", "--api-token", "--client-secret"])
    func credentialFlags(flag: String) {
        let result = M.maskArguments([flag, Fake.generic])
        #expect(result.foundSecret)
        #expect(!result.args.contains(Fake.generic))
    }

    // MARK: - AI-3 / AI-4: key names

    @Test("settings that aren't secrets are not flagged",
          arguments: [("MAX_THINKING_TOKENS", "31999"), ("CLAUDE_CODE_MAX_OUTPUT_TOKENS", "32000"),
                      ("MAX_MCP_OUTPUT_TOKENS", "25000"), ("TOKENIZERS_PARALLELISM", "false"),
                      ("GIT_AUTHOR_NAME", "Jane Doe"), ("KEYBOARD_LAYOUT", "us"),
                      ("CLAUDE_CODE_DISABLE_TERMINAL_TITLE_AUTH_HINT", "1"), ("KEYCHAIN_PATH", "/tmp/x")])
    func nonSecretsAreNotFlagged(key: String, value: String) {
        #expect(!M.maskedPair(key: key, value: value).isLiteralSecret, "\(key) flagged")
    }

    @Test("credential names and values are flagged",
          arguments: [("DATABASE_URL", "postgres://app:\(Fake.generic)@db.example.com/prod"),
                      ("DB_PASS", Fake.generic), ("PGPASS", Fake.generic),
                      ("Cookie", "session=\(Fake.generic)"),
                      ("GOOGLE_APPLICATION_CREDENTIALS_JSON", "{\"private_key\":\"\(Fake.generic)\"}"),
                      ("SLACK_WEBHOOK", Fake.slackWebhook), ("GH_PAT", Fake.generic),
                      ("apiKey", Fake.generic), ("OPENAI_API_KEY", Fake.generic)])
    func credentialsAreFlagged(key: String, value: String) {
        let pair = M.maskedPair(key: key, value: value)
        #expect(pair.isLiteralSecret, "\(key) not flagged")
        #expect(!pair.maskedValue.contains(Fake.generic))
    }

    @Test("masking rule is unchanged: short values fully hidden, 8+ keep 4 characters")
    func maskingRule() {
        #expect(M.maskedPair(key: "API_KEY", value: "1234567").maskedValue == "••••")
        #expect(M.maskedPair(key: "API_KEY", value: "12345678").maskedValue == "1234…")
    }

    // MARK: - CL-9: the first prompt isn't kept

    @Test("Install History never keeps the user's first prompt")
    func firstPromptIsDropped() {
        let context = ProvenanceEvidence.ClaudeCodeContext(
            sessionId: "s1",
            projectPath: "/Users/tester/projects/app",
            sessionSummary: "Add video export",
            firstUserMessage: "here is my key \(Fake.generic), please set up ffmpeg",
            bashInvocation: "brew install ffmpeg",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let redacted = redactor.redact(context)
        #expect(redacted.firstUserMessage == nil)
        #expect(redacted.sessionSummary == "Add video export")
    }
}

@Suite("Home key row when settings files couldn't be read (AI-5)")
struct KeyRowCoverageTests {
    private func keyRow(_ input: CheckupInput) -> CheckupRow? {
        Checkup.make(from: input).first { $0.area == .secrets }
    }

    @Test("no keys found but a settings file was unreadable → not fully checked")
    func unreadableMeansNotFullyChecked() throws {
        let row = try #require(keyRow(CheckupInput(packageCount: 10, exposedSecretCount: 0, unreadableSettingsFileCount: 1)))
        #expect(row.status == .unknown)
        #expect(row.headline == "Not fully checked")
        #expect(row.detail.contains("1 settings file couldn't be read"))
        #expect(row.action == .reviewAITools)
    }

    @Test("everything readable and no keys → good")
    func allReadIsGood() throws {
        let row = try #require(keyRow(CheckupInput(packageCount: 10, exposedSecretCount: 0)))
        #expect(row.status == .good)
    }

    @Test("found keys still need attention even if another file was unreadable")
    func keysStillNeedAttention() throws {
        let row = try #require(keyRow(CheckupInput(packageCount: 10, exposedSecretCount: 2, unreadableSettingsFileCount: 1)))
        #expect(row.status == .attention)
    }

    @Test("only settings files count, not instruction files")
    func instructionFilesDontCount() {
        let audit = AgentConfigAudit(
            servers: [], instructionFiles: [], permissionProfiles: [], findings: [],
            unreadableFiles: [
                UnreadableConfigFile(path: URL(fileURLWithPath: "/Users/t/.claude.json"), reason: .tooLarge),
                UnreadableConfigFile(path: URL(fileURLWithPath: "/Users/t/p/CLAUDE.md"), reason: .tooLarge),
                UnreadableConfigFile(path: URL(fileURLWithPath: "/Users/t/p/.cursorrules"), reason: .unreadable),
            ]
        )
        #expect(audit.unreadableSettingsFileCount == 1)
    }
}

@Suite("Redaction stays fast on long input")
struct RedactionPerformanceTests {
    @Test("a 200 KB single-line command redacts in well under a second")
    func longLine() {
        let filler = String(repeating: "curl docker login mysql sshpass --user a ", count: 5_000)
        let start = Date()
        let output = AgentConfigSecretMasker.redactCommand(filler + "TOKEN=abcdefghijkl", maximumLength: .max)
        let elapsed = Date().timeIntervalSince(start)
        #expect(output.hasSuffix("TOKEN=••••"))
        #expect(elapsed < 1.0, "took \(elapsed) s")
    }
}
