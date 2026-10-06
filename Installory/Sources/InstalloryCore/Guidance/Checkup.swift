import Foundation

/// One of the four areas the Home "Checkup" reports on.
public enum CheckupArea: String, Sendable, Equatable, Hashable, CaseIterable {
    case installedTools
    case aiTools
    case secrets
    case space
}

public enum CheckupStatus: String, Sendable, Equatable, Hashable {
    /// Nothing needs doing.
    case good
    /// Worth a look.
    case attention
    /// Not checked (yet) — the detail says what to grant or enable.
    case unknown
}

/// A plain-English status row for the Home screen.
public struct CheckupRow: Sendable, Equatable, Hashable, Identifiable {
    public let area: CheckupArea
    public let status: CheckupStatus
    /// Short summary, e.g. "122 tools, 3 duplicates".
    public let headline: String
    /// One sentence a beginner understands.
    public let detail: String
    /// Optional call to action, e.g. "Review duplicates".
    public let actionTitle: String?

    public var id: CheckupArea { area }

    public init(area: CheckupArea, status: CheckupStatus, headline: String, detail: String, actionTitle: String?) {
        self.area = area
        self.status = status
        self.headline = headline
        self.detail = detail
        self.actionTitle = actionTitle
    }
}

/// Counts of agent / MCP-server findings by severity.
public struct CheckupFindingCounts: Sendable, Equatable, Hashable {
    public let high: Int
    public let medium: Int
    public let low: Int

    public init(high: Int = 0, medium: Int = 0, low: Int = 0) {
        self.high = high
        self.medium = medium
        self.low = low
    }

    public var total: Int { high + medium + low }
}

/// Something Installory could not look at, which limits what the Checkup can say.
public enum CheckupCoverageGap: Sendable, Equatable, Hashable {
    /// The home folder has not been granted, so per-user tools and agent config are invisible.
    case homeFolderNotGranted
    /// AI agent configuration (skills, MCP servers) is not being checked.
    case agentConfigCheckDisabled
    /// The plain-text secrets check is turned off.
    case secretsCheckDisabled
    /// Anything else; `description` is a short noun phrase shown to the user.
    case other(String)
}

/// Plain values the Home screen already has; `Checkup.make(from:)` turns them into rows.
public struct CheckupInput: Sendable, Equatable {
    public var packageCount: Int
    public var duplicateGroupCount: Int
    /// Duplicate groups with `DuplicateSeverity.active` (a real PATH clash).
    public var highSeverityDuplicateCount: Int
    public var reviewCandidateCount: Int
    public var aiInstalledThisWeekCount: Int
    /// nil = agent / MCP config not scanned.
    public var agentFindings: CheckupFindingCounts?
    /// Secrets written in plain text in AI tool settings (MCP env, headers,
    /// arguments, agent settings `env`). nil = not checked. Project `.env`
    /// files are not part of this count.
    public var exposedSecretCount: Int?
    public var reclaimableBytes: Int64
    public var safeToRemoveCount: Int
    public var coverageGaps: [CheckupCoverageGap]

    public init(
        packageCount: Int,
        duplicateGroupCount: Int = 0,
        highSeverityDuplicateCount: Int = 0,
        reviewCandidateCount: Int = 0,
        aiInstalledThisWeekCount: Int = 0,
        agentFindings: CheckupFindingCounts? = nil,
        exposedSecretCount: Int? = nil,
        reclaimableBytes: Int64 = 0,
        safeToRemoveCount: Int = 0,
        coverageGaps: [CheckupCoverageGap] = []
    ) {
        self.packageCount = packageCount
        self.duplicateGroupCount = duplicateGroupCount
        self.highSeverityDuplicateCount = highSeverityDuplicateCount
        self.reviewCandidateCount = reviewCandidateCount
        self.aiInstalledThisWeekCount = aiInstalledThisWeekCount
        self.agentFindings = agentFindings
        self.exposedSecretCount = exposedSecretCount
        self.reclaimableBytes = reclaimableBytes
        self.safeToRemoveCount = safeToRemoveCount
        self.coverageGaps = coverageGaps
    }
}

/// Builds the four Home "Checkup" rows. Pure and deterministic (apart from
/// `ByteCountFormatter`'s locale formatting of sizes).
public enum Checkup {
    /// Space at or above this is flagged `.attention`; below it is `.good`.
    public static let spaceAttentionThresholdBytes: Int64 = 1_000_000_000

