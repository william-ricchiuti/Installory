import InstalloryCore

/// What a Home checkup row's button does.
enum CheckupAction: Equatable {
    case navigate(SidebarSelection)
    case grantHomeAccess
    case openSettings
    case scan
}

extension CheckupRow {
    /// The action behind `actionTitle`, or nil when the row has no button (or
    /// the destination doesn't exist yet, such as the coming secrets check).
    var action: CheckupAction? {
        guard let actionTitle else { return nil }
        switch actionTitle {
        case "Grant access": return .grantHomeAccess
        case "Open Settings": return .openSettings
        case "Scan now": return .scan
        default: break
        }
        switch area {
        case .installedTools:
            return actionTitle == "See review list" ? .navigate(.orphans) : .navigate(.duplicates)
        case .aiTools:
            return actionTitle == "See this week's installs" ? .navigate(.aiInstalled) : .navigate(.skills)
        case .space:
            return .navigate(.diskUsage)
        case .secrets:
            return nil
        }
    }

    /// VoiceOver wording for the status indicator.
    var statusAccessibilityLabel: String {
        switch status {
        case .good: "Looks good"
        case .attention: "Needs attention"
        case .unknown: "Not checked"
        }
    }

    /// Short section name shown above the headline.
    var areaTitle: String {
        switch area {
        case .installedTools: "Installed tools"
        case .aiTools: "AI tools"
        case .secrets: "API keys"
        case .space: "Disk space"
        }
    }
}
