import InstalloryCore
import SwiftUI

/// Why a dedicated analysis view has no rows to display.
///
/// A positive "no findings" message is reserved for a completed scan in which
/// no manager failed or timed out. Skipped managers (not installed, or not
/// granted) don't make results inconclusive; saved inventory with unknown
/// coverage and failed or timed-out scans do.
enum AnalysisEmptyState: Equatable {
    case scanInProgress
    case noInventory
    case incompleteCoverage
    case noResults

    static func resolve(
        packageCount: Int,
        isScanning: Bool,
        isDemoMode: Bool,
        scanStatuses: [PackageManager: ScannerStatus]
    ) -> AnalysisEmptyState {
        if isScanning {
            return .scanInProgress
        }
        if isDemoMode {
            return packageCount == 0 ? .noInventory : .noResults
        }

        // Only a scanner that actually failed or timed out makes results
        // inconclusive. `.skipped` means the manager isn't present on this Mac
        // (or its folder isn't granted), which is a complete answer.
        let hasScanProblem = scanStatuses.values.contains { status in
            switch status {
            case .failed, .timedOut: true
            case .succeeded, .skipped: false
            }
        }
        if hasScanProblem {
            return .incompleteCoverage
        }
        if packageCount == 0 {
            return .noInventory
        }
        // Saved inventory with no scan this session has unknown coverage.
        return scanStatuses.isEmpty ? .incompleteCoverage : .noResults
    }
}

/// Sections that can contain shell-removable packages and expose bulk controls.
extension SidebarSelection {
    var supportsCleanupControls: Bool {
        switch self {
        case .all, .manager, .duplicates, .orphans, .skills:
            return true
        case .dashboard, .readOnly, .diskUsage, .aiInstalled, .projects, .snapshot:
            return false
        }
    }
}

struct AnalysisEmptyStateView: View {
    let state: AnalysisEmptyState
    let noResultsTitle: String
    let noResultsSystemImage: String
    let noResultsDescription: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        }
    }

    private var title: String {
        switch state {
        case .scanInProgress: "Analysis in Progress"
        case .noInventory: "No Package Inventory"
        case .incompleteCoverage: "Results May Be Incomplete"
        case .noResults: noResultsTitle
        }
    }

    private var systemImage: String {
        switch state {
        case .scanInProgress: "arrow.triangle.2.circlepath"
        case .noInventory: "shippingbox"
        case .incompleteCoverage: "exclamationmark.triangle"
        case .noResults: noResultsSystemImage
        }
    }

    private var description: String {
        switch state {
        case .scanInProgress:
            "Installory is still scanning. This analysis will update when the scan finishes."
        case .noInventory:
            "Grant access to a package directory and run a scan before using this analysis."
        case .incompleteCoverage:
            "A package manager scan failed or timed out, or this saved inventory hasn\u{2019}t been rescanned yet. Review Scan Coverage and scan again before relying on this analysis."
        case .noResults:
            noResultsDescription
        }
    }
}

/// How a sidebar destination uses the window.
enum DestinationLayout: Equatable {
    /// Sidebar + list column + package detail column.
    case listWithDetail
    /// Sidebar + one full-width view; there is no package selection to detail.
    case fullWidth
}

extension SidebarSelection {
    /// Destinations without a package selection that drives the detail column
    /// render full width instead of leaving an empty "No Package Selected" pane.
    var destinationLayout: DestinationLayout {
        switch self {
        case .dashboard, .projects, .snapshot:
            return .fullWidth
        case .all, .manager, .readOnly, .duplicates, .orphans, .diskUsage, .aiInstalled, .skills:
            return .listWithDetail
        }
    }
}

