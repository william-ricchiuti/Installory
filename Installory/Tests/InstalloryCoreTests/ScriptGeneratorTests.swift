import Testing
import Foundation
@testable import InstalloryCore

@Suite("ScriptGenerator")
struct ScriptGeneratorTests {

    // Custom denylist with no entries, so tests control denylist behaviour explicitly.
    private let generator = ScriptGenerator(denylist: Denylist(entries: []))
    // Generator with the real default denylist for denylist-specific tests.
    private let defaultGenerator = ScriptGenerator()

    // MARK: - Helpers

    private func makePackage(
        manager: PackageManager,
        name: String,
        version: String = "1.0.0",
        qualifier: String? = nil,
        isReadOnly: Bool = false,
        dependencies: [String] = [],
        artifactPaths: [String]? = nil
    ) -> Package {
        Package(
            id: manager == .gem
                ? "\(manager.rawValue):\(qualifier ?? ""):\(name):\(version)"
                : "\(manager.rawValue):\(qualifier ?? ""):\(name)",
            manager: manager,
            qualifier: qualifier,
            name: name,
            version: version,
            installPath: nil,
            installedAt: nil,
            installedAtConfidence: .low,
            sizeBytes: nil,
            isExplicit: true,
            isReadOnly: isReadOnly,
            dependencies: dependencies,
            artifactPaths: artifactPaths,
            lastSeen: Date()
        )
    }

    private func lines(of script: String) -> [String] {
        script.components(separatedBy: "\n")
    }

    // MARK: - Empty package list

    @Test func emptyPackageListProducesHeaderOnly() {
        let result = generator.generate(packages: [])
        let script = result.scriptText

        #expect(script.hasPrefix("#!/usr/bin/env bash\n"))
        #expect(script.contains("failed=()"))
        #expect(result.skippedReadOnly.isEmpty)
        #expect(result.warnedDenylisted.isEmpty)

        // No uninstall commands or manager section headers
        #expect(!script.contains("uninstall"))
        #expect(!script.contains("# ==="))
    }

    // MARK: - Brew formula

    @Test func brewFormulaProducesCorrectCommand() {
        let pkg = makePackage(manager: .brew, name: "jq")
        let result = generator.generate(packages: [pkg])
        let script = result.scriptText

        #expect(script.contains(#"echo "→ brew uninstall jq""#))
        #expect(lines(of: script).contains("brew uninstall jq"))
        #expect(script.contains("# === Homebrew Formulae ==="))
    }

    // MARK: - Brew cask

    @Test func brewCaskProducesCommandAndArtifactComments() {
        let pkg = makePackage(
            manager: .brewCask,
            name: "warp",
            artifactPaths: ["/Applications/Warp.app", "~/Library/Application Support/Warp"]
        )
        let result = generator.generate(packages: [pkg])
        let script = result.scriptText

        #expect(script.contains(#"echo "→ brew uninstall --cask warp""#))
        #expect(lines(of: script).contains("brew uninstall --cask warp"))
        #expect(script.contains("# === Homebrew Casks ==="))

        // Artifact path comments appear immediately after the command
        let scriptLines = lines(of: script)
        let cmdIndex = scriptLines.firstIndex(of: "brew uninstall --cask warp")
        if let cmdIndex {
            #expect(scriptLines[cmdIndex + 1] == "# Files brew may not remove automatically:")
            #expect(scriptLines[cmdIndex + 2] == "#   /Applications/Warp.app")
            #expect(scriptLines[cmdIndex + 3] == "#   ~/Library/Application Support/Warp")
        }
    }

    @Test func brewCaskWithNoArtifactPathsHasNoArtifactComment() {
        let pkg = makePackage(manager: .brewCask, name: "alfred")
        let result = generator.generate(packages: [pkg])
        #expect(!result.scriptText.contains("Files brew may not remove"))
    }

    // MARK: - pip

    @Test func pipCommandUsesQualifierAsInterpreter() {
        let interpreter = "/Users/x/.pyenv/versions/3.11.7/bin/python"
        let pkg = makePackage(manager: .pip, name: "requests", qualifier: interpreter)
        let result = generator.generate(packages: [pkg])
        let script = result.scriptText

        let expectedCmd = #"/Users/x/.pyenv/versions/3.11.7/bin/python -m pip uninstall -y requests"#
        #expect(lines(of: script).contains(expectedCmd))

        // Section header includes the interpreter path
        #expect(script.contains("# === pip (interpreter: \(interpreter)) ==="))
    }

    @Test func pipCommandWithSpaceInInterpreterPath() {
        // Spaces in the path must not break the generated command
        let interpreter = "/Users/my user/.pyenv/versions/3.12.0/bin/python"
        let pkg = makePackage(manager: .pip, name: "flask", qualifier: interpreter)
        let result = generator.generate(packages: [pkg])
        let script = result.scriptText

        #expect(script.contains("'\(interpreter)' -m pip uninstall -y flask"))
    }

    // MARK: - npm

    @Test func npmPackageProducesCorrectCommand() {
        let pkg = makePackage(manager: .npm, name: "typescript")
        let result = generator.generate(packages: [pkg])
        let script = result.scriptText

        #expect(lines(of: script).contains("npm uninstall -g typescript"))
        #expect(script.contains("# === npm (global) ==="))
    }

