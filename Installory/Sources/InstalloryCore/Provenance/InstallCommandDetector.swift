import Foundation

/// Parses a command line and identifies package-install operations within it.
///
/// Each detected install yields a `(name, manager)` tuple. A command can yield
/// multiple tuples when it installs several packages or contains multiple shell
/// invocations joined by a control operator.
public struct InstallCommandDetector: Sendable {
    public init() {}

    /// Returns every `(packageName, manager)` pair encoded in `command`.
    ///
    /// This is deliberately a conservative recognizer, not a complete shell parser.
    /// It never expands variables or substitutions. Quoted literals are supported;
    /// escaping and grouping are rejected instead of guessed at.
    public func detect(_ command: String) -> [(name: String, manager: PackageManager)] {
        detectInstallations(command).map { ($0.name, $0.manager) }
    }

    /// Returns detections with scope information when the invocation itself
    /// identifies a Python interpreter. Kept internal so the public detector API
    /// remains source-compatible while provenance can avoid cross-scope matches.
    func detectInstallations(_ command: String) -> [DetectedInstall] {
        guard let invocations = tokenizeCommandChain(command) else { return [] }
        return invocations.flatMap(detectInvocation)
    }

    private func detectInvocation(
        _ tokens: [String]
    ) -> [DetectedInstall] {
        guard !tokens.isEmpty else { return [] }

        let manager: PackageManager
        let argStartIndex: Int
        var qualifierHint: InstallQualifierHint? = nil

        switch tokens[0] {
        case "brew":
            guard tokens.count >= 2 else { return [] }
            switch tokens[1] {
            case "install":
                if tokens.count >= 3, tokens[2] == "--cask" {
                    manager = .brewCask
                    argStartIndex = 3
                } else {
                    manager = .brew
                    argStartIndex = 2
                }
            case "reinstall":
                manager = .brew
                argStartIndex = 2
            case "cask":
                guard tokens.count >= 3, tokens[2] == "install" else { return [] }
                manager = .brewCask
                argStartIndex = 3
            default:
                return []
            }
        case "pip", "pip3":
            guard tokens.count >= 2, tokens[1] == "install" else { return [] }
            manager = .pip
            argStartIndex = 2
        case let executable where isPythonExecutable(executable):
            guard tokens.count >= 4,
                  tokens[1] == "-m",
                  tokens[2] == "pip",
                  tokens[3] == "install" else { return [] }
            manager = .pip
            argStartIndex = 4
            qualifierHint = pythonQualifierHint(for: executable)
        case "uv":
            guard tokens.count >= 3 else { return [] }
            if tokens[1] == "pip", tokens[2] == "install" {
                manager = .pip
                argStartIndex = 3
            } else if tokens[1] == "tool", tokens[2] == "install" {
                manager = .uv
                argStartIndex = 3
            } else {
                return []
            }
        case "pipx":
            guard tokens.count >= 2, tokens[1] == "install" else { return [] }
            manager = .pipx
            argStartIndex = 2
        case "npm":
            guard tokens.count >= 3,
                  tokens[1] == "install" || tokens[1] == "i",
                  hasNpmGlobalOption(in: Array(tokens.dropFirst(2))) else { return [] }
            manager = .npm
            argStartIndex = 2
        case "yarn":
            guard tokens.count >= 3,
                  tokens[1] == "global",
                  tokens[2] == "add" else { return [] }
            manager = .npm
            argStartIndex = 3
        case "cargo":
            guard tokens.count >= 2, tokens[1] == "install" else { return [] }
            manager = .cargo
            argStartIndex = 2
        case "gem":
            guard tokens.count >= 2, tokens[1] == "install" else { return [] }
            manager = .gem
            argStartIndex = 2
        case "mas":
            guard tokens.count >= 2, tokens[1] == "install" else { return [] }
            manager = .mas
            argStartIndex = 2
        default:
            return []
        }

        return extractPackages(
            from: Array(tokens.dropFirst(argStartIndex)),
            manager: manager,
            qualifierHint: qualifierHint
        )
    }

