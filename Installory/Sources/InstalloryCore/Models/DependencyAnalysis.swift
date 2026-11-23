import Foundation

/// Reverse-dependency analysis for the installed package graph.
///
/// **Limitations (by design):**
/// - Only same-manager, same-qualifier, in-inventory direct dependencies are analysed,
///   plus one cross-manager case: Homebrew runtimes that host other managers'
///   packages (see `RuntimeHosting`). Other cross-manager dependencies (e.g. a
///   Cargo binary calling a Homebrew `ffmpeg`) are invisible.
/// - Managers that do not populate `Package.dependencies` (e.g. `mas`, some
///   `cargo` and `gem` installs) will never produce dependents — this is
///   expected behaviour, not a defect.
/// - "Nothing in your inventory depends on it" ≠ "safe to delete". System-wide
///   usage by other processes, shell scripts, or cross-manager tools is not
///   tracked here.
extension [Package] {

    /// Returns explicitly-installed, non-read-only packages that have no
    /// in-inventory dependents within their own package-manager scope.
    ///
    /// A package qualifies as an orphan candidate when **all** of the following
    /// hold:
    /// - `isExplicit == true`
    /// - `isReadOnly == false`
    /// - it is not denylisted (defaults to `Denylist.default`)
    /// - no other package in the **same manager and qualifier** lists its name
    ///   in `dependencies`
    ///
    /// The result is sorted by manager raw value, then name, for deterministic
    /// output. The input array is never mutated.
    ///
    /// - Parameter denylist: The denylist to apply; defaults to
    ///   `Denylist.default`. Pass a custom `Denylist` in tests or when the
    ///   caller needs to suppress specific packages.
    /// - Returns: Orphan candidates, sorted manager-then-name.
    public func orphanedPackages(denylist: Denylist = .default) -> [Package] {
        // Build a reverse-dependent index keyed on manager, qualifier, and
        // normalized package name.
        // For every package P, each name in P.dependencies gets an entry
        // recording that P depends on it.
        var reverseDependents: [DependencyKey: Set<String>] = [:]
        for pkg in self {
            for dep in pkg.dependencies {
                for scope in PackageIdentity.dependencyScopes(of: pkg) {
                    let key = DependencyKey(
                        manager: scope.manager,
                        qualifier: scope.qualifier,
                        name: dep
                    )
                    reverseDependents[key, default: []].insert(pkg.id)
                }
            }
        }

        // Homebrew runtimes that other managers' packages run on (node@22 with
        // npm globals, uv with uv tools, …) are never orphans.
        let hostIDs = Set(RuntimeHosting.hostedPackageIDs(in: self).keys)

        return self
            .filter { pkg in
                guard pkg.manager.participatesInDependencyAnalysis else { return false }
                guard !hostIDs.contains(pkg.id) else { return false }
                guard pkg.isExplicit else { return false }
                guard !pkg.isReadOnly else { return false }
                guard !denylist.isDenylisted(pkg) else { return false }
                let key = DependencyKey(
                    manager: pkg.manager,
                    qualifier: pkg.qualifier,
                    name: pkg.name
                )
                // Orphan if reverse-dependent set is absent (no one depends on
                // it at all) or explicitly empty.
                return reverseDependents[key]?.isEmpty ?? true
            }
            .sorted {
                if $0.manager.rawValue != $1.manager.rawValue {
                    return $0.manager.rawValue < $1.manager.rawValue
                }
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.id < $1.id
            }
    }

}

private struct DependencyKey: Hashable {
    let manager: PackageManager
    let qualifier: String?
    let name: String

    init(manager: PackageManager, qualifier: String?, name: String) {
        self.manager = manager
        self.qualifier = qualifier
        self.name = PackageIdentity.normalizedName(name, manager: manager)
    }
}

/// Shared package-name identity rules used when comparing scanner output with
/// package-manager metadata or install commands.
enum PackageIdentity {
    /// Where a package's dependency names point. Usually its own manager and
    /// qualifier; a Homebrew cask's receipt lists both formula and cask
    /// dependencies by name, so its names are matched against both.
    static func dependencyScopes(of package: Package) -> [(manager: PackageManager, qualifier: String?)] {
        if package.manager == .brewCask {
            return [(.brewCask, package.qualifier), (.brew, nil)]
        }
        return [(package.manager, package.qualifier)]
    }

    static func normalizedName(_ name: String, manager: PackageManager) -> String {
        switch manager {
        case .pip, .pipx, .uv:
            return pep503Normalized(name)
        default:
            return name.lowercased()
        }
    }

    /// PEP 503: lowercase and collapse each run of `-`, `_`, or `.` to `-`.
    private static func pep503Normalized(_ name: String) -> String {
        var normalized = ""
        var isInSeparatorRun = false

        for character in name.lowercased() {
            if character == "-" || character == "_" || character == "." {
                if !isInSeparatorRun {
                    normalized.append("-")
                    isInSeparatorRun = true
                }
            } else {
                normalized.append(character)
                isInSeparatorRun = false
            }
        }

        return normalized
    }
}
