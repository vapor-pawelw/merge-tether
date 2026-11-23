import Foundation
import Testing
@testable import MergeTether

@Suite("Assistant dependencies")
struct AssistantDependenciesTests {
    #if DEBUG
    @MainActor @Test(arguments: AutomationAssistant.allCases)
    func testHostDiscoveryCannotFallBackToInstalledAssistants(_ assistant: AutomationAssistant) async {
        let status = await AssistantCLI.detect(assistant)
        switch status {
        case .missingCLI: break
        case .ready(let executable), .loginRequired(let executable):
            #expect(executable.path.hasPrefix(URL.homeDirectory.appending(path: ".local/bin").path + "/"))
        default: Issue.record("Test-host discovery must use an isolated-home fixture or report a missing CLI")
        }
    }
    #endif

    @Test(arguments: AutomationAssistant.allCases)
    func workingHeadlessCLIIsReadyWithoutDesktop(_ assistant: AutomationAssistant) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = folder.appending(path: assistant.rawValue)
        try Data("#!/bin/sh\ncase \"$*\" in\n  --version) echo version-1 ;;\n  'auth status') echo '{\"loggedIn\":true}' ;;\n  *) echo 'exec --output-schema --ignore-user-config --ignore-rules --dangerously-bypass-approvals-and-sandbox --print --tools --safe-mode --dangerously-skip-permissions --output-format --json-schema' ;;\nesac\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)

        let status = await AssistantCLI.check(assistant, candidates: [cli])

        #expect(status == .ready(cli))
        try FileManager.default.removeItem(at: cli)
        #expect(await AssistantCLI.check(assistant, candidates: [cli]) == .missingCLI)
    }

    @Test(arguments: AutomationAssistant.allCases)
    func aCLIWithoutFullAccessSupportNeedsAnUpdate(_ assistant: AutomationAssistant) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = folder.appending(path: assistant.rawValue)
        try Data("""
        #!/bin/sh
        case "$*" in
          --version) echo version-1 ;;
          'auth status') echo '{"loggedIn":true}' ;;
          *) echo 'exec --output-schema --ignore-user-config --print --tools --safe-mode --output-format --json-schema' ;;
        esac
        """.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        #expect(await AssistantCLI.check(assistant, candidates: [cli]) == .invalidCLI)
    }

    @Test(arguments: AutomationAssistant.allCases)
    func noExecutableMeansMissingCLI(_ assistant: AutomationAssistant) async {
        let status = await AssistantCLI.check(assistant, candidates: [])
        #expect(status == .missingCLI)
    }

    @Test(arguments: AutomationAssistant.allCases)
    func loginFailureCannotBeTreatedAsReady(_ assistant: AutomationAssistant) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = folder.appending(path: assistant.rawValue)
        try Data("#!/bin/sh\ncase \"$*\" in\n 'login status'|'auth status') exit 1 ;;\n *) echo '--output-schema --ignore-user-config --ignore-rules --dangerously-bypass-approvals-and-sandbox --tools --safe-mode --dangerously-skip-permissions --json-schema' ;;\nesac\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        #expect(await AssistantCLI.check(assistant, candidates: [cli]) == .loginRequired(cli))
    }

    @Test func standaloneDiscoveryWorksWithoutAnAppAndOptionalBundledCLIIsPreferred() {
        let home = URL(fileURLWithPath: "/example/home")
        let standalone = AssistantCLI.candidates(for: .codex, desktopURL: nil, home: home)
        #expect(standalone.first == home.appending(path: ".local/bin/codex"))
        let app = URL(fileURLWithPath: "/Applications/Codex.app")
        let bundled = AssistantCLI.candidates(for: .codex, desktopURL: app, home: home)
        #expect(bundled.first == app.appending(path: "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"))
        #expect(bundled.contains(home.appending(path: ".local/bin/codex")))
    }

    @MainActor @Test func setupCannotCommitWhenTheCLIHasNotSignedIn() async {
        let setup = AssistantSetupSession(assistant: .codex, probe: { _ in
            .loginRequired(URL(fileURLWithPath: "/example/codex"))
        })
        #expect(await setup.verify() == false)
        #expect(!setup.canCommit)
    }

