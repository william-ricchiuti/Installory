import Foundation
import Testing
@testable import InstalloryCore

/// Review findings SC-7 and PF-1. Onboarding promises Installory doesn't open
/// Documents, Photos or Mail. With a home-folder grant the project scanner
/// used to list those folders, and when home itself looked like a project it
/// sized the whole home tree. Each project also got its own sizing budget, so
/// big projects made the scan slow.
@Suite("Home-folder skip-list and project sizing")
struct HomeSkipListTests {
    private let home = URL(fileURLWithPath: "/Users/demo", isDirectory: true)

    private let personalFolders = [
        "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Library", "Public", ".Trash",
    ]

    /// A home folder with personal folders full of private data and project
    /// markers, a normal project, and project markers at home itself.
    private func fakeHome() -> InMemoryDirectoryAccessProvider {
        InMemoryDirectoryAccessProvider.make { b in
            let h = home.path
            b.addFile(at: URL(fileURLWithPath: "\(h)/package.json"), data: Data("{}".utf8))
            b.addFile(at: URL(fileURLWithPath: "\(h)/.git/HEAD"), data: Data())
            b.addFile(at: URL(fileURLWithPath: "\(h)/myproject/package.json"), data: Data("{}".utf8))
            b.addFile(at: URL(fileURLWithPath: "\(h)/myproject/.venv/bin/python3"), data: Data())
            b.addDirectory(at: URL(fileURLWithPath: "\(h)/myproject/.venv/lib/python3.12/site-packages"))
            b.addFile(at: URL(fileURLWithPath: "\(h)/Documents/taxes.pdf"), data: Data("private".utf8))
            b.addFile(at: URL(fileURLWithPath: "\(h)/Documents/thesis/package.json"), data: Data("{}".utf8))
            b.addFile(at: URL(fileURLWithPath: "\(h)/Documents/thesis/.venv/bin/python3"), data: Data())
            b.addDirectory(at: URL(fileURLWithPath: "\(h)/Documents/thesis/.venv/lib/python3.12/site-packages"))
            b.addFile(at: URL(fileURLWithPath: "\(h)/Desktop/site/.git/HEAD"), data: Data())
            b.addFile(at: URL(fileURLWithPath: "\(h)/Downloads/repo/Cargo.toml"), data: Data())
            b.addFile(at: URL(fileURLWithPath: "\(h)/Pictures/Photos Library.photoslibrary/database/Photos.sqlite"), data: Data())
            b.addFile(at: URL(fileURLWithPath: "\(h)/Library/Mail/V10/INBOX.mbox/1.emlx"), data: Data("mail".utf8))
            b.addFile(at: URL(fileURLWithPath: "\(h)/Movies/clip.mov"), data: Data())
            b.addFile(at: URL(fileURLWithPath: "\(h)/Music/song.m4a"), data: Data())
            b.addFile(at: URL(fileURLWithPath: "\(h)/Public/Drop Box/x"), data: Data())
            b.addFile(at: URL(fileURLWithPath: "\(h)/.Trash/old/package.json"), data: Data("{}".utf8))
            b.addFile(at: URL(fileURLWithPath: "\(h)/Old Photos.photoslibrary/database/Photos.sqlite"), data: Data())
        }
    }

