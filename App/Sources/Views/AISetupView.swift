import InstalloryCore
import SwiftUI

/// "AI Setup": what the user's AI coding tools are set up to do, read straight
/// from their settings files. Read-only; secret values arrive already masked
/// and are never put into a prompt.
struct AISetupView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                content
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("AI Setup")
    }

    // MARK: - Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                titleBlock
                Spacer(minLength: 12)
                checkAgainButton
            }
            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                checkAgainButton
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your AI setup")
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("What your AI coding tools are allowed to do and which add-ons they use, read from their settings files. Installory only looks; it never changes them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let checkedLine {
                Text(checkedLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var checkedLine: String? {
        if coordinator.isDemoMode { return "Showing sample data" }
        if coordinator.isScanning { return "Checking\u{2026}" }
        guard coordinator.aiSetupAudit != nil, let date = coordinator.agentConfigAuditedAt else { return nil }
        return "Last checked \(date.formatted(.relative(presentation: .named)))"
    }

    @ViewBuilder
    private var checkAgainButton: some View {
        if coordinator.aiSetupAccessGranted {
            Button {
                Task { await coordinator.refresh() }
            } label: {
                Label("Check Again", systemImage: "arrow.clockwise")
            }
            .disabled(coordinator.isScanning)
            .help("Read your AI tools' settings again (\u{2318}R)")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !coordinator.aiSetupAccessGranted {
            notGrantedState
        } else if let audit = coordinator.aiSetupAudit {
            AISetupSections(audit: audit)
        } else if coordinator.isScanning {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking your AI setup\u{2026}")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            ContentUnavailableView {
                Label("Not Checked Yet", systemImage: "cpu")
            } description: {
                Text("Installory checks your AI setup each time it scans.")
            } actions: {
                Button("Check Now") {
                    Task { await coordinator.refresh() }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    private var notGrantedState: some View {
        ContentUnavailableView {
            Label("Allow Access to Your Home Folder", systemImage: "folder.badge.questionmark")
        } description: {
            Text("Your AI tools keep their settings in hidden folders inside your home folder, such as ~/.claude and ~/.cursor. Installory needs read-only access to check them. Nothing is changed or sent anywhere.")
        } actions: {
            Button("Allow Home Folder\u{2026}") {
                Task { await coordinator.grantDirectory(suggestedPath: UserHome.directory.path) }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}

// MARK: - Sections

private struct AISetupSections: View {
    let audit: AgentConfigAudit

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            FindingsSection(audit: audit)
            MCPServersSection(audit: audit)
            InstructionFilesSection(files: audit.instructionFiles)
            PermissionsSection(profiles: audit.permissionProfiles)
            if !audit.unreadableFiles.isEmpty {
                UnreadableFilesNote(files: audit.unreadableFiles)
            }
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let explanation: String?
    var count: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if let explanation {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A rounded, subtly filled container shared by every section.
private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }
}

// MARK: - a. Things to look at

private struct FindingsSection: View {
    let audit: AgentConfigAudit
    @State private var showNotes = false

    private var important: [AgentConfigFinding] { audit.findings(atLeast: .warning) }
    private var notes: [AgentConfigFinding] { audit.findings.filter { $0.severity == .info } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Things to look at", explanation: nil, count: important.count)

            if important.isEmpty {
                Card {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No problems found")
                                .font(.headline)
                            Text(notes.isEmpty
                                ? "Your AI tools' settings look healthy."
                                : "Your AI tools' settings look healthy. A few notes are below if you're curious.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                    }
                    .padding(16)
                }
            } else {
                Card {
                    ForEach(Array(important.enumerated()), id: \.element.id) { index, finding in
                        if index > 0 { Divider().padding(.leading, 52) }
                        FindingRow(finding: finding, audit: audit)
                    }
                }
            }

            if !notes.isEmpty {
                DisclosureGroup(isExpanded: $showNotes) {
                    Card {
                        ForEach(Array(notes.enumerated()), id: \.element.id) { index, finding in
                            if index > 0 { Divider().padding(.leading, 52) }
                            FindingRow(finding: finding, audit: audit)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Good to know (\(notes.count))")
                        .font(.headline)
                }
            }
        }
    }
}

// Accessibility crash guard (see commit a65277f): never put
// `.textSelection(.enabled)` on text inside a view that has
// `.accessibilityElement(children: .combine)` or `.accessibilityLabel` on it or
// on an ancestor. SwiftUI recurses resolving the label and overflows the stack
// when VoiceOver or another accessibility client hit-tests the screen. Only
// text that is its own accessibility element (like the explanation below) may
// stay selectable.
private struct FindingRow: View {
    let finding: AgentConfigFinding
    let audit: AgentConfigAudit
    @Environment(AppCoordinator.self) private var coordinator

    private var tint: Color {
        switch finding.severity {
        case .critical: .red
        case .warning: .orange
        case .info: .blue
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: AISetupPresentation.severitySymbol(finding.severity))
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AISetupPresentation.severityTitle(finding.severity))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(finding.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)

                Text(finding.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if let fix = finding.suggestedFix {
                    Label {
                        Text(fix)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lightbulb")
                            .foregroundStyle(.yellow)
                    }
                    .font(.callout)
                    .accessibilityLabel("Suggested fix: \(fix)")
                }

                if !finding.affectedFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(finding.affectedFiles, id: \.self) { file in
                            FilePathRow(url: file)
                        }
                    }
                }

                AskAgentButton(
                    help: finding.isLiteralSecret
                        ? "Copy a prompt that asks your AI assistant to help rotate this key. It names the file and key, never the value."
                        : "Copy a prompt about this finding to paste into your AI assistant. Installory never sends it anywhere."
                ) { agent in
                    coordinator.promptBuilder(for: agent)
                        .findingPrompt(for: AISetupPresentation.promptFinding(for: finding, in: audit))
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
    }
}

/// A file path shown with `~`, plus Reveal in Finder.
private struct FilePathRow: View {
    let url: URL
    @Environment(AppCoordinator.self) private var coordinator
    @State private var revealFailed = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(HomePathRedactor(homeDirectory: UserHome.directory).display(url))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(url.path)
            Button(revealFailed ? "Not Available" : "Reveal in Finder") {
                revealFailed = !coordinator.folderAccess.revealGrantedItemInFinder(at: url)
            }
            .buttonStyle(.link)
            .font(.caption)
            .disabled(coordinator.isDemoMode || revealFailed)
            .help(coordinator.isDemoMode ? "Sample files aren't on this Mac" : "Show this file in Finder")
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - b. MCP servers

private struct MCPServersSection: View {
    let audit: AgentConfigAudit

    var body: some View {
        let groups = AISetupPresentation.serverGroups(audit.servers)
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "MCP servers",
                explanation: "MCP servers are add-ons that give your AI assistant extra abilities, like reading GitHub issues or controlling a browser. Each app keeps its own list.",
                count: groups.count
            )
            if groups.isEmpty {
                Card {
                    Text("None of your AI apps have MCP servers set up.")
                        .foregroundStyle(.secondary)
                        .padding(16)
                }
            } else {
                Card {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { Divider() }
                        ServerGroupRow(group: group, audit: audit)
                    }
                }
            }
        }
    }
}

private struct ServerGroupRow: View {
    let group: AISetupPresentation.ServerGroup
    let audit: AgentConfigAudit

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.name)
                    .font(.headline)
                Text(group.clientNames)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if group.hasDifferentDefinitions {
                    StatusChip(
                        title: "Set up differently",
                        systemImage: "arrow.triangle.branch",
                        tint: .orange,
                        help: "The copies of this server don't start the same way in every app or project."
                    )
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.entries) { entry in
                    ServerEntryRow(entry: entry, statuses: AISetupPresentation.statuses(for: entry, in: audit))
                }
            }
            .padding(.leading, 12)
        }
        .padding(16)
    }
}

private struct ServerEntryRow: View {
    let entry: MCPServerEntry
    let statuses: [AISetupPresentation.ServerStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.client.displayName)
                    .font(.subheadline.weight(.medium))
                Text("\u{00B7}")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(AISetupPresentation.scopeLabel(entry.scope))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .help(AISetupPresentation.scopeHelp(entry.scope))
                ForEach(statuses) { status in
                    StatusChip(
                        title: status.title,
                        systemImage: status.systemImage,
                        tint: status == .disabled ? .secondary : (status == .inlineSecret ? .red : .orange),
                        help: status.help
                    )
                }
            }
            HStack(spacing: 6) {
                Image(systemName: entry.transport == .remote ? "globe" : "terminal")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(AISetupPresentation.runDescription(entry))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [
            entry.client.displayName,
            AISetupPresentation.scopeLabel(entry.scope),
            entry.transport == .remote
                ? AISetupPresentation.runDescription(entry)
                : "Runs \(entry.command ?? "an unknown program")",
        ]
        parts += statuses.map(\.title)
        return parts.joined(separator: ", ")
    }
}

private struct StatusChip: View {
    let title: String
    let systemImage: String
    let tint: Color
    let help: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .fixedSize()
            .help(help)
    }
}

// MARK: - c. Instruction files

private struct InstructionFilesSection: View {
    let files: [InstructionFile]

    var body: some View {
        let groups = AISetupPresentation.instructionGroups(files)
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Instruction files",
                explanation: "Instruction files (like CLAUDE.md and AGENTS.md) are notes your AI tools read at the start of every conversation: your house rules, such as \u{201C}use pnpm\u{201D} or \u{201C}write tests first\u{201D}.",
                count: files.count
            )
            if groups.isEmpty {
                Card {
                    Text("No instruction files found in your home folder or your projects.")
                        .foregroundStyle(.secondary)
                        .padding(16)
                }
            } else {
                Card {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { Divider() }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.files) { file in
                                InstructionFileRow(file: file, projectPath: group.projectPath)
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
    }
}

private struct InstructionFileRow: View {
    let file: InstructionFile
    let projectPath: URL?
    @Environment(AppCoordinator.self) private var coordinator
    /// Mirrors `FilePathRow`: once Finder can't show the file, say so.
    @State private var revealFailed = false

    private var displayName: String {
        if let projectPath, file.path.path.hasPrefix(projectPath.path + "/") {
            return String(file.path.path.dropFirst(projectPath.path.count + 1))
        }
        return HomePathRedactor(homeDirectory: UserHome.directory).display(file.path)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: file.isBrokenSymlink ? "exclamationmark.triangle" : "doc.plaintext")
                .foregroundStyle(file.isBrokenSymlink ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Read by \(file.tool.displayName) \u{00B7} \(AISetupPresentation.sizeLabel(file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button(revealFailed ? "Not Available" : "Reveal") {
                revealFailed = !coordinator.folderAccess.revealGrantedItemInFinder(at: file.path)
            }
            .buttonStyle(.link)
            .font(.caption)
            .disabled(coordinator.isDemoMode || file.isBrokenSymlink || revealFailed)
            .help(revealFailed ? "Installory can\u{2019}t show this file in Finder" : "Show this file in Finder")
            .accessibilityLabel(
                revealFailed
                    ? "\(file.path.lastPathComponent) is not available in Finder"
                    : "Reveal \(file.path.lastPathComponent) in Finder"
            )
        }
    }
}

// MARK: - d. Permissions

private struct PermissionsSection: View {
    let profiles: [PermissionProfile]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Permissions you've granted",
                explanation: "What you've told your AI tools they may do without asking you first. Anything highlighted gives an agent a lot of freedom.",
                count: nil
            )
            if profiles.isEmpty {
                Card {
                    Text("No permission settings found. Your AI tools ask before doing anything risky, which is the safe default.")
                        .foregroundStyle(.secondary)
                        .padding(16)
                }
            } else {
                Card {
                    ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                        if index > 0 { Divider() }
                        PermissionProfileRow(profile: profile)
                    }
                }
            }
        }
    }
}

