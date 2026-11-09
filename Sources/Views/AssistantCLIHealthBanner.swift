import SwiftUI

struct AssistantCLIHealthBanner: View {
    let monitor: TodoMonitorService
    var body: some View {
        ForEach(AutomationAssistant.allCases.filter { provider in
            provider == monitor.settings.automation.assistant || (monitor.cliHealth.hold(for: provider) != nil
                && monitor.assistantHandoffs.contains {
                    $0.key.assistant == provider && !$0.isObsoleteReminder
                        && $0.execution.map { $0.state != .succeeded } == true
                })
        }, id: \.rawValue) { provider in
            AssistantCLIProviderHealthBanner(monitor: monitor, assistant: provider)
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

    var body: some View {
        if let kind {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: kind == .loginRequired ? "person.crop.circle.badge.exclamationmark" : "hourglass")
                    .foregroundStyle(.orange).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind == .loginRequired ? .CLIHealth.cliHealthLoginTitle(String(localized: assistant.displayName))
                        : .CLIHealth.cliHealthLimitTitle(String(localized: assistant.displayName))).fontWeight(.semibold)
                    Text(kind == .loginRequired ? .CLIHealth.cliHealthLoginHelp : .CLIHealth.cliHealthLimitHelp)
                        .foregroundStyle(.secondary)
                    if let reset = hold?.issue.resetsAt {
                        Text(.CLIHealth.cliHealthReset(reset.formatted(date: .abbreviated, time: .shortened)))
                    } else if let hint = hold?.issue.resetHint {
                        Text(.CLIHealth.cliHealthReset(hint))
                    }
                    if actionFailed { Text(.CLIHealth.cliHealthActionFailed).foregroundStyle(.red) }
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
                Button { openSettings() } label: { Text(.Menu.menuActionSettings) }
            }
            .font(.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1))
        }
    }

    private func recheck() {
        let provider = assistant
        let expectedID = hold?.id
        checking = true
        actionFailed = false
        Task {
            defer { checking = false }
            let result = await AssistantCLI.detect(provider, requireCLI: true)
            guard result.isReady else { actionFailed = true; monitor.assistantDependencies.refresh(force: true); return }
            // Explicit retry releases unstarted queued work. Failed runs are never replayed automatically.
            if let expectedID { _ = monitor.cliHealth.clear(provider, expectedID: expectedID) }
            monitor.assistantDependencies.refresh(force: true)
            AssistantAutomationRunner.resumePendingJobs()
        }
    }
}
