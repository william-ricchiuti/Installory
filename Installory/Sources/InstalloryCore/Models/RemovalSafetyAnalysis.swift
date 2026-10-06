import Foundation

/// Distils Installory's dependency, denylist, and eligibility analyses into a
/// single `RemovalSafetyVerdict` for a package.
///
/// This is a pure value transformation: no filesystem access, no process
/// spawning, no database I/O. Every input is computed upstream and injected, so
/// the result is deterministic and trivially testable.
///
/// The verdict is deliberately conservative. "Safe" means only "nothing in
/// Installory's inventory depends on it and a removal command can be produced";
/// it never asserts the package is unused by processes, scripts, or tools
/// outside the inventory.
public enum RemovalSafetyAnalysis {

    /// - Parameters:
    ///   - package: The package to classify.
    ///   - reverseDependencyIndex: Index of dependents over the full inventory.
    ///   - orphanedIDs: Package IDs classified as orphan candidates
    ///     (`[Package].orphanedPackages`). Passed as a set for O(1) membership.
    ///   - denylist: Denylist to consult; defaults to `Denylist.default`.
    public static func verdict(
        for package: Package,
        reverseDependencyIndex: ReverseDependencyIndex,
        orphanedIDs: Set<String>,
        denylist: Denylist = .default
    ) -> RemovalSafetyVerdict {
        // 1. Read-only packages are managed by the system; never removable.
        if package.isReadOnly {
            return RemovalSafetyVerdict(
                safety: .leaveAlone,
                reasons: ["Installed as read-only — managed outside Installory"]
            )
        }

        // 2. Mac App Store apps have no CLI uninstall path.
        if package.manager == .mas {
            return RemovalSafetyVerdict(
                safety: .leaveAlone,
                reasons: ["Remove from the App Store or drag the app to the Trash"]
            )
        }

        // 3. Denylisted packages are commonly depended on by other software.
        if let reason = denylist.reason(for: package) {
            return RemovalSafetyVerdict(
                safety: .leaveAlone,
                reasons: ["Commonly required by other tools: \(reason)"]
            )
        }

        // 4. No scripted removal command exists.
        if package.manager == .agentCli {
            return RemovalSafetyVerdict(
                safety: .caution,
                reasons: ["Remove with the installer that originally placed it"]
            )
        }
        if !package.isRemovalScriptEligible {
            return RemovalSafetyVerdict(
                safety: .caution,
                reasons: ["Installory can't generate a removal command for this package"]
            )
        }

        // 5. Something in the inventory depends on it.
        let dependents = reverseDependencyIndex.dependents(of: package)
        if !dependents.isEmpty {
            let names = dependents.prefix(3).map(\.name).joined(separator: ", ")
            let extra = dependents.count > 3 ? " (+\(dependents.count - 3) more)" : ""
            return RemovalSafetyVerdict(
                safety: .caution,
                reasons: ["Depended on by \(names)\(extra)"]
            )
        }

        // 6. Installed implicitly as a dependency rather than deliberately.
        if !package.isExplicit {
            return RemovalSafetyVerdict(
                safety: .caution,
                reasons: ["Installed automatically as a dependency"]
            )
        }

        // 7. Explicit, nothing depends on it, not denylisted → orphan candidate.
        if orphanedIDs.contains(package.id) {
            return RemovalSafetyVerdict(
                safety: .safe,
                reasons: ["Nothing in your inventory depends on it"]
            )
        }

        // 8. Removable but outside orphan analysis (managers that don't publish
        //    dependencies, or agent/editor rows). Tailor the reason by manager.
        switch package.manager {
        case .agentSkill:
            if package.isBrokenAgentSkillLink {
                return RemovalSafetyVerdict(
                    safety: .safe,
                    reasons: ["Just a dangling link — removing it is harmless"]
                )
            }
            return RemovalSafetyVerdict(
                safety: .caution,
                reasons: ["Deletes the skill's files permanently — no package-manager backup"]
            )
        case .agentCli:
            return RemovalSafetyVerdict(
                safety: .caution,
                reasons: ["Remove with the installer that originally placed it"]
            )
        case .editorExtension:
            return RemovalSafetyVerdict(
                safety: .caution,
                reasons: ["Remove through the editor — Installory can't verify usage"]
            )
        default:
            return RemovalSafetyVerdict(
                safety: .caution,
                reasons: ["Installory can't verify whether anything depends on this"]
            )
        }
    }
}