    @Test func scopedNpmPackageRendersCorrectly() {
        let pkg = makePackage(manager: .npm, name: "@types/node")
        let result = generator.generate(packages: [pkg])
        let script = result.scriptText

        #expect(lines(of: script).contains("npm uninstall -g @types/node"))
    }

    // MARK: - Read-only filter

    @Test func readOnlyPackageIsAbsentFromScriptAndReturnedInSkipped() {
        let readOnly = makePackage(manager: .pip, name: "six", qualifier: "/usr/bin/python3", isReadOnly: true)
        let normal   = makePackage(manager: .brew, name: "jq")

        let result = generator.generate(packages: [readOnly, normal])
        let script = result.scriptText

        // Read-only package must not appear anywhere in the script
        #expect(!script.contains("six"))
        #expect(!script.contains("/usr/bin/python3"))

        // Normal package must appear
        #expect(script.contains("brew uninstall jq"))

        // Return value must capture the skipped package
        #expect(result.skippedReadOnly.count == 1)
        #expect(result.skippedReadOnly[0].name == "six")
    }

    // MARK: - Denylist

    @Test func denylistedPackageIsCommentedOutAtBottomWithWarning() {
        let git = makePackage(manager: .brew, name: "git")
        let result = defaultGenerator.generate(packages: [git])
        let script = result.scriptText
        let scriptLines = lines(of: script)

        // No active command for git
        #expect(!scriptLines.contains("brew uninstall git"))
        // Echo line for git must not appear either
        #expect(!script.contains(#"echo "→ brew uninstall git""#))

        // The WARNING banner must appear
        #expect(script.contains("WARNING"))

        // The commented command must appear (with reason)
        #expect(script.contains("# brew uninstall git"))
        #expect(script.contains("reason:"))

        // Return value
        #expect(result.warnedDenylisted.count == 1)
        #expect(result.warnedDenylisted[0].name == "git")
    }

    @Test func denylistedSectionIsAlwaysAtTheBottomOfTheScript() {
        // Mix of active and denylisted packages
        let jq  = makePackage(manager: .brew, name: "jq")       // not denylisted
        let git = makePackage(manager: .brew, name: "git")       // denylisted

        let result = defaultGenerator.generate(packages: [jq, git])
        let script = result.scriptText

        let activePos  = script.range(of: "brew uninstall jq")
        let warningPos = script.range(of: "WARNING")

        // Both must be present
        #expect(activePos != nil)
        #expect(warningPos != nil)

        if let a = activePos, let w = warningPos {
            #expect(a.lowerBound < w.lowerBound)
        }
    }

    @Test func python312MatchesDenylistGlob() {
        let py312 = makePackage(manager: .brew, name: "python@3.12")
        let result = defaultGenerator.generate(packages: [py312])
        #expect(result.warnedDenylisted.count == 1)
        #expect(result.warnedDenylisted[0].name == "python@3.12")
        #expect(!result.scriptText.contains("brew uninstall python@3.12\n"))
        #expect(result.scriptText.contains("# brew uninstall python@3.12"))
    }

    // MARK: - Dependency-aware ordering

    @Test func dependentPackageAppearesBeforeItsDependency() {
        // app-a depends on lib-b → app-a must appear before lib-b in the script
        let appA = makePackage(manager: .brew, name: "app-a", dependencies: ["lib-b"])
        let libB = makePackage(manager: .brew, name: "lib-b", dependencies: [])

        let result = generator.generate(packages: [appA, libB])
        let script = result.scriptText

        let posA = script.range(of: "brew uninstall app-a")
        let posB = script.range(of: "brew uninstall lib-b")

        #expect(posA != nil)
        #expect(posB != nil)
        if let a = posA, let b = posB {
            #expect(a.lowerBound < b.lowerBound, "app-a (dependent) must appear before lib-b (dependency)")
        }
    }

    @Test func independentPackagesAreIncluded() {
        // Packages with no inter-dependencies: both must appear
        let pkgA = makePackage(manager: .brew, name: "htop")
        let pkgB = makePackage(manager: .brew, name: "tree")
        let result = generator.generate(packages: [pkgA, pkgB])
        let script = result.scriptText
        #expect(script.contains("brew uninstall htop"))
        #expect(script.contains("brew uninstall tree"))
    }

    @Test func dependencyCycleEmitsWarningComment() {
        // A depends on B, B depends on A — cycle
        let pkgA = makePackage(manager: .brew, name: "cycler-a", dependencies: ["cycler-b"])
        let pkgB = makePackage(manager: .brew, name: "cycler-b", dependencies: ["cycler-a"])
        let result = generator.generate(packages: [pkgA, pkgB])
        let script = result.scriptText
        #expect(script.contains("# WARNING: dependency cycle detected"))
        // Both packages must still appear
        #expect(script.contains("brew uninstall cycler-a"))
        #expect(script.contains("brew uninstall cycler-b"))
    }

