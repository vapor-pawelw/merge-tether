import SwiftUI

struct AuthorFeedbackView: View {
    let item: MergeRequestAttentionMonitor.Item
    let monitor: TodoMonitorService
    var citationContext: MRCommentCitation.Context?
    var sourceLoading = false
    var decisionUpdating = false
    var onIgnoreSuggestion: ((MRCommentCitation, String, String) -> Void)?
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
                    case .complete: EmptyView()
                    }
                    if status.phase == .complete || status.phase == .waitingPublication {
                        let findings = status.primaryFinding.map { primary in
                            [primary] + status.findings.filter { $0.id != primary.id }
                        } ?? status.findings
                        ForEach(findings) { finding in
                            let source = citationContext?.finding(finding, status: status)
                            VStack(alignment: .leading, spacing: 4) {
                                if source?.id != finding.id, let url = noteURL(finding.id) {
                                    Link(destination: url) {
                                        Text(.FeedbackSuggestions.feedbackSuggestionsThreadOpenedBy("@" + finding.reviewerUsername))
                                            .fontWeight(.medium)
                                    }
                                }
                                Text(message(finding))
                                if status.replyNoteIDs.contains(finding.id), finding.state != .needsReply {
                                    Text(.AuthorFeedback.authorFeedbackReplyNeeded)
                                }
                                if let summary = AgentExplanation.summary(finding.summary) { Text(verbatim: summary).textSelection(.enabled) }
                                if let reason = finding.reason { AgentDiagnosticDetails(reason: reason) }
                                sourceEvidence(for: finding, status: status, source: source)
                            }
                        }
                        ForEach(status.codeReviewRequests) { question in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(.AuthorFeedback.authorFeedbackCodeReviewQuestion).fontWeight(.medium)
                                Text(verbatim: question.summary).textSelection(.enabled)
                                AgentDiagnosticDetails(reason: question.question)
                                if let url = noteURL(question.sourceNoteID) {
                                    Link(destination: url) { Text(.AuthorFeedback.authorFeedbackCodeReviewContext) }
                                }
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

    @ViewBuilder
    private func sourceEvidence(for finding: AuthorFeedbackPolicy.Finding, status: AuthorFeedbackStatus,
                                source: MRCommentCitation?) -> some View {
        if let source {
            MRCommentCitationView(citation: source, relation: .FeedbackSuggestions.feedbackSuggestionsSourceAssessment)
            if let onIgnoreSuggestion, let reason = finding.reason,
               !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               finding.state == .needsChanges || finding.state == .needsVerification
                || status.followUpNoteIDs.contains(source.id) || status.replyNoteIDs.contains(source.id) {
                Button {
                    onIgnoreSuggestion(source, AgentExplanation.summary(finding.summary) ?? reason, reason)
                } label: { Text(.FeedbackSuggestions.feedbackSuggestionsIgnore) }
                    .buttonStyle(.plain).foregroundStyle(.orange).disabled(decisionUpdating)
            }
        } else {
            Text(sourceLoading ? .FeedbackSuggestions.feedbackSuggestionsSourceLoading : .FeedbackSuggestions.feedbackSuggestionsSourceUnavailable)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func message(_ finding: AuthorFeedbackPolicy.Finding) -> LocalizedStringResource {
        switch finding.state {
        case .waitingAcceptance: .AuthorFeedback.authorFeedbackWaitingAcceptance(finding.waitingForReviewers.map { "@" + $0 }.joined(separator: ", "))
        case .needsChanges: .AuthorFeedback.authorFeedbackNeedsChanges
        case .needsVerification: .AuthorFeedback.authorFeedbackNeedsVerification
        case .needsReply: .AuthorFeedback.authorFeedbackReplyNeeded
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

    private func noteURL(_ id: Int) -> URL? {
        guard id > 0 else { return nil }
        var components = URLComponents(url: item.url, resolvingAgainstBaseURL: false)
        components?.fragment = "note_\(id)"
        return components?.url
    }
}