    private func touchedPersonalPaths(_ trace: DirectoryAccessTrace) -> [String] {
        let skipped = personalFolders.map { home.appendingPathComponent($0).path }
            + [home.appendingPathComponent("Old Photos.photoslibrary").path]
        return trace.entries.map(\.url.standardizedFileURL.path).filter { path in
            skipped.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }

    @Test("a home grant never touches personal folders and home isn't a project")
    func homeGrantSkipsPersonalFolders() async throws {
        let trace = DirectoryAccessTrace()
        let access = TracingDirectoryAccessProvider(base: fakeHome(), trace: trace)
        let scanner = ProjectWorkspaceScanner(roots: [home], directoryAccess: access, homeDirectory: home)
        let workspaces = try await scanner.scan()

        #expect(workspaces.map(\.name) == ["myproject"], "workspaces: \(workspaces.map(\.path.path))")
        #expect(!workspaces.contains { $0.path.standardizedFileURL.path == home.path })
        #expect(touchedPersonalPaths(trace).isEmpty, "touched: \(touchedPersonalPaths(trace))")
    }

    @Test("a folder granted on purpose is still scanned, even a personal one")
    func directGrantStillScanned() async throws {
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let scanner = ProjectWorkspaceScanner(roots: [documents], directoryAccess: fakeHome(), homeDirectory: home)
        let names = try await scanner.scan().map(\.name)
        #expect(names.contains("thesis"))
    }

    @Test("a Homebrew prefix is never a project")
    func homebrewPrefixIsNotAProject() async throws {
        let access = InMemoryDirectoryAccessProvider.make { b in
            b.addFile(at: URL(fileURLWithPath: "/opt/homebrew/.git/HEAD"), data: Data())
            b.addFile(at: URL(fileURLWithPath: "/opt/homebrew/Library/Taps/x/.git/HEAD"), data: Data())
            b.addFile(at: URL(fileURLWithPath: "/opt/homebrew/bin/jq"), data: Data())
        }
        let scanner = ProjectWorkspaceScanner(
            roots: [URL(fileURLWithPath: "/opt/homebrew", isDirectory: true)],
            directoryAccess: access,
            homeDirectory: home
        )
        #expect(try await scanner.scan().isEmpty)
    }

    @Test("Python venv discovery skips personal folders under a home grant")
    func venvDiscoverySkipsPersonalFolders() {
        let trace = DirectoryAccessTrace()
        let access = TracingDirectoryAccessProvider(base: fakeHome(), trace: trace)
        let discovery = PythonInterpreterDiscovery(
            directoryAccess: access,
            homeDirectory: home,
            environment: .empty,
            projectVenvRoots: [home]
        )
        let executables = discovery.discover().map(\.executable.path)
        #expect(executables.contains("/Users/demo/myproject/.venv/bin/python3"))
        #expect(!executables.contains { $0.hasPrefix("/Users/demo/Documents/") })
        #expect(touchedPersonalPaths(trace).isEmpty, "touched: \(touchedPersonalPaths(trace))")
    }

    @Test("projects share one sizing budget instead of one each")
    func sizingBudgetIsShared() async throws {
        let root = URL(fileURLWithPath: "/granted/projects", isDirectory: true)
        let access = InMemoryDirectoryAccessProvider.make { b in
            for project in 1...5 {
                b.addFile(at: root.appendingPathComponent("p\(project)/package.json"), data: Data("{}".utf8))
                for file in 1...19 {
                    b.addFile(at: root.appendingPathComponent("p\(project)/src/f\(file).js"), data: Data("x".utf8))
                }
            }
        }
        // Each project has 22 entries to visit; the whole scan may visit 50.
        let limits = DirectorySizeLimits(
            maxEntriesPerMeasurement: 1_000,
            maxBytesPerMeasurement: 1_000_000,
            maxDurationPerMeasurement: .seconds(5),
            maxEntriesPerScan: 50,
            maxBytesPerScan: 1_000_000,
            maxDurationPerScan: .seconds(5)
        )
        let scanner = ProjectWorkspaceScanner(
            roots: [root],
            directoryAccess: access,
            limits: .default,
            directorySizeLimits: limits,
            homeDirectory: home
        )
        let workspaces = try await scanner.scan()
        #expect(workspaces.count == 5)
        let sized = workspaces.filter { $0.sizeBytes != nil }.count
        #expect(sized == 2, "sized \(sized) of 5; a fresh budget per project would size all 5")
    }

    @Test("the default project sizing budget is small")
    func defaultProjectBudget() {
        #expect(ProjectWorkspaceScanner.defaultSizeLimits.maxDurationPerScan <= .milliseconds(1_500))
        #expect(ProjectWorkspaceScanner.defaultSizeLimits.maxDurationPerMeasurement <= .milliseconds(500))
    }
}
