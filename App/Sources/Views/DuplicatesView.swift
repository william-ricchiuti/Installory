import InstalloryCore
import SwiftUI

// MARK: - View

struct DuplicatesView: View {
    @Environment(AppCoordinator.self) private var coordinator

    // MARK: PATH

    /// PATH components at app-launch time, earliest-searched first.
    ///
    /// **Caveat:** A sandboxed GUI app may have a different PATH than the
    /// user's interactive terminal. Results are framed accordingly in the UI.
    private var pathComponents: [String] {
        AppCoordinator.launchPathComponents
    }

    // MARK: Grouped data

    private var grouped: DuplicateAnalysisState {
        coordinator.duplicateAnalysis(pathComponents: pathComponents)
    }

    private var analysisEmptyState: AnalysisEmptyState {
        AnalysisEmptyState.resolve(
            packageCount: coordinator.packages.count,
            isScanning: coordinator.isScanning,
            isDemoMode: coordinator.isDemoMode,
            scanStatuses: coordinator.scanStatuses
        )
    }

    // MARK: Body

    var body: some View {
        @Bindable var coordinator = coordinator
        let allData = grouped
        let data = allData.matching(query: coordinator.searchQuery)
        let hasCrossManager = !data.active.isEmpty
            || !data.potential.isEmpty
            || !data.benign.isEmpty
        let hasMultiLocation = !data.multiLocation.isEmpty

        Group {
            if allData.isEmpty {
                AnalysisEmptyStateView(
                    state: analysisEmptyState,
                    noResultsTitle: "No Duplicates",
                    noResultsSystemImage: "checkmark.circle",
                    noResultsDescription: "No scanned tools are installed by more than one package manager or in multiple managed locations."
                )
            } else if !hasCrossManager && !hasMultiLocation {
                ContentUnavailableView.search(text: coordinator.searchQuery)
            } else {
                List(
                selection: Binding(
                    get: { coordinator.selectedPackage?.id },
                    set: { id in
                        coordinator.selectedPackage = id.flatMap(coordinator.package(id:))
                    }
                )
                ) {
                // ── Intro text ───────────────────────────────────────────
                if hasCrossManager {
                    Section {
                        Text(
                            "These tools are installed by more than one package manager. " +
                            "That can cause version confusion \u{2014} a command like \u{201C}node\u{201D} " +
                            "resolves to whichever install is first on your PATH. " +
                            "Where we can determine which install is active, " +
                            "you\u{2019}ll see which copy \u{201C}Runs first\u{201D} and which is \u{201C}Hidden by another copy\u{201D}. " +
                            "This is based on the environment at app launch " +
                            "and may not match your terminal\u{2019}s PATH. " +
                            "Select an install below to open its detail pane and generate a removal script."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 2)
                        .selectionDisabled()
                    }
                }

                // ── Active conflicts ─────────────────────────────────────
                if !data.active.isEmpty {
                    Section {
                        ForEach(data.active, id: \.group.name) { entry in
                            duplicateGroupSection(entry)
                        }
                    } header: {
                        Label("These can cause the wrong version to run",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                // ── Potential conflicts ──────────────────────────────────
                if !data.potential.isEmpty {
                    Section {
                        ForEach(data.potential, id: \.group.name) { entry in
                            duplicateGroupSection(entry)
                        }
                    } header: {
                        Label("Possible conflicts \u{2014} worth reviewing",
                              systemImage: "questionmark.circle")
                            .foregroundStyle(.orange)
                    }
                }

                // ── Benign groups ────────────────────────────────────────
                if !data.benign.isEmpty {
                    Section {
                        ForEach(data.benign, id: \.group.name) { entry in
                            duplicateGroupSection(entry)
                        }
                    } header: {
                        Label("Likely harmless \u{2014} tools that share a name",
                              systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }

                // ── Same-manager multi-location installs (informational) ─
                if hasMultiLocation {
                    Section {
                        Text(
                            "These packages appear under multiple interpreters or environments. " +
                            "This is usually fine, but can cause version confusion " +
                            "when different tools pick different installs."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 2)
                        .selectionDisabled()

                        ForEach(data.multiLocation) { mlGroup in
                            Section(mlGroup.name) {
                                ForEach(mlGroup.packages) { pkg in
                                    MultiLocationInstallRow(package: pkg)
                                        .tag(pkg.id)
                                }
                            }
                        }
                    } header: {
                        Label("Installed in multiple places (informational)",
                              systemImage: "tray.2")
                            .foregroundStyle(.secondary)
                    }
                }
                }
                .listStyle(.inset)
                .navigationTitle("Duplicates")
            }
        }
        .searchable(
            text: $coordinator.searchQuery,
            placement: .toolbar,
            prompt: "Search duplicates"
        )
        .findCommandFocusable()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CleanupSelectionFooter()
        }
        .onChange(of: coordinator.searchQuery) { _, query in
            let visibleIDs = grouped.matching(query: query).packageIDs
            guard let selectedID = coordinator.selectedPackage?.id,
                  !visibleIDs.contains(selectedID) else {
                return
            }
            coordinator.selectedPackage = nil
        }
    }

    /// One duplicate group with an "Ask your agent" prompt in its header. The
    /// PATH standings computed for the view go into the prompt as-is.
    private func duplicateGroupSection(
        _ entry: (group: DuplicateGroup, standings: [String: PathStanding])
    ) -> some View {
        Section {
            ForEach(entry.group.packages) { pkg in
                DuplicateInstallRow(
                    package: pkg,
                    standing: entry.standings[pkg.id] ?? .unknown
                )
                .tag(pkg.id)
            }
        } header: {
            HStack(spacing: 8) {
                Text(entry.group.name)
                Spacer(minLength: 0)
                AskAgentButton(
                    title: "Ask AI",
                    help: "Copy a prompt that asks your AI assistant which copy of \(entry.group.name) to keep. Installory never sends it anywhere."
                ) { agent in
                    coordinator.promptBuilder(for: agent)
                        .duplicatePrompt(for: entry.group, standings: entry.standings)
                }
                .controlSize(.small)
                .menuStyle(.borderlessButton)
            }
        }
    }
}

private extension DuplicateAnalysisState {
    var isEmpty: Bool {
        active.isEmpty && potential.isEmpty && benign.isEmpty && multiLocation.isEmpty
    }

    var packageIDs: Set<String> {
        var ids: Set<String> = []
        for entry in active {
            ids.formUnion(entry.group.packages.map(\.id))
        }
        for entry in potential {
            ids.formUnion(entry.group.packages.map(\.id))
        }
        for entry in benign {
            ids.formUnion(entry.group.packages.map(\.id))
        }
        for group in multiLocation {
            ids.formUnion(group.packages.map(\.id))
        }
        return ids
    }

    /// A matching member keeps its whole group visible so search never removes
    /// the companion install needed to understand the duplicate relationship.
    func matching(query: String) -> DuplicateAnalysisState {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return self }

        return DuplicateAnalysisState(
            active: active.filter { entry in
                entry.group.packages.contains { $0.matchesSearchQuery(query) }
            },
            potential: potential.filter { entry in
                entry.group.packages.contains { $0.matchesSearchQuery(query) }
            },
            benign: benign.filter { entry in
                entry.group.packages.contains { $0.matchesSearchQuery(query) }
            },
            multiLocation: multiLocation.filter { group in
                group.packages.contains { $0.matchesSearchQuery(query) }
            }
        )
    }
}

// MARK: - Cross-manager install row

private struct DuplicateInstallRow: View {
    let package: Package
    let standing: PathStanding

    var body: some View {
        HStack(spacing: 10) {
            CleanupSelectionToggle(package: package)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ManagerBadge(manager: package.manager)
                    Text(package.version)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    PathStandingBadge(standing: standing)
                }
                if let qualifier = package.qualifier {
                    Text(qualifier)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let path = package.installPath {
                    Text(path.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Multi-location install row

private struct MultiLocationInstallRow: View {
    let package: Package

    var body: some View {
        HStack(spacing: 10) {
            CleanupSelectionToggle(package: package)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ManagerBadge(manager: package.manager)
                    Text(package.version)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let qualifier = package.qualifier {
                    Text(qualifier)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let path = package.installPath {
                    Text(path.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - PATH standing badge

private struct PathStandingBadge: View {
    let standing: PathStanding

    var body: some View {
        switch standing {
        case .wins:
            Text("Runs first")
                .font(.system(.caption2, design: .default, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15))
                .foregroundStyle(Color.green)
                .clipShape(Capsule())
                .help("This copy runs when you type the command (based on the PATH Installory saw at launch)")

        case .shadowed:
            Text("Hidden by another copy")
                .font(.system(.caption2, design: .default, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
                .help("Another copy earlier on your PATH runs instead of this one")

        case .unknown:
            EmptyView()
        }
    }
}

// MARK: - Preview

#Preview {
    DuplicatesView()
        .environment(AppCoordinator())
        .frame(width: 380, height: 600)
}
