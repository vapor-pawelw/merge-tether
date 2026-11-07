import Foundation

extension AssistantAutomationRunner.Handoff {
    /// Task routing identifies the activity; CLI output cannot reliably identify a live substep.
    func progressTitle(intents: [MRTodoIntent] = [], conflictReceipts: Set<MergeConflictReceipt> = []) -> LocalizedStringResource {
        let intentKind = intents.first {
            $0.jobID == id && $0.target.host == key.work.host && $0.target.username == key.username
                && $0.target.projectID == key.work.projectID && $0.target.iid == key.work.iid
        }?.kind
        let conflict = conflictReceipts.contains {
            $0.jobID == id && $0.host == key.work.host && $0.projectID == key.work.projectID && $0.iid == key.work.iid
        }
        if operationalExecution?.state == .queued { return .AutomationProgress.progressQueued }
        if pipelineReservation != nil || intentKind == .pipeline { return .AutomationProgress.progressPipeline }
        if intentKind == .conflict || conflict || allowsPush { return .AutomationProgress.progressConflicts }
        if workflow == .review || reviewModel != nil { return .AutomationProgress.progressReview }
        if workflow == .followUp { return .AutomationProgress.progressFeedback }
        return .AutomationProgress.progressAgent
    }
}
