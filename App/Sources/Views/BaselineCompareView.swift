import InstalloryCore
import SwiftUI

/// Compares the live inventory against an imported baseline snapshot payload.
///
/// Presents three change buckets — packages only on this Mac (added), packages
/// only in the baseline (removed), and packages present at different versions —
/// and can generate a reinstall script for the removed packages.
struct BaselineCompareView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var showingReinstallScript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            changeContent
            buttonRow
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 480)
        .sheet(isPresented: $showingReinstallScript) {
            if let changeSet = coordinator.baselineChangeSet {
                reinstallScriptSheet(changeSet)
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Compare with Saved Setup")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("What's different between this Mac and the saved setup you imported.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Import Another Saved Setup\u{2026}") {
                Task { await coordinator.pickBaselineFile() }
            }
            .disabled(coordinator.isScanning)
        }
    }

    @ViewBuilder
    private var changeContent: some View {
        if let changeSet = coordinator.baselineChangeSet {
            if changeSet.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !changeSet.added.isEmpty {
                            changeSection(
                                title: "Only on this Mac (\(changeSet.added.count))",
                                systemImage: "plus.circle",
                                color: .green
                            ) {
                                ForEach(changeSet.added) { package in
                                    PackageChangeRow(name: package.name, manager: package.manager, version: package.version)
                                }
                            }
                        }
                        if !changeSet.removed.isEmpty {
                            changeSection(
                                title: "In saved setup, not here (\(changeSet.removed.count))",
                                systemImage: "minus.circle",
                                color: .orange
                            ) {
                                ForEach(changeSet.removed) { missing in
                                    PackageChangeRow(
                                        name: missing.package.name,
                                        manager: missing.manager,
                                        version: missing.package.version
                                    )
                                }
                            }
                        }
                        if !changeSet.versionChanged.isEmpty {
                            changeSection(
                                title: "Different versions (\(changeSet.versionChanged.count))",
                                systemImage: "arrow.left.arrow.right",
                                color: .blue
                            ) {
                                ForEach(changeSet.versionChanged) { change in
                                    HStack(spacing: 6) {
                                        Text(change.name)
                                            .font(.callout)
                                        ManagerBadge(manager: change.manager)
                                        Spacer()
                                        Text(change.oldVersion)
                                            .font(.callout)
                                            .strikethrough()
                                            .foregroundStyle(.secondary)
                                        Image(systemName: "arrow.right")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                        Text(change.newVersion)
                                            .font(.callout)
                                            .fontWeight(.semibold)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            coordinator.baselinePayload == nil ? "No Saved Setup Imported" : "No Differences",
            systemImage: "arrow.triangle.2.circlepath",
            description: Text(
                coordinator.baselinePayload == nil
                    ? "Import a snapshot JSON captured on another Mac to see what's different here."
                    : "This Mac matches the saved setup — no differences found."
            )
        )
    }

    private func changeSection(
        title: String,
        systemImage: String,
        color: Color,
        @ViewBuilder rows: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                rows()
            }
        }
    }

    @ViewBuilder
    private var buttonRow: some View {
        Divider()
        HStack {
            if let changeSet = coordinator.baselineChangeSet, !changeSet.removed.isEmpty {
                Button {
                    showingReinstallScript = true
                } label: {
                    Label("Generate Reinstall Script", systemImage: "arrow.counterclockwise.circle")
                }
                .help("Generate a script that reinstalls the \(changeSet.removed.count) package(s) missing from this Mac")
            }
            if coordinator.baselinePayload != nil {
                Button("Clear Saved Setup", role: .destructive) {
                    coordinator.clearBaseline()
                }
            }
            Spacer()
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func reinstallScriptSheet(_ changeSet: SnapshotChangeSet) -> some View {
        let generator = ReinstallScriptGenerator()
        let script = generator.generate(missing: changeSet.removed)
        return ScriptSheetView(
            title: "Reinstall Script Ready",
            filename: "installory-reinstall.sh",
            scriptText: script.scriptText
        )
    }
}

private struct PackageChangeRow: View {
    let name: String
    let manager: PackageManager
    let version: String

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.callout)
            ManagerBadge(manager: manager)
            Spacer()
            if !version.isEmpty {
                Text(version)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
