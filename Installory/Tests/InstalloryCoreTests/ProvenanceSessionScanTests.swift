import Testing
import Foundation
import GRDB
@testable import InstalloryCore

/// Budgets, newest-first traversal, line prefilter and the per-file cache for
/// the Codex and Claude Code session-log collectors.
@Suite("Provenance session scan")
struct ProvenanceSessionScanTests {
    private let home = URL(fileURLWithPath: "/fake-home")
    private let t0 = Date(timeIntervalSince1970: 1_772_000_000)

    // MARK: - Fixtures

    private func codexURL(day: String, name: String) -> URL {
        // day = "2026/03/01"
        URL(fileURLWithPath: "/fake-home/.codex/sessions/\(day)/rollout-\(name).jsonl")
    }

    private func codexSession(id: String, command: String, at date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = f.string(from: date)
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\\\\\"")
        return """
            {"timestamp":"\(ts)","type":"session_meta","payload":{"id":"\(id)","cwd":"/Users/will/projects/\(id)"}}
            {"timestamp":"\(ts)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}
            {"timestamp":"\(ts)","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"\(escaped)\\"}"}}
            """
    }

    private func claudeSession(id: String, command: String, at date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = f.string(from: date)
        return """
            {"sessionId":"\(id)","timestamp":"\(ts)","cwd":"/Users/will/projects/\(id)","message":{"role":"user","content":[{"type":"text","text":"please set up \(id)"}]}}
            {"sessionId":"\(id)","timestamp":"\(ts)","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"\(command)"}}]}}
            """
    }

    private func makePackage(
        _ name: String,
        manager: PackageManager = .brew,
        qualifier: String? = nil,
        installedAt: Date?
    ) -> Package {
        Package(
            id: "\(manager.rawValue):\(qualifier ?? ""):\(name)",
            manager: manager,
            qualifier: qualifier,
            name: name,
            version: "1.0.0",
            installPath: nil,
            installedAt: installedAt,
            installedAtConfidence: installedAt != nil ? .high : .unknown,
            sizeBytes: nil,
            isExplicit: true,
            isReadOnly: false,
            dependencies: [],
            lastSeen: t0
        )
    }

    private func dataReads(_ trace: DirectoryAccessTrace, suffix: String = ".jsonl") -> [URL] {
        trace.entries
            .filter { $0.operation == .data && $0.url.path.hasSuffix(suffix) }
            .map(\.url)
    }

    /// Three Codex sessions on three days, oldest to newest.
    private func threeCodexDays() -> (InMemoryDirectoryAccessProvider, [URL]) {
        let urls = [
            codexURL(day: "2025/12/30", name: "old"),
            codexURL(day: "2026/01/15", name: "mid"),
            codexURL(day: "2026/03/01", name: "new"),
        ]
        let names = ["wget", "jq", "ripgrep"]
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            for (index, url) in urls.enumerated() {
                builder.addFile(
                    at: url,
                    data: Data(codexSession(
                        id: "s\(index)",
                        command: "brew install \(names[index])",
                        at: t0.addingTimeInterval(Double(index) * 86_400)
                    ).utf8),
                    modificationDate: t0.addingTimeInterval(Double(index) * 86_400)
                )
            }
        }
        return (provider, urls)
    }

    // MARK: - Newest first

    @Test("Codex walks years, months, days and files newest first")
    func codexNewestFirst() {
        let (base, urls) = threeCodexDays()
        let trace = DirectoryAccessTrace()
        let provider = TracingDirectoryAccessProvider(base: base, trace: trace)
        let records = CodexLogCollector(directoryAccess: provider, homeDirectory: home).collect()

        #expect(records.map(\.packageName) == ["ripgrep", "jq", "wget"])
        #expect(dataReads(trace) == urls.reversed())
    }

    @Test("Claude Code visits sessions by modification date, newest first, across projects")
    func claudeNewestFirst() {
        let projectA = home.appendingPathComponent(".claude/projects/-a")
        let projectB = home.appendingPathComponent(".claude/projects/-b")
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            builder.addFile(
                at: projectA.appendingPathComponent("old.jsonl"),
                data: Data(claudeSession(id: "old", command: "brew install wget", at: t0).utf8),
                modificationDate: t0
            )
            builder.addFile(
                at: projectA.appendingPathComponent("newest.jsonl"),
                data: Data(claudeSession(id: "newest", command: "brew install ripgrep", at: t0).utf8),
                modificationDate: t0.addingTimeInterval(300)
            )
            builder.addFile(
                at: projectB.appendingPathComponent("middle.jsonl"),
                data: Data(claudeSession(id: "middle", command: "brew install jq", at: t0).utf8),
                modificationDate: t0.addingTimeInterval(100)
            )
        }
        let records = ClaudeCodeLogCollector(directoryAccess: provider, homeDirectory: home).collect()
        #expect(records.map(\.packageName) == ["ripgrep", "jq", "wget"])
    }

    // MARK: - Budgets

    @Test("Byte budget stops reading new files and keeps the newest results")
    func byteBudgetStops() {
        let (base, urls) = threeCodexDays()
        let trace = DirectoryAccessTrace()
        let provider = TracingDirectoryAccessProvider(base: base, trace: trace)
        let (records, report) = CodexLogCollector(
            directoryAccess: provider,
            homeDirectory: home,
            limits: ProvenanceCollectionLimits(maximumSessionBytesPerScan: 1)
        ).collectWithReport()

        #expect(records.map(\.packageName) == ["ripgrep"])
        #expect(dataReads(trace) == [urls[2]])
        #expect(report.stopReason == .byteBudget)
        #expect(report.filesParsed == 1)
        #expect(report.filesSkippedForBudget == 2)
    }

    @Test("Wall-clock budget stops the collector using an injected clock")
    func timeBudgetStops() {
        let (base, urls) = threeCodexDays()
        let trace = DirectoryAccessTrace()
        let provider = TracingDirectoryAccessProvider(base: base, trace: trace)
        // Each clock read advances 10 s. Start = 0; checks before file 1 (10 s)
        // and file 2 (20 s) pass a 25 s budget; the check before file 3 (30 s) fails.
        let clock = SteppingClock(start: t0, step: 10)
        let (records, report) = CodexLogCollector(
            directoryAccess: provider,
            homeDirectory: home,
            limits: ProvenanceCollectionLimits(maximumDuration: 25, now: { clock.next() })
        ).collectWithReport()

        #expect(records.map(\.packageName) == ["ripgrep", "jq"])
        #expect(dataReads(trace) == [urls[2], urls[1]])
        #expect(report.stopReason == .timeBudget)
    }

    @Test("Claude Code honours the byte budget too")
    func claudeByteBudget() {
        let project = home.appendingPathComponent(".claude/projects/-a")
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            for (index, name) in ["wget", "jq", "ripgrep"].enumerated() {
                builder.addFile(
                    at: project.appendingPathComponent("s\(index).jsonl"),
                    data: Data(claudeSession(id: "s\(index)", command: "brew install \(name)", at: t0).utf8),
                    modificationDate: t0.addingTimeInterval(Double(index))
                )
            }
        }
        let (records, report) = ClaudeCodeLogCollector(
            directoryAccess: provider,
            homeDirectory: home,
            limits: ProvenanceCollectionLimits(maximumSessionBytesPerScan: 1)
        ).collectWithReport()
        #expect(records.map(\.packageName) == ["ripgrep"])
        #expect(report.stopReason == .byteBudget)
    }

    // MARK: - Prefilter

    @Test("Prefilter needs the tool-call marker and a package-manager token")
    func prefilterSkipsIrrelevantLines() {
        func codex(_ line: String) -> Bool {
            Array(line.utf8).withUnsafeBytes {
                ProvenanceLinePrefilter.codexToolCall.mayContainInstall($0)
            }
        }
        func claude(_ line: String) -> Bool {
            Array(line.utf8).withUnsafeBytes {
                ProvenanceLinePrefilter.claudeToolCall.mayContainInstall($0)
            }
        }
        #expect(codex(#"{"payload":{"name":"exec_command","arguments":"{\"cmd\":\"brew install wget\"}"}}"#))
        #expect(codex(#"{"payload":{"name":"exec_command","arguments":"{\"cmd\":\"python3 -m pip install x\"}"}}"#))
        #expect(!codex(#"{"payload":{"name":"exec_command","arguments":"{\"cmd\":\"ls -la\"}"}}"#))
        #expect(!codex(#"{"payload":{"type":"message","text":"brew install wget"}}"#))
        #expect(claude(#"{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm i -g x"}}]}}"#))
        #expect(!claude(#"{"message":{"content":[{"type":"tool_use","name":"Read","input":{"path":"/tmp"}}]}}"#))
        #expect(!claude(#"{"message":{"content":[{"type":"text","text":"run brew install wget in Bash"}]}}"#))
    }

    @Test("Lines without install tokens are skipped but session_meta and cwd still apply")
    func prefilterKeepsContext() {
        let project = home.appendingPathComponent(".claude/projects/-tmp")
        let jsonl = [
            #"{"sessionId":"c1","timestamp":"2026-03-01T10:00:00.000Z","cwd":"/work/first","message":{"role":"user","content":"start"}}"#,
            #"{"sessionId":"c1","timestamp":"2026-03-01T10:01:00.000Z","cwd":"/work/second","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#,
            #"{"sessionId":"c1","timestamp":"2026-03-01T10:02:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"brew install wget"}}]}}"#,
        ].joined(separator: "\n")
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            builder.addFile(at: project.appendingPathComponent("c1.jsonl"), data: Data(jsonl.utf8))
        }
        let records = ClaudeCodeLogCollector(directoryAccess: provider, homeDirectory: home).collect()
        #expect(records.count == 1)
        #expect(records.first?.context.projectPath == "/work/second")
        #expect(records.first?.context.firstUserMessage == "start")

        let (codexBase, _) = threeCodexDays()
        let codex = CodexLogCollector(directoryAccess: codexBase, homeDirectory: home).collect()
        #expect(codex.first?.context.sessionId == "s2")
        #expect(codex.first?.context.projectPath == "/Users/will/projects/s2")
    }

    // MARK: - Cache

    @Test("Cache hit skips reading unchanged session files and returns the same records")
    func cacheHitSkipsParsing() {
        let (base, _) = threeCodexDays()
        let cache = InMemoryProvenanceFileCacheStore()

        let firstTrace = DirectoryAccessTrace()
        let (first, firstReport) = CodexLogCollector(
            directoryAccess: TracingDirectoryAccessProvider(base: base, trace: firstTrace),
            homeDirectory: home,
            cache: cache
        ).collectWithReport()
        #expect(dataReads(firstTrace).count == 3)
        #expect(firstReport.filesParsed == 3)

        let secondTrace = DirectoryAccessTrace()
        let (second, secondReport) = CodexLogCollector(
            directoryAccess: TracingDirectoryAccessProvider(base: base, trace: secondTrace),
            homeDirectory: home,
            cache: cache
        ).collectWithReport()
        #expect(dataReads(secondTrace).isEmpty)
        #expect(secondReport.cacheHits == 3)
        #expect(secondReport.filesParsed == 0)
        #expect(second == first)
    }

    @Test("Claude Code cache hit skips reading the session and its summary index")
    func claudeCacheHit() {
        let project = home.appendingPathComponent(".claude/projects/-a")
        let base = InMemoryDirectoryAccessProvider.make { builder in
            builder.addFile(
                at: project.appendingPathComponent("s1.jsonl"),
                data: Data(claudeSession(id: "s1", command: "brew install wget", at: t0).utf8),
                modificationDate: t0
            )
            builder.addFile(
                at: project.appendingPathComponent("sessions-index.json"),
                data: Data(#"{"sessions":[{"id":"s1","summary":"Set up wget"}]}"#.utf8),
                modificationDate: t0
            )
        }
        let cache = InMemoryProvenanceFileCacheStore()
        let first = ClaudeCodeLogCollector(directoryAccess: base, homeDirectory: home, cache: cache).collect()
        #expect(first.first?.context.sessionSummary == "Set up wget")

        let trace = DirectoryAccessTrace()
        let second = ClaudeCodeLogCollector(
            directoryAccess: TracingDirectoryAccessProvider(base: base, trace: trace),
            homeDirectory: home,
            cache: cache
        ).collect()
        #expect(!trace.entries.contains { $0.operation == .data })
        #expect(second == first)
    }

    @Test("A changed file is re-parsed; a deleted file's cache entry is evicted")
    func cacheInvalidationAndEviction() throws {
        let cache = InMemoryProvenanceFileCacheStore()
        let keep = codexURL(day: "2026/03/01", name: "keep")
        let gone = codexURL(day: "2026/03/02", name: "gone")
        let before = InMemoryDirectoryAccessProvider.make { builder in
            builder.addFile(at: keep, data: Data(codexSession(id: "k", command: "brew install wget", at: t0).utf8), modificationDate: t0)
            builder.addFile(at: gone, data: Data(codexSession(id: "g", command: "brew install jq", at: t0).utf8), modificationDate: t0)
        }
        _ = CodexLogCollector(directoryAccess: before, homeDirectory: home, cache: cache).collect()
        #expect(Set(try cache.entries(for: .codex).keys) == [keep.path, gone.path])

        // `keep` grows (new mtime); `gone` is deleted.
        let after = InMemoryDirectoryAccessProvider.make { builder in
            builder.addFile(
                at: keep,
                data: Data((codexSession(id: "k", command: "brew install wget", at: t0) + "\n"
                    + codexSession(id: "k", command: "brew install ripgrep", at: t0)).utf8),
                modificationDate: t0.addingTimeInterval(60)
            )
        }
        let trace = DirectoryAccessTrace()
        let records = CodexLogCollector(
            directoryAccess: TracingDirectoryAccessProvider(base: after, trace: trace),
            homeDirectory: home,
            cache: cache
        ).collect()
        #expect(dataReads(trace) == [keep])
        #expect(Set(records.map(\.packageName)) == ["wget", "ripgrep"])
        let entries = try cache.entries(for: .codex)
        #expect(Set(entries.keys) == [keep.path])
        #expect(entries[keep.path]?.modifiedAt == t0.addingTimeInterval(60).timeIntervalSince1970)
    }

    @Test("Entries for unvisited files survive a budget stop while the file exists")
    func budgetStopKeepsUnvisitedEntries() throws {
        let (base, urls) = threeCodexDays()
        let cache = InMemoryProvenanceFileCacheStore()
        _ = CodexLogCollector(directoryAccess: base, homeDirectory: home, cache: cache).collect()
        let clock = SteppingClock(start: t0, step: 10)
        _ = CodexLogCollector(
            directoryAccess: base,
            homeDirectory: home,
            limits: ProvenanceCollectionLimits(maximumDuration: 15, now: { clock.next() }),
            cache: cache
        ).collect()
        #expect(Set(try cache.entries(for: .codex).keys) == Set(urls.map(\.path)))
    }

    @Test("Cached payloads hold redacted records only, never raw secrets or home paths")
    func cachePayloadIsRedacted() throws {
        let cache = InMemoryProvenanceFileCacheStore()
        let url = codexURL(day: "2026/03/01", name: "secret")
        let command = "npm install -g typescript --registry https://deploy:supersecretvalue123@registry.example.com"
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            builder.addFile(at: url, data: Data(codexSession(id: "x", command: command, at: t0).utf8), modificationDate: t0)
        }
        let records = CodexLogCollector(directoryAccess: provider, homeDirectory: home, cache: cache).collect()
        #expect(records.map(\.packageName) == ["typescript"])
        let payload = try #require(try cache.entries(for: .codex)[url.path]?.payload)
        let text = String(decoding: payload, as: UTF8.self)
        #expect(!text.contains("supersecret"))
        #expect(!text.contains("/Users/will"))
        #expect(text.contains("REDACTED"))
        // Returned records match what the cache holds.
        #expect(!records[0].context.bashInvocation.contains("supersecret"))
    }

    @Test("Evidence is identical with and without the cache, including interpreter scope")
    func evidenceUnchangedByCache() throws {
        let venv = "/Users/will/.venv/bin/python3"
        let url = codexURL(day: "2026/03/01", name: "scope")
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            builder.addFile(
                at: url,
                data: Data(codexSession(id: "scope", command: "\(venv) -m pip install httpx", at: t0).utf8),
                modificationDate: t0
            )
        }
        let packages = [
            makePackage("httpx", manager: .pip, qualifier: venv, installedAt: t0),
            makePackage("httpx", manager: .pip, qualifier: "/opt/other/bin/python3", installedAt: t0),
        ]
        func evidence(cache: (any ProvenanceFileCacheStore)?) -> [String: ProvenanceEvidence] {
            let list = ProvenanceCollector(
                shellCollector: ShellHistoryCollector(
                    directoryAccess: InMemoryDirectoryAccessProvider.make { _ in },
                    homeDirectory: home
                ),
                claudeCodeCollector: ClaudeCodeLogCollector(
                    directoryAccess: InMemoryDirectoryAccessProvider.make { _ in },
                    homeDirectory: home
                ),
                codexCollector: CodexLogCollector(directoryAccess: provider, homeDirectory: home, cache: cache),
                opencodeCollector: OpenCodeLogCollector(databasePath: home.appendingPathComponent("none.db"))
            ).collect(packages: packages)
            return Dictionary(uniqueKeysWithValues: list.map { ($0.packageId, $0) })
        }

        let cache = InMemoryProvenanceFileCacheStore()
        let uncached = evidence(cache: nil)
        let freshWithCache = evidence(cache: cache)
        let fromCache = evidence(cache: cache)

        for package in packages {
            let expected = uncached[package.id]?.codexContext
            #expect(freshWithCache[package.id]?.codexContext == expected)
            #expect(fromCache[package.id]?.codexContext == expected)
            #expect(fromCache[package.id]?.overallConfidence == uncached[package.id]?.overallConfidence)
        }
        // Scope survives redaction: only the matching interpreter gets context.
        #expect(fromCache[packages[0].id]?.codexContext != nil)
        #expect(fromCache[packages[1].id]?.codexContext == nil)
    }

    // MARK: - Persistence

    @Test("Database cache round-trips entries and Clear History (deleteAll) erases them")
    func clearHistoryClearsCache() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenanceSessionScanTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try InstalloryCore.Database(directory: dir)
        let store = ProvenanceFileCacheDAO(database: database)

        let (base, _) = threeCodexDays()
        let first = CodexLogCollector(directoryAccess: base, homeDirectory: home, cache: store).collect()
        #expect(try store.entries(for: .codex).count == 3)
        #expect(try store.entries(for: .claudeCode).isEmpty)

        let trace = DirectoryAccessTrace()
        let second = CodexLogCollector(
            directoryAccess: TracingDirectoryAccessProvider(base: base, trace: trace),
            homeDirectory: home,
            cache: store
        ).collect()
        #expect(second == first)
        #expect(dataReads(trace).isEmpty)

        try await ProvenanceDAO(database: database).deleteAll()
        #expect(try store.entries(for: .codex).isEmpty)
    }
}

/// Deterministic clock: every read advances by `step` seconds.
private final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private let step: TimeInterval

    init(start: Date, step: TimeInterval) {
        self.current = start
        self.step = step
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let value = current
        current = current.addingTimeInterval(step)
        return value
    }
}
