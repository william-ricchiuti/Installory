import Foundation

/// Decides when Installory may ask for an App Store rating.
///
/// Pure: every input is passed in, so the gating is unit-testable. The app asks
/// only after a positive moment — a finished real scan that either found space
/// to free or a clean checkup, with every manager read cleanly — once the app
/// has been used on a few different days, and at most once per app version.
/// Never in demo mode or onboarding, and never after the automatic launch scan
/// (the caller asks only after a scan the user started).
enum ReviewPromptPolicy {
    /// Distinct calendar days the app must have been launched on.
    static let minimumLaunchDays = 3
    /// Launch days kept in UserDefaults; only the count matters.
    static let maxRecordedDays = 10

    struct Context: Equatable {
        var isDemoMode: Bool
        var onboardingCompleted: Bool
        var scanCompleted: Bool
        var distinctLaunchDays: Int
        var reclaimableBytes: Int64
        var checkupAllGood: Bool
        /// No package manager failed or timed out during the scan.
        var noScanProblems: Bool
        var currentVersion: String
        var lastPromptedVersion: String?
    }

    static func shouldRequestReview(_ context: Context) -> Bool {
        guard !context.isDemoMode,
              context.onboardingCompleted,
              context.scanCompleted,
              context.noScanProblems,
              context.distinctLaunchDays >= minimumLaunchDays,
              context.lastPromptedVersion != context.currentVersion else {
            return false
        }
        return context.reclaimableBytes > 0 || context.checkupAllGood
    }

    /// A stable `yyyy-MM-dd` key for the calendar day containing `date`.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Adds `day` to the recorded launch days (deduplicated, most recent kept).
    static func recording(day: String, in days: [String]) -> [String] {
        guard !days.contains(day) else { return days }
        return Array((days + [day]).suffix(maxRecordedDays))
    }
}
