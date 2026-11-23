import Foundation
import Testing
@testable import InstalloryCore

@Suite("ProvenanceRedactor")
struct ProvenanceRedactorTests {
    private let redactor = ProvenanceRedactor(
        homeDirectory: URL(fileURLWithPath: "/Users/alice")
    )

    @Test("common assignments, URL credentials, bearer values, and standalone tokens are redacted")
    func commonSecretShapesAreRedacted() {
        let text = """
        TOKEN=top-secret pip install requests --password 'two words' \
        https://alice:hunter2@example.com/private?api_key=query-secret \
        Authorization: Bearer abcdefghijklmnop \
        Authorization: Basic YWxpY2U6aHVudGVyMg== \
        AWS_SECRET_ACCESS_KEY=aws-secret \
        OPENAI_API_KEY=openai-secret \
        refresh_token=refresh-secret private_token=private-secret \
        sk-abcdefghijklmnopqrstuvwxyz123456
        """

        let result = redactor.redactText(text)

        #expect(!result.contains("top-secret"))
        #expect(!result.contains("two words"))
        #expect(!result.contains("alice:hunter2"))
        #expect(!result.contains("query-secret"))
        #expect(!result.contains("abcdefghijklmnop"))
        #expect(!result.contains("YWxpY2U6aHVudGVyMg"))
        #expect(!result.contains("aws-secret"))
        #expect(!result.contains("openai-secret"))
        #expect(!result.contains("refresh-secret"))
        #expect(!result.contains("private-secret"))
        #expect(!result.contains("sk-abcdefghijklmnopqrstuvwxyz123456"))
        #expect(result.contains("pip install requests"))
        #expect(result.contains("example.com/private"))
    }

    @Test("evidence redaction minimizes home paths and bounds free-form text")
    func evidenceIsMinimizedAndBounded() {
        let evidence = ProvenanceEvidence(
            packageId: "pip:/usr/bin/python3:requests",
            fsInstallTime: nil,
            fsInstallTimeSource: nil,
            installCommand: ProvenanceEvidence.InstallCommandRecord(
                timestamp: nil,
                command: "cd /Users/alice/work && API_KEY=secret pip install requests",
                shell: .zsh,
                cwd: "/Users/alice/work"
            ),
            claudeCodeContext: ProvenanceEvidence.ClaudeCodeContext(
                sessionId: String(repeating: "s", count: 200),
                projectPath: "/Users/alice/work/client",
                sessionSummary: "password=hidden " + String(repeating: "x", count: 700),
                firstUserMessage: "install requests with token=hidden",
                bashInvocation: "TOKEN=hidden pip install requests",
                timestamp: nil
            ),
            nearbyProjects: [
                ProvenanceEvidence.NearbyProject(
                    path: "/Users/alice/work/client",
                    modifiedFileCount: 2,
                    gitCommitsThatDay: 1
                ),
            ],
            coInstalledWithin1h: [],
            overallConfidence: .high,
            collectedAt: .now
        )

        let result = redactor.redact(evidence)

        #expect(result.installCommand?.command == "cd ~/work && API_KEY=[REDACTED] pip install requests")
        #expect(result.installCommand?.cwd == "~/work")
        #expect(result.claudeCodeContext?.projectPath == "~/work/client")
        #expect(result.claudeCodeContext?.bashInvocation == "TOKEN=[REDACTED] pip install requests")
        // The first prompt is never kept (2026-11 review, CL-9).
        #expect(result.claudeCodeContext?.firstUserMessage == nil)
        #expect(result.claudeCodeContext?.sessionId.count == 128)
        #expect(result.claudeCodeContext?.sessionSummary?.count == 512)
        #expect(result.nearbyProjects.first?.path == "~/work/client")
    }

    @Test("private key blocks and JWTs are removed")
    func privateKeysAndJWTsAreRedacted() {
        let jwt = "eyJabcdefghijk.abcdefghijkl.abcdefghijkl"
        let text = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        very-secret-key-material
        -----END OPENSSH PRIVATE KEY-----
        bearer=\(jwt)
        """

        let result = redactor.redactText(text)

        #expect(!result.contains("very-secret-key-material"))
        #expect(!result.contains(jwt))
        #expect(result.contains("[REDACTED PRIVATE KEY]"))
    }
}