    @Test("PERF25-010: large dependency ordering uses a deterministic logarithmic ready queue")
    func largeDependencyOrderingUsesDeterministicLogarithmicReadyQueue() {
        let pairCount = 2_000
        let apps = (0..<pairCount).map { index in
            let suffix = String(format: "%04d", index)
            return makePackage(
                manager: .brew,
                name: "app-\(suffix)",
                dependencies: ["lib-\(suffix)"]
            )
        }
        let libraries = (0..<pairCount).map { index in
            makePackage(
                manager: .brew,
                name: "lib-\(String(format: "%04d", index))"
            )
        }
        let packages = Array((apps + libraries).reversed())

        func uninstallNames(from packages: [Package]) -> [String] {
            lines(of: generator.generate(packages: packages).scriptText)
                .filter { $0.hasPrefix("brew uninstall ") }
                .map { String($0.dropFirst("brew uninstall ".count)) }
        }

        let firstOrder = uninstallNames(from: packages)
        let secondOrder = uninstallNames(from: libraries + apps)
        let positions = Dictionary(
            uniqueKeysWithValues: firstOrder.enumerated().map { ($0.element, $0.offset) }
        )

        #expect(firstOrder == secondOrder)
        #expect(firstOrder.count == packages.count)
        for index in 0..<pairCount {
            let suffix = String(format: "%04d", index)
            let appPosition = positions["app-\(suffix)"]
            let libraryPosition = positions["lib-\(suffix)"]
            #expect(appPosition != nil && libraryPosition != nil)
            if let appPosition, let libraryPosition {
                #expect(appPosition < libraryPosition)
            }
        }

        let diagnostics = ScriptGenerator.dependencyOrderingDiagnostics(for: packages)
        #expect(diagnostics.enqueuedNodeCount == packages.count)
        #expect(diagnostics.dequeuedNodeCount == packages.count)
        // A binary heap performs O(n log n) comparisons. This generous structural
        // bound catches a return to whole-queue sorting without using wall-clock time.
        #expect(diagnostics.queueComparisonCount < packages.count * 40)
    }

    // MARK: - Multiple managers

    @Test func multipleManagersEachGetOwnSectionHeader() {
        let brew = makePackage(manager: .brew, name: "jq")
        let npm  = makePackage(manager: .npm,  name: "typescript")
        let pip  = makePackage(manager: .pip,  name: "requests", qualifier: "/usr/local/bin/python3")

        let result = generator.generate(packages: [brew, npm, pip])
        let script = result.scriptText

        #expect(script.contains("# === Homebrew Formulae ==="))
        #expect(script.contains("# === npm (global) ==="))
        #expect(script.contains("# === pip (interpreter: /usr/local/bin/python3) ==="))

        // Canonical order: brew → pip → npm  (matches managerOrder in ScriptGenerator)
        let brewPos = script.range(of: "# === Homebrew Formulae ===")
        let pipPos  = script.range(of: "# === pip (interpreter:")
        let npmPos  = script.range(of: "# === npm (global) ===")

        #expect(brewPos != nil && pipPos != nil && npmPos != nil)
        if let b = brewPos, let p = pipPos, let n = npmPos {
            #expect(b.lowerBound < p.lowerBound)
            #expect(p.lowerBound < n.lowerBound)
        }
    }

    // MARK: - Snapshot context

    @Test func snapshotContextAppearsInHeader() {
        let id = UUID(uuidString: "AABBCCDD-1122-3344-5566-778899AABBCC")!
        let createdAt = Date(timeIntervalSince1970: 1_000_000)
        let ctx = SnapshotContext(id: id, createdAt: createdAt)

        let result = generator.generate(packages: [], snapshot: ctx)
        let script = result.scriptText

        #expect(script.contains(id.uuidString))
        #expect(script.contains("Snapshot taken before this script was generated"))
    }

    @Test func noSnapshotContextMeansNoSnapshotLines() {
        let result = generator.generate(packages: [])
        #expect(!result.scriptText.contains("Snapshot taken"))
        #expect(!result.scriptText.contains("Export as reinstall script"))
    }

    // MARK: - Preamble correctness

    @Test func scriptUsesStrictBashPreamble() {
        let result = generator.generate(packages: [makePackage(manager: .brew, name: "jq")])
        #expect(result.scriptText.contains("set -euo pipefail"))
        // Must NOT use the weaker "set -e" alone on its own line
        let strictLine = lines(of: result.scriptText).contains("set -euo pipefail")
        #expect(strictLine)
    }

    @Test func scriptEndsWithNewline() {
        let result = generator.generate(packages: [makePackage(manager: .brew, name: "jq")])
        #expect(result.scriptText.hasSuffix("\n"))
    }

    @Test func shellArgumentsQuoteUnsafePackageNames() {
        let pkg = makePackage(manager: .brew, name: "weird package'$(rm -rf ~)")
        let result = generator.generate(packages: [pkg])
        #expect(lines(of: result.scriptText).contains(#"brew uninstall 'weird package'\''$(rm -rf ~)'"#))
    }

    // MARK: - CORE25-003 / SEC25-003: comment injection

    @Test("CORE25-003/SEC25-003: shell comment sanitizer neutralizes line breaks and control characters")
    func shellCommentSanitizerNeutralizesUnsafeScalars() {
        let unsafe = CharacterSet.controlCharacters.union(.newlines)
        let sanitized = shellCommentText("alpha\r\nbeta\t\u{001B}gamma\u{2028}delta\u{2029}end")

        #expect(sanitized == "alpha  beta  gamma delta end")
        #expect(sanitized.unicodeScalars.allSatisfy { !unsafe.contains($0) })
    }

