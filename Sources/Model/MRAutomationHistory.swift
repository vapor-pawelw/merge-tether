import Foundation

/// Application decisions that cannot be reconstructed from a worker's persisted execution.
struct MRAutomationEvent: Codable, Identifiable, Equatable, Sendable {
    enum Action: String, Codable, Sendable {
        case retry, review, followUp, draftReply, verification, feedbackDecision, pipeline, conflict, refresh, approval
        case approve, removeApproval, publication, merge, enqueueMerge
    }
    enum Origin: String, Codable, Sendable { case manual, automatic }
    enum State: String, Codable, Sendable { case requested, queued, failed, completed, blocked }
    let id: UUID
    let target: MRAutomationScope.Target
    let createdAt: Date
    let action: Action
    let origin: Origin
    let state: State
    let message: String?
    var intentID: UUID? = nil
    var jobID: UUID? = nil
    var relatedJobID: UUID? = nil
    var approvedHeadSHA: String? = nil
    var publishedNoteID: Int? = nil
    var publicationBasedOnAuthorTrust: Bool? = nil

    var title: LocalizedStringResource {
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
        case .approval: .AutomationHistory.automationHistoryActionApproval
        case .approve: .AutomationHistory.automationHistoryActionApproved
        case .removeApproval: .Board.boardApprovalsRemoved
        case .publication: publicationBasedOnAuthorTrust == true
            ? .AutomationHistory.automationHistoryPublicationAuthorTrust : .AutomationHistory.automationHistoryActionPublication
        case .merge: .AutomationHistory.automationHistoryMerged
        case .enqueueMerge: .AutomationHistory.automationHistoryActionEnqueueMerge
        }
    }
}

/// A read-only chronology; run lifecycle remains owned by AssistantJobExecution.
@MainActor
struct MRAutomationHistory {
    struct Entry: Identifiable {
        enum Source {
            case job(AssistantAutomationRunner.Handoff, attempt: Int)
            case workflow(MergeWorkflowActivityEntry)
            case event(MRAutomationEvent)
            case gitLab(MRGitLabActivity, appEvent: MRAutomationEvent?)
        }
        let id: String
        let createdAt: Date
        let source: Source

        var isAutomatic: Bool {
            switch source {
            case .job(let job, _): job.manual == false && job.pipelineHandoffConfirmation == nil
            case .workflow: true
            case .event(let event): event.origin == .automatic
            case .gitLab(_, let appEvent): appEvent?.origin == .automatic
            }
        }
    }
    let entries: [Entry]

    static func reviewLaunchReasons(for job: AssistantAutomationRunner.Handoff,
                                    workflows: [MergeWorkflowActivityEntry], intents: [MRTodoIntent]) -> [ReviewLaunchReason] {
        guard job.manual == false, AssistantAutomationRunner.recordsReviewVerdict(for: job),
              let url = job.mergeRequestURL, let head = job.expectedHeadSHA else { return [] }
        let work = job.key.work
        let target = MRAutomationScope.Target(host: work.host, username: job.key.username, projectID: work.projectID, iid: work.iid)
        if intents.contains(where: {
            $0.reviewRecoveryJobID == job.id && $0.kind == .review && $0.target == target
                && $0.request.webURL == url && $0.headSHA == head
        }) {
            return [.unverifiedReview]
        }
        let workflow = workflows.first {
            let request = $0.event.mergeRequest
            return ($0.assistantJobID ?? $0.preparedReviewJobID) == job.id && $0.event.kind == .reviewUpdate
                && $0.host == work.host && $0.user.username == job.key.username
                && request.projectID == work.projectID && request.iid == work.iid && request.webURL == url && request.sha == head
        }
        let trigger = workflow?.event.reviewUpdateReasons ?? []
        return job.automaticRetryIdentity == nil ? trigger : [.automaticRetry] + trigger
    }

    func associatedRuns(for entry: Entry) -> [AssistantAutomationRunner.Handoff] {
        let ids: [UUID]
        switch entry.source {
        case .job(let job, _): ids = [job.id]
        case .workflow(let workflow): ids = [workflow.assistantJobID].compactMap { $0 }
        case .event(let event): ids = [event.jobID, event.relatedJobID].compactMap { $0 }
        case .gitLab: ids = []
        }
        var result: [AssistantAutomationRunner.Handoff] = []
        for id in ids where !result.contains(where: { $0.id == id }) {
            for candidate in entries {
                if case .job(let job, _) = candidate.source, job.id == id { result.append(job); break }
            }
        }
        return result
    }

