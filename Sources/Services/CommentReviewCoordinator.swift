import Foundation

/// Reconciles the existing per-account MR checkpoint with freshly observed GitLab evidence.
@MainActor
struct CommentReviewCoordinator {
    enum Proof {
        case explicit(CommentReviewSnapshot, URL)
        case manualPublication(CommentReviewSnapshot, [GitLabDraftNote])
        case automaticPublication(SettingsManager.CommentReviewProgress.AutomaticPublication)

        var isExplicit: Bool {
            if case .explicit = self { return true }
            return false
        }
    }

    struct Observation {
        let request: GitLabMergeRequest
        let discussions: [GitLabMergeRequestDiscussion]
        let drafts: [GitLabDraftNote]

        var snapshot: CommentReviewSnapshot? { .init(request: request, discussions: discussions) }
    }

    enum Decision: Equatable {
        case completed, pending, changed, stale
    }

    let glab: GlabService

    func read(_ target: MRAutomationScope.Target, user: GitLabAuthenticatedUser,
              requireUser: Bool = false, isCurrent: () -> Bool) async throws -> Observation? {
        guard let iid = target.iid, isCurrent() else { return nil }
        async let authenticated = glab.fetchAuthenticatedUser(host: target.host, expectedUsername: target.username)
        async let request = glab.fetchMergeRequest(projectID: target.projectID, iid: iid, host: target.host)
        async let discussions = glab.fetchMergeRequestDiscussions(projectID: target.projectID, iid: iid, host: target.host)
        let (liveUser, live, threads) = try await (authenticated, request, discussions)
        guard isCurrent() else { return nil }
        guard liveUser == user else {
            if requireUser { throw GlabError.notAuthenticated }
            return nil
        }
        // Observe drafts after the reads that can otherwise race an edit in GitLab.
        let drafts = try await glab.fetchOwnDraftNotes(projectID: target.projectID, iid: iid, host: target.host, userID: user.id)
        guard isCurrent() else { return nil }
        return .init(request: live, discussions: threads, drafts: drafts)
    }

    static func decide(_ proof: Proof, observed: Observation, target: MRAutomationScope.Target,
                       userID: Int, latestRequest: GitLabMergeRequest?) -> Decision {
        let request = observed.request
        let draftsAreEmpty = observed.drafts.isEmpty
        guard let iid = target.iid, request.projectID == target.projectID, request.iid == iid,
              request.webURL.isGitLabMergeRequest(host: target.host, iid: iid) else { return .changed }
        switch proof {
        case .explicit(let snapshot, let url):
            return draftsAreEmpty && request.webURL == url
                && snapshot.matches(request, discussions: observed.discussions, userID: userID) ? .completed : .changed
        case .manualPublication(let snapshot, let published):
            guard snapshot.matches(request, discussions: observed.discussions, publishedDrafts: published, userID: userID)
            else { return .changed }
            return draftsAreEmpty ? .completed : .pending
        case .automaticPublication(let receipt):
            guard receipt.evidenceContext.binds(to: .init(recoveryContext: request.draftProofRecoveryDigest),
                                                policy: .recoveryDigest) else { return .changed }
            guard MRAttentionRecord.sameContext(latestRequest, request) else { return .stale }
            guard draftsAreEmpty, observed.snapshot != nil else { return .pending }
            return receipt.snapshot.matches(request, discussions: observed.discussions,
                publishedBodyDigests: Array(receipt.publishedBodyDigests.values), userID: userID) ? .completed : .changed
        }
    }
}
