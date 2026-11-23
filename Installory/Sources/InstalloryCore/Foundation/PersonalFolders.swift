import Foundation

/// Folders inside the home folder that hold personal data rather than code.
///
/// Onboarding promises Installory doesn't open Documents, Photos, Mail and
/// similar folders. When the granted folder *is* the home folder, the scanners
/// that look for projects and project virtual environments skip these
/// children entirely: no listing, no metadata, no sizing. A folder the user
/// grants on purpose (for example `~/Documents`) is still scanned, because
/// then it's the granted root, not a child of home.
enum PersonalFolders {
    /// Direct children of the home folder that are never inspected.
    static let names: Set<String> = [
        "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music",
        "Library", "Public", "Applications", ".Trash",
    ]

    /// Library bundles that may sit anywhere directly under home.
    static let bundleSuffixes = [".photoslibrary", ".photolibrary", ".musiclibrary", ".tvlibrary"]

    /// True when `child` is a personal folder directly inside the home folder.
    static func isPersonal(_ child: URL, home: URL) -> Bool {
        let standardized = child.standardizedFileURL
        guard standardized.deletingLastPathComponent().standardizedFileURL.path == home.standardizedFileURL.path else {
            return false
        }
        let name = standardized.lastPathComponent
        if names.contains(name) { return true }
        let lowered = name.lowercased()
        return bundleSuffixes.contains { lowered.hasSuffix($0) }
    }

    /// Roots whose contents are never projects: Homebrew's own folders, which
    /// are a Git checkout and would otherwise show up as one.
    static func isToolPrefix(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return ["/opt/homebrew", "/usr/local", "/usr/local/Homebrew", "/home/linuxbrew/.linuxbrew"].contains(path)
    }
}
