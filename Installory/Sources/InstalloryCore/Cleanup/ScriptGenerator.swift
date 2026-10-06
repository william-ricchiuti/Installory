import Foundation

/// Metadata about the snapshot captured before this cleanup script was generated.
///
/// Pass this to `ScriptGenerator.generate(packages:snapshot:)` so the script
/// header can reference the snapshot the user can restore from if something goes wrong.
public struct SnapshotContext: Sendable {
    public let id: UUID
    public let createdAt: Date

    public init(id: UUID, createdAt: Date) {
        self.id = id
        self.createdAt = createdAt
    }
}

/// The output of `ScriptGenerator.generate(packages:snapshot:)`.
public struct GeneratedScript: Sendable {
    /// Complete shell script text, ready to paste into Terminal.
    public let scriptText: String
    /// Packages omitted because `isReadOnly == true`. Never appear in the script.
    public let skippedReadOnly: [Package]
    /// Packages included in the script as commented-out lines with a warning banner.
    public let warnedDenylisted: [Package]
}

/// How a generated removal script should treat file-backed packages.
///
/// `.uninstall` (the default) emits each manager's real uninstall command. `.trash`
/// is the reversible alternative: for packages that are just files on disk (agent
/// skills and editor extensions), it moves them into a timestamped folder under
/// `~/.Trash` instead of deleting them. Package-manager packages (brew, pip, npm,
/// …) have no "trash" equivalent, so they still use their normal uninstall command.
public enum RemovalStrategy: Sendable, Equatable {
    case uninstall
    case trash

    public var rawValue: String {
        switch self {
        case .uninstall: return "uninstall"
        case .trash: return "trash"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "uninstall": self = .uninstall
        case "trash": self = .trash
        default: return nil
        }
    }
}

extension Package {
    /// True when a generated cleanup script would contain a runnable command for
    /// this row under at least one `RemovalStrategy`. The app uses the same
    /// predicate for Cleanup Mode selection controls.
    ///
    /// False for read-only rows, Mac App Store apps, uv rows without a safe
    /// target, and agent CLIs — their script output would be comment-only. A real
    /// agent-skill directory is eligible only because trash mode can move it; use
    /// ``isRemovalScriptEligible(strategy:)`` when the strategy is known.
    public var isRemovalScriptEligible: Bool {
        isRemovalScriptEligible(strategy: .uninstall) || isRemovalScriptEligible(strategy: .trash)
    }

    /// True when `ScriptGenerator.generate(packages:strategy:)` would emit a
    /// runnable (non-comment) command for this row with `strategy`. Rows for
    /// which this is false would produce a comment-only script, so the UI should
    /// not offer them for cleanup under that strategy.
    ///
    /// Denylist status is not considered here; denylisted rows are commented out
    /// by the generator and reported through `GeneratedScript.warnedDenylisted`.
    public func isRemovalScriptEligible(strategy: RemovalStrategy) -> Bool {
        guard !isReadOnly, manager != .mas else { return false }
        if strategy == .trash, ScriptGenerator.trashSource(for: self) != nil {
            return true
        }
        switch manager {
        case .uv:
            return UvToolEnvironmentIdentity.target(from: qualifier) != nil
        case .agentCli:
            return false
        case .agentSkill:
            return isBrokenAgentSkillLink
        case .editorExtension:
            return ScriptGenerator.editorCommand(for: qualifier) != nil
        case .brew, .brewCask, .pip, .npm, .pipx, .cargo, .gem, .mas:
            return true
        }
    }
}

/// Turns a selection of packages into a shell script the user can paste into Terminal.
///
/// This is a pure value: it reads `[Package]` and produces a `GeneratedScript` string.
/// It never touches the filesystem, spawns a process, or accesses the database.
public struct ScriptGenerator: Sendable {
    private let denylist: Denylist

    public init(denylist: Denylist = .default) {
        self.denylist = denylist
    }

