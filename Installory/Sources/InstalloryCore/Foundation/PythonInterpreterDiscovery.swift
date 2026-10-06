import Foundation

/// A Python interpreter discovered by walking known on-disk installation roots.
public struct PythonInterpreter: Equatable, Hashable, Sendable {
    /// The interpreter executable path.
    public let executable: URL
    /// The parsed interpreter version.
    public let version: PythonVersion
    /// The installation family that owns this interpreter.
    public let kind: Kind
    /// Existing `site-packages` or `dist-packages` directories for this interpreter.
    public let sitePackages: [URL]
    /// True when this interpreter is managed by macOS or Xcode Command Line Tools.
    public let isSystem: Bool

    public init(
        executable: URL,
        version: PythonVersion,
        kind: Kind,
        sitePackages: [URL],
        isSystem: Bool
    ) {
        self.executable = executable
        self.version = version
        self.kind = kind
        self.sitePackages = sitePackages
        self.isSystem = isSystem
    }

    /// The known Python interpreter installation families.
    public enum Kind: String, Codable, Sendable {
        case system
        case commandLineTools
        case homebrew
        case pyenv
        case uv
        case conda
        case pipx
        case projectVenv
    }

    /// A semantic Python version with major, minor, and patch components.
    public struct PythonVersion: Comparable, Codable, Hashable, Sendable {
        public let major: Int
        public let minor: Int
        public let patch: Int

        public init(major: Int, minor: Int, patch: Int) {
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        /// Parses a version from strings such as `"3.12"`, `"3.11.7"`, `"Python 3.11.7"`, or `"python@3.12"`.
        /// Requires at least a major.minor pair; bare integers like `"3"` or executable names like `"python3"` return nil.
        public init?(_ string: String) {
            let components = Self.versionComponents(in: string)
            guard components.count >= 2 else { return nil }

            self.major = components[0]
            self.minor = components[1]
            self.patch = components.count >= 3 ? components[2] : 0
        }

        public static func < (lhs: PythonVersion, rhs: PythonVersion) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }

        private static func versionComponents(in string: String) -> [Int] {
            var best: [Int] = []
            var current = ""

            for scalar in string.unicodeScalars {
                if CharacterSet.decimalDigits.contains(scalar) || scalar.value == 46 {
                    current.unicodeScalars.append(scalar)
                } else {
                    best = choose(best: best, candidate: current)
                    current = ""
                }
            }
            return choose(best: best, candidate: current)
        }

        private static func choose(best: [Int], candidate: String) -> [Int] {
            let parts = candidate
                .split(separator: ".")
                .compactMap { Int($0) }
            return parts.count > best.count ? parts : best
        }
    }
}

/// Reference-type, thread-safe memo cache so `discover()` runs its filesystem
/// walk at most once per `PythonInterpreterDiscovery` instance.
private final class DiscoveryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PythonInterpreter]?
    var value: [PythonInterpreter]? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

/// Discovers Python interpreters by walking known filesystem locations,
/// including `$PYENV_ROOT` when configured.
///
/// Discovery never invokes Python or `pip`; all filesystem operations go
/// through the injected `DirectoryAccessProvider`.
public struct PythonInterpreterDiscovery: Sendable {
    private let directoryAccess: any DirectoryAccessProvider
    private let homeDirectory: URL
    private let environment: PackageManagerEnvironment
    private let cache = DiscoveryCache()

    public init(
        directoryAccess: any DirectoryAccessProvider = SystemDirectoryAccessProvider(),
        homeDirectory: URL = UserHome.directory,
        environment: PackageManagerEnvironment = .current,
        projectVenvRoots: [URL] = []
    ) {
        self.directoryAccess = directoryAccess
        self.homeDirectory = homeDirectory
        self.environment = environment
        self._projectVenvRoots = projectVenvRoots
    }

