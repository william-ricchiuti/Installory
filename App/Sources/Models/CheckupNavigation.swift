import InstalloryCore

/// What the app does for a Home checkup row's button.
enum CheckupCommand: Equatable {
    case navigate(SidebarSelection)
    case grantHomeAccess
    case openSettings
    case scan
}

extension CheckupAction {
    /// Routes the typed Core action; exhaustive, so a new case must be mapped.
    var command: CheckupCommand {
        switch self {
        case .grantHomeAccess: .grantHomeAccess
        case .openSettings: .openSettings
        case .scan: .scan
        case .reviewDuplicates: .navigate(.duplicates)
        case .seePossiblyUnused: .navigate(.orphans)
        case .seeThisWeeksInstalls: .navigate(.aiInstalled)
        case .reviewAITools, .seeAINotes, .reviewKeys: .navigate(.aiSetup)
        case .reviewSpace, .freeUpSpace: .navigate(.diskUsage)
        }
    }
}

extension CheckupRow {
    /// The command behind the row's button, or nil when it has none.
    var command: CheckupCommand? { action?.command }

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