    /// Generates a shell script that, when run in Terminal, uninstalls the given packages.
    ///
    /// Snapshot policy belongs to the caller. When snapshot metadata is supplied,
    /// the generated header references it for recovery.
    ///
    /// Behaviour:
    /// - Packages with `isReadOnly == true` are excluded and returned in `skippedReadOnly`.
    /// - Denylisted packages are rendered as commented-out lines at the bottom of the script
    ///   and returned in `warnedDenylisted`.
    /// - Within each manager, packages are topologically sorted so dependents are removed
    ///   before their dependencies. Dependency cycles are flagged with a `# WARNING` comment.
    /// Returns the shell command a user would paste into Terminal to remove this single
    /// package, or `nil` when no shell uninstall command exists for it.
    ///
    /// Returns `nil` for:
    /// - packages where `isReadOnly == true` (system packages cannot be removed)
    /// - `.mas` packages (Mac App Store apps have no CLI uninstall)
    ///
    /// This is a pure per-package display API. It performs no denylist filtering,
    /// dependency sorting, or script-header generation. `renderCommand` remains
    /// private and script-oriented; this method owns the nil cases cleanly.
    ///
    /// Agent rows whose removal is review-only (agent CLIs, real skill
    /// directories, unknown editor roots) return their explanatory `#` comment
    /// so the UI can still show why nothing runs; use
    /// `Package.isRemovalScriptEligible(strategy:)` to decide whether to offer
    /// cleanup at all.
    public func removalCommand(for package: Package) -> String? {
        guard !package.isReadOnly, package.manager != .mas else { return nil }
        if package.manager == .uv, UvToolEnvironmentIdentity.target(from: package.qualifier) == nil {
            return nil
        }
        return renderCommand(for: package)
    }

    public func generate(
        packages: [Package],
        snapshot: SnapshotContext? = nil,
        strategy: RemovalStrategy = .uninstall
    ) -> GeneratedScript {
        var skippedReadOnly: [Package] = []
        var warnedDenylisted: [Package] = []
        var active: [Package] = []

        for pkg in packages {
            if pkg.isReadOnly {
                skippedReadOnly.append(pkg)
            } else if denylist.isDenylisted(pkg) {
                warnedDenylisted.append(pkg)
            } else {
                active.append(pkg)
            }
        }

        let trashRoot = "$HOME/.Trash/installory-\(Int(Date().timeIntervalSince1970))"
        let script = buildScript(
            active: active,
            denylisted: warnedDenylisted,
            snapshot: snapshot,
            strategy: strategy,
            trashRoot: trashRoot
        )
        return GeneratedScript(
            scriptText: script,
            skippedReadOnly: skippedReadOnly,
            warnedDenylisted: warnedDenylisted
        )
    }

    // MARK: - Script assembly

    private func buildScript(
        active: [Package],
        denylisted: [Package],
        snapshot: SnapshotContext?,
        strategy: RemovalStrategy,
        trashRoot: String
    ) -> String {
        var header: [String] = []
        appendHeader(to: &header, snapshot: snapshot, strategy: strategy)
        var out: [String] = []
        if strategy == .trash && active.contains(where: { Self.trashSource(for: $0) != nil }) {
            out.append("mkdir -p \(trashRoot)")
        }
        appendManagerSections(packages: active, strategy: strategy, trashRoot: trashRoot, to: &out)
        if !denylisted.isEmpty {
            appendDenylistSection(packages: denylisted, to: &out)
        }
        return assembleSubshellScript(header: header, body: out)
    }

    private func appendHeader(to out: inout [String], snapshot: SnapshotContext?, strategy: RemovalStrategy) {
        let fmt = makeISO8601Formatter()
        out.append("#!/usr/bin/env bash")
        out.append("# Generated by Installory on \(fmt.string(from: Date()))")
        out.append("# Review every line before running. You can run this script manually")
        out.append("# in Terminal — Installory does not execute it for you.")

        if strategy == .trash {
            out.append("#")
            out.append("# Trash mode: file-backed packages are moved to ~/.Trash instead of")
            out.append("# being deleted. Package-manager packages still use their normal")
            out.append("# uninstall command.")
        }

        if let snapshot {
            out.append("#")
            out.append("# Snapshot taken before this script was generated:")
            out.append("#   \(snapshot.id.uuidString)  (created \(fmt.string(from: snapshot.createdAt)))")
            out.append("# To restore the original state if something goes wrong, load this")
            out.append("# snapshot in Installory and use \"Restore Missing Packages\".")
        }
    }