    // MARK: - Invocation helpers

    private func isPythonExecutable(_ token: String) -> Bool {
        let executable = token
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? token
        guard executable.hasPrefix("python") else { return false }

        let suffix = executable.dropFirst("python".count)
        guard !suffix.isEmpty else { return true }
        guard suffix.first.map(isASCIIDigit) == true,
              suffix.last.map(isASCIIDigit) == true else { return false }
        return suffix.allSatisfy { isASCIIDigit($0) || $0 == "." }
            && !suffix.contains("..")
    }

    /// Absolute paths identify one exact interpreter. A versioned executable
    /// name identifies only that basename; it may legitimately match multiple
    /// installations whose paths end in the same name. Plain `python` carries no
    /// scope signal and therefore remains unqualified evidence.
    private func pythonQualifierHint(for token: String) -> InstallQualifierHint? {
        if token.hasPrefix("/") {
            return .exactPath(token)
        }

        let executable = token
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? token
        return executable == "python" ? nil : .executableName(executable)
    }

    private func hasNpmGlobalOption(in args: [String]) -> Bool {
        for token in args {
            if token == "--" { return false }
            if token == "-g" || token == "--global" { return true }
        }
        return false
    }

    // MARK: - Package extraction

    private func extractPackages(
        from args: [String],
        manager: PackageManager,
        qualifierHint: InstallQualifierHint?
    ) -> [DetectedInstall] {
        var results: [DetectedInstall] = []
        var skipNext = false

        for token in args {
            if skipNext {
                skipNext = false
                continue
            }
            if token.hasPrefix("-") {
                if !token.contains("="), optionConsumesValue(token, manager: manager) {
                    skipNext = true
                }
                continue
            }
            if token.hasSuffix("requirements.txt") { continue }
            if token == "." || token == ".." { continue }
            if token.contains("/"), !isSupportedQualifiedName(token, manager: manager) {
                continue
            }
            if token.hasSuffix(".whl") { continue }

            let name = cleaned(token, manager: manager)
            guard !name.isEmpty,
                  !name.contains(where: { $0.isWhitespace || unsafePackageCharacters.contains($0) }) else {
                continue
            }
            results.append(DetectedInstall(
                name: name,
                manager: manager,
                qualifierHint: qualifierHint
            ))
            // A persistent uv tool environment has exactly one primary target.
            // Receipt options may name additional dependencies, but those are
            // not independently-managed tool rows.
            if manager == .uv { break }
        }

        return results
    }

    /// Options used by supported install commands whose value occupies the next
    /// token. Keeping this explicit prevents values from becoming fake packages.
    private func optionConsumesValue(_ option: String, manager: PackageManager) -> Bool {
        switch manager {
        case .brew, .brewCask:
            return false
        case .pip:
            return [
                "-c", "-e", "-r", "-t", "--constraint", "--editable",
                "--extra-index-url", "--index-url", "--python-version",
                "--requirement", "--target",
            ].contains(option)
        case .pipx:
            return ["--index-url", "--pip-args", "--python", "--suffix"].contains(option)
        case .uv:
            return [
                "-c", "-e", "-w", "--build-constraint", "--config-file", "--constraint",
                "--default-index", "--editable", "--extra-index-url", "--find-links",
                "--index", "--index-url", "--keyring-provider", "--override", "--python",
                "--python-preference", "--resolution", "--with", "--with-editable",
                "--with-executables-from", "--with-requirements",
            ].contains(option)
        case .npm:
            return ["-w", "--prefix", "--registry", "--tag", "--workspace"].contains(option)
        case .cargo:
            return [
                "--branch", "--git", "--path", "--registry", "--rev", "--root",
                "--tag", "--version",
            ].contains(option)
        case .gem:
            return [
                "-i", "-n", "-v", "--bindir", "--install-dir", "--platform",
                "--source", "--version",
            ].contains(option)
        case .mas:
            return false
        case .agentSkill, .agentCli, .editorExtension:
            return false
        }
    }

