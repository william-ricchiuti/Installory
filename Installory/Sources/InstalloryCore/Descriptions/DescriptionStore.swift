import Foundation

/// Read-only lookup store for the bundled package descriptions corpus.
///
/// Load once at startup by passing the URL of `descriptions.json` from the
/// app bundle. The app (not the library) supplies the URL so the library
/// stays testable without referencing `Bundle.main`.
///
/// Lookup normalizes package names before matching — pip names follow PEP 503,
/// npm names are lowercased — so installed names like `requests_oauthlib` or
/// `Requests` find the corpus entry keyed as `pip:requests-oauthlib`.
public struct DescriptionStore: Sendable {

    // MARK: - State

    private let descriptions: [String: String]

    // MARK: - Init

    /// Loads the corpus from a JSON file produced by `scripts/generate-descriptions/generate.py`.
    /// Throws if the file cannot be read or is not valid JSON in the expected format.
    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        let corpus = try JSONDecoder().decode(CorpusFile.self, from: data)
        self.descriptions = corpus.descriptions
    }

    /// Empty store — every lookup returns nil. Used as the default when the corpus
    /// file is absent (e.g. in tests that don't load the full bundle).
    public init() {
        self.descriptions = [:]
    }

    /// Internal init for unit tests — accepts the raw keyed dictionary directly.
    init(raw descriptions: [String: String]) {
        self.descriptions = descriptions
    }

    // MARK: - Lookup

    /// Returns the one-line plain-English description for the given package, or
    /// nil if the corpus has no entry for it.
    ///
    /// pipx and uv tools are PyPI distributions, so when the corpus has no
    /// manager-specific key they resolve through the shared `pip:` key.
    /// Well-known agent CLIs (`claude`, `codex`, `opencode`, `cursor`) resolve
    /// to built-in descriptions when the corpus has no entry.
    public func description(for manager: PackageManager, name: String) -> String? {
        for key in lookupKeys(manager: manager, name: name) {
            if let text = descriptions[key] { return text }
        }
        if manager == .agentCli {
            return Self.knownAgentCliDescriptions[name.lowercased()]
        }
        return nil
    }

    /// Returns the corpus description when available, otherwise a per-manager
    /// plain-English fallback so unknown packages never surface a bare
    /// "no description" state. The fallback describes what the package *is* by
    /// its manager rather than guessing what it does.
    public func descriptionOrFallback(for manager: PackageManager, name: String) -> String {
        description(for: manager, name: name) ?? Self.fallback(for: manager)
    }

    /// Resolves the best description for a concrete package row, or nil.
    ///
    /// Order: the scanner-supplied ``Package/summary`` for agent skills and
    /// editor extensions (their own manifests describe them better than a
    /// name-keyed corpus can), then the corpus / built-in lookup by
    /// `(manager, name)`, then the summary for any other manager.
    public func description(for package: Package) -> String? {
        let summary = package.summary.flatMap { text -> String? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        switch package.manager {
        case .agentSkill, .editorExtension:
            if let summary { return summary }
        default:
            break
        }
        return description(for: package.manager, name: package.name) ?? summary
    }

    /// ``description(for:)-(Package)`` with the per-manager fallback, so a
    /// package row never shows a bare "no description" state. This is the
    /// preferred entry point for display.
    public func descriptionOrFallback(for package: Package) -> String {
        description(for: package) ?? Self.fallback(for: package.manager)
    }

    /// Corpus-independent descriptions for agent CLIs Installory recognizes.
    /// Keyed by the canonical CLI name `AgentCliScanner` assigns.
    static let knownAgentCliDescriptions: [String: String] = [
        "claude": "Anthropic's Claude Code, an AI coding agent that works in your terminal and projects.",
        "codex": "OpenAI's Codex CLI, an AI coding agent that runs in your terminal.",
        "opencode": "opencode, an open-source AI coding agent for the terminal.",
        "cursor": "Cursor, an AI code editor; this folder holds its settings and extensions.",
    ]

    /// A concise, human-friendly one-liner for each manager, used when the
    /// corpus has no entry for a specific package.
    public static func fallback(for manager: PackageManager) -> String {
        switch manager {
        case .brew:
            return "A Homebrew command-line tool."
        case .brewCask:
            return "A Homebrew app installed as a cask."
        case .pip:
            return "A Python package installed with pip."
        case .pipx:
            return "A Python command-line tool installed with pipx."
        case .uv:
            return "A Python tool installed with uv."
        case .npm:
            return "A Node.js package installed with npm."
        case .cargo:
            return "A Rust crate installed with Cargo."
        case .gem:
            return "A Ruby gem."
        case .mas:
            return "An app installed from the Mac App Store."
        case .agentSkill:
            return "An AI agent skill — a folder of instructions and scripts that teaches an agent a new capability."
        case .agentCli:
            return "An AI agent command-line tool, such as Claude Code, Codex, opencode, or Cursor."
        case .editorExtension:
            return "An editor extension for VS Code or Cursor."
        }
    }

    // MARK: - Private

    /// Corpus keys to try, most specific first.
    private func lookupKeys(manager: PackageManager, name: String) -> [String] {
        switch manager {
        case .pip:
            return ["pip:\(pep503(name))"]
        case .pipx:
            // The corpus is keyed by PyPI distribution under `pip:`; a pipx-specific
            // key, if one is ever added, still wins.
            return ["pipx:\(pep503(name))", "pip:\(pep503(name))"]
        case .uv:
            return ["pip:\(pep503(name))"]
        case .npm:
            return ["npm:\(name.lowercased())"]
        default:
            // brew, brewCask, cargo, gem, mas: exact names from registry
            return ["\(manager.rawValue):\(name)"]
        }
    }

    /// PEP 503 normalization: lowercase then collapse runs of [-_.] to a single hyphen.
    private func pep503(_ name: String) -> String {
        var result = ""
        var inSeparator = false
        for ch in name.lowercased() {
            if ch == "-" || ch == "_" || ch == "." {
                if !inSeparator {
                    result.append("-")
                    inSeparator = true
                }
            } else {
                result.append(ch)
                inSeparator = false
            }
        }
        return result
    }

    // MARK: - Private types

    private struct CorpusFile: Decodable {
        let descriptions: [String: String]
    }
}