    // MARK: - Manager sections

    // Canonical output order. Managers not in this list are appended alphabetically.
    private static let managerOrder: [PackageManager] = [
        .brew, .brewCask, .pip, .npm, .pipx, .uv, .cargo, .gem, .mas, .agentSkill,
        .agentCli, .editorExtension,
    ]

    private func appendManagerSections(
        packages: [Package],
        strategy: RemovalStrategy,
        trashRoot: String,
        to out: inout [String]
    ) {
        let handledSet = Set(Self.managerOrder)

        for manager in Self.managerOrder {
            let pkgs = packages.filter { $0.manager == manager }
            guard !pkgs.isEmpty else { continue }
            appendSection(manager: manager, packages: pkgs, strategy: strategy, trashRoot: trashRoot, to: &out)
        }

        // Any enum case omitted from the preferred order remains deterministic.
        let extra = Set(packages.map { $0.manager })
            .subtracting(handledSet)
            .sorted { $0.rawValue < $1.rawValue }
        for manager in extra {
            let pkgs = packages.filter { $0.manager == manager }
            appendSection(manager: manager, packages: pkgs, strategy: strategy, trashRoot: trashRoot, to: &out)
        }
    }

    private func appendSection(
        manager: PackageManager,
        packages: [Package],
        strategy: RemovalStrategy,
        trashRoot: String,
        to out: inout [String]
    ) {
        if manager.groupsByQualifier {
            // pip, npm and gem emit one row per qualifier (interpreter, Node install,
            // Ruby install). Each qualifier gets its own sub-section so the reader can
            // see which installation a block of commands targets.
            let byQualifier = Dictionary(grouping: packages) { $0.qualifier ?? "" }
            for qualifier in byQualifier.keys.sorted() {
                let pkgs = byQualifier[qualifier]!
                let sorted = topologicalSort(pkgs)
                out.append("")
                out.append(qualifiedSectionHeader(for: manager, qualifier: qualifier))
                appendCommandLines(
                    sorted: sorted.sorted,
                    cyclePackages: sorted.cyclePackages,
                    strategy: strategy,
                    trashRoot: trashRoot,
                    to: &out
                )
            }
        } else {
            // pipx and uv can contain distinct managed environments whose internal
            // dependencies are not separate inventory rows. Name-keyed dependency
            // sorting would collapse those records, so keep path-qualified order.
            let sorted = manager == .pipx || manager == .uv
                ? SortResult(
                    sorted: packages.sorted(by: pipxPackageOrder),
                    cyclePackages: []
                )
                : topologicalSort(packages)
            out.append("")
            out.append(sectionHeader(for: manager))
            appendCommandLines(
                sorted: sorted.sorted,
                cyclePackages: sorted.cyclePackages,
                strategy: strategy,
                trashRoot: trashRoot,
                to: &out
            )
        }
    }

    private func appendCommandLines(
        sorted: [Package],
        cyclePackages: [Package],
        strategy: RemovalStrategy,
        trashRoot: String,
        to out: inout [String]
    ) {
        for pkg in sorted {
            appendSinglePackageLines(for: pkg, strategy: strategy, trashRoot: trashRoot, to: &out)
        }
        if !cyclePackages.isEmpty {
            out.append("# WARNING: dependency cycle detected")
            for pkg in cyclePackages {
                appendSinglePackageLines(for: pkg, strategy: strategy, trashRoot: trashRoot, to: &out)
            }
        }
    }

