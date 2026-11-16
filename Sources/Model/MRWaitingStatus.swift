import Foundation

/// Display facts only. Waiting never grants merge, approval, publication or resolution permission.
@MainActor struct MRWaitingStatus {
    let reviewers: [String]
    let approvalProgress: MergeRequestApprovalProgress?
    let hasCurrentDependencyHold: Bool
    private let awaitsReviewer: Bool
    private let humanResolutionAuthors: [String]
    private let people: PersonDirectory

    var awaitingRequiredApprovals: Bool {
        guard let progress = approvalProgress, progress.required > 0 else { return false }
        return progress.requirementsSatisfied == false
            || (progress.requirementsSatisfied != true && progress.completed < progress.required)
    }

    init?(row: MergeRequestBoardSnapshot.Row) {
        let item = row.item
        guard item.isAuthored, row.evidenceMatchesCatalogContext,
              let request = row.displayRequest, request.state == "opened", request.draft == false,
              request.sha?.isEmpty == false, MRAttentionRecord.sameContext(item.mergeRequest, request) else { return nil }
        let dependencies = row.displayItem.dependencies
        let dependencyHold = request.detailedMergeStatus == "merge_request_blocked"
            && dependencies?.issues.isDisjoint(with: [.dependenciesUnavailable, .hiddenDependency]) == true
            && dependencies?.predecessors.contains(where: { $0.isCurrent && $0.sources.contains(.gitLab) }) == true
        guard !request.hasQueuedMerge, !request.hasMergeConflict, !request.mergeTrainEvidenceUnavailable,
              request.canMerge != false, request.headPipeline.map({ $0.status == "success" }) ?? true,
              dependencyHold || [nil, "mergeable", "not_approved", "requested_changes", "discussions_not_resolved"].contains(request.detailedMergeStatus),
              !row.hasIndependentStoppedWork, row.latestJob?.operationalExecution?.state.isActive != true,
              !row.attentionIntents.contains(where: { $0.state == .pending && !$0.isDeferredReview }),
              item.draftCount == 0, item.drafts.isEmpty, !item.requiresCommentReview,
              !item.requiresDiscussionRecheck, !item.awaitingRemoteVerification,
              !item.draftProofRecoveryReadFailure, item.draftProofRecoveryFailure == nil,
              item.reReviewReadiness == nil, !item.reReviewUnconfirmed, !item.canConfirmReReview,
              !item.needsMerge, !item.canApprove || item.approvalWaitingForReadiness,
              !item.hasConflict, !item.failedPipeline, !item.needsPipelineHandoff else { return nil }

        if let status = item.authorFeedbackStatus {
            guard status.phase == .complete, status.head == request.sha,
                  let semantic = status.semanticContextFingerprint, semantic == request.semanticContextFingerprint,
                  let fingerprint = item.observedDiscussionFingerprint, !fingerprint.isEmpty,
                  status.fingerprint == fingerprint, !status.needsAttention, status.pendingDraftCount == 0,
                  status.followUpNoteIDs.isEmpty, status.replyNoteIDs.isEmpty, status.codeReviewRequests.isEmpty,
                  status.findings.allSatisfy({ [.waitingAcceptance, .ready].contains($0.state)
                      || $0.state == .disabled && $0.resolutionWaitMessage != nil }) else { return nil }
            humanResolutionAuthors = AuthorFeedbackPolicy.normalizedHandles(status.findings.filter {
                $0.resolutionWaitMessage != nil
            }.flatMap(\.waitingForHumanResolution))
            awaitsReviewer = status.waitingForReviewer || !humanResolutionAuthors.isEmpty
            var handles: [String: String] = [:]
            for value in status.findings.filter({ $0.state == .waitingAcceptance }).flatMap(\.waitingForReviewers) {
                let name = value.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "@" })
                guard !name.isEmpty else { continue }
                handles[String(name).lowercased()] = String(name)
            }
            reviewers = handles.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        } else {
            awaitsReviewer = false
            reviewers = []
            humanResolutionAuthors = []
        }
        let verified = item.presentingVerifiedAuthorFeedback()
        guard verified.feedback.isEmpty, !verified.needsDiscussion, !verified.needsChanges,
              !verified.hasOtherUnresolvedDiscussions else { return nil }
        approvalProgress = row.displayItem.approvalProgress
        people = request.personDirectory(approvals: approvalProgress, notes: item.feedback)
        hasCurrentDependencyHold = dependencyHold
        guard awaitsReviewer || awaitingRequiredApprovals else { return nil }
    }

    /// One blocker per line; the header badge already shows the approval count.
    var requirements: [LocalizedStringResource] {
        var lines: [LocalizedStringResource] = []
        if let reviewerRequirement { lines.append(reviewerRequirement) }
        if awaitingRequiredApprovals, let progress = approvalProgress {
            let remaining = progress.required - progress.completed
            lines.append(remaining > 0 ? .AuthorFeedback.authorFeedbackNeedsMoreApprovals(remaining)
                : .MergeActions.mergeActionsApprovals)
        }
        return lines
    }

    /// Merge blockers these requirements already state, so the card does not repeat them.
    var coveredBlockers: Set<MergeRequestBlocker> {
        var covered: Set<MergeRequestBlocker> = []
        if awaitsReviewer { covered.insert(.discussions) }
        if awaitingRequiredApprovals { covered.insert(.approvals) }
        return covered
    }

    /// A single line for surfaces that cannot show the list.
    var title: LocalizedStringResource {
        let lines = requirements
        guard lines.count > 1 else { return lines.first ?? .MergeActions.mergeActionsApprovals }
        return lines.dropFirst().reduce(lines[0]) { summary, line in
            .AuthorFeedback.authorFeedbackWaitingSummary(String(localized: summary), String(localized: line))
        }
    }

    private var reviewerRequirement: LocalizedStringResource? {
        guard awaitsReviewer else { return nil }
        let names = people.displayNames(Array(reviewers.prefix(3)))
        if let resolution = AuthorFeedbackPolicy.resolutionWaitMessage(authors: humanResolutionAuthors, people: people) { return resolution }
        if reviewers.isEmpty { return .AuthorFeedback.authorFeedbackWaitingChip }
        if reviewers.count > 3 { return .AuthorFeedback.authorFeedbackWaitingReviewersMore(names, reviewers.count - 3) }
        return .AuthorFeedback.authorFeedbackWaitingReviewers(names)
    }
}
