import Foundation

struct AgentQuestionContext: Encodable, Sendable {
    struct Settings: Encodable, Sendable {
        let profile: String?
        let decision: String
        let automationOn: Bool
        let automaticPublicActionsAllowed: Bool
        let autoMerge: Bool
        let autoMergeWithOtherAssignees: Bool
        let treatAssignedMergeRequestsAsOwn: Bool
        let publicationMode: String
        let autoApproval: Bool
        let followUpPush: Bool
        let conflictPush: Bool
        let autoReReview: Bool
        let autoClaimPipelineFailures: Bool
    }

    struct Card: Encodable, Sendable {
        let lane: String
        let project: String?
        let iid: Int
        let title: String
        let url: URL
        let state: String?
        let draft: Bool
        let pipeline: String?
        let pipelineCheckedAt: Date?
        let approvalsCompleted: Int?
        let approvalsRequired: Int?
        let unresolvedDiscussions: Bool?
        let privateDrafts: Int
        let effectiveRules: [String]
        let autoMergeConfigured: Bool
        let eligibleForAutoMerge: Bool?
        let mergeBlockers: [String]?
        let mergeSubmission: String?
        let gitLabMergeStatus: String?
        let gitLabHasConflicts: Bool?
        let evidenceCurrent: Bool
    }

    struct Detail: Encodable, Sendable {
        struct Event: Encodable, Sendable {
            let date: Date
            let source: String
            let title: String
            let status: String?
            let reason: String?
            let currentHead: Bool?
        }
        let iid: Int
        let url: URL
        let author: String?
        let assignees: [String]?
        let currentUserIsAuthor: Bool?
        let currentUserIsAssignee: Bool?
        let visibleReason: String?
        let sourceBranch: String?
        let targetBranch: String?
        let gitLabMergeStatus: String?
        let gitLabHasConflicts: Bool?
        let recordedConflictWarning: Bool
        let evidenceMatchesCurrentCatalog: Bool
        let followUpPolicyHold: String?
        let eventLog: [Event]
    }

    let capturedAt: Date
    let lastInboxRefresh: Date?
    let lastAuthoredRefresh: Date?
    let boardState: String
    let settings: Settings
    let cards: [Card]
    let omittedCards: Int
}

