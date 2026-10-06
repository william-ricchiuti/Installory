import AppKit
import InstalloryCore
import SwiftUI

extension SidebarSelection {
    /// Destinations whose view attaches a `.searchable` field (⌘F target).
    var hasSearchField: Bool {
        switch self {
        case .all, .manager, .readOnly, .duplicates, .orphans, .aiInstalled, .skills, .snapshot:
            return true
        case .dashboard, .diskUsage, .projects:
            return false
        }
    }
}

/// Moves keyboard focus into the visible search field for ⌘F.
///
/// macOS 15+ uses SwiftUI's `searchFocused`, driven by
/// `AppCoordinator.searchFocusRequest`. macOS 14 has no SwiftUI API for this, so
/// it falls back to AppKit: the toolbar's `NSSearchToolbarItem`, or the first
/// `NSSearchField` in the window.
@MainActor
enum SearchFieldFocuser {
    @discardableResult
    static func focusSearchField(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        if let item = window.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first {
            item.beginSearchInteraction()
            return true
        }
        // The toolbar lives in the theme frame, the content view's superview.
        let root = window.contentView?.superview ?? window.contentView
        if let root, let field = firstSearchField(in: root) {
            return window.makeFirstResponder(field)
        }
        return false
    }

    private static func firstSearchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField, !field.isHiddenOrHasHiddenAncestor {
            return field
        }
        for subview in view.subviews {
            if let field = firstSearchField(in: subview) {
                return field
            }
        }
        return nil
    }
}

/// Attach after `.searchable` so ⌘F can focus that search field.
struct FindCommandFocusModifier: ViewModifier {
    @Environment(AppCoordinator.self) private var coordinator

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.modifier(SearchFocusedModifier(request: coordinator.searchFocusRequest))
        } else {
            content
        }
    }
}

@available(macOS 15.0, *)
private struct SearchFocusedModifier: ViewModifier {
    let request: Int
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .searchFocused($isFocused)
            .onChange(of: request) { _, _ in
                isFocused = true
            }
    }
}

extension View {
    func findCommandFocusable() -> some View {
        modifier(FindCommandFocusModifier())
    }
}
