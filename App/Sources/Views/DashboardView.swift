import InstalloryCore
import SwiftUI

/// The Home screen. Leads with a plain-English "checkup" (four rows, each with
/// a status, one sentence, and a button that goes where the answer is), then a
/// compact grid of numbers. Read-only: everything comes from coordinator state.
struct DashboardView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        Group {
            if coordinator.packages.isEmpty {
                emptyState
            } else {
                dashboard
            }
        }
        .navigationTitle("Home")
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                CheckupCard(rows: coordinator.checkupRows)
                atAGlance
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                titleBlock
                Spacer(minLength: 12)
                shareSetupButton
            }
            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                shareSetupButton
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your Mac\u{2019}s coding setup")
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        if coordinator.isScanning { return "Scanning\u{2026}" }
        if coordinator.isDemoMode { return "Showing sample data" }
        return coordinator.lastScanSummary ?? "Not scanned yet"
    }

    private var shareSetupButton: some View {
        AskAgentButton(
            title: "Copy My Setup for My AI Assistant",
            systemImage: "doc.on.clipboard",
            help: "Copy a summary of your installed tools to paste into your AI assistant, so its advice fits your Mac. Installory never sends it anywhere."
        ) { agent in
            coordinator.setupPrompt(for: agent)
        }
    }

    // MARK: - At a glance

    private var atAGlance: some View {
        let bundle = coordinator.freeUpSpaceBundle
        let aiThisWeek = coordinator.aiInstalledThisWeekCount()
        let orphanCount = coordinator.orphanedPackages.count
        let duplicateCount = coordinator.duplicateGroups.count
        let brokenCount = coordinator.agentStackAnalysis.brokenSymlinkCount
            + coordinator.agentStackAnalysis.missingManifestCount

        return VStack(alignment: .leading, spacing: 12) {
            Text("At a glance")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 190), spacing: 12)],
                spacing: 12
            ) {
                StatCard(
                    title: "Packages tracked",
                    value: "\(coordinator.packages.count)",
                    systemImage: "shippingbox",
                    tint: .blue
                ) {
                    coordinator.sidebarSelection = .all
                }

                StatCard(
                    title: "Size on disk",
                    value: byteLabel(coordinator.diskUsageSummary.totalKnownBytes),
                    systemImage: "chart.bar.xaxis",
                    tint: .indigo
                ) {
                    coordinator.sidebarSelection = .diskUsage
                }

                if !bundle.isEmpty {
                    StatCard(
                        title: "Safe to free up",
                        value: byteLabel(bundle.totalReclaimableBytes),
                        subtitle: "\(bundle.candidates.count) \(bundle.candidates.count == 1 ? "package" : "packages")",
                        systemImage: "sparkles",
                        tint: .green
                    ) {
                        coordinator.sidebarSelection = .diskUsage
                    }
                }

                if aiThisWeek > 0 {
                    StatCard(
                        title: "AI installed this week",
                        value: "\(aiThisWeek)",
                        systemImage: "sparkle",
                        tint: .pink
                    ) {
                        coordinator.sidebarSelection = .aiInstalled
                    }
                }

                if orphanCount > 0 {
                    StatCard(
                        title: "Possibly unused",
                        value: "\(orphanCount)",
                        systemImage: "leaf.circle",
                        tint: .orange
                    ) {
                        coordinator.sidebarSelection = .orphans
                    }
                }

                if duplicateCount > 0 {
                    StatCard(
                        title: "Duplicates",
                        value: "\(duplicateCount)",
                        systemImage: "doc.on.doc",
                        tint: .purple
                    ) {
                        coordinator.sidebarSelection = .duplicates
                    }
                }

                if brokenCount > 0 {
                    StatCard(
                        title: "Broken skills",
                        value: "\(brokenCount)",
                        systemImage: "link.badge.plus",
                        tint: .red
                    ) {
                        coordinator.sidebarSelection = .skills
                    }
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Welcome to Installory", systemImage: "shippingbox")
        } description: {
            Text("Grant Installory read access to a package directory, then run a scan to see what's installed on this Mac.")
        } actions: {
            Button("Grant Access") {
                Task { await coordinator.grantCustomDirectory() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func byteLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Checkup

private struct CheckupCard: View {
    let rows: [CheckupRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Checkup")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider().padding(.leading, 64)
                    }
                    CheckupRowView(row: row)
                }
            }
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.6),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            }
        }
    }
}

private struct CheckupRowView: View {
    let row: CheckupRow
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            statusIndicator

            VStack(alignment: .leading, spacing: 3) {
                Text(row.areaTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(row.headline)
                    .font(.headline)
                    .contentTransition(.numericText())
                Text(row.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            if let title = row.actionTitle, let action = row.action {
                Button(title) { perform(action) }
                    .buttonStyle(.bordered)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .animation(reduceMotion ? nil : .smooth, value: row)
    }

    private var statusIndicator: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(tint.opacity(0.14), in: Circle())
            .symbolEffect(.pulse, isActive: coordinator.isScanning && !reduceMotion)
            .symbolEffect(.bounce, value: reduceMotion ? .unknown : row.status)
            .accessibilityLabel(row.statusAccessibilityLabel)
            .help(row.statusAccessibilityLabel)
    }

    private var symbol: String {
        switch row.status {
        case .good: "checkmark"
        case .attention: "exclamationmark"
        case .unknown: "questionmark"
        }
    }

    private var tint: Color {
        switch row.status {
        case .good: .green
        case .attention: .orange
        case .unknown: .secondary
        }
    }

    private func perform(_ action: CheckupAction) {
        switch action {
        case .navigate(let destination):
            coordinator.sidebarSelection = destination
        case .grantHomeAccess:
            Task { await coordinator.grantDirectory(suggestedPath: UserHome.directory.path) }
        case .openSettings:
            openSettings()
        case .scan:
            Task { await coordinator.refresh() }
        }
    }
}

// MARK: - Stat card

private struct StatCard: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    let systemImage: String
    let tint: Color
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(value)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .smooth, value: value)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.6),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(value)")
    }
}

#Preview {
    let coordinator = AppCoordinator()
    coordinator.enterDemoMode()
    coordinator.sidebarSelection = .dashboard
    return DashboardView()
        .environment(coordinator)
        .frame(width: 760, height: 720)
}
