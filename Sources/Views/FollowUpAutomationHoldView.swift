import SwiftUI

struct FollowUpAutomationHoldView: View {
    let row: MergeRequestBoardSnapshot.Row
    let monitor: TodoMonitorService
    var showsRetryRequired = true
    @Environment(\.openSettings) private var openSettings

    private var reason: MRFollowUpAutomationHold? {
        let item = row.item
        guard item.isAuthored, let request = item.mergeRequest,
              row.latestJob?.operationalExecution?.state != .running,
              item.authorFeedbackStatus?.phase != .checking, item.reReviewReadiness != .checking,
              !item.draftProofRecoveryChecking, !row.isCheckingReadOnlyReconciliation,
              !row.attentionIntents.contains(where: { $0.kind == .followUp && $0.state == .running }),
              item.needsDiscussion || item.needsChanges || !item.feedback.isEmpty
                || item.authorFeedbackStatus?.needsAttention == true
                || row.attentionIntents.contains(where: { $0.kind == .followUp }),
              let target = monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url)
        else { return nil }
        let provider = row.latestJob?.key.assistant ?? monitor.settings.automation.assistant
        if row.latestJob?.execution?.state == .queued, let issue = monitor.cliHealth.hold(for: provider)?.issue {
            return issue.kind == .loginRequired ? .loginRequired : .rateLimited
        }
        if let hold = monitor.settings.configuredAutomation.followUpAutomationHold(for: request, target: target,
            ignored: monitor.settings.ignoredMergeRequests.contains(target),
            requiresTodoRouting: row.attentionIntents.contains(where: { $0.kind == .followUp })) { return hold }
        if let issue = monitor.cliHealth.hold(for: provider)?.issue {
            return issue.kind == .loginRequired ? .loginRequired : .rateLimited
        }
        if !monitor.selectedAssistantReady, !monitor.checkingSelectedAssistant { return .assistantUnavailable }
        if (row.stoppedJobNeedsAttention && row.latestJob?.workflow == .followUp)
            || row.attentionIntents.contains(where: { $0.kind == .followUp && $0.state == .failed }) {
            return .retryRequired
        }
        return nil
    }

    var body: some View {
        if let reason, reason != .retryRequired || showsRetryRequired {
            VStack(alignment: .leading, spacing: 6) {
                Label { Text(.AutomationHold.automationHoldTitle) } icon: { Image(systemName: "pause.fill") }
                    .font(.subheadline.weight(.medium))
                Text(reason.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button {
                    if reason == .assistantUnavailable || reason == .loginRequired {
                        SettingsNavigation.shared.showCodingAgent(openSettings: { openSettings() },
                            onConfigured: { Task { await monitor.refreshFromGitLab(for: row.id) } })
                    } else { openSettings() }
                } label: {
                    Text(reason == .assistantUnavailable || reason == .loginRequired
                        ? .Settings.settingsAssistantResumeAction : .Menu.menuActionSettings)
                }
                    .buttonStyle(.link).font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
