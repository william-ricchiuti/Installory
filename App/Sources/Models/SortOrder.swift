import InstalloryCore
import Foundation

enum PackageSortOrder: String, CaseIterable, Sendable {
    case recentlyInstalled
    case nameAscending
    case managerThenName
    /// Largest `sizeBytes` first; packages with unknown size sink to the end.
    case largestFirst
    /// Oldest `installedAt` first (earliest date first); unknown dates sink to the end.
    case oldestFirst
    /// Highest combined cleanup score (age + size) first. Packages in the
    /// `.unknown` bucket (no size AND no date) are appended at the end.
    /// This is not "most deletable" — it is "oldest and/or largest". Installory
    /// has no usage telemetry and cannot determine whether a package is unused.
    case cleanupCandidates

    var displayName: String {
        switch self {
        case .recentlyInstalled:  "Recently Installed"
        case .nameAscending:      "Name (A\u{2013}Z)"
        case .managerThenName:    "Manager, then Name"
        case .largestFirst:       "Largest First"
        case .oldestFirst:        "Oldest First"
        case .cleanupCandidates:  "Cleanup Candidates"
        }
    }
}

extension [Package] {
    func sorted(by order: PackageSortOrder) -> [Package] {        switch order {
        case .recentlyInstalled:
            sorted {
                let lhsDate = $0.installedAt ?? .distantPast
                let rhsDate = $1.installedAt ?? .distantPast
                return lhsDate != rhsDate ? lhsDate > rhsDate : $0.id < $1.id
            }
        case .nameAscending:
            sorted {
                let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
                return comparison == .orderedSame
                    ? $0.id < $1.id
                    : comparison == .orderedAscending
            }
        case .managerThenName:
            sorted {
                if $0.manager.rawValue != $1.manager.rawValue {
                    return $0.manager.rawValue < $1.manager.rawValue
                }
                let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
                return comparison == .orderedSame
                    ? $0.id < $1.id
                    : comparison == .orderedAscending
            }
        case .largestFirst:
            sorted {
                let lhsSize = $0.sizeBytes ?? -1
                let rhsSize = $1.sizeBytes ?? -1
                return lhsSize != rhsSize ? lhsSize > rhsSize : $0.id < $1.id
            }
        case .oldestFirst:
            sorted {
                let lhsDate = $0.installedAt ?? .distantFuture
                let rhsDate = $1.installedAt ?? .distantFuture
                return lhsDate != rhsDate ? lhsDate < rhsDate : $0.id < $1.id
            }
        case .cleanupCandidates:
            cleanupScores(for: self, now: Date())
                .sorted { lhs, rhs in
                    let lhsUnknown = lhs.bucket == .unknown
                    let rhsUnknown = rhs.bucket == .unknown
                    if lhsUnknown != rhsUnknown {
                        return !lhsUnknown
                    }
                    if lhs.score != rhs.score {
                        return lhs.score > rhs.score
                    }
                    return lhs.package.id < rhs.package.id
                }
                .map(\.package)
        }
    }

    /// Sorts `by` `order`, but lifts any package whose ID is in `pinnedIDs` to
    /// the front of the result, preserving the chosen order within the pinned
    /// and unpinned groups. Pinned packages float to the top of the inventory
    /// list no matter which sort the user picks.
    func sorted(by order: PackageSortOrder, pinnedFirst pinnedIDs: Set<String>) -> [Package] {
        guard !pinnedIDs.isEmpty else { return sorted(by: order) }
        let pinned = filter { pinnedIDs.contains($0.id) }.sorted(by: order)
        let unpinned = filter { !pinnedIDs.contains($0.id) }.sorted(by: order)
        return pinned + unpinned
    }
}

// MARK: - Generation-keyed inventory derivation

/// One-pass primitives reused by sidebar counts and identity lookups.
struct InventoryIndex {
    let packagesByID: [String: Package]
    let packageNamesByID: [String: String]
    let managerCounts: [PackageManager: Int]
    let packageManagers: Set<PackageManager>
    let readOnlyCount: Int
}

/// The duplicate view's inventory- and PATH-derived presentation groups.
struct DuplicateAnalysisState {
    let active: [(group: DuplicateGroup, standings: [String: PathStanding])]
    let potential: [(group: DuplicateGroup, standings: [String: PathStanding])]
    let benign: [(group: DuplicateGroup, standings: [String: PathStanding])]
    let multiLocation: [MultiLocationGroup]
}

/// Deterministic instrumentation for regressions around cache reuse/invalidation.
struct InventoryDerivedComputationCounts: Equatable {
    fileprivate(set) var inventoryIndex = 0
    fileprivate(set) var duplicateGroups = 0
    fileprivate(set) var multiLocationGroups = 0
    fileprivate(set) var orphanedPackages = 0
    fileprivate(set) var diskUsageSummary = 0
    fileprivate(set) var aiInstalledPackages = 0
    fileprivate(set) var duplicatePathAnalysis = 0
    fileprivate(set) var agentStackAnalysis = 0
    fileprivate(set) var reverseDependencyIndex = 0
    fileprivate(set) var removalSafety = 0
    fileprivate(set) var freeUpSpaceBundle = 0
}

