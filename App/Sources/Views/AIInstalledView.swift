import InstalloryCore
import SwiftUI

/// Displays packages with provenance linked to matching Claude Code sessions.
struct AIInstalledView: View {
    @Environment(AppCoordinator.self) private var coordinator

    private var analysisEmptyState: AnalysisEmptyState {
        AnalysisEmptyState.resolve(
            packageCount: coordinator.packages.count,
            isScanning: coordinator.isScanning,
            isDemoMode: coordinator.isDemoMode,
            scanStatuses: coordinator.scanStatuses
        )
    }

    /// Packages whose provenance evidence carries a `ClaudeCodeContext`.
    /// Shared with the sidebar through the generation-keyed derived-state cache.
    private var aiInstalledPackages: [Package] {
        coordinator.aiInstalledPackages
    }

    var body: some View {
        @Bindable var coordinator = coordinator
        let allPackages = aiInstalledPackages
        let visiblePackages = allPackages.matching(query: coordinator.searchQuery)

        Group {
            if allPackages.isEmpty {
                emptyState
            } else if visiblePackages.isEmpty {
                ContentUnavailableView.search(text: coordinator.searchQuery)
            } else {
                packageList(visiblePackages)
            }
        }
        .searchable(
            text: $coordinator.searchQuery,
            placement: .toolbar,
            prompt: "Search AI-attributed packages"
        )
        .findCommandFocusable()
        .onChange(of: coordinator.searchQuery) { _, query in
            let visible = aiInstalledPackages.matching(query: query)
            guard let selectedID = coordinator.selectedPackage?.id,
                  !visible.contains(where: { $0.id == selectedID }) else {
                return
            }
            coordinator.selectedPackage = nil
        }
    }

    // MARK: - Package list

    private func packageList(_ packages: [Package]) -> some View {
        @Bindable var coordinator = coordinator

        return List(
            selection: Binding(
                get: { coordinator.selectedPackage?.id },
                set: { id in
                    coordinator.selectedPackage = id.flatMap(coordinator.package(id:))
                }
            )
        ) {
            Section {
                explanationHeader
            }
            .selectionDisabled()

            Section {
                ForEach(packages) { pkg in
                    AIInstalledPackageRow(
                        package: pkg,
                        context: coordinator.provenanceByPackageId[pkg.id]?.claudeCodeContext
                    )
                    .tag(pkg.id)
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle("AI Installed")
    }

    // MARK: - Header

    private var explanationHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Evidence links \(aiInstalledPackages.count) package\(aiInstalledPackages.count == 1 ? "" : "s") to AI coding sessions")
                    .fontWeight(.semibold)
                Text("Based on nearby package timestamps and matching Claude Code Bash events. This is a best-effort attribution, and history may be incomplete.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        if analysisEmptyState == .noResults,
           !(coordinator.isDemoMode || coordinator.provenanceCollection) {
            ContentUnavailableView {
                Label("Install Tracing Is Off", systemImage: "sparkles")
            } description: {
                Text("Turn on \u{201C}Trace how packages were installed\u{201D} in Settings \u{2192} Privacy to detect packages installed during AI coding sessions.")
            }
        } else {
            AnalysisEmptyStateView(
                state: analysisEmptyState,
                noResultsTitle: "No AI-Attributed Packages",
                noResultsSystemImage: "sparkles",
                noResultsDescription: "The completed scan found no package evidence linked to an AI coding session. Install history may still be incomplete."
            )
        }
    }
}

// MARK: - Package row

private struct AIInstalledPackageRow: View {
    let package: Package
    let context: ProvenanceEvidence.ClaudeCodeContext?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Name + manager + AI badge + version
            HStack(spacing: 8) {
                Text(package.name)
                    .fontWeight(.semibold)
                ManagerBadge(manager: package.manager)
                AIBadge()
                Spacer(minLength: 0)
                Text(package.version)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let ctx = context {
                attributionDetail(ctx)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func attributionDetail(_ ctx: ProvenanceEvidence.ClaudeCodeContext) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Evidence suggests this was installed during a Claude Code session")
                .font(.caption)
                .foregroundStyle(.secondary)
                .italic()

            if let summary = ctx.sessionSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 4) {
                Image(systemName: "terminal")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(ctx.bashInvocation)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(ctx.projectPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let ts = ctx.timestamp {
                Text(ts, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - AI badge

/// A subtle badge consistent with `ManagerBadge` styling but indicating
/// AI assistant attribution rather than a package manager.
struct AIBadge: View {
    var body: some View {
        Text("AI")
            .font(.system(.caption2, design: .default, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.purple.opacity(0.15))
            .foregroundStyle(Color.purple)
            .clipShape(Capsule())
            .accessibilityLabel("Evidence of an AI-assisted install")
            .accessibilityAddTraits(.isStaticText)
            .help("Installory found matching local Claude Code evidence")
    }
}

#Preview {
    AIInstalledView()
        .environment(AppCoordinator())
        .frame(width: 400, height: 500)
}
