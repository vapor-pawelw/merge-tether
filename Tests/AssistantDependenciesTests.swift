import Foundation
import Testing
@testable import GitLabTodos

@Suite("Assistant dependencies")
struct AssistantDependenciesTests {
    @Test(arguments: AutomationAssistant.allCases)
    func workingHeadlessCLIIsReadyWithoutDesktop(_ assistant: AutomationAssistant) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = folder.appending(path: assistant.rawValue)
        try Data("#!/bin/sh\ncase \"$*\" in\n  --version) echo version-1 ;;\n  'auth status') echo '{\"loggedIn\":true}' ;;\n  *) echo 'exec --output-schema --ignore-user-config --print --tools --safe-mode --output-format --json-schema' ;;\nesac\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)

        let status = await AssistantCLI.check(assistant, desktopURL: nil, candidates: [cli])

        #expect(status == .ready(cli))
        try FileManager.default.removeItem(at: cli)
        #expect(await AssistantCLI.check(assistant, desktopURL: nil, candidates: [cli]) == .missingCLI)
    }

    @Test(arguments: AutomationAssistant.allCases)
    func missingCLIBlocksAutomationEvenWhenVerificationIsOff(_ assistant: AutomationAssistant) async {
        let status = await AssistantCLI.check(assistant, desktopURL: .temporaryDirectory, candidates: [], requireCLI: false)
        #expect(status == .missingCLI)
    }

    @Test(arguments: AutomationAssistant.allCases)
    func loginFailureCannotBeTreatedAsReady(_ assistant: AutomationAssistant) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = folder.appending(path: assistant.rawValue)
        try Data("#!/bin/sh\ncase \"$*\" in\n 'login status'|'auth status') exit 1 ;;\n *) echo '--output-schema --ignore-user-config --tools --safe-mode --json-schema' ;;\nesac\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        #expect(await AssistantCLI.check(assistant, desktopURL: nil, candidates: [cli]) == .loginRequired(cli))
        #expect(await AssistantCLI.check(assistant, desktopURL: nil, candidates: [cli], requireCLI: false) == .loginRequired(cli))
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

    @MainActor @Test func setupAlwaysRequiresCLIRegardlessOfVerificationPreference() async {
        var requestedCLI = false
        let setup = AssistantSetupSession(assistant: .codex, requireCLI: false, probe: { _, requireCLI in
            requestedCLI = requireCLI
            return .missingCLI
        })
        #expect(await setup.verify() == false)
        #expect(requestedCLI)
        #expect(!setup.canCommit)
        #expect(!AssistantDependencyStatus.desktopOnly.isReady)
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

    @MainActor @Test func cancellingSelectionRejectsLateSuccessfulProbe() async {
        var resume: CheckedContinuation<AssistantDependencyStatus, Never>?
        let setup = AssistantSetupSession(assistant: .claude, requireCLI: true, probe: { _, _ in
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
    @MainActor @Test func failedInstallationAndMissingCLIKeepSelectionUncommitted() async {
        let setup = AssistantSetupSession(assistant: .codex, requireCLI: true,
            probe: { _, _ in .missingCLI }, install: { _ in throw AssistantCLI.SetupError.installationFailed })
        #expect(await setup.verify() == false)
        #expect(await setup.installAndVerify() == false)
        #expect(!setup.canCommit)
    }

    @MainActor @Test func cancellingInstallationRejectsLateInstallerSuccess() async {
        var resume: CheckedContinuation<Void, Error>?
        let setup = AssistantSetupSession(assistant: .claude, requireCLI: true,
            probe: { _, _ in .ready(URL(fileURLWithPath: "/example/cli")) },
            install: { _ in try await withCheckedThrowingContinuation { resume = $0 } })
        let task = Task { await setup.installAndVerify() }
        for _ in 0..<1000 where resume == nil { await Task.yield() }
        guard let resume else { Issue.record("Installation must be awaited"); return }
        setup.cancel()
        resume.resume()
        #expect(await task.value == false)
        #expect(!setup.canCommit)
    }

    @MainActor @Test func olderSuccessfulCheckCannotOverrideANewerFailedCheck() async {
        var completions: [CheckedContinuation<AssistantDependencyStatus, Never>] = []
        let setup = AssistantSetupSession(assistant: .codex, requireCLI: true, probe: { _, _ in
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

    @MainActor @Test func runtimeFailureAndRecoveryAreDetectedWithoutChangingSavedSelection() async throws {
        var status: AssistantDependencyStatus = .ready(URL(fileURLWithPath: "/example/cli"))
        let monitor = AssistantDependencyMonitor(probe: { _, requireCLI in requireCLI ? status : .desktopOnly })
        var recovered: Set<AutomationAssistant> = []
        monitor.onRecovered = { recovered.insert($0) }
        func refresh(requireCLI: Bool) async throws {
            monitor.refresh(requireCLI: requireCLI, force: true)
            for _ in 0..<1000 where monitor.isChecking { await Task.yield() }
            try #require(!monitor.isChecking)
        }
        try await refresh(requireCLI: true)
        #expect(monitor.available == Set(AutomationAssistant.allCases))
        status = .missingCLI
        try await refresh(requireCLI: true)
        #expect(monitor.available.isEmpty)
        status = .ready(URL(fileURLWithPath: "/example/cli"))
        try await refresh(requireCLI: true)
        #expect(recovered == Set(AutomationAssistant.allCases))
        status = .missingCLI
        try await refresh(requireCLI: false)
        #expect(monitor.available.isEmpty)
        try await refresh(requireCLI: true)
        #expect(monitor.available.isEmpty)
    }
}
