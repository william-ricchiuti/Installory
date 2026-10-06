import InstalloryCore
import SwiftUI

// MARK: - Tab selection

private enum SnapshotViewTab: String, CaseIterable, Identifiable {
    case contents = "Snapshot"
    case changes  = "Changes"
    var id: String { rawValue }
}

// MARK: - Main view

struct SnapshotContentView: View {
    let snapshotID: UUID
    @Environment(AppCoordinator.self) private var coordinator
    @State private var searchQuery = ""
    @State private var activeTab: SnapshotViewTab = .contents
    @State private var isLoadingSnapshot = true
    @State private var snapshotLoadFailed = false

    // Restore flow state — all local; nothing in coordinator changes.
    @State private var missingPackages: [MissingPackage] = []
    @State private var showRestoreChecklist = false
    @State private var showNothingMissingAlert = false

    private var snapshotSummary: SnapshotSummary? {
        coordinator.snapshots.first { $0.id == snapshotID }
    }

    private var snapshot: Snapshot? {
        guard coordinator.loadedSnapshot?.id == snapshotID else { return nil }
        return coordinator.loadedSnapshot
    }

    var body: some View {
        Group {
            if snapshotSummary == nil {
                ContentUnavailableView {
                    Label("Snapshot Not Found", systemImage: "camera.viewfinder")
                } description: {
                    Text("This snapshot may have been deleted.")
                }
            } else if let snapshot {
                snapshotBody(snapshot)
            } else if isLoadingSnapshot {
                ProgressView("Loading Snapshot…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snapshotLoadFailed {
                ContentUnavailableView {
                    Label("Snapshot Couldn't Be Loaded", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("The saved snapshot payload could not be read.")
                }
            }
        }
        // Key the task to metadata availability as well as selection. A sidebar
        // selection restored before launch hydration must retry once its summary
        // arrives instead of remaining in a false load-failure state.
        .task(id: snapshotSummary?.id) {
            guard snapshotSummary != nil else {
                isLoadingSnapshot = false
                snapshotLoadFailed = false
                return
            }
            isLoadingSnapshot = true
            snapshotLoadFailed = false
            let loaded = await coordinator.loadSnapshot(id: snapshotID)
            guard !Task.isCancelled else { return }
            isLoadingSnapshot = false
            snapshotLoadFailed = loaded == nil
        }
    }

    @ViewBuilder
    private func snapshotBody(_ snapshot: Snapshot) -> some View {
        let managers = snapshot.payload.managers.keys
            .sorted { $0.rawValue < $1.rawValue }

        List {
            Section {
                metadataHeader(snapshot)
                Picker("View Mode", selection: $activeTab) {
                    ForEach(SnapshotViewTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.vertical, 2)
            }
            .selectionDisabled()

            if activeTab == .contents {
                ForEach(managers, id: \.self) { manager in
                    let pkgs = filteredPackages(
                        snapshot.payload.managers[manager] ?? [],
                        query: searchQuery
                    )
                    if !pkgs.isEmpty {
                        Section(manager.displayName) {
                            ForEach(pkgs) { pkg in
                                SnapshotPackageRowView(package: pkg, manager: manager)
                            }
                        }
                    }
                }
            } else {
                changesSections(snapshot)
            }
        }
        .listStyle(.inset)
        .searchable(text: $searchQuery, prompt: "Filter snapshot")
        .findCommandFocusable()
        .navigationTitle("Snapshot")
        .alert("Nothing Missing", isPresented: $showNothingMissingAlert) {
            Button("OK") {}
        } message: {
            Text("Everything in this snapshot is still installed.")
        }
        .sheet(isPresented: $showRestoreChecklist) {
            RestoreChecklistSheet(snapshot: snapshot, missingPackages: missingPackages)
        }
    }

    // MARK: - Changes sections

    @ViewBuilder
    private func changesSections(_ snapshot: Snapshot) -> some View {
        let changes = snapshotChanges(from: snapshot, to: coordinator.packages)

        if changes.isEmpty {
            Section {
                HStack {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text("No changes since this snapshot.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            .selectionDisabled()
        } else {
            Section {
                changesSummaryRow(snapshot: snapshot, changes: changes)
            }
            .selectionDisabled()

            if !changes.added.isEmpty {
                Section("Added (\(changes.added.count))") {
                    ForEach(changes.added) { pkg in
                        AddedPackageRowView(package: pkg)
                    }
                }
            }

            if !changes.removed.isEmpty {
                Section("Removed (\(changes.removed.count))") {
                    ForEach(changes.removed) { mp in
                        SnapshotPackageRowView(package: mp.package, manager: mp.manager)
                    }
                }
            }

            if !changes.versionChanged.isEmpty {
                Section("Updated (\(changes.versionChanged.count))") {
                    ForEach(changes.versionChanged) { vc in
                        VersionChangeRowView(change: vc)
                    }
                }
            }
        }
    }

    private func changesSummaryRow(snapshot: Snapshot, changes: SnapshotChangeSet) -> some View {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relDate = formatter.localizedString(for: snapshot.createdAt, relativeTo: Date())

        var parts: [String] = []
        if !changes.added.isEmpty {
            let w = changes.added.count == 1 ? "package" : "packages"
            parts.append("\(changes.added.count) \(w) added")
        }
        if !changes.removed.isEmpty {
            let w = changes.removed.count == 1 ? "package" : "packages"
            parts.append("\(changes.removed.count) \(w) removed")
        }
        if !changes.versionChanged.isEmpty {
            let w = changes.versionChanged.count == 1 ? "package" : "packages"
            parts.append("\(changes.versionChanged.count) \(w) updated")
        }

        let summary = parts.joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 2) {
            Text("Since \(relDate)")
                .font(.callout)
                .foregroundStyle(.primary)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Metadata header

    private func metadataHeader(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(snapshotReasonLabel(snapshot.reason), systemImage: "camera.viewfinder")
                    .font(.headline)
                Spacer()
                Button {
                    computeAndShowRestoreFlow(snapshot: snapshot)
                } label: {
                    Label("Restore Missing Packages\u{2026}", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .disabled(coordinator.isScanning)
                .help("Diff this snapshot against the current inventory and generate a reinstall script")
                Button {
                    coordinator.sidebarSelection = .all
                } label: {
                    Label("Exit Snapshot", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Return to live inventory")
            }
            Text("Captured \(formattedDate(snapshot.createdAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
            let totalCount = snapshot.payload.managers.values.reduce(0) { $0 + $1.count }
            Text("\(totalCount) packages across \(snapshot.payload.managers.count) manager(s)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Restore flow

    private func computeAndShowRestoreFlow(snapshot: Snapshot) {
        let missing = snapshotDiff(snapshot: snapshot, livePackages: coordinator.packages)
        if missing.isEmpty {
            showNothingMissingAlert = true
        } else {
            missingPackages = missing
            showRestoreChecklist = true
        }
    }

    // MARK: - Helpers

    private func filteredPackages(_ packages: [SnapshotPackage], query: String) -> [SnapshotPackage] {
        guard !query.isEmpty else { return packages }
        return packages.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func snapshotReasonLabel(_ reason: SnapshotReason) -> String {
        reason.displayName
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Snapshot package row

private struct SnapshotPackageRowView: View {
    let package: SnapshotPackage
    let manager: PackageManager

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(package.name)
                        .fontWeight(.semibold)
                    ManagerBadge(manager: manager)
                }
                HStack(spacing: 8) {
                    Text(package.version)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if !package.isExplicit {
                        Text("dependency")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            if let qualifier = package.qualifier {
                Text(URL(fileURLWithPath: qualifier).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Added package row (live Package from snapshotChanges)

private struct AddedPackageRowView: View {
    let package: Package

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(package.name)
                        .fontWeight(.semibold)
                    ManagerBadge(manager: package.manager)
                }
                HStack(spacing: 8) {
                    Text(package.version)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if !package.isExplicit {
                        Text("dependency")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            if let qualifier = package.qualifier {
                Text(URL(fileURLWithPath: qualifier).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Version change row

private struct VersionChangeRowView: View {
    let change: VersionChange

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(change.name)
                        .fontWeight(.semibold)
                    ManagerBadge(manager: change.manager)
                }
                HStack(spacing: 4) {
                    Text(change.oldVersion)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(change.newVersion)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let qualifier = change.qualifier {
                Text(URL(fileURLWithPath: qualifier).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Restore checklist sheet

/// Two-step sheet: first shows a checklist of missing packages (all pre-checked);
/// after the user clicks "Generate Reinstall Script", the same sheet surface
/// switches to `ScriptSheetView`. Dismissing from either step closes the sheet.
private struct RestoreChecklistSheet: View {
    let snapshot: Snapshot
    let missingPackages: [MissingPackage]

    @State private var selectedIDs: Set<String>
    @State private var generatedScript: String? = nil
    @Environment(\.dismiss) private var dismiss

    init(snapshot: Snapshot, missingPackages: [MissingPackage]) {
        self.snapshot = snapshot
        self.missingPackages = missingPackages
        _selectedIDs = State(initialValue: Set(missingPackages.map(\.id)))
    }

    var body: some View {
        if let script = generatedScript {
            ScriptSheetView(
                title: "Reinstall Script",
                filename: "installory-reinstall.sh",
                scriptText: script
            )
        } else {
            checklistView
        }
    }

    // MARK: - Checklist

    private var checklistView: some View {
        VStack(alignment: .leading, spacing: 0) {
            checklistHeader
            Divider()
            packageList
            Divider()
            footerBar
        }
        .frame(minWidth: 560, minHeight: 400)
    }

    private var checklistHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Restore Missing Packages")
                .font(.title2)
                .fontWeight(.bold)
            HStack(spacing: 6) {
                Text(snapshotReasonLabel(snapshot.reason))
                Text("\u{00B7}")
                Text("Captured \(formattedDate(snapshot.createdAt))")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Text("\(missingPackages.count) package(s) not in current inventory")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var packageList: some View {
        List(missingPackages) { mp in
            HStack(spacing: 10) {
                Button {
                    if selectedIDs.contains(mp.id) {
                        selectedIDs.remove(mp.id)
                    } else {
                        selectedIDs.insert(mp.id)
                    }
                } label: {
                    Image(systemName: selectedIDs.contains(mp.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selectedIDs.contains(mp.id) ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(mp.package.name), \(mp.manager.displayName)")
                .accessibilityValue(
                    selectedIDs.contains(mp.id) ? "Selected for reinstall" : "Not selected for reinstall"
                )
                .accessibilityHint("Toggle whether this package is included in the reinstall script")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(mp.package.name)
                            .fontWeight(.semibold)
                        ManagerBadge(manager: mp.manager)
                    }
                    Text(mp.package.version)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let qualifier = mp.package.qualifier {
                    Text(URL(fileURLWithPath: qualifier).lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    private var footerBar: some View {
        HStack {
            Button("Cancel") { dismiss() }
            Spacer()
            Button {
                let selected = missingPackages.filter { selectedIDs.contains($0.id) }
                let result = ReinstallScriptGenerator().generate(missing: selected)
                generatedScript = result.scriptText
            } label: {
                Label(
                    "Generate Reinstall Script (\(selectedIDs.count))",
                    systemImage: "doc.text"
                )
            }
            .disabled(selectedIDs.isEmpty)
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    // MARK: - Helpers

    private func snapshotReasonLabel(_ reason: SnapshotReason) -> String {
        reason.displayName
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview {
    SnapshotContentView(snapshotID: UUID())
        .environment(AppCoordinator())
        .frame(width: 380, height: 500)
}
