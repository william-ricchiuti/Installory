import InstalloryCore
import Foundation

struct CanonicalDirectory: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let managers: [PackageManager]

    var displayPath: String {
        path.replacingOccurrences(
            of: UserHome.directory.path,
            with: "~"
        )
    }

    var subtitle: String {
        managers.map(\.displayName).joined(separator: ", ")
    }

    // All canonical directories for this Mac architecture.
    static func all(isAppleSilicon: Bool) -> [CanonicalDirectory] {
        let home = UserHome.directory.path
        var dirs: [CanonicalDirectory] = []
        if isAppleSilicon {
            dirs.append(.init(path: "/opt/homebrew", managers: [.brew, .brewCask, .pip, .npm, .gem]))
        }
        // Intel Homebrew and language-manager installs can coexist under
        // /usr/local on Apple Silicon through Rosetta, so always offer it.
        dirs.append(.init(path: "/usr/local", managers: [.brew, .brewCask, .pip, .npm, .gem]))
        dirs.append(.init(path: "\(home)/.pyenv", managers: [.pip]))
        dirs.append(.init(path: "\(home)/.nvm", managers: [.npm]))
        dirs.append(.init(path: "\(home)/.volta", managers: [.npm]))
        dirs.append(.init(path: "\(home)/.local/share/pipx", managers: [.pipx]))
        dirs.append(.init(path: "\(home)/.local/share/uv", managers: [.uv, .pip]))
        dirs.append(.init(path: "\(home)/.cargo", managers: [.cargo]))
        dirs.append(.init(path: "\(home)/.rbenv", managers: [.gem]))
        dirs.append(.init(path: "\(home)/.gem", managers: [.gem]))
        dirs.append(.init(path: "\(home)/.claude/skills", managers: [.agentSkill]))
        dirs.append(.init(path: "\(home)/.agents/skills", managers: [.agentSkill]))
        dirs.append(.init(path: "\(home)/.config/opencode/skills", managers: [.agentSkill]))
        dirs.append(.init(path: "\(home)/.opencode/skills", managers: [.agentSkill]))
        dirs.append(.init(path: "\(home)/.claude", managers: [.agentCli]))
        dirs.append(.init(path: "\(home)/.codex", managers: [.agentCli]))
        dirs.append(.init(path: "\(home)/.config/opencode", managers: [.agentCli]))
        dirs.append(.init(path: "\(home)/.cursor", managers: [.agentCli]))
        dirs.append(.init(path: "\(home)/.vscode/extensions", managers: [.editorExtension]))
        dirs.append(.init(path: "\(home)/.cursor/extensions", managers: [.editorExtension]))
        dirs.append(.init(path: "/Applications", managers: [.mas]))
        dirs.append(.init(path: "\(home)/Applications", managers: [.mas]))
        return dirs
    }
}