    private func appendSinglePackageLines(
        for pkg: Package,
        strategy: RemovalStrategy,
        trashRoot: String,
        to out: inout [String]
    ) {
        if pkg.manager == .mas {
            out.append("# \(shellCommentText(pkg.name)): mas does not support CLI uninstall; remove the .app manually from /Applications")
            return
        }

        if strategy == .trash, let cmd = trashCommand(for: pkg, trashRoot: trashRoot) {
            out.append(shellEchoLine(for: cmd))
            out.append(cmd)
            return
        }

        if pkg.manager == .agentSkill {
            // Skills have no package-manager backup. A broken symlink can be removed
            // safely (it is just a dangling link); a real skill directory or a
            // resolvable symlink is destructive to delete, so it stays commented.
            if pkg.isBrokenAgentSkillLink {
                let linkPath = Self.agentSkillLinkPath(for: pkg)
                let cmd = "rm \(shellArgument(linkPath))"
                out.append(shellEchoLine(for: cmd))
                out.append(cmd)
                return
            }
            let bar = "# " + String(repeating: "=", count: 40)
            out.append(bar)
            out.append("# WARNING: agent skills have no package-manager backup. Removing")
            out.append("# this skill deletes its files permanently.")
            out.append(bar)
            let target = pkg.installPath?.path ?? pkg.artifactPaths?.first ?? pkg.name
            out.append("# rm -rf \(shellCommentText(target))")
            return
        }

        let cmd = renderCommand(for: pkg)
        if cmd.hasPrefix("#") {
            out.append(cmd)
            return
        }
        out.append(shellEchoLine(for: cmd))
        out.append(cmd)

        // For casks, list artifact paths the user may want to clean up manually.
        if pkg.manager == .brewCask, let paths = pkg.artifactPaths, !paths.isEmpty {
            out.append("# Files brew may not remove automatically:")
            for path in paths {
                out.append("#   \(shellCommentText(path))")
            }
        }
    }

    /// Reconstructs the on-disk location of an agent skill row from its qualifier
    /// (owning skills root) and name. Broken-symlink rows store no `installPath`
    /// (the link does not resolve), but the link itself always sits directly under
    /// the owning root, so `qualifier/name` is the exact path to remove.
    static func agentSkillLinkPath(for pkg: Package) -> String {
        guard let root = pkg.qualifier, !root.isEmpty else { return pkg.name }
        return URL(fileURLWithPath: root)
            .appendingPathComponent(pkg.name)
            .standardizedFileURL
            .path
    }

    /// The reversible `mv` command used in trash mode, or nil for packages that have
    /// no file-backed form. Moves the item into a fresh, timestamped folder under
    /// `~/.Trash` so a same-named item already in the Trash is never clobbered.
    private func trashCommand(for pkg: Package, trashRoot: String) -> String? {
        guard let source = Self.trashSource(for: pkg) else { return nil }
        return "mv \(shellArgument(source)) \(trashRoot)/\(shellArgument(pkg.name))"
    }

    /// The on-disk path trash mode would move for a file-backed row, or nil when
    /// the row has no file-backed form (package-manager rows, agent CLIs).
    static func trashSource(for pkg: Package) -> String? {
        let source: String?
        switch pkg.manager {
        case .agentSkill:
            source = pkg.isBrokenAgentSkillLink
                ? agentSkillLinkPath(for: pkg)
                : (pkg.installPath?.path ?? pkg.artifactPaths?.first)
        case .editorExtension:
            source = pkg.installPath?.path
        default:
            return nil
        }
        guard let source, !source.isEmpty else { return nil }
        return source
    }

    private func appendDenylistSection(packages: [Package], to out: inout [String]) {
        let bar = "# " + String(repeating: "=", count: 60)
        out.append("")
        out.append(bar)
        out.append("# WARNING: the following packages are commonly depended on by other")
        out.append("# software. Installory has commented them out. Uncomment only if you are")
        out.append("# certain you do not need them.")
        out.append(bar)

        for pkg in packages {
            let reasonSuffix = denylist.reason(for: pkg)
                .map { "  # reason: \(shellCommentText($0))" } ?? ""
            if pkg.manager == .mas {
                out.append("# \(shellCommentText(pkg.name)): mas does not support CLI uninstall; remove the .app manually from /Applications\(reasonSuffix)")
            } else {
                // `shellArgument` protects active commands, but this copy is embedded
                // after `#` and therefore must never contain a physical line break.
                let cmd = shellCommentText(renderCommand(for: pkg))
                out.append("# \(cmd)\(reasonSuffix)")
            }
        }
    }

    // MARK: - Command rendering

