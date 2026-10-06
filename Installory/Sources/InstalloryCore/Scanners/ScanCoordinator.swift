import Foundation

/// Events emitted by `ScanCoordinator.scan()`.
public enum ScanEvent: Sendable {
    case scannerStarted(PackageManager)
    case scannerFinished(PackageManager, ScannerStatus, [Package])
    case allFinished(perManager: [PackageManager: ScannerStatus], allPackages: [Package])
}

/// Runs all registered `PackageScanner`s concurrently and streams `ScanEvent`s
/// as each scanner starts, finishes, and when all are done.
///
/// This actor has no UI isolation. `AppCoordinator` consumes its event stream on
/// the main actor and projects scan state into SwiftUI.
public actor ScanCoordinator {
    private let scanners: [any PackageScanner]
    private let timeouts: [PackageManager: TimeInterval]

    // npm is given the highest budget because deep nvm trees with many node
    // versions each carrying a large global node_modules can take noticeably
    // longer than the other scanners' filesystem walks.
    private static let defaultTimeouts: [PackageManager: TimeInterval] = [
        .brew: 5, .brewCask: 5, .pip: 8, .npm: 30,
        .pipx: 5, .uv: 8, .cargo: 5, .gem: 5, .mas: 5,
    ]

    public init(
        scanners: [any PackageScanner],
        timeouts: [PackageManager: TimeInterval] = [:]
    ) {
        self.scanners = scanners
        self.timeouts = Self.defaultTimeouts.merging(timeouts) { _, override in override }
    }

    /// Runs every scanner concurrently and yields events as they happen.
    /// The stream completes after `.allFinished` is yielded.
    public func scan() -> AsyncStream<ScanEvent> {
        let scanners = self.scanners
        let timeouts = self.timeouts
        return AsyncStream { (continuation: AsyncStream<ScanEvent>.Continuation) in
            let producer = Task.detached {
                var allPackages: [Package] = []
                var perManager: [PackageManager: ScannerStatus] = [:]

                await withTaskGroup(
                    of: (PackageManager, ScannerStatus, [Package])?.self
                ) { group in
                    for scanner in scanners {
                        let mgr = scanner.manager
                        let timeoutSecs = timeouts[mgr] ?? 30

                        group.addTask {
                            guard !Task.isCancelled else { return nil }
                            // .scannerStarted must be yielded before awaiting scan().
                            continuation.yield(.scannerStarted(mgr))
                            let start = Date()
                            let status: ScannerStatus
                            let packages: [Package]
                            do {
                                let pkgs = try await withTimeout(timeoutSecs) {
                                    guard await scanner.isAvailable() else {
                                        throw ScannerUnavailable(reason: scanner.unavailableReason)
                                    }
                                    return try await scanner.scan()
                                }
                                let ms = Int(Date().timeIntervalSince(start) * 1000)
                                status = .succeeded(count: pkgs.count, durationMs: ms)
                                packages = pkgs
                            } catch let unavailable as ScannerUnavailable {
                                status = .skipped(reason: unavailable.reason)
                                packages = []
                            } catch is TimeoutError {
                                let ms = Int(Date().timeIntervalSince(start) * 1000)
                                status = .timedOut(durationMs: ms)
                                packages = []
                            } catch is CancellationError {
                                return nil
                            } catch where ScanCoordinator.isPermissionDenied(error) {
                                // The sandbox can see that a folder exists but not read it
                                // until the user grants access. That is "not granted yet",
                                // not a broken scan.
                                status = .skipped(reason: ScanCoordinator.accessNeededReason)
                                packages = []
                            } catch {
                                let ms = Int(Date().timeIntervalSince(start) * 1000)
                                status = .failed(reason: error.localizedDescription, durationMs: ms)
                                packages = []
                            }
                            guard !Task.isCancelled else { return nil }
                            continuation.yield(.scannerFinished(mgr, status, packages))
                            return (mgr, status, packages)
                        }
                    }

                    for await result in group {
                        guard let (mgr, status, pkgs) = result else { continue }
                        perManager[mgr] = status
                        allPackages += pkgs
                    }
                }

                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                continuation.yield(.allFinished(perManager: perManager, allPackages: allPackages))
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }
}

extension ScanCoordinator {
    static let accessNeededReason = "Installory needs read access to this tool's folder"

    /// True when `error`, or any error it wraps, is a file-permission refusal.
    nonisolated static func isPermissionDenied(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error {
            return isPermissionDenied(underlying)
        }
        return false
    }
}

private struct ScannerUnavailable: Error, Sendable {
    let reason: String
}
