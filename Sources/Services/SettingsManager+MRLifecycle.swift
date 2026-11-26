import Foundation

extension SettingsManager {
    private static let closedHistoryRetention: TimeInterval = 30 * 24 * 60 * 60
    private static let retainedRunHistory = 12

    func retainedHistoryCandidates(host: String, username: String) -> Set<MRAutomationScope.Target> {
        var counts: [MRAutomationScope.Target: Int] = [:]
        for job in assistantHandoffs where job.key.work.host == host && job.key.username == username
            && job.execution?.state == .succeeded {
            counts[job.key.automationTarget, default: 0] += 1
        }
        return Set(counts.compactMap { $0.value > Self.retainedRunHistory ? $0.key : nil })
    }

    func retireMRProgress(for target: MRAutomationScope.Target, state: GitLabMergeRequestState,
                          terminalSince: Date, now: Date) {
        guard state == .merged || state == .closed else { return }
        let removedNewMarker = newReviewTargets.contains(target)
        if removedNewMarker { newReviewTargets.remove(target) }
        let mayRetireHistory = state == .merged || now.timeIntervalSince(terminalSince) >= Self.closedHistoryRetention
        let removedHistory = mayRetireHistory && retireRunHistory(for: target)
        let removedPin = mayRetireHistory && retireCardPin(for: target)
        if removedNewMarker || removedHistory || removedPin { save() }
    }

    private func retireCardPin(for target: MRAutomationScope.Target) -> Bool {
        guard let iid = target.iid, let pin = BoardCardPin.mergeRequest(
            host: target.host, username: target.username, projectID: target.projectID, iid: iid),
              boardPins.contains(pin) else { return false }
        return boardPins.remove(pin) != nil
    }

    private func retireRunHistory(for target: MRAutomationScope.Target) -> Bool {
        let scopedJobs = assistantHandoffs.filter { $0.key.automationTarget == target }
        guard scopedJobs.count > Self.retainedRunHistory else { return false }
        var protected = referencedRunIDs()
        if let latest = scopedJobs.max(by: { $0.createdAt < $1.createdAt }) {
            protected.insert(latest.id)
        }

        let completed = scopedJobs.filter {
            !protected.contains($0.id) && $0.execution?.state == .succeeded
                && $0.execution?.pendingWorkerAudit == nil && $0.execution?.remoteEffects?.isEmpty != false
                && $0.execution?.sourceHeadChange == nil
        }.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.createdAt > $1.createdAt
        }
        // The transcript from a successful run doesn't participate in action checks.
        // Its run metadata and the authenticated checkpoint may still be evidence.
        let transcripts = Set(completed.lazy.filter { $0.execution?.output != nil }
            .dropFirst(Self.retainedRunHistory).map(\.id))
        let displayHistory = completed.filter {
            $0.manual == true && $0.readOnlyReview == true && $0.workflow == .review && !$0.allowsPush && $0.draftRepair == nil
                && $0.pipelineReservation == nil && $0.followUpPushAllowed != true
                && $0.verifiedFeedbackNotes?.isEmpty != false && $0.feedbackTodos?.isEmpty != false
                && $0.feedbackNoteIDs?.isEmpty != false
        }
        let retired = Set(displayHistory.dropFirst(Self.retainedRunHistory).map(\.id))
        guard !retired.isEmpty || !transcripts.isEmpty else { return false }
        assistantHandoffs = assistantHandoffs.compactMap { job in
            guard !retired.contains(job.id) else { return nil }
            guard transcripts.contains(job.id) else { return job }
            var trimmed = job
            trimmed.execution?.output = nil
            return trimmed
        }
        return true
    }

    private func referencedRunIDs() -> Set<UUID> {
        var ids = Set(conflictReceipts.compactMap(\.jobID))
        ids.formUnion(authorFeedbackAttempts.compactMap(\.recoveryRootID))
        ids.formUnion(assistantAutomaticRetryAttempts.flatMap { [$0.rootID, $0.parentJobID, $0.replacementJobID].compactMap { $0 } })
        ids.formUnion(mrActionIntents.flatMap { [$0.jobID, $0.reviewRecoveryJobID].compactMap { $0 } })
        ids.formUnion(workflowActivity.flatMap { [$0.assistantJobID, $0.preparedReviewJobID].compactMap { $0 } })
        ids.formUnion(automationEvents.flatMap { [$0.jobID, $0.relatedJobID].compactMap { $0 } })
        ids.formUnion(assistantHandoffs.flatMap {
            [$0.retryOf, $0.environmentRecoveryOf, $0.feedbackRecoveryRootID, $0.automaticRetryIdentity?.rootID].compactMap { $0 }
        })
        return ids
    }
}