    init(target: MRAutomationScope.Target, handoffs: [AssistantAutomationRunner.Handoff],
         workflows: [MergeWorkflowActivityEntry], events: [MRAutomationEvent], gitLab: [MRGitLabActivity] = []) {
        guard let iid = target.iid else { entries = []; return }
        let runs = handoffs.filter {
            $0.key.work.host == target.host && $0.key.username == target.username
                && $0.key.work.projectID == target.projectID && $0.key.work.iid == iid
        }.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
        let runEntries = runs.enumerated().map { offset, run in
            Entry(id: "job/\(run.id)",
                  createdAt: run.execution?.finishedAt ?? run.execution?.startedAt ?? run.createdAt,
                  source: .job(run, attempt: offset + 1))
        }
        let workflowEntries = workflows.filter {
            $0.host == target.host && $0.user.username == target.username
                && $0.event.mergeRequest.projectID == target.projectID && $0.event.mergeRequest.iid == iid
                && $0.event.mergeRequest.webURL.isGitLabMergeRequest(host: target.host, iid: iid)
        }.map { Entry(id: "workflow/\($0.id)", createdAt: $0.createdAt, source: .workflow($0)) }
        let decisions = events.filter { $0.target == target }
        let publicationsByNote = Dictionary(grouping: decisions.filter { $0.action == .publication }, by: \.publishedNoteID)
        let merges = decisions.filter { $0.action == .merge && $0.state == .completed }
        var attributedDecisions = Set<UUID>()
        var seen = Set<String>()
        let distinctActivity = gitLab.filter { seen.insert($0.id).inserted }
        let mergeCount = distinctActivity.count { if case .state(.merged) = $0.kind { true } else { false } }
        let gitLabEntries = distinctActivity.map { activity in
            let appEvent: MRAutomationEvent?
            switch activity.kind {
            case .comment(let id, _) where publicationsByNote[id]?.count == 1:
                appEvent = publicationsByNote[id]?.first
            case .state(.merged) where mergeCount == 1 && merges.count == 1:
                appEvent = merges.first
            default: appEvent = nil
            }
            if let appEvent { attributedDecisions.insert(appEvent.id) }
            return Entry(id: activity.id, createdAt: activity.createdAt, source: .gitLab(activity, appEvent: appEvent))
        }
        let decisionEntries = decisions.filter { !attributedDecisions.contains($0.id) }
            .map { Entry(id: "event/\($0.id)", createdAt: $0.createdAt, source: .event($0)) }
        entries = (runEntries + workflowEntries + decisionEntries + gitLabEntries).sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
    }
}

extension SettingsManager {
    func hasAutomaticApprovalWithOpenFindings(for target: MRAutomationScope.Target, head: String) -> Bool {
        let latest = automationEvents.first {
            $0.target == target && $0.state == .completed && $0.approvedHeadSHA == head
                && [.approval, .approve, .removeApproval].contains($0.action)
        }
        return latest?.action == .approval && latest?.origin == .automatic
    }

    func recordAutomationEvent(target: MRAutomationScope.Target, action: MRAutomationEvent.Action,
                               origin: MRAutomationEvent.Origin, state: MRAutomationEvent.State,
                               message: String? = nil, intentID: UUID? = nil, jobID: UUID? = nil,
                               relatedJobID: UUID? = nil, approvedHeadSHA: String? = nil,
                               publishedNoteID: Int? = nil, publicationBasedOnAuthorTrust: Bool? = nil, now: Date = Date()) {
        guard target.iid != nil else { return }
        let event = MRAutomationEvent(id: UUID(), target: target, createdAt: now, action: action,
            origin: origin, state: state, message: message.map(GlabService.redactWorkflowEvidence),
            intentID: intentID, jobID: jobID, relatedJobID: relatedJobID, approvedHeadSHA: approvedHeadSHA,
            publishedNoteID: publishedNoteID, publicationBasedOnAuthorTrust: publicationBasedOnAuthorTrust)
        var counts: [MRAutomationScope.Target: Int] = [:]
        automationEvents = ([event] + automationEvents).sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }.filter {
            counts[$0.target, default: 0] += 1
            return counts[$0.target, default: 0] <= 100
        }
        automationEvents = Array(automationEvents.prefix(1_000))
        save()
    }
}
