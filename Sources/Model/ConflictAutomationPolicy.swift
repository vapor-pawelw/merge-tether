import Foundation

@MainActor
enum ConflictAutomationPolicy {
    enum State: Equatable { case available, processing, requiresAttention }

    static func canStart(previous: MergeConflictReceipt?, previousJob: AssistantAutomationRunner.Handoff?,
                         username: String, allowsPush: Bool) -> Bool {
        guard previousJob?.execution?.state.isActive != true else { return false }
        guard let previous else { return true }
        guard allowsPush else { return false }
        if previous.allowsPush == false { return true }
        return previous.allowsPush == nil && previousJob.map { isKnownPlan($0, receipt: previous, username: username) } == true
    }

    static func state(previous: MergeConflictReceipt?, previousJob: AssistantAutomationRunner.Handoff?,
                      username: String, allowsPush: Bool, preparing: Bool = false) -> State {
        if preparing || previousJob?.execution?.state.isActive == true { return .processing }
        return canStart(previous: previous, previousJob: previousJob, username: username, allowsPush: allowsPush)
            ? .available : .requiresAttention
    }

    static func isKnownPlan(_ job: AssistantAutomationRunner.Handoff, receipt: MergeConflictReceipt, username: String) -> Bool {
        guard job.key.work.host == receipt.host, job.key.work.projectID == receipt.projectID,
              job.key.work.iid == receipt.iid, job.key.username == username,
              job.expectedHeadSHA == receipt.sourceSHA, !job.allowsPush, job.workflow == nil else { return false }
        if receipt.allowsPush == false, receipt.jobID == job.id { return true }
        guard let taskPrompt = job.taskPrompt else { return false }
        let task = taskPrompt.components(separatedBy: "<gitlab-evidence>").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return task.hasPrefix("Resolve the merge conflict in this GitLab merge request.")
            && task.contains("at \(receipt.targetSHA)")
    }
}
