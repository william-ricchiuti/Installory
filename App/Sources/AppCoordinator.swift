import AppKit
import InstalloryCore
import Foundation
import UniformTypeIdentifiers

/// The result of a cleanup-script generation, carrying both the script and
/// the snapshot outcome. The sheet uses these flags to decide what status to show:
///  - `snapshotTaken == true`: snapshot was captured successfully.
///  - `snapshotFailed == true`: snapshot was requested but could not be saved.
///  - Both false: user chose to skip the snapshot (Never preference or explicit skip).
struct CleanupResult: Identifiable {
    let id = UUID()
    let script: GeneratedScript
    let restoreScript: GeneratedReinstallScript
    let snapshotTaken: Bool
    let snapshotFailed: Bool
}

typealias SnapshotCaptureOperation = @Sendable (
    _ packages: [Package],
    _ reason: SnapshotReason,
    _ note: String?
) async throws -> Snapshot

typealias SnapshotListOperation = @Sendable () async throws -> [SnapshotSummary]

private struct PersistenceResources: Sendable {
    let database: Database
    let packageDAO: PackageDAO
    let scanRunDAO: ScanRunDAO
    let snapshotManager: SnapshotManager
    let provenanceDAO: ProvenanceDAO
    let packageUserStateDAO: PackageUserStateDAO
}

private enum PersistenceInitializationResult: Sendable {
    case ready(PersistenceResources)
    case failed(String)
}

/// Canonical UserDefaults key names. The original product was named "Backshelf";
/// keys carry an `app.installory.` prefix today and a one-time migration in
/// `init` copies any pre-existing `backshelf.` keys forward so settings survive
/// the rename without orphaning anyone.
private enum DefaultsKey {
    static let onboardingCompleted   = "app.installory.onboarding.completed"
    static let sortOrder             = "app.installory.ui.sortOrder"
    static let inventoryViewMode     = "app.installory.ui.inventoryViewMode"
    static let tableSortOrder        = "app.installory.ui.tableSortOrder"
    static let sidebarSelection      = "app.installory.ui.sidebarSelection"
    static let snapshotBeforeRemoval = "app.installory.settings.snapshotBeforeRemoval"
    static let removalStrategy       = "app.installory.settings.removalStrategy"
    static let scanOnLaunch          = "app.installory.settings.scanOnLaunch"
    static let firstScanTaken        = "app.installory.firstScanSnapshotTaken"
    static let migrationCompleted    = "app.installory.migration.fromBackshelf"
    static let provenanceCollection  = "app.installory.settings.provenanceCollection"
}

@Observable
@MainActor
final class AppCoordinator {
    // MARK: - Scan state

    private(set) var packages: [Package] = [] {
        didSet { inventoryDerivedCache.invalidateInventory() }
    }
    private(set) var scanStatuses: [PackageManager: ScannerStatus] = [:]
    private(set) var isScanning = false
    private(set) var lastScanCompletedAt: Date?

    /// Non-nil when local persistence is unavailable — the SQLite cache couldn't
    /// be opened, or a save failed. The UI surfaces this so results that silently
    /// won't be remembered between launches don't look like a mysterious bug.
    private(set) var storageWarning: String?

    /// Managers whose scan is currently in flight, used for per-manager progress
    /// in the scanning empty state.
    private(set) var inFlightManagers: Set<PackageManager> = []

    // MARK: - UI state

    var searchQuery: String = ""
    var sidebarSelection: SidebarSelection? = .dashboard
    var sortOrder: PackageSortOrder = .recentlyInstalled
    var inventoryViewMode: InventoryViewMode = .list
    var tableSortOrder: [PackageTableSortDescriptor] = PackageTableSortDescriptor.defaultOrder
    var selectedPackage: Package?

    /// Incremented by ⌘F; searchable views observe it to focus their field.
    private(set) var searchFocusRequest = 0

    /// True when the current destination shows a search field.
    var canFocusSearch: Bool {
        sidebarSelection?.hasSearchField ?? false
    }