    @Test("CORE25-003/SEC25-003: echo previews neutralize terminal control sequences")
    func echoPreviewNeutralizesTerminalControlSequences() {
        let unsafe = CharacterSet.controlCharacters.union(.newlines)
        let preview = shellEchoLine(
            for: "brew uninstall 'tool\u{001B}]52;c;Y2xpcGJvYXJk\u{0007}\nnext'"
        )

        #expect(preview.contains("tool ]52;c;Y2xpcGJvYXJk  next"))
        #expect(preview.unicodeScalars.allSatisfy { !unsafe.contains($0) })
    }

    @Test("CORE25-003/SEC25-003: hostile qualifier stays inside its section comment")
    func hostileQualifierCannotEscapeSectionComment() {
        let qualifier = "/tmp/python\nprintf QUALIFIER_PWNED\u{001B}"
        let pkg = makePackage(manager: .pip, name: "requests", qualifier: qualifier)
        let script = generator.generate(packages: [pkg]).scriptText

        #expect(script.contains("# === pip (interpreter: /tmp/python printf QUALIFIER_PWNED ) ==="))
        #expect(!script.contains("# === pip (interpreter: /tmp/python\n"))
    }

    @Test("CORE25-003/SEC25-003: hostile cask artifact path stays inside its comment")
    func hostileCaskArtifactPathCannotEscapeComment() {
        let pkg = makePackage(
            manager: .brewCask,
            name: "warp",
            artifactPaths: ["/Applications/Warp.app\nprintf ARTIFACT_PWNED\u{0007}"]
        )
        let script = generator.generate(packages: [pkg]).scriptText

        #expect(script.contains("#   /Applications/Warp.app printf ARTIFACT_PWNED "))
        #expect(!script.contains("#   /Applications/Warp.app\n"))
        #expect(!lines(of: script).contains(where: { $0.hasPrefix("printf ARTIFACT_PWNED") }))
    }

    @Test("CORE25-003/SEC25-003: hostile MAS name stays inside its manual-removal comment")
    func hostileMASNameCannotEscapeComment() {
        let pkg = makePackage(manager: .mas, name: "Xcode\nprintf MAS_PWNED\u{0000}")
        let script = generator.generate(packages: [pkg]).scriptText

        #expect(script.contains("# Xcode printf MAS_PWNED : mas does not support CLI uninstall"))
        #expect(!lines(of: script).contains(where: { $0.hasPrefix("printf MAS_PWNED") }))
    }

    @Test("CORE25-003/SEC25-003: hostile denylist command and reason remain commented")
    func hostileDenylistMetadataCannotEscapeComment() {
        let packageName = "essential\nprintf COMMAND_PWNED"
        let denylist = Denylist(entries: [
            DenylistEntry(
                manager: .brew,
                namePattern: packageName,
                reason: "needed\nprintf REASON_PWNED\u{001B}"
            ),
        ])
        let hostileGenerator = ScriptGenerator(denylist: denylist)
        let script = hostileGenerator.generate(packages: [
            makePackage(manager: .brew, name: packageName),
        ]).scriptText

        #expect(script.contains("# brew uninstall 'essential printf COMMAND_PWNED'  # reason: needed printf REASON_PWNED "))
        #expect(!lines(of: script).contains(where: { $0.hasPrefix("printf COMMAND_PWNED") }))
        #expect(!lines(of: script).contains(where: { $0.hasPrefix("printf REASON_PWNED") }))
    }

    // MARK: - removalCommand(for:)

    @Test func removalCommandBrewFormula() {
        let pkg = makePackage(manager: .brew, name: "jq")
        #expect(generator.removalCommand(for: pkg) == "brew uninstall jq")
    }

    @Test func removalCommandBrewCask() {
        let pkg = makePackage(manager: .brewCask, name: "visual-studio-code")
        #expect(generator.removalCommand(for: pkg) == "brew uninstall --cask visual-studio-code")
    }

    @Test func removalCommandPipWithQualifier() {
        let interpreter = "/Users/x/.pyenv/versions/3.12.1/bin/python3.12"
        let pkg = makePackage(manager: .pip, name: "requests", qualifier: interpreter)
        #expect(generator.removalCommand(for: pkg) == #"/Users/x/.pyenv/versions/3.12.1/bin/python3.12 -m pip uninstall -y requests"#)
        // Homebrew's Python is protected (PEP 668): explained, not run.
        let homebrew = makePackage(manager: .pip, name: "requests", qualifier: "/opt/homebrew/bin/python3.12")
        #expect(generator.removalCommand(for: homebrew)?.hasPrefix("# requests: Homebrew's Python") == true)
    }

    @Test func removalCommandPipNoQualifierFallsBackToPython3() {
        let pkg = makePackage(manager: .pip, name: "flask")
        #expect(generator.removalCommand(for: pkg) == "python3 -m pip uninstall -y flask")
    }

    @Test func removalCommandNpm() {
        let pkg = makePackage(manager: .npm, name: "typescript")
        #expect(generator.removalCommand(for: pkg) == "npm uninstall -g typescript")
    }

    @Test func removalCommandScopedNpm() {
        let pkg = makePackage(manager: .npm, name: "@types/node")
        #expect(generator.removalCommand(for: pkg) == "npm uninstall -g @types/node")
    }

