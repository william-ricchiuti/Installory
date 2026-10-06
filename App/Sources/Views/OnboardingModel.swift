import Foundation
import InstalloryCore

/// The five onboarding steps, in order.
enum OnboardingPage: Int, CaseIterable, Sendable {
    case welcome
    case promise
    case access
    case history
    case done

    static var count: Int { allCases.count }

    /// 1-based position used for the page indicator and VoiceOver.
    var number: Int { rawValue + 1 }

    /// Accessibility value for the page indicator, e.g. "Page 3 of 5".
    var indicatorValue: String { "Page \(number) of \(Self.count)" }

    var next: OnboardingPage? { OnboardingPage(rawValue: rawValue + 1) }
    var previous: OnboardingPage? { OnboardingPage(rawValue: rawValue - 1) }

    /// Where Esc goes: back one page, or nowhere on the first page. Esc never
    /// skips the guide; only the visible Skip button completes it.
    var escapeDestination: OnboardingPage? { previous }
}

/// What the Access page should offer, derived from the current grants and
/// which Homebrew prefix exists on this Mac. Pure so it can be unit tested.
struct OnboardingAccessPlan: Equatable, Sendable {
    /// The user's home folder path (from `UserHome.directory`).
    let homePath: String
    /// True when an existing grant covers the home folder.
    let homeGranted: Bool
    /// The Homebrew prefix to grant, when one exists on this Mac.
    /// `/opt/homebrew` on Apple Silicon; `/usr/local` when an Intel-style
    /// `/usr/local/Homebrew` checkout exists (the scanners read `/usr/local`).
    let homebrewPath: String?
    /// True when an existing grant already covers `homebrewPath`.
    let homebrewGranted: Bool

    /// Show "Also allow Homebrew" only when Homebrew exists and isn't covered.
    var showsHomebrewButton: Bool { homebrewPath != nil && !homebrewGranted }

    /// Show a granted checkmark row for Homebrew when it exists and is covered.
    var showsHomebrewGrantedRow: Bool { homebrewPath != nil && homebrewGranted }

    /// The primary button on the Access page asks for the home folder until it
    /// is granted, then simply continues.
    var primaryAction: OnboardingAccessPrimaryAction {
        homeGranted ? .continue : .allowHome
    }

    static func make(
        homePath: String,
        grantedPaths: [String],
        directoryExists: (String) -> Bool
    ) -> OnboardingAccessPlan {
        let homeGranted = GrantedPathResolver.deepestCoveringPath(
            for: homePath,
            among: grantedPaths
        ) != nil

        let homebrewPath = homebrewPrefix(directoryExists: directoryExists)
        let homebrewGranted = homebrewPath.map {
            GrantedPathResolver.deepestCoveringPath(for: $0, among: grantedPaths) != nil
        } ?? false

        return OnboardingAccessPlan(
            homePath: homePath,
            homeGranted: homeGranted,
            homebrewPath: homebrewPath,
            homebrewGranted: homebrewGranted
        )
    }

    /// The Homebrew prefix present on this Mac, if any. Never suggests a
    /// missing folder, so the open panel can't land in a protected system path.
    static func homebrewPrefix(directoryExists: (String) -> Bool) -> String? {
        if directoryExists("/opt/homebrew") { return "/opt/homebrew" }
        if directoryExists("/usr/local/Homebrew") { return "/usr/local" }
        return nil
    }

    /// Live filesystem check used by the view.
    static func liveDirectoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

enum OnboardingAccessPrimaryAction: Equatable, Sendable {
    case allowHome
    case `continue`

    var title: String {
        switch self {
        case .allowHome: "Allow Home Folder"
        case .continue: "Continue"
        }
    }
}

/// State of the optional install-history toggle on the History page.
enum OnboardingHistoryToggleState: Equatable, Sendable {
    /// Home isn't granted yet, so the toggle is disabled with an explanation.
    case needsHomeAccess
    case available(isOn: Bool)

    static func make(homeGranted: Bool, provenanceEnabled: Bool) -> OnboardingHistoryToggleState {
        homeGranted ? .available(isOn: provenanceEnabled) : .needsHomeAccess
    }

    var isEnabled: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Copy and decisions for the final page. Pure for testing.
enum OnboardingFinish {
    /// Short line under the Done title summarizing what the first scan covers.
    static func summary(homeGranted: Bool, homebrewGranted: Bool, anyGrant: Bool, historyOn: Bool) -> String {
        guard anyGrant else {
            return "You haven\u{2019}t allowed any folders yet, so the first scan will find very little. You can allow folders any time in Settings."
        }
        var parts: [String] = []
        if homeGranted {
            parts.append("your packages and AI tools")
        } else {
            parts.append("the folders you allowed")
        }
        if homebrewGranted { parts.append("Homebrew") }
        var line = "Installory will look at " + listJoined(parts) + "."
        if historyOn {
            line += " Install history is on, so it will also match tools to the command or AI session that installed them."
        }
        return line
    }

    /// The first scan should run unless a scan already finished during
    /// onboarding and nothing since then needs a rescan (install history was
    /// turned on after that scan started, so it needs a fresh one).
    static func shouldScan(lastScanCompleted: Bool, historyOn: Bool) -> Bool {
        !lastScanCompleted || historyOn
    }

    private static func listJoined(_ parts: [String]) -> String {
        switch parts.count {
        case 0: ""
        case 1: parts[0]
        case 2: parts[0] + " and " + parts[1]
        default: parts.dropLast().joined(separator: ", ") + ", and " + parts.last!
        }
    }
}

/// Copy for the Access page's "Reads / Never reads" lists.
enum OnboardingReadsCopy {
    static let reads = [
        "Package folders (Homebrew, ~/.nvm, ~/.cargo, Python)",
        "AI tool settings (~/.claude, ~/.codex, ~/.cursor)",
        "Editor extensions",
    ]
    static let readsTitle = "Reads"
    /// The home-folder grant is technically broad, so this is a promise about
    /// what Installory's code opens, not a claim about what macOS allows.
    static let neverReadsTitle = "Doesn\u{2019}t open"
    static let neverReadsLead = "Installory only opens the folders listed under Reads. It doesn\u{2019}t open:"
    static let neverReads = [
        "Documents",
        "Photos",
        "Mail",
        "Browser data",
        "Passwords and keychain",
    ]
}
