import Foundation
import MergeTetherRemote

@MainActor enum RemoteMRDetailSupplement {
    static func append(to details: inout RemoteMRDetails, row: MergeRequestBoardSnapshot.Row,
                       monitor: TodoMonitorService, usage: AssistantUsageSnapshot?) {
        let item = row.evidenceMatchesCatalogContext ? row.item : row.displayItem
        guard let request = row.displayRequest, let host = monitor.glab.resolvedHost,
              let username = monitor.glab.currentUsername else { return }
        let target = MRAutomationScope.Target(host: host, username: username, projectID: request.projectID, iid: request.iid)
        let assessment = details.discussionFingerprint.flatMap {
            monitor.attention.authorFeedbackCoordinator?.assessment(for: request, fingerprint: $0)
        }
        applyFeedback(to: &details, assessment: assessment, authorID: request.author.id)
        let reasons = RemoteBoardAdapter.detail(item)
        if !reasons.isEmpty { details.reasons = [reasons] }
        let status = RemoteBoardAdapter.matchingMergeStatus(for: row, statuses: monitor.authoredMergeRequests.requests)
        let input = MREffectivePolicyPresentation.Input(request: request, target: target, settings: monitor.settings,
            assistantReady: monitor.availableAssistants.contains(monitor.settings.automation.assistant),
            readState: .init(catalogCurrent: monitor.attention.hasSyncedCurrentCatalog || monitor.authoredMergeRequests.hasSyncedCurrentCatalog,
                sameContext: row.evidenceMatchesCatalogContext, readFailed: monitor.lastError != nil || monitor.attention.hasError,
                rechecking: monitor.isLoading || monitor.attention.isLoading),
            submission: status?.submissionState ?? .none,
            cliHold: monitor.cliHealth.hold(for: monitor.settings.automation.assistant)?.issue.kind)
        details.policy = MREffectivePolicyPresentation(input: input).clauses.map { String(localized: message($0)) }
        if let feedback = item.authorFeedbackStatus, feedback.head == request.sha,
           feedback.semanticContextFingerprint == request.semanticContextFingerprint,
           feedback.fingerprint == details.discussionFingerprint {
            let phase: LocalizedStringResource = switch feedback.phase {
            case .checking: .AuthorFeedback.authorFeedbackChecking
            case .failed: .AuthorFeedback.authorFeedbackFailed
            case .waitingPublication: .AuthorFeedback.authorFeedbackWaitingPublication(feedback.pendingDraftCount)
            case .complete: .AuthorFeedback.authorFeedbackReady
            }
            details.feedback.append(.init(label: String(localized: .AuthorFeedback.authorFeedbackTitle), value: String(localized: phase)))
            for finding in feedback.findings {
                let fallback: LocalizedStringResource = switch finding.state {
                case .waitingAcceptance: .AuthorFeedback.authorFeedbackWaitingAcceptance(finding.waitingForReviewers.map { "@" + $0 }.joined(separator: ", "))
                case .needsChanges: .AuthorFeedback.authorFeedbackNeedsChanges
                case .needsVerification: .AuthorFeedback.authorFeedbackNeedsVerification
                case .needsReply: .AuthorFeedback.authorFeedbackReplyNeeded
                case .disabled: .AuthorFeedback.authorFeedbackDisabled
                case .waitingPublication: .AuthorFeedback.authorFeedbackWaitingPublication(item.draftCount)
                case .ready: .AuthorFeedback.authorFeedbackReady
                }
                let clean = feedback.phase == .complete && feedback.pendingDraftCount == 0
                    && feedback.replyNoteIDs.isEmpty && feedback.followUpNoteIDs.isEmpty && feedback.codeReviewRequests.isEmpty
                let state = clean ? finding.resolutionWaitMessage ?? fallback : fallback
                var components = URLComponents(url: request.webURL, resolvingAgainstBaseURL: false)
                components?.fragment = "note_\(finding.sourceNoteID ?? finding.id)"
                details.feedback.append(.init(label: "@" + finding.reviewerUsername,
                    value: ([String(localized: state), AgentExplanation.summary(finding.summary), finding.reason].compactMap { $0 })
                        .map(GlabService.redactWorkflowEvidence).joined(separator: "\n\n"), url: components?.url))
            }
            for question in feedback.codeReviewRequests {
                details.feedback.append(.init(label: String(localized: .AuthorFeedback.authorFeedbackCodeReviewQuestion),
                    value: GlabService.redactWorkflowEvidence(question.summary + "\n\n" + question.question)))
            }
        }
        for decision in monitor.settings.feedbackSuggestionDecisions.entries(for: target) {
            details.feedback.append(.init(label: String(localized: .FeedbackSuggestions.feedbackSuggestionsIgnored),
                value: decision.concernSummary + "\n\n" + decision.concernReason))
        }
        let history = MRAutomationHistory(target: target, handoffs: monitor.assistantHandoffs,
            workflows: monitor.authoredMergeRequests.workflow.entries, events: monitor.settings.automationEvents)
        details.activity = history.entries.prefix(30).map { entry in
            switch entry.source {
            case .job(let job, let attempt):
                return .init(id: entry.id, title: String(localized: .AutomationHistory.automationHistoryRun(attempt)) + " · " + job.title,
                    status: jobStatus(job.execution?.state),
                    summary: (job.execution?.attentionExplanation ?? job.execution?.summary ?? job.execution?.error).map(GlabService.redactWorkflowEvidence),
                    createdAt: entry.createdAt, head: job.expectedHeadSHA)
            case .workflow(let workflow):
                return .init(id: entry.id, title: String(localized: workflow.event.kind.displayLabel),
                    status: workflowStatus(workflow.state), summary: workflow.summary.map(GlabService.redactWorkflowEvidence), createdAt: entry.createdAt)
            case .event(let event):
                return .init(id: entry.id, title: String(localized: eventTitle(event.action)),
                    status: eventStatus(event.state), summary: event.message.map(GlabService.redactWorkflowEvidence), createdAt: entry.createdAt)
            }
        }
        if history.entries.count > 30 { details.truncated = true }
        details.usage = usage.map { snapshot in
            let identity = AssistantUsageMergeRequest(host: host, username: username, projectID: request.projectID, iid: request.iid)
            var overall = AssistantUsageTotal()
            let roles = AssistantUsageRole.allCases.map { role in
                let total = snapshot.total(for: identity, role: role)
                overall.add(total)
                let title: LocalizedStringResource = role == .verifier ? .AssistantUsage.assistantUsageMRVerifier : .AssistantUsage.assistantUsageMRReviewer
                var lines = [amount(total), String(localized: .AssistantUsage.assistantUsageMRAgentRequests(total.runs))]
                if total.unknownCostRuns > 0 { lines.append(String(localized: .AssistantUsage.assistantUsageMRUnknownRuns(total.unknownCostRuns))) }
                if total.runs > 0 {
                    if total.inputTokens > 0 || total.outputTokens > 0 || total.tokensUnavailable != true {
                        lines.append(String(localized: .AssistantUsage.assistantUsageTokens(total.inputTokens, total.cachedInputTokens, total.outputTokens)))
                        if total.tokensUnavailable == true { lines.append(String(localized: .AssistantUsage.assistantUsageTokensPartial)) }
                    } else { lines.append(String(localized: .AssistantUsage.assistantUsageTokensUnavailable)) }
                }
                return RemoteDetailField(label: String(localized: title), value: lines.joined(separator: "\n"))
            }
            return roles + [.init(label: String(localized: .AssistantUsage.assistantUsageMRLifetimeCost),
                value: amount(overall) + "\n\n" + String(localized: .AssistantUsage.assistantUsageMRHistoryHelp))]
        }
    }

