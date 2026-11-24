import AppKit
import InstalloryCore
import SwiftUI
import Testing
@testable import Installory

@Suite("Package table rendering", .serialized)
@MainActor
struct PackageTableRenderingTests {
    @Test("APP-F3: table cells retain the coordinator environment during layout")
    func tableCellsRetainCoordinatorEnvironmentDuringLayout() async throws {
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstalloryTableRenderingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let coordinator = AppCoordinator(dataDirectoryOverride: dataDirectory)
        coordinator.enterDemoMode()
        coordinator.sidebarSelection = .all

        let hostingView = NSHostingView(
            rootView: PackageListView()
                .environment(coordinator)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 700)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // A window made in code releases itself on close by default, and ARC
        // releases it again: that over-release crashed the test host at
        // teardown (after every test had passed).
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hostingView
        window.setContentSize(NSSize(width: 1_000, height: 700))
        await settleLayout(in: window, hostingView: hostingView)

        let selectedPackage = try #require(coordinator.packages.first { $0.name == "ruff" })
        coordinator.selectedPackage = selectedPackage
        await settleLayout(in: window, hostingView: hostingView)
        coordinator.inventoryViewMode = .table
        await settleLayout(in: window, hostingView: hostingView)

        let tableView = hostingView.firstDescendant(ofType: NSTableView.self)
        #expect(tableView?.numberOfRows == coordinator.packages.count)
    }

    private func settleLayout(in window: NSWindow, hostingView: NSView) async {
        for _ in 0..<3 {
            window.layoutIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            await Task.yield()
        }
    }
}

private extension NSView {
    func firstDescendant<ViewType: NSView>(ofType type: ViewType.Type) -> ViewType? {
        if let match = self as? ViewType { return match }
        return subviews.lazy.compactMap { $0.firstDescendant(ofType: type) }.first
    }
}
