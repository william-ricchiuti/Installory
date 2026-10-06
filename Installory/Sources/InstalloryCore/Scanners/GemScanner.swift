import Foundation

/// Scans Ruby gems by walking `specifications/*.gemspec` files for common Ruby
/// installations, `$GEM_HOME`, and version managers.
///
/// Gemspecs are not evaluated as Ruby. Installory only uses the filename for
/// name/version and best-effort string extraction for runtime dependencies.
public struct GemScanner: PackageScanner, Sendable {
    public let manager: PackageManager = .gem

    private let directoryAccess: any DirectoryAccessProvider
    private let homeDirectory: URL
    private let environment: PackageManagerEnvironment

    public init(
        directoryAccess: any DirectoryAccessProvider = SystemDirectoryAccessProvider(),
        homeDirectory: URL = UserHome.directory,
        environment: PackageManagerEnvironment = .current
    ) {
        self.directoryAccess = directoryAccess
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    public func isAvailable() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let dirs = try? specificationDirs() else { return false }
        return !Task.isCancelled && !dirs.isEmpty
    }

    public var unavailableReason: String {
        "Ruby gem specifications not granted or not found"
    }

    public func scan() async throws -> [Package] {
        try Task.checkCancellation()
        var sizer = BoundedDirectorySizer(directoryAccess: directoryAccess)
        var seen: Set<String> = []
        var packages: [Package] = []

        for specificationsDir in try specificationDirs() {
            try Task.checkCancellation()
            let discovered = try await packagesInSpecificationsDir(
                specificationsDir,
                sizer: &sizer
            )
            for package in discovered {
                try Task.checkCancellation()
                guard seen.insert(package.id).inserted else { continue }
                packages.append(package)
            }
        }

        let sortedPackages = packages.sorted {
            ($0.name, $0.qualifier ?? "", $0.version)
                < ($1.name, $1.qualifier ?? "", $1.version)
        }
        try Task.checkCancellation()
        return sortedPackages
    }

    private func specificationDirs() throws -> [URL] {
        let roots = try rubyGemsRoots()
        var candidates: [URL] = []
        for root in roots {
            try Task.checkCancellation()
            candidates.append(contentsOf: try specificationDirs(inGemsRoot: root))
        }

        var seen: Set<String> = []
        var result: [URL] = []
        for candidate in candidates {
            try Task.checkCancellation()
            let resolved = directoryAccess.resolvingSymlinks(at: candidate).path
            guard seen.insert(resolved).inserted else { continue }
            result.append(candidate)
        }
        let sortedResult = result.sorted { $0.path < $1.path }
        try Task.checkCancellation()
        return sortedResult
    }

    private func rubyGemsRoots() throws -> [URL] {
        let userGemHome = environment.gemHome(
            fallback: homeDirectory.appendingPathComponent(".gem/ruby")
        )
        var roots: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/lib/ruby/gems"),
            URL(fileURLWithPath: "/usr/local/lib/ruby/gems"),
            URL(fileURLWithPath: "/Library/Ruby/Gems"),
            userGemHome,
        ]

        let rbenvVersions = homeDirectory.appendingPathComponent(".rbenv/versions")
        let versions = directoryAccess.directoryContentsOrEmpty(at: rbenvVersions)
        try Task.checkCancellation()
        for version in versions {
            try Task.checkCancellation()
            roots.append(version.appendingPathComponent("lib/ruby/gems"))
        }

