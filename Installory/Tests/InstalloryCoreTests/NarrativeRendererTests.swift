import Testing
import Foundation
@testable import InstalloryCore

@Suite("NarrativeRenderer")
struct NarrativeRendererTests {
    private let renderer = NarrativeRenderer()

    @Test("renderer redacts legacy unredacted evidence")
    func rendererRedactsLegacyEvidence() {
        let command = ProvenanceEvidence.InstallCommandRecord(
            timestamp: nil,
            command: "TOKEN=legacy-secret brew install ffmpeg",
            shell: .zsh,
            cwd: nil
        )
        let evidence = makeEvidence(command: command)

        let output = renderer.render(evidence, package: makePackage())

        #expect(!output.contains("legacy-secret"))
        #expect(output.contains("TOKEN=[REDACTED] brew install ffmpeg"))
    }

    // MARK: - Helpers

    /// A fixed "old" date well outside the 14-day relative window (~Aug 14, 2024).
    private let oldDate = Date(timeIntervalSince1970: 1_723_648_991)

    private func makePackage() -> Package {
        Package(
            id: "brew::ffmpeg",
            manager: .brew,
            qualifier: nil,
            name: "ffmpeg",
            version: "6.1",
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

    private func makeContext(
        date: Date,
        sessionSummary: String? = nil,
        firstUserMessage: String? = nil
    ) -> ProvenanceEvidence.ClaudeCodeContext {
        ProvenanceEvidence.ClaudeCodeContext(
            sessionId: "sess-abc",
            projectPath: "/Users/will/projects/podcast-app",
            sessionSummary: sessionSummary,
            firstUserMessage: firstUserMessage,
            bashInvocation: "brew install ffmpeg",
            timestamp: date
        )
    }

    private func makeEvidence(
        fsDate: Date? = nil,
        command: ProvenanceEvidence.InstallCommandRecord? = nil,
        context: ProvenanceEvidence.ClaudeCodeContext? = nil,
        coInstalled: [String] = [],
        coInstalledTotalCount: Int? = nil
    ) -> ProvenanceEvidence {
        ProvenanceEvidence(
            packageId: "brew::ffmpeg",
            fsInstallTime: fsDate,
            fsInstallTimeSource: fsDate != nil ? "INSTALL_RECEIPT.json" : nil,
            installCommand: command,
            claudeCodeContext: context,
            nearbyProjects: [],
            coInstalledWithin1h: coInstalled,
            coInstalledWithin1hTotalCount: coInstalledTotalCount,
            overallConfidence: .low,
            collectedAt: Date(timeIntervalSince1970: 1_723_700_000)
        )
    }

    // MARK: - Template case: Claude Code present

    @Test("Claude Code case with session summary renders full context string")
    func claudeCodeWithSummary() {
        let context = makeContext(date: oldDate, sessionSummary: "Building a podcast transcription script")
        let evidence = makeEvidence(context: context)
        let result = renderer.render(evidence, package: makePackage())
        #expect(result.hasPrefix("Installed "))
        #expect(result.contains("working in ~/projects/podcast-app"))
        #expect(result.contains("That session was about: Building a podcast transcription script."))
        #expect(!result.contains("You'd asked:"))
    }

    @Test("Claude Code case with no summary never shows the user's first prompt")
    func claudeCodeWithUserMessageOnly() {
        let context = makeContext(
            date: oldDate,
            sessionSummary: nil,
            firstUserMessage: "help me build a podcast app"
        )
        let evidence = makeEvidence(context: context)
        let result = renderer.render(evidence, package: makePackage())
        #expect(!result.contains("help me build a podcast app"))
        #expect(!result.contains("You'd asked:"))
        #expect(!result.contains("That session was about:"))
    }

    @Test("Claude Code case with no summary and no user message omits the summary clause")
    func claudeCodeNoSummaryNoMessage() {
        let context = makeContext(date: oldDate)
        let evidence = makeEvidence(context: context)
        let result = renderer.render(evidence, package: makePackage())
        #expect(result.contains("while working in"))
        #expect(!result.contains("That session was about:"))
        #expect(!result.contains("You'd asked:"))
    }

    // MARK: - Template case: shell only

    @Test("shell-only case renders with backtick-quoted command")
    func shellOnlyCase() {
        let cmd = ProvenanceEvidence.InstallCommandRecord(
            timestamp: oldDate,
            command: "brew install ffmpeg",
            shell: .zsh,
            cwd: nil
        )
        let evidence = makeEvidence(command: cmd)
        let result = renderer.render(evidence, package: makePackage())
        #expect(result.contains("`brew install ffmpeg`"))
        #expect(result.contains("in your terminal."))
        #expect(!result.contains("working in"))
        #expect(!result.contains("file timestamp"))
    }

    // MARK: - Template case: fs-only

    @Test("fs-only case renders with file-timestamp disclaimer")
    func fsOnlyCase() {
        let evidence = makeEvidence(fsDate: oldDate)
        let result = renderer.render(evidence, package: makePackage())
        #expect(result.contains("based on file timestamp"))
        #expect(result.contains("we don't have a matching install command in your history"))
        #expect(!result.contains("working in"))
        #expect(!result.contains("terminal"))
    }

    // MARK: - Template case: unknown

    @Test("unknown case renders the no-recorded-install-date message")
    func unknownCase() {
        let evidence = makeEvidence()
        let result = renderer.render(evidence, package: makePackage())
        #expect(result == "We don't have a recorded install date for this package.")
    }

    // MARK: - Co-installed formatting

    @Test("zero co-installed items omits the co-installed clause")
    func coInstalledZero() {
        let context = makeContext(date: oldDate)
        let evidence = makeEvidence(context: context, coInstalled: [])
        let result = renderer.render(evidence, package: makePackage())
        #expect(!result.contains("You also installed"))
    }

    @Test("one co-installed item uses bare name without conjunction")
    func coInstalledOne() {
        let evidence = makeEvidence(
            fsDate: oldDate,
            coInstalled: ["brew::libpng"]
        )
        let result = renderer.render(
            evidence,
            package: makePackage(),
            nameByPackageId: ["brew::libpng": "libpng"]
        )
        #expect(result.contains("You also installed libpng around the same time."))
    }

    @Test("two co-installed items use 'and' conjunction without Oxford comma")
    func coInstalledTwo() {
        let evidence = makeEvidence(
            fsDate: oldDate,
            coInstalled: ["brew::ffplay", "brew::libpng"]
        )
        let result = renderer.render(
            evidence,
            package: makePackage(),
            nameByPackageId: ["brew::ffplay": "ffplay", "brew::libpng": "libpng"]
        )
        #expect(result.contains("You also installed ffplay and libpng around the same time."))
    }

    @Test("three or more co-installed items use Oxford-comma list")
    func coInstalledThreePlus() {
        let evidence = makeEvidence(
            fsDate: oldDate,
            coInstalled: ["brew::ffplay", "brew::libpng", "brew::pydub"]
        )
        let result = renderer.render(
            evidence,
            package: makePackage(),
            nameByPackageId: [
                "brew::ffplay": "ffplay",
                "brew::libpng": "libpng",
                "brew::pydub": "pydub",
            ]
        )
        #expect(result.contains("You also installed ffplay, libpng, and pydub around the same time."))
    }

    @Test("bounded co-installed sample reports the omitted package count")
    func coInstalledBoundedSample() {
        let evidence = makeEvidence(
            fsDate: oldDate,
            coInstalled: ["brew::ffplay", "brew::libpng"],
            coInstalledTotalCount: 12
        )
        let result = renderer.render(
            evidence,
            package: makePackage(),
            nameByPackageId: ["brew::ffplay": "ffplay", "brew::libpng": "libpng"]
        )
        #expect(result.contains("You also installed ffplay and libpng and 10 more around the same time."))
    }

    // MARK: - Date formatting

    @Test("dates within 14 days use relative format (no year)")
    func recentDateRelativeFormat() {
        let threeDaysAgo = Date().addingTimeInterval(-3 * 86400)
        let context = makeContext(date: threeDaysAgo)
        let evidence = makeEvidence(context: context)
        let result = renderer.render(evidence, package: makePackage())
        // Relative format never includes a 4-digit year.
        #expect(!result.contains("202"))
    }

    @Test("dates older than 14 days use absolute format (month day, year)")
    func oldDateAbsoluteFormat() {
        let context = makeContext(date: oldDate)
        let evidence = makeEvidence(context: context)
        let result = renderer.render(evidence, package: makePackage())
        // Absolute format always includes a 4-digit year.
        #expect(result.contains("2024"))
        // The formatted date should also appear in the result as produced by the same formatter.
        let expectedDate: String = {
            let f = DateFormatter()
            f.dateFormat = "MMM d, yyyy"
            return f.string(from: oldDate)
        }()
        #expect(result.contains(expectedDate))
    }

    // MARK: - Co-installed name fallback

    @Test("co-installed id absent from dict falls back to last colon-segment of id")
    func coInstalledNameFallback() {
        let evidence = makeEvidence(
            fsDate: oldDate,
            coInstalled: ["pip:/usr/bin/python3:requests"]
        )
        // Pass an empty dict so the fallback path is exercised.
        let result = renderer.render(evidence, package: makePackage(), nameByPackageId: [:])
        // The fallback should extract "requests" from the id.
        #expect(result.contains("requests"))
        #expect(!result.contains("pip:/usr/bin/python3:requests"))
    }
}