    @Test func removalCommandPipx() {
        let pkg = makePackage(
            manager: .pipx,
            name: "black",
            qualifier: "/Users/tester/.local/share/pipx/venvs/black"
        )
        #expect(generator.removalCommand(for: pkg) == "pipx uninstall black")
    }

    @Test("CORE25-004: same-name suffixed pipx installs have distinct exact uninstall targets")
    func suffixedPipxInstallsHaveDistinctUninstallTargets() {
        let venv311 = "/Users/tester/.local/share/pipx/venvs/black-3-11"
        let venv312 = "/Users/tester/.local/share/pipx/venvs/black-3-12"
        let packages = [
            makePackage(manager: .pipx, name: "black", qualifier: venv312),
            makePackage(manager: .pipx, name: "black", qualifier: venv311),
        ]

        let commands = lines(of: generator.generate(packages: packages).scriptText)
            .filter { $0.hasPrefix("pipx uninstall ") }

        #expect(commands == [
            "pipx uninstall black-3-11",
            "pipx uninstall black-3-12",
        ])
        #expect(generator.removalCommand(for: packages[0]) == "pipx uninstall black-3-12")
        #expect(generator.removalCommand(for: packages[1]) == "pipx uninstall black-3-11")
    }

    @Test("CORE25-004: pipx environment targets are shell quoted end-to-end")
    func pipxEnvironmentTargetIsShellQuoted() {
        let environmentName = "black-qa'$(touch PWNED)"
        let package = makePackage(
            manager: .pipx,
            name: "black",
            qualifier: "/Users/tester/.local/share/pipx/venvs/\(environmentName)"
        )

        #expect(generator.removalCommand(for: package)
            == #"pipx uninstall 'black-qa'\''$(touch PWNED)'"#)
    }

    @Test func removalCommandCargo() {
        let pkg = makePackage(manager: .cargo, name: "ripgrep")
        #expect(generator.removalCommand(for: pkg) == "cargo uninstall ripgrep")
    }

    @Test("CORE25-007: gem removal targets the recorded version")
    func gemRemovalTargetsRecordedVersion() {
        let pkg = makePackage(manager: .gem, name: "nokogiri", version: "1.15.4")
        #expect(generator.removalCommand(for: pkg) == "gem uninstall nokogiri -v 1.15.4")
    }

    @Test("CORE25-007: cleanup keeps every selected version of the same gem")
    func cleanupKeepsMultipleGemVersions() {
        let qualifier = "/Users/tester/.gem/ruby/3.3.0/specifications"
        let packages = [
            makePackage(manager: .gem, name: "nokogiri", version: "1.15.4", qualifier: qualifier),
            makePackage(manager: .gem, name: "nokogiri", version: "1.16.8", qualifier: qualifier),
        ]

        let commands = lines(of: generator.generate(packages: Array(packages.reversed())).scriptText)
            .filter { $0.hasPrefix("gem uninstall nokogiri -v ") }

        #expect(commands == [
            "gem uninstall nokogiri -v 1.15.4 --install-dir /Users/tester/.gem/ruby/3.3.0",
            "gem uninstall nokogiri -v 1.16.8 --install-dir /Users/tester/.gem/ruby/3.3.0",
        ])
    }

    @Test func removalCommandMasReturnsNil() {
        let pkg = makePackage(manager: .mas, name: "Xcode")
        #expect(generator.removalCommand(for: pkg) == nil)
    }

    @Test func removalCommandReadOnlyReturnsNil() {
        let pkg = makePackage(manager: .brew, name: "python3", isReadOnly: true)
        #expect(generator.removalCommand(for: pkg) == nil)
    }

    @Test("APP-F2: cleanup selection eligibility matches removal-command availability")
    func cleanupSelectionEligibilityMatchesRemovalCommands() {
        let eligible = makePackage(manager: .brew, name: "jq")
        let readOnly = makePackage(manager: .pip, name: "six", isReadOnly: true)
        let appStore = makePackage(manager: .mas, name: "Xcode")

        for package in [eligible, readOnly, appStore] {
            #expect(
                package.isRemovalScriptEligible
                    == (generator.removalCommand(for: package) != nil)
            )
        }
    }

    @Test func removalCommandPipWithSpecialCharsInInterpreterPath() {
        let interpreter = "/Users/my user/.pyenv/versions/3.12.0/bin/python"
        let pkg = makePackage(manager: .pip, name: "flask", qualifier: interpreter)
        let cmd = generator.removalCommand(for: pkg)
        #expect(cmd == #"'/Users/my user/.pyenv/versions/3.12.0/bin/python' -m pip uninstall -y flask"#)
    }
}

// MARK: - CORE-03: npm/gem commands must target the recorded qualifier

@Suite("ScriptGenerator multi-qualifier targeting")
struct ScriptGeneratorQualifierTests {

    private let generator = ScriptGenerator(denylist: Denylist(entries: []))

    private func makePackage(manager: PackageManager, name: String, qualifier: String?) -> Package {
        Package(
            id: "\(manager.rawValue):\(qualifier ?? ""):\(name)",
            manager: manager,
            qualifier: qualifier,
            name: name,
            version: "1.0.0",
            installPath: nil,
            installedAt: nil,
            installedAtConfidence: .low,
            sizeBytes: nil,
            isExplicit: true,
            isReadOnly: false,
            dependencies: [],
            lastSeen: Date()
        )
    }

