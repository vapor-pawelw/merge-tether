import SwiftUI
import MergeTetherRemote

struct AuthorFeedbackView: View {
    let item: MergeRequestAttentionMonitor.ItemPresentation
    let monitor: TodoMonitorService
    /// Inside Details' Next step the surrounding disclosure already provides the title and frame.
    var embedded = false
    var citationContext: MRCommentCitation.Context?
    var sourceLoading = false
    var decisionUpdating = false
    var onIgnoreSuggestion: ((MRCommentCitation, String, String) -> Void)?
    @State private var starting = false

    var body: some View {
        if let status = item.authorFeedbackStatus {
            if embedded {
                content(status)
            } else {
                GroupBox { content(status).padding(8) } label: { Text(.AuthorFeedback.authorFeedbackTitle).font(.headline) }
            }
        }
    }

    private func content(_ status: AuthorFeedbackStatus) -> some View {
                VStack(alignment: .leading, spacing: 14) {
                    switch status.phase {
                    case .checking:
                        MRActivityStatus(status: MRActivity.agentStatus(.AuthorFeedback.authorFeedbackChecking,
                            assistant: monitor.settings.automation.assistant), startedAt: nil, effect: .aiCheck)
                    case .failed: Text(.AuthorFeedback.authorFeedbackFailed).foregroundStyle(.orange)
                    case .waitingPublication: Text(.AuthorFeedback.authorFeedbackWaitingPublication(status.pendingDraftCount))
                    case .complete: EmptyView()
                    }
                    if status.phase == .complete || status.phase == .waitingPublication {
                        let findings = status.displayFindings
                        ForEach(Array(findings.enumerated()), id: \.element.id) { index, finding in
                            let source = citationContext?.finding(finding, status: status)
                            if index > 0 { Divider() }
                            VStack(alignment: .leading, spacing: 6) {
                                if source?.id != finding.id, let url = noteURL(finding.id) {
                                    let reviewer = item.personDirectory.person(username: finding.reviewerUsername)
                                    HStack(spacing: 8) {
                                        if let message = RemotePeopleMessage(.FeedbackSuggestions.feedbackSuggestionsThreadOpenedBy, people: [reviewer]) {
                                            PeopleMessageLabel(message: message).fontWeight(.medium)
                                        }
                                        Spacer(minLength: 4)
                                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                                            .buttonStyle(.borderless)
                                            .accessibilityLabel(Text(.MRDiscussions.mrDiscussionsOpenInGitLab))
                                            .help(Text(.MRDiscussions.mrDiscussionsOpenInGitLab))
                                    }
                                }
                                // One headline per finding; the explanation and evidence follow in quieter text.
                                Label {
                                    Group {
                                        if let message = peopleMessage(finding) { PeopleMessageLabel(message: message) }
                                        else { Text(message(finding)) }
                                    }.font(.callout.weight(.medium))
                                } icon: {
                                    Image(systemName: symbol(finding.state)).foregroundStyle(tint(finding.state))
                                }
                                .labelStyle(BoardCardStatusLabelStyle())
                                Group {
                                    if status.replyNoteIDs.contains(finding.id), finding.state != .needsReply {
                                        Text(.AuthorFeedback.authorFeedbackReplyNeeded)
                                    }
                                    if let summary = AgentExplanation.summary(finding.summary) {
                                        Text(verbatim: summary).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                    if let decision = finding.manualDecision {
                                        manualDecision(decision)
                                    } else if let reason = finding.reason { AgentDiagnosticDetails(reason: reason) }
                                    sourceEvidence(for: finding, status: status, source: source)
                                }
                                .padding(.leading, 20)
                            }
                            // No vertical fixedSize here: it measured collapsed disclosures and let
                            // expanded technical details overlap the following rows.
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
                    if !status.followUpNoteIDs.isEmpty, let request = item.authoredRequest {
                        Button {
                            guard confirmMRAction(.handleFeedback, title: .AuthorFeedback.authorFeedbackHandle, monitor: monitor) else { return }
                            starting = true
                            Task {
                                defer { starting = false }
                                await monitor.runVerifiedAuthorFeedback(request: request,
                                    noteIDs: status.followUpNoteIDs, fingerprint: status.fingerprint)
                            }
                        } label: { MRActionLabel(title: .AuthorFeedback.authorFeedbackHandle, cta: .handleFeedback) }
                        .disabled(starting)
                        .mrActionHelp(.handleFeedback)
                    }
                    if !status.followUpNoteIDs.isEmpty && !automaticFollowUp {
                        Text(.AuthorFeedback.authorFeedbackAutoFollowUpOff).foregroundStyle(.secondary)
                    }
                    if !status.followUpNoteIDs.isEmpty && !monitor.settings.automation.allowFollowUpPush {
                        Text(.AuthorFeedback.authorFeedbackPushOff).foregroundStyle(.secondary)
                    }
                }
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func manualDecision(_ decision: ReReviewAssessment.Note.ManualDecision) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            decisionSection(.AuthorFeedback.authorFeedbackDecisionContext, decision.context)
            decisionSection(.AuthorFeedback.authorFeedbackDecisionVerified, decision.verifiedFacts)
            decisionSection(.AuthorFeedback.authorFeedbackDecisionMissing, decision.missingEvidence)
            decisionSection(.AuthorFeedback.authorFeedbackDecisionQuestion, decision.question)
            decisionSection(.AuthorFeedback.authorFeedbackDecisionImpact, decision.mergeImpact)
        }
    }

    private func decisionSection(_ title: LocalizedStringResource, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.medium)
            Text(verbatim: text).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func symbol(_ state: AuthorFeedbackPolicy.State) -> String {
        switch state {
        case .ready: "checkmark.circle"
        case .waitingAcceptance, .waitingPublication: "clock"
        case .disabled: "pause.circle"
        case .needsChanges, .needsVerification, .needsReply: "exclamationmark.circle"
        }
    }

    private func tint(_ state: AuthorFeedbackPolicy.State) -> Color {
        switch state {
        case .ready: .green
        case .waitingAcceptance, .waitingPublication, .disabled: .secondary
        case .needsChanges, .needsVerification, .needsReply: .orange
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
                    .mrActionHelp(.ignoreSuggestion)
            }
        } else {
            Text(sourceLoading ? .FeedbackSuggestions.feedbackSuggestionsSourceLoading : .FeedbackSuggestions.feedbackSuggestionsSourceUnavailable)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func peopleMessage(_ finding: AuthorFeedbackPolicy.Finding) -> RemotePeopleMessage? {
        guard finding.manualDecision == nil else { return nil }
        let people = item.personDirectory
        if let status = item.authorFeedbackStatus, status.phase == .complete,
           status.pendingDraftCount == 0, item.draftCount == 0, item.drafts.isEmpty,
           status.replyNoteIDs.isEmpty, status.followUpNoteIDs.isEmpty, status.codeReviewRequests.isEmpty,
           !sourceLoading, citationContext?.finding(finding, status: status) != nil,
           let message = finding.resolutionWaitPeopleMessage(people: people) {
            return message
        }
        return finding.state == .waitingAcceptance ? finding.waitingAcceptancePeopleMessage(people: people) : nil
    }

    private func message(_ finding: AuthorFeedbackPolicy.Finding) -> LocalizedStringResource {
        if finding.manualDecision != nil { return .AuthorFeedback.authorFeedbackManualDecision }
        return switch finding.state {
        case .waitingAcceptance: .AuthorFeedback.authorFeedbackWaitingAcceptance
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
        let configuration = monitor.settings.configuredAutomation
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
