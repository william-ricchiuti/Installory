import InstalloryCore
import SwiftUI

/// Presented by RootView when the snapshot preference is `.ask` and the user
/// has initiated a per-package removal. One sheet, one code path — both the
/// detail-pane button and the context menu route here via AppCoordinator.
struct SnapshotChoiceSheet: View {
    let packages: [Package]
    @Environment(AppCoordinator.self) private var coordinator
    @State private var rememberChoice = false

    private var packageNames: String {
        switch packages.count {
        case 1:
            return packages[0].name
        case 2:
            return "\(packages[0].name) and \(packages[1].name)"
        default:
            return "\(packages[0].name) and \(packages.count - 1) others"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Snapshot \(packageNames) before generating the removal script?")
                    .font(.headline)
                Text("A snapshot is what lets Installory generate a reinstall script later. Skip it and this removal can\u{2019}t be undone from Installory.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Remember my choice", isOn: $rememberChoice)

            Text("You can change this at any time in Installory › Settings…")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()

            HStack(spacing: 10) {
                Button("Cancel") {
                    coordinator.cancelRemoval()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Skip Snapshot") {
                    Task {
                        await coordinator.confirmRemoval(
                            packages: packages,
                            takeSnapshot: false,
                            remember: rememberChoice
                        )
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Take Snapshot") {
                    Task {
                        await coordinator.confirmRemoval(
                            packages: packages,
                            takeSnapshot: true,
                            remember: rememberChoice
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .disabled(coordinator.isPreparingRemovalScript)
        }
        .padding(24)
        .frame(width: 420)
    }
}
