import AppKit
import InstalloryCore
import Foundation
import SwiftUI

struct PackageDetailView: View {
    let package: Package
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showRawRecord = false
    @State private var copiedCommand = false
    @State private var noteDraft = ""
    @State private var noteLoaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                Divider()
                fieldsSection
                Divider()
                userAnnotationsSection
                Divider()
                dependentsSection
                Divider()
                provenanceSection
                Divider()
                removalSection
                Divider()
                rawRecordSection
            }
            .padding(20)
        }
        .frame(minWidth: 300)
        .onAppear {
            if !noteLoaded {
                noteLoaded = true
                noteDraft = coordinator.note(for: package.id) ?? ""
            }
        }
        .onDisappear {
            // Selecting another package replaces this view (`.id(pkg.id)`),
            // which would drop an unsaved draft. Save it like Save Note does.
            guard noteLoaded else { return }
            coordinator.saveNoteDraftIfChanged(noteDraft, for: package.id)
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(package.name)
                    .font(.title2)
                    .fontWeight(.bold)
                Text(package.version)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                // Package-aware lookup so skill and extension summaries show.
                if let desc = coordinator.descriptionStore.description(for: package) {
                    Text(desc)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(coordinator.descriptionStore.descriptionOrFallback(for: package))
                    .foregroundStyle(.tertiary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                ManagerBadge(manager: package.manager)
                HStack(spacing: 8) {
                    Button {
                        coordinator.togglePinned(package.id)
                    } label: {
                        Image(systemName: coordinator.isPinned(package.id)
                            ? "pin.fill"
                            : "pin")
                    }
                    .help(coordinator.isPinned(package.id)
                        ? "Unpin this package"
                        : "Pin this package to the top of the list")

                    Button {
                        coordinator.toggleHidden(package.id)
                    } label: {
                        Image(systemName: coordinator.isHidden(package.id)
                            ? "eye.slash.fill"
                            : "eye.slash")
                    }
                    .help(coordinator.isHidden(package.id)
                        ? "Unhide this package"
                        : "Hide this package from the inventory list")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let installedAt = package.installedAt {
                LabeledContent("Installed") {
                    Text("\(relativeTime(installedAt)) (\(absoluteDate(installedAt)))")
                        .foregroundStyle(.secondary)
                }
            }

            if let installPath = package.installPath {
                LabeledContent("Install path") {
                    HStack(spacing: 8) {
                        Text(installPath.path)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        let exists = coordinator.packageInstallPathExists(at: installPath)
                        Button("Reveal in Finder") {
                            coordinator.revealPackageInstallPath(at: installPath)
                        }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .disabled(!exists)
                        .help(exists ? "Open the install path in Finder" : "File no longer exists at this path")
                    }
                }
            }

            if !package.dependencies.isEmpty {
                LabeledContent("Dependencies") {
                    Text(package.dependencies.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }

            if package.isReadOnly {
                LabeledContent("") {
                    Text("System (read-only)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }

    // MARK: - User annotations section

    private var userAnnotationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Your Notes")
                    .font(.headline)
                if coordinator.isPinned(package.id) {
                    Label("Pinned", systemImage: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if coordinator.isHidden(package.id) {
                    Label("Hidden", systemImage: "eye.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Add a note about this package\u{2026}", text: $noteDraft, axis: .vertical)
                .lineLimit(3, reservesSpace: true)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("Notes are stored locally and travel with the package across rescans.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Save Note") {
                    coordinator.setNote(noteDraft, for: package.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Dependents section

    private var dependentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What Depends On It")
                .font(.headline)

            let directDependents = coordinator.reverseDependencyIndex.dependents(of: package)
            if directDependents.isEmpty {
                Text("Nothing in your inventory depends directly on this package.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(directDependents.count) installed package\(directDependents.count == 1 ? "" : "s") depend on it directly.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ReverseDependencyTree(
                        rootPackages: directDependents,
                        index: coordinator.reverseDependencyIndex
                    )
                }
            }
        }
    }

    // MARK: - Provenance section

    private var provenanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How it was installed")
                .font(.headline)

            if !(coordinator.isDemoMode || coordinator.provenanceCollection) {
                // Provenance is off — show a subtle nudge rather than an empty section.
                Text("Turn on install history in Settings \u{2192} Privacy to see how this was installed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if coordinator.installHistoryNeedsHomeAccess {
                Text("Install history is on but needs read access to your home folder. Allow it in Settings \u{2192} Privacy.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let evidence = coordinator.provenanceByPackageId[package.id] {
                // Evidence found — render the narrative sentence.
                let nameByPackageId = coordinator.inventoryIndex.packageNamesByID
                Text(NarrativeRenderer().render(evidence, package: package, nameByPackageId: nameByPackageId))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let attribution = evidence.agentAttribution {
                    HStack(spacing: 6) {
                        AIBadge()
                        Text("Installed during a \(attribution.agentName) session")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                // Provenance is on but no trace found for this package.
                Text("No install trace found for this package.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Shell history may be truncated, or this package was installed before your history began.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Removal section

    private var removalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Removal Script")
                .font(.headline)

            removalSafetyVerdictBanner

            AskAgentButton(
                help: "Copy a prompt that asks your AI assistant to check whether \(package.name) is still needed before removing it. Installory never sends it anywhere."
            ) { agent in
                removalPrompt(for: agent)
            }

            if package.isReadOnly {
                removalMessage(
                    icon: "lock.fill",
                    text: "This is a system package and cannot be removed."
                )
            } else if package.manager == .mas {
                removalMessage(
                    icon: "info.circle",
                    text: "Mac App Store apps are removed by dragging them from /Applications to the Trash \u{2014} mas has no uninstall command."
                )
            } else if let cmd = ScriptGenerator().removalCommand(for: package) {
                if package.isRemovalScriptEligible(strategy: coordinator.removalStrategy) {
                    removableContent(cmd)
                } else {
                    removalMessage(
                        icon: "info.circle",
                        text: ineligibleRemovalText
                    )
                    rawCommandDisclosure(cmd)
                }
            }
        }
    }

    /// Why no script is offered for a row that has only a review comment
    /// (or a command under the other strategy).
    private var ineligibleRemovalText: String {
        if coordinator.removalStrategy == .uninstall,
           package.isRemovalScriptEligible(strategy: .trash) {
            return "Installory can only remove this by moving it to the Trash. Choose \u{201C}Move to Trash\u{201D} in Cleanup Mode to include it in a script."
        }
        return "Installory can\u{2019}t build a removal command for this. The note below explains how to remove it by hand."
    }

    private func removalPrompt(for agent: PromptAgent) -> AgentPrompt {
        coordinator.promptBuilder(for: agent).removalPrompt(
            for: package,
            dependentsCount: coordinator.reverseDependencyIndex.dependents(of: package).count,
            verdict: coordinator.removalSafety(for: package),
            installedBy: AgentPromptBuilder.installerLabel(
                from: coordinator.provenanceByPackageId[package.id]
            )
        )
    }

    @ViewBuilder
    private var removalSafetyVerdictBanner: some View {
        let verdict = coordinator.removalSafety(for: package)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: verdictSymbol(verdict.safety))
                .foregroundStyle(verdictTint(verdict.safety))
            VStack(alignment: .leading, spacing: 2) {
                Text(verdictLabel(verdict.safety))
                    .font(.callout.weight(.semibold))
                if !verdict.reasons.isEmpty {
                    Text(verdict.reasons.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(verdictTint(verdict.safety).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func verdictSymbol(_ safety: RemovalSafety) -> String {
        switch safety {
        case .safe:       "checkmark.shield"
        case .caution:    "exclamationmark.shield"
        case .leaveAlone: "xmark.shield"
        }
    }

    private func verdictTint(_ safety: RemovalSafety) -> Color {
        switch safety {
        case .safe:       .green
        case .caution:    .orange
        case .leaveAlone: .red
        }
    }

    private func verdictLabel(_ safety: RemovalSafety) -> String {
        switch safety {
        case .safe:       "Safe to remove"
        case .caution:    "Remove with care"
        case .leaveAlone: "Leave this installed"
        }
    }

    @ViewBuilder
    private func removalMessage(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    @ViewBuilder
    private func removableContent(_ cmd: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if Denylist.default.isDenylisted(package) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Other software commonly depends on this package. Review carefully before removing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Button {
                Task { await coordinator.requestRemoval([package]) }
            } label: {
                Label("Create Removal Script\u{2026}", systemImage: "doc.text")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text(removalScriptCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            rawCommandDisclosure(cmd)
        }
    }

    @ViewBuilder
    private func rawCommandDisclosure(_ cmd: String) -> some View {
        if Denylist.default.isDenylisted(package) {
            Text("Raw command hidden for safety. Use the script flow above.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            DisclosureGroup("Advanced command") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(cmd)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cmd, forType: .string)
                        copiedCommand = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedCommand = false
                        }
                    } label: {
                        Label(
                            copiedCommand ? "Copied" : "Copy command",
                            systemImage: copiedCommand ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)

                    Text("Skips the snapshot and review steps. For advanced users.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
        }
    }

    private var removalScriptCaption: String {
        switch coordinator.snapshotBeforeRemoval {
        case .always:
            return "Saves a snapshot so you can undo, then builds a script you review and run yourself."
        case .never:
            return "Builds a script you review and run yourself. No snapshot is saved."
        case .ask:
            return "You\u{2019}ll be asked whether to save a snapshot first, then given a script you review and run yourself."
        }
    }

    // MARK: - Raw record section

    private var rawRecordSection: some View {
        DisclosureGroup("Show raw record", isExpanded: $showRawRecord) {
            let json = encodedJSON()
            ScrollView(.horizontal, showsIndicators: true) {
                Text(json)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.top, 6)
        }
    }

    // MARK: - Helpers

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func absoluteDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func encodedJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(package),
              let string = String(data: data, encoding: .utf8) else {
            return "// Error encoding package"
        }
        return string
    }
}

#Preview {
    PackageDetailView(
        package: Package(
            id: "brew::ffmpeg",
            manager: .brew,
            qualifier: nil,
            name: "ffmpeg",
            version: "6.0_1",
            installPath: URL(fileURLWithPath: "/opt/homebrew/Cellar/ffmpeg/6.0_1"),
            installedAt: Calendar.current.date(byAdding: .month, value: -3, to: Date()),
            installedAtConfidence: .high,
            sizeBytes: 223_000_000,
            isExplicit: true,
            isReadOnly: false,
            dependencies: ["aom", "dav1d", "fdk-aac", "lame", "libass"],
            artifactPaths: nil,
            lastSeen: Date()
        )
    )
    .environment(AppCoordinator())
    .frame(width: 400, height: 600)
}

/// Recursive, expandable tree of reverse dependents.
///
/// Renders each root package as a node whose children are the packages that
/// depend on it, and so on. Cycle-safe: a package already on the current path is
/// shown once without expanding further.
private struct ReverseDependencyTree: View {
    let rootPackages: [Package]
    let index: ReverseDependencyIndex

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rootPackages, id: \.id) { pkg in
                ReverseDependencyNode(package: pkg, index: index, ancestors: [pkg.id])
            }
        }
    }
}

private struct ReverseDependencyNode: View {
    let package: Package
    let index: ReverseDependencyIndex
    let ancestors: Set<String>

    private var dependents: [Package] {
        index.dependents(of: package).filter { !ancestors.contains($0.id) }
    }

    var body: some View {
        if dependents.isEmpty {
            nodeRow
        } else {
            DisclosureGroup {
                ForEach(dependents, id: \.id) { dependent in
                    ReverseDependencyNode(
                        package: dependent,
                        index: index,
                        ancestors: ancestors.union([dependent.id])
                    )
                }
            } label: {
                nodeRow
            }
        }
    }

    private var nodeRow: some View {
        HStack(spacing: 6) {
            Text(package.name)
                .font(.callout)
            ManagerBadge(manager: package.manager)
            if !package.version.isEmpty {
                Text(package.version)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 1)
    }
}