private struct PermissionProfileRow: View {
    let profile: PermissionProfile
    @State private var showRules = false

    private var secretCount: Int { profile.maskedEnv.filter(\.isLiteralSecret).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(profile.tool.displayName)
                    .font(.headline)
                Text(AISetupPresentation.scopeLabel(profile.scope))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(AISetupPresentation.scopeHelp(profile.scope))
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            FilePathRow(url: profile.configFile)

            if let mode = AISetupPresentation.modeDescription(profile) {
                PermissionLine(systemImage: "hand.raised", text: mode.text, isRisky: mode.isRisky)
            }
            if profile.enableAllProjectMcpServers == true {
                PermissionLine(
                    systemImage: "server.rack",
                    text: "Starts any project's MCP servers without asking",
                    isRisky: true
                )
            }
            if profile.skipDangerousModePermissionPrompt == true {
                PermissionLine(
                    systemImage: "exclamationmark.shield",
                    text: "Skips the warning before \u{201C}run everything\u{201D} mode",
                    isRisky: true
                )
            }
            if secretCount > 0 {
                PermissionLine(
                    systemImage: "key.fill",
                    text: "\(secretCount) \(secretCount == 1 ? "key is" : "keys are") written in this file",
                    isRisky: true
                )
            }

            if !profile.allow.isEmpty {
                allowRules
            }
            if !profile.deny.isEmpty {
                PermissionLine(
                    systemImage: "nosign",
                    text: "\(profile.deny.count) \(profile.deny.count == 1 ? "thing is" : "things are") always blocked",
                    isRisky: false
                )
            }
            ForEach(Array(profile.hooks.enumerated()), id: \.offset) { _, hook in
                hookLine(hook)
            }
        }
        .padding(16)
    }

    private var allowRules: some View {
        let broad = Set(profile.broadAllowRules)
        let count = profile.allow.count
        return DisclosureGroup(isExpanded: $showRules) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(profile.allow, id: \.self) { rule in
                    let explanation = PermissionProfile.broadAllowRuleExplanation(rule)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: broad.contains(rule) ? "exclamationmark.triangle.fill" : "checkmark")
                            .foregroundStyle(broad.contains(rule) ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                            .font(.caption)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule)
                                .font(.caption.monospaced())
                            if let explanation {
                                Text(explanation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(broad.contains(rule) ? "Risky: \(rule). \(explanation ?? "")" : rule)
                }
            }
            .padding(.top, 6)
            .padding(.leading, 4)
        } label: {
            HStack(spacing: 6) {
                PermissionLine(
                    systemImage: "checkmark.seal",
                    text: "\(count) \(count == 1 ? "command or action runs" : "commands or actions run") without asking",
                    isRisky: false
                )
                if !broad.isEmpty {
                    StatusChip(
                        title: "\(broad.count) broad",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange,
                        help: "Some of these rules allow a lot more than one specific command."
                    )
                }
            }
        }
    }

    private func hookLine(_ hook: AgentHook) -> some View {
        let trigger = hook.triggerDescription
        let matcher = hook.matcher.map { " (\($0))" } ?? ""
        return VStack(alignment: .leading, spacing: 3) {
            PermissionLine(
                systemImage: "bolt.fill",
                text: "Runs automatically: \(trigger.prefix(1).lowercased() + trigger.dropFirst())\(matcher)",
                isRisky: false
            )
            ForEach(hook.commands, id: \.self) { command in
                Text(command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.leading, 26)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PermissionLine: View {
    let systemImage: String
    let text: String
    let isRisky: Bool

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: isRisky ? "exclamationmark.triangle.fill" : systemImage)
                .foregroundStyle(isRisky ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        .font(.callout)
        .foregroundStyle(isRisky ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
        .accessibilityLabel(isRisky ? "Risky: \(text)" : text)
    }
}

// MARK: - Unreadable files

private struct UnreadableFilesNote: View {
    let files: [UnreadableConfigFile]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "Installory couldn't read \(files.count) settings \(files.count == 1 ? "file" : "files"), so this page may be incomplete.",
                systemImage: "exclamationmark.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            ForEach(files, id: \.path) { file in
                Text("\(HomePathRedactor(homeDirectory: UserHome.directory).display(file.path)) \u{2014} \(reason(file.reason))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func reason(_ reason: UnreadableConfigFile.Reason) -> String {
        switch reason {
        case .tooLarge: "too large to read"
        case .unreadable: "no access"
        case .invalidFormat: "not in a format Installory understands"
        }
    }
}

#Preview {
    let coordinator = AppCoordinator()
    coordinator.enterDemoMode()
    return AISetupView()
        .environment(coordinator)
        .frame(width: 900, height: 900)
}
