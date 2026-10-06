import Foundation

/// Renders paths under the user's home folder as `~/...` so copied prompts
/// don't reveal the account name.
///
/// The home directory is injected; this type never asks the system for it.
public struct HomePathRedactor: Sendable, Equatable {
    public let homePath: String

    public init(homeDirectory: URL) {
        var path = homeDirectory.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        self.homePath = path
    }

    /// `~` for the home folder itself, `~/rest` for anything beneath it,
    /// otherwise the path unchanged.
    public func display(_ url: URL) -> String {
        display(path: url.path)
    }

    public func display(path: String) -> String {
        guard homePath.count > 1 else { return path }
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }

    /// Replaces every occurrence of the home path inside free text (for
    /// example a rendered Markdown report). Only whole-path matches are
    /// replaced: `/Users/a` is not touched inside `/Users/ab`.
    public func redact(text: String) -> String {
        guard homePath.count > 1, text.contains(homePath) else { return text }
        let escaped = NSRegularExpression.escapedPattern(for: homePath)
        guard let regex = try? NSRegularExpression(pattern: escaped + #"(?=$|[/\s'"`)\]|,;:])"#,
                                                   options: [.anchorsMatchLines]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "~")
    }
}
