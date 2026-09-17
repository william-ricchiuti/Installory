import AppKit
import InstalloryCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }

            ScanningTab()
                .tabItem { Label("Scanning", systemImage: "magnifyingglass") }

            PrivacyTab()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 360)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        Form {
            Section {
                Picker("Snapshot before removing a package", selection: $coordinator.snapshotBeforeRemoval) {
                    ForEach(SnapshotPreference.allCases, id: \.self) { pref in
                        Text(pref.displayName).tag(pref)
                    }
                }
                .pickerStyle(.inline)
                Text("Batch cleanup always captures a snapshot regardless of this setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Snapshots")
            }

            Section {
                if coordinator.isDemoMode {
                    Label("Demo mode is on — showing sample data.", systemImage: "wand.and.stars")
                        .foregroundStyle(.secondary)
                    Button("Exit Demo Mode") { coordinator.exitDemoMode() }
                } else {
                    Button("Load Sample Data") { coordinator.enterDemoMode() }
                    Text("Loads a pre-populated sample inventory so you can explore every feature without granting access to any folders.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Demo Mode")
            }

            Section {
                Button("Show Onboarding Again") { coordinator.resetOnboarding() }
                Text("Re-displays the welcome flow on next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Onboarding")
            }
        }
        .formStyle(.grouped)
        .onChange(of: coordinator.snapshotBeforeRemoval) { _, _ in coordinator.persistSettings() }
    }
}

// MARK: - Scanning

private struct ScanningTab: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        Form {
            Section {
                Toggle("Scan on launch", isOn: $coordinator.scanOnLaunch)
                Text("When off, Installory shows the last scan result on launch. Use ⌘R to scan manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Scanning")
            }

            Section {
                Button("Export Inventory as CSV\u{2026}") {
                    Task { await coordinator.exportInventory(format: .csv) }
                }
                .disabled(coordinator.packages.isEmpty)

                Button("Export Inventory as Markdown\u{2026}") {
                    Task { await coordinator.exportInventory(format: .markdown) }
                }
                .disabled(coordinator.packages.isEmpty)

                Button("Export Inventory as JSON\u{2026}") {
                    Task { await coordinator.exportInventory(format: .json) }
                }
                .disabled(coordinator.packages.isEmpty)

                Button("Export Environment Report\u{2026}") {
                    Task { await coordinator.exportEnvironmentReport() }
                }
                .disabled(coordinator.packages.isEmpty)

                Text("Saves a copy of the current inventory to a file you choose. The environment report includes duplicates, review candidates, and a full package table. Exports never leave your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Export")
            }
        }
        .formStyle(.grouped)
        .onChange(of: coordinator.scanOnLaunch) { _, _ in coordinator.persistSettings() }
        .actionErrorAlert(coordinator: coordinator)
    }
}

// MARK: - Privacy

private struct PrivacyTab: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showClearEvidenceConfirmation = false

    var body: some View {
        @Bindable var coordinator = coordinator
        Form {
            Section {
                Label("Installory makes no network connections.", systemImage: "network.slash")
                Label("All data stays on your Mac.", systemImage: "lock.shield")
                Label("Installory reads, never writes, your package directories.", systemImage: "eye")
                Label("Cleanup scripts are generated, never executed.", systemImage: "terminal")
            } header: {
                Text("How Installory handles your data")
            }

            // MARK: Provenance section

            Section {
                Toggle("Trace how packages were installed", isOn: $coordinator.provenanceCollection)
                    .disabled(coordinator.isScanning)

                Text("When enabled, Installory reads your shell history and agent session logs (Claude Code, Codex, opencode) to identify which packages were installed when, and by what. Everything stays on your Mac \u{2014} nothing is sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Files that will be read:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Group {
                        Text("\u{2022} ~/.zsh_history")
                        Text("\u{2022} ~/.bash_history")
                        Text("\u{2022} ~/.local/share/fish/fish_history")
                        Text("\u{2022} ~/.claude/projects/")
                        Text("\u{2022} ~/.codex/sessions/")
                        Text("\u{2022} ~/.local/share/opencode/opencode.db")
                    }
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                }

                if coordinator.provenanceCollection {
                    if coordinator.provenanceAccessGranted {
                        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
                        let grantedPath = coordinator.folderAccess.grantedPath(forPrefix: homePath) ?? homePath
                        Label("Access granted to \(grantedPath)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                        Button("Revoke Access", role: .destructive) {
                            coordinator.revokeProvenanceAccess()
                        }
                        .disabled(coordinator.isScanning)
                    } else {
                        Button("Grant read access\u{2026}") {
                            Task { await coordinator.requestProvenanceAccess() }
                        }
                        .disabled(coordinator.isScanning)
                        Text("Installory will ask you to select your home folder so it can read shell history and agent session logs. You can revoke access at any time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Provenance")
            }

            Section {
                Button("Show Installory Data Folder\u{2026}") {
                    coordinator.revealDataFolder()
                }
                Text("Reveals ~/Library/Application Support/Installory in Finder. The SQLite cache and snapshots live there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Local Storage")
            }

            Section {
                Link("Read the full privacy policy", destination: URL(string: "https://installory.app/privacy/")!)
            } header: {
                Text("Online")
            }
        }
        .formStyle(.grouped)
        .onChange(of: coordinator.provenanceCollection) { _, newValue in
            coordinator.persistSettings()
            if !newValue {
                // User turned off provenance — offer to erase stored evidence.
                showClearEvidenceConfirmation = true
            }
        }
        .confirmationDialog(
            "Clear stored install history?",
            isPresented: $showClearEvidenceConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                Task { await coordinator.clearProvenanceEvidence() }
            }
            Button("Keep History", role: .cancel) {}
        } message: {
            Text("Installory will no longer trace how packages were installed. Stored evidence will be deleted from the local cache.")
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: version)
                LabeledContent("Source", value: "MIT-licensed open source")
            } header: {
                Text("Installory")
            }

            Section {
                Link("Website", destination: URL(string: "https://installory.app/")!)
                Link("GitHub repository", destination: URL(string: "https://github.com/william-ricchiuti/Installory")!)
                Link("Support", destination: URL(string: "https://installory.app/support/")!)
            } header: {
                Text("Links")
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SettingsView()
        .environment(AppCoordinator())
}