    private func commandLines(_ script: String, containing needle: String) -> [String] {
        script.components(separatedBy: "\n")
            .filter { $0.contains(needle) && !$0.hasPrefix("#") && !$0.hasPrefix("echo") }
    }

    private func lines(of script: String) -> [String] {
        script.components(separatedBy: "\n")
    }

    private let node18 = "/Users/w/.nvm/versions/node/v18.19.1/lib/node_modules"
    private let node20 = "/Users/w/.nvm/versions/node/v20.11.0/lib/node_modules"
    private let ruby31 = "/Users/w/.rbenv/versions/3.1.4/lib/ruby/gems/3.1.0/specifications"
    private let ruby32 = "/Users/w/.rbenv/versions/3.2.2/lib/ruby/gems/3.2.0/specifications"

    @Test("CORE-03: the same npm package under two Node installs emits two distinct commands")
    func npmTwoNodeInstallsEmitDistinctCommands() {
        let script = generator.generate(packages: [
            makePackage(manager: .npm, name: "typescript", qualifier: node18),
            makePackage(manager: .npm, name: "typescript", qualifier: node20),
        ]).scriptText

        let commands = commandLines(script, containing: "uninstall -g typescript")
        #expect(commands.count == 2)
        #expect(Set(commands).count == 2)
        #expect(commands.contains("/Users/w/.nvm/versions/node/v18.19.1/bin/npm uninstall -g typescript"))
        #expect(commands.contains("/Users/w/.nvm/versions/node/v20.11.0/bin/npm uninstall -g typescript"))
    }

    @Test("CORE-03: the same gem under two Ruby installs emits two distinct commands")
    func gemTwoRubyInstallsEmitDistinctCommands() {
        let script = generator.generate(packages: [
            makePackage(manager: .gem, name: "bundler", qualifier: ruby31),
            makePackage(manager: .gem, name: "bundler", qualifier: ruby32),
        ]).scriptText

        let commands = commandLines(script, containing: "uninstall bundler")
        #expect(commands.count == 2)
        #expect(Set(commands).count == 2)
        #expect(commands.contains("/Users/w/.rbenv/versions/3.1.4/bin/gem uninstall bundler -v 1.0.0"))
        #expect(commands.contains("/Users/w/.rbenv/versions/3.2.2/bin/gem uninstall bundler -v 1.0.0"))
    }

    @Test("CORE-03: npm sections are grouped per Node install")
    func npmSectionsGroupedByQualifier() {
        let script = generator.generate(packages: [
            makePackage(manager: .npm, name: "typescript", qualifier: node18),
            makePackage(manager: .npm, name: "prettier", qualifier: node20),
        ]).scriptText

        #expect(script.contains("# === npm (global: \(node18)) ==="))
        #expect(script.contains("# === npm (global: \(node20)) ==="))
    }

    @Test("CORE-03: gem sections are grouped per Ruby install")
    func gemSectionsGroupedByQualifier() {
        let script = generator.generate(packages: [
            makePackage(manager: .gem, name: "bundler", qualifier: ruby31),
            makePackage(manager: .gem, name: "rake", qualifier: ruby32),
        ]).scriptText

        #expect(script.contains("# === Ruby Gems (\(ruby31)) ==="))
        #expect(script.contains("# === Ruby Gems (\(ruby32)) ==="))
    }

    @Test("CORE-03: a gem with no colocated client is scoped with --install-dir")
    func gemWithoutColocatedClientUsesInstallDir() {
        let script = generator.generate(packages: [
            makePackage(manager: .gem, name: "bundler", qualifier: "/Users/w/.gem/ruby/3.2.0/specifications"),
        ]).scriptText

        #expect(script.contains("gem uninstall bundler -v 1.0.0 --install-dir /Users/w/.gem/ruby/3.2.0"))
    }

