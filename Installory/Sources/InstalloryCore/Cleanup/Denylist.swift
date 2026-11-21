import Foundation

/// A single entry in the denylist, matching packages by manager and name pattern.
public struct DenylistEntry: Sendable {
    /// The package manager this entry applies to.
    public let manager: PackageManager
    /// Exact package name or glob pattern. A trailing `*` acts as a prefix wildcard —
    /// e.g., `python@*` matches `python@3.12`, `python@3.13`, etc.
    public let namePattern: String
    /// Human-readable explanation shown in the generated script comment.
    public let reason: String

    public init(manager: PackageManager, namePattern: String, reason: String) {
        self.manager = manager
        self.namePattern = namePattern
        self.reason = reason
    }

    func matches(_ package: Package) -> Bool {
        guard package.manager == manager else { return false }
        if namePattern.hasSuffix("*") {
            return package.name.hasPrefix(String(namePattern.dropLast()))
        }
        return package.name == namePattern
    }
}

/// Identifies packages that, while removable, are so commonly required that Installory
/// renders them as commented-out warnings rather than active uninstall commands.
///
/// Default entries are defined in Core so cleanup behavior is deterministic and
/// does not depend on an app bundle resource.
public struct Denylist: Sendable {
    private let entries: [DenylistEntry]

    /// Built-in denylist covering common essentials across Homebrew, pip, and npm.
    public static let `default` = Denylist(entries: [
        // Homebrew formulae
        .init(manager: .brew, namePattern: "git",             reason: "required by many development tools"),
        .init(manager: .brew, namePattern: "curl",            reason: "required by many tools and scripts"),
        .init(manager: .brew, namePattern: "wget",            reason: "required by many download scripts"),
        .init(manager: .brew, namePattern: "openssl",         reason: "required by many tools and libraries"),
        .init(manager: .brew, namePattern: "openssl@3",       reason: "required by many tools and libraries"),
        .init(manager: .brew, namePattern: "ca-certificates", reason: "required for TLS verification"),
        .init(manager: .brew, namePattern: "gnupg",           reason: "required for package verification"),
        .init(manager: .brew, namePattern: "gpg",             reason: "required for package verification"),
        .init(manager: .brew, namePattern: "python@*",        reason: "removing Python can break many tools"),
        .init(manager: .brew, namePattern: "node",            reason: "many development tools depend on Node"),
        .init(manager: .brew, namePattern: "node@*",          reason: "many development tools depend on Node"),
        .init(manager: .brew, namePattern: "ffmpeg",          reason: "commonly depended on by media tools"),
        .init(manager: .brew, namePattern: "sqlite",          reason: "required by Python and many applications"),
        // pip interpreter-level packages
        .init(manager: .pip, namePattern: "pip",              reason: "removing pip breaks the interpreter"),
        .init(manager: .pip, namePattern: "setuptools",       reason: "required for installing Python packages"),
        .init(manager: .pip, namePattern: "wheel",            reason: "required for building Python packages"),
        // npm globals
        .init(manager: .npm, namePattern: "npm",              reason: "removing npm breaks package management"),
        .init(manager: .npm, namePattern: "corepack",         reason: "required for package manager shims"),
    ])

    public init(entries: [DenylistEntry]) {
        self.entries = entries
    }

    /// Returns `true` if the package matches any entry for its manager.
    public func isDenylisted(_ package: Package) -> Bool {
        entries.contains { $0.matches(package) }
    }

    /// Returns the reason string for the first matching entry, or `nil` if not denylisted.
    public func reason(for package: Package) -> String? {
        entries.first { $0.matches(package) }?.reason
    }
}
