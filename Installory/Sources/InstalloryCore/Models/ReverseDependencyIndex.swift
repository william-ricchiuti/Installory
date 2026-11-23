import Foundation

/// Reverse-edge index over the installed package graph.
///
/// For every installed package P, each name listed in `P.dependencies` records
/// P as a dependent of that dependency. Lookups use the same matching rules as
/// `orphanedPackages` (`DependencyKey` semantics: same manager, same qualifier,
/// name normalized via `PackageIdentity.normalizedName`), so "what depends on
/// this package" stays consistent with orphan analysis.
///
/// **Limitations (by design):**
/// - Only same-manager, same-qualifier, in-inventory direct dependencies are
///   tracked. Cross-manager dependencies are invisible.
/// - Managers that do not populate `Package.dependencies` never appear as
///   dependents.
public struct ReverseDependencyIndex: Sendable {

    private struct Key: Hashable {
        let manager: PackageManager
        let qualifier: String?
        let name: String

        init(manager: PackageManager, qualifier: String?, name: String) {
            self.manager = manager
            self.qualifier = qualifier
            self.name = PackageIdentity.normalizedName(name, manager: manager)
        }
    }

    private let dependentsByKey: [Key: [String]]
    private let packagesByID: [String: Package]
    private let hostedByFormulaID: [String: [String]]

    public init(packages: [Package]) {
        var reverseDependents: [Key: [String]] = [:]
        var byID: [String: Package] = [:]

        for pkg in packages {
            byID[pkg.id] = pkg
            for dep in pkg.dependencies {
                let key = Key(manager: pkg.manager, qualifier: pkg.qualifier, name: dep)
                reverseDependents[key, default: []].append(pkg.id)
            }
        }

        self.dependentsByKey = reverseDependents
        self.packagesByID = byID
        self.hostedByFormulaID = RuntimeHosting.hostedPackageIDs(in: packages)
    }

    /// The installed packages that directly depend on `package`.
    ///
    /// The result is sorted by manager raw value, then name, for deterministic
    /// output. The input is never mutated.
    public func dependents(of package: Package) -> [Package] {
        let key = Key(
            manager: package.manager,
            qualifier: package.qualifier,
            name: package.name
        )
        return dependents(ofKey: key)
    }

    /// The installed packages that directly depend on the package with the given
    /// inventory id. Returns an empty array when the id is unknown.
    /// Packages from other managers that run on this Homebrew formula (for
    /// example npm globals inside `node@22`, gems inside `ruby`, tools inside
    /// `uv` or `pipx`). Empty for anything that isn't such a runtime.
    public func hostedPackages(of package: Package) -> [Package] {
        (hostedByFormulaID[package.id] ?? [])
            .compactMap { packagesByID[$0] }
            .sorted {
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.id < $1.id
            }
    }

    public func dependents(ofPackageID id: String) -> [Package] {
        guard let package = packagesByID[id] else { return [] }
        return dependents(of: package)
    }

    private func dependents(ofKey key: Key) -> [Package] {
        let ids = dependentsByKey[key] ?? []
        return ids
            .compactMap { packagesByID[$0] }
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
