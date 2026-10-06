import AppKit
import InstalloryCore
import SwiftUI

struct PackageListView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        let visiblePackages = coordinator.filteredPackageSource

        Group {
            if coordinator.packages.isEmpty {
                emptyState
            } else if visiblePackages.isEmpty {
                noMatchState
            } else {
                packageContent(visiblePackages)
            }
        }
        .searchable(text: $coordinator.searchQuery, placement: .toolbar, prompt: "Filter packages")
        .findCommandFocusable()
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                demoBanner
                storageBanner
                failureBanner
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CleanupSelectionFooter()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Inventory view", selection: $coordinator.inventoryViewMode) {
                    Label("List", systemImage: "list.bullet")
                        .tag(InventoryViewMode.list)
                    Label("Table", systemImage: "tablecells")
                        .tag(InventoryViewMode.table)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Inventory view")
                .help("Show packages as a list or sortable table")
            }
            ToolbarItem(placement: .automatic) {
                if coordinator.inventoryViewMode == .list, !coordinator.isCleanupMode {
                    Picker("Sort", selection: $coordinator.sortOrder) {
                        ForEach(PackageSortOrder.allCases, id: \.self) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .help("Sort order")
                }
            }
        }
        .navigationTitle("Packages")
        .onChange(of: coordinator.sortOrder) { _, _ in
            coordinator.persistUIPreferences()
        }
        .onChange(of: coordinator.inventoryViewMode) { _, _ in
            coordinator.persistUIPreferences()
        }
        .onChange(of: coordinator.tableSortOrder) { _, _ in
            coordinator.persistUIPreferences()
        }
        .onChange(of: coordinator.searchQuery) { _, _ in
            guard let selectedID = coordinator.selectedPackage?.id,
                  !visiblePackages.contains(where: { $0.id == selectedID }) else {
                return
            }
            coordinator.selectedPackage = nil
        }
        // Sidebar selection is persisted by RootView, which stays mounted. This view
        // unmounts when the user navigates to Duplicates, Review Candidates, or
        // AI Installed — so an onChange here would never fire for those sections.
    }

    // MARK: - Demo banner

    @ViewBuilder
    private var demoBanner: some View {
        if coordinator.isDemoMode {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                    Text("You're viewing sample data. Nothing here is from your Mac.")
                        .font(.callout)
                    Spacer(minLength: 0)
                    Button("Exit Demo Mode") {
                        coordinator.exitDemoMode()
                    }
                    .buttonStyle(.borderless)
                    .font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.14))
                Divider()
            }
        }
    }

    // MARK: - Storage warning banner

    @ViewBuilder
    private var storageBanner: some View {
        if let warning = coordinator.storageWarning, !coordinator.isDemoMode {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.callout)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .accessibilityElement(children: .combine)
                Divider()
            }
        }
    }

    // MARK: - Failure banner

    @ViewBuilder
    private var failureBanner: some View {
        let failed = coordinator.failedManagers
        if !failed.isEmpty, !coordinator.isDemoMode {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failed.count == 1
                             ? "\(failed[0].0.displayName) didn\u{2019}t finish scanning"
                             : "\(failed.count) scanners didn\u{2019}t finish")
                            .font(.callout.weight(.semibold))
                        Text(failed.map { "\($0.0.displayName): \($0.1)" }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button("Rescan") {
                        Task { await coordinator.refresh() }
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .accessibilityElement(children: .combine)
                Divider()
            }
        }
    }

    // MARK: - Empty states

    @ViewBuilder
    private var emptyState: some View {
        if coordinator.isScanning {
            VStack(spacing: 12) {
                ProgressView()
                Text(scanningStatusText)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !coordinator.folderAccess.hasAnyGrant {
            ContentUnavailableView {
                Label("No Access Granted", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Grant access to a directory to see what's installed, or explore a pre-populated sample inventory.")
            } actions: {
                exploreSampleDataButton
            }
        } else {
            ContentUnavailableView {
                Label("No Packages Found", systemImage: "shippingbox")
            } description: {
                Text("Installory didn't find any packages in the granted directories. You can explore a pre-populated sample inventory instead.")
            } actions: {
                exploreSampleDataButton
            }
        }
    }

    private var exploreSampleDataButton: some View {
        Button {
            coordinator.enterDemoMode()
        } label: {
            Label("Explore with Sample Data", systemImage: "wand.and.stars")
        }
        .buttonStyle(.borderedProminent)
        .help("Load a pre-populated sample inventory so you can explore every feature without granting access to any folders.")
    }

    /// Per-manager scan progress for the scanning empty state. Falls back to a
    /// generic message when no managers are currently in flight.
    private var scanningStatusText: String {
        let names = coordinator.inFlightManagers.map(\.displayName).sorted()
        guard !names.isEmpty else { return "Scanning…" }
        return "Scanning \(names.joined(separator: ", "))…"
    }

    private var noMatchState: some View {
        ContentUnavailableView.search(text: coordinator.searchQuery)
    }

    // MARK: - Package list

    @ViewBuilder
    private func packageContent(_ visiblePackages: [Package]) -> some View {
        switch coordinator.inventoryViewMode {
        case .list:
            packageList(
                visiblePackages.sorted(
                    by: coordinator.sortOrder,
                    pinnedFirst: coordinator.pinnedIDs
                )
            )
        case .table:
            @Bindable var coordinator = coordinator
            PackageTableView(
                packages: visiblePackages,
                sortOrder: $coordinator.tableSortOrder
            )
        }
    }

    private func packageList(_ visiblePackages: [Package]) -> some View {
        List(
            visiblePackages,
            selection: Binding(
                get: { coordinator.selectedPackage?.id },
                set: { id in
                    coordinator.selectedPackage = id.flatMap(coordinator.package(id:))
                }
            )
        ) { pkg in
            PackageRowView(
                package: pkg,
                onRemove: pkg.isRemovalScriptEligible(strategy: coordinator.removalStrategy) ? {
                    Task { await coordinator.requestRemoval([pkg]) }
                } : nil
            )
        }
        .listStyle(.inset)
    }
}

// MARK: - Row

private struct PackageRowView: View {
    @Environment(AppCoordinator.self) private var coordinator
    let package: Package
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            CleanupSelectionToggle(package: package)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(package.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .layoutPriority(1)
                    ManagerBadge(manager: package.manager)
                    RemovalSafetyBadge(verdict: coordinator.removalSafety(for: package))
                    if coordinator.isPinned(package.id) {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Pinned — floats to the top of the list")
                    }
                }
                Text(package.version)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // The name column wins over the trailing cleanup annotation.
            .layoutPriority(1)
            Spacer(minLength: 0)
            CleanupAnnotationView(package: package)
        }
        .padding(.vertical, 2)
        .contextMenu {
            PackageContextMenu(package: package, onRemove: onRemove)
        }
    }
}