        return roots
    }

    private func specificationDirs(inGemsRoot root: URL) throws -> [URL] {
        try Task.checkCancellation()
        var dirs: [URL] = []

        let direct = root.appendingPathComponent("specifications")
        if directoryAccess.fileExists(at: direct) {
            dirs.append(direct)
        }
        try Task.checkCancellation()

        let apiVersions = directoryAccess.directoryContentsOrEmpty(at: root)
        try Task.checkCancellation()
        for apiVersion in apiVersions {
            try Task.checkCancellation()
            let specifications = apiVersion.appendingPathComponent("specifications")
            if directoryAccess.fileExists(at: specifications) {
                dirs.append(specifications)
            }
        }

        try Task.checkCancellation()
        return dirs
    }

    private func packagesInSpecificationsDir(
        _ specificationsDir: URL,
        sizer: inout BoundedDirectorySizer
    ) async throws -> [Package] {
        var packages: [Package] = []
        let entries = directoryAccess.directoryContentsOrEmpty(at: specificationsDir)
        try Task.checkCancellation()
        for entry in entries {
            try Task.checkCancellation()
            guard entry.pathExtension == "gemspec",
                  let package = try await makePackage(
                    gemspec: entry,
                    specificationsDir: specificationsDir,
                    sizer: &sizer
                  )
            else { continue }
            packages.append(package)
        }
        try Task.checkCancellation()
        return packages
    }

    private func makePackage(
        gemspec: URL,
        specificationsDir: URL,
        sizer: inout BoundedDirectorySizer
    ) async throws -> Package? {
        try Task.checkCancellation()
        guard let parsed = parseGemspecFilename(gemspec.lastPathComponent) else { return nil }
        // The unpacked gem directory keeps the platform suffix that `version` drops.
        let gemDirName = [parsed.name, parsed.version, parsed.platform]
            .compactMap { $0 }
            .joined(separator: "-")
        let gemDir = specificationsDir
            .deletingLastPathComponent()
            .appendingPathComponent("gems")
            .appendingPathComponent(gemDirName)
        let gemDirExists = directoryAccess.fileExists(at: gemDir)
        let installPath = gemDirExists ? gemDir : gemspec
        let sizeBytes: Int64?
        if gemDirExists {
            sizeBytes = (try await sizer.measure(
                [.tree(gemDir)],
                constrainedTo: specificationsDir.deletingLastPathComponent()
            )).sizeBytes
        } else {
            sizeBytes = nil
        }
        let dependencies = try parseRuntimeDependencies(in: gemspec)
        try Task.checkCancellation()

        return Package(
            id: "gem:\(specificationsDir.path):\(parsed.name):\(parsed.version)",
            manager: .gem,
            qualifier: specificationsDir.path,
            name: parsed.name,
            version: parsed.version,
            installPath: installPath,
            installedAt: directoryAccess.modificationDate(at: gemspec),
            installedAtConfidence: .low,
            sizeBytes: sizeBytes,
            isExplicit: true,
            isReadOnly: isSystemGemPath(specificationsDir),
            dependencies: dependencies,
            lastSeen: Date()
        )
    }

    /// Splits `nokogiri-1.15.4-arm64-darwin.gemspec` into name, version, and the
    /// optional platform suffix that binary gems carry.
    ///
    /// The version is the first hyphen-separated segment that is a real gem version;
    /// everything after it is the platform. A backward walk would instead fold the
    /// platform into the version and emit `gem install nokogiri -v 1.15.4-arm64-darwin`,
    /// which fails.
    private func parseGemspecFilename(
        _ filename: String
    ) -> (name: String, version: String, platform: String?)? {
        guard filename.hasSuffix(".gemspec") else { return nil }
        let basename = String(filename.dropLast(".gemspec".count))
        let parts = basename.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }

        for index in parts.indices.dropFirst() where isGemVersion(parts[index]) {
            let name = parts[..<index].joined(separator: "-")
            guard !name.isEmpty else { return nil }
            let platform = parts[(index + 1)...].joined(separator: "-")
            return (name, String(parts[index]), platform.isEmpty ? nil : platform)
        }

        return nil
    }

    /// A gem version is a dot-separated sequence whose first component is numeric and
    /// whose remaining components are alphanumeric — `1.15.4`, `7.1.0.beta1`, `60`.
    ///
    /// Platform segments never match: `arm64` and `darwin` don't start with a digit,
    /// `x86_64` contains an underscore. Neither does a name segment like `2captcha`,
    /// which is numeric-led but has no dotted structure.
    private func isGemVersion(_ segment: Substring) -> Bool {
        let components = segment.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = components.first, !first.isEmpty,
              first.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) })
        else { return false }

        return components.dropFirst().allSatisfy { component in
            !component.isEmpty
                && component.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        }
    }

    private func parseRuntimeDependencies(in gemspec: URL) throws -> [String] {
        try Task.checkCancellation()
        guard let data = try? directoryAccess.data(contentsOf: gemspec),
              let text = String(data: data, encoding: .utf8) else { return [] }
        try Task.checkCancellation()

        var dependencies: [String] = []
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            try Task.checkCancellation()
            guard line.contains("add_runtime_dependency") || line.contains("add_dependency") else {
                continue
            }
            if let dependency = firstDependencyLiteral(in: line) {
                dependencies.append(dependency)
            }
        }
        let sortedDependencies = Array(Set(dependencies)).sorted()
        try Task.checkCancellation()
        return sortedDependencies
    }

    /// Extracts only the first dependency-name literal after the declaration method.
    /// RubyGems-generated gemspecs commonly use `%q<name>.freeze`; supporting a
    /// bounded set of literal delimiters keeps parsing useful without evaluating Ruby.
    private func firstDependencyLiteral(in line: String) -> String? {
        let methodEnd = line.range(of: "add_runtime_dependency")?.upperBound
            ?? line.range(of: "add_dependency")?.upperBound
        guard var cursor = methodEnd else { return nil }

        while cursor < line.endIndex {
            let character = line[cursor]
            if character == "\"" || character == "'" {
                let contentStart = line.index(after: cursor)
                guard let end = line[contentStart...].firstIndex(of: character) else { return nil }
                return nonemptyLiteral(in: line, from: contentStart, to: end)
            }

            if character == "%" {
                let qIndex = line.index(after: cursor)
                if qIndex < line.endIndex, line[qIndex] == "q" {
                    let delimiterIndex = line.index(after: qIndex)
                    guard delimiterIndex < line.endIndex,
                          let closingDelimiter = percentQClosingDelimiter(for: line[delimiterIndex])
                    else { return nil }
                    let contentStart = line.index(after: delimiterIndex)
                    guard let end = line[contentStart...].firstIndex(of: closingDelimiter) else {
                        return nil
                    }
                    return nonemptyLiteral(in: line, from: contentStart, to: end)
                }
            }

            cursor = line.index(after: cursor)
        }
        return nil
    }

    private func percentQClosingDelimiter(for openingDelimiter: Character) -> Character? {
        switch openingDelimiter {
        case "(": ")"
        case "[": "]"
        case "{": "}"
        case "<": ">"
        case "|", "!", "/": openingDelimiter
        default: nil
        }
    }

    private func nonemptyLiteral(
        in line: String,
        from start: String.Index,
        to end: String.Index
    ) -> String? {
        let value = String(line[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func isSystemGemPath(_ url: URL) -> Bool {
        url.path.hasPrefix("/System/") || url.path.hasPrefix("/Library/Ruby/")
    }
}
