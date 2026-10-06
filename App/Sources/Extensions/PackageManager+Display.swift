import InstalloryCore
import SwiftUI

extension PackageManager {
    var displayName: String {
        switch self {
        case .brew: "Homebrew"
        case .brewCask: "Homebrew Cask"
        case .pip: "pip"
        case .pipx: "pipx"
        case .uv: "uv tools"
        case .npm: "npm"
        case .cargo: "Cargo"
        case .gem: "RubyGems"
        case .mas: "Mac App Store"
        case .agentSkill: "Agent Skills"
        case .agentCli: "Agent CLIs"
        case .editorExtension: "Editor Extensions"
        }
    }

    var badgeLabel: String {
        switch self {
        case .brew: "brew"
        case .brewCask: "app"
        case .pip: "pip"
        case .pipx: "pipx"
        case .uv: "uv"
        case .npm: "npm"
        case .cargo: "cargo"
        case .gem: "gem"
        case .mas: "App Store"
        case .agentSkill: "skill"
        case .agentCli: "AI tool"
        case .editorExtension: "ext"
        }
    }

    // Accessible, distinct badge colors. brew/brewCask share amber (both are Homebrew).
    var badgeColor: Color {
        switch self {
        case .brew, .brewCask: Color(red: 0.85, green: 0.55, blue: 0.05)
        case .pip, .pipx, .uv: Color(red: 0.20, green: 0.45, blue: 0.90)
        case .npm: Color(red: 0.85, green: 0.15, blue: 0.15)
        case .cargo: Color(red: 0.60, green: 0.30, blue: 0.10)
        case .gem: Color(red: 0.75, green: 0.10, blue: 0.50)
        case .mas: Color(red: 0.45, green: 0.20, blue: 0.85)
        case .agentSkill: Color(red: 0.20, green: 0.70, blue: 0.60)
        case .agentCli: Color(red: 0.30, green: 0.60, blue: 0.90)
        case .editorExtension: Color(red: 0.85, green: 0.55, blue: 0.85)
        }
    }

    var sidebarSymbol: String {
        switch self {
        case .brew, .brewCask: "shippingbox"
        case .pip, .pipx, .uv: "terminal"
        case .npm: "globe"
        case .cargo: "shippingbox.fill"
        case .gem: "sparkles"
        case .mas: "app.badge"
        case .agentSkill: "wand.and.stars"
        case .agentCli: "cpu"
        case .editorExtension: "puzzlepiece.extension"
        }
    }
}

extension ScannerStatus {
    /// Plain sentence for a skipped scanner in Scan Coverage. Raw skip reasons
    /// ("pipx venv directory not granted or not found") are scanner jargon; a
    /// skip always means the same thing to a person: not here, or not shared.
    static let friendlySkipDescription = "Not found on this Mac, or Installory doesn\u{2019}t have access to its folder yet"
}
