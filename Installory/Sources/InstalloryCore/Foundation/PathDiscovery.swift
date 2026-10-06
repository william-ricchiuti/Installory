import Foundation

/// Locates package manager directories by checking known on-disk prefixes.
///
/// All discovery is pure filesystem existence checking via `checkExists`.
/// No external binaries are invoked and no directory contents are read.
///
/// The `checkExists` closure is injected so tests can supply a fake
/// filesystem without depending on what's actually installed.
public struct PathDiscovery: Sendable {

    private let checkExists: @Sendable (String) -> Bool
    private let environment: PackageManagerEnvironment
    private let homeDirectory: URL

    /// Creates a `PathDiscovery` backed by a real or fake filesystem.
    ///
    /// - Parameters:
    ///   - environment: Package-manager root overrides inherited by the app.
    ///   - homeDirectory: The user's home directory used for default roots.
    ///   - checkExists: Returns `true` if the given absolute path exists.
    public init(
        environment: PackageManagerEnvironment = .current,
        homeDirectory: URL = UserHome.directory,
        checkExists: @Sendable @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.checkExists = checkExists
    }

    // MARK: - Homebrew

    /// All Homebrew prefix directories present on this system.
    ///
    /// Checks Apple Silicon (`/opt/homebrew`) first, then Intel (`/usr/local`).
    /// Both can coexist on Apple Silicon Macs running Rosetta workloads.
    public var homebrewPrefixes: [URL] {
        ["/opt/homebrew", "/usr/local"]
            .filter { checkExists($0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Other managers

    /// Resolves a managed directory to a URL, or `nil` if the directory
    /// does not exist on this system.
    public func locate(_ kind: ManagerDirectory) -> URL? {
        let fallback = URL(
            fileURLWithPath: kind.candidatePath(home: homeDirectory.path),
            isDirectory: true
        )
        let candidate: URL
        switch kind {
        case .cargoHome:
            candidate = environment.cargoHome(fallback: fallback)
        case .pyenvVersions:
            let fallbackRoot = homeDirectory.appendingPathComponent(".pyenv")
            candidate = environment.pyenvRoot(fallback: fallbackRoot)
                .appendingPathComponent("versions")
        case .nvmNode:
            let fallbackRoot = homeDirectory.appendingPathComponent(".nvm")
            candidate = environment.nvmDirectory(fallback: fallbackRoot)
                .appendingPathComponent("versions/node")
        case .pipxVenvs:
            let fallbackRoot = homeDirectory.appendingPathComponent(".local/share/pipx")
            candidate = environment.pipxHome(fallback: fallbackRoot)
                .appendingPathComponent("venvs")
        case .voltaNode, .bunGlobal, .rbenvVersions:
            candidate = fallback
        }

        guard checkExists(candidate.path) else { return nil }
        return candidate
    }
}

// MARK: - ManagerDirectory

/// The package-manager-specific directories PathDiscovery can locate.
///
/// Homebrew is handled separately via `homebrewPrefixes` because it has
/// two canonical prefixes (Apple Silicon and Intel) that may both be present.
public enum ManagerDirectory: CaseIterable, Sendable {
    case cargoHome       // ~/.cargo
    case pyenvVersions   // ~/.pyenv/versions
    case nvmNode         // ~/.nvm/versions/node
    case voltaNode       // ~/.volta/tools/image/node
    case bunGlobal       // ~/.bun/install/global
    case pipxVenvs       // ~/.local/share/pipx/venvs
    case rbenvVersions   // ~/.rbenv/versions

    /// The absolute path to check for this directory.
    public func candidatePath(home: String) -> String {
        switch self {
        case .cargoHome:      return "\(home)/.cargo"
        case .pyenvVersions:  return "\(home)/.pyenv/versions"
        case .nvmNode:        return "\(home)/.nvm/versions/node"
        case .voltaNode:      return "\(home)/.volta/tools/image/node"
        case .bunGlobal:      return "\(home)/.bun/install/global"
        case .pipxVenvs:      return "\(home)/.local/share/pipx/venvs"
        case .rbenvVersions:  return "\(home)/.rbenv/versions"
        }
    }
}