    static func applyFeedback(to details: inout RemoteMRDetails, assessment: ReReviewAssessment?, authorID: Int) {
        details.threads = details.threads.map { threads in
            threads.map { original in
                var thread = original
                let feedback = MRDiscussionSnapshot.Feedback.summarize(
                    notes: thread.notes.map { (Int($0.id), $0.authorID) }, assessment: assessment, authorID: authorID)
                thread.feedback = .init(rawValue: feedback.rawValue) ?? .needsVerification
                return thread
            }
        }
    }

    @discardableResult static func scheduleDisplayOrigins(in details: RemoteMRDetails, request: GitLabMergeRequest,
        monitor: TodoMonitorService, accountRevision: UInt64) -> Task<Void, Never>? {
        guard let coordinator = monitor.attention.displayAIOriginCoordinator else { return nil }
        return scheduleDisplayOrigins(in: details, request: request, glab: monitor.glab,
            coordinator: coordinator, accountRevision: accountRevision)
    }

    @discardableResult static func scheduleDisplayOrigins(in details: RemoteMRDetails, request: GitLabMergeRequest,
        glab: GlabService, coordinator: AICommentDisplayCoordinator, accountRevision: UInt64) -> Task<Void, Never>? {
        guard coordinator.permitsSourceRead(request: request, accountRevision: accountRevision),
              let host = glab.resolvedHost, let username = glab.currentUsername,
              let context = RemoteBoardAdapter.contextRevision(request) else { return nil }
        if details.truncated || details.threads?.contains(where: \.truncated) == true {
            return Task {
                do {
                    @MainActor func current(_ live: GitLabMergeRequest) -> Bool {
                        coordinator.permitsSourceRead(request: live, accountRevision: accountRevision)
                            && glab.resolvedHost == host && glab.currentUsername == username
                            && RemoteBoardAdapter.contextRevision(live) == context
                    }
                    let live = try await glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
                    guard current(live) else { return }
                    let action = coordinator.sourceAssessmentDirectory
                    let store = MRDiscussionStore(assessmentDirectory: action,
                        provenanceDirectory: action.deletingLastPathComponent().appending(path: "display-comment-origins"),
                        displayAssessmentDirectory: coordinator.displayDirectory)
                    await store.refresh(target: .init(host: host, username: username, projectID: request.projectID,
                        iid: request.iid, url: request.webURL), glab: glab)
                    guard store.hasLoaded, !store.hasError, current(live) else { return }
                    let checked = try await glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
                    guard current(checked) else { return }
                    await coordinator.schedule(request: checked, notes: store.discussions.flatMap(\.notes),
                        knownNoteIDs: Set(store.origins.keys))
                } catch {}
            }
        }
        guard let threads = details.threads else { return nil }
        let source = threads.flatMap(\.notes)
        let notes: [GitLabMergeRequestDiscussion.Note] = source.compactMap { note in
            guard let id = Int(note.id), let authorID = note.authorID else { return nil }
            return .init(id: id, author: .init(id: authorID, username: note.username, name: note.author), system: false,
                resolvable: nil, resolved: nil, resolvedBy: nil, body: note.body)
        }
        let known = Set(source.filter { $0.origin != nil }.compactMap { Int($0.id) })
        return Task {
            guard glab.accountRevision == accountRevision else { return }
            await coordinator.schedule(request: request, notes: notes, knownNoteIDs: known)
        }
    }

