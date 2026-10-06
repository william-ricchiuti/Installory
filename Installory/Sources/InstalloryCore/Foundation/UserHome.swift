import Darwin
import Foundation

/// The signed-in user's real home directory.
///
/// Inside the App Sandbox, `FileManager.homeDirectoryForCurrentUser` and
/// `NSHomeDirectory()` return the app container
/// (`~/Library/Containers/<bundle-id>/Data`), not the user's home. Scanners
/// derive `~/.claude`, `~/.cargo`, `~/.nvm`, and similar roots from the home
/// directory, so they must start from the real one. Reads still succeed only
/// under a user-granted security-scoped bookmark.
public enum UserHome {
    public static let directory: URL = resolve()

    static func resolve() -> URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