/// A single generation seam for whole-inventory derived state.
///
/// `AppCoordinator` owns one instance and invalidates it from `packages` and
/// provenance property observers. Individual results remain lazy so opening a
/// simple package list does not eagerly compute every analysis.
@MainActor
final class InventoryDerivedCache {
    private var inventoryGeneration = 0
    private var provenanceGeneration = 0

    private var cachedIndex: (generation: Int, value: InventoryIndex)?
    private var cachedDuplicateGroups: (generation: Int, value: [DuplicateGroup])?
    private var cachedMultiLocationGroups: (generation: Int, value: [MultiLocationGroup])?
    private var cachedOrphans: (generation: Int, value: [Package])?
    private var cachedDiskUsageSummary: (generation: Int, value: DiskUsageSummary)?
    private var cachedAI: (
        inventoryGeneration: Int,
        provenanceGeneration: Int,
        value: [Package]
    )?
    private var cachedDuplicateAnalysis: (
        generation: Int,
        pathComponents: [String],
        value: DuplicateAnalysisState
    )?
    private var cachedAgentStackAnalysis: (generation: Int, value: AgentStackAnalysis)?
    private var cachedReverseDependencyIndex: (generation: Int, value: ReverseDependencyIndex)?
    private var cachedRemovalSafety: (generation: Int, value: [String: RemovalSafetyVerdict])?
    private var cachedFreeUpSpace: (
        generation: Int,
        limit: Int,
        excludedIDs: Set<String>,
        value: FreeUpSpaceBundle
    )?

    private(set) var computationCounts = InventoryDerivedComputationCounts()

    func invalidateInventory() {
        inventoryGeneration &+= 1
        cachedIndex = nil
        cachedDuplicateGroups = nil
        cachedMultiLocationGroups = nil
        cachedOrphans = nil
        cachedDiskUsageSummary = nil
        cachedAI = nil
        cachedDuplicateAnalysis = nil
        cachedAgentStackAnalysis = nil
        cachedReverseDependencyIndex = nil
        cachedRemovalSafety = nil
        cachedFreeUpSpace = nil
    }

    func invalidateProvenance() {
        provenanceGeneration &+= 1
        cachedAI = nil
    }

    func index(for packages: [Package]) -> InventoryIndex {
        if let cachedIndex, cachedIndex.generation == inventoryGeneration {
            return cachedIndex.value
        }

        computationCounts.inventoryIndex += 1
        var packagesByID: [String: Package] = [:]
        var packageNamesByID: [String: String] = [:]
        var managerCounts: [PackageManager: Int] = [:]
        var packageManagers: Set<PackageManager> = []
        var readOnlyCount = 0
        packagesByID.reserveCapacity(packages.count)
        packageNamesByID.reserveCapacity(packages.count)
        for package in packages {
            packagesByID[package.id] = package
            packageNamesByID[package.id] = package.name
            managerCounts[package.manager, default: 0] += 1
            packageManagers.insert(package.manager)
            if package.isReadOnly {
                readOnlyCount += 1
            }
        }

        let value = InventoryIndex(
            packagesByID: packagesByID,
            packageNamesByID: packageNamesByID,
            managerCounts: managerCounts,
            packageManagers: packageManagers,
            readOnlyCount: readOnlyCount
        )
        cachedIndex = (inventoryGeneration, value)
        return value
    }

    func duplicateGroups(for packages: [Package]) -> [DuplicateGroup] {
        if let cachedDuplicateGroups,
           cachedDuplicateGroups.generation == inventoryGeneration {
            return cachedDuplicateGroups.value
        }
        computationCounts.duplicateGroups += 1
        let value = packages.crossManagerDuplicates()
        cachedDuplicateGroups = (inventoryGeneration, value)
        return value
    }

    func multiLocationGroups(for packages: [Package]) -> [MultiLocationGroup] {
        if let cachedMultiLocationGroups,
           cachedMultiLocationGroups.generation == inventoryGeneration {
            return cachedMultiLocationGroups.value
        }
        computationCounts.multiLocationGroups += 1
        let value = packages.multiLocationInstalls()
        cachedMultiLocationGroups = (inventoryGeneration, value)
        return value
    }

    func orphanedPackages(for packages: [Package]) -> [Package] {
        if let cachedOrphans, cachedOrphans.generation == inventoryGeneration {
            return cachedOrphans.value
        }
        computationCounts.orphanedPackages += 1
        let value = packages.orphanedPackages()
        cachedOrphans = (inventoryGeneration, value)
        return value
    }