    /// Rows in fixed order: installed tools, AI tools, secrets, space.
    public static func make(from input: CheckupInput) -> [CheckupRow] {
        [
            installedToolsRow(input),
            aiToolsRow(input),
            secretsRow(input),
            spaceRow(input),
        ]
    }

    /// Size formatting used by the Checkup copy.
    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Rows

    static func installedToolsRow(_ input: CheckupInput) -> CheckupRow {
        let homeMissing = input.coverageGaps.contains(.homeFolderNotGranted)

        if input.packageCount == 0 {
            return CheckupRow(
                area: .installedTools,
                status: .unknown,
                headline: "No tools found yet",
                detail: homeMissing
                    ? "Grant access to your home folder in Settings so Installory can see the tools you've installed."
                    : "Run a scan to see the developer tools installed on this Mac.",
                actionTitle: homeMissing ? "Grant access" : "Scan now"
            )
        }

        var headline = count(input.packageCount, "tool")
        if input.duplicateGroupCount > 0 {
            headline += ", " + count(input.duplicateGroupCount, "duplicate")
        }

        if input.highSeverityDuplicateCount > 0 {
            let clashing = input.highSeverityDuplicateCount
            return CheckupRow(
                area: .installedTools,
                status: .attention,
                headline: headline,
                detail: clashing == 1
                    ? "One tool is installed twice and the copies clash, so a command might run a different version than you expect."
                    : "\(clashing) tools are installed more than once and the copies clash, so some commands might run a different version than you expect.",
                actionTitle: "Review duplicates"
            )
        }

        if input.duplicateGroupCount > 0 {
            return CheckupRow(
                area: .installedTools,
                status: .good,
                headline: headline,
                detail: "Some tools are installed more than once, but none of the copies are clashing right now.",
                actionTitle: "Review duplicates"
            )
        }

        if homeMissing {
            return CheckupRow(
                area: .installedTools,
                status: .good,
                headline: headline,
                detail: "No clashes found, but tools in your home folder aren't counted until you grant access in Settings.",
                actionTitle: "Grant access"
            )
        }

        return CheckupRow(
            area: .installedTools,
            status: .good,
            headline: headline,
            detail: input.reviewCandidateCount > 0
                ? "Nothing is clashing, and \(count(input.reviewCandidateCount, "tool")) that nothing else needs can be reviewed when you have time."
                : "Each tool is installed once, so nothing is fighting over which version runs.",
            actionTitle: input.reviewCandidateCount > 0 ? "See review list" : nil
        )
    }

    static func aiToolsRow(_ input: CheckupInput) -> CheckupRow {
        guard let findings = input.agentFindings else {
            if input.coverageGaps.contains(.homeFolderNotGranted) {
                return CheckupRow(
                    area: .aiTools,
                    status: .unknown,
                    headline: "Not checked yet",
                    detail: "Grant access to your home folder in Settings so Installory can check your AI agent setup and MCP servers.",
                    actionTitle: "Grant access"
                )
            }
            if input.coverageGaps.contains(.agentConfigCheckDisabled) {
                return CheckupRow(
                    area: .aiTools,
                    status: .unknown,
                    headline: "Not checked yet",
                    detail: "Turn on the AI tools check in Settings to look for broken skills and misconfigured MCP servers.",
                    actionTitle: "Open Settings"
                )
            }
            // Nothing is blocking the check; it simply hasn't run yet (the AI
            // setup check runs as part of a scan once the home folder is granted).
            let aiWeek = input.aiInstalledThisWeekCount
            if aiWeek > 0 {
                return CheckupRow(
                    area: .aiTools,
                    status: .unknown,
                    headline: "\(count(aiWeek, "tool")) added by AI this week",
                    detail: "Your AI agent settings haven't been checked yet, but you can glance at what your agents installed this week.",
                    actionTitle: "See this week's installs"
                )
            }
            return CheckupRow(
                area: .aiTools,
                status: .unknown,
                headline: "Not checked yet",
                detail: "Run a scan to check your AI agent settings and MCP servers.",
                actionTitle: "Scan now"
            )
        }

        let serious = findings.high + findings.medium
        if serious > 0 {
            return CheckupRow(
                area: .aiTools,
                status: .attention,
                headline: count(serious, "problem") + " found",
                detail: findings.high > 0
                    ? "Some of your AI agent settings have problems that can stop tools from working or expose more than you intended."
                    : "Some of your AI agent settings could be tidied up so your tools behave predictably.",
                actionTitle: "Review AI tools"
            )
        }

        let aiWeek = input.aiInstalledThisWeekCount
        if aiWeek > 0 {
            return CheckupRow(
                area: .aiTools,
                status: .good,
                headline: "\(count(aiWeek, "tool")) added by AI this week",
                detail: "Your AI agent setup looks healthy; glance at this week's installs to make sure you meant to add them.",
                actionTitle: "See this week's installs"
            )
        }

        return CheckupRow(
            area: .aiTools,
            status: .good,
            headline: findings.low > 0 ? count(findings.low, "minor note") : "No problems found",
            detail: findings.low > 0
                ? "Your AI agent setup looks healthy, with a few small notes you can ignore for now."
                : "Your AI agent setup and MCP servers look healthy.",
            actionTitle: findings.low > 0 ? "See notes" : nil
        )
    }