    private func renderCommand(for pkg: Package) -> String {
        let name = shellArgument(pkg.name)
        switch pkg.manager {
        case .brew:
            return "brew uninstall \(name)"
        case .brewCask:
            return "brew uninstall --cask \(name)"
        case .pip:
            let interpreter = pkg.qualifier ?? "python3"
            return "\(shellArgument(interpreter)) -m pip uninstall -y \(name)"
        case .npm:
            // Bare `npm` resolves via PATH, which silently targets the wrong Node
            // install when the same package exists under several. See ManagerBinaryResolver.
            let npm = ManagerBinaryResolver.npm(forQualifier: pkg.qualifier)
            return "\(shellArgument(npm)) uninstall -g \(name)"
        case .pipx:
            let environment = PipxEnvironmentIdentity.environmentName(from: pkg.qualifier)
                ?? pkg.name
            return "pipx uninstall \(shellArgument(environment))"
        case .uv:
            guard let target = UvToolEnvironmentIdentity.target(from: pkg.qualifier) else {
                let recordedEnvironment = pkg.qualifier.map(shellCommentText)
                    ?? "no recorded environment path"
                return "# Manual review required: cannot safely target uv tool "
                    + "\(shellCommentText(pkg.name)) from \(recordedEnvironment); "
                    + "no uninstall command generated."
            }
            return "UV_TOOL_DIR=\(shellArgument(target.toolsRoot)) uv tool uninstall "
                + shellArgument(target.environmentName)
        case .cargo:
            return "cargo uninstall \(name)"
        case .gem:
            let gem = ManagerBinaryResolver.gem(forQualifier: pkg.qualifier)
            let versionTarget = "\(name) -v \(shellArgument(pkg.version))"
            if let installDir = gem.installDir {
                return "\(shellArgument(gem.binary)) uninstall \(versionTarget) --install-dir \(shellArgument(installDir))"
            }
            return "\(shellArgument(gem.binary)) uninstall \(versionTarget)"
        case .mas:
            // mas has no CLI uninstall; caller handles this case before reaching renderCommand
            return "\(pkg.name)  # remove manually from /Applications"
        case .agentSkill:
            // Broken symlink: remove only the dangling link itself.
            if pkg.isBrokenAgentSkillLink {
                return "rm \(shellArgument(Self.agentSkillLinkPath(for: pkg)))"
            }
            // Real directory or resolvable symlink: destructive, no package-manager
            // backup. Emitted as a comment so it never runs without explicit review.
            let target = pkg.installPath?.path ?? pkg.artifactPaths?.first ?? pkg.name
            return "# rm -rf \(shellCommentText(target))  # no package-manager backup"
        case .agentCli:
            // Agent CLIs are typically installed by an external installer (brew, npm,
            // pkg) that this row does not track. Emit a review comment, never a command.
            let configRoot = pkg.qualifier.map(shellCommentText) ?? "unknown config root"
            return "# \(shellCommentText(pkg.name)): remove with the installer that placed it "
                + "(config at \(configRoot)); no generated uninstall command"
        case .editorExtension:
            // `code`/`cursor` — uninstall through the editor's own CLI, which is the
            // only safe path (it also removes the extension from enabled state).
            guard let editor = Self.editorCommand(for: pkg.qualifier) else {
                let recordedRoot = pkg.qualifier.map(shellCommentText) ?? "no recorded editor root"
                return "# Manual review required: no editor CLI known for \(recordedRoot); "
                    + "uninstall \(shellCommentText(pkg.name)) from the editor UI"
            }
            return "\(editor) --uninstall-extension \(name)"
        }
    }

    /// Maps an editor-extension qualifier (an editor extensions root path) to the
    /// editor CLI binary that manages it. Returns nil when no editor is recognized.
    static func editorCommand(for qualifier: String?) -> String? {
        let path = qualifier ?? ""
        if path.contains("/.cursor/") { return "cursor" }
        if path.contains("/.vscode/") { return "code" }
        return nil
    }

    private func sectionHeader(for manager: PackageManager) -> String {
        switch manager {
        case .brew:    return "# === Homebrew Formulae ==="
        case .brewCask: return "# === Homebrew Casks ==="
        case .pip:     return "# === pip ==="
        case .npm:     return "# === npm (global) ==="
        case .pipx:    return "# === pipx ==="
        case .uv:      return "# === uv tools ==="
        case .cargo:   return "# === Cargo (Rust) ==="
        case .gem:     return "# === Ruby Gems ==="
        case .mas:     return "# === Mac App Store ==="
        case .agentSkill: return "# === Agent Skills ==="
        case .agentCli: return "# === Agent CLIs ==="
        case .editorExtension: return "# === Editor Extensions ==="
        }
    }