    @Test("CORE-03: removalCommand honours the qualifier, matching the generated script")
    func removalCommandHonoursQualifier() {
        let pkg = makePackage(manager: .npm, name: "typescript", qualifier: node20)
        #expect(generator.removalCommand(for: pkg)
            == "/Users/w/.nvm/versions/node/v20.11.0/bin/npm uninstall -g typescript")
    }

    @Test("CORE-03: unqualified npm and gem packages keep the ambient commands")
    func unqualifiedPackagesUseAmbientCommands() {
        let script = generator.generate(packages: [
            makePackage(manager: .npm, name: "typescript", qualifier: nil),
            makePackage(manager: .gem, name: "bundler", qualifier: nil),
        ]).scriptText

        #expect(script.contains("npm uninstall -g typescript"))
        #expect(script.contains("gem uninstall bundler -v 1.0.0"))
        #expect(script.contains("# === npm (global) ==="))
        #expect(script.contains("# === Ruby Gems ==="))
    }

    // MARK: - Agent skills

    private func makeSkillPackage(
        name: String,
        root: String,
        installPath: String?,
        artifactPaths: [String]? = nil
    ) -> Package {
        Package(
            id: "agentSkill:\(root):\(name)",
            manager: .agentSkill,
            qualifier: root,
            name: name,
            version: installPath == nil ? "" : "1.0.0",
            installPath: installPath.map(URL.init(fileURLWithPath:)),
            installedAt: nil,
            installedAtConfidence: .low,
            sizeBytes: nil,
            isExplicit: true,
            isReadOnly: false,
            dependencies: [],
            artifactPaths: artifactPaths,
            lastSeen: Date()
        )
    }

    @Test("agent skill real directory produces a destructive-removal comment and warning")
    func agentSkillDirectoryIsCommented() {
        let root = "/Users/x/.claude/skills"
        let pkg = makeSkillPackage(
            name: "app-design",
            root: root,
            installPath: "\(root)/app-design"
        )
        let result = generator.generate(packages: [pkg])
        let script = result.scriptText

        #expect(script.contains("# === Agent Skills (\(root)) ==="))
        #expect(script.contains("WARNING: agent skills have no package-manager backup"))
        #expect(script.contains("# rm -rf \(root)/app-design"))
        // Must never emit an active rm -rf for a real directory.
        let scriptLines = lines(of: script)
        #expect(!scriptLines.contains("rm -rf \(root)/app-design"))
    }

    @Test("agent skill broken symlink produces an active rm of just the link")
    func agentSkillBrokenSymlinkRemovesLinkOnly() {
        let root = "/Users/x/.config/opencode/skills"
        let target = "/Users/x/skills-src/deprecated"
        let pkg = makeSkillPackage(
            name: "deprecated-skill",
            root: root,
            installPath: nil,
            artifactPaths: [target]
        )
        let result = generator.generate(packages: [pkg])
        let script = result.scriptText

        let cmd = "rm \(root)/deprecated-skill"
        let scriptLines = lines(of: script)
        #expect(scriptLines.contains(cmd))
        #expect(!script.contains("rm -rf"))
        #expect(!script.contains("WARNING"))
    }

    @Test("removalCommand returns the active link removal for a broken skill symlink")
    func removalCommandForBrokenSkillSymlink() {
        let root = "/Users/x/.agents/skills"
        let pkg = makeSkillPackage(
            name: "stale",
            root: root,
            installPath: nil,
            artifactPaths: ["/Users/x/old-target"]
        )
        #expect(generator.removalCommand(for: pkg) == "rm \(root)/stale")
    }

    @Test("removalCommand returns the commented destructive line for a real skill directory")
    func removalCommandForRealSkillDirectory() {
        let root = "/Users/x/.claude/skills"
        let pkg = makeSkillPackage(name: "app-design", root: root, installPath: "\(root)/app-design")
        #expect(generator.removalCommand(for: pkg)
            == "# rm -rf \(root)/app-design  # no package-manager backup")
    }

    @Test("agent skill sections are grouped per tool root")
    func agentSkillSectionsGroupedByRoot() {
        let script = generator.generate(packages: [
            makeSkillPackage(name: "a-skill", root: "/Users/x/.claude/skills", installPath: "/Users/x/.claude/skills/a-skill"),
            makeSkillPackage(name: "b-skill", root: "/Users/x/.config/opencode/skills", installPath: "/Users/x/.config/opencode/skills/b-skill"),
        ]).scriptText

        #expect(script.contains("# === Agent Skills (/Users/x/.claude/skills) ==="))
        #expect(script.contains("# === Agent Skills (/Users/x/.config/opencode/skills) ==="))
    }

    // MARK: - Phase B: agent CLIs and editor extensions

    @Test("agent CLI removal is emitted as a review comment, never a command")
    func agentCliRemovalIsAComment() {
        let pkg = makePackage(manager: .agentCli, name: "claude", qualifier: "/Users/x/.claude")
        let command = generator.removalCommand(for: pkg)
        #expect(command?.hasPrefix("#") == true)
        #expect(command?.contains("claude") == true)
        #expect(command?.contains("no generated uninstall command") == true)

        let script = generator.generate(packages: [pkg]).scriptText
        let scriptLines = lines(of: script)
        #expect(!scriptLines.contains(where: { $0.hasPrefix("claude ") && !$0.hasPrefix("#") }))
    }

    @Test("editor extension under VS Code emits a code uninstall command")
    func editorExtensionVSCodeUsesCodeCLI() {
        let pkg = makePackage(
            manager: .editorExtension,
            name: "prettier-vscode",
            qualifier: "/Users/x/.vscode/extensions"
        )
        #expect(generator.removalCommand(for: pkg) == "code --uninstall-extension prettier-vscode")
    }

    @Test("editor extension under Cursor emits a cursor uninstall command")
    func editorExtensionCursorUsesCursorCLI() {
        let pkg = makePackage(
            manager: .editorExtension,
            name: "python",
            qualifier: "/Users/x/.cursor/extensions"
        )
        #expect(generator.removalCommand(for: pkg) == "cursor --uninstall-extension python")
    }

    @Test("editor extension with an unknown root is a manual-review comment")
    func editorExtensionUnknownRootIsManualReview() {
        let pkg = makePackage(
            manager: .editorExtension,
            name: "some-ext",
            qualifier: "/Users/x/custom/place"
        )
        let command = generator.removalCommand(for: pkg)
        #expect(command?.hasPrefix("#") == true)
        #expect(command?.contains("Manual review required") == true)
    }

    @Test("editor extension sections are grouped per editor root")
    func editorExtensionSectionsGroupedByRoot() {
        let script = generator.generate(packages: [
            makePackage(manager: .editorExtension, name: "prettier-vscode", qualifier: "/Users/x/.vscode/extensions"),
            makePackage(manager: .editorExtension, name: "python", qualifier: "/Users/x/.cursor/extensions"),
        ]).scriptText

        #expect(script.contains("# === Editor Extensions (/Users/x/.vscode/extensions) ==="))
        #expect(script.contains("# === Editor Extensions (/Users/x/.cursor/extensions) ==="))
        #expect(script.contains("code --uninstall-extension prettier-vscode"))
        #expect(script.contains("cursor --uninstall-extension python"))
    }
}