    /// Strips Python extras and version specifiers from a package token.
    private func cleaned(_ token: String, manager: PackageManager) -> String {
        var name = token
        if manager == .brew || manager == .brewCask, name.contains("/") {
            name = name.split(separator: "/").last.map(String.init) ?? name
        }
        if manager == .npm {
            let versionSearchStart: String.Index
            if name.hasPrefix("@"), let slash = name.firstIndex(of: "/") {
                versionSearchStart = name.index(after: slash)
            } else {
                versionSearchStart = name.startIndex
            }
            if let versionSeparator = name[versionSearchStart...].firstIndex(of: "@") {
                name = String(name[..<versionSeparator])
            }
        } else if manager == .uv, let versionSeparator = name.firstIndex(of: "@") {
            name = String(name[..<versionSeparator])
        }
        if let idx = name.firstIndex(of: "[") {
            name = String(name[..<idx])
        }
        if let idx = name.firstIndex(where: { "=!><~".contains($0) }) {
            name = String(name[..<idx])
        }
        return name
    }

    /// The only slash-bearing package targets this detector accepts are
    /// manager-defined names, never filesystem paths.
    private func isSupportedQualifiedName(
        _ token: String,
        manager: PackageManager
    ) -> Bool {
        let components = token.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return false
        }
        switch manager {
        case .brew, .brewCask:
            return components.count == 3 && !token.hasPrefix("/")
        case .npm:
            return components.count == 2 && token.hasPrefix("@")
        default:
            return false
        }
    }

    // MARK: - Minimal shell tokenization

    /// Tokenizes quoted literal arguments and splits control operators only when
    /// they appear outside quotes. Expansion, escaping, and grouping are rejected.
    private func tokenizeCommandChain(_ command: String) -> [[String]]? {
        let characters = Array(command)
        var invocations: [[String]] = []
        var invocation: [String] = []
        var token = ""
        var tokenStarted = false
        var quote: Character?
        var index = 0

        func finishToken() {
            guard tokenStarted else { return }
            if !token.isEmpty { invocation.append(token) }
            token = ""
            tokenStarted = false
        }

        func finishInvocation() {
            finishToken()
            if !invocation.isEmpty { invocations.append(invocation) }
            invocation.removeAll(keepingCapacity: true)
        }

        while index < characters.count {
            let character = characters[index]

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    // Single quotes are fully literal. Double quotes still perform
                    // expansion/escaping in a real shell, so reject those constructs.
                    if activeQuote == "\"", character == "$" || character == "`" || character == "\\" {
                        return nil
                    }
                    token.append(character)
                }
                tokenStarted = true
                index += 1
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                tokenStarted = true
                index += 1
                continue
            }
            if character == "$" || character == "`" || character == "\\"
                || character == "(" || character == ")" {
                return nil
            }
            if character == "#", !tokenStarted {
                while index < characters.count, characters[index] != "\n" {
                    index += 1
                }
                continue
            }
            if character == ";" || character == "\n" {
                finishInvocation()
                index += 1
                continue
            }
            if character == "|" {
                finishInvocation()
                index += (index + 1 < characters.count && characters[index + 1] == "|") ? 2 : 1
                continue
            }
            if character == "&",
               index + 1 < characters.count,
               characters[index + 1] == "&" {
                finishInvocation()
                index += 2
                continue
            }
            if character.isWhitespace {
                finishToken()
                index += 1
                continue
            }

            token.append(character)
            tokenStarted = true
            index += 1
        }

        guard quote == nil else { return nil }
        finishInvocation()
        return invocations
    }
}

struct DetectedInstall: Sendable, Equatable {
    let name: String
    let manager: PackageManager
    let qualifierHint: InstallQualifierHint?
}

enum InstallQualifierHint: Sendable, Hashable, Codable {
    /// The command names an absolute interpreter path.
    case exactPath(String)
    /// The command names a versioned interpreter executable without an absolute path.
    case executableName(String)
}

private let unsafePackageCharacters = "$`(){};|&*?\\\"'"

private func isASCIIDigit(_ character: Character) -> Bool {
    character.asciiValue.map { (48...57).contains($0) } == true
}