/// Shared row actions for List and Table inventory presentations. Filesystem
/// existence and reveal behavior stay behind the coordinator's granted-path
/// checks, and removal remains a generated-script request only.
struct PackageContextMenu: View {
    @Environment(AppCoordinator.self) private var coordinator

    let package: Package
    var onRemove: (() -> Void)? = nil

    var body: some View {
        Button("Copy Name", systemImage: "doc.on.doc") {
            copy(package.name)
        }
        if let installPath = package.installPath {
            Button("Copy Install Path", systemImage: "doc.on.doc.fill") {
                copy(installPath.path)
            }
            let exists = coordinator.packageInstallPathExists(at: installPath)
            Button("Reveal in Finder", systemImage: "folder") {
                coordinator.revealPackageInstallPath(at: installPath)
            }
            .disabled(!exists)
        }
        Divider()
        if coordinator.isPinned(package.id) {
            Button("Unpin", systemImage: "pin.slash") {
                coordinator.togglePinned(package.id)
            }
        } else {
            Button("Pin", systemImage: "pin") {
                coordinator.togglePinned(package.id)
            }
        }
        if coordinator.isHidden(package.id) {
            Button("Unhide", systemImage: "eye") {
                coordinator.toggleHidden(package.id)
            }
        } else {
            Button("Hide from Inventory", systemImage: "eye.slash") {
                coordinator.toggleHidden(package.id)
            }
        }
        if let onRemove {
            Divider()
            Button("Create Removal Script\u{2026}", systemImage: "doc.text") {
                onRemove()
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct CleanupAnnotationView: View {
    let package: Package

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let size = package.sizeBytes {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let date = package.installedAt {
                Text(ageLabel(date: date, confidence: package.installedAtConfidence))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func ageLabel(date: Date, confidence: Confidence) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let relative = formatter.localizedString(for: date, relativeTo: .now)
        switch confidence {
        case .low, .unknown:
            return "\(relative) (est.)"
        case .medium, .high:
            return relative
        }
    }
}

#Preview {
    let coordinator = AppCoordinator()
    return PackageListView()
        .environment(coordinator)
        .frame(width: 380, height: 500)
}
