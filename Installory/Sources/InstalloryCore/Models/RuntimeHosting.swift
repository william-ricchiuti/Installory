import Foundation

/// Finds Homebrew formulae that other package managers' packages run on.
///
/// Package metadata only records dependencies within one manager, so a
/// formula such as `node@22`, `ruby`, `pyenv`, `uv` or `pipx` looks unused
/// even when npm globals, gems, Python packages or uv/pipx tools live inside
/// it. Removing it would break those tools. This index links each such
/// formula to the packages it hosts, using only paths already in the
/// inventory (no filesystem access).
enum RuntimeHosting {
    /// Maps a brew formula's package id to the ids of packages it hosts.
    static func hostedPackageIDs(in packages: [Package]) -> [String: [String]] {
        // Only a handful of formula names can host other managers' packages,
        // so the pairwise check stays cheap even with thousands of rows.
        let formulae = packages.filter { $0.manager == .brew && isRuntimeName($0.name) }
        guard !formulae.isEmpty else { return [:] }
        var result: [String: [String]] = [:]
        for formula in formulae {
            let prefixes = homebrewPrefixes(for: formula)
            let hosted = packages.filter { candidate in
                candidate.id != formula.id
                    && candidate.manager != .brew
                    && candidate.manager != .brewCask
                    && hosts(formula: formula.name, prefixes: prefixes, candidate: candidate)
            }
            if !hosted.isEmpty {
                result[formula.id] = hosted.map(\.id)
            }
        }
        return result
    }

    private static let runtimeNames: Set<String> = [
        "node", "ruby", "pyenv", "rbenv", "nodenv", "nvm", "volta", "fnm", "asdf", "mise", "uv", "pipx",
    ]

    private static func isRuntimeName(_ name: String) -> Bool {
        runtimeNames.contains(name) || name.hasPrefix("node@") || name.hasPrefix("ruby@")
    }

    /// The Homebrew prefix a formula lives in, read from its Cellar install
    /// path. Falls back to both standard prefixes when the path is unknown.
    private static func homebrewPrefixes(for formula: Package) -> [String] {
        if let path = formula.installPath?.path, let range = path.range(of: "/Cellar/") {
            return [String(path[..<range.lowerBound])]
        }
        return ["/opt/homebrew", "/usr/local"]
    }

    private static func hosts(formula name: String, prefixes: [String], candidate: Package) -> Bool {
        let location = candidate.qualifier ?? candidate.installPath?.path ?? ""
        let inThisKeg = location.contains("/Cellar/\(name)/") || location.contains("/opt/\(name)/")

        switch name {
        case _ where name == "node" || name.hasPrefix("node@"):
            guard candidate.manager == .npm else { return false }
            return inThisKeg || prefixes.contains { location.hasPrefix("\($0)/lib/node_modules") }
        case _ where name == "ruby" || name.hasPrefix("ruby@"):
            guard candidate.manager == .gem else { return false }
            return inThisKeg || prefixes.contains { location.hasPrefix("\($0)/lib/ruby/gems/") }
        case "pyenv":
            return candidate.manager == .pip && location.contains("/.pyenv/versions/")
        case "rbenv":
            return candidate.manager == .gem && location.contains("/.rbenv/versions/")
        case "nodenv":
            return candidate.manager == .npm && location.contains("/.nodenv/versions/")
        case "nvm":
            return candidate.manager == .npm && location.contains("/.nvm/versions/")
        case "volta":
            return candidate.manager == .npm && location.contains("/.volta/")
        case "fnm":
            return candidate.manager == .npm
                && (location.contains("/fnm/node-versions/") || location.contains("/fnm_multishells/"))
        case "asdf":
            return location.contains("/.asdf/installs/")
        case "mise":
            return location.contains("/mise/installs/")
        case "uv":
            return candidate.manager == .uv
                || (candidate.manager == .pip && location.contains("/uv/python/"))
        case "pipx":
            return candidate.manager == .pipx
        default:
            return false
        }
    }
}