struct RootView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showingBaselineCompare = false
    /// Shared by both split-view layouts so a collapsed sidebar stays collapsed
    /// when switching between full-width and list destinations.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var layout: DestinationLayout {
        (coordinator.sidebarSelection ?? .all).destinationLayout
    }

    var body: some View {
        @Bindable var coordinator = coordinator

        Group {
            switch layout {
            case .fullWidth:
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                } detail: {
                    fullWidthDestination
                }
            case .listWithDetail:
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                } content: {
                    listDestination
                        .navigationSplitViewColumnWidth(min: 300, ideal: 360)
                } detail: {
                    packageDetail
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    DirectoryGrantsView()
                    Divider()
                    Button("Grant Custom Directory\u{2026}", systemImage: "folder") {
                        Task { await coordinator.grantCustomDirectory() }
                    }
                } label: {
                    Label("Grant Access", systemImage: "folder.badge.plus")
                }
                .help("Grant Installory read access to a folder")
            }

            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    if coordinator.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button {
                        coordinator.isCleanupMode.toggle()
                        if !coordinator.isCleanupMode {
                            coordinator.selectedForCleanup = []
                        }
                    } label: {
                        Label(
                            coordinator.isCleanupMode ? "Exit Cleanup Mode" : "Cleanup Mode",
                            systemImage: coordinator.isCleanupMode ? "checklist.checked" : "checklist"
                        )
                    }
                    .disabled(
                        !coordinator.canEnterCleanupMode
                    )
                    .help(
                        coordinator.canEnterCleanupMode
                            ? "Select packages to generate a cleanup script (⇧⌘K)"
                            : "No packages in this section have a generated removal command"
                    )

                    Button {
                        Task { await coordinator.captureManualSnapshot() }
                    } label: {
                        Label("Snapshot Now", systemImage: "camera.viewfinder")
                    }
                    .help("Capture a manual snapshot of the current inventory")
                    .disabled(coordinator.packages.isEmpty || coordinator.isScanning)

                    Menu {
                        Button("Import Baseline\u{2026}", systemImage: "arrow.down.doc") {
                            Task { await coordinator.pickBaselineFile() }
                        }
                        .disabled(coordinator.packages.isEmpty)
                        if coordinator.baselinePayload != nil {
                            Button("Compare with Baseline\u{2026}", systemImage: "arrow.triangle.2.circlepath") {
                                showingBaselineCompare = true
                            }
                            Divider()
                            Button("Clear Baseline", systemImage: "trash", role: .destructive) {
                                coordinator.clearBaseline()
                            }
                        }
                    } label: {
                        Label("Baseline", systemImage: coordinator.baselinePayload != nil ? "checklist" : "doc.badge.arrow.up")
                    }
                    .help("Compare the inventory against a snapshot captured on another Mac")

                    Button {
                        Task { await coordinator.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(coordinator.isScanning)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Rescan all granted directories (⌘R)")
                }
            }
        }
        .frame(minWidth: 900, minHeight: 580)
        .task {
            await coordinator.hydratePersistedState()
            await coordinator.autoScanIfNeeded()
        }
        // Persisted here rather than in PackageListView, which unmounts whenever the
        // user navigates to one of the dedicated sections above.
        .onChange(of: coordinator.sidebarSelection) { _, _ in
            coordinator.reconcileCleanupSelectionForCurrentSidebar()
            coordinator.reconcileSelectedPackageForCurrentSidebar()
            coordinator.persistUIPreferences()
        }
        .onChange(of: coordinator.isCleanupMode) { _, _ in
            // Also catches the global keyboard command in a section without a
            // package that can produce a removal command.
            coordinator.reconcileCleanupSelectionForCurrentSidebar()
        }
        .sheet(isPresented: Binding(
            get: { coordinator.cleanupResult != nil },
            set: { if !$0 { coordinator.cleanupResult = nil } }
        )) {
            if let result = coordinator.cleanupResult {
                CleanupScriptSheetView(result: result)
                    .environment(coordinator)
            }
        }
        .sheet(isPresented: Binding(
            get: { coordinator.pendingRemovalPackages != nil },
            set: { if !$0 { coordinator.cancelRemoval() } }
        )) {
            if let packages = coordinator.pendingRemovalPackages {
                SnapshotChoiceSheet(packages: packages)
                    .environment(coordinator)
            }
        }
        .sheet(isPresented: Binding(
            get: { !coordinator.onboardingCompleted },
            set: { _ in }
        )) {
            OnboardingView()
                .environment(coordinator)
        }
        .sheet(isPresented: $showingBaselineCompare) {
            BaselineCompareView()
                .environment(coordinator)
        }
        .actionErrorAlert(coordinator: coordinator)
    }

    // MARK: - Destinations

    @ViewBuilder
    private var fullWidthDestination: some View {
        switch coordinator.sidebarSelection {
        case .snapshot(let id):
            SnapshotContentView(snapshotID: id)
        case .projects:
            ProjectsView()
        default:
            DashboardView()
        }
    }

    @ViewBuilder
    private var listDestination: some View {
        switch coordinator.sidebarSelection {
        case .duplicates:
            DuplicatesView()
        case .orphans:
            OrphansView()
        case .diskUsage:
            DiskUsageView()
        case .aiInstalled:
            AIInstalledView()
        case .skills:
            SkillsView()
        default:
            PackageListView()
        }
    }

    @ViewBuilder
    private var packageDetail: some View {
        if let pkg = coordinator.selectedPackage {
            PackageDetailView(package: pkg)
                // Fresh per-package @State (e.g. the note draft).
                .id(pkg.id)
        } else {
            ContentUnavailableView {
                Label("No Package Selected", systemImage: "shippingbox")
            } description: {
                Text("Select a package from the list to view its details.")
            }
        }
    }

}

extension View {
    /// Surfaces a failed user-initiated action (export, manual snapshot) as an alert.
    /// Applied wherever those actions can be triggered — the main window and Settings.
    func actionErrorAlert(coordinator: AppCoordinator) -> some View {
        alert(
            "Something didn\u{2019}t work",
            isPresented: Binding(
                get: { coordinator.actionError != nil },
                set: { if !$0 { coordinator.dismissActionError() } }
            )
        ) {
            Button("OK", role: .cancel) { coordinator.dismissActionError() }
        } message: {
            if let message = coordinator.actionError {
                Text(message)
            }
        }
    }
}

#Preview {
    RootView()
        .environment(AppCoordinator())
}
