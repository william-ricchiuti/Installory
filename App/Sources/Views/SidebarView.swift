import InstalloryCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator

        List(selection: $coordinator.sidebarSelection) {
            homeSection
            packageManagerSection
            scanCoverageSection
            directoryAccessSection
            snapshotsSection
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 360)
        .navigationTitle("Installory")
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
    }

    // MARK: - Home section

    private var homeSection: some View {
        Section {
            NavigationLink(value: SidebarSelection.dashboard) {
                Label("Home", systemImage: "house")
            }
            NavigationLink(value: SidebarSelection.aiSetup) {
                Label("AI Setup", systemImage: "cpu")
            }
            .badge(coordinator.aiSetupAttentionCount)
            .accessibilityValue(aiSetupBadgeAccessibilityValue)
            .help("Your MCP servers, AI instruction files and agent permissions (\u{2318}3)")
            if !coordinator.projectWorkspaces.isEmpty {
                NavigationLink(value: SidebarSelection.projects) {
                    Label("Projects (\(coordinator.projectWorkspaces.count))", systemImage: "folder")
                }
            }
        }
    }

    private var aiSetupBadgeAccessibilityValue: String {
        let count = coordinator.aiSetupAttentionCount
        switch count {
        case 0: return ""
        case 1: return "1 thing to look at"
        default: return "\(count) things to look at"
        }
    }

    // MARK: - Package Managers section (Task F)

    private var packageManagerSection: some View {
        let inventoryIndex = coordinator.inventoryIndex
        return Section("Package Managers") {
            NavigationLink(value: SidebarSelection.all) {
                Label("All packages (\(coordinator.packages.count))", systemImage: "tray.full")
            }

            ForEach(visibleManagers, id: \.self) { manager in
                let count = inventoryIndex.managerCounts[manager, default: 0]
                NavigationLink(value: SidebarSelection.manager(manager)) {
                    Label {
                        HStack(spacing: 4) {
                            Text("\(manager.displayName) (\(count))")
                            Spacer(minLength: 0)
                            managerStatusBadge(manager: manager)
                        }
                    } icon: {
                        Image(systemName: manager.sidebarSymbol)
                    }
                }
            }

            let readOnlyCount = inventoryIndex.readOnlyCount
            if readOnlyCount > 0 {
                NavigationLink(value: SidebarSelection.readOnly) {
                    Label("Read-only (\(readOnlyCount))", systemImage: "lock")
                }
            }

            let duplicateCount = coordinator.duplicateGroups.count
            if duplicateCount > 0 {
                NavigationLink(value: SidebarSelection.duplicates) {
                    Label("Duplicates (\(duplicateCount))", systemImage: "doc.on.doc")
                }
            }

            let orphanCount = coordinator.orphanedPackages.count
            if orphanCount > 0 {
                NavigationLink(value: SidebarSelection.orphans) {
                    Label("Possibly Unused (\(orphanCount))", systemImage: "leaf.circle")
                }
            }

            let skillCount = coordinator.agentSkillPackages.count
            if skillCount > 0 {
                NavigationLink(value: SidebarSelection.skills) {
                    Label("Skills (\(skillCount))", systemImage: "wand.and.stars")
                }
            }

            if !coordinator.packages.isEmpty {
                NavigationLink(value: SidebarSelection.diskUsage) {
                    Label("Disk Usage", systemImage: "chart.bar.xaxis")
                }
            }

            if coordinator.isDemoMode || coordinator.provenanceCollection {
                let aiCount = coordinator.aiInstalledPackages.count
                if aiCount > 0 {
                    NavigationLink(value: SidebarSelection.aiInstalled) {
                        Label("AI Installed (\(aiCount))", systemImage: "sparkles")
                    }
                }
            }
        }
    }

    // MARK: - Directory Access section (Tasks F + G)

    @ViewBuilder
    private var directoryAccessSection: some View {
        Section("Directory Access") {
            // Task G: stale bookmarks with Re-grant affordance
            let stalePaths = coordinator.folderAccess.staleBookmarkPaths.sorted()
            ForEach(stalePaths, id: \.self) { path in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .lineLimit(1)
                        Text("Access lost — directory moved or revoked")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                    Button("Re-grant") {
                        Task { await coordinator.grantDirectory(suggestedPath: path) }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Re-open the access panel for \(path)")
                }
                .selectionDisabled()
            }

            // Active grants
            let granted = coordinator.grantedDirectories
            if granted.isEmpty && stalePaths.isEmpty {
                Text("No directories granted")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .selectionDisabled()
            } else {
                ForEach(granted) { dir in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dir.displayPath)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text(dir.managersUnlocked)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .selectionDisabled()
                }
            }
        }
    }

    // MARK: - Snapshots section

    @ViewBuilder
    private var snapshotsSection: some View {
        Section("Snapshots") {
            if coordinator.snapshots.isEmpty {
                Text("No snapshots yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .selectionDisabled()
            } else {
                ForEach(coordinator.snapshots) { snapshot in
                    NavigationLink(value: SidebarSelection.snapshot(snapshot.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshotReasonLabel(snapshot.reason))
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(relativeDate(snapshot.createdAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func snapshotReasonLabel(_ reason: SnapshotReason) -> String {
        reason.displayName
    }

    // MARK: - Scan coverage section

    @ViewBuilder
    private var scanCoverageSection: some View {
        let coverage = coordinator.scanCoverage
        if !coverage.isEmpty {
            Section("Scan Coverage") {
                ForEach(coverage, id: \.manager) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: coverageIcon(entry.status))
                            .foregroundStyle(coverageColor(entry.status))
                            .imageScale(.small)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.manager.displayName)
                                .font(.caption)
                            Text(coverageDetail(entry.status))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .selectionDisabled()
                    .help(coverageDetail(entry.status))
                    .accessibilityLabel("\(entry.manager.displayName): \(coverageDetail(entry.status))")
                }
            }
        }
    }

    private func coverageIcon(_ status: ScannerStatus) -> String {
        switch status {
        case .succeeded:  return "checkmark.circle.fill"
        case .skipped:    return "minus.circle"
        case .failed:     return "xmark.octagon.fill"
        case .timedOut:   return "clock.badge.exclamationmark"
        }
    }

    private func coverageColor(_ status: ScannerStatus) -> Color {
        switch status {
        case .succeeded: return .green
        case .skipped:   return .secondary
        case .failed:    return .red
        case .timedOut:  return .orange
        }
    }

    private func coverageDetail(_ status: ScannerStatus) -> String {
        switch status {
        case .succeeded(let count, _):
            return "\(count) package\(count == 1 ? "" : "s")"
        case .skipped:
            return ScannerStatus.friendlySkipDescription
        case .failed(let reason, _):
            return reason
        case .timedOut:
            return "Scan took too long and was stopped"
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if coordinator.isDemoMode {
                HStack(spacing: 6) {
                    Label("Demo data", systemImage: "wand.and.stars")
                        .font(.caption.weight(.medium))
                    Spacer(minLength: 0)
                    Button("Exit") {
                        coordinator.exitDemoMode()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Exit demo mode and scan your own Mac")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Text(coordinator.statusSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let summary = coordinator.lastScanSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Menu {
                Section("Recommended") {
                    DirectoryGrantsView()
                }
                Divider()
                Button("Custom Folder\u{2026}", systemImage: "folder") {
                    Task { await coordinator.grantCustomDirectory() }
                }
            } label: {
                Label("Add Folder", systemImage: "folder.badge.plus")
                    .font(.callout)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Grant read access to a recommended or custom folder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Helpers (Task F)

    /// Managers to show in the sidebar.
    ///
    /// Rule: show if the manager has ≥1 package from the current scan, OR its status
    /// is `.failed`/`.timedOut` (surfacing errors even when N=0). Managers with
    /// `.succeeded(count: 0)` or `.skipped` stay hidden — clean noise reduction.
    private var visibleManagers: [PackageManager] {
        let hasPackages = coordinator.inventoryIndex.packageManagers
        return PackageManager.allCases.filter { manager in
            if hasPackages.contains(manager) { return true }
            if let status = coordinator.scanStatuses[manager] {
                switch status {
                case .failed, .timedOut: return true
                default: return false
                }
            }
            return false
        }
    }

    /// Returns a non-nil warning message when the manager's last scan failed or timed out.
    private func scanWarning(for manager: PackageManager) -> String? {
        guard let status = coordinator.scanStatuses[manager] else { return nil }
        switch status {
        case .failed(let reason, _): return reason
        case .timedOut: return "Scan timed out"
        default: return nil
        }
    }

    @ViewBuilder
    private func managerStatusBadge(manager: PackageManager) -> some View {
        if let warning = scanWarning(for: manager) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.small)
                .help(warning)
                .accessibilityLabel("\(manager.displayName) scan warning: \(warning)")
        }
    }
}

#Preview {
    NavigationSplitView {
        SidebarView()
    } content: {
        Text("List")
    } detail: {
        Text("Detail")
    }
    .environment(AppCoordinator())
    .frame(width: 900, height: 600)
}
