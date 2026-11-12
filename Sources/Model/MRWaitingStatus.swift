import Foundation

/// Display facts only. Waiting never grants merge, approval, publication or resolution permission.
@MainActor struct MRWaitingStatus {
    let reviewers: [String]
    let approvalProgress: MergeRequestApprovalProgress?
    let hasCurrentDependencyHold: Bool
    private let awaitsReviewer: Bool
    private let humanResolutionAuthors: [String]

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
        hasCurrentDependencyHold = dependencyHold
        guard awaitsReviewer || awaitingRequiredApprovals else { return nil }
    }

    var title: LocalizedStringResource {
        guard awaitsReviewer else { return approvalTitle! }
        let reviewerTitle: LocalizedStringResource
        let names = reviewers.prefix(3).map { "@" + $0 }.joined(separator: ", ")
        if let resolution = AuthorFeedbackPolicy.resolutionWaitMessage(authors: humanResolutionAuthors) { reviewerTitle = resolution }
        else if reviewers.isEmpty { reviewerTitle = .AuthorFeedback.authorFeedbackWaitingChip }
        else if reviewers.count > 3 {
            reviewerTitle = .AuthorFeedback.authorFeedbackWaitingReviewersMore(names, reviewers.count - 3)
        } else { reviewerTitle = .AuthorFeedback.authorFeedbackWaitingReviewers(names) }
        guard let approvalTitle else { return reviewerTitle }
        return .AuthorFeedback.authorFeedbackWaitingSummary(String(localized: reviewerTitle), String(localized: approvalTitle))
    }

    private var approvalTitle: LocalizedStringResource? {
        guard let progress = approvalProgress else { return nil }
        if awaitingRequiredApprovals {
            return .AuthorFeedback.authorFeedbackWaitingRequiredApprovals(progress.completed, progress.required)
        }
        if progress.required == 0 { return .Board.boardApprovalsReceived(progress.completed) }
        return .AuthorFeedback.authorFeedbackWaitingApprovalCount(progress.completed, progress.required)
    }
}
