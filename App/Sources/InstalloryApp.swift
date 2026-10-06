import InstalloryCore
import SwiftUI

@main
struct InstalloryApp: App {
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(coordinator)
        }
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Find Packages") {
                    coordinator.focusSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!coordinator.canFocusSearch)
            }

            CommandGroup(after: .sidebar) {
                Button("Show as List") {
                    coordinator.showInventory(as: .list)
                }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(
                    !coordinator.supportsInventoryViewMode
                        || coordinator.inventoryViewMode == .list
                )

                Button("Show as Table") {
                    coordinator.showInventory(as: .table)
                }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(
                    !coordinator.supportsInventoryViewMode
                        || coordinator.inventoryViewMode == .table
                )

                Divider()

                Button("AI Setup") {
                    coordinator.sidebarSelection = .aiSetup
                }
                .keyboardShortcut("3", modifiers: .command)
            }

            CommandMenu("Inventory") {
                Button("Refresh") {
                    Task { await coordinator.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(coordinator.isScanning)

                Button("Snapshot Now") {
                    Task { await coordinator.captureManualSnapshot() }
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(coordinator.packages.isEmpty || coordinator.isScanning)

                Divider()

                Button("Grant Custom Directory\u{2026}") {
                    Task { await coordinator.grantCustomDirectory() }
                }
                .keyboardShortcut("o", modifiers: .command)

                Button(coordinator.isCleanupMode ? "Exit Cleanup Mode" : "Enter Cleanup Mode") {
                    coordinator.isCleanupMode.toggle()
                    if !coordinator.isCleanupMode {
                        coordinator.selectedForCleanup = []
                    }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!coordinator.canEnterCleanupMode)

                Divider()

                Button(coordinator.isDemoMode ? "Exit Demo Mode" : "Load Sample Data") {
                    if coordinator.isDemoMode {
                        coordinator.exitDemoMode()
                    } else {
                        coordinator.enterDemoMode()
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button("Export Inventory as CSV\u{2026}") {
                    Task { await coordinator.exportInventory(format: .csv) }
                }
                .disabled(coordinator.packages.isEmpty)
                .keyboardShortcut("e", modifiers: .command)

                Button("Export Inventory as Markdown\u{2026}") {
                    Task { await coordinator.exportInventory(format: .markdown) }
                }
                .disabled(coordinator.packages.isEmpty)
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Export Inventory as JSON\u{2026}") {
                    Task { await coordinator.exportInventory(format: .json) }
                }
                .disabled(coordinator.packages.isEmpty)
                .keyboardShortcut("e", modifiers: [.command, .option])

                Button("Show Data Folder in Finder") {
                    coordinator.revealDataFolder()
                }

                Divider()

                Menu("Copy My Setup for My AI Assistant") {
                    ForEach(PromptAgent.allCases, id: \.self) { agent in
                        Button(PromptClipboard.menuTitle(for: agent)) {
                            coordinator.copySetupPrompt(for: agent)
                        }
                    }
                }
                .disabled(coordinator.packages.isEmpty)
            }
        }

        Settings {
            SettingsView()
                .environment(coordinator)
        }
    }
}
