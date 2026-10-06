import AppKit
import Foundation
import InstalloryCore

@Observable
@MainActor
final class FolderAccessManager {
    /// Paths whose stored bookmarks failed to resolve on launch.
    /// The user will be prompted to re-grant on the next scan attempt.
    private(set) var staleBookmarkPaths: Set<String> = []

    private var storedBookmarks: [String: Data] = [:]
    private let defaultsKey = "app.installory.bookmarks"

    // MARK: - Launch

    func loadPersistedBookmarks() {
        let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]

        var valid: [String: Data] = [:]
        var stale: Set<String> = []
        for (path, data) in raw {
            var isStale = false
            let resolvedURL = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if let resolvedURL,
               Self.bookmarkResolutionIsUsable(
                   storedPath: path,
                   resolvedURL: resolvedURL,
                   isStale: isStale
               ) {
                valid[path] = data
            } else {
                stale.insert(path)
            }
        }

        storedBookmarks = valid
        staleBookmarkPaths = stale
        // Keep stale bookmark data persisted. The path remains available to the
        // re-grant UI across launches and is replaced only after a successful grant.
    }

    // MARK: - Task-spec API

    /// Opens an NSOpenPanel pre-navigated to `suggestedURL`, creates a
    /// security-scoped bookmark, persists it to UserDefaults, and returns the
    /// granted URL. Returns nil if the user cancels or bookmark creation fails.
    func requestAccess(to suggestedURL: URL?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Grant Installory read access to this folder"
        panel.prompt = "Grant Access"
        // Only pre-navigate the panel to the suggested folder when it actually
        // exists as a readable directory. Pointing the panel at a missing or
        // root-owned system path can lead the user to grant a protected
        // directory, which makes macOS present an authentication sheet. When the
        // suggestion isn't usable, start in the user's home folder instead.
        panel.directoryURL = Self.safePanelDirectory(for: suggestedURL)
        // Many package roots are dot-folders (~/.claude, ~/.cargo). Show hidden
        // items when the panel starts at one of them or at the home folder so
        // they can actually be selected.
        panel.showsHiddenFiles = Self.shouldShowHiddenFiles(for: suggestedURL)

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // AppKit implicitly starts security-scoped access for URLs returned by
        // NSOpenPanel. Balance that grant after creating the persistent bookmark.
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return nil }

        let path = Self.standardizedPath(url.path)
        storedBookmarks[path] = data

        var raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
        // A successful re-grant may point at a moved folder with a new path. Remove
        // the stale entry that initiated this panel only after bookmark creation succeeds.
        if let suggestedURL,
           let stalePath = staleBookmarkPaths.sorted().first(where: {
               Self.pathsReferToSameLocation($0, suggestedURL.path)
           }) {
            raw.removeValue(forKey: stalePath)
            staleBookmarkPaths.remove(stalePath)
        }
        staleBookmarkPaths.remove(path)
        raw[path] = data
        UserDefaults.standard.set(raw, forKey: defaultsKey)

        return url
    }

    /// Resolves `bookmarkData` and starts security-scoped access.
    /// Returns the resolved URL on success, nil if resolution or access fails.
    /// The caller must eventually call `stopAccessing(_:)` on the returned URL.
    func startAccessing(_ bookmarkData: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), !isStale else { return nil }

        guard url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    /// Performs one operation against a path covered by an existing bookmark.
    /// The narrowest covering grant is resolved and started only for the
    /// duration of `operation`; no new grant is requested or persisted.
    func withAccessToGrantedPath<Result>(
        _ targetURL: URL,
        operation: (URL) -> Result
    ) -> Result? {
        Self.withAccessToGrantedPath(
            targetURL,
            bookmarks: grantedBookmarks(),
            startAccessing: { [self] bookmark in startAccessing(bookmark) },
            stopAccessing: { [self] url in stopAccessing(url) },
            operation: operation
        )
    }

    /// Scoped existence check for package install paths outside the container.
    func grantedItemExists(at targetURL: URL) -> Bool {
        withAccessToGrantedPath(targetURL) { scopedTarget in
            FileManager.default.fileExists(atPath: scopedTarget.path)
        } ?? false
    }

    /// Reveals an existing package install path while its covering bookmark is
    /// active. Returns false when the path is ungranted, unavailable, or gone.
    @discardableResult
    func revealGrantedItemInFinder(at targetURL: URL) -> Bool {
        withAccessToGrantedPath(targetURL) { scopedTarget in
            guard FileManager.default.fileExists(atPath: scopedTarget.path) else {
                return false
            }
            NSWorkspace.shared.activateFileViewerSelecting([scopedTarget])
            return true
        } ?? false
    }

    func grantedBookmarks() -> [(path: String, bookmark: Data)] {
        storedBookmarks.map { (path: $0.key, bookmark: $0.value) }
    }

    /// Removes exactly one stored grant and its persisted bookmark.
    /// Ancestor and descendant grants are left untouched.
    @discardableResult
    func remove(path: String) -> Bool {
        let removedStored = storedBookmarks.removeValue(forKey: path) != nil
        let removedStale = staleBookmarkPaths.remove(path) != nil

        var raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
        let removedPersisted = raw.removeValue(forKey: path) != nil
        if removedPersisted {
            UserDefaults.standard.set(raw, forKey: defaultsKey)
        }
        return removedStored || removedStale || removedPersisted
    }

    // MARK: - Helpers

    /// Returns a safe starting directory for the open panel: the suggested URL
    /// only when it exists as a directory, otherwise the user's home folder.
    /// Never returns a path that doesn't exist, so the panel can't land the user
    /// inside a missing or system-protected location.
    static func safePanelDirectory(for suggestedURL: URL?) -> URL {
        let fm = FileManager.default
        if let suggestedURL {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: suggestedURL.path, isDirectory: &isDir), isDir.boolValue {
                return suggestedURL
            }
        }
        return UserHome.directory
    }

    /// True when the grant panel should reveal hidden items: the suggestion is
    /// (or lives inside) a dot-folder, is the home folder itself, or is missing
    /// so the panel falls back to home (where the dot-folders live).
    static func shouldShowHiddenFiles(for suggestedURL: URL?) -> Bool {
        let home = standardizedPath(UserHome.directory.path)
        guard let suggestedURL else { return true }
        let path = standardizedPath(suggestedURL.path)
        if path == home { return true }
        if URL(fileURLWithPath: path).pathComponents.contains(where: { $0.hasPrefix(".") && $0 != "." && $0 != ".." }) {
            return true
        }
        return standardizedPath(safePanelDirectory(for: suggestedURL).path) == home
    }

    var hasAnyGrant: Bool { !storedBookmarks.isEmpty }

    /// All currently-granted directory paths.
    var grantedPaths: [String] { Array(storedBookmarks.keys) }

    /// Returns the narrowest stored grant that contains `targetPath`.
    ///
    /// Coverage is one-way and path-component aware: `/Users/me` covers
    /// `/Users/me/project`, but the child does not cover its parent and
    /// `/Users/me2` is unrelated. Ties are resolved lexicographically so the
    /// result does not depend on Dictionary iteration order.
    func grantedPath(covering targetPath: String) -> String? {
        GrantedPathResolver.deepestCoveringPath(
            for: targetPath,
            among: Array(storedBookmarks.keys)
        )
    }

    /// Compatibility spelling for existing view call sites. Matching is ancestor-only;
    /// despite the historical name, this no longer performs symmetric string-prefix checks.
    func grantedPath(forPrefix targetPath: String) -> String? {
        grantedPath(covering: targetPath)
    }

    /// Injectable seam used by the live bookmark wrapper above and regression
    /// tests. Every successful start is paired with exactly one stop, including
    /// the case where a resolved bookmark no longer covers the requested path.
    static func withAccessToGrantedPath<Result>(
        _ targetURL: URL,
        bookmarks: [(path: String, bookmark: Data)],
        startAccessing: (Data) -> URL?,
        stopAccessing: (URL) -> Void,
        operation: (URL) -> Result
    ) -> Result? {
        let targetURL = targetURL.standardizedFileURL
        guard
            let grantedPath = GrantedPathResolver.deepestCoveringPath(
                for: targetURL.path,
                among: bookmarks.map(\.path)
            ),
            let bookmark = bookmarks.first(where: { $0.path == grantedPath })?.bookmark,
            let accessedRoot = startAccessing(bookmark)
        else {
            return nil
        }
        defer { stopAccessing(accessedRoot) }

        // A bookmark can resolve somewhere other than its persisted path after
        // a move. Requiring exact root identity is important: merely checking
        // that the resolved root contains the target would accept an unexpectedly
        // broader scope such as `/` for a bookmark stored as `/Users/me`.
        guard GrantedPathResolver.referToSameLocation(
            accessedRoot.path,
            grantedPath
        ) else {
            return nil
        }

        return operation(targetURL)
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private static func pathsReferToSameLocation(_ lhs: String, _ rhs: String) -> Bool {
        GrantedPathResolver.referToSameLocation(lhs, rhs)
    }

    /// A bookmark is usable only while it resolves to the directory whose path
    /// was persisted alongside it. Treat moved—even unexpectedly broader—roots
    /// as stale so the UI keeps offering a re-grant instead of retaining an
    /// unusable entry in the active bookmark cache.
    static func bookmarkResolutionIsUsable(
        storedPath: String,
        resolvedURL: URL,
        isStale: Bool
    ) -> Bool {
        !isStale && pathsReferToSameLocation(storedPath, resolvedURL.path)
    }
}
