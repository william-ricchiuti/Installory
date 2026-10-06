import InstalloryCore
import SwiftUI

/// Reviews the agent-skills inventory: which skills exist across every tool
/// root, which names live in more than one root, which entries are dangling
/// symlinks, and which directories are missing their `SKILL.md` manifest.
struct SkillsView: View {
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
        let analysis = coordinator.agentStackAnalysis
        let skills = coordinator.agentSkillPackages
        let visible = skills.matching(query: coordinator.searchQuery)

        Group {
            if skills.isEmpty {
                emptyState
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: coordinator.searchQuery)
            } else {
                listView(skills: visible, analysis: analysis)
            }
        }
        .searchable(
            text: $coordinator.searchQuery,
            placement: .toolbar,
            prompt: "Search skills"
        )
        .findCommandFocusable()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CleanupSelectionFooter()
        }
        .onChange(of: coordinator.searchQuery) { _, query in
            let visible = coordinator.agentSkillPackages.matching(query: query)
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
            noResultsTitle: "No Agent Skills Found",
            noResultsSystemImage: "wand.and.stars",
            noResultsDescription: "No agent skills were found in the granted skill directories. Grant access to a tool's skills folder (for example ~/.claude/skills or ~/.config/opencode/skills) to inventory its skills."
        )
    }

    // MARK: - List

    @ViewBuilder
    private func listView(skills: [Package], analysis: AgentStackAnalysis) -> some View {
        @Bindable var coordinator = coordinator

        let roots = orderedRoots(from: skills)

        List(
            selection: Binding(
                get: { coordinator.selectedPackage?.id },
                set: { id in
                    coordinator.selectedPackage = id.flatMap(coordinator.package(id:))
                }
            )
        ) {
            if analysis.brokenSymlinkCount > 0
                || analysis.missingManifestCount > 0
                || analysis.duplicatedSkillCount > 0 {
                Section {
                    summaryBanner(analysis: analysis)
                }
            }

            // One section per tool root (qualifier), sorted lexicographically.
            ForEach(roots, id: \.self) { root in
                let rootSkills = skills
                    .filter { $0.qualifier == root }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                Section(sectionTitle(for: root)) {
                    ForEach(rootSkills) { skill in
                        SkillRow(
                            package: skill,
                            isDuplicate: analysis.containsDuplicatedName(skill.name)
                        )
                        .tag(skill.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle("Skills")
    }

    @ViewBuilder
    private func summaryBanner(analysis: AgentStackAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Skills review")
                .font(.callout.weight(.semibold))
            Text(summaryText(analysis: analysis))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .selectionDisabled()
    }

    private func summaryText(analysis: AgentStackAnalysis) -> String {
        var parts: [String] = []
        if analysis.brokenSymlinkCount > 0 {
            parts.append("\(analysis.brokenSymlinkCount) dangling symlink\(analysis.brokenSymlinkCount == 1 ? "" : "s")")
        }
        if analysis.missingManifestCount > 0 {
            parts.append("\(analysis.missingManifestCount) missing SKILL.md")
        }
        if analysis.duplicatedSkillCount > 0 {
            parts.append("\(analysis.duplicatedSkillCount) name\(analysis.duplicatedSkillCount == 1 ? "" : "s") installed in more than one root")
        }
        return parts.isEmpty
            ? "No issues detected across your agent skills."
            : "Found: " + parts.joined(separator: ", ") + "."
    }

    /// Tool label + root path, e.g. "Claude Code — ~/.claude/skills".
    private func sectionTitle(for root: String) -> String {
        let label = toolLabel(for: root)
        let displayPath = root.replacingOccurrences(
            of: UserHome.directory.path,
            with: "~"
        )
        return "\(label) — \(displayPath)"
    }

    private func toolLabel(for root: String) -> String {
        if root.contains("/.claude/") || root.hasSuffix("/.claude") {
            return "Claude Code"
        }
        if root.contains("/.agents/") || root.hasSuffix("/.agents") {
            return "Shared (~/.agents)"
        }
        if root.contains("/.config/opencode") || root.contains("/.opencode") {
            return "opencode"
        }
        return "Agent"
    }

    /// Returns the distinct tool-root paths present in `skills`, sorted
    /// lexicographically (matches the ordering produced by `AgentStackAnalysis`).
    private func orderedRoots(from skills: [Package]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for skill in skills {
            guard let qualifier = skill.qualifier, seen.insert(qualifier).inserted else {
                continue
            }
            ordered.append(qualifier)
        }
        return ordered.sorted()
    }
}

// MARK: - Row

private struct SkillRow: View {
    let package: Package
    let isDuplicate: Bool

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
                    if isDuplicate {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("This skill name is installed in more than one tool root")
                    }
                    if package.isBrokenAgentSkillLink {
                        Image(systemName: "link.badge.minus")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .help("Dangling symlink — target is missing")
                    } else if package.isMissingManifestAgentSkill {
                        Image(systemName: "doc.badge.ellipsis")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .help("No SKILL.md manifest found")
                    }
                }
                if !package.version.isEmpty {
                    Text(package.version)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let target = package.artifactPaths?.first, package.isBrokenAgentSkillLink {
                    Text("→ \(target)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
    SkillsView()
        .environment(AppCoordinator())
        .frame(width: 420, height: 540)
}
