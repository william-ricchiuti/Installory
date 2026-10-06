import InstalloryCore
import Foundation

struct GrantedDirectory: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let bookmark: Data

    var displayPath: String {
        path.replacingOccurrences(
            of: UserHome.directory.path,
            with: "~"
        )
    }

    var managersUnlocked: String {
        let home = UserHome.directory.path
        if path.hasPrefix("/opt/homebrew") || path.hasPrefix("/usr/local") {
            return "Homebrew, pip, npm, RubyGems"
        } else if path.hasPrefix("\(home)/.pyenv") {
            return "pip"
        } else if path.hasPrefix("\(home)/.nvm") || path.hasPrefix("\(home)/.volta") {
            return "npm"
        } else if path.hasPrefix("\(home)/.local/share/pipx") {
            return "pipx"
        } else if path.hasPrefix("\(home)/.local/share/uv") {
            return "uv tools, pip"
        } else if path.hasPrefix("\(home)/.cargo") {
            return "Cargo"
        } else if path.hasPrefix("\(home)/.rbenv") || path.hasPrefix("\(home)/.gem") {
            return "RubyGems"
        } else if path == "/Applications" || path.hasPrefix("\(home)/Applications") {
            return "Mac App Store"
        }
        return "All managers"
    }
}
