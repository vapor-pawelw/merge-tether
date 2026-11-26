import Foundation

/// Reconciles presentation from current evidence without rewriting a worker's recorded result.
enum PipelineJobReconciliation {
    static func matchingDetails(_ displayed: GitLabMergeRequest?, details: GitLabMergeRequest?,
                                checkedAt: Date?, job: AssistantAutomationRunner.Handoff?) -> GitLabMergeRequest? {
        guard let displayed, let details, let checkedAt, let job,
              checkedAt >= (job.execution?.finishedAt ?? job.createdAt),
              displayed.author.id == details.author.id, displayed.author.username == details.author.username,
              details.isOwned(by: job.key.username, includingSoleAssignee: job.requiresSoleAssignment == true),
              MergeRequestDependencySummary.Context(displayed) == MergeRequestDependencySummary.Context(details),
              displayed.semanticContextFingerprint == details.semanticContextFingerprint,
              displayed.draft == details.draft,
              let pipeline = details.headPipeline, let id = pipeline.id, id > 0 else { return nil }
        return details
    }

    static func isObsolete(_ job: AssistantAutomationRunner.Handoff?, request: GitLabMergeRequest?) -> Bool {
        guard let job, let request, let prior = job.pipelineReservation,
              let state = job.operationalExecution?.state, !state.isActive,
              [.blocked, .failed, .interrupted, .cancelled].contains(state),
              !job.allowsPush, job.workflow != .review, job.reviewModel == nil,
              (job.feedbackNoteIDs ?? []).isEmpty, (job.verifiedFeedbackNotes ?? [:]).isEmpty,
              (job.feedbackTodos ?? []).isEmpty,
              job.key.work.host == prior.host, job.key.work.projectID == prior.projectID,
              job.key.work.iid == prior.mergeRequestIID,
              request.projectID == prior.projectID, request.iid == prior.mergeRequestIID,
              request.isOwned(by: job.key.username, includingSoleAssignee: job.requiresSoleAssignment == true),
              request.webURL.isGitLabMergeRequest(host: prior.host, iid: prior.mergeRequestIID),
              let expected = job.expectedHeadSHA, !expected.isEmpty, request.sha == expected,
              let pipeline = request.headPipeline, let id = pipeline.id, id > 0,
              pipeline.projectID == nil || pipeline.projectID == request.projectID else { return false }
        if id == prior.pipelineID {
            return [.success, .running, .pending, .created, .preparing, .waitingForResource].contains(pipeline.status)
        }
        guard id > prior.pipelineID else { return false }
        return [.success, .failed, .running, .pending, .created, .preparing,
                .waitingForResource, .canceled, .skipped].contains(pipeline.status)
    }
}
