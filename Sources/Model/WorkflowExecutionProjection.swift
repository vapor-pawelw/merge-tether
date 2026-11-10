import Foundation

/// Job state is display evidence, never a new workflow admission or a persisted outcome mirror.
enum WorkflowExecutionProjection {
    static func entry(_ stored: MergeWorkflowActivityEntry,
                      job: AssistantAutomationRunner.Handoff?) -> MergeWorkflowActivityEntry {
        guard stored.assistantJobID != nil else { return stored }
        guard let job = matchingJob(stored, job: job) else {
            var unavailable = stored
            unavailable.state = .skipped
            unavailable.summary = String(localized: .AutomationHistory.automationHistoryExecutionUnavailable)
            return unavailable
        }
        guard let execution = job.execution else { return stored }
        // Retirement is an explicit local decision, separate from cancellation of an old reminder run.
        if stored.event.kind == .reviewWaiting, job.workflow == .draftReply,
           execution.state.isActive || execution.state == .cancelled { return stored }
        var visible = stored
        visible.state = switch execution.state {
        case .queued: .waitingForAssistant
        case .running: .running
        case .succeeded: .completed
        case .blocked, .failed, .interrupted: .failed
        case .cancelled: .skipped
        }
        visible.summary = execution.summary ?? execution.error
        return visible
    }

    /// Unavailable evidence changes presentation, but cannot prove that a claim's run finished.
    static func hasTerminalExecution(_ stored: MergeWorkflowActivityEntry,
                                     job: AssistantAutomationRunner.Handoff?) -> Bool {
        guard let execution = matchingJob(stored, job: job)?.execution else { return false }
        return !execution.state.isActive
    }

    private static func matchingJob(_ stored: MergeWorkflowActivityEntry,
                                    job: AssistantAutomationRunner.Handoff?) -> AssistantAutomationRunner.Handoff? {
        guard let id = stored.assistantJobID, let job, job.id == id, job.key.work.host == stored.host,
              job.key.username == stored.user.username,
              job.key.work.projectID == stored.event.mergeRequest.projectID,
              job.key.work.iid == stored.event.mergeRequest.iid else { return nil }
        return job
    }
}