    /// Section header for a manager that groups by qualifier. An empty qualifier means
    /// the scanner recorded no installation, so the plain header is used.
    private func qualifiedSectionHeader(for manager: PackageManager, qualifier: String) -> String {
        guard !qualifier.isEmpty else { return sectionHeader(for: manager) }
        let commentQualifier = shellCommentText(qualifier)
        switch manager {
        case .pip: return "# === pip (interpreter: \(commentQualifier)) ==="
        case .npm: return "# === npm (global: \(commentQualifier)) ==="
        case .gem: return "# === Ruby Gems (\(commentQualifier)) ==="
        case .agentSkill: return "# === Agent Skills (\(commentQualifier)) ==="
        case .agentCli: return "# === Agent CLIs (\(commentQualifier)) ==="
        case .editorExtension: return "# === Editor Extensions (\(commentQualifier)) ==="
        default:   return sectionHeader(for: manager)
        }
    }

    // MARK: - Topological sort

    private struct SortResult: Sendable {
        let sorted: [Package]
        let cyclePackages: [Package]
    }

    struct DependencyOrderingDiagnostics: Sendable, Equatable {
        let enqueuedNodeCount: Int
        let dequeuedNodeCount: Int
        let queueComparisonCount: Int
    }

    private struct LexicographicMinHeap {
        private(set) var comparisonCount = 0
        private var elements: [String] = []

        mutating func insert(_ element: String) {
            elements.append(element)
            var child = elements.count - 1

            while child > 0 {
                let parent = (child - 1) / 2
                guard isOrdered(elements[child], before: elements[parent]) else { break }
                elements.swapAt(child, parent)
                child = parent
            }
        }

        mutating func removeMinimum() -> String? {
            guard !elements.isEmpty else { return nil }
            guard elements.count > 1 else { return elements.removeLast() }

            let minimum = elements[0]
            elements[0] = elements.removeLast()
            var parent = 0

            while true {
                let left = 2 * parent + 1
                guard left < elements.count else { break }

                let right = left + 1
                var minimumChild = left
                if right < elements.count,
                   isOrdered(elements[right], before: elements[left]) {
                    minimumChild = right
                }

                guard isOrdered(elements[minimumChild], before: elements[parent]) else { break }
                elements.swapAt(parent, minimumChild)
                parent = minimumChild
            }

            return minimum
        }

        private mutating func isOrdered(_ lhs: String, before rhs: String) -> Bool {
            comparisonCount += 1
            return lhs < rhs
        }
    }

    private func pipxPackageOrder(_ lhs: Package, _ rhs: Package) -> Bool {
        let lhsQualifier = lhs.qualifier ?? ""
        let rhsQualifier = rhs.qualifier ?? ""
        if lhsQualifier != rhsQualifier { return lhsQualifier < rhsQualifier }
        return lhs.id < rhs.id
    }

    /// Kahn's algorithm over the within-group dependency graph.
    ///
    /// Edge A → B means "A depends on B" so A is removed before B in the script.
    /// Nodes with in-degree 0 among the selected set have no selected dependents
    /// and are safe to remove first. Remaining nodes after the traversal form cycles.
    private func topologicalSort(_ packages: [Package]) -> SortResult {
        Self.makeDependencyOrder(packages).result
    }

    /// Internal instrumentation for regression tests. Production and tests both use
    /// `makeDependencyOrder`, so the reported operation shape covers the real path.
    static func dependencyOrderingDiagnostics(
        for packages: [Package]
    ) -> DependencyOrderingDiagnostics {
        makeDependencyOrder(packages).diagnostics
    }