    /// Focuses the visible search field (Edit ▸ Find Packages, ⌘F).
    func focusSearch() {
        guard canFocusSearch else { return }
        if #available(macOS 15.0, *) {
            searchFocusRequest &+= 1
        } else {
            SearchFieldFocuser.focusSearchField(in: NSApp.keyWindow ?? NSApp.mainWindow)
        }
    }

    /// A user-initiated action failed. Presented as an alert and cleared on dismiss.
    ///
    /// Distinct from `storageWarning`, which is an ambient banner about the local cache:
    /// this reports that the thing the user just asked for did not happen.
    private(set) var actionError: String?

    func dismissActionError() {
        actionError = nil
    }

    // MARK: - Snapshot state

    /// Snapshot history is metadata-only. Exactly one full payload is retained
    /// after the user selects it.
    private(set) var snapshots: [SnapshotSummary] = []
    private(set) var loadedSnapshot: Snapshot?
    private var snapshotManager: SnapshotManager?
    private var snapshotCapture: SnapshotCaptureOperation?
    private var snapshotList: SnapshotListOperation?
    private var snapshotLoadRequestID: UUID?
    /// Demo snapshots cannot use persistence, so keep their encoded form and
    /// decode only the selected payload, matching production memory behavior.
    private var demoSnapshotDataByID: [UUID: Data] = [:]

    // MARK: - Baseline state

    /// An imported snapshot payload captured elsewhere (typically another Mac)
    /// that the live inventory is compared against.
    private(set) var baselinePayload: SnapshotPayload?

    /// The change set between the imported baseline and the live inventory.
    var baselineChangeSet: SnapshotChangeSet? {
        guard let baselinePayload else { return nil }
        return Baseline.changes(from: baselinePayload, to: packages)
    }

    // MARK: - Cleanup state

    var selectedForCleanup: Set<String> = []
    var isCleanupMode: Bool = false
    var cleanupResult: CleanupResult? = nil

    // MARK: - Onboarding

    var onboardingCompleted: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.onboardingCompleted)

    // MARK: - Demo mode

    /// When true, the app is showing pre-populated sample data instead of a real
    /// scan. Demo mode is fully self-contained: it never reads the filesystem,
    /// writes to the database, or makes network calls. It exists so the app's
    /// full feature set can be verified on a machine with no package managers
    /// installed (for example, App Review's clean test device).
    private(set) var isDemoMode: Bool = false

    /// True when the process was launched in demo mode via `-demo` argument or
    /// the `INSTALLORY_DEMO=1` environment variable. Lets App Review script the
    /// demo without any clicks.
    private static var demoLaunchRequested: Bool {
        CommandLine.arguments.contains("-demo")
            || ProcessInfo.processInfo.environment["INSTALLORY_DEMO"] == "1"
    }

    // MARK: - Settings

    var snapshotBeforeRemoval: SnapshotPreference = .ask
    var removalStrategy: RemovalStrategy = .uninstall
    var scanOnLaunch: Bool = true

    /// When true, Installory reads shell history and Claude Code session logs
    /// during scans to build install-origin evidence per package.
    ///
    /// Defaults to `false`. The collectors must never be called until the user
    /// explicitly opts in via Settings → Privacy → Provenance.
    var provenanceCollection: Bool = false

    // MARK: - Removal flow (coordinator-driven "Ask" dialog)

    /// Non-nil when the user triggered a per-package removal and the snapshot
    /// preference is `.ask`. RootView presents the snapshot-choice sheet while
    /// this is set; the sheet clears it on confirm or cancel.
    var pendingRemovalPackages: [Package]? = nil

    // MARK: - Description corpus

    private(set) var descriptionStore: DescriptionStore = DescriptionStore()

    // MARK: - Infrastructure

    let folderAccess = FolderAccessManager()
    @ObservationIgnored private let inventoryDerivedCache = InventoryDerivedCache()
    private(set) var database: Database?
    private var packageDAO: PackageDAO?
    private var scanRunDAO: ScanRunDAO?
    private var provenancePersistence: ProvenancePersistenceClient?
    private var packageUserStateDAO: PackageUserStateDAO?
    private var dataDirectory: URL?
    @ObservationIgnored private var persistenceInitializationTask: Task<
        PersistenceInitializationResult,
        Never
    >?
    private var hasHydratedPersistedState = false
    private var isHydratingPersistedState = false
    @ObservationIgnored private var hydrationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Provenance evidence keyed by package ID. Populated after opted-in scans;
    /// demo mode supplies its own bundled sample evidence.
    private(set) var provenanceByPackageId: [String: ProvenanceEvidence] = [:] {
        didSet { inventoryDerivedCache.invalidateProvenance() }
    }

    /// Per-package user annotations (hidden, pinned, note) keyed by package ID.
    private(set) var packageUserStates: [String: PackageUserState] = [:]

    /// Development projects discovered under the user's granted project
    /// directories. In-memory only — recomputed on each scan, never persisted.
    private(set) var projectWorkspaces: [ProjectWorkspace] = []

    /// Minimum interval between automatic scans triggered by `autoScanIfNeeded`.
    /// Manual `refresh()` ignores this — the user pressing ⌘R always rescans.
    private static let autoScanCooldown: TimeInterval = 60

    // MARK: - Computed: provenance access

    /// True when a security-scoped bookmark covering the user's home directory
    /// exists in `FolderAccessManager`, indicating the user has granted read
    /// access for provenance collection.
    var provenanceAccessGranted: Bool {
        let homePath = UserHome.directory.path
        return folderAccess.grantedPath(covering: homePath) != nil
    }

    // MARK: - Init

    init(
        dataDirectoryOverride: URL? = nil,
        provenancePersistenceOverride: ProvenancePersistenceClient? = nil,
        snapshotCaptureOverride: SnapshotCaptureOperation? = nil,
        snapshotListOverride: SnapshotListOperation? = nil
    ) {
        migrateLegacyDefaultsIfNeeded()
        snapshotCapture = snapshotCaptureOverride
        snapshotList = snapshotListOverride
        provenancePersistence = provenancePersistenceOverride

        let defaultDataDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("Installory", isDirectory: true)
        if let dir = dataDirectoryOverride ?? defaultDataDirectory {
            dataDirectory = dir
        } else {
            storageWarning = "Couldn't locate Application Support, so scan results won't be saved between launches."
        }

        folderAccess.loadPersistedBookmarks()
        restoreUIPreferences()
        restoreSettings()
        loadDescriptionStoreInBackground()

        // Allow App Review (or anyone) to launch straight into demo mode without
        // any clicks, via `-demo` or INSTALLORY_DEMO=1.
        if Self.demoLaunchRequested {
            enterDemoMode()
        }
    }

    // MARK: - Defaults migration

    /// Copies legacy `backshelf.*` keys to their `app.installory.*` equivalents
    /// the first time the renamed app launches. Old keys are left in place so a
    /// downgrade still finds its settings.
    private func migrateLegacyDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: DefaultsKey.migrationCompleted) else { return }

        let pairs: [(legacy: String, current: String, kind: DefaultsKind)] = [
            ("backshelf.onboarding.completed",            DefaultsKey.onboardingCompleted,   .bool),
            ("backshelf.ui.sortOrder",                    DefaultsKey.sortOrder,             .string),
            ("backshelf.ui.sidebarSelection",             DefaultsKey.sidebarSelection,      .string),
            ("backshelf.settings.snapshotBeforeRemoval",  DefaultsKey.snapshotBeforeRemoval, .string),
            ("backshelf.settings.scanOnLaunch",           DefaultsKey.scanOnLaunch,          .bool),
            ("backshelf.firstScanSnapshotTaken",          DefaultsKey.firstScanTaken,        .bool),
            ("backshelf.settings.provenanceCollection",   DefaultsKey.provenanceCollection,  .bool),
        ]
        for pair in pairs {
            guard defaults.object(forKey: pair.legacy) != nil,
                  defaults.object(forKey: pair.current) == nil
            else { continue }
            switch pair.kind {
            case .bool:
                defaults.set(defaults.bool(forKey: pair.legacy), forKey: pair.current)
            case .string:
                if let value = defaults.string(forKey: pair.legacy) {
                    defaults.set(value, forKey: pair.current)
                }
            }
        }
        defaults.set(true, forKey: DefaultsKey.migrationCompleted)
    }
    private enum DefaultsKind { case bool, string }

    // MARK: - Demo mode actions

    /// Loads the bundled sample inventory and snapshots into memory and switches
    /// the app into demo mode. No filesystem, database, or network access occurs.
    func enterDemoMode() {
        isDemoMode = true
        isScanning = false
        searchQuery = ""
        sidebarSelection = .all
        selectedPackage = nil
        isCleanupMode = false
        selectedForCleanup = []
        packages = DemoData.packages()
        replaceDemoSnapshots(with: DemoData.snapshots())
        scanStatuses = [:]
        lastScanCompletedAt = Date()
        provenanceByPackageId = DemoData.demoProvenanceByPackageId()
        // Dismiss onboarding for the demo session without persisting the flag —
        // a developer who runs `-demo` once shouldn't permanently skip onboarding.
        onboardingCompleted = true
    }

    /// Leaves demo mode and restores the real (possibly empty) local state.
    func exitDemoMode() {
        isDemoMode = false
        packages = []
        lastScanCompletedAt = nil
        snapshots = []
        loadedSnapshot = nil
        snapshotLoadRequestID = nil
        demoSnapshotDataByID = [:]
        scanStatuses = [:]
        selectedPackage = nil
        isCleanupMode = false
        selectedForCleanup = []
        searchQuery = ""
        sidebarSelection = .all
        provenanceByPackageId = [:]
        onboardingCompleted = UserDefaults.standard.bool(forKey: DefaultsKey.onboardingCompleted)
        hasHydratedPersistedState = false
        Task {
            await hydratePersistedState()
            await autoScanIfNeeded()
        }
    }

    // MARK: - Computed: packages

    /// Package IDs the user has pinned. Used by the List and Table presentations
    /// to float pinned packages to the top after their own sort is applied.
    var pinnedIDs: Set<String> {
        Set(packageUserStates.filter { $0.value.isPinned }.map(\.key))
    }

    /// Order-preserving source shared by List and Table presentation. Each mode
    /// applies only its own persisted sort preference after filtering.
    var filteredPackageSource: [Package] {
        packages
            .filter { !isHidden($0.id) }
            .filtered(by: sidebarSelection, query: searchQuery)
    }

    // MARK: - Computed: package user annotations

    func userState(for packageID: String) -> PackageUserState? {
        packageUserStates[packageID]
    }

    func isHidden(_ packageID: String) -> Bool {
        packageUserStates[packageID]?.isHidden ?? false
    }

    func isPinned(_ packageID: String) -> Bool {
        packageUserStates[packageID]?.isPinned ?? false
    }

    func note(for packageID: String) -> String? {
        packageUserStates[packageID]?.note
    }

    var supportsInventoryViewMode: Bool {
        switch sidebarSelection {
        case nil, .all, .manager, .readOnly:
            true
        case .dashboard, .duplicates, .orphans, .diskUsage, .aiInstalled, .skills, .projects, .snapshot:
            false
        }
    }

    func showInventory(as mode: InventoryViewMode) {
        guard supportsInventoryViewMode else { return }
        inventoryViewMode = mode
        persistUIPreferences()
    }

    var inventoryIndex: InventoryIndex {
        inventoryDerivedCache.index(for: packages)
    }

    func package(id: String) -> Package? {
        inventoryIndex.packagesByID[id]
    }

    var duplicateGroups: [DuplicateGroup] {
        inventoryDerivedCache.duplicateGroups(for: packages)
    }

    var multiLocationGroups: [MultiLocationGroup] {
        inventoryDerivedCache.multiLocationGroups(for: packages)
    }

    /// Explicitly-installed packages that have no in-inventory dependents within
    /// their own package manager. See ``DependencyAnalysis`` for caveats.
    var orphanedPackages: [Package] {
        inventoryDerivedCache.orphanedPackages(for: packages)
    }

    /// Agent skills — `.agentSkill` packages across every discovered tool root.
    var agentSkillPackages: [Package] {
        packages.filter { $0.manager == .agentSkill }
    }

    /// Review aggregate over the agent-skills inventory.
    var agentStackAnalysis: AgentStackAnalysis {
        inventoryDerivedCache.agentStackAnalysis(for: packages)
    }

    /// Reverse-dependency index over the installed package graph (what depends on what).
    var reverseDependencyIndex: ReverseDependencyIndex {
        inventoryDerivedCache.reverseDependencyIndex(for: packages)
    }

    /// Per-package removal-safety verdicts, keyed by package ID.
    var removalSafetyByPackageID: [String: RemovalSafetyVerdict] {
        inventoryDerivedCache.removalSafety(for: packages)
    }

    /// The removal-safety verdict for a single package.
    func removalSafety(for package: Package) -> RemovalSafetyVerdict {
        removalSafetyByPackageID[package.id]
            ?? RemovalSafetyVerdict(safety: .caution, reasons: [])
    }

    /// Packages whose provenance evidence indicates installation during an AI assistant session.
    /// Empty when provenance collection is off or no evidence is attributed to an AI session.
    var aiInstalledPackages: [Package] {
        inventoryDerivedCache.aiInstalledPackages(
            for: packages,
            provenance: provenanceByPackageId
        )
    }

    var diskUsageSummary: DiskUsageSummary {
        inventoryDerivedCache.diskUsageSummary(for: packages)
    }

    /// Ranked safe-to-remove candidates plus their combined reclaimable payload.
    var freeUpSpaceBundle: FreeUpSpaceBundle {
        inventoryDerivedCache.freeUpSpaceBundle(for: packages)
    }

    /// Discovered project workspaces, oldest-touched first (unlnown dates last).
    var sortedProjectWorkspaces: [ProjectWorkspace] {
        ProjectWorkspaceAnalysis.sortedByStaleness(projectWorkspaces)
    }

    /// Workspaces whose last modification predates the staleness threshold.
    var staleProjectWorkspaces: [ProjectWorkspace] {
        let now = Date()
        return sortedProjectWorkspaces.filter {
            ProjectWorkspaceAnalysis.isStale($0, now: now)
        }
    }

    func duplicateAnalysis(pathComponents: [String]) -> DuplicateAnalysisState {
        inventoryDerivedCache.duplicateAnalysis(
            for: packages,
            pathComponents: pathComponents
        )
    }

    /// Packages the current sidebar section may include in a generated removal
    /// script. Search does not change this scope, so an explicit selection can
    /// remain checked while temporarily filtered from view.
    var cleanupPackagesForCurrentSection: [Package] {
        let candidates: [Package]
        switch sidebarSelection {
        case nil, .all:
            candidates = packages
        case .manager(let manager):
            candidates = packages.filter { $0.manager == manager }
        case .duplicates:
            let ids = Set(
                duplicateGroups.flatMap { $0.packages.map(\.id) }
                    + multiLocationGroups.flatMap { $0.packages.map(\.id) }
            )
            candidates = packages.filter { ids.contains($0.id) }
        case .orphans:
            candidates = orphanedPackages
        case .skills:
            candidates = packages.filter { $0.manager == .agentSkill }
        case .dashboard, .readOnly, .diskUsage, .aiInstalled, .projects, .snapshot:
            candidates = []
        }
        return candidates
            .filter { !isHidden($0.id) }
            .filter(\.isRemovalScriptEligible)
    }

    var canEnterCleanupMode: Bool {
        !cleanupPackagesForCurrentSection.isEmpty
    }

    var selectedCleanupPackages: [Package] {
        cleanupPackagesForCurrentSection.filter { selectedForCleanup.contains($0.id) }
    }

    /// Prevents a selection made in one analysis from leaking into a script
    /// generated from another sidebar section.
    func reconcileCleanupSelectionForCurrentSidebar() {
        let eligibleIDs = Set(cleanupPackagesForCurrentSection.map(\.id))
        selectedForCleanup.formIntersection(eligibleIDs)
        if eligibleIDs.isEmpty, isCleanupMode {
            isCleanupMode = false
        }
    }

    /// Test instrumentation for generation reuse and invalidation. The cache is
    /// observation-ignored, so reading these counters never drives UI updates.
    var inventoryDerivedComputationCounts: InventoryDerivedComputationCounts {
        inventoryDerivedCache.computationCounts
    }

    /// Drops cleanup/detail selections that no longer refer to a usable package
    /// after inventory replacement, then ensures the detail package belongs to
    /// the currently visible sidebar section.
    func reconcileInventorySelections() {
        reconcileCleanupSelectionForCurrentSidebar()
        selectedPackage = selectedPackage.flatMap { package(id: $0.id) }
        reconcileSelectedPackageForCurrentSidebar()
    }

    /// Keeps the detail column consistent with the content column whenever the
    /// sidebar changes. Dedicated analysis sections have their own package sets;
    /// snapshots never display a live-inventory package detail.
    func reconcileSelectedPackageForCurrentSidebar() {
        guard let selectedPackage = selectedPackage.flatMap({ package(id: $0.id) }) else {
            self.selectedPackage = nil
            return
        }
        self.selectedPackage = selectedPackage
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchesSearch = query.isEmpty || selectedPackage.matchesSearchQuery(query)

        let remainsVisible: Bool
        switch sidebarSelection {
        case nil, .all:
            remainsVisible = matchesSearch
        case .manager(let manager):
            remainsVisible = selectedPackage.manager == manager && matchesSearch
        case .readOnly:
            remainsVisible = selectedPackage.isReadOnly && matchesSearch
        case .duplicates:
            let duplicateIDs = Set(
                duplicateGroups
                    .filter { group in
                        query.isEmpty || group.packages.contains { $0.matchesSearchQuery(query) }
                    }
                    .flatMap { $0.packages.map(\.id) }
                    + multiLocationGroups
                        .filter { group in
                            query.isEmpty || group.packages.contains { $0.matchesSearchQuery(query) }
                        }
                        .flatMap { $0.packages.map(\.id) }
            )
            remainsVisible = duplicateIDs.contains(selectedPackage.id)
        case .orphans:
            remainsVisible = matchesSearch
                && orphanedPackages.contains { $0.id == selectedPackage.id }
        case .diskUsage:
            remainsVisible = diskUsageSummary.largestPackages.contains {
                $0.id == selectedPackage.id
            }
        case .aiInstalled:
            remainsVisible = matchesSearch
                && aiInstalledPackages.contains { $0.id == selectedPackage.id }
        case .skills:
            remainsVisible = matchesSearch
                && packages.contains { $0.id == selectedPackage.id && $0.manager == .agentSkill }
        case .dashboard, .projects, .snapshot:
            remainsVisible = false
        }

        if !remainsVisible {
            self.selectedPackage = nil
        }
    }

    // MARK: - Computed: directories

    var grantedDirectories: [GrantedDirectory] {
        folderAccess.grantedBookmarks().map {
            GrantedDirectory(path: $0.path, bookmark: $0.bookmark)
        }
    }

    var ungrantedCanonicalDirectories: [CanonicalDirectory] {
        return CanonicalDirectory.all(isAppleSilicon: isAppleSilicon)
            .filter { folderAccess.grantedPath(covering: $0.path) == nil }
    }

    // MARK: - Computed: status

    var statusSummary: String {
        if isScanning {
            let names = inFlightManagers.map(\.displayName).sorted()
            return names.isEmpty ? "Scanning…" : "Scanning \(names.joined(separator: ", "))…"
        }
        let pkgs = packages.count
        let managers = Set(packages.map(\.manager)).count
        if pkgs == 0 {
            return "Ready — no packages scanned yet."
        }
        let pkgWord = pkgs == 1 ? "package" : "packages"
        let mgrWord = managers == 1 ? "manager" : "managers"
        return "\(pkgs) \(pkgWord) across \(managers) \(mgrWord)."
    }

    var lastScanSummary: String? {
        guard let date = lastScanCompletedAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last scanned \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    /// Per-manager status entries (managers that ran or were skipped/failed),
    /// sorted by display name. Used by the "Scan coverage" view.
    var scanCoverage: [(manager: PackageManager, status: ScannerStatus)] {
        scanStatuses
            .map { ($0.key, $0.value) }
            .sorted { $0.0.displayName < $1.0.displayName }
    }

    /// Managers whose last scan failed or timed out. Used by the aggregated
    /// "Some scans failed" banner above the package list.
    var failedManagers: [(PackageManager, String)] {
        scanStatuses.compactMap { (manager, status) -> (PackageManager, String)? in
            switch status {
            case .failed(let reason, _): return (manager, reason)
            case .timedOut:              return (manager, "Scan timed out")
            default:                     return nil
            }
        }
        .sorted { $0.0.displayName < $1.0.displayName }
    }

    // MARK: - Actions

    /// Toggles a package's hidden flag. Hidden packages drop out of the
    /// inventory list and are never proposed for cleanup, but stay tracked so
    /// the flag can be undone from package detail.
    func toggleHidden(_ packageID: String) {
        let existing = packageUserStates[packageID]
        updateUserState(
            packageID: packageID,
            isHidden: !(existing?.isHidden ?? false),
            isPinned: existing?.isPinned ?? false,
            note: existing?.note
        )
    }

    /// Toggles a package's pinned flag, which pins it to the top of the
    /// inventory list regardless of sort order.
    func togglePinned(_ packageID: String) {
        let existing = packageUserStates[packageID]
        updateUserState(
            packageID: packageID,
            isHidden: existing?.isHidden ?? false,
            isPinned: !(existing?.isPinned ?? false),
            note: existing?.note
        )
    }

    /// Sets (or clears, when `note` is empty) the free-form note attached to a
    /// package.
    func setNote(_ note: String, for packageID: String) {
        let existing = packageUserStates[packageID]
        updateUserState(
            packageID: packageID,
            isHidden: existing?.isHidden ?? false,
            isPinned: existing?.isPinned ?? false,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : note
        )
    }

    private func updateUserState(
        packageID: String,
        isHidden: Bool,
        isPinned: Bool,
        note: String?
    ) {
        let state = PackageUserState(
            packageId: packageID,
            isHidden: isHidden,
            isPinned: isPinned,
            note: note,
            updatedAt: Date()
        )
        packageUserStates[packageID] = state
        if let dao = packageUserStateDAO {
            Task.detached(priority: .utility) { [state] in
                try? await dao.upsert(state)
            }
        }
    }

    /// Opens and migrates the SQLite cache away from MainActor. The task is
    /// shared by every caller so launch hydration and an early user action can
    /// never race two database initializations.
    private func initializePersistenceIfNeeded() async -> Bool {
        if database != nil { return true }
        guard let directory = dataDirectory else { return false }

        if persistenceInitializationTask == nil {
            // The cache gates visible launch state, so create its pool at
            // user-initiated QoS while still keeping migration off MainActor.
            // GRDB's internal queues inherit this context; utility QoS here can
            // otherwise trigger priority inversion when the UI awaits a read.
            persistenceInitializationTask = Task.detached(priority: .userInitiated) {
                do {
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: true
                    )
                    let database = try Database(directory: directory)
                    return .ready(PersistenceResources(
                        database: database,
                        packageDAO: PackageDAO(database: database),
                        scanRunDAO: ScanRunDAO(database: database),
                        snapshotManager: SnapshotManager(database: database),
                        provenanceDAO: ProvenanceDAO(database: database),
                        packageUserStateDAO: PackageUserStateDAO(database: database)
                    ))
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
        }

        guard let result = await persistenceInitializationTask?.value else {
            return false
        }
        if database != nil { return true }

        switch result {
        case .ready(let resources):
            database = resources.database
            packageDAO = resources.packageDAO
            scanRunDAO = resources.scanRunDAO
            snapshotManager = resources.snapshotManager
            if snapshotCapture == nil {
                let manager = resources.snapshotManager
                snapshotCapture = { packages, reason, note in
                    try await manager.capture(
                        packages: packages,
                        reason: reason,
                        note: note
                    )
                }
            }
            if snapshotList == nil {
                let manager = resources.snapshotManager
                snapshotList = { try await manager.list() }
            }
            if provenancePersistence == nil {
                provenancePersistence = ProvenancePersistenceClient(
                    dao: resources.provenanceDAO
                )
            }
            packageUserStateDAO = resources.packageUserStateDAO
            storageWarning = nil
            return true
        case .failed(let reason):
            storageWarning = "Couldn't open the local cache, so scan results won't be saved between launches. \(reason)"
            return false
        }
    }

    /// Loads every persisted UI surface independently of the scan-on-launch
    /// preference. Opening/migrating SQLite and reads that can block use a
    /// detached task; actor-backed snapshot/provenance reads suspend MainActor.
    func hydratePersistedState() async {
        guard !isDemoMode, !hasHydratedPersistedState else {
            return
        }
        if isHydratingPersistedState {
            await withCheckedContinuation { continuation in
                hydrationWaiters.append(continuation)
            }
            return
        }
        isHydratingPersistedState = true
        defer {
            isHydratingPersistedState = false
            let waiters = hydrationWaiters
            hydrationWaiters.removeAll(keepingCapacity: true)
            for waiter in waiters {
                waiter.resume()
            }
        }

        guard await initializePersistenceIfNeeded() else {
            hasHydratedPersistedState = true
            return
        }

        var failures: [String] = []

        if let dao = packageDAO {
            do {
                let loaded = try await Task.detached(priority: .utility) {
                    try dao.loadAll()
                }.value
                guard !isDemoMode else { return }
                packages = loaded
                reconcileInventorySelections()
            } catch {
                failures.append("package inventory")
            }
        }

        if let dao = scanRunDAO {
            do {
                let loaded = try await Task.detached(priority: .utility) {
                    try dao.mostRecentCompletedAt()
                }.value
                guard !isDemoMode else { return }
                lastScanCompletedAt = loaded
            } catch {
                failures.append("last scan date")
            }
        }

        if let snapshotList {
            do {
                let loaded = try await snapshotList()
                guard !isDemoMode else { return }
                replaceSnapshotSummaries(with: loaded)
            } catch {
                failures.append("snapshots")
            }
        }

        if let persistence = provenancePersistence {
            do {
                let loaded = try await persistence.fetchAll()
                guard !isDemoMode else { return }
                provenanceByPackageId = Dictionary(
                    loaded.map { ($0.packageId, $0) },
                    uniquingKeysWith: { _, newest in newest }
                )
            } catch {
                failures.append("install history")
            }
        }

        if let dao = packageUserStateDAO {
            do {
                let loaded = try await Task.detached(priority: .utility) {
                    try await dao.fetchAll()
                }.value
                guard !isDemoMode else { return }
                packageUserStates = Dictionary(
                    loaded.map { ($0.packageId, $0) },
                    uniquingKeysWith: { _, newest in newest }
                )
            } catch {
                failures.append("package annotations")
            }
        }

        guard !isDemoMode else { return }
        hasHydratedPersistedState = true
        if failures.isEmpty {
            storageWarning = nil
        } else {
            storageWarning = "Couldn't load \(failures.joined(separator: ", ")) from the local cache. Your on-disk data was left unchanged."
        }
    }

    func autoScanIfNeeded() async {
        guard !isDemoMode else { return }
        await hydratePersistedState()
        guard folderAccess.hasAnyGrant, scanOnLaunch else { return }
        if let last = lastScanCompletedAt, Date().timeIntervalSince(last) < Self.autoScanCooldown {
            return
        }
        // "Scan on launch" means a real rescan (cooldown-gated above); the
        // saved inventory from hydration is shown until it finishes.
        await scan()
        await refreshSnapshots()
    }

    /// Loads a baseline payload from a user-selected JSON file (sandbox read
    /// access is granted by the open panel).
    func importBaseline(from url: URL) async throws {
        let data = try Data(contentsOf: url)
        let payload = try JSONDecoder().decode(SnapshotPayload.self, from: data)
        baselinePayload = payload
        actionError = nil
    }

    /// Drops the imported baseline; the live inventory is unchanged.
    func clearBaseline() {
        baselinePayload = nil
    }

    /// Presents an open panel (granting sandbox read access) and imports the
    /// chosen snapshot JSON as the comparison baseline.
    func pickBaselineFile() async {
        let panel = NSOpenPanel()
        panel.title = "Import Baseline"
        panel.message = "Choose a snapshot JSON captured on another Mac to compare against this inventory."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The open panel grants the sandbox read access for the selected file.
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            try await importBaseline(from: url)
        } catch {
            actionError = "Couldn\u{2019}t import baseline. \(error.localizedDescription)"
        }
    }


    func refresh() async {
        // In demo mode a "scan" just re-seeds the sample inventory — there is
        // nothing on disk to read.
        guard !isDemoMode else {
            enterDemoMode()
            return
        }
        await hydratePersistedState()
        await scan()
        await refreshSnapshots()
    }

    /// Rescan just one manager, leaving the rest of the inventory in place.
    /// Useful after the user fixes a perms issue or grants a new directory.
    func rescan(manager: PackageManager) async {
        guard !isDemoMode, !isScanning else { return }
        isScanning = true
        inFlightManagers = [manager]
        defer {
            isScanning = false
            inFlightManagers = []
        }

        var accessedURLs: [URL] = []
        for (_, data) in folderAccess.grantedBookmarks() {
            if let url = folderAccess.startAccessing(data) {
                accessedURLs.append(url)
            }
        }
        defer { for url in accessedURLs { folderAccess.stopAccessing(url) } }

        guard let scanner = scanner(for: manager, grantedURLs: accessedURLs) else { return }
        let coordinator = ScanCoordinator(scanners: [scanner])
        let managedManagers = scanner.managedPackageManagers

        // Build into a local array so `packages` changes exactly once, as `scan()`
        // does. Mutating it twice inside the event loop flickers the list.
        var updated = packages
        var updatedStatuses = scanStatuses
        for await event in await coordinator.scan() {
            if case let .scannerFinished(_, status, pkgs) = event {
                for managedManager in managedManagers {
                    updatedStatuses[managedManager] = partitionStatus(
                        status,
                        for: managedManager,
                        packages: pkgs
                    )
                }
                updated = ScanInventoryReconciler.reconcile(
                    existing: updated,
                    scanned: pkgs,
                    managedManagers: managedManagers,
                    status: status
                )
            }
        }
        guard !Task.isCancelled else { return }
        packages = updated
        scanStatuses = updatedStatuses
        reconcileInventorySelections()
        lastScanCompletedAt = Date()
        if let dao = packageDAO {
            let persistedPackages = packages
            do {
                try await Task.detached(priority: .utility) {
                    try dao.replaceAll(with: persistedPackages)
                }.value
                storageWarning = nil
            } catch {
                storageWarning = "Couldn't save the latest scan to the local cache, so it won't be remembered next launch."
            }
        }
    }

    @discardableResult
    func grantDirectory(suggestedPath: String) async -> Bool {
        guard await folderAccess.requestAccess(to: URL(fileURLWithPath: suggestedPath)) != nil else {
            return false
        }
        Task { await refresh() }
        return true
    }

    @discardableResult
    func grantCustomDirectory() async -> Bool {
        guard await folderAccess.requestAccess(to: nil) != nil else { return false }
        Task { await refresh() }
        return true
    }

    func persistUIPreferences() {
        UserDefaults.standard.set(sortOrder.rawValue, forKey: DefaultsKey.sortOrder)
        InventoryPresentationPreferences(
            viewMode: inventoryViewMode,
            tableSortOrder: tableSortOrder
        ).persist(
            to: UserDefaults.standard,
            viewModeKey: DefaultsKey.inventoryViewMode,
            tableSortOrderKey: DefaultsKey.tableSortOrder
        )
        if let sel = sidebarSelection, case .snapshot = sel {
            return  // do not persist snapshot selection — the ID may not exist on next launch
        }
        if let sel = sidebarSelection {
            UserDefaults.standard.set(sel.userDefaultsKey, forKey: DefaultsKey.sidebarSelection)
        }
    }

    func persistSettings() {
        UserDefaults.standard.set(
            snapshotBeforeRemoval.rawValue,
            forKey: DefaultsKey.snapshotBeforeRemoval
        )
        UserDefaults.standard.set(
            removalStrategy.rawValue,
            forKey: DefaultsKey.removalStrategy
        )
        UserDefaults.standard.set(scanOnLaunch, forKey: DefaultsKey.scanOnLaunch)
        UserDefaults.standard.set(provenanceCollection, forKey: DefaultsKey.provenanceCollection)
    }

    func completeOnboarding() {
        onboardingCompleted = true
        UserDefaults.standard.set(true, forKey: DefaultsKey.onboardingCompleted)
    }

    /// Re-show the onboarding sheet on next view appearance. Used by Settings.
    func resetOnboarding() {
        onboardingCompleted = false
        UserDefaults.standard.set(false, forKey: DefaultsKey.onboardingCompleted)
    }

    /// Reveals the local data directory (Application Support/Installory) in Finder
    /// so users can see exactly what Installory persists.
    func revealDataFolder() {
        guard let dir = dataDirectory else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// Checks an external package path only while its narrowest covering
    /// security-scoped bookmark is active.
    func packageInstallPathExists(at installPath: URL) -> Bool {
        folderAccess.grantedItemExists(at: installPath)
    }

    /// Reveals an external package path without extending or persisting access.
    @discardableResult
    func revealPackageInstallPath(at installPath: URL) -> Bool {
        folderAccess.revealGrantedItemInFinder(at: installPath)
    }

    /// Renders and writes a Markdown environment report to a user-chosen path.
    @discardableResult
    func exportEnvironmentReport() async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Environment Report"
        panel.nameFieldStringValue = "installory-environment-report.md"
        if let type = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // NSSavePanel implicitly starts security-scoped access for its URL.
        defer { url.stopAccessingSecurityScopedResource() }
        let exportPackages = packages
        let exportDuplicateGroups = duplicateGroups
        let exportOrphans = orphanedPackages
        let exportDate = Date()
        do {
            try await Task.detached(priority: .utility) {
                let content = EnvironmentReportRenderer().render(
                    packages: exportPackages,
                    duplicateGroups: exportDuplicateGroups,
                    orphans: exportOrphans,
                    now: exportDate
                )
                try content.write(to: url, atomically: true, encoding: .utf8)
            }.value
            actionError = nil
            return url
        } catch {
            actionError = "Couldn't write the environment report to \(url.lastPathComponent). \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func exportInventory(format: InventoryExporter.Format) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Inventory"
        panel.nameFieldStringValue = "installory-inventory.\(format.fileExtension)"
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // NSSavePanel implicitly starts security-scoped access for its URL.
        defer { url.stopAccessingSecurityScopedResource() }
        let exportPackages = packages
        do {
            try await Task.detached(priority: .utility) {
                let content = InventoryExporter().export(exportPackages, format: format)
                try content.write(to: url, atomically: true, encoding: .utf8)
            }.value
            actionError = nil
            return url
        } catch {
            actionError = "Couldn't write the inventory to \(url.lastPathComponent). \(error.localizedDescription)"
            return nil
        }
    }

    func refreshSnapshots() async {
        // Demo snapshots live only in memory — never overwrite them from the DB.
        guard !isDemoMode else { return }
        guard let snapshotList else { return }
        do {
            let refreshed = try await snapshotList()
            guard !isDemoMode, !Task.isCancelled else { return }
            replaceSnapshotSummaries(with: refreshed)
        } catch is CancellationError {
            return
        } catch {
            // Preserve the last known list. A transient read error must not make
            // durable snapshots appear deleted.
            storageWarning = "Couldn't refresh saved snapshots from the local cache. Your existing snapshot list was preserved."
        }
    }

    /// Loads one full snapshot payload on demand. A request token prevents a
    /// slower prior selection from replacing a newer one after actor reentrancy.
    func loadSnapshot(id: UUID) async -> Snapshot? {
        snapshotLoadRequestID = id

        guard snapshots.contains(where: { $0.id == id }) else {
            if loadedSnapshot?.id == id {
                loadedSnapshot = nil
            }
            return nil
        }
        if loadedSnapshot?.id == id {
            return loadedSnapshot
        }

        let loaded: Snapshot?
        if isDemoMode {
            loaded = demoSnapshotDataByID[id].flatMap {
                try? JSONDecoder().decode(Snapshot.self, from: $0)
            }
        } else if let manager = snapshotManager {
            loaded = try? await manager.snapshot(id: id)
        } else {
            loaded = nil
        }

        guard snapshotLoadRequestID == id,
              snapshots.contains(where: { $0.id == id }) else {
            return nil
        }
        loadedSnapshot = loaded
        return loaded
    }

    func captureManualSnapshot() async {
        // In demo mode, capture a snapshot in memory so the flow is demonstrable
        // without writing to the database.
        if isDemoMode {
            insertDemoSnapshot(DemoData.makeSnapshot(reason: .manual, from: packages))
            return
        }
        guard let capture = snapshotCapture else {
            actionError = "Couldn't take a snapshot: the local cache isn't available."
            return
        }
        do {
            _ = try await capture(packages, .manual, nil)
            actionError = nil
        } catch {
            actionError = "Couldn't take a snapshot. \(error.localizedDescription)"
        }
        await refreshSnapshots()
    }

    /// Captures the automatic first-scan snapshot and records the preference
    /// only after the snapshot has been durably inserted. A missing cache or a
    /// write failure leaves the preference false so a later scan can retry.
    func captureAutomaticFirstScanSnapshotIfNeeded() async {
        guard !isDemoMode,
              !packages.isEmpty,
              !UserDefaults.standard.bool(forKey: DefaultsKey.firstScanTaken),
              let capture = snapshotCapture else {
            return
        }

        do {
            _ = try await capture(packages, .autoFirstScan, nil)
            UserDefaults.standard.set(true, forKey: DefaultsKey.firstScanTaken)
            await refreshSnapshots()
        } catch {
            // The next successful scan retries. Do not claim a snapshot exists
            // when the database write did not complete.
        }
    }

    // MARK: - Removal flow

    /// Entry point for all per-package removal. Checks the snapshot preference
    /// and either proceeds immediately or raises pending-removal state so RootView
    /// can present the snapshot-choice sheet. Both the detail pane and the row
    /// context menu call this method — one code path regardless of entry point.
    func requestRemoval(_ packages: [Package]) async {
        guard !packages.isEmpty else { return }
        switch snapshotBeforeRemoval {
        case .always:
            await generateAndShowCleanupScript(packages: packages, captureSnapshot: true)
        case .never:
            await generateAndShowCleanupScript(packages: packages, captureSnapshot: false)
        case .ask:
            pendingRemovalPackages = packages
        }
    }

    /// Called by SnapshotChoiceSheet when the user answers the snapshot question.
    /// Clears the pending state (dismisses the sheet), optionally persists the choice,
    /// then proceeds to script generation.
    func confirmRemoval(packages: [Package], takeSnapshot: Bool, remember: Bool) async {
        if remember {
            snapshotBeforeRemoval = takeSnapshot ? .always : .never
            persistSettings()
        }
        pendingRemovalPackages = nil
        await generateAndShowCleanupScript(packages: packages, captureSnapshot: takeSnapshot)
    }

    /// Called when the user dismisses the snapshot-choice sheet without choosing.
    func cancelRemoval() {
        pendingRemovalPackages = nil
    }

    /// Generates a cleanup script, optionally capturing a snapshot first.
    func generateAndShowCleanupScript(packages packagesToRemove: [Package], captureSnapshot: Bool) async {
        guard !packagesToRemove.isEmpty else { return }

        var snapshotCtx: SnapshotContext? = nil
        var snapshotFailed = false
        if captureSnapshot, isDemoMode {
            let snap = DemoData.makeSnapshot(reason: .preCleanup, from: packagesToRemove)
            if insertDemoSnapshot(snap) {
                snapshotCtx = SnapshotContext(id: snap.id, createdAt: snap.createdAt)
            } else {
                snapshotFailed = true
            }
        } else if captureSnapshot {
            if let capture = snapshotCapture {
                if let snap = try? await capture(packagesToRemove, .preCleanup, nil) {
                    snapshotCtx = SnapshotContext(id: snap.id, createdAt: snap.createdAt)
                    await refreshSnapshots()
                } else {
                    snapshotFailed = true
                }
            } else {
                snapshotFailed = true
            }
        }

        let generator = ScriptGenerator()
        let script = generator.generate(packages: packagesToRemove, snapshot: snapshotCtx, strategy: removalStrategy)
        let restoreScript = ReinstallScriptGenerator().generate(removing: packagesToRemove)
        cleanupResult = CleanupResult(
            script: script,
            restoreScript: restoreScript,
            snapshotTaken: snapshotCtx != nil,
            snapshotFailed: snapshotFailed
        )
    }

    private func replaceSnapshotSummaries(with summaries: [SnapshotSummary]) {
        snapshots = summaries
        let retainedIDs = Set(summaries.map(\.id))
        if let loadedID = loadedSnapshot?.id, !retainedIDs.contains(loadedID) {
            loadedSnapshot = nil
        }
        if let requestedID = snapshotLoadRequestID, !retainedIDs.contains(requestedID) {
            snapshotLoadRequestID = nil
        }
    }

    private func replaceDemoSnapshots(with fullSnapshots: [Snapshot]) {
        loadedSnapshot = nil
        snapshotLoadRequestID = nil
        demoSnapshotDataByID = [:]
        snapshots = []

        for snapshot in fullSnapshots {
            guard let data = try? JSONEncoder().encode(snapshot) else { continue }
            demoSnapshotDataByID[snapshot.id] = data
            snapshots.append(SnapshotSummary(snapshot: snapshot))
        }
    }

    @discardableResult
    private func insertDemoSnapshot(_ snapshot: Snapshot) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            actionError = "Couldn't keep the demo snapshot in memory."
            return false
        }
        demoSnapshotDataByID[snapshot.id] = data
        snapshots.insert(SnapshotSummary(snapshot: snapshot), at: 0)
        actionError = nil
        return true
    }

    // MARK: - Provenance actions

    /// Presents an `NSOpenPanel` pre-navigated to the user's home directory so
    /// the user can grant Installory read access to their shell history and agent
    /// session logs. The resulting security-scoped bookmark is stored in
    /// `FolderAccessManager` and persisted to UserDefaults.
    ///
    /// The open panel title and surrounding Settings UI copy explicitly name what
    /// will be read: `~/.zsh_history`, `~/.bash_history`,
    /// `~/.local/share/fish/fish_history`, `~/.claude/projects/`,
    /// `~/.codex/sessions/`, and `~/.local/share/opencode/opencode.db`.
    func requestProvenanceAccess() async {
        let homeDir = UserHome.directory
        _ = await folderAccess.requestAccess(to: homeDir)
    }

    /// Removes exactly the narrowest grant that covers the home directory.
    /// Other ancestor, descendant, and unrelated grants remain intact.
    ///
    /// Safe to call outside of an active scan (the Revoke button is shown only
    /// when the toggle is ON and the toggle is disabled while scanning).
    func revokeProvenanceAccess() {
        let homePath = UserHome.directory.path
        guard let storedPath = folderAccess.grantedPath(covering: homePath) else { return }
        folderAccess.remove(path: storedPath)
    }

    /// Deletes all rows from `provenance_evidence` and clears the in-memory cache.
    /// Called when the user turns off provenance collection and confirms they want
    /// to erase stored install history.
    func clearProvenanceEvidence() async {
        guard let persistence = provenancePersistence else {
            actionError = "Couldn't erase install history because the local cache isn't available."
            return
        }
        do {
            try await persistence.deleteAll()
            provenanceByPackageId = [:]
            actionError = nil
        } catch {
            actionError = "Couldn't erase install history. Your saved evidence is still on disk. \(error.localizedDescription)"
        }
    }

    // MARK: - Private

    private func restoreUIPreferences() {
        if let raw = UserDefaults.standard.string(forKey: DefaultsKey.sortOrder),
           let sort = PackageSortOrder(rawValue: raw) {
            sortOrder = sort
        }
        let presentation = InventoryPresentationPreferences.restore(
            from: UserDefaults.standard,
            viewModeKey: DefaultsKey.inventoryViewMode,
            tableSortOrderKey: DefaultsKey.tableSortOrder
        )
        inventoryViewMode = presentation.viewMode
        tableSortOrder = presentation.tableSortOrder
        if let raw = UserDefaults.standard.string(forKey: DefaultsKey.sidebarSelection),
           let sel = SidebarSelection(userDefaultsKey: raw) {
            sidebarSelection = sel
        }
    }

    private func restoreSettings() {
        if let raw = UserDefaults.standard.string(forKey: DefaultsKey.snapshotBeforeRemoval),
           let pref = SnapshotPreference(rawValue: raw) {
            snapshotBeforeRemoval = pref
        }
        if let raw = UserDefaults.standard.string(forKey: DefaultsKey.removalStrategy),
           let strategy = RemovalStrategy(rawValue: raw) {
            removalStrategy = strategy
        }
        // Bool defaults are `false` in UserDefaults when not yet set.
        // Guard with object(forKey:) for settings whose product default differs
        // from the raw UserDefaults default.
        if UserDefaults.standard.object(forKey: DefaultsKey.scanOnLaunch) != nil {
            scanOnLaunch = UserDefaults.standard.bool(forKey: DefaultsKey.scanOnLaunch)
        }
        if UserDefaults.standard.object(forKey: DefaultsKey.provenanceCollection) != nil {
            provenanceCollection = UserDefaults.standard.bool(forKey: DefaultsKey.provenanceCollection)
        }
    }

    private func loadDescriptionStoreInBackground() {
        guard let url = Bundle.main.url(forResource: "descriptions", withExtension: "json") else { return }
        Task { [weak self] in
            let store = await Task.detached(priority: .utility) {
                try? DescriptionStore(contentsOf: url)
            }.value
            guard let store else { return }
            self?.descriptionStore = store
        }
    }

    private var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Scan

    func scan() async {
        guard !isDemoMode else { return }
        guard !isScanning else { return }
        isScanning = true
        let scanStartedAt = Date()
        defer {
            isScanning = false
            inFlightManagers = []
        }

        var accessedURLs: [URL] = []
        for (_, data) in folderAccess.grantedBookmarks() {
            if let url = folderAccess.startAccessing(data) {
                accessedURLs.append(url)
            }
        }
        defer {
            for url in accessedURLs { folderAccess.stopAccessing(url) }
        }

        let managerEnvironment = PackageManagerEnvironment.current
        let homeDirectory = UserHome.directory
        let pythonDiscovery = PythonInterpreterDiscovery(
            homeDirectory: homeDirectory,
            environment: managerEnvironment,
            projectVenvRoots: accessedURLs
        )
        let scanners: [any PackageScanner] = [
            BrewScanner(),
            PipScanner(discovery: pythonDiscovery),
            PipxScanner(),
            UvToolScanner(
                homeDirectory: homeDirectory,
                environment: managerEnvironment
            ),
            NpmScanner(),
            CargoScanner(),
            GemScanner(),
            MasScanner(applicationDirectories: grantedApplicationsDirectories(accessedURLs)),
            AgentSkillScanner(
                homeDirectory: homeDirectory,
                environment: managerEnvironment,
                grantedURLs: accessedURLs
            ),
            AgentCliScanner(
                homeDirectory: homeDirectory,
                environment: managerEnvironment,
                grantedURLs: accessedURLs
            ),
            EditorExtensionScanner(
                homeDirectory: homeDirectory,
                environment: managerEnvironment,
                grantedURLs: accessedURLs
            ),
        ]
        let scanCoordinator = ScanCoordinator(scanners: scanners)
        let managedManagersByScanner = Dictionary(
            uniqueKeysWithValues: scanners.map { ($0.manager, $0.managedPackageManagers) }
        )

        // Double-buffer from the last-known inventory. Each successful scanner
        // replaces only the partitions it authoritatively observed; failures,
        // skips, and timeouts preserve those partitions instead of reporting
        // false removals or cascading away provenance.
        var buildPackages = packages
        var buildStatuses: [PackageManager: ScannerStatus] = [:]
        inFlightManagers = []

        for await event in await scanCoordinator.scan() {
            switch event {
            case let .scannerStarted(manager):
                inFlightManagers.insert(manager)
            case let .scannerFinished(manager, status, pkgs):
                inFlightManagers.remove(manager)
                let managedManagers = managedManagersByScanner[manager] ?? [manager]
                for managedManager in managedManagers {
                    buildStatuses[managedManager] = partitionStatus(
                        status,
                        for: managedManager,
                        packages: pkgs
                    )
                }
                buildPackages = ScanInventoryReconciler.reconcile(
                    existing: buildPackages,
                    scanned: pkgs,
                    managedManagers: managedManagers,
                    status: status
                )
            case let .allFinished(perManager, _):
                inFlightManagers = []
                // `scannerFinished` carries the packages needed for partition
                // reconciliation. Re-read final statuses defensively without
                // replacing inventory with the success-only aggregate.
                for (manager, status) in perManager {
                    let managedManagers = managedManagersByScanner[manager] ?? [manager]
                    for managedManager in managedManagers {
                        // The matching `scannerFinished` event already recorded
                        // per-partition success counts. Only fill a missing status
                        // here; failure/timeout/skipped values carry no count split.
                        if buildStatuses[managedManager] == nil {
                            buildStatuses[managedManager] = status
                        }
                    }
                }
            }
        }

        // AsyncStream termination cancels the producer. Do not publish or
        // persist its incomplete double buffer when this consumer was cancelled.
        guard !Task.isCancelled else { return }

        // Swap in the freshly built results once. This is the only point
        // where `packages` and `scanStatuses` change during a scan.
        packages = buildPackages
        scanStatuses = buildStatuses
        reconcileInventorySelections()
        inFlightManagers = []
        lastScanCompletedAt = Date()

        if let dao = packageDAO {
            let persistedPackages = packages
            do {
                try await Task.detached(priority: .utility) {
                    try dao.replaceAll(with: persistedPackages)
                }.value
                storageWarning = nil
            } catch {
                storageWarning = "Couldn't save the latest scan to the local cache, so it won't be remembered next launch."
            }
        }

        await captureAutomaticFirstScanSnapshotIfNeeded()

        if let dao = scanRunDAO {
            let scanRun = ScanRun(
                id: UUID(),
                startedAt: scanStartedAt,
                completedAt: lastScanCompletedAt,
                perManagerResults: scanStatuses
            )
            do {
                try await Task.detached(priority: .utility) {
                    try dao.save(scanRun)
                }.value
            } catch {
                storageWarning = "Couldn't save scan history to the local cache."
            }
        }

        // MARK: Project workspace discovery (granted project directories)
        //
        // Runs on a background executor using the same security-scoped URLs the
        // main scan loop started above (accessedURLs is still in scope here).
        // Read-only; results are in-memory only and are never persisted.
        if !accessedURLs.isEmpty {
            let scanner = ProjectWorkspaceScanner(grantedURLs: accessedURLs)
            do {
                let workspaces = try await Task.detached(priority: .utility) {
                    try await scanner.scan()
                }.value
                projectWorkspaces = workspaces
            } catch {
                projectWorkspaces = []
            }
        }

        // MARK: Provenance collection (gated by user opt-in)
        //
        // This block must remain at the very end of scan(), after packageDAO.replaceAll,
        // so the FK constraint (provenance_evidence.package_id → packages.id) is satisfied.
        //
        // Critical: the guard below is the primary enforcement of "provenance defaults OFF".
        // Nothing outside this block should call the collectors.
        guard provenanceCollection else { return }

        // Require a security-scoped bookmark covering the home directory.
        // The user grants this via "Grant read access…" in Settings → Privacy.
        let homeDir = UserHome.directory
        guard
            let homePath = folderAccess.grantedPath(covering: homeDir.path),
            let homeBookmarkPair = folderAccess.grantedBookmarks().first(where: { $0.path == homePath })
        else { return }

        // Start security-scoped access for the home directory grant.
        // `startAccessingSecurityScopedResource` is reference-counted: if the
        // same URL was already started in the main scan loop above (because the
        // user also uses the home directory for regular scanning), the count
        // increments to 2 and both `defer` blocks decrement it correctly.
        guard let homeURL = folderAccess.startAccessing(homeBookmarkPair.bookmark) else { return }
        defer { folderAccess.stopAccessing(homeURL) }

        // Run collectors on a background executor. File I/O must stay off the
        // main actor. All captured values are Sendable (URL, [Package]).
        let capturedPackages = packages
        let capturedHomeURL = homeURL
        let evidenceList: [ProvenanceEvidence] = await Task.detached(priority: .utility) {
            ProvenanceCollector(
                shellCollector: ShellHistoryCollector(homeDirectory: capturedHomeURL),
                claudeCodeCollector: ClaudeCodeLogCollector(homeDirectory: capturedHomeURL),
                codexCollector: CodexLogCollector(homeDirectory: capturedHomeURL),
                opencodeCollector: OpenCodeLogCollector(
                    databasePath: capturedHomeURL
                        .appendingPathComponent(".local/share/opencode/opencode.db")
                )
            ).collect(packages: capturedPackages)
        }.value

        // Persist evidence and refresh the in-memory cache. packageDAO.replaceAll
        // already ran above, so FK constraints are satisfied.
        let byId = Dictionary(
            evidenceList.map { ($0.packageId, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        provenanceByPackageId = byId
        if let persistence = provenancePersistence {
            do {
                try await persistence.upsertAll(evidenceList)
            } catch {
                storageWarning = "Couldn't save the latest install history to the local cache, so it won't be remembered next launch."
            }
        }
    }

    private func partitionStatus(
        _ status: ScannerStatus,
        for manager: PackageManager,
        packages: [Package]
    ) -> ScannerStatus {
        guard case .succeeded(_, let durationMs) = status else { return status }
        return .succeeded(
            count: packages.lazy.filter { $0.manager == manager }.count,
            durationMs: durationMs
        )
    }

    private func scanner(for manager: PackageManager, grantedURLs: [URL]) -> (any PackageScanner)? {
        let environment = PackageManagerEnvironment.current
        let homeDirectory = UserHome.directory
        switch manager {
        case .brew, .brewCask: return BrewScanner()
        case .pip:
            return PipScanner(discovery: PythonInterpreterDiscovery(
                homeDirectory: homeDirectory,
                environment: environment,
                projectVenvRoots: grantedURLs
            ))
        case .pipx:            return PipxScanner()
        case .uv:
            return UvToolScanner(
                homeDirectory: homeDirectory,
                environment: environment
            )
        case .npm:             return NpmScanner()
        case .cargo:           return CargoScanner()
        case .gem:             return GemScanner()
        case .mas:             return MasScanner(applicationDirectories: grantedApplicationsDirectories(grantedURLs))
        case .agentSkill:
            return AgentSkillScanner(
                homeDirectory: homeDirectory,
                environment: environment,
                grantedURLs: grantedURLs
            )
        case .agentCli:
            return AgentCliScanner(
                homeDirectory: homeDirectory,
                environment: environment,
                grantedURLs: grantedURLs
            )
        case .editorExtension:
            return EditorExtensionScanner(
                homeDirectory: homeDirectory,
                environment: environment,
                grantedURLs: grantedURLs
            )
        }
    }

    private func grantedApplicationsDirectories(_ grantedRoots: [URL]) -> [URL] {
        let homeApplications = UserHome.directory
            .appendingPathComponent("Applications", isDirectory: true)
        let candidates = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeApplications,
        ]

        return candidates.filter { candidate in
            grantedRoots.contains { root in
                let rootPath = root.standardizedFileURL.path
                let candidatePath = candidate.standardizedFileURL.path
                return rootPath == candidatePath || candidatePath.hasPrefix(rootPath + "/")
            }
        }
    }
}
