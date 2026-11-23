import Foundation
import Testing
@testable import InstalloryCore

@Suite("CORE-10 foundation helper consolidation")
struct FoundationConsolidationTests {
    @Test("directory fallback preserves provider order and does not filter entries")
    func directoryFallbackPreservesOrderAndEntries() {
        let root = URL(fileURLWithPath: "/inventory")
        let directory = root.appendingPathComponent("z-directory")
        let file = root.appendingPathComponent("a-file")
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            builder.addDirectory(at: directory)
            builder.addFile(at: file, data: Data())
        }

        let contents = provider.directoryContentsOrEmpty(at: root)

        #expect(contents == [directory, file])
    }

    @Test("directory fallback converts missing and unreadable locations to empty contents")
    func directoryFallbackConvertsAccessFailuresToEmptyContents() {
        let unreadable = URL(fileURLWithPath: "/inventory")
        let missing = URL(fileURLWithPath: "/missing")
        let provider = InMemoryDirectoryAccessProvider.make { builder in
            builder.addDirectory(at: unreadable)
            builder.makeUnreadable(at: unreadable)
        }

        #expect(provider.directoryContentsOrEmpty(at: unreadable).isEmpty)
        #expect(provider.directoryContentsOrEmpty(at: missing).isEmpty)
    }

    @Test("Requires-Dist name parsing drops constraints, markers and extras")
    func requirementNameParsingPreservesScannerSemantics() {
        #expect(
            PythonRequirement.distributionName(
                from: " requests (>=2.0) ; python_version > '3' "
            ) == "requests"
        )
        #expect(
            PythonRequirement.distributionName(
                from: "typing-extensions; python_version < '3.11'"
            ) == "typing-extensions"
        )
        // Extras name optional features of the same distribution; the
        // dependency is still on `httpx`, so it must match the installed row.
        #expect(PythonRequirement.distributionName(from: "httpx[http2] >= 0.27") == "httpx")
        #expect(PythonRequirement.distributionName(from: "   ").isEmpty)
    }
}
