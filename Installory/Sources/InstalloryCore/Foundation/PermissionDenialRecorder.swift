import Foundation

/// Lists a scanner's folders while remembering whether any of them refused
/// read permission.
///
/// A missing folder means "nothing installed here", but a folder the sandbox
/// won't let Installory read means "unknown". If a scan finds nothing and a
/// folder refused access, the scanner must not report a successful empty
/// result: the reconciler would replace that manager's packages with nothing
/// and their Install History evidence would be deleted with them. Instead it
/// throws a permission error, which `ScanCoordinator` reports as "access
/// needed" (skipped), keeping the last-known rows.
///
/// When some folders are readable the scanner returns what it found, so a
/// partial grant (for example Homebrew but not the home folder) keeps working.
///
/// A recorder is created per scanner instance and reset at the start of each
/// scan; it's a reference type so struct copies of a scanner share it.
final class PermissionDenialRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var denied = false

    var sawDenial: Bool {
        lock.lock(); defer { lock.unlock() }
        return denied
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        denied = false
    }

    func recordDenial() {
        lock.lock(); defer { lock.unlock() }
        denied = true
    }

    /// The folder's direct contents, or an empty list when it is missing or
    /// unreadable. A permission refusal is remembered.
    func contents(of url: URL, using provider: any DirectoryAccessProvider) -> [URL] {
        do {
            return try provider.contentsOfDirectory(at: url)
        } catch {
            if ScanCoordinator.isPermissionDenied(error) {
                recordDenial()
            }
            return []
        }
    }

    /// Throws a permission error when the scan found nothing and at least one
    /// folder refused access.
    func throwIfNothingFoundBecauseDenied(foundNothing: Bool) throws {
        if foundNothing, sawDenial {
            throw CocoaError(.fileReadNoPermission)
        }
    }
}
