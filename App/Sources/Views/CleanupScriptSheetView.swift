import InstalloryCore
import SwiftUI

/// Cleanup-specific script sheet. Wraps `ScriptSheetView` with the snapshot-status
/// line and optional denylist warning that are specific to the uninstall flow.
///
/// Takes a `CleanupResult` rather than a bare `GeneratedScript` so it can report
/// truthfully whether a snapshot was captured — when the user chose to skip the
/// snapshot, the sheet must not claim one was taken.
struct CleanupScriptSheetView: View {
    let result: CleanupResult
    @State private var restoreSaveError: String?

    var body: some View {
        ScriptSheetView(
            title: "Cleanup Script Ready",
            filename: "installory-cleanup.sh",
            scriptText: result.script.scriptText
        ) {
            snapshotStatusLine
            if !result.script.warnedDenylisted.isEmpty {
                denylistWarning
            }
            undoSection
        }
        .alert(
            "Couldn't Save Restore Script",
            isPresented: Binding(
                get: { restoreSaveError != nil },
                set: { if !$0 { restoreSaveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { restoreSaveError = nil }
        } message: {
            if let restoreSaveError {
                Text(restoreSaveError)
            }
        }
    }

    /// Offers a way back: the restore script for exactly the packages being
    /// removed. The durable restore point is the `.preCleanup` snapshot (reported
    /// above); this script is the immediate "put it back" companion.
    @ViewBuilder
    private var undoSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("This reinstalls the packages this cleanup script removes. It's the quick way to undo if you change your mind.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView([.vertical, .horizontal]) {
                    Text(result.restoreScript.scriptText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 180)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("Copy Restore Script") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.restoreScript.scriptText, forType: .string)
                    }
                    Button("Save Restore Script\u{2026}") {
                        Task { await saveRestoreScript() }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Undo this removal (restore script)", systemImage: "arrow.uturn.backward.circle")
                .font(.callout)
        }
    }

    private func saveRestoreScript() async {
        let panel = NSSavePanel()
        panel.title = "Save Restore Script"
        panel.nameFieldStringValue = "installory-restore.sh"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // NSSavePanel implicitly starts security-scoped access for its URL; the
        // write is awaited before this scope ends so access stays valid for it.
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            try await ScriptFileWriter.write(result.restoreScript.scriptText, to: url)
            restoreSaveError = nil
        } catch {
            restoreSaveError = "The restore script wasn't written to \(url.lastPathComponent). \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var snapshotStatusLine: some View {
        if result.snapshotTaken {
            Label("Snapshot captured before generation", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        } else if result.snapshotFailed {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snapshot could not be saved")
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text("A snapshot was requested but couldn\u{2019}t be written. Without it, Installory won\u{2019}t be able to undo this removal — proceed with caution.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Label(
                "No snapshot taken — you won\u{2019}t be able to undo this from Installory.",
                systemImage: "info.circle"
            )
            .foregroundStyle(.secondary)
            .font(.callout)
        }
    }

    @ViewBuilder
    private var denylistWarning: some View {
        let names = result.script.warnedDenylisted.map(\.name).joined(separator: ", ")
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Common essentials detected")
                    .fontWeight(.semibold)
                Text("\(names) — these appear in the script as commented-out lines. Uncomment only if you are certain.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview("Snapshot taken") {
    let sample = Package(
        id: "brew::ffmpeg",
        manager: .brew,
        qualifier: nil,
        name: "ffmpeg",
        version: "7.0.1",
        installPath: nil,
        installedAt: nil,
        installedAtConfidence: .low,
        sizeBytes: nil,
        isExplicit: true,
        isReadOnly: false,
        dependencies: [],
        artifactPaths: nil,
        lastSeen: Date()
    )
    let script = ScriptGenerator().generate(packages: [sample])
    return CleanupScriptSheetView(
        result: CleanupResult(
            script: script,
            restoreScript: ReinstallScriptGenerator().generate(removing: [sample]),
            snapshotTaken: true,
            snapshotFailed: false
        )
    )
}

#Preview("Snapshot skipped") {
    let sample = Package(
        id: "brew::ffmpeg",
        manager: .brew,
        qualifier: nil,
        name: "ffmpeg",
        version: "7.0.1",
        installPath: nil,
        installedAt: nil,
        installedAtConfidence: .low,
        sizeBytes: nil,
        isExplicit: true,
        isReadOnly: false,
        dependencies: [],
        artifactPaths: nil,
        lastSeen: Date()
    )
    let script = ScriptGenerator().generate(packages: [sample])
    return CleanupScriptSheetView(
        result: CleanupResult(
            script: script,
            restoreScript: ReinstallScriptGenerator().generate(removing: [sample]),
            snapshotTaken: false,
            snapshotFailed: false
        )
    )
}

#Preview("Snapshot failed") {
    let sample = Package(
        id: "brew::ffmpeg",
        manager: .brew,
        qualifier: nil,
        name: "ffmpeg",
        version: "7.0.1",
        installPath: nil,
        installedAt: nil,
        installedAtConfidence: .low,
        sizeBytes: nil,
        isExplicit: true,
        isReadOnly: false,
        dependencies: [],
        artifactPaths: nil,
        lastSeen: Date()
    )
    let script = ScriptGenerator().generate(packages: [sample])
    return CleanupScriptSheetView(
        result: CleanupResult(
            script: script,
            restoreScript: ReinstallScriptGenerator().generate(removing: [sample]),
            snapshotTaken: false,
            snapshotFailed: true
        )
    )
}