    /// Returns all discovered interpreters, memoized for the lifetime of this
    /// discovery instance.
    ///
    /// A single scan reuses one `PythonInterpreterDiscovery` for both
    /// `isAvailable()` and `scan()`, so without memoization the (filesystem-heavy)
    /// walk runs multiple times per scan. The cache is shared across struct copies
    /// because it's a reference type, and a fresh discovery is created per scan, so
    /// results stay current run-to-run.
    public func discover() -> [PythonInterpreter] {
        guard !Task.isCancelled else { return [] }
        if let cached = cache.value { return cached }
        let result = computeDiscover()
        // Never memoize a partial walk abandoned by a scanner timeout.
        guard !Task.isCancelled else { return [] }
        cache.value = result
        return result
    }

    private func computeDiscover() -> [PythonInterpreter] {
        var candidates: [Candidate] = []
        let candidateGroups: [() -> [Candidate]] = [
            systemCandidates,
            commandLineToolsCandidates,
            homebrewCandidates,
            pyenvCandidates,
            uvCandidates,
            condaCandidates,
            pipxCandidates,
            projectVenvCandidates,
        ]
        for candidateGroup in candidateGroups {
            guard !Task.isCancelled else { return [] }
            candidates.append(contentsOf: candidateGroup())
        }

        var seen: Set<String> = []
        var interpreters: [PythonInterpreter] = []
        for candidate in candidates {
            guard !Task.isCancelled else { return [] }
            guard directoryAccess.fileExists(at: candidate.executable) else { continue }
            let resolved = directoryAccess.resolvingSymlinks(at: candidate.executable).path
            guard seen.insert(resolved).inserted else { continue }
            if let interpreter = makeInterpreter(from: candidate) {
                interpreters.append(interpreter)
            }
        }
        return interpreters.sorted { $0.executable.path < $1.executable.path }
    }

    // MARK: - Candidate enumeration

    private func systemCandidates() -> [Candidate] {
        [Candidate(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            kind: .system,
            installRoot: URL(fileURLWithPath: "/usr"),
            versionHint: "python3"
        )]
    }

    private func commandLineToolsCandidates() -> [Candidate] {
        let executable = URL(fileURLWithPath: "/Library/Developer/CommandLineTools/usr/bin/python3")
        return [Candidate(
            executable: executable,
            kind: .commandLineTools,
            installRoot: URL(fileURLWithPath: "/Library/Developer/CommandLineTools/usr"),
            versionHint: "python3"
        )]
    }

    private func homebrewCandidates() -> [Candidate] {
        let prefixes = [
            URL(fileURLWithPath: "/opt/homebrew"),
            URL(fileURLWithPath: "/usr/local"),
        ]
        return prefixes.flatMap { prefix in
            homebrewOptCandidates(prefix: prefix)
                + homebrewCellarCandidates(prefix: prefix)
                + homebrewBinCandidates(prefix: prefix)
        }
    }

    private func homebrewOptCandidates(prefix: URL) -> [Candidate] {
        let opt = prefix.appendingPathComponent("opt")
        return cancellableDirectoryContents(at: opt)
            .filter { $0.lastPathComponent.hasPrefix("python@") }
            .flatMap { pythonRoot -> [Candidate] in
                guard !Task.isCancelled else { return [] }
                let bin = pythonRoot.appendingPathComponent("bin")
                return pythonExecutables(in: bin).map {
                    Candidate(
                        executable: $0,
                        kind: .homebrew,
                        installRoot: pythonRoot,
                        versionHint: pythonRoot.lastPathComponent
                    )
                }
            }
    }

    private func homebrewCellarCandidates(prefix: URL) -> [Candidate] {
        let cellar = prefix.appendingPathComponent("Cellar")
        return cancellableDirectoryContents(at: cellar)
            .filter { $0.lastPathComponent.hasPrefix("python@") }
            .flatMap { formula -> [Candidate] in
                guard !Task.isCancelled else { return [] }
                return cancellableDirectoryContents(at: formula).flatMap { versionRoot -> [Candidate] in
                    guard !Task.isCancelled else { return [] }
                    let bin = versionRoot.appendingPathComponent("bin")
                    return pythonExecutables(in: bin).map {
                        Candidate(
                            executable: $0,
                            kind: .homebrew,
                            installRoot: versionRoot,
                            versionHint: versionRoot.lastPathComponent
                        )
                    }
                }
            }
    }