    static func secretsRow(_ input: CheckupInput) -> CheckupRow {
        guard let exposed = input.exposedSecretCount else {
            let detail: String
            let action: String
            if input.coverageGaps.contains(.homeFolderNotGranted) {
                detail = "Grant access to your home folder in Settings so Installory can look for API keys saved in plain text."
                action = "Grant access"
            } else if input.coverageGaps.contains(.secretsCheckDisabled) {
                detail = "Turn on the secrets check in Settings to look for API keys saved in plain text."
                action = "Open Settings"
            } else {
                // Not blocked, just not run yet: the check runs with a scan.
                return CheckupRow(
                    area: .secrets,
                    status: .unknown,
                    headline: "Not checked yet",
                    detail: "Run a scan to look for API keys written in plain text in your AI tools' settings.",
                    actionTitle: "Scan now"
                )
            }
            return CheckupRow(area: .secrets, status: .unknown, headline: "Not checked yet", detail: detail, actionTitle: action)
        }

        if exposed > 0 {
            return CheckupRow(
                area: .secrets,
                status: .attention,
                headline: count(exposed, "key") + " in AI tool settings",
                detail: "Some API keys are written in plain text in your AI tools' settings, where other programs could read them; replace them with new keys and store them somewhere safer.",
                actionTitle: "Review keys"
            )
        }

        return CheckupRow(
            area: .secrets,
            status: .good,
            headline: "No keys in AI tool settings",
            detail: "None of your AI tools' settings files have an API key written in plain text. (Installory doesn't check project .env files.)",
            actionTitle: nil
        )
    }

    static func spaceRow(_ input: CheckupInput) -> CheckupRow {
        if input.packageCount == 0 {
            return CheckupRow(
                area: .space,
                status: .unknown,
                headline: "Not measured yet",
                detail: "Run a scan to see how much space your developer tools use.",
                actionTitle: nil
            )
        }

        if input.safeToRemoveCount == 0 {
            return CheckupRow(
                area: .space,
                status: .good,
                headline: "Nothing to free up",
                detail: "None of your tools are both unused by others and safe to remove right now.",
                actionTitle: nil
            )
        }

        if input.reclaimableBytes <= 0 {
            return CheckupRow(
                area: .space,
                status: .unknown,
                headline: "\(count(input.safeToRemoveCount, "tool")) safe to remove",
                detail: "Their sizes haven't been measured yet, so Installory can't say how much space you'd get back.",
                actionTitle: "Review"
            )
        }

        let size = formatBytes(input.reclaimableBytes)
        let isLarge = input.reclaimableBytes >= spaceAttentionThresholdBytes
        return CheckupRow(
            area: .space,
            status: isLarge ? .attention : .good,
            headline: "\(size) can be freed",
            detail: "Removing \(count(input.safeToRemoveCount, "tool")) that nothing else needs would give back about \(size).",
            actionTitle: "Free up space"
        )
    }

    // MARK: - Helpers

    static func count(_ n: Int, _ singular: String) -> String {
        "\(n) \(n == 1 ? singular : singular + "s")"
    }
}
