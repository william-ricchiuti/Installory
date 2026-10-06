import Foundation
import InstalloryCore
import Testing
@testable import Installory

@Suite("Canonical directories")
struct CanonicalDirectoryTests {
    @Test("APP25-011: Apple Silicon offers both native and Rosetta Homebrew roots")
    func appleSiliconIncludesBothHomebrewRoots() {
        let paths = CanonicalDirectory.all(isAppleSilicon: true).map(\.path)

        #expect(paths.contains("/opt/homebrew"))
        #expect(paths.contains("/usr/local"))
    }

    @Test("Intel offers the Intel Homebrew root once")
    func intelIncludesUsrLocalOnce() {
        let paths = CanonicalDirectory.all(isAppleSilicon: false).map(\.path)

        #expect(paths.filter { $0 == "/usr/local" }.count == 1)
        #expect(!paths.contains("/opt/homebrew"))
    }

    @Test("UV-F1: canonical uv grant unlocks persistent tools and managed Python")
    func uvGrantCoversToolsAndManagedPython() throws {
        let home = UserHome.directory.path
        let directory = try #require(
            CanonicalDirectory.all(isAppleSilicon: true).first {
                $0.path == "\(home)/.local/share/uv"
            }
        )

        #expect(directory.managers == [.uv, .pip])
        #expect(GrantedDirectory(path: directory.path, bookmark: Data()).managersUnlocked == "uv tools, pip")
    }

    @Test("UV-F1: uv manager has concise accessible display metadata")
    func uvDisplayMetadata() {
        #expect(PackageManager.uv.displayName == "uv tools")
        #expect(PackageManager.uv.badgeLabel == "uv")
        #expect(PackageManager.uv.sidebarSymbol == "terminal")
    }
}