    private static func amount(_ total: AssistantUsageTotal) -> String {
        guard total.runs > 0 else { return String(localized: .AssistantUsage.assistantUsageNoActivity) }
        guard total.costUnavailable != true, total.estimatedUSD > 0 || total.unknownCostRuns < total.runs else {
            return String(localized: .AssistantUsage.assistantUsageCostUnavailable)
        }
        let value = total.estimatedUSD.formatted(.currency(code: "USD").precision(.fractionLength(8)))
        return String(localized: .AssistantUsage.assistantUsageEstimate(value))
    }

    private static func workflowStatus(_ state: MergeWorkflowActivityState) -> String {
        let label: LocalizedStringResource = switch state {
        case .preview: .Menu.menuWorkflowStatePreview
        case .notified: .Menu.menuWorkflowStateNotified
        case .awaitingPipelineHandoff: .Menu.menuWorkflowStateAwaitingPipelineHandoff
        case .alreadyRegistered: .Menu.menuWorkflowStateAlreadyRegistered
        case .queued: .Menu.menuWorkflowStateQueued
        case .running: .Menu.menuWorkflowStateRunning
        case .waitingForAssistant: .Menu.menuWorkflowStateWaitingForAssistant
        case .completed: .Menu.menuWorkflowStateCompleted
        case .failed: .Menu.menuWorkflowStateFailed
        case .skipped: .Menu.menuWorkflowStateSkipped
        }
        return String(localized: label)
    }

