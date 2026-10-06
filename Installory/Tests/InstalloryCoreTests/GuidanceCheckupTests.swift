import Foundation
import InstalloryCore
import Testing

@Suite("Guidance: Home checkup")
struct GuidanceCheckupTests {

    private func row(_ area: CheckupArea, _ input: CheckupInput) -> CheckupRow {
        let rows = Checkup.make(from: input)
        return rows.first { $0.area == area }!
    }

    @Test("Rows come back in fixed order, one per area")
    func order() {
        let rows = Checkup.make(from: CheckupInput(packageCount: 10))
        #expect(rows.map(\.area) == [.installedTools, .aiTools, .secrets, .space])
        #expect(rows.map(\.id) == CheckupArea.allCases)
    }

    // MARK: Installed tools

    @Test("Installed tools: nothing scanned is unknown, gap-aware")
    func toolsUnknown() {
        let plain = row(.installedTools, CheckupInput(packageCount: 0))
        #expect(plain.status == .unknown)
        #expect(plain.headline == "No tools found yet")
        #expect(plain.actionTitle == "Scan now")

        let gap = row(.installedTools, CheckupInput(packageCount: 0, coverageGaps: [.homeFolderNotGranted]))
        #expect(gap.status == .unknown)
        #expect(gap.detail.contains("home folder"))
        #expect(gap.actionTitle == "Grant access")
    }

    @Test("Installed tools: clashing duplicates need attention")
    func toolsAttention() {
        let r = row(.installedTools, CheckupInput(packageCount: 122, duplicateGroupCount: 3, highSeverityDuplicateCount: 2))
        #expect(r.status == .attention)
        #expect(r.headline == "122 tools, 3 duplicates")
        #expect(r.detail.hasPrefix("2 tools are installed more than once"))
        #expect(r.actionTitle == "Review duplicates")

        let one = row(.installedTools, CheckupInput(packageCount: 2, duplicateGroupCount: 1, highSeverityDuplicateCount: 1))
        #expect(one.headline == "2 tools, 1 duplicate")
        #expect(one.detail.hasPrefix("One tool is installed twice"))
    }

    @Test("Installed tools: harmless duplicates are good with a review action")
    func toolsBenignDuplicates() {
        let r = row(.installedTools, CheckupInput(packageCount: 50, duplicateGroupCount: 4))
        #expect(r.status == .good)
        #expect(r.headline == "50 tools, 4 duplicates")
        #expect(r.detail.contains("none of the copies are clashing"))
        #expect(r.actionTitle == "Review duplicates")
    }

    @Test("Installed tools: good with home folder missing mentions the gap")
    func toolsGoodWithGap() {
        let r = row(.installedTools, CheckupInput(packageCount: 1, coverageGaps: [.homeFolderNotGranted]))
        #expect(r.status == .good)
        #expect(r.headline == "1 tool")
        #expect(r.detail.contains("grant access"))
        #expect(r.actionTitle == "Grant access")
    }

    @Test("Installed tools: clean, with and without review candidates")
    func toolsClean() {
        let clean = row(.installedTools, CheckupInput(packageCount: 30))
        #expect(clean.status == .good)
        #expect(clean.headline == "30 tools")
        #expect(clean.detail.contains("installed once"))
        #expect(clean.actionTitle == nil)

        let review = row(.installedTools, CheckupInput(packageCount: 30, reviewCandidateCount: 5))
        #expect(review.status == .good)
        #expect(review.detail.contains("5 tools that nothing else needs"))
        #expect(review.actionTitle == "See possibly unused")
    }

    // MARK: AI tools

    @Test("AI tools: not scanned is unknown, telling the user what to grant or enable")
    func aiUnknown() {
        let home = row(.aiTools, CheckupInput(packageCount: 5, coverageGaps: [.homeFolderNotGranted]))
        #expect(home.status == .unknown)
        #expect(home.headline == "Not checked yet")
        #expect(home.detail.contains("Grant access to your home folder"))
        #expect(home.actionTitle == "Grant access")

        let disabled = row(.aiTools, CheckupInput(packageCount: 5, coverageGaps: [.agentConfigCheckDisabled]))
        #expect(disabled.status == .unknown)
        #expect(disabled.detail.contains("Turn on the AI tools check"))
        #expect(disabled.actionTitle == "Open Settings")

        // Not blocked but not run yet: the check runs with the next scan.
        let plain = row(.aiTools, CheckupInput(packageCount: 5))
        #expect(plain.status == .unknown)
        #expect(plain.headline == "Not checked yet")
        #expect(plain.detail.contains("Run a scan"))
        #expect(plain.actionTitle == "Scan now")

        let week = row(.aiTools, CheckupInput(packageCount: 5, aiInstalledThisWeekCount: 2))
        #expect(week.status == .unknown)
        #expect(week.headline == "2 tools added by AI this week")
        #expect(week.actionTitle == "See this week's installs")
    }

    @Test("AI tools: high or medium findings need attention")
    func aiAttention() {
        let high = row(.aiTools, CheckupInput(packageCount: 5, agentFindings: .init(high: 1, medium: 1, low: 3)))
        #expect(high.status == .attention)
        #expect(high.headline == "2 problems found")
        #expect(high.detail.contains("stop tools from working"))
        #expect(high.actionTitle == "Review AI tools")

        let medium = row(.aiTools, CheckupInput(packageCount: 5, agentFindings: .init(medium: 1)))
        #expect(medium.status == .attention)
        #expect(medium.headline == "1 problem found")
        #expect(medium.detail.contains("tidied up"))
    }

