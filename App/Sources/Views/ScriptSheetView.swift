import AppKit
import InstalloryCore
import SwiftUI
import UniformTypeIdentifiers

enum ScriptFileWriter {
    static func write(_ script: String, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try script.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }
}

/// A generic sheet that displays a generated shell script with Copy, Save, and Done actions.
///
/// Used by both the cleanup flow (uninstall) and the restore flow (reinstall).
/// The `Warning` slot accepts any additional content shown between the title and the
/// script body — pass the denylist warning for cleanup, `EmptyView` for reinstall.
struct ScriptSheetView<Warning: View>: View {
    let title: String
    let filename: String
    let scriptText: String
    @ViewBuilder let warningContent: () -> Warning
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
            warningContent()
            scriptSection
            howToRunDisclosure
            safetyReminder
            buttonRow
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 480)
        .alert(
            "Couldn't Save Script",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            if let saveError {
                Text(saveError)
            }
        }
    }

    private var scriptSection: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(scriptText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(minHeight: 200)
    }

    /// Short, beginner-friendly steps. Saving and running with `bash` avoids
    /// zsh history expansion ("event not found") that pasting can trigger.
    private var howToRunDisclosure: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Click **Save as .sh\u{2026}** and save the script, for example to your Downloads folder.")
                Text("2. Open Terminal and run it with bash, for example:")
                Text(verbatim: "bash ~/Downloads/\(filename)")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                Text("Pasting a long script straight into Terminal can fail with \u{201C}event not found\u{201D}, so saving it and running it with bash is more reliable.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        } label: {
            Label("How to run this", systemImage: "questionmark.circle")
                .font(.callout)
        }
    }

    private var safetyReminder: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Review this script here first. When you are ready, copy or save it and run it yourself in Terminal. **Installory never runs commands for you.**")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var buttonRow: some View {
        HStack {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(scriptText, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    copied = false
                }
            } label: {
                Label(
                    copied ? "Copied" : "Copy to Clipboard",
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
            }
            // Not plain ⌘C: the script text is selectable, and binding ⌘C here would
            // silently copy the whole script when the user meant to copy their selection.
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Copy the whole script (\u{21E7}\u{2318}C)")

            Button {
                Task { await saveScript() }
            } label: {
                Label("Save as .sh\u{2026}", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)

            Spacer()

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func saveScript() async {
        let panel = NSSavePanel()
        panel.title = "Save Script"
        panel.nameFieldStringValue = filename
        if let shellType = UTType(filenameExtension: "sh") {
            panel.allowedContentTypes = [shellType]
        }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // NSSavePanel implicitly starts security-scoped access for its URL.
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            try await ScriptFileWriter.write(scriptText, to: url)
            saveError = nil
        } catch {
            saveError = "The script wasn't written to \(url.lastPathComponent). \(error.localizedDescription)"
        }
    }
}

extension ScriptSheetView where Warning == EmptyView {
    init(title: String, filename: String, scriptText: String) {
        self.init(
            title: title,
            filename: filename,
            scriptText: scriptText,
            warningContent: { EmptyView() }
        )
    }
}
