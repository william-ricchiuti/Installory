import Foundation
import InstalloryCore
import SwiftUI

/// First-run walkthrough: welcome, read-only promise, folder access,
/// optional install history, and the first scan.
struct OnboardingView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: OnboardingPage = .welcome
    @State private var isGoingForward = true
    @State private var isRequestingAccess = false
    /// Set when the user granted a folder but it didn't cover the home folder.
    @State private var grantMissedHome = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                pageContent
                    .id(page)
                    .transition(pageTransition)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 440, idealHeight: 500)
        // Esc must not close the sheet: completion happens only via Skip,
        // Start First Scan, or Explore with Sample Data.
        .interactiveDismissDisabled()
        .onExitCommand {
            guard !isRequestingAccess, let destination = page.escapeDestination else { return }
            go(to: destination)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            OnboardingPageIndicator(page: page)
            Spacer()
            // No `.cancelAction` shortcut: Esc goes Back (see `onExitCommand`)
            // so a stray keypress can't permanently skip the guide.
            Button("Skip") { complete() }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Close this guide. You can show it again from Settings.")
                .accessibilityHint("Closes the guide without scanning")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                coordinator.enterDemoMode()
                dismiss()
            } label: {
                Label("Explore with Sample Data", systemImage: "wand.and.stars")
            }
            .buttonStyle(.link)
            .help("Load a sample inventory so you can try every feature without allowing any folders.")

            Spacer()

            if let previous = page.previous {
                Button("Back") { go(to: previous) }
                    .disabled(isRequestingAccess)
            }
            primaryButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch page {
        case .access where accessPlan.primaryAction == .allowHome:
            Button(OnboardingAccessPrimaryAction.allowHome.title) { allowHome() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isRequestingAccess)
                .accessibilityHint("Opens a folder picker set to your home folder")
        case .done:
            Button("Start First Scan") { startFirstScan() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        default:
            Button("Continue") {
                if let next = page.next { go(to: next) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isRequestingAccess)
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .welcome: welcomePage
        case .promise: promisePage
        case .access: accessPage
        case .history: historyPage
        case .done: donePage
        }
    }

    private var welcomePage: some View {
        OnboardingPageLayout(
            systemImage: "shippingbox",
            title: "See what\u{2019}s on your Mac, and what your AI tools did."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                OnboardingBullet(
                    systemImage: "square.stack.3d.up",
                    title: "What\u{2019}s installed",
                    detail: "Homebrew, Python, Node and more, in one list."
                )
                OnboardingBullet(
                    systemImage: "sparkles",
                    title: "Your AI tools",
                    detail: "Claude Code, Codex, Cursor and opencode: their skills, extensions and what they installed."
                )
                OnboardingBullet(
                    systemImage: "leaf",
                    title: "What\u{2019}s safe to clean up",
                    detail: "Clear verdicts, so you know what you can remove."
                )
            }
            Text("Small colored badges tell you which installer added each tool.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var promisePage: some View {
        OnboardingPageLayout(
            systemImage: "lock.shield",
            title: "Look, don\u{2019}t touch",
            message: "Installory only reads. It\u{2019}s safe to explore."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                OnboardingBullet(
                    systemImage: "hand.raised",
                    title: "Never changes anything",
                    detail: "It never installs, deletes or changes anything on your Mac."
                )
                OnboardingBullet(
                    systemImage: "lock.shield",
                    title: "Your data stays on your Mac",
                    detail: "Installory never sends your data anywhere and has no internet code of its own."
                )
                OnboardingBullet(
                    systemImage: "doc.text.magnifyingglass",
                    title: "You stay in charge of cleanup",
                    detail: "Cleanup is a script you read first and run yourself in Terminal (the Mac\u{2019}s command-line app)."
                )
            }
        }
    }

    private var accessPage: some View {
        let plan = accessPlan
        return OnboardingPageLayout(
            systemImage: "folder.badge.person.crop",
            title: "Allow your home folder",
            message: "macOS keeps apps out of your folders until you pick them. Installory needs your home folder (\(homeFolderName)) to find your packages and AI tools. It can only read, never write."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                OnboardingGrantRow(
                    title: "Home folder",
                    path: plan.homePath,
                    granted: plan.homeGranted
                )
                if plan.showsHomebrewGrantedRow, let brew = plan.homebrewPath {
                    OnboardingGrantRow(title: "Homebrew", path: brew, granted: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if grantMissedHome && !plan.homeGranted {
                Label(
                    "That folder was added. To see your AI tools, pick your home folder, \(homeFolderName).",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            OnboardingReadsList()

            VStack(spacing: 6) {
                if plan.showsHomebrewButton, let brew = plan.homebrewPath {
                    Button("Also Allow Homebrew") { grant(brew) }
                        .disabled(isRequestingAccess)
                        .help("Homebrew lives in \(brew), outside your home folder.")
                        .accessibilityHint("Opens a folder picker set to \(brew)")
                }
                Button("Choose Folders Myself\u{2026}") { chooseCustom() }
                    .buttonStyle(.link)
                    .disabled(isRequestingAccess)
            }
        }
    }

    private var historyPage: some View {
        let toggleState = OnboardingHistoryToggleState.make(
            homeGranted: accessPlan.homeGranted,
            provenanceEnabled: coordinator.provenanceCollection
        )
        return OnboardingPageLayout(
            systemImage: "clock.arrow.circlepath",
            title: "Install history (optional)",
            message: "Installory can match each tool to the terminal command or AI session that installed it, by reading your shell history (the list of commands you\u{2019}ve typed) and Claude Code, Codex and opencode session logs on this Mac."
        ) {
            Toggle(isOn: historyBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show how each tool was installed")
                    Text("Off by default. Everything is redacted and stays on your Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(!toggleState.isEnabled || coordinator.isScanning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHint(
                toggleState.isEnabled
                    ? "Turns on reading shell history and AI session logs during scans"
                    : "Unavailable until you allow your home folder"
            )

            if !toggleState.isEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "This needs your home folder, because that\u{2019}s where these logs live.",
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Button("Allow Home Folder") { allowHome() }
                        .disabled(isRequestingAccess)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("You can change this later in Settings \u{2192} Privacy.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var donePage: some View {
        let plan = accessPlan
        return OnboardingPageLayout(
            systemImage: "checkmark.circle",
            title: "You\u{2019}re all set",
            message: OnboardingFinish.summary(
                homeGranted: plan.homeGranted,
                homebrewGranted: plan.homebrewGranted,
                anyGrant: coordinator.folderAccess.hasAnyGrant,
                historyOn: coordinator.provenanceCollection
            )
        ) {
            EmptyView()
        }
    }

    // MARK: - Derived state

    private var accessPlan: OnboardingAccessPlan {
        OnboardingAccessPlan.make(
            homePath: UserHome.directory.path,
            grantedPaths: coordinator.folderAccess.grantedPaths,
            directoryExists: OnboardingAccessPlan.liveDirectoryExists
        )
    }

    private var homeFolderName: String { UserHome.directory.lastPathComponent }

    private var historyBinding: Binding<Bool> {
        Binding(
            get: { coordinator.provenanceCollection },
            set: { newValue in
                coordinator.provenanceCollection = newValue
                coordinator.persistSettings()
            }
        )
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: isGoingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: isGoingForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    // MARK: - Actions

    private func go(to destination: OnboardingPage) {
        isGoingForward = destination.rawValue > page.rawValue
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            page = destination
        }
    }

    private func allowHome() {
        runGrant {
            let granted = await coordinator.grantDirectory(suggestedPath: UserHome.directory.path)
            if granted {
                grantMissedHome = !accessPlan.homeGranted
            }
        }
    }

    private func grant(_ path: String) {
        runGrant { _ = await coordinator.grantDirectory(suggestedPath: path) }
    }

    private func chooseCustom() {
        runGrant { _ = await coordinator.grantCustomDirectory() }
    }

    private func runGrant(_ operation: @escaping @MainActor () async -> Void) {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        Task { @MainActor in
            await operation()
            isRequestingAccess = false
        }
    }

    private func startFirstScan() {
        let coordinator = coordinator
        let needsScan = OnboardingFinish.shouldScan(
            lastScanCompleted: coordinator.lastScanCompletedAt != nil,
            historyOn: coordinator.provenanceCollection
        )
        complete()
        guard needsScan else { return }
        Task { @MainActor in
            // A grant made during onboarding may already have started a scan.
            // Wait for it so this scan includes the latest settings.
            while coordinator.isScanning {
                try? await Task.sleep(for: .milliseconds(250))
            }
            await coordinator.refresh()
        }
    }

    private func complete() {
        coordinator.completeOnboarding()
        dismiss()
    }
}

#Preview {
    OnboardingView()
        .environment(AppCoordinator())
}
