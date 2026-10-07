import Foundation
import InstalloryCore
import Testing
@testable import Installory

private actor SnapshotCaptureProbe {
    private(set) var callCount = 0

    func recordCall() {
        callCount += 1
    }
}

private struct SnapshotCaptureTestError: Error, Sendable {}

private struct SnapshotListTestError: Error, Sendable {}

private actor SnapshotListProbe {
    private let summaries: [SnapshotSummary]
    private var fails = false

    init(summaries: [SnapshotSummary]) {
        self.summaries = summaries
    }

    func setFails(_ fails: Bool) {
        self.fails = fails
    }

    func list() throws -> [SnapshotSummary] {
        if fails { throw SnapshotListTestError() }
        return summaries
    }
}

private actor SnapshotListGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func list() async -> [SnapshotSummary] {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return []
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// Holds a snapshot capture open until the test releases it.
private actor CaptureGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    func capture() async {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor CompletionProbe {
    private(set) var completed = false

    func markCompleted() {
        completed = true
    }
}

@Suite("AppCoordinator persistence", .serialized)
@MainActor
struct AppCoordinatorPersistenceTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstalloryAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func package() -> Package {
        Package(
            id: "brew::ffmpeg",
            manager: .brew,
            qualifier: nil,
            name: "ffmpeg",
            version: "7.1",
            installPath: URL(fileURLWithPath: "/opt/homebrew/Cellar/ffmpeg/7.1"),
            installedAt: Date(timeIntervalSince1970: 1_720_000_000),
            installedAtConfidence: .high,
            sizeBytes: 42,
            isExplicit: true,
            isReadOnly: false,
            dependencies: [],
            lastSeen: Date(timeIntervalSince1970: 1_720_100_000)
        )
    }

    private func sortablePackage(id: String) -> Package {
        Package(
            id: id,
            manager: .brew,
            qualifier: nil,
            name: "same-name",
            version: "1.0",
            installPath: URL(fileURLWithPath: "/opt/homebrew/Cellar/same-name/1.0"),
            installedAt: Date(timeIntervalSince1970: 1_720_000_000),
            installedAtConfidence: .high,
            sizeBytes: 1_024,
            isExplicit: true,
            isReadOnly: false,
            dependencies: [],
            lastSeen: Date(timeIntervalSince1970: 1_720_100_000)
        )
    }

    private func scopedPackage(
        id: String,
        manager: PackageManager,
        name: String,
        qualifier: String? = nil,
        isReadOnly: Bool = false,
        sizeBytes: Int64? = 512
    ) -> Package {
        Package(
            id: id,
            manager: manager,
            qualifier: qualifier,
            name: name,
            version: "1.0",
            installPath: qualifier.map { URL(fileURLWithPath: $0) },
            installedAt: Date(timeIntervalSince1970: 1_720_000_000),
            installedAtConfidence: .medium,
            sizeBytes: sizeBytes,
            isExplicit: true,
            isReadOnly: isReadOnly,
            dependencies: [],
            lastSeen: Date(timeIntervalSince1970: 1_720_100_000)
        )
    }

    private func evidence(secret: String? = nil) -> ProvenanceEvidence {
        ProvenanceEvidence(
            packageId: "brew::ffmpeg",
            fsInstallTime: Date(timeIntervalSince1970: 1_720_000_000),
            fsInstallTimeSource: "INSTALL_RECEIPT.json",
            installCommand: ProvenanceEvidence.InstallCommandRecord(
                timestamp: Date(timeIntervalSince1970: 1_720_000_000),
                command: secret.map { "TOKEN=\($0) brew install ffmpeg" }
                    ?? "brew install ffmpeg",
                shell: .zsh,
                cwd: nil
            ),
            claudeCodeContext: nil,
            nearbyProjects: [],
            coInstalledWithin1h: [],
            overallConfidence: .high,
            collectedAt: Date(timeIntervalSince1970: 1_720_100_000)
        )
    }

    @Test("PERF25-007: database creation and migration are deferred until async hydration")
    func persistenceInitializationIsDeferred() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("deferred-cache", isDirectory: true)

        let coordinator = AppCoordinator(dataDirectoryOverride: directory)

        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(coordinator.database == nil)

        await coordinator.hydratePersistedState()

        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(coordinator.database != nil)
        #expect(coordinator.storageWarning == nil)
    }

    @Test("APP25-017: script writer propagates save failures instead of swallowing them")
    func scriptWriterReportsFailure() async {
        let invalidDestination = URL(fileURLWithPath: "/dev/null/installory-cleanup.sh")

        await #expect(throws: (any Error).self) {
            try await ScriptFileWriter.write("#!/bin/sh\n", to: invalidDestination)
        }
    }

    @Test("PERF25-012: background script writer preserves the complete output")
    func scriptWriterPersistsCompleteOutput() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("cleanup.sh")
        let script = "#!/bin/sh\nprintf '%s\\n' 'review me'\n"

        try await ScriptFileWriter.write(script, to: destination)

        #expect(try String(contentsOf: destination, encoding: .utf8) == script)
    }

    @Test("APP25-003: launch hydration restores packages, snapshots, and provenance with auto-scan disabled")
    func launchHydrationIsIndependentOfAutoScan() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try Database(directory: directory)
        let storedPackage = package()
        try PackageDAO(database: database).replaceAll(with: [storedPackage])
        try ScanRunDAO(database: database).save(ScanRun(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_720_000_000),
            completedAt: Date(timeIntervalSince1970: 1_720_000_100),
            perManagerResults: [.brew: .succeeded(count: 1, durationMs: 5)]
        ))
        _ = try await SnapshotManager(database: database).capture(
            packages: [storedPackage],
            reason: .manual,
            note: nil
        )
        try await ProvenanceDAO(database: database).upsert(evidence(secret: "stored-secret"))

        let coordinator = AppCoordinator(dataDirectoryOverride: directory)
        coordinator.scanOnLaunch = false
        await coordinator.hydratePersistedState()

        #expect(coordinator.packages.map(\.id) == [storedPackage.id])
        #expect(coordinator.snapshots.count == 1)
        #expect(coordinator.lastScanCompletedAt == Date(timeIntervalSince1970: 1_720_000_100))
        let hydrated = try #require(coordinator.provenanceByPackageId[storedPackage.id])
        #expect(hydrated.installCommand?.command == "TOKEN=[REDACTED] brew install ffmpeg")
        #expect(coordinator.storageWarning == nil)
        #expect(!coordinator.isScanning)
    }

    @Test("APP25-003: concurrent launch hydration joins the active cache load")
    func concurrentHydrationWaitsForTheActiveLoad() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = SnapshotListGate()
        let completion = CompletionProbe()
        let coordinator = AppCoordinator(
            dataDirectoryOverride: directory,
            snapshotListOverride: { await gate.list() }
        )

        let first = Task { @MainActor in
            await coordinator.hydratePersistedState()
        }
        await gate.waitUntilStarted()

        let second = Task { @MainActor in
            await coordinator.hydratePersistedState()
            await completion.markCompleted()
        }
        await Task.yield()
        #expect(await !completion.completed)

        await gate.release()
        await first.value
        await second.value
        #expect(await completion.completed)
    }

    @Test("PERF25-008: snapshot hydration retains summaries and lazily replaces one loaded payload")
    func snapshotPayloadsLoadOneAtATime() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try Database(directory: directory)
        let manager = SnapshotManager(database: database)
        let first = try await manager.capture(
            packages: [package()],
            reason: .manual,
            note: "first"
        )
        let second = try await manager.capture(
            packages: [sortablePackage(id: "brew::second")],
            reason: .preCleanup,
            note: "second"
        )

        let coordinator = AppCoordinator(dataDirectoryOverride: directory)
        coordinator.scanOnLaunch = false
        await coordinator.hydratePersistedState()

        #expect(Set(coordinator.snapshots.map(\.id)) == [first.id, second.id])
        #expect(coordinator.loadedSnapshot?.id == nil)

        let loadedFirst = try #require(await coordinator.loadSnapshot(id: first.id))
        #expect(loadedFirst.note == "first")
        #expect(coordinator.loadedSnapshot?.id == first.id)

        let loadedSecond = try #require(await coordinator.loadSnapshot(id: second.id))
        #expect(loadedSecond.note == "second")
        #expect(coordinator.loadedSnapshot?.id == second.id)
    }

    @Test("APP25-003: failed snapshot refresh preserves the last known history")
    func failedSnapshotRefreshPreservesHistory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let summary = SnapshotSummary(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_720_000_000),
            reason: .manual,
            note: "preserve me"
        )
        let probe = SnapshotListProbe(summaries: [summary])
        let coordinator = AppCoordinator(
            dataDirectoryOverride: directory,
            snapshotListOverride: { try await probe.list() }
        )

        await coordinator.hydratePersistedState()
        #expect(coordinator.snapshots.map(\.id) == [summary.id])

        await probe.setFails(true)
        await coordinator.refreshSnapshots()

        #expect(coordinator.snapshots.map(\.id) == [summary.id])
        #expect(coordinator.storageWarning?.contains("preserved") == true)
    }

    @Test("APP25-006: failed durable erase preserves visible evidence and reports an error")
    func failedEraseDoesNotClaimSuccess() async throws {
        struct EraseFailure: LocalizedError, Sendable {
            var errorDescription: String? { "simulated write failure" }
        }

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storedEvidence = evidence()
        let client = ProvenancePersistenceClient(
            fetchAll: { [storedEvidence] },
            upsertAll: { _ in },
            deleteAll: { throw EraseFailure() }
        )
        let coordinator = AppCoordinator(
            dataDirectoryOverride: directory,
            provenancePersistenceOverride: client
        )
        await coordinator.hydratePersistedState()
        #expect(coordinator.provenanceByPackageId["brew::ffmpeg"] != nil)

        await coordinator.clearProvenanceEvidence()

        #expect(coordinator.provenanceByPackageId["brew::ffmpeg"] != nil)
        #expect(coordinator.actionError?.contains("still on disk") == true)
        #expect(coordinator.actionError?.contains("simulated write failure") == true)
    }

    @Test("APP25-004: package path access uses the narrowest grant and balances its scope")
    func packagePathAccessIsNarrowAndBalanced() throws {
        let broadBookmark = Data([0x01])
        let narrowBookmark = Data([0x02])
        let target = URL(fileURLWithPath: "/grants/packages/tool/1.0")
        var startedBookmarks: [Data] = []
        var stoppedRoots: [URL] = []
        var operatedTargets: [URL] = []

        let result = FolderAccessManager.withAccessToGrantedPath(
            target,
            bookmarks: [
                (path: "/grants", bookmark: broadBookmark),
                (path: "/grants/packages", bookmark: narrowBookmark),
            ],
            startAccessing: { bookmark in
                startedBookmarks.append(bookmark)
                return URL(fileURLWithPath: "/grants/packages", isDirectory: true)
            },
            stopAccessing: { stoppedRoots.append($0) },
            operation: { scopedTarget in
                operatedTargets.append(scopedTarget)
                return "visited"
            }
        )

        #expect(result == "visited")
        #expect(startedBookmarks == [narrowBookmark])
        #expect(stoppedRoots.map(\.path) == ["/grants/packages"])
        #expect(operatedTargets.map(\.path) == [target.path])
    }

    @Test("SEC25-009: moved or broader bookmark resolution is rejected after balancing access")
    func movedBookmarkCannotBroadenPathAccess() {
        let target = URL(fileURLWithPath: "/grants/packages/tool/1.0")
        for resolvedRoot in ["/different/location", "/"] {
            var stopCount = 0
            var operationCount = 0

            let result: Bool? = FolderAccessManager.withAccessToGrantedPath(
                target,
                bookmarks: [(path: "/grants/packages", bookmark: Data([0x01]))],
                startAccessing: { _ in
                    URL(fileURLWithPath: resolvedRoot, isDirectory: true)
                },
                stopAccessing: { _ in stopCount += 1 },
                operation: { _ in
                    operationCount += 1
                    return true
                }
            )

            #expect(result == nil)
            #expect(stopCount == 1)
            #expect(operationCount == 0)
        }
    }

    @Test("APP25-012: moved bookmark roots are classified stale for re-grant")
    func movedBookmarkRootIsNotLoadedAsAnActiveGrant() {
        #expect(FolderAccessManager.bookmarkResolutionIsUsable(
            storedPath: "/grants/packages",
            resolvedURL: URL(fileURLWithPath: "/grants/packages", isDirectory: true),
            isStale: false
        ))
        #expect(!FolderAccessManager.bookmarkResolutionIsUsable(
            storedPath: "/grants/packages",
            resolvedURL: URL(fileURLWithPath: "/", isDirectory: true),
            isStale: false
        ))
        #expect(!FolderAccessManager.bookmarkResolutionIsUsable(
            storedPath: "/grants/packages",
            resolvedURL: URL(fileURLWithPath: "/grants/packages", isDirectory: true),
            isStale: true
        ))
    }

    @Test("APP25-007: requested cleanup snapshot without persistence is reported failed")
    func missingSnapshotPersistenceIsReportedAsFailure() async throws {
        let unavailableDirectory = URL(
            fileURLWithPath: "/dev/null/Installory-\(UUID().uuidString)",
            isDirectory: true
        )
        let coordinator = AppCoordinator(dataDirectoryOverride: unavailableDirectory)

        await coordinator.generateAndShowCleanupScript(
            packages: [package()],
            captureSnapshot: true
        )

        let result = try #require(coordinator.cleanupResult)
        #expect(!result.snapshotTaken)
        #expect(result.snapshotFailed)
    }

    @Test("QA-1.6: Skip Snapshot swaps the removal sheet to the script without a selection")
    func skipSnapshotShowsScript() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AppCoordinator(dataDirectoryOverride: directory)
        coordinator.snapshotBeforeRemoval = .ask
        // The detail pane may lose its selection while a scan lands; the
        // removal flow must not depend on it.
        coordinator.selectedPackage = nil

        await coordinator.requestRemoval([package()])
        #expect(coordinator.pendingRemovalPackages?.map(\.id) == ["brew::ffmpeg"])
        #expect(coordinator.isRemovalSheetPresented)
        #expect(coordinator.cleanupResult == nil)

        await coordinator.confirmRemoval(packages: [package()], takeSnapshot: false, remember: false)

        let result = try #require(coordinator.cleanupResult)
        #expect(result.script.scriptText.contains("ffmpeg"))
        #expect(!result.snapshotTaken)
        #expect(!result.snapshotFailed)
        #expect(coordinator.pendingRemovalPackages == nil)
        // Still one presented sheet, now showing the script.
        #expect(coordinator.isRemovalSheetPresented)
        #expect(coordinator.snapshotBeforeRemoval == .ask)

        coordinator.dismissRemovalSheet()
        #expect(coordinator.cleanupResult == nil)
        #expect(!coordinator.isRemovalSheetPresented)
    }

    @Test("QA-1.6: Take Snapshot keeps the removal sheet up until the script exists")
    func takeSnapshotKeepsSheetPresented() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = CaptureGate()
        let coordinator = AppCoordinator(
            dataDirectoryOverride: directory,
            snapshotCaptureOverride: { _, _, _ in
                await gate.capture()
                throw SnapshotCaptureTestError()
            }
        )
        coordinator.snapshotBeforeRemoval = .ask
        await coordinator.requestRemoval([package()])

        let confirm = Task { @MainActor in
            await coordinator.confirmRemoval(packages: [package()], takeSnapshot: true, remember: false)
        }
        await gate.waitUntilStarted()

        // Mid-capture: the question stays on screen (no dismissal gap) and
        // cannot be cancelled or dismissed out from under the capture.
        #expect(coordinator.isPreparingRemovalScript)
        #expect(coordinator.isRemovalSheetPresented)
        coordinator.cancelRemoval()
        coordinator.dismissRemovalSheet()
        #expect(coordinator.pendingRemovalPackages != nil)

        await gate.release()
        await confirm.value

        let result = try #require(coordinator.cleanupResult)
        #expect(result.snapshotFailed)
        #expect(!coordinator.isPreparingRemovalScript)
        #expect(coordinator.pendingRemovalPackages == nil)
        #expect(coordinator.isRemovalSheetPresented)
    }

    @Test("QA-1.6: removal flow uses one sheet; install history runs after the scan and is cancellable")
    func removalSheetAndInstallHistoryWiring() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let root = try String(
            contentsOf: sources.appendingPathComponent("Views/RootView.swift"),
            encoding: .utf8
        )
        #expect(root.components(separatedBy: "CleanupScriptSheetView(result:").count == 2)
        #expect(root.contains("coordinator.isRemovalSheetPresented"))
        #expect(!root.contains("get: { coordinator.pendingRemovalPackages != nil }"))

        let coordinator = try String(
            contentsOf: sources.appendingPathComponent("AppCoordinator.swift"),
            encoding: .utf8
        )
        // scan(), rescan(manager:) and Clear History each stop a running
        // collection before touching inventory or evidence.
        #expect(coordinator.components(separatedBy: "await cancelInstallHistoryCollection()").count == 4)
        #expect(coordinator.contains("startInstallHistoryCollection()"))
        #expect(coordinator.contains("cache: fileCache"))
        // rescan(manager:) restarts the collection it cancelled.
        let rescan = try #require(coordinator.range(of: "func rescan(manager: PackageManager) async {"))
        #expect(coordinator[rescan.upperBound...].prefix(700).contains("defer { startInstallHistoryCollection() }"))
        // Turning history off, revoking, demo mode and Clear History close the
        // cache-write gate synchronously before anything else.
        #expect(coordinator.contains("if !provenanceCollection { stopInstallHistoryCollection() }"))
        #expect(coordinator.components(separatedBy: "stopInstallHistoryCollection()").count >= 5)
        #expect(coordinator.contains("ProvenanceCollectionOutcome.merged("))
    }

    @Test("APP25-007: failed automatic first snapshot remains retryable")
    func failedFirstScanSnapshotDoesNotSetPreference() async throws {
        let defaults = UserDefaults.standard
        let preferenceKey = "app.installory.firstScanSnapshotTaken"
        let previousValue = defaults.object(forKey: preferenceKey)
        defaults.removeObject(forKey: preferenceKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: preferenceKey)
            } else {
                defaults.removeObject(forKey: preferenceKey)
            }
        }

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try Database(directory: directory)
        try PackageDAO(database: database).replaceAll(with: [package()])
        let probe = SnapshotCaptureProbe()
        let coordinator = AppCoordinator(
            dataDirectoryOverride: directory,
            snapshotCaptureOverride: { _, _, _ in
                await probe.recordCall()
                throw SnapshotCaptureTestError()
            }
        )
        await coordinator.hydratePersistedState()

        await coordinator.captureAutomaticFirstScanSnapshotIfNeeded()

        let callCount = await probe.callCount
        #expect(callCount == 1)
        #expect(!defaults.bool(forKey: preferenceKey))
    }

    @Test("APP25-014: hydration removes stale cleanup selections")
    func hydrationReconcilesCleanupSelection() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try Database(directory: directory)
        let storedPackage = package()
        try PackageDAO(database: database).replaceAll(with: [storedPackage])

        let coordinator = AppCoordinator(dataDirectoryOverride: directory)
        // Pin the section so a sidebar choice persisted by a local app run can't hide the package.
        coordinator.sidebarSelection = .all
        coordinator.selectedForCleanup = [storedPackage.id, "brew::no-longer-installed"]
        await coordinator.hydratePersistedState()

        #expect(coordinator.selectedForCleanup == [storedPackage.id])
    }

    @Test("APP25-015: sidebar changes clear details outside the visible section")
    func sidebarChangeReconcilesSelectedPackage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try Database(directory: directory)
        let storedPackage = package()
        try PackageDAO(database: database).replaceAll(with: [storedPackage])

        let coordinator = AppCoordinator(dataDirectoryOverride: directory)
        await coordinator.hydratePersistedState()
        coordinator.selectedPackage = storedPackage
        coordinator.sidebarSelection = .manager(.npm)

        coordinator.reconcileSelectedPackageForCurrentSidebar()

        #expect(coordinator.selectedPackage == nil)

        coordinator.selectedPackage = storedPackage
        coordinator.sidebarSelection = .manager(.brew)
        coordinator.reconcileSelectedPackageForCurrentSidebar()
        #expect(coordinator.selectedPackage?.id == storedPackage.id)

        coordinator.sidebarSelection = .snapshot(UUID())
        coordinator.reconcileSelectedPackageForCurrentSidebar()
        #expect(coordinator.selectedPackage == nil)
    }

    @Test("APP-F1: search reconciliation clears a detail that is no longer visible")
    func searchReconcilesSelectedPackage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try Database(directory: directory)
        let storedPackage = package()
        try PackageDAO(database: database).replaceAll(with: [storedPackage])

        let coordinator = AppCoordinator(dataDirectoryOverride: directory)
        await coordinator.hydratePersistedState()
        coordinator.sidebarSelection = .all
        coordinator.selectedPackage = storedPackage
        coordinator.searchQuery = "CELLAR/FFMPEG"
        coordinator.reconcileSelectedPackageForCurrentSidebar()
        #expect(coordinator.selectedPackage?.id == storedPackage.id)

        coordinator.searchQuery = "not-in-any-search-field"
        coordinator.reconcileSelectedPackageForCurrentSidebar()
        #expect(coordinator.selectedPackage == nil)
    }

    @Test("APP25-010: analysis emptiness is inconclusive only for failed, timed-out, or unknown coverage")
    func analysisEmptyStateReflectsCoverage() {
        let completeCoverage = Dictionary(
            uniqueKeysWithValues: PackageManager.allCases.map {
                ($0, ScannerStatus.succeeded(count: 0, durationMs: 1))
            }
        )
        var failedCoverage = completeCoverage
        failedCoverage[.npm] = .failed(reason: "fixture failure", durationMs: 1)
        var timedOutCoverage = completeCoverage
        timedOutCoverage[.cargo] = .timedOut(durationMs: 1)
        var skippedCoverage = completeCoverage
        skippedCoverage[.gem] = .skipped(reason: "RubyGems not installed")
        skippedCoverage[.uv] = .skipped(reason: "No uv tools directory")

        #expect(AnalysisEmptyState.resolve(
            packageCount: 0,
            isScanning: false,
            isDemoMode: false,
            scanStatuses: [:]
        ) == .noInventory)
        #expect(AnalysisEmptyState.resolve(
            packageCount: 2,
            isScanning: true,
            isDemoMode: false,
            scanStatuses: completeCoverage
        ) == .scanInProgress)
        #expect(AnalysisEmptyState.resolve(
            packageCount: 2,
            isScanning: false,
            isDemoMode: false,
            scanStatuses: [:]
        ) == .incompleteCoverage)
        #expect(AnalysisEmptyState.resolve(
            packageCount: 2,
            isScanning: false,
            isDemoMode: false,
            scanStatuses: failedCoverage
        ) == .incompleteCoverage)
        #expect(AnalysisEmptyState.resolve(
            packageCount: 2,
            isScanning: false,
            isDemoMode: false,
            scanStatuses: completeCoverage
        ) == .noResults)
        #expect(AnalysisEmptyState.resolve(
            packageCount: 2,
            isScanning: false,
            isDemoMode: false,
            scanStatuses: timedOutCoverage
        ) == .incompleteCoverage)
        // A manager the user simply doesn't have is not a coverage gap.
        #expect(AnalysisEmptyState.resolve(
            packageCount: 2,
            isScanning: false,
            isDemoMode: false,
            scanStatuses: skippedCoverage
        ) == .noResults)
        #expect(AnalysisEmptyState.resolve(
            packageCount: 0,
            isScanning: false,
            isDemoMode: false,
            scanStatuses: skippedCoverage
        ) == .noInventory)

        // A tool whose folder the sandbox refused is a coverage gap, not "not installed".
        var accessNeededCoverage = skippedCoverage
        accessNeededCoverage[.cargo] = .skipped(reason: ScanCoordinator.accessNeededReason)
        #expect(AnalysisEmptyState.resolve(
            packageCount: 2,
            isScanning: false,
            isDemoMode: false,
            scanStatuses: accessNeededCoverage
        ) == .foldersNotGranted)
        // A real failure still wins over a missing grant.
        accessNeededCoverage[.npm] = .failed(reason: "fixture failure", durationMs: 1)
        #expect(AnalysisEmptyState.resolve(
            packageCount: 2,
            isScanning: false,
            isDemoMode: false,
            scanStatuses: accessNeededCoverage
        ) == .incompleteCoverage)
    }

    @Test("Scan Coverage tells 'not granted' apart from 'not installed'")
    func accessNeededCoverageCopy() {
        let accessNeeded = ScannerStatus.skipped(reason: ScanCoordinator.accessNeededReason)
        #expect(accessNeeded.isAccessNeeded)
        #expect(!ScannerStatus.skipped(reason: "RubyGems not installed").isAccessNeeded)
        #expect(!ScannerStatus.failed(reason: ScanCoordinator.accessNeededReason, durationMs: 1).isAccessNeeded)
        #expect(ScannerStatus.friendlyAccessNeededDescription == "Allow access to its folder to include it")
    }

    @Test("Rating prompt is requested after the AI setup audit so the checkup is current")
    func reviewRequestFollowsAgentConfigAudit() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppCoordinator.swift"),
            encoding: .utf8
        )
        let scanStart = try #require(source.range(of: "    func scan(userInitiated: Bool = false) async {"))
        let scanBody = source[scanStart.upperBound...]
        let audit = try #require(scanBody.range(of: "await runAgentConfigAudit(grantedURLs: accessedURLs)"))
        let review = try #require(scanBody.range(of: "if userInitiated {\n            requestReviewIfAppropriate()"))
        #expect(audit.upperBound <= review.lowerBound)
    }

    @Test("Rating prompt never follows the automatic launch scan")
    func reviewRequestOnlyAfterUserInitiatedScan() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppCoordinator.swift"),
            encoding: .utf8
        )
        func body(of signature: String) throws -> Substring {
            let start = try #require(source.range(of: signature))
            let rest = source[start.upperBound...]
            let end = rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex
            return rest[..<end]
        }
        let autoScan = try body(of: "    func autoScanIfNeeded() async {")
        #expect(autoScan.contains("await scan()"))
        #expect(!autoScan.contains("userInitiated: true"))
        let refresh = try body(of: "    func refresh() async {")
        #expect(refresh.contains("await scan(userInitiated: true)"))
        // The only call to the prompt is the gated one inside scan().
        #expect(source.components(separatedBy: "requestReviewIfAppropriate()").count == 3)
    }

    @Test("Sidebar rows don't use .badge, which breaks List selection on macOS")
    func sidebarRowsAvoidBadge() throws {
        let sidebar = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Views/SidebarView.swift"),
            encoding: .utf8
        )
        // A .badge on the AI Setup NavigationLink made clicks clear the
        // selection, so the row never opened AI Setup (found in 1.6.0 QA).
        #expect(!sidebar.contains(".badge("))
    }

    @Test("Views reset per item and keep relative times fresh")
    func viewIdentityAndTimelineWiring() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Views")
        let root = try String(contentsOf: views.appendingPathComponent("RootView.swift"), encoding: .utf8)
        let snapshot = try #require(root.range(of: "SnapshotContentView(snapshotID: id)"))
        #expect(root[snapshot.upperBound...].prefix(200).contains(".id(id)"))
        let dashboard = try String(contentsOf: views.appendingPathComponent("DashboardView.swift"), encoding: .utf8)
        #expect(dashboard.contains("TimelineView(.periodic(from: .now, by: 60))"))
        #expect(dashboard.contains("lastScanSummary(relativeTo: now)"))
        let sidebar = try String(contentsOf: views.appendingPathComponent("SidebarView.swift"), encoding: .utf8)
        #expect(sidebar.contains("TimelineView(.periodic(from: .now, by: 30))"))
        #expect(sidebar.contains("lastScanSummary(relativeTo: context.date)"))
        let aiSetup = try String(contentsOf: views.appendingPathComponent("AISetupView.swift"), encoding: .utf8)
        #expect(aiSetup.contains("TimelineView(.periodic(from: .now, by: 30))"))
        #expect(aiSetup.contains("checkedLine(now: context.date)"))
        let detail = try String(contentsOf: views.appendingPathComponent("PackageDetailView.swift"), encoding: .utf8)
        #expect(detail.contains("coordinator.saveNoteDraftIfChanged(noteDraft, for: package.id)"))
    }

    @Test("Last scanned text is computed relative to the given time")
    func lastScanSummaryRelativeTime() {
        let scannedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let soon = AppCoordinator.lastScanSummary(for: scannedAt, relativeTo: scannedAt.addingTimeInterval(60))
        let later = AppCoordinator.lastScanSummary(for: scannedAt, relativeTo: scannedAt.addingTimeInterval(3 * 3600))
        #expect(soon != later)
        #expect(soon?.hasPrefix("Last scanned") == true)
        #expect(AppCoordinator.lastScanSummary(for: nil, relativeTo: scannedAt) == nil)
    }

    @Test("APP-F2: Duplicates and Review Candidates expose cleanup controls")
    func cleanupModeDestinationCapabilities() {
        #expect(SidebarSelection.all.supportsCleanupControls)
        #expect(SidebarSelection.manager(.pip).supportsCleanupControls)
        #expect(SidebarSelection.duplicates.supportsCleanupControls)
        #expect(SidebarSelection.orphans.supportsCleanupControls)
        #expect(!SidebarSelection.readOnly.supportsCleanupControls)
        #expect(!SidebarSelection.diskUsage.supportsCleanupControls)
        #expect(!SidebarSelection.aiInstalled.supportsCleanupControls)
        #expect(!SidebarSelection.snapshot(UUID()).supportsCleanupControls)
    }

    @Test("Layout: selection-free destinations use the full window width")
    func destinationLayouts() {
        #expect(SidebarSelection.dashboard.destinationLayout == .fullWidth)
        #expect(SidebarSelection.projects.destinationLayout == .fullWidth)
        #expect(SidebarSelection.aiSetup.destinationLayout == .fullWidth)
        #expect(!SidebarSelection.aiSetup.supportsCleanupControls)
        #expect(!SidebarSelection.aiSetup.hasSearchField)
        #expect(SidebarSelection.snapshot(UUID()).destinationLayout == .fullWidth)
        #expect(SidebarSelection.all.destinationLayout == .listWithDetail)
        #expect(SidebarSelection.manager(.npm).destinationLayout == .listWithDetail)
        #expect(SidebarSelection.diskUsage.destinationLayout == .listWithDetail)
        #expect(SidebarSelection.aiInstalled.destinationLayout == .listWithDetail)
    }

    @Test("Find: ⌘F is offered only where a search field exists")
    func findCommandAvailability() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AppCoordinator(dataDirectoryOverride: directory)
        coordinator.sidebarSelection = .dashboard
        #expect(!coordinator.canFocusSearch)
        coordinator.sidebarSelection = .all
        #expect(coordinator.canFocusSearch)
        #expect(SidebarSelection.skills.hasSearchField)
        #expect(!SidebarSelection.diskUsage.hasSearchField)
    }

    @Test("Grant panel shows hidden files for dot-folders and home")
    func grantPanelHiddenFiles() {
        let home = UserHome.directory
        #expect(FolderAccessManager.shouldShowHiddenFiles(for: nil))
        #expect(FolderAccessManager.shouldShowHiddenFiles(for: home))
        #expect(FolderAccessManager.shouldShowHiddenFiles(for: home.appendingPathComponent(".claude")))
        #expect(!FolderAccessManager.shouldShowHiddenFiles(for: URL(fileURLWithPath: "/usr")))
    }

    @Test("VoiceOver reads a human removal-safety label")
    func removalSafetyLabels() {
        #expect(RemovalSafetyBadge.label(for: .leaveAlone) == "Leave alone")
        #expect(RemovalSafetyBadge.label(for: .safe) == "Safe to remove")
    }

    @Test("APP-F2: sidebar reconciliation removes cleanup selections outside the new scope")
    func cleanupSelectionReconcilesToSidebarScope() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try Database(directory: directory)
        let brew = package()
        let npm = scopedPackage(id: "npm::typescript", manager: .npm, name: "typescript")
        try PackageDAO(database: database).replaceAll(with: [brew, npm])

        let coordinator = AppCoordinator(dataDirectoryOverride: directory)
        await coordinator.hydratePersistedState()
        coordinator.isCleanupMode = true
        coordinator.selectedForCleanup = [brew.id, npm.id]
        coordinator.sidebarSelection = .manager(.brew)

        coordinator.reconcileCleanupSelectionForCurrentSidebar()

        #expect(coordinator.selectedForCleanup == [brew.id])
        #expect(coordinator.isCleanupMode)

        coordinator.sidebarSelection = .readOnly
        coordinator.reconcileCleanupSelectionForCurrentSidebar()
        #expect(coordinator.selectedForCleanup.isEmpty)
        #expect(!coordinator.isCleanupMode)
    }

    @Test("APP-F2: duplicate cleanup scope deduplicates overlapping analysis groups")
    func duplicateCleanupScopeIsUnique() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try Database(directory: directory)
        let brew = scopedPackage(id: "brew::ruff", manager: .brew, name: "ruff")
        let pipA = scopedPackage(
            id: "pip:/python-a:ruff",
            manager: .pip,
            name: "ruff",
            qualifier: "/python-a"
        )
        let pipB = scopedPackage(
            id: "pip:/python-b:ruff",
            manager: .pip,
            name: "ruff",
            qualifier: "/python-b"
        )
        try PackageDAO(database: database).replaceAll(with: [brew, pipA, pipB])

        let coordinator = AppCoordinator(dataDirectoryOverride: directory)
        await coordinator.hydratePersistedState()
        coordinator.sidebarSelection = .duplicates

        #expect(Set(coordinator.cleanupPackagesForCurrentSection.map(\.id)) == [
            brew.id,
            pipA.id,
            pipB.id,
        ])
        #expect(coordinator.cleanupPackagesForCurrentSection.count == 3)
    }

    @Test("APP25-022: every package sort has a stable identity tie-breaker")
    func packageSortsAreDeterministicWhenPrimaryKeysTie() {
        let laterIdentity = sortablePackage(id: "z-package")
        let earlierIdentity = sortablePackage(id: "a-package")

        for order in PackageSortOrder.allCases {
            #expect(
                [laterIdentity, earlierIdentity].sorted(by: order).map(\.id)
                    == [earlierIdentity.id, laterIdentity.id],
                "Missing deterministic tie-breaker for \(order.rawValue)"
            )
        }
    }

    @Test("APP-F3: coordinator round-trips independent List and Table presentation preferences")
    func inventoryPresentationPreferencesRoundTrip() throws {
        let defaults = UserDefaults.standard
        let keys = [
            "app.installory.ui.sortOrder",
            "app.installory.ui.inventoryViewMode",
            "app.installory.ui.tableSortOrder",
        ]
        var previous: [String: Any] = [:]
        for key in keys {
            previous[key] = defaults.object(forKey: key)
        }
        for key in keys { defaults.removeObject(forKey: key) }
        defer {
            for key in keys {
                if let value = previous[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = AppCoordinator(dataDirectoryOverride: directory)
        first.sortOrder = .oldestFirst
        first.inventoryViewMode = .table
        first.tableSortOrder = [
            PackageTableSortDescriptor(column: .size, direction: .descending),
            PackageTableSortDescriptor(column: .name, direction: .ascending),
        ]
        first.persistUIPreferences()

        let restored = AppCoordinator(dataDirectoryOverride: directory)
        #expect(restored.sortOrder == .oldestFirst)
        #expect(restored.inventoryViewMode == .table)
        #expect(restored.tableSortOrder == first.tableSortOrder)
    }

    @Test("APP-F3: corrupt Table preferences restore safely without changing List sort")
    func corruptInventoryPresentationPreferencesRestoreSafely() throws {
        let defaults = UserDefaults.standard
        let sortKey = "app.installory.ui.sortOrder"
        let modeKey = "app.installory.ui.inventoryViewMode"
        let tableKey = "app.installory.ui.tableSortOrder"
        let keys = [sortKey, modeKey, tableKey]
        var previous: [String: Any] = [:]
        for key in keys {
            previous[key] = defaults.object(forKey: key)
        }
        defer {
            for key in keys {
                if let value = previous[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        defaults.set(PackageSortOrder.managerThenName.rawValue, forKey: sortKey)
        defaults.set("future-mode", forKey: modeKey)
        defaults.set(Data("not valid descriptor JSON".utf8), forKey: tableKey)

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AppCoordinator(dataDirectoryOverride: directory)

        #expect(coordinator.sortOrder == .managerThenName)
        #expect(coordinator.inventoryViewMode == .list)
        #expect(coordinator.tableSortOrder == PackageTableSortDescriptor.defaultOrder)
    }

    @Test("APP-F3: view-mode commands only affect ordinary inventory sections")
    func inventoryViewModeScopeIsTruthful() throws {
        let defaults = UserDefaults.standard
        let keys = [
            "app.installory.ui.sortOrder",
            "app.installory.ui.inventoryViewMode",
            "app.installory.ui.tableSortOrder",
            "app.installory.ui.sidebarSelection",
        ]
        var previous: [String: Any] = [:]
        for key in keys {
            previous[key] = defaults.object(forKey: key)
        }
        defer {
            for key in keys {
                if let value = previous[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AppCoordinator(dataDirectoryOverride: directory)

        for selection in [
            SidebarSelection.all,
            .manager(.pip),
            .readOnly,
        ] {
            coordinator.sidebarSelection = selection
            #expect(coordinator.supportsInventoryViewMode)
            coordinator.showInventory(as: .table)
            #expect(coordinator.inventoryViewMode == .table)
            coordinator.showInventory(as: .list)
            #expect(coordinator.inventoryViewMode == .list)
        }

        for selection in [
            SidebarSelection.duplicates,
            .orphans,
            .diskUsage,
            .aiInstalled,
            .snapshot(UUID()),
        ] {
            coordinator.sidebarSelection = selection
            #expect(!coordinator.supportsInventoryViewMode)
            coordinator.showInventory(as: .table)
            #expect(coordinator.inventoryViewMode == .list)
        }
    }

    @Test("PERF25-009: repeated derived reads reuse one inventory generation")
    func repeatedDerivedReadsUseCache() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AppCoordinator(dataDirectoryOverride: directory)
        coordinator.enterDemoMode()

        _ = coordinator.inventoryIndex
        _ = coordinator.inventoryIndex
        _ = coordinator.duplicateGroups
        _ = coordinator.duplicateGroups
        _ = coordinator.multiLocationGroups
        _ = coordinator.multiLocationGroups
        _ = coordinator.orphanedPackages
        _ = coordinator.orphanedPackages
        _ = coordinator.aiInstalledPackages
        _ = coordinator.aiInstalledPackages
        _ = coordinator.duplicateAnalysis(pathComponents: ["/opt/homebrew/bin"])
        _ = coordinator.duplicateAnalysis(pathComponents: ["/opt/homebrew/bin"])

        let counts = coordinator.inventoryDerivedComputationCounts
        #expect(counts.inventoryIndex == 1)
        #expect(counts.duplicateGroups == 1)
        #expect(counts.multiLocationGroups == 1)
        #expect(counts.orphanedPackages == 1)
        #expect(counts.aiInstalledPackages == 1)
        #expect(counts.duplicatePathAnalysis == 1)
    }

    @Test("PERF25-009: package mutation invalidates inventory-derived values")
    func packageMutationInvalidatesDerivedCache() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AppCoordinator(dataDirectoryOverride: directory)
        coordinator.enterDemoMode()

        _ = coordinator.inventoryIndex
        _ = coordinator.duplicateGroups
        _ = coordinator.orphanedPackages
        let firstCounts = coordinator.inventoryDerivedComputationCounts

        // Re-seeding assigns a fresh package generation even when its fixture
        // contents happen to be equal to the previous demo inventory.
        coordinator.enterDemoMode()
        _ = coordinator.inventoryIndex
        _ = coordinator.duplicateGroups
        _ = coordinator.orphanedPackages
        let secondCounts = coordinator.inventoryDerivedComputationCounts

        #expect(secondCounts.inventoryIndex == firstCounts.inventoryIndex + 1)
        #expect(secondCounts.duplicateGroups == firstCounts.duplicateGroups + 1)
        #expect(secondCounts.orphanedPackages == firstCounts.orphanedPackages + 1)
    }

    @Test("APP-F4: disk-usage aggregation cache reuses and invalidates by inventory generation")
    func diskUsageSummaryUsesInventoryCache() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = AppCoordinator(dataDirectoryOverride: directory)
        coordinator.enterDemoMode()

        _ = coordinator.diskUsageSummary
        _ = coordinator.diskUsageSummary
        let firstCounts = coordinator.inventoryDerivedComputationCounts
        #expect(firstCounts.diskUsageSummary == 1)

        coordinator.enterDemoMode()
        _ = coordinator.diskUsageSummary
        let secondCounts = coordinator.inventoryDerivedComputationCounts
        #expect(secondCounts.diskUsageSummary == firstCounts.diskUsageSummary + 1)
    }

    @Test("APP-F4: Disk Usage sidebar selection persists through coordinator preferences")
    func diskUsageSidebarSelectionPersists() throws {
        let defaults = UserDefaults.standard
        let key = "app.installory.ui.sidebarSelection"
        let previous = defaults.object(forKey: key)
        defaults.set("diskUsage", forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let restored = AppCoordinator(dataDirectoryOverride: directory)
        #expect(restored.sidebarSelection == .diskUsage)

        restored.sidebarSelection = .all
        restored.persistUIPreferences()
        #expect(defaults.string(forKey: key) == "all")
        restored.sidebarSelection = .diskUsage
        restored.persistUIPreferences()
        #expect(defaults.string(forKey: key) == "diskUsage")
    }

    @Test("APP-F4: Disk Usage detail selection must remain in the current top ten")
    func diskUsageSelectionReconcilesToLargestPackages() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try Database(directory: directory)
        let packages = (1...11).map { rank in
            scopedPackage(
                id: "brew::rank-\(rank)",
                manager: .brew,
                name: "rank-\(rank)",
                sizeBytes: Int64(rank)
            )
        }
        try PackageDAO(database: database).replaceAll(with: packages)

        let coordinator = AppCoordinator(dataDirectoryOverride: directory)
        await coordinator.hydratePersistedState()
        coordinator.sidebarSelection = .diskUsage

        coordinator.selectedPackage = packages[0]
        coordinator.reconcileSelectedPackageForCurrentSidebar()
        #expect(coordinator.selectedPackage == nil)

        let largest = try #require(coordinator.diskUsageSummary.largestPackages.first)
        coordinator.selectedPackage = largest
        coordinator.reconcileSelectedPackageForCurrentSidebar()
        #expect(coordinator.selectedPackage?.id == largest.id)
    }

    @Test("PERF25-009: provenance mutation invalidates AI state only")
    func provenanceMutationInvalidatesAIDerivedCache() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ProvenancePersistenceClient(
            fetchAll: { [] },
            upsertAll: { _ in },
            deleteAll: {}
        )
        let coordinator = AppCoordinator(
            dataDirectoryOverride: directory,
            provenancePersistenceOverride: persistence
        )
        coordinator.enterDemoMode()

        _ = coordinator.aiInstalledPackages
        _ = coordinator.aiInstalledPackages
        _ = coordinator.duplicateGroups
        let firstCounts = coordinator.inventoryDerivedComputationCounts

        await coordinator.clearProvenanceEvidence()
        _ = coordinator.aiInstalledPackages
        _ = coordinator.aiInstalledPackages
        _ = coordinator.duplicateGroups
        let secondCounts = coordinator.inventoryDerivedComputationCounts

        #expect(secondCounts.aiInstalledPackages == firstCounts.aiInstalledPackages + 1)
        #expect(secondCounts.duplicateGroups == firstCounts.duplicateGroups)
    }
}