    private func homebrewBinCandidates(prefix: URL) -> [Candidate] {
        let bin = prefix.appendingPathComponent("bin")
        return pythonExecutables(in: bin).map {
            Candidate(
                executable: $0,
                kind: .homebrew,
                installRoot: prefix,
                versionHint: $0.lastPathComponent
            )
        }
    }

    private func pyenvCandidates() -> [Candidate] {
        let pyenvRoot = environment.pyenvRoot(
            fallback: homeDirectory.appendingPathComponent(".pyenv")
        )
        let versions = pyenvRoot
            .appendingPathComponent("versions")

        return cancellableDirectoryContents(at: versions).compactMap { versionRoot in
            guard !Task.isCancelled else { return nil }
            return Candidate(
                executable: versionRoot.appendingPathComponent("bin/python"),
                kind: .pyenv,
                installRoot: versionRoot,
                versionHint: versionRoot.lastPathComponent
            )
        }
    }

    /// uv installs interpreters under `~/.local/share/uv/python/<id>/`. Each
    /// `<id>` directory contains a `bin/python3.<minor>` executable. We accept
    /// either `bin/python3` or `bin/python3.<minor>`.
    private func uvCandidates() -> [Candidate] {
        let root = environment.uvPythonInstallDirectory(
            fallback: homeDirectory.appendingPathComponent(".local/share/uv/python")
        )
        return cancellableDirectoryContents(at: root).flatMap { versionRoot -> [Candidate] in
            guard !Task.isCancelled else { return [] }
            let bin = versionRoot.appendingPathComponent("bin")
            return pythonExecutables(in: bin).map {
                Candidate(
                    executable: $0,
                    kind: .uv,
                    installRoot: versionRoot,
                    versionHint: versionRoot.lastPathComponent
                )
            }
        }
    }

    private func condaCandidates() -> [Candidate] {
        []
    }

    private func pipxCandidates() -> [Candidate] {
        []
    }

    /// Project venvs in additional roots provided by the host app (typically
    /// directories the user granted read access to). For each root we check the
    /// root itself and its immediate children for `.venv/bin/python(3)` and
    /// `venv/bin/python(3)`. Going deeper would force-walk the filesystem under
    /// every granted directory, which is too expensive.
    private func projectVenvCandidates() -> [Candidate] {
        var candidates: [Candidate] = []
        var seenProjectDirectories: Set<String> = []

        for root in projectVenvRoots
            .map(\.standardizedFileURL)
            .sorted(by: { $0.path < $1.path }) {
            guard !Task.isCancelled else { return [] }
            let resolvedRoot = directoryAccess
                .resolvingSymlinks(at: root)
                .standardizedFileURL
            let projectDirectories = ([root] + cancellableDirectoryContents(at: root))
                .map(\.standardizedFileURL)
                .filter { isSameOrImmediateChild($0, of: root) }
                .sorted(by: { $0.path < $1.path })

            for projectDirectory in projectDirectories {
                guard !Task.isCancelled else { return [] }
                let resolvedProject = directoryAccess
                    .resolvingSymlinks(at: projectDirectory)
                    .standardizedFileURL
                guard isContained(resolvedProject, in: resolvedRoot),
                      seenProjectDirectories.insert(resolvedProject.path).inserted else {
                    continue
                }

                let venvCandidates = [
                    projectDirectory.appendingPathComponent(".venv"),
                    projectDirectory.appendingPathComponent("venv"),
                ]
                for venv in venvCandidates {
                    guard !Task.isCancelled else { return [] }
                    let resolvedVenv = directoryAccess
                        .resolvingSymlinks(at: venv)
                        .standardizedFileURL
                    guard isContained(resolvedVenv, in: resolvedRoot) else { continue }

                    let bin = venv.appendingPathComponent("bin")
                    for executable in pythonExecutables(in: bin)
                        .sorted(by: { $0.path < $1.path }) {
                        guard !Task.isCancelled else { return [] }
                        let resolvedExecutable = directoryAccess
                            .resolvingSymlinks(at: executable)
                            .standardizedFileURL
                        guard isContained(resolvedExecutable, in: resolvedRoot) else { continue }
                        candidates.append(Candidate(
                            executable: executable,
                            kind: .projectVenv,
                            installRoot: venv,
                            versionHint: executable.lastPathComponent
                        ))
                    }
                }
            }
        }
        return candidates
    }

