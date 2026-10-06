import Foundation

/// Finds the instruction files ("rules" / memory files) that AI coding agents
/// load into every conversation, globally and per project.
struct InstructionFileCollector {
    let homeDirectory: URL
    let projectRoots: [URL]
    let limits: AgentConfigAuditor.Limits

    struct Candidate {
        let relativePath: String
        let kind: InstructionFileKind
        let tool: InstructionTool
    }

    static let globalCandidates: [Candidate] = [
        Candidate(relativePath: ".claude/CLAUDE.md", kind: .claudeMd, tool: .claudeCode),
        Candidate(relativePath: ".codex/AGENTS.md", kind: .agentsMd, tool: .codex),
        Candidate(relativePath: ".config/opencode/AGENTS.md", kind: .agentsMd, tool: .opencode),
        Candidate(relativePath: ".gemini/GEMINI.md", kind: .geminiMd, tool: .gemini),
    ]

    static let projectCandidates: [Candidate] = [
        Candidate(relativePath: "CLAUDE.md", kind: .claudeMd, tool: .claudeCode),
        Candidate(relativePath: "CLAUDE.local.md", kind: .claudeLocalMd, tool: .claudeCode),
        Candidate(relativePath: ".claude/CLAUDE.md", kind: .claudeMd, tool: .claudeCode),
        Candidate(relativePath: "AGENTS.md", kind: .agentsMd, tool: .agentsStandard),
        Candidate(relativePath: "GEMINI.md", kind: .geminiMd, tool: .gemini),
        Candidate(relativePath: ".cursorrules", kind: .cursorRulesLegacy, tool: .cursor),
        Candidate(relativePath: ".github/copilot-instructions.md", kind: .copilotInstructions, tool: .githubCopilot),
        Candidate(relativePath: ".windsurfrules", kind: .windsurfRules, tool: .windsurf),
    ]

    func collect(reader: inout AgentConfigFileReader) -> [InstructionFile] {
        var files: [InstructionFile] = []
        for candidate in Self.globalCandidates {
            if let file = inspect(
                homeDirectory.appendingPathComponent(candidate.relativePath),
                kind: candidate.kind, tool: candidate.tool, scope: .user, reader: &reader
            ) {
                files.append(file)
            }
        }
        for project in projectRoots {
            let root = project.standardizedFileURL
            let scope = AgentConfigScope.project(root)
            for candidate in Self.projectCandidates {
                if let file = inspect(
                    root.appendingPathComponent(candidate.relativePath),
                    kind: candidate.kind, tool: candidate.tool, scope: scope, reader: &reader
                ) {
                    files.append(file)
                }
            }
            let rulesDirectory = root.appendingPathComponent(".cursor/rules", isDirectory: true)
            let ruleFiles = reader.access.directoryContentsOrEmpty(at: rulesDirectory)
                .filter { ["mdc", "md"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .prefix(limits.maximumCursorRuleFiles)
            for rule in ruleFiles {
                if let file = inspect(
                    rulesDirectory.appendingPathComponent(rule.lastPathComponent),
                    kind: .cursorRule, tool: .cursor, scope: scope, reader: &reader
                ) {
                    files.append(file)
                }
            }
        }
        return files
    }

    private func inspect(
        _ url: URL,
        kind: InstructionFileKind,
        tool: InstructionTool,
        scope: AgentConfigScope,
        reader: inout AgentConfigFileReader
    ) -> InstructionFile? {
        let access = reader.access
        guard let metadata = try? access.metadata(at: url) else { return nil }
        guard metadata.kind != .directory else { return nil }
        let isSymlink = metadata.kind == .symbolicLink

        if isSymlink, !access.fileExists(at: url) {
            let target = access.resolvingSymlinks(at: url).standardizedFileURL
            return InstructionFile(
                kind: kind, tool: tool, scope: scope, path: url,
                byteSize: nil, lineCount: nil, characterCount: nil,
                isSymlink: true,
                symlinkTarget: target.path == url.standardizedFileURL.path ? nil : target,
                isBrokenSymlink: true,
                imports: []
            )
        }

        let resolved = access.resolvingSymlinks(at: url).standardizedFileURL
        var byteSize = (try? access.metadata(at: resolved))?.logicalSizeBytes
        var lineCount: Int?
        var characterCount: Int?
        var imports: [String] = []
        if let text = reader.readText(url, maximumBytes: limits.maximumInstructionBytes) {
            byteSize = Int64(text.utf8.count)
            characterCount = text.count
            lineCount = Self.lineCount(text)
            if [.claudeMd, .claudeLocalMd, .geminiMd].contains(kind) {
                imports = Self.imports(in: text)
            }
        }
        return InstructionFile(
            kind: kind, tool: tool, scope: scope, path: url,
            byteSize: byteSize,
            lineCount: lineCount,
            characterCount: characterCount,
            isSymlink: isSymlink,
            symlinkTarget: isSymlink ? resolved : nil,
            isBrokenSymlink: false,
            imports: imports
        )
    }

    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 0
        text.enumerateLines { _, _ in count += 1 }
        return count
    }

    /// Extracts `@path` imports (Claude Code / Gemini memory-file syntax).
    ///
    /// Tokens inside fenced code blocks or inline code are ignored, as are
    /// `@mentions` that do not look like a path (no `/`, `.` or `~`).
    static func imports(in text: String, limit: Int = 200) -> [String] {
        var result: [String] = []
        var inFence = false
        text.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                return
            }
            guard !inFence else { return }
            var inCode = false
            var token = ""
            func flush() {
                defer { token = "" }
                guard token.hasPrefix("@"), token.count > 1 else { return }
                var path = String(token.dropFirst())
                // Trailing punctuation (including a sentence's full stop) is not part of the path.
                while let last = path.last, ",;:.)]}>!?\"'".contains(last) { path.removeLast() }
                guard !path.isEmpty, !path.contains("@"),
                      path.contains("/") || path.contains(".") || path.hasPrefix("~") else { return }
                if !result.contains(path) { result.append(path) }
            }
            for character in line {
                if character == "`" {
                    flush()
                    inCode.toggle()
                    continue
                }
                if inCode { continue }
                if character.isWhitespace || character == "(" || character == "[" {
                    flush()
                } else {
                    token.append(character)
                }
            }
            if !inCode { flush() }
            if result.count >= limit { stop = true }
        }
        return result
    }

    /// Resolves an import written in `file` to an absolute URL.
    static func resolveImport(_ path: String, from file: URL, homeDirectory: URL) -> URL {
        if path == "~" { return homeDirectory.standardizedFileURL }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL
        }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return file.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
    }
}