@MainActor extension TodoMonitorService {
    func agentQuestionContext() -> AgentQuestionContext {
        let board = boardSnapshot
        let configured = settings.configuredAutomation
        let options = AgentQuestionContext.Settings(profile: configured.baselinePreset?.rawValue,
            decision: configured.packageDecision.rawValue, automationOn: settings.automationGloballyEnabled,
            automaticPublicActionsAllowed: self.settings.automaticPublicWritesAllowed,
            autoMerge: configured.autoMergeEnabled, autoMergeWithOtherAssignees: configured.autoMergeWithOtherAssignees,
            treatAssignedMergeRequestsAsOwn: self.settings.treatAssignedMergeRequestsAsOwn,
            publicationMode: configured.publicationMode.rawValue, autoApproval: configured.autoApproveEnabled,
            followUpPush: configured.allowFollowUpPush, conflictPush: configured.allowConflictPush,
            autoReReview: configured.autoReReviewEnabled, autoClaimPipelineFailures: configured.autoClaimPipelineFailures)
        let boardState = menuBarGitLabStatus
        let lanes = [("Own", board.own), ("Reviewing", board.reviewed), ("Inbox", board.otherMergeRequests)]
        let authoredByID = Dictionary(authoredMergeRequests.requests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = lanes.flatMap { lane, rows in rows.map { (lane, $0) } }
        let cards = rows.prefix(180).compactMap { lane, row in
            agentQuestionCard(row, lane: lane, authored: authoredByID[row.id], boardCurrent: boardState == .current)
        }
        return .init(capturedAt: .now, lastInboxRefresh: lastRefresh, lastAuthoredRefresh: authoredMergeRequests.lastRefresh,
            boardState: String(describing: boardState), settings: options, cards: cards, omittedCards: rows.count - cards.count)
    }

    func agentQuestionDetails(for iids: [Int]) -> [AgentQuestionContext.Detail] {
        let selected = Set(iids.filter { $0 > 0 }.prefix(4))
        guard !selected.isEmpty else { return [] }
        let board = boardSnapshot
        var seen = Set<URL>()
        return (board.own + board.reviewed + board.otherMergeRequests)
            .filter { selected.contains($0.id.iid) && seen.insert($0.displayURL).inserted }
            .prefix(8).compactMap { agentQuestionDetail($0) }
    }

    private func agentQuestionDetail(_ row: MergeRequestBoardSnapshot.Row) -> AgentQuestionContext.Detail? {
        guard let target = scopeTarget(projectID: row.id.projectID, iid: row.id.iid, url: row.displayURL) else { return nil }
        let request = row.displayRequest
        let policyHold = request.flatMap {
            settings.configuredAutomation.followUpAutomationHold(for: $0, target: target,
                ignored: settings.ignoredMergeRequests.contains(target),
                requiresTodoRouting: row.attentionIntents.contains { $0.kind == .followUp })
        }
        let notes = glab.cachedDiscussions(projectID: target.projectID, iid: row.id.iid)
            .map { MRGitLabActivity.notes(in: $0.discussions).filter { $0.systemHeadline != nil } } ?? []
        let history = MRAutomationHistory(target: target, handoffs: assistantHandoffs,
            workflows: authoredMergeRequests.workflow.entries, events: settings.automationEvents, gitLab: notes)
        let explanation = confirmedHumanAction(for: row)?.explanation
            ?? row.latestJob?.operationalExecution?.attentionExplanation
        return .init(iid: row.id.iid, url: row.displayURL,
            author: request.map { cleanQuestionEvidence($0.author.username) },
            assignees: request?.assignees.map { $0.prefix(20).map { cleanQuestionEvidence($0.username) } },
            currentUserIsAuthor: request.map { $0.author.username == target.username },
            currentUserIsAssignee: request?.assignees.map { $0.contains { $0.username == target.username } },
            visibleReason: explanation.map(cleanQuestionEvidence),
            sourceBranch: request.map { cleanQuestionEvidence($0.sourceBranch) },
            targetBranch: request.map { cleanQuestionEvidence($0.targetBranch) },
            gitLabMergeStatus: request?.detailedMergeStatus?.rawValue, gitLabHasConflicts: request?.hasConflicts,
            recordedConflictWarning: row.item.hasConflict || row.attentionIntents.contains { $0.kind == .conflict },
            evidenceMatchesCurrentCatalog: row.evidenceMatchesCatalogContext,
            followUpPolicyHold: policyHold.map { String(localized: $0.message) },
            eventLog: history.entries.prefix(12).map { agentQuestionEvent($0, head: request?.sha) })
    }

    private func agentQuestionEvent(_ event: MRAutomationHistory.Entry, head: String?) -> AgentQuestionContext.Detail.Event {
        switch event.source {
        case .job(let job, _):
            let execution = job.operationalExecution
            return .init(date: event.createdAt, source: "agent job", title: cleanQuestionEvidence(job.title),
                status: execution.map { String(localized: $0.statusTitle) },
                reason: (execution?.attentionExplanation ?? execution?.summary ?? execution?.errorExplanation).map(cleanQuestionEvidence),
                currentHead: job.expectedHeadSHA.flatMap { sha in head.map { $0 == sha } })
        case .workflow(let workflow):
            return .init(date: event.createdAt, source: "workflow", title: String(localized: workflow.event.kind.displayLabel),
                status: String(describing: workflow.state), reason: workflow.summary.map(cleanQuestionEvidence),
                currentHead: workflow.event.mergeRequest.sha.flatMap { sha in head.map { $0 == sha } })
        case .event(let decision):
            return .init(date: event.createdAt, source: "MergeTether " + decision.origin.rawValue,
                title: String(localized: decision.title), status: decision.state.rawValue, reason: decision.message.map(cleanQuestionEvidence),
                currentHead: decision.approvedHeadSHA.flatMap { sha in head.map { $0 == sha } })
        case .gitLab(let activity, _):
            return .init(date: event.createdAt, source: "cached GitLab activity",
                title: cleanQuestionEvidence(activity.systemHeadline ?? String(localized: activity.title)),
                status: nil, reason: activity.body.map(cleanQuestionEvidence), currentHead: nil)
        }
    }

    private func cleanQuestionEvidence(_ text: String) -> String {
        String(GlabService.redactWorkflowEvidence(text).prefix(480))
    }

    private func agentQuestionCard(_ row: MergeRequestBoardSnapshot.Row, lane: String,
                                   authored: AuthoredMergeRequestStatus?, boardCurrent: Bool) -> AgentQuestionContext.Card? {
        let url = row.displayURL
        guard let target = scopeTarget(projectID: row.id.projectID, iid: row.id.iid, url: url),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let request = row.displayRequest
        let current = boardCurrent && row.evidenceMatchesCatalogContext && !attentionRefreshFailed(for: row)
            && !isRecheckingAttention(for: row)
        let status = request.flatMap { request in current && authored?.matchesCurrentRequest(request) == true ? authored : nil }
        let reading: MREffectivePolicyPresentation.ReadState = current ? .current : .unavailable
        let input = MREffectivePolicyPresentation.Input(request: request, target: target, settings: settings,
            assistantReady: selectedAssistantReady, readState: reading,
            submission: status?.displayedSubmissionState ?? (request?.hasQueuedMerge == true ? .queued : .none))
        let approval = current ? row.item.approvalProgress : nil
        let blockers = status.map { status in
            var blockers = status.blockers.map { String(describing: $0) }
            if let observed = row.item.manualMergeBlocker(using: status) {
                let description = String(localized: observed.title)
                if !blockers.contains(description) { blockers.append(description) }
            }
            return blockers
        }
        return .init(lane: lane, project: url.gitLabProjectPath, iid: row.id.iid,
            title: String(GlabService.redactWorkflowEvidence(row.displayTitle).prefix(160)), url: url,
            state: request.map { String(describing: $0.state) }, draft: row.isDraft,
            pipeline: (row.pipelineEvidence?.headPipeline ?? request?.headPipeline)?.status.rawValue,
            pipelineCheckedAt: row.pipelineEvidenceCheckedAt, approvalsCompleted: approval?.completed,
            approvalsRequired: approval?.required,
            unresolvedDiscussions: request?.blockingDiscussionsResolved.map { !$0 },
            privateDrafts: current ? row.item.draftCount : 0,
            effectiveRules: MREffectivePolicyPresentation(input: input).clauses.map { String(localized: $0.message) },
            autoMergeConfigured: input.mergeAllowed,
            eligibleForAutoMerge: status == nil ? nil : row.isEligibleForAutomaticMerge,
            mergeBlockers: blockers, mergeSubmission: input.submission == .none ? nil : input.submission.rawValue,
            gitLabMergeStatus: request?.detailedMergeStatus?.rawValue, gitLabHasConflicts: request?.hasConflicts,
            evidenceCurrent: current)
    }
}
