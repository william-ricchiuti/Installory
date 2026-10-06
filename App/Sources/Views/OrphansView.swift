import InstalloryCore
import SwiftUI

/// Lists explicitly-installed packages that have no in-inventory dependents
/// within their own package manager — a good starting point for cleanup review.
///
/// **What this view is NOT:**
/// - It does not claim the listed packages are unused or safe to remove.
/// - It only sees same-manager direct dependencies that Installory scanned.
/// - System-wide usage (scripts, other apps, cross-manager tools) is invisible.
struct OrphansView: View {
    @Environment(AppCoordinator.self) private var coordinator

    private var analysisEmptyState: AnalysisEmptyState {
        AnalysisEmptyState.resolve(
            packageCount: coordinator.packages.count,
            isScanning: coordinator.isScanning,
            isDemoMode: coordinator.isDemoMode,
            scanStatuses: coordinator.scanStatuses
        )
    }

    var body: some View {
        @Bindable var coordinator = coordinator
        let allOrphans = coordinator.orphanedPackages
        let orphans = allOrphans.matching(query: coordinator.searchQuery)

        Group {
            if allOrphans.isEmpty {
                emptyState
            } else if orphans.isEmpty {
                ContentUnavailableView.search(text: coordinator.searchQuery)
            } else {
                listView(orphans: orphans)
            }
        }
        .searchable(
            text: $coordinator.searchQuery,
            placement: .toolbar,
            prompt: "Search review candidates"
        )
        .findCommandFocusable()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CleanupSelectionFooter()
        }
        .onChange(of: coordinator.searchQuery) { _, query in
            let visible = coordinator.orphanedPackages.matching(query: query)
            guard let selectedID = coordinator.selectedPackage?.id,
                  !visible.contains(where: { $0.id == selectedID }) else {
                return
            }
            coordinator.selectedPackage = nil
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        AnalysisEmptyStateView(
            state: analysisEmptyState,
            noResultsTitle: "No Review Candidates",
            noResultsSystemImage: "checkmark.seal",
            noResultsDescription: "Every explicitly installed package in the completed scan has at least one same-manager package that depends on it."
        )
    }

    // MARK: - List

    @ViewBuilder
    private func listView(orphans: [Package]) -> some View {
        @Bindable var coordinator = coordinator

        let managers = orderedManagers(from: orphans)

        List(
            selection: Binding(
                get: { coordinator.selectedPackage?.id },
                set: { id in
                    coordinator.selectedPackage = id.flatMap(coordinator.package(id:))
                }
            )
        ) {
            // Honesty banner — must be the first thing the user reads.
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Good first candidates to review")
                        .font(.callout.weight(.semibold))
                    Text(
                        "Nothing \u{201C}in your inventory\u{201D} depends on these packages \u{2014} " +
                        "but that doesn\u{2019}t mean they\u{2019}re unused or safe to remove. " +
                        "Installory only sees same-manager direct dependencies it scanned. " +
                        "System-wide usage (other apps, shell scripts, cross-manager tools) " +
                        "is invisible to this analysis."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .selectionDisabled()
            }

            // One section per manager, sorted by manager raw value.
            ForEach(managers, id: \.self) { manager in
                let managerOrphans = orphans.filter { $0.manager == manager }
                Section(manager.displayName) {
                    ForEach(managerOrphans) { pkg in
                        OrphanRow(package: pkg)
                            .tag(pkg.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle("Review Candidates")
    }

    // MARK: - Helpers

    /// Returns the distinct managers present in `orphans`, ordered by raw value
    /// (matches the sort order used by `orphanedPackages()`).
    private func orderedManagers(from orphans: [Package]) -> [PackageManager] {
        var seen: Set<PackageManager> = []
        var ordered: [PackageManager] = []
        for pkg in orphans {
            if seen.insert(pkg.manager).inserted {
                ordered.append(pkg.manager)
            }
        }
        return ordered
    }
}

// MARK: - Row

private struct OrphanRow: View {
    let package: Package

    var body: some View {
        HStack(spacing: 10) {
            CleanupSelectionToggle(package: package)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(package.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .layoutPriority(1)
                    ManagerBadge(manager: package.manager)
                }
                Text(package.version)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let qualifier = package.qualifier {
                    Text(qualifier)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            if let size = package.sizeBytes {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    OrphansView()
        .environment(AppCoordinator())
        .frame(width: 420, height: 540)
}
