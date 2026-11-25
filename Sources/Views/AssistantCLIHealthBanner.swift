import SwiftUI

struct AssistantCLIHealthBanner: View {
    let monitor: TodoMonitorService
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ForEach(AutomationAssistant.allCases.filter { provider in
            provider == monitor.settings.automation.selectedAssistant || (monitor.cliHealth.hold(for: provider) != nil
                && monitor.assistantHandoffs.contains {
                    $0.key.assistant == provider && !$0.isObsoleteReminder
                        && $0.execution.map { $0.state != .succeeded } == true
                })
        }, id: \.rawValue) { provider in
            AssistantCLIProviderHealthBanner(monitor: monitor, assistant: provider)
        }
        if monitor.settings.incomingReviewFilterSettings.activeCriteria != nil,
           monitor.settings.automationGloballyEnabled, !monitor.checkingSelectedAssistant,
           !monitor.selectedAssistantReady {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.orange).accessibilityHidden(true)
                Text(.ReviewIntake.reviewIntakeUnavailable)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(.ReviewIntake.reviewIntakeAgentSettings) {
                    SettingsNavigation.shared.showCodingAgent(openSettings: { openSettings() })
                }
            }
            .font(.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1))
        }
    }
}

private struct AssistantCLIProviderHealthBanner: View {
    let monitor: TodoMonitorService
    @State private var checking = false
    @State private var actionFailed = false
    @Environment(\.openSettings) private var openSettings

    let assistant: AutomationAssistant
    private var hold: AssistantCLIHealthStore.Hold? { monitor.cliHealth.hold(for: assistant) }
    private var kind: AssistantCLIHealthIssue.Kind? {
        if case .loginRequired = monitor.assistantDependencies.statuses[assistant] { return .loginRequired }
        return hold?.issue.kind
    }
    private var executable: URL? {
        switch monitor.assistantDependencies.statuses[assistant] {
        case .ready(let url), .loginRequired(let url): url
        default: hold?.executable
        }
    }

    private func help(for kind: AssistantCLIHealthIssue.Kind) -> LocalizedStringResource {
        if kind == .loginRequired { return .CLIHealth.cliHealthLoginHelp }
        if hold?.limitRecheck?.exhausted == true { return .CLIHealth.cliHealthLimitChecksStopped }
        if let nextCheck = hold?.limitCheckAt {
            return .CLIHealth.cliHealthLimitCheckScheduled(nextCheck.formatted(date: .abbreviated, time: .shortened))
        }
        return .CLIHealth.cliHealthLimitHelp
    }

    var body: some View {
        if let kind {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: kind == .loginRequired ? "person.crop.circle.badge.exclamationmark" : "hourglass")
                    .foregroundStyle(.orange).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind == .loginRequired ? .CLIHealth.cliHealthLoginTitle(String(localized: assistant.displayName))
                        : .CLIHealth.cliHealthLimitTitle(String(localized: assistant.displayName))).fontWeight(.semibold)
                    Text(help(for: kind))
                        .foregroundStyle(.secondary)
                    if let reset = hold?.issue.reportedReset {
                        Text(.CLIHealth.cliHealthReset(reset.formatted(date: .abbreviated, time: .shortened)))
                    } else if let hint = hold?.issue.resetHint {
                        Text(.CLIHealth.cliHealthReset(hint))
                    }
                    if actionFailed {
                        Text(kind == .rateLimited ? .CLIHealth.cliHealthLimitStillUnavailable : .CLIHealth.cliHealthActionFailed)
                            .foregroundStyle(.red)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if kind == .loginRequired, let executable {
                    Button {
                        let provider = assistant
                        Task {
                            do { try await AssistantCLI.openLogin(provider, executable: executable) }
                            catch { actionFailed = true }
                        }
                    } label: { Text(.CLIHealth.cliHealthSignIn) }
                }
                Button { recheck() } label: {
                    Text(kind == .rateLimited ? .CLIHealth.cliHealthRetry : .CLIHealth.cliHealthRecheck)
                }
                .disabled(checking)
                Button { SettingsNavigation.shared.showCodingAgent(openSettings: { openSettings() }) } label: { Text(.Menu.menuActionSettings) }
            }
            .font(.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1))
        }
    }

    private func recheck() {
        let provider = assistant
        let expectedHold = hold
        checking = true
        actionFailed = false
        Task {
            defer { checking = false }
            let result = await AssistantCLI.detect(provider)
            guard case .ready(let executable) = result else {
                actionFailed = true
                monitor.assistantDependencies.refresh(force: true)
                return
            }
            if let expectedHold, expectedHold.limitRecheck?.exhausted == true {
                actionFailed = !(await monitor.assistantLimitRecovery.recheckExhaustedHold(provider,
                    executable: executable, expectedID: expectedHold.id))
                return
            }
            monitor.assistantDependencies.refresh(force: true)
            if let expectedHold, !monitor.cliHealth.clear(provider, expectedID: expectedHold.id) { return }
            monitor.assistantCLIHealthDidRecover(provider)
        }
    }
}
