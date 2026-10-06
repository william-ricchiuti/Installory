import InstalloryCore
import SwiftUI

struct ManagerBadge: View {
    let manager: PackageManager

    var body: some View {
        Text(manager.badgeLabel)
            .font(.system(.caption2, design: .default, weight: .medium))
            // Never wrap ("np / m") or truncate; row titles yield space first.
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(manager.badgeColor.opacity(0.15), in: Capsule())
            // System primary text maintains readable contrast in both
            // appearances; the manager color remains a redundant accent.
            .foregroundStyle(.primary)
            .overlay {
                Capsule().stroke(manager.badgeColor.opacity(0.45), lineWidth: 0.5)
            }
            .accessibilityLabel(manager.displayName)
            .accessibilityAddTraits(.isStaticText)
            .help(manager.displayName)
    }
}

#Preview {
    HStack(spacing: 8) {
        ManagerBadge(manager: .brew)
        ManagerBadge(manager: .brewCask)
        ManagerBadge(manager: .pip)
        ManagerBadge(manager: .npm)
    }
    .padding()
}
