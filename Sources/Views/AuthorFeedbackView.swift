import SwiftUI

struct AuthorFeedbackView: View {
    let item: MergeRequestAttentionMonitor.Item
    let monitor: TodoMonitorService
    @State private var starting = false

    var body: some View {
        if let status = item.authorFeedbackStatus {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    switch status.phase {
                    case .checking:
                        HStack { ProgressView().controlSize(.small); Text(.AuthorFeedback.authorFeedbackChecking) }
                    case .failed: Text(.AuthorFeedback.authorFeedbackFailed).foregroundStyle(.orange)
                    case .waitingPublication: Text(.AuthorFeedback.authorFeedbackWaitingPublication(status.pendingDraftCount))
                    case .complete:
                        ForEach(status.findings) { finding in
                            VStack(alignment: .leading, spacing: 4) {
                                Link(destination: noteURL(finding.id)) {
                                    Text(verbatim: "@\(finding.reviewerUsername)").fontWeight(.medium)
                                }
                                Text(message(finding))
                                if status.replyNoteIDs.contains(finding.id) { Text(.AuthorFeedback.authorFeedbackReplyNeeded) }
                                if let reason = finding.reason { Text(verbatim: reason).foregroundStyle(.secondary).textSelection(.enabled) }
                            }
                        }
                    }
                    HStack {
                        Button { monitor.attention.retryAuthorFeedback(item.id) } label: { Text(.AuthorFeedback.authorFeedbackRecheck) }
                        if !status.followUpNoteIDs.isEmpty, let request = item.authoredRequest {
                            Button {
                                starting = true
                                Task {
                                    defer { starting = false }
                                    await monitor.runVerifiedAuthorFeedback(request: request,
                                        noteIDs: status.followUpNoteIDs, fingerprint: status.fingerprint)
                                }
                            } label: { Text(.AuthorFeedback.authorFeedbackHandle) }
                            .disabled(starting)
                        }
                    }
                    if !status.followUpNoteIDs.isEmpty && !automaticFollowUp {
                        Text(.AuthorFeedback.authorFeedbackAutoFollowUpOff).foregroundStyle(.secondary)
                    }
                    if !status.followUpNoteIDs.isEmpty && !monitor.settings.automation.allowFollowUpPush {
                        Text(.AuthorFeedback.authorFeedbackPushOff).foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } label: { Text(.AuthorFeedback.authorFeedbackTitle).font(.headline) }
        }
    }

    private func message(_ finding: AuthorFeedbackPolicy.Finding) -> LocalizedStringResource {
        switch finding.state {
        case .waitingAcceptance: .AuthorFeedback.authorFeedbackWaitingAcceptance(finding.waitingForReviewers.map { "@" + $0 }.joined(separator: ", "))
        case .needsChanges: .AuthorFeedback.authorFeedbackNeedsChanges
        case .needsVerification: .AuthorFeedback.authorFeedbackNeedsVerification
        case .disabled: .AuthorFeedback.authorFeedbackDisabled
        case .waitingPublication: .AuthorFeedback.authorFeedbackWaitingPublication(item.draftCount)
        case .ready: .AuthorFeedback.authorFeedbackReady
        }
    }

    private var automaticFollowUp: Bool {
        guard let request = item.authoredRequest else { return false }
        let configuration = monitor.settings.automation
        let workflow = configuration.workflowRules[.newDiscussion]
        return configuration.authorFeedback.isEnabled || (workflow.mode == .assistant && workflow.includes(request))
    }

    private func noteURL(_ id: Int) -> URL {
        var components = URLComponents(url: item.url, resolvingAgainstBaseURL: false)
        components?.fragment = "note_\(id)"
        return components?.url ?? item.url
    }
}
