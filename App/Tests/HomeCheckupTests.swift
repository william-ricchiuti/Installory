import Foundation
import InstalloryCore
import Testing
@testable import Installory

@Suite("Home checkup, cleanup eligibility, and rating prompt", .serialized)
@MainActor
struct HomeCheckupTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstalloryHomeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makePackage(
        id: String,
        manager: PackageManager,
        name: String,
        installPath: String? = nil,
        sizeBytes: Int64? = 4_096
    ) -> Package {
        Package(
            id: id,
            manager: manager,
            qualifier: nil,
            name: name,
            version: "1.0",
            installPath: installPath.map { URL(fileURLWithPath: $0) },
            installedAt: Date(timeIntervalSince1970: 1_720_000_000),
            installedAtConfidence: .high,
            sizeBytes: sizeBytes,
            isExplicit: true,
            isReadOnly: false,
            dependencies: [],
            lastSeen: Date(timeIntervalSince1970: 1_720_100_000)
        )
    }

    private func hydratedCoordinator(
        with packages: [Package],
        in directory: URL
    ) async throws -> AppCoordinator {
        let database = try Database(directory: directory)
        try PackageDAO(database: database).replaceAll(with: packages)
        let coordinator = AppCoordinator(dataDirectoryOverride: directory)
        await coordinator.hydratePersistedState()
        return coordinator
    }

    // MARK: - Checkup input

    @Test("Checkup input mirrors coordinator aggregates in demo mode")
    func checkupInputFromDemoState() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AppCoordinator(dataDirectoryOverride: directory)
        coordinator.enterDemoMode()

        let path = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let input = coordinator.checkupInput(pathComponents: path)
        let bundle = coordinator.freeUpSpaceBundle

        #expect(input.packageCount == coordinator.packages.count)
        #expect(input.duplicateGroupCount == coordinator.duplicateGroups.count)
        #expect(input.highSeverityDuplicateCount
            == coordinator.duplicateAnalysis(pathComponents: path).active.count)
        #expect(input.reviewCandidateCount == coordinator.orphanedPackages.count)
        #expect(input.reclaimableBytes == bundle.totalReclaimableBytes)
        #expect(input.safeToRemoveCount == bundle.candidates.count)
        #expect(input.agentFindings == nil)
        #expect(input.exposedSecretCount == nil)
        // Demo data never asks the user to grant real folders.
        #expect(input.coverageGaps.isEmpty)
        #expect(Checkup.make(from: input).count == 4)
    }

    @Test("Checkup flags the home folder gap when no grant covers it")
    func checkupInputReportsHomeGap() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = try await hydratedCoordinator(
            with: [makePackage(id: "brew::jq", manager: .brew, name: "jq")],
            in: directory
        )
        let input = coordinator.checkupInput(pathComponents: [])
        #expect(input.coverageGaps.contains(.homeFolderNotGranted) == !coordinator.provenanceAccessGranted)
        #expect(input.packageCount == 1)
    }

    @Test("Checkup actions route to the screen that explains each row")
    func checkupRowActions() {
        let duplicates = CheckupRow(area: .installedTools, status: .attention, headline: "", detail: "", actionTitle: "Review duplicates")
        #expect(duplicates.action == .navigate(.duplicates))
        let review = CheckupRow(area: .installedTools, status: .good, headline: "", detail: "", actionTitle: "See review list")
        #expect(review.action == .navigate(.orphans))
        let week = CheckupRow(area: .aiTools, status: .good, headline: "", detail: "", actionTitle: "See this week's installs")
        #expect(week.action == .navigate(.aiInstalled))
        let space = CheckupRow(area: .space, status: .attention, headline: "", detail: "", actionTitle: "Free up space")
        #expect(space.action == .navigate(.diskUsage))
        let grant = CheckupRow(area: .secrets, status: .unknown, headline: "", detail: "", actionTitle: "Grant access")
        #expect(grant.action == .grantHomeAccess)
        let settings = CheckupRow(area: .aiTools, status: .unknown, headline: "", detail: "", actionTitle: "Open Settings")
        #expect(settings.action == .openSettings)
        let none = CheckupRow(area: .secrets, status: .good, headline: "", detail: "", actionTitle: nil)
        #expect(none.action == nil)
        #expect(none.statusAccessibilityLabel == "Looks good")
    }

    // MARK: - Free up space

    @Test("Hidden packages drop out of the free-up-space bundle")
    func hiddenPackagesAreExcludedFromBundle() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jq = makePackage(id: "brew::jq", manager: .brew, name: "jq", sizeBytes: 9_000)
        let coordinator = try await hydratedCoordinator(with: [jq], in: directory)

        #expect(coordinator.freeUpSpaceBundle.candidates.map(\.package.id) == [jq.id])
        let before = coordinator.inventoryDerivedComputationCounts.freeUpSpaceBundle

        coordinator.toggleHidden(jq.id)
        #expect(coordinator.freeUpSpaceBundle.isEmpty)
        #expect(coordinator.inventoryDerivedComputationCounts.freeUpSpaceBundle == before + 1)

        // Same hidden set reuses the cached bundle.
        _ = coordinator.freeUpSpaceBundle
        #expect(coordinator.inventoryDerivedComputationCounts.freeUpSpaceBundle == before + 1)
    }

    // MARK: - Cleanup eligibility

    @Test("Cleanup selection follows the removal strategy")
    func cleanupEligibilityFollowsStrategy() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let skill = makePackage(
            id: "agentSkill::claude:pdf",
            manager: .agentSkill,
            name: "pdf",
            installPath: "/Users/example/.claude/skills/pdf"
        )
        let cli = makePackage(id: "agentCli::claude", manager: .agentCli, name: "claude")
        let coordinator = try await hydratedCoordinator(with: [skill, cli], in: directory)
        let previousStrategy = coordinator.removalStrategy
        defer { coordinator.removalStrategy = previousStrategy }

        coordinator.removalStrategy = .uninstall
        coordinator.sidebarSelection = .skills
        // A real skill folder can only be moved to the Trash.
        #expect(coordinator.cleanupPackagesForCurrentSection.isEmpty)
        // Cleanup Mode stays reachable so the strategy picker can be used.
        #expect(coordinator.canEnterCleanupMode)

        coordinator.removalStrategy = .trash
        #expect(coordinator.cleanupPackagesForCurrentSection.map(\.id) == [skill.id])

        coordinator.isCleanupMode = true
        coordinator.selectedForCleanup = [skill.id]
        coordinator.removalStrategy = .uninstall
        #expect(coordinator.selectedForCleanup.isEmpty)
        #expect(coordinator.isCleanupMode)

        // Agent CLIs never have a runnable command under either strategy.
        coordinator.sidebarSelection = .all
        #expect(!coordinator.cleanupScopePackagesForCurrentSection.contains { $0.id == cli.id })
        #expect(
            CleanupSelectionToggle.ineligibleDescription(for: skill, strategy: .uninstall)
                == "Switch to Move to Trash to include pdf"
        )
        #expect(
            CleanupSelectionToggle.ineligibleDescription(for: cli, strategy: .trash)
                .contains("no removal command")
        )
    }

    // MARK: - Rating prompt

    private func reviewContext(
        isDemoMode: Bool = false,
        onboardingCompleted: Bool = true,
        scanCompleted: Bool = true,
        days: Int = 3,
        reclaimable: Int64 = 1,
        allGood: Bool = false,
        version: String = "1.2",
        lastPrompted: String? = nil
    ) -> ReviewPromptPolicy.Context {
        ReviewPromptPolicy.Context(
            isDemoMode: isDemoMode,
            onboardingCompleted: onboardingCompleted,
            scanCompleted: scanCompleted,
            distinctLaunchDays: days,
            reclaimableBytes: reclaimable,
            checkupAllGood: allGood,
            currentVersion: version,
            lastPromptedVersion: lastPrompted
        )
    }

    @Test("Rating prompt appears only after a positive, real, repeated-use moment")
    func reviewPromptGating() {
        #expect(ReviewPromptPolicy.shouldRequestReview(reviewContext()))
        #expect(ReviewPromptPolicy.shouldRequestReview(reviewContext(reclaimable: 0, allGood: true)))

        #expect(!ReviewPromptPolicy.shouldRequestReview(reviewContext(reclaimable: 0, allGood: false)))
        #expect(!ReviewPromptPolicy.shouldRequestReview(reviewContext(isDemoMode: true)))
        #expect(!ReviewPromptPolicy.shouldRequestReview(reviewContext(onboardingCompleted: false)))
        #expect(!ReviewPromptPolicy.shouldRequestReview(reviewContext(scanCompleted: false)))
        #expect(!ReviewPromptPolicy.shouldRequestReview(reviewContext(days: 2)))
        #expect(!ReviewPromptPolicy.shouldRequestReview(reviewContext(lastPrompted: "1.2")))
        #expect(ReviewPromptPolicy.shouldRequestReview(reviewContext(lastPrompted: "1.1")))
    }

    @Test("Launch days are recorded once per calendar day")
    func launchDayRecording() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let morning = Date(timeIntervalSince1970: 1_759_651_200) // 2025-10-05 08:00 UTC
        let evening = morning.addingTimeInterval(10 * 3_600)
        let nextDay = morning.addingTimeInterval(24 * 3_600)

        let first = ReviewPromptPolicy.dayKey(for: morning, calendar: calendar)
        #expect(first == "2025-10-05")
        var days = ReviewPromptPolicy.recording(day: first, in: [])
        days = ReviewPromptPolicy.recording(day: ReviewPromptPolicy.dayKey(for: evening, calendar: calendar), in: days)
        #expect(days.count == 1)
        days = ReviewPromptPolicy.recording(day: ReviewPromptPolicy.dayKey(for: nextDay, calendar: calendar), in: days)
        #expect(days == ["2025-10-05", "2025-10-06"])

        let many = (1...20).reduce([String]()) { ReviewPromptPolicy.recording(day: "d\($1)", in: $0) }
        #expect(many.count == ReviewPromptPolicy.maxRecordedDays)
    }

    // MARK: - Copy

    @Test("Ask-your-agent menu titles name the agent")
    func askAgentMenuTitles() {
        #expect(PromptClipboard.menuTitle(for: .claudeCode) == "Copy Prompt for Claude Code")
        #expect(PromptClipboard.menuTitle(for: .codex) == "Copy Prompt for Codex")
        #expect(PromptClipboard.menuTitle(for: .generic) == "Copy Prompt for Any AI Assistant")
    }

    @Test("Plain-language badges and setup prompt")
    func plainLanguageCopy() throws {
        #expect(PackageManager.brewCask.badgeLabel == "app")
        #expect(PackageManager.mas.badgeLabel == "App Store")
        #expect(PackageManager.agentCli.badgeLabel == "AI tool")

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AppCoordinator(dataDirectoryOverride: directory)
        coordinator.enterDemoMode()
        let prompt = coordinator.setupPrompt(for: .codex)
        #expect(prompt.body.hasPrefix("Hi Codex."))
        #expect(prompt.body.count <= AgentPromptBuilder.defaultSetupMaxCharacters)
        #expect(!prompt.body.contains(UserHome.directory.path + "/"))
    }
}