    /// Extra roots to look under for project venvs. Defaults to none; the app
    /// layer injects this from the user's granted directories.
    private var projectVenvRoots: [URL] { _projectVenvRoots }
    private let _projectVenvRoots: [URL]

    // MARK: - Interpreter construction

    private func makeInterpreter(from candidate: Candidate) -> PythonInterpreter? {
        guard let version = inferVersion(from: candidate) else { return nil }

        let sitePackages = [
            candidate.installRoot
                .appendingPathComponent("lib")
                .appendingPathComponent("python\(version.major).\(version.minor)")
                .appendingPathComponent("site-packages"),
            candidate.installRoot
                .appendingPathComponent("lib")
                .appendingPathComponent("python\(version.major).\(version.minor)")
                .appendingPathComponent("dist-packages"),
        ].filter { directoryAccess.fileExists(at: $0) }

        return PythonInterpreter(
            executable: candidate.executable,
            version: version,
            kind: candidate.kind,
            sitePackages: sitePackages,
            isSystem: isSystem(candidate.executable, kind: candidate.kind)
        )
    }

    private func inferVersion(from candidate: Candidate) -> PythonInterpreter.PythonVersion? {
        if let version = PythonInterpreter.PythonVersion(candidate.versionHint) {
            return version
        }

        let lib = candidate.installRoot.appendingPathComponent("lib")
        for child in cancellableDirectoryContents(at: lib)
            where child.lastPathComponent.hasPrefix("python") {
            guard !Task.isCancelled else { return nil }
            if let version = PythonInterpreter.PythonVersion(child.lastPathComponent) {
                return version
            }
        }
        return nil
    }

    private func isSystem(_ executable: URL, kind: PythonInterpreter.Kind) -> Bool {
        kind == .system
            || kind == .commandLineTools
            || executable.path.hasPrefix("/usr/bin")
            || executable.path.contains("CommandLineTools")
    }

    // MARK: - Filesystem helpers

    private func cancellableDirectoryContents(at url: URL) -> [URL] {
        guard !Task.isCancelled else { return [] }
        return directoryAccess.directoryContentsOrEmpty(at: url)
    }

    private func pythonExecutables(in bin: URL) -> [URL] {
        guard !Task.isCancelled else { return [] }
        return cancellableDirectoryContents(at: bin)
            .filter { child in
                guard !Task.isCancelled else { return false }
                let name = child.lastPathComponent
                if name == "python" || name == "python3" { return true }
                guard name.hasPrefix("python3.") else { return false }
                let suffix = name.dropFirst("python3.".count)
                return !suffix.isEmpty && suffix.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains)
            }
    }

    private func isSameOrImmediateChild(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count == rootComponents.count
                || candidateComponents.count == rootComponents.count + 1 else {
            return false
        }
        return zip(rootComponents, candidateComponents).allSatisfy { pair in
            pair.0 == pair.1
        }
    }

    private func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard rootComponents.count <= candidateComponents.count else { return false }
        return zip(rootComponents, candidateComponents).allSatisfy { pair in
            pair.0 == pair.1
        }
    }
}

private struct Candidate: Sendable {
    let executable: URL
    let kind: PythonInterpreter.Kind
    let installRoot: URL
    let versionHint: String
}