// MARK: - Phase 3: trash mode (reversible removal)

@Suite("ScriptGenerator trash mode")
struct ScriptGeneratorTrashTests {

    private let generator = ScriptGenerator(denylist: Denylist(entries: []))

    private func makePackage(
        manager: PackageManager,
        name: String,
        qualifier: String? = nil,
        installPath: String? = nil,
        artifactPaths: [String]? = nil
    ) -> Package {
        Package(
            id: "\(manager.rawValue):\(qualifier ?? ""):\(name)",
            manager: manager,
            qualifier: qualifier,
            name: name,
            version: "1.0.0",
            installPath: installPath.map(URL.init(fileURLWithPath:)),
            installedAt: nil,
            installedAtConfidence: .low,
            sizeBytes: nil,
            isExplicit: true,
            isReadOnly: false,
            dependencies: [],
            artifactPaths: artifactPaths,
            lastSeen: Date()
        )
    }

    private func activeLines(_ script: String, prefix: String) -> [String] {
        script.components(separatedBy: "\n").filter { $0.hasPrefix(prefix) }
    }

    @Test("trash mode adds the header note")
    func trashModeHeaderNote() {
        let script = generator.generate(packages: [], strategy: .trash).scriptText
        #expect(script.contains("Trash mode: file-backed packages are moved to ~/.Trash"))
    }

    @Test("trash mode moves a real skill directory instead of rm -rf")
    func trashModeMovesRealSkillDirectory() {
        let root = "/Users/x/.claude/skills"
        let pkg = makePackage(
            manager: .agentSkill,
            name: "app-design",
            qualifier: root,
            installPath: "\(root)/app-design"
        )
        let script = generator.generate(packages: [pkg], strategy: .trash).scriptText

        #expect(!script.contains("rm -rf"))
        let mv = activeLines(script, prefix: "mv ")
        #expect(mv.count == 1)
        #expect(mv[0].contains("\(root)/app-design"))
        #expect(mv[0].contains("$HOME/.Trash/installory-"))
        #expect(mv[0].hasSuffix("/app-design"))
    }

    @Test("trash mode moves a broken skill symlink")
    func trashModeMovesBrokenSkillSymlink() {
        let root = "/Users/x/.config/opencode/skills"
        let pkg = makePackage(
            manager: .agentSkill,
            name: "stale",
            qualifier: root,
            installPath: nil,
            artifactPaths: ["/Users/x/skills-src/deprecated"]
        )
        let script = generator.generate(packages: [pkg], strategy: .trash).scriptText

        #expect(!script.contains("rm "))
        let mv = activeLines(script, prefix: "mv ")
        #expect(mv.count == 1)
        #expect(mv[0].contains("\(root)/stale"))
    }

    @Test("trash mode moves an editor extension instead of --uninstall-extension")
    func trashModeMovesEditorExtension() {
        let pkg = makePackage(
            manager: .editorExtension,
            name: "prettier-vscode",
            qualifier: "/Users/x/.vscode/extensions",
            installPath: "/Users/x/.vscode/extensions/prettier-vscode-1.2.3"
        )
        let script = generator.generate(packages: [pkg], strategy: .trash).scriptText

        #expect(!script.contains("--uninstall-extension"))
        let mv = activeLines(script, prefix: "mv ")
        #expect(mv.count == 1)
        #expect(mv[0].contains("/Users/x/.vscode/extensions/prettier-vscode-1.2.3"))
        // Named after the extension's own folder, never the manifest name.
        #expect(mv[0].hasSuffix("/prettier-vscode-1.2.3"))
    }

    @Test("trash mode still uninstalls package-manager packages")
    func trashModeKeepsUninstallForBrew() {
        let pkg = makePackage(manager: .brew, name: "jq")
        let script = generator.generate(packages: [pkg], strategy: .trash).scriptText

        #expect(script.contains("brew uninstall jq"))
        #expect(!script.contains("$HOME/.Trash/installory-"))
        #expect(!script.contains("mkdir -p"))
    }

    @Test("trash mode emits a single mkdir when a trash-eligible package is present")
    func trashModeMkdirOnlyWhenNeeded() {
        let skill = makePackage(
            manager: .agentSkill,
            name: "app-design",
            qualifier: "/Users/x/.claude/skills",
            installPath: "/Users/x/.claude/skills/app-design"
        )
        let brew = makePackage(manager: .brew, name: "jq")

        let withSkill = generator.generate(packages: [skill, brew], strategy: .trash).scriptText
        let mkdirs = activeLines(withSkill, prefix: "mkdir -p ")
        #expect(mkdirs.count == 1)
        #expect(mkdirs[0].hasPrefix(#"mkdir -p "$HOME/.Trash/installory-"#))

        let withoutSkill = generator.generate(packages: [brew], strategy: .trash).scriptText
        #expect(activeLines(withoutSkill, prefix: "mkdir -p ").isEmpty)
    }
}