    @MainActor @Test func anInstalledCLIDoesNotMakeAgentActionsReadyUntilSelected() async throws {
        let suite = "AssistantDependenciesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let dependencies = AssistantDependencyMonitor(probe: { assistant in
            assistant == .claude ? .ready(URL(fileURLWithPath: "/example/claude")) : .missingCLI
        })
        let monitor = TodoMonitorService(settings: settings, glab: GlabService(), assistantDependencies: dependencies)
        defer { monitor.stopTimer() }

        dependencies.refresh()
        for _ in 0..<1000 where dependencies.isChecking { await Task.yield() }
        try #require(dependencies.statuses[.codex] == .missingCLI)
        #expect(monitor.availableAssistants.contains(.claude))
        #expect(!monitor.selectedAssistantReady)
        settings.automation.selectedAssistant = .codex
        #expect(!monitor.selectedAssistantReady)
        settings.automation.selectedAssistant = .claude
        #expect(monitor.selectedAssistantReady)
    }

    @Test func verificationMigratesOnAndPreservesExplicitOptOut() throws {
        let decoder = JSONDecoder()
        let migrated = try decoder.decode(AutomationSettings.self, from: Data(#"{"packageDecision":"enabled"}"#.utf8))
        #expect(migrated.autoVerifyReReview)
        #expect(migrated.codexVerificationModel == .luna)
        #expect(migrated.claudeVerificationModel == .haiku)
        var disabled = migrated
        disabled.autoVerifyReReview = false
        #expect(try !decoder.decode(AutomationSettings.self, from: JSONEncoder().encode(disabled)).autoVerifyReReview)
        disabled.applyRecommended(for: .claude)
        #expect(disabled.autoVerifyReReview)
    }

    @Test(arguments: AutomationAssistant.allCases)
    func verifierThinkingDefaultsToHighButPresetsPreserveExplicitSelection(_ assistant: AutomationAssistant) throws {
        func thinking(_ settings: AutomationSettings) throws -> String? {
            let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
            return object["verificationThinking"] as? String
        }
        #expect(try thinking(AutomationSettings()) == "high")
        for legacy in [#"{}"#, #"{"verificationThinking":"unsupported"}"#] {
            let decoded = try JSONDecoder().decode(AutomationSettings.self, from: Data(legacy.utf8))
            #expect(try thinking(decoded) == "high")
        }
        var configured = try JSONDecoder().decode(AutomationSettings.self,
            from: Data(#"{"verificationThinking":"low"}"#.utf8))
        configured.applyRecommended(for: assistant)
        #expect(try thinking(configured) == "high")
        for preset in AutomationPreset.allCases + [.checkpoints] {
            configured = try JSONDecoder().decode(AutomationSettings.self,
                from: Data(#"{"verificationThinking":"low"}"#.utf8))
            configured.applyPreset(preset, for: assistant)
            #expect(try thinking(configured) == "low")
            let restored = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(configured))
            #expect(try thinking(restored) == "low")
        }
    }

    @MainActor @Test(arguments: ["low", "medium", "high"], AutomationAssistant.allCases)
    func explicitVerifierThinkingPersistsAcrossSettingsReload(_ thinking: String, _ assistant: AutomationAssistant) throws {
        let suite = "VerifierThinkingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = SettingsManager(defaults: defaults)
        manager.automation = try JSONDecoder().decode(AutomationSettings.self,
            from: Data(#"{"assistant":"\#(assistant.rawValue)","verificationThinking":"\#(thinking)"}"#.utf8))
        manager.save()

        let restored = SettingsManager(defaults: defaults)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.automation)) as? [String: Any])
        #expect(encoded["verificationThinking"] as? String == thinking)
        #expect(restored.automation.assistant == assistant)
    }

    @MainActor @Test func cancellingSelectionRejectsLateSuccessfulProbe() async {
        var resume: CheckedContinuation<AssistantDependencyStatus, Never>?
        let setup = AssistantSetupSession(assistant: .claude, probe: { _ in
            await withCheckedContinuation { resume = $0 }
        })
        let task = Task { await setup.verify() }
        for _ in 0..<1000 where resume == nil { await Task.yield() }
        guard let resume else { Issue.record("Selection must await the dependency probe"); return }
        setup.cancel()
        resume.resume(returning: .ready(URL(fileURLWithPath: "/example/claude")))
        #expect(await task.value == false)
        #expect(!setup.canCommit)
    }
    @Test(arguments: AutomationAssistant.allCases)
    func installationGuidesUseOfficialDocumentation(_ assistant: AutomationAssistant) {
        let guide = AssistantCLI.installationGuide(for: assistant)
        #expect(guide.scheme == "https")
        #expect(guide.host == (assistant == .codex ? "learn.chatgpt.com" : "code.claude.com"))
        #expect(guide.path == (assistant == .codex ? "/docs/codex/cli" : "/docs/en/setup"))
    }

    @MainActor @Test func recheckingAfterExternalInstallationUpdatesReadiness() async {
        var state: AssistantDependencyStatus = .missingCLI
        let setup = AssistantSetupSession(assistant: .codex, probe: { _ in state })
        #expect(await setup.verify() == false)
        #expect(!setup.canCommit)
        state = .ready(URL(fileURLWithPath: "/example/cli"))
        #expect(await setup.verify())
        #expect(setup.canCommit)
    }

    @MainActor @Test func olderSuccessfulCheckCannotOverrideANewerFailedCheck() async {
        var completions: [CheckedContinuation<AssistantDependencyStatus, Never>] = []
        let setup = AssistantSetupSession(assistant: .codex, probe: { _ in
            await withCheckedContinuation { completions.append($0) }
        })
        let first = Task { await setup.verify() }
        for _ in 0..<1000 where completions.count < 1 { await Task.yield() }
        let second = Task { await setup.verify() }
        for _ in 0..<1000 where completions.count < 2 { await Task.yield() }
        guard completions.count == 2 else { Issue.record("Both checks must start"); return }
        completions[1].resume(returning: .missingCLI)
        #expect(await second.value == false)
        completions[0].resume(returning: .ready(URL(fileURLWithPath: "/example/cli")))
        #expect(await first.value == false)
        #expect(setup.status == .missingCLI && !setup.canCommit)
    }

    @MainActor @Test func frequentRefreshesCoalesceAndOnlyProbeRequestedAssistants() async throws {
        var probes: [AutomationAssistant] = []
        let monitor = AssistantDependencyMonitor(probe: { assistant in
            probes.append(assistant)
            return .ready(URL(fileURLWithPath: "/example/cli"))
        })
        func finish() async throws {
            for _ in 0..<1000 where monitor.isChecking { await Task.yield() }
            try #require(!monitor.isChecking)
        }

        for _ in 0..<10 { monitor.refresh([.codex]) }
        try await finish()
        for _ in 0..<10 { monitor.refresh([.codex]) }
        #expect(!monitor.isChecking)
        #expect(probes == [.codex])

        monitor.refresh([.claude])
        try await finish()
        #expect(probes == [.codex, .claude])
        #expect(monitor.available == [.codex, .claude])

        monitor.refresh([.codex], force: true)
        try await finish()
        #expect(probes == [.codex, .claude, .codex])
    }

    @MainActor @Test func initialReadinessIsSeparateFromReadOnlyFailureRecovery() async throws {
        var status: AssistantDependencyStatus = .ready(URL(fileURLWithPath: "/example/cli"))
        let monitor = AssistantDependencyMonitor(probe: { _ in status })
        var ready: [AutomationAssistant] = [], recovered: [AutomationAssistant] = []
        monitor.onReady = { assistant in
            #expect(monitor.available.contains(assistant))
            ready.append(assistant)
        }
        monitor.onRecovered = { recovered.append($0) }
        func refresh() async throws {
            monitor.refresh(force: true)
            for _ in 0..<1000 where monitor.isChecking { await Task.yield() }
            try #require(!monitor.isChecking)
        }

        try await refresh()
        #expect(Set(ready) == Set(AutomationAssistant.allCases) && recovered.isEmpty)
        let initialCount = ready.count
        try await refresh()
        #expect(ready.count == initialCount && recovered.isEmpty)
        status = .missingCLI
        try await refresh()
        status = .ready(URL(fileURLWithPath: "/example/cli"))
        try await refresh()
        #expect(ready.count == initialCount * 2 && Set(recovered) == Set(AutomationAssistant.allCases))
    }

    @MainActor @Test func runtimeFailureAndRecoveryAreDetectedWithoutChangingSavedSelection() async throws {
        var status: AssistantDependencyStatus = .ready(URL(fileURLWithPath: "/example/cli"))
        let monitor = AssistantDependencyMonitor(probe: { _ in status })
        var recovered: Set<AutomationAssistant> = []
        monitor.onRecovered = { recovered.insert($0) }
        func refresh() async throws {
            monitor.refresh(force: true)
            for _ in 0..<1000 where monitor.isChecking { await Task.yield() }
            try #require(!monitor.isChecking)
        }
        try await refresh()
        #expect(monitor.available == Set(AutomationAssistant.allCases))
        status = .missingCLI
        try await refresh()
        #expect(monitor.available.isEmpty)
        status = .ready(URL(fileURLWithPath: "/example/cli"))
        try await refresh()
        #expect(recovered == Set(AutomationAssistant.allCases))
        status = .missingCLI
        try await refresh()
        #expect(monitor.available.isEmpty)
    }
}
