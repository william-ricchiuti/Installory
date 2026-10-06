import Foundation

/// A ranked set of packages that are safe to remove, plus their combined
/// measured payload.
///
/// "Safe" here has a precise, conservative meaning: the package's
/// `RemovalSafety` verdict is `.safe` and a generated removal script would
/// contain a runnable command for it.
/// It is **not** a usage signal — Installory has no usage telemetry, so a
/// high-ranked package is "old and/or large", not "unused".
public struct FreeUpSpaceBundle: Sendable, Equatable {
    /// Highest-score safe-to-remove candidates, sorted highest-first.
    public let candidates: [CleanupScore]
    /// Sum of measured `sizeBytes` across `candidates`. Unknown sizes are
    /// treated as zero (they contribute nothing), never inferred.
    public let totalReclaimableBytes: Int64

    public init(candidates: [CleanupScore]) {
        self.candidates = candidates
        self.totalReclaimableBytes = candidates.reduce(0) {
            $0 + ($1.package.sizeBytes ?? 0)
        }
    }

    public var isEmpty: Bool { candidates.isEmpty }
}

/// Pure functions that turn existing cleanup signals into a single
/// "free up space" bundle.
public enum FreeUpSpace {
    /// Returns the top `limit` safe-to-remove packages ranked by cleanup score.
    ///
    /// A package qualifies when all of the following hold:
    /// - its `RemovalSafetyAnalysis` verdict is `.safe` (read-only, App Store,
    ///   denylisted, depended-on, implicitly installed and agent/editor rows
    ///   that need manual care are all excluded by that verdict),
    /// - a generated removal script would contain a runnable command for it
    ///   (`Package.isRemovalScriptEligible(strategy: .uninstall)`), so the
    ///   bundle never hands the user a comment-only script,
    /// - its id is not in `excludingPackageIDs` (for example rows the user
    ///   has hidden), and
    /// - its measured size is greater than zero.
    ///
    /// The function is pure and deterministic: the clock is injected via
    /// `now`, and no filesystem or network I/O occurs.
    ///
    /// - Parameters:
    ///   - orphanedIDs: Orphan-candidate ids (`[Package].orphanedPackages`).
    ///     Pass a precomputed set to avoid recomputing it; `nil` computes it
    ///     from `packages` with `denylist`.
    ///   - excludingPackageIDs: Package ids never to include, such as hidden rows.
    public static func bundle(
        packages: [Package],
        now: Date,
        reverseDependencyIndex: ReverseDependencyIndex,
        denylist: Denylist = .default,
        orphanedIDs: Set<String>? = nil,
        excludingPackageIDs: Set<String> = [],
        limit: Int = 5
    ) -> FreeUpSpaceBundle {
        let orphans = orphanedIDs
            ?? Set(packages.orphanedPackages(denylist: denylist).map(\.id))
        let safe = cleanupScores(for: packages, now: now).filter { scored in
            let package = scored.package
            guard !excludingPackageIDs.contains(package.id),
                  package.isRemovalScriptEligible(strategy: .uninstall),
                  !denylist.isDenylisted(package),
                  (package.sizeBytes ?? 0) > 0,
                  reverseDependencyIndex.dependents(of: package).isEmpty else {
                return false
            }
            let verdict = RemovalSafetyAnalysis.verdict(
                for: package,
                reverseDependencyIndex: reverseDependencyIndex,
                orphanedIDs: orphans,
                denylist: denylist
            )
            return verdict.safety == .safe
        }
        return FreeUpSpaceBundle(candidates: Array(safe.prefix(max(0, limit))))
    }
}