    func agentStackAnalysis(for packages: [Package]) -> AgentStackAnalysis {
        if let cachedAgentStackAnalysis,
           cachedAgentStackAnalysis.generation == inventoryGeneration {
            return cachedAgentStackAnalysis.value
        }
        computationCounts.agentStackAnalysis += 1
        let value = AgentStackAnalysis(skills: packages)
        cachedAgentStackAnalysis = (inventoryGeneration, value)
        return value
    }

    func reverseDependencyIndex(for packages: [Package]) -> ReverseDependencyIndex {
        if let cachedReverseDependencyIndex,
           cachedReverseDependencyIndex.generation == inventoryGeneration {
            return cachedReverseDependencyIndex.value
        }
        computationCounts.reverseDependencyIndex += 1
        let value = ReverseDependencyIndex(packages: packages)
        cachedReverseDependencyIndex = (inventoryGeneration, value)
        return value
    }

    func removalSafety(for packages: [Package]) -> [String: RemovalSafetyVerdict] {
        if let cachedRemovalSafety, cachedRemovalSafety.generation == inventoryGeneration {
            return cachedRemovalSafety.value
        }
        computationCounts.removalSafety += 1
        let reverseIndex = reverseDependencyIndex(for: packages)
        let orphanedIDs = Set(orphanedPackages(for: packages).map(\.id))
        var value: [String: RemovalSafetyVerdict] = [:]
        value.reserveCapacity(packages.count)
        for package in packages {
            value[package.id] = RemovalSafetyAnalysis.verdict(
                for: package,
                reverseDependencyIndex: reverseIndex,
                orphanedIDs: orphanedIDs
            )
        }
        cachedRemovalSafety = (inventoryGeneration, value)
        return value
    }

    /// Safe-to-remove bundle over the visible inventory. Hidden rows are passed
    /// as `excludingPackageIDs` and are part of the cache key, so hiding or
    /// unhiding a package recomputes the bundle without a new inventory generation.
    func freeUpSpaceBundle(
        for packages: [Package],
        excludingPackageIDs excludedIDs: Set<String> = [],
        limit: Int = 5
    ) -> FreeUpSpaceBundle {
        if let cachedFreeUpSpace,
           cachedFreeUpSpace.generation == inventoryGeneration,
           cachedFreeUpSpace.limit == limit,
           cachedFreeUpSpace.excludedIDs == excludedIDs {
            return cachedFreeUpSpace.value
        }
        computationCounts.freeUpSpaceBundle += 1
        let reverseIndex = reverseDependencyIndex(for: packages)
        let value = FreeUpSpace.bundle(
            packages: packages,
            now: Date(),
            reverseDependencyIndex: reverseIndex,
            orphanedIDs: Set(orphanedPackages(for: packages).map(\.id)),
            excludingPackageIDs: excludedIDs,
            limit: limit
        )
        cachedFreeUpSpace = (inventoryGeneration, limit, excludedIDs, value)
        return value
    }

    func diskUsageSummary(for packages: [Package]) -> DiskUsageSummary {
        if let cachedDiskUsageSummary,
           cachedDiskUsageSummary.generation == inventoryGeneration {
            return cachedDiskUsageSummary.value
        }
        computationCounts.diskUsageSummary += 1
        let value = InstalloryCore.diskUsageSummary(for: packages)
        cachedDiskUsageSummary = (inventoryGeneration, value)
        return value
    }

    func aiInstalledPackages(
        for packages: [Package],
        provenance: [String: ProvenanceEvidence]
    ) -> [Package] {
        if let cachedAI,
           cachedAI.inventoryGeneration == inventoryGeneration,
           cachedAI.provenanceGeneration == provenanceGeneration {
            return cachedAI.value
        }
        computationCounts.aiInstalledPackages += 1
        let value = packages.filter {
            wasInstalledByAIAssistant(provenance[$0.id])
        }
        cachedAI = (inventoryGeneration, provenanceGeneration, value)
        return value
    }

    func duplicateAnalysis(
        for packages: [Package],
        pathComponents: [String]
    ) -> DuplicateAnalysisState {
        if let cachedDuplicateAnalysis,
           cachedDuplicateAnalysis.generation == inventoryGeneration,
           cachedDuplicateAnalysis.pathComponents == pathComponents {
            return cachedDuplicateAnalysis.value
        }

        computationCounts.duplicatePathAnalysis += 1
        var active: [(DuplicateGroup, [String: PathStanding])] = []
        var potential: [(DuplicateGroup, [String: PathStanding])] = []
        var benign: [(DuplicateGroup, [String: PathStanding])] = []
        for group in duplicateGroups(for: packages) {
            let standings = resolvePathStandings(for: group, path: pathComponents)
            switch severity(for: group, standings: standings) {
            case .active: active.append((group, standings))
            case .potential: potential.append((group, standings))
            case .benign: benign.append((group, standings))
            }
        }

        let value = DuplicateAnalysisState(
            active: active,
            potential: potential,
            benign: benign,
            multiLocation: multiLocationGroups(for: packages)
        )
        cachedDuplicateAnalysis = (inventoryGeneration, pathComponents, value)
        return value
    }
}