    private static func makeDependencyOrder(
        _ packages: [Package]
    ) -> (result: SortResult, diagnostics: DependencyOrderingDiagnostics) {
        guard packages.count > 1 else {
            return (
                SortResult(sorted: packages, cyclePackages: []),
                DependencyOrderingDiagnostics(
                    enqueuedNodeCount: packages.count,
                    dequeuedNodeCount: packages.count,
                    queueComparisonCount: 0
                )
            )
        }

        // Package names are not unique within a manager scope: RubyGems permits
        // several installed versions at once. Graph nodes therefore use stable
        // package IDs, while dependency names fan out to every selected package
        // with that normalized name.
        let byID = Dictionary(packages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var idsByName: [String: [String]] = [:]
        for package in byID.values {
            let name = PackageIdentity.normalizedName(package.name, manager: package.manager)
            idsByName[name, default: []].append(package.id)
        }
        for key in idsByName.keys { idsByName[key]?.sort() }

        // in-degree: how many selected packages depend on this node.
        var inDegree: [String: Int] = Dictionary(uniqueKeysWithValues: byID.keys.map { ($0, 0) })
        // adj[x] = dependency package IDs of x that are also selected.
        var adjacencySets: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: byID.keys.map { ($0, Set<String>()) }
        )

        for package in byID.values {
            for dependencyName in package.dependencies {
                let normalized = PackageIdentity.normalizedName(
                    dependencyName,
                    manager: package.manager
                )
                for dependencyID in idsByName[normalized] ?? []
                    where dependencyID != package.id {
                    if adjacencySets[package.id, default: []].insert(dependencyID).inserted {
                        inDegree[dependencyID, default: 0] += 1
                    }
                }
            }
        }
        let adjacency = adjacencySets.mapValues { $0.sorted() }

        var queue = LexicographicMinHeap()
        var enqueuedNodeCount = 0
        for packageID in inDegree.lazy.filter({ $0.value == 0 }).map(\.key) {
            queue.insert(packageID)
            enqueuedNodeCount += 1
        }

        var result: [Package] = []
        var seen: Set<String> = []
        var dequeuedNodeCount = 0

        while let packageID = queue.removeMinimum() {
            dequeuedNodeCount += 1
            guard !seen.contains(packageID), let package = byID[packageID] else { continue }
            seen.insert(packageID)
            result.append(package)

            for dependencyID in adjacency[packageID, default: []] {
                inDegree[dependencyID, default: 0] -= 1
                if inDegree[dependencyID] == 0 {
                    queue.insert(dependencyID)
                    enqueuedNodeCount += 1
                }
            }
        }

        let cyclePackages = byID.values
            .filter { !seen.contains($0.id) }
            .sorted { $0.id < $1.id }
        return (
            SortResult(sorted: result, cyclePackages: cyclePackages),
            DependencyOrderingDiagnostics(
                enqueuedNodeCount: enqueuedNodeCount,
                dequeuedNodeCount: dequeuedNodeCount,
                queueComparisonCount: queue.comparisonCount
            )
        )
    }

    // MARK: - Utilities

    private func makeISO8601Formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }
}

enum PipxEnvironmentIdentity {
    enum ReinstallTarget: Equatable {
        case base
        case suffixed(String)
        case manualReview
    }

    static func environmentName(from qualifier: String?) -> String? {
        guard let qualifier, qualifier.hasPrefix("/") else { return nil }
        let rawComponents = qualifier.split(separator: "/", omittingEmptySubsequences: true)
        guard !rawComponents.isEmpty,
              !rawComponents.contains(where: { $0 == "." || $0 == ".." }) else {
            return nil
        }

        let environmentName = URL(fileURLWithPath: qualifier)
            .standardizedFileURL
            .lastPathComponent
        return environmentName.isEmpty ? nil : environmentName
    }

    static func reinstallTarget(
        distributionName: String,
        qualifier: String?
    ) -> ReinstallTarget {
        guard isSafeIdentityComponent(distributionName),
              let environmentName = environmentName(from: qualifier),
              isSafeIdentityComponent(environmentName) else {
            return .manualReview
        }
        if environmentName == distributionName { return .base }
        guard environmentName.hasPrefix(distributionName) else { return .manualReview }

        let suffix = String(environmentName.dropFirst(distributionName.count))
        return suffix.isEmpty ? .manualReview : .suffixed(suffix)
    }

    private static func isSafeIdentityComponent(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains("/") else { return false }
        let unsafeScalars = CharacterSet.controlCharacters.union(.newlines)
        return value.unicodeScalars.allSatisfy { !unsafeScalars.contains($0) }
    }
}