    @Test("AI tools: healthy variants")
    func aiGood() {
        let week = row(.aiTools, CheckupInput(packageCount: 5, aiInstalledThisWeekCount: 4, agentFindings: .init(low: 2)))
        #expect(week.status == .good)
        #expect(week.headline == "4 tools added by AI this week")
        #expect(week.actionTitle == "See this week's installs")

        let notes = row(.aiTools, CheckupInput(packageCount: 5, agentFindings: .init(low: 1)))
        #expect(notes.status == .good)
        #expect(notes.headline == "1 minor note")
        #expect(notes.actionTitle == "See notes")

        let clean = row(.aiTools, CheckupInput(packageCount: 5, agentFindings: .init()))
        #expect(clean.status == .good)
        #expect(clean.headline == "No problems found")
        #expect(clean.actionTitle == nil)
    }

    // MARK: Secrets

    @Test("Secrets: not checked is unknown, gap-aware")
    func secretsUnknown() {
        let home = row(.secrets, CheckupInput(packageCount: 5, coverageGaps: [.homeFolderNotGranted, .secretsCheckDisabled]))
        #expect(home.status == .unknown)
        #expect(home.detail.contains("home folder"))
        #expect(home.actionTitle == "Grant access")

        let disabled = row(.secrets, CheckupInput(packageCount: 5, coverageGaps: [.secretsCheckDisabled]))
        #expect(disabled.status == .unknown)
        #expect(disabled.detail.contains("Turn on the secrets check"))
        #expect(disabled.actionTitle == "Open Settings")

        let plain = row(.secrets, CheckupInput(packageCount: 5, coverageGaps: [.other("Downloads")]))
        #expect(plain.status == .unknown)
        #expect(plain.detail.contains("Run a scan"))
        #expect(plain.actionTitle == "Scan now")
    }

    @Test("Secrets: exposed keys need attention; zero is good")
    func secretsKnown() {
        let exposed = row(.secrets, CheckupInput(packageCount: 5, exposedSecretCount: 2))
        #expect(exposed.status == .attention)
        #expect(exposed.headline == "2 keys in AI tool settings")
        #expect(exposed.actionTitle == "Review keys")

        let one = row(.secrets, CheckupInput(packageCount: 5, exposedSecretCount: 1))
        #expect(one.headline == "1 key in AI tool settings")

        let none = row(.secrets, CheckupInput(packageCount: 5, exposedSecretCount: 0))
        #expect(none.status == .good)
        #expect(none.headline == "No keys in AI tool settings")
        #expect(none.detail.contains(".env"))
        #expect(none.actionTitle == nil)
    }

    // MARK: Space

    @Test("Space: unknown when nothing scanned or sizes unmeasured")
    func spaceUnknown() {
        let empty = row(.space, CheckupInput(packageCount: 0))
        #expect(empty.status == .unknown)
        #expect(empty.headline == "Not measured yet")

        let unmeasured = row(.space, CheckupInput(packageCount: 10, reclaimableBytes: 0, safeToRemoveCount: 3))
        #expect(unmeasured.status == .unknown)
        #expect(unmeasured.headline == "3 tools safe to remove")
        #expect(unmeasured.detail.contains("haven't been measured"))
    }

    @Test("Space: nothing safe to remove is good")
    func spaceNothing() {
        let r = row(.space, CheckupInput(packageCount: 10, reclaimableBytes: 5_000_000_000, safeToRemoveCount: 0))
        #expect(r.status == .good)
        #expect(r.headline == "Nothing to free up")
        #expect(r.actionTitle == nil)
    }

    @Test("Space: small reclaimable is good, large needs attention; sizes use ByteCountFormatter")
    func spaceSizes() {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]

        let small = row(.space, CheckupInput(packageCount: 10, reclaimableBytes: 350_000_000, safeToRemoveCount: 2))
        #expect(small.status == .good)
        #expect(small.headline == "\(formatter.string(fromByteCount: 350_000_000)) can be freed")
        #expect(small.detail.contains("Removing 2 tools"))
        #expect(small.actionTitle == "Free up space")

        let large = row(.space, CheckupInput(packageCount: 10, reclaimableBytes: Checkup.spaceAttentionThresholdBytes, safeToRemoveCount: 1))
        #expect(large.status == .attention)
        #expect(large.headline == "\(formatter.string(fromByteCount: Checkup.spaceAttentionThresholdBytes)) can be freed")
        #expect(large.detail.contains("Removing 1 tool that"))
        #expect(Checkup.formatBytes(2_100_000_000) == formatter.string(fromByteCount: 2_100_000_000))
    }

    @Test("Output is deterministic")
    func deterministic() {
        let input = CheckupInput(
            packageCount: 122, duplicateGroupCount: 3, highSeverityDuplicateCount: 1,
            reviewCandidateCount: 4, aiInstalledThisWeekCount: 2,
            agentFindings: .init(high: 0, medium: 0, low: 0), exposedSecretCount: 0,
            reclaimableBytes: 2_000_000_000, safeToRemoveCount: 5
        )
        #expect(Checkup.make(from: input) == Checkup.make(from: input))
    }
}