    private static func jobStatus(_ state: AssistantJobExecution.State?) -> String {
        let label: LocalizedStringResource = switch state {
        case .queued: .AssistantJobs.assistantJobsQueued
        case .running: .AssistantJobs.assistantJobsRunning
        case .succeeded: .AssistantJobs.assistantJobsSucceeded
        case .blocked: .AssistantJobs.assistantJobsBlocked
        case .failed: .AssistantJobs.assistantJobsFailed
        case .cancelled: .AssistantJobs.assistantJobsCancelled
        case .interrupted: .AssistantJobs.assistantJobsInterrupted
        case nil: .AssistantJobs.assistantJobsLegacy
        }
        return String(localized: label)
    }
    private static func eventTitle(_ action: MRAutomationEvent.Action) -> LocalizedStringResource {
        switch action {
        case .retry: .AutomationHistory.automationHistoryActionRetry
        case .review: .AutomationHistory.automationHistoryActionReview
        case .followUp: .AutomationHistory.automationHistoryActionFollowUp
        case .draftReply: .AutomationHistory.automationHistoryActionDraftReply
        case .verification: .AutomationHistory.automationHistoryActionVerification
        case .feedbackDecision: .FeedbackDecisionActions.historyTitle
        case .pipeline: .Settings.settingsAutomationWorkflowPipelineFailure
        case .conflict: .AutomationHistory.automationHistoryActionConflict
        case .refresh: .AutomationHistory.automationHistoryActionRefresh
        }
    }
    private static func eventStatus(_ state: MRAutomationEvent.State) -> String {
        let label: LocalizedStringResource = switch state {
        case .requested: .AutomationHistory.automationHistoryStateRequested
        case .queued: .AssistantJobs.assistantJobsQueued
        case .failed: .AssistantJobs.assistantJobsFailed
        case .completed: .Menu.menuWorkflowStateCompleted
        case .blocked: .AssistantJobs.assistantJobsBlocked
        }
        return String(localized: label)
    }
    private static func message(_ clause: MREffectivePolicyPresentation.Clause) -> LocalizedStringResource {
        switch clause {
        case .publicationAfterChecks(let mode):
            switch mode {
            case .all: .EffectivePolicy.policyPublicationAll
            case .aiReplies: .EffectivePolicy.policyPublicationAi
            case .filtered: .EffectivePolicy.policyPublicationFiltered
            case .manual: .EffectivePolicy.policyPublicationManual
            }
        case .publicationManual: .EffectivePolicy.policyPublicationManual
        case .mergeManual: .EffectivePolicy.policyMergeManual
        case .mergeAfterChecks: .EffectivePolicy.policyMergeChecks
        case .approvalManual: .EffectivePolicy.policyApprovalManual
        case .approvalAfterChecks: .EffectivePolicy.policyApprovalChecks
        case .deliveryManual: .EffectivePolicy.policyDeliveryManual
        case .draftPaused: .EffectivePolicy.policyDraftPaused
        case .scopePaused: .EffectivePolicy.policyScopePaused
        case .automationOff: .EffectivePolicy.policyOff
        case .automationDecisionRequired: .EffectivePolicy.policyAutomationDecision
        case .privateWork: .AutomationProfiles.privateWork
        case .savedDataHold: .EffectivePolicy.policySavedData
        case .requiresVerification: .EffectivePolicy.policyVerification
        case .assistantUnavailable: .EffectivePolicy.policyAssistant
        case .loginRequired: .EffectivePolicy.policyLogin
        case .rateLimited: .EffectivePolicy.policyLimit
        case .finishCommentReview: .EffectivePolicy.policyCommentReview
        case .mergeSubmission(let state): state.title ?? .EffectivePolicy.policyVerification
        }
    }
}
