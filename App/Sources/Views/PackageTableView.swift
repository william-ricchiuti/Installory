import Foundation
import InstalloryCore
import SwiftUI

/// Dense, sortable presentation of the already-filtered live inventory.
///
/// The caller owns filtering while this view applies only the table descriptor
/// sequence. Selection and cleanup state stay coordinator-owned so switching
/// between List and Table never creates a second source of truth.
struct PackageTableView: View {
    @Environment(AppCoordinator.self) private var coordinator

    let packages: [Package]
    @Binding var sortOrder: [PackageTableSortDescriptor]

    var body: some View {
        let sortedPackages = packages.sortedForTable(
            using: sortOrder,
            pinnedFirst: coordinator.pinnedIDs
        )

        Table(
            of: Package.self,
            selection: selectedPackageID,
            sortOrder: $sortOrder
        ) {
            TableColumn(
                "Name",
                sortUsing: PackageTableSortDescriptor(column: .name)
            ) { package in
                HStack(spacing: 6) {
                    CleanupSelectionToggle(package: package)
                        .environment(coordinator)
                    Text(package.name)
                        .lineLimit(1)
                        .help(package.name)
                        .accessibilityLabel("Package name \(package.name)")
                }
            }
            .width(min: 160, ideal: 240)

            TableColumn(
                "Manager",
                sortUsing: PackageTableSortDescriptor(column: .manager)
            ) { package in
                Text(package.manager.displayName)
                    .lineLimit(1)
                    .help(package.manager.displayName)
                    .accessibilityLabel("Manager \(package.manager.displayName)")
            }
            .width(min: 110, ideal: 130, max: 150)

            TableColumn(
                "Version",
                sortUsing: PackageTableSortDescriptor(column: .version)
            ) { package in
                Text(package.version)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .help(package.version)
                    .accessibilityLabel("Version \(package.version)")
            }
            .width(min: 90, ideal: 110, max: 130)

            TableColumn(
                "Size",
                sortUsing: PackageTableSortDescriptor(column: .size)
            ) { package in
                let label = sizeLabel(for: package)
                Text(label)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(sizeHelp(for: package))
                    .accessibilityLabel(sizeAccessibilityLabel(for: package))
            }
            .width(min: 90, ideal: 100, max: 120)
            .alignment(.trailing)

            TableColumn(
                "Installed",
                sortUsing: PackageTableSortDescriptor(column: .installed)
            ) { package in
                Text(installedLabel(for: package))
                    .lineLimit(1)
                    .help(installedHelp(for: package))
                    .accessibilityLabel(installedAccessibilityLabel(for: package))
            }
            .width(min: 120, ideal: 145, max: 170)
        } rows: {
            ForEach(sortedPackages) { package in
                TableRow(package)
                    .contextMenu {
                        PackageContextMenu(
                            package: package,
                            onRemove: package.isRemovalScriptEligible(strategy: coordinator.removalStrategy) ? {
                                Task { await coordinator.requestRemoval([package]) }
                            } : nil
                        )
                        .environment(coordinator)
                    }
            }
        }
    }

    private var selectedPackageID: Binding<Package.ID?> {
        Binding(
            get: { coordinator.selectedPackage?.id },
            set: { id in
                coordinator.selectedPackage = id.flatMap(coordinator.package(id:))
            }
        )
    }

    // MARK: - Cell formatting

    private func sizeLabel(for package: Package) -> String {
        guard let size = package.sizeBytes else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func sizeHelp(for package: Package) -> String {
        guard package.sizeBytes != nil else { return "Size unknown" }
        return sizeLabel(for: package)
    }

    private func sizeAccessibilityLabel(for package: Package) -> String {
        guard package.sizeBytes != nil else { return "Size unknown" }
        return "Size \(sizeLabel(for: package))"
    }

    private func installedLabel(for package: Package) -> String {
        guard let date = package.installedAt else { return "Unknown" }

        let relative = relativeDateLabel(date)
        switch package.installedAtConfidence {
        case .low, .unknown:
            return "\(relative) (est.)"
        case .medium, .high:
            return relative
        }
    }

    private func installedHelp(for package: Package) -> String {
        guard let date = package.installedAt else { return "Installed date unknown" }

        let absolute = absoluteDateLabel(date)
        switch package.installedAtConfidence {
        case .low, .unknown:
            return "Installed \(absolute) (estimated)"
        case .medium, .high:
            return "Installed \(absolute)"
        }
    }

    private func installedAccessibilityLabel(for package: Package) -> String {
        guard let date = package.installedAt else { return "Installed date unknown" }

        let relative = relativeDateLabel(date)
        switch package.installedAtConfidence {
        case .low, .unknown:
            return "Installed \(relative), estimated"
        case .medium, .high:
            return "Installed \(relative)"
        }
    }

    private func relativeDateLabel(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    private func absoluteDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
