import InstalloryCore
import Testing
@testable import Installory

@Suite("Onboarding flow")
struct OnboardingViewTests {
    private let home = "/Users/alex"

    private func plan(granted: [String], existing: Set<String>) -> OnboardingAccessPlan {
        OnboardingAccessPlan.make(
            homePath: home,
            grantedPaths: granted,
            directoryExists: { existing.contains($0) }
        )
    }

    // MARK: Pages

    @Test("There are five pages in order, ending at Done")
    func pageOrder() {
        #expect(OnboardingPage.allCases == [.welcome, .promise, .access, .history, .done])
        #expect(OnboardingPage.welcome.previous == nil)
        #expect(OnboardingPage.done.next == nil)
        #expect(OnboardingPage.access.next == .history)
        #expect(OnboardingPage.history.previous == .access)
    }

    @Test("Page indicator reads 'Page n of 5'")
    func indicatorValue() {
        #expect(OnboardingPage.welcome.indicatorValue == "Page 1 of 5")
        #expect(OnboardingPage.access.indicatorValue == "Page 3 of 5")
        #expect(OnboardingPage.done.indicatorValue == "Page 5 of 5")
    }

    // MARK: Access plan

    @Test("No grants and no Homebrew: ask for home, hide Homebrew button")
    func noGrantsNoBrew() {
        let p = plan(granted: [], existing: [])
        #expect(!p.homeGranted)
        #expect(p.homebrewPath == nil)
        #expect(!p.showsHomebrewButton)
        #expect(!p.showsHomebrewGrantedRow)
        #expect(p.primaryAction == .allowHome)
        #expect(p.primaryAction.title == "Allow Home Folder")
    }

    @Test("Apple Silicon Homebrew not granted: offer 'Also allow Homebrew'")
    func brewOffered() {
        let p = plan(granted: [], existing: ["/opt/homebrew"])
        #expect(p.homebrewPath == "/opt/homebrew")
        #expect(p.showsHomebrewButton)
        #expect(!p.showsHomebrewGrantedRow)
    }

    @Test("Intel Homebrew checkout maps to the /usr/local prefix")
    func intelBrew() {
        let p = plan(granted: [], existing: ["/usr/local/Homebrew"])
        #expect(p.homebrewPath == "/usr/local")
        #expect(p.showsHomebrewButton)
    }

    @Test("/usr/local without a Homebrew checkout is not offered")
    func usrLocalWithoutBrew() {
        #expect(OnboardingAccessPlan.homebrewPrefix(directoryExists: { $0 == "/usr/local" }) == nil)
    }

    @Test("Granted Homebrew shows a checkmark row instead of the button")
    func brewGranted() {
        let p = plan(granted: ["/opt/homebrew"], existing: ["/opt/homebrew"])
        #expect(p.homebrewGranted)
        #expect(!p.showsHomebrewButton)
        #expect(p.showsHomebrewGrantedRow)
        #expect(!p.homeGranted)
    }

    @Test("Home grant flips the primary action to Continue")
    func homeGranted() {
        let p = plan(granted: [home], existing: ["/opt/homebrew"])
        #expect(p.homeGranted)
        #expect(p.primaryAction == .continue)
        // Home does not cover /opt/homebrew.
        #expect(p.showsHomebrewButton)
    }

    @Test("A broader ancestor grant covers home; a sibling or child does not")
    func coverageRules() {
        #expect(plan(granted: ["/Users"], existing: []).homeGranted)
        #expect(!plan(granted: ["/Users/alex2"], existing: []).homeGranted)
        #expect(!plan(granted: ["/Users/alex/.claude"], existing: []).homeGranted)
    }

    @Test("Reads list names AI tool folders; never-reads covers private data")
    func readsCopy() {
        let reads = OnboardingReadsCopy.reads.joined(separator: " ")
        for folder in ["~/.claude", "~/.codex", "~/.cursor", "Homebrew"] {
            #expect(reads.contains(folder))
        }
        let never = OnboardingReadsCopy.neverReads.joined(separator: " ").lowercased()
        for item in ["documents", "photos", "mail", "browser", "keychain"] {
            #expect(never.contains(item))
        }
        // The home grant is broad, so the copy promises what Installory's code
        // opens rather than claiming it "never reads" anything.
        #expect(OnboardingReadsCopy.neverReadsLead == "Installory only opens the folders listed under Reads. It doesn\u{2019}t open:")
        #expect(OnboardingReadsCopy.neverReadsLead.contains(OnboardingReadsCopy.readsTitle))
        #expect(OnboardingReadsCopy.neverReadsTitle == "Doesn\u{2019}t open")
        #expect(!OnboardingReadsCopy.neverReadsTitle.lowercased().contains("never"))
    }

    // MARK: Install history

    @Test("History toggle is disabled until home is granted")
    func historyToggle() {
        let locked = OnboardingHistoryToggleState.make(homeGranted: false, provenanceEnabled: true)
        #expect(locked == .needsHomeAccess)
        #expect(!locked.isEnabled)

        let open = OnboardingHistoryToggleState.make(homeGranted: true, provenanceEnabled: false)
        #expect(open == .available(isOn: false))
        #expect(open.isEnabled)
    }

    // MARK: Done

    @Test("First scan runs unless one already finished and history is off")
    func shouldScan() {
        #expect(OnboardingFinish.shouldScan(lastScanCompleted: false, historyOn: false))
        #expect(OnboardingFinish.shouldScan(lastScanCompleted: false, historyOn: true))
        #expect(OnboardingFinish.shouldScan(lastScanCompleted: true, historyOn: true))
        #expect(!OnboardingFinish.shouldScan(lastScanCompleted: true, historyOn: false))
    }

    @Test("Done summary reflects grants and history")
    func doneSummary() {
        let none = OnboardingFinish.summary(homeGranted: false, homebrewGranted: false, anyGrant: false, historyOn: false)
        #expect(none.contains("Settings"))

        let full = OnboardingFinish.summary(homeGranted: true, homebrewGranted: true, anyGrant: true, historyOn: true)
        #expect(full.contains("AI tools"))
        #expect(full.contains("Homebrew"))
        #expect(full.contains("Install history is on"))

        let custom = OnboardingFinish.summary(homeGranted: false, homebrewGranted: false, anyGrant: true, historyOn: false)
        #expect(custom.contains("folders you allowed"))
        #expect(!custom.contains("Install history"))
    }
}
