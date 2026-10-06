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
        // Demo mode carries a sample AI setup audit.
        let audit = try #require(coordinator.aiSetupAudit)
        #expect(input.agentFindings == AISetupPresentation.checkupCounts(audit))
        #expect(input.exposedSecretCount == audit.literalSecretCount)
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

    @Test("Install history on without a home grant is shown as needing access, not active")
    func installHistoryNeedsHomeAccess() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AppCoordinator(dataDirectoryOverride: directory)
        coordinator.provenanceCollection = false
        #expect(!coordinator.installHistoryNeedsHomeAccess)
        coordinator.provenanceCollection = true
        // Upgraders from 1.5 can have the toggle on but no grant for the real
        // home folder; the stored toggle is left alone and the state is shown.
        #expect(coordinator.installHistoryNeedsHomeAccess == !coordinator.provenanceAccessGranted)
        #expect(coordinator.provenanceCollection)
    }

    @Test("Unsaved note drafts are saved when the detail view goes away")
    func noteDraftAutosave() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AppCoordinator(dataDirectoryOverride: directory)
        let id = "brew::jq"
        // Untouched empty draft: nothing written.
        #expect(!coordinator.saveNoteDraftIfChanged("", for: id))
        #expect(!coordinator.saveNoteDraftIfChanged("  \n", for: id))
        #expect(coordinator.packageUserStates[id] == nil)
        // A typed draft is saved.
        #expect(coordinator.saveNoteDraftIfChanged("keep for work", for: id))
        #expect(coordinator.note(for: id) == "keep for work")
        // Unchanged draft: no write.
        #expect(!coordinator.saveNoteDraftIfChanged("keep for work", for: id))
        // Clearing the note on purpose is saved, like Save Note.
        #expect(coordinator.saveNoteDraftIfChanged("", for: id))
        #expect(coordinator.note(for: id) == nil)
    }

    @Test("Checkup actions route to the screen that explains each row")
    func checkupRowActions() {
        func row(_ area: CheckupArea, _ action: CheckupAction?) -> CheckupRow {
            CheckupRow(area: area, status: .good, headline: "", detail: "", action: action)
        }
        #expect(row(.installedTools, .reviewDuplicates).command == .navigate(.duplicates))
        #expect(row(.installedTools, .seePossiblyUnused).command == .navigate(.orphans))
        #expect(row(.installedTools, .seePossiblyUnused).actionTitle == "See possibly unused")
        #expect(row(.aiTools, .seeThisWeeksInstalls).command == .navigate(.aiInstalled))
        #expect(row(.space, .freeUpSpace).command == .navigate(.diskUsage))
        #expect(row(.space, .reviewSpace).command == .navigate(.diskUsage))
        #expect(row(.secrets, .grantHomeAccess).command == .grantHomeAccess)
        #expect(row(.aiTools, .openSettings).command == .openSettings)
        #expect(row(.aiTools, .reviewAITools).command == .navigate(.aiSetup))
        #expect(row(.aiTools, .seeAINotes).command == .navigate(.aiSetup))
        #expect(row(.secrets, .reviewKeys).command == .navigate(.aiSetup))
        #expect(row(.aiTools, .scan).command == .scan)
        // Routing depends only on the typed action, not the area or title.
        #expect(row(.space, .seePossiblyUnused).command == .navigate(.orphans))
        let none = row(.secrets, nil)
        #expect(none.command == nil)
        #expect(none.actionTitle == nil)
        #expect(none.statusAccessibilityLabel == "Looks good")
        // Every action has display text.
        #expect(CheckupAction.allCases.allSatisfy { !$0.title.isEmpty })
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
        noScanProblems: Bool = true,
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
            noScanProblems: noScanProblems,
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
        #expect(!ReviewPromptPolicy.shouldRequestReview(reviewContext(noScanProblems: false)))
        #expect(!ReviewPromptPolicy.shouldRequestReview(reviewContext(reclaimable: 0, allGood: true, noScanProblems: false)))
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
