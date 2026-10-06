import AppKit
import InstalloryCore
import SwiftUI

/// Writes prompt text to the general pasteboard. Installory never sends a
/// prompt anywhere; the user pastes it into their own assistant.
@MainActor
enum PromptClipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Menu item title for copying a prompt aimed at `agent`.
    static func menuTitle(for agent: PromptAgent) -> String {
        if let name = agent.displayName {
            return "Copy Prompt for \(name)"
        }
        return "Copy Prompt for Any AI Assistant"
    }
}

/// "Ask your agent": a menu that copies a ready-made prompt for Claude Code,
/// Codex, or any assistant, then briefly confirms with "Copied".
///
/// The prompt is built lazily when an item is chosen, so placing the button in
/// a list or detail view costs nothing until it is used.
struct AskAgentButton: View {
    var title: String = "Ask Your AI Assistant"
    var systemImage: String = "bubble.left.and.text.bubble.right"
    var help: String = "Copy a ready-made prompt to paste into your AI coding assistant. Installory never sends it anywhere."
    let makePrompt: @MainActor (PromptAgent) -> AgentPrompt

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Menu {
            ForEach(PromptAgent.allCases, id: \.self) { agent in
                Button(PromptClipboard.menuTitle(for: agent)) {
                    copy(for: agent)
                }
            }
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : systemImage)
                .contentTransition(.opacity)
        }
        .fixedSize()
        .help(help)
        .accessibilityLabel(copied ? "Prompt copied" : title)
        .accessibilityHint("Copies a prompt you can paste into an AI coding assistant")
    }

    private func copy(for agent: PromptAgent) {
        PromptClipboard.copy(makePrompt(agent).body)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        AccessibilityNotification.Announcement("Prompt copied").post()
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }
}
