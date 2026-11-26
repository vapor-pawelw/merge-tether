import Foundation

/// Completion evidence stays separate from the semantic feedback assessment.
struct CommentReviewSnapshot: Codable, Equatable, Sendable {
    let headSHA: String
    let semanticContext: String
    let discussionFingerprint: String

    var evidenceContext: EvidenceContext {
        .init(head: headSHA, discussionContent: .init(discussionFingerprint), semanticContext: .init(semanticContext))
    }

    init?(request: GitLabMergeRequest?, discussions: [GitLabMergeRequestDiscussion]?) {
        guard let request, request.isOpen, let head = request.sha, !head.isEmpty,
              let discussions, let fingerprint = ReviewVerdict.fingerprint(discussions) else { return nil }
        headSHA = head
        semanticContext = request.semanticContextFingerprint
        discussionFingerprint = fingerprint
    }

    func matches(_ request: GitLabMergeRequest, discussions: [GitLabMergeRequestDiscussion],
                 publishedDrafts: [GitLabDraftNote] = [], userID: Int) -> Bool {
        matches(request, discussions: discussions,
            publishedBodyDigests: publishedDrafts.compactMap(\.note).map(AICommentAssessmentStore.digest),
            userID: userID)
    }

    func matches(_ request: GitLabMergeRequest, discussions: [GitLabMergeRequestDiscussion],
                 publishedBodyDigests: [String], userID: Int) -> Bool {
        guard covers(request) else { return false }
        if evidenceContext.binds(to: .init(discussionContent: ReviewVerdict.discussionContentDigest(discussions)),
                                 policy: .discussionContent) { return true }
        // Permit only the new own comments this publication actually sent.
        var bodies = Dictionary(grouping: publishedBodyDigests, by: { $0 }).mapValues(\.count)
        let ownPublished = discussions.flatMap(\.notes).compactMap { note -> (id: Int, digest: String)? in
            guard note.system != true, note.author?.id == userID, let body = note.body, let id = note.id else { return nil }
            let digest = AICommentAssessmentStore.digest(body)
            guard bodies[digest] != nil else { return nil }
            return (id, digest)
        }.sorted { $0.id > $1.id }
        var excluded = Set<Int>()
        for note in ownPublished {
            guard let remaining = bodies[note.digest], remaining > 0 else { continue }
            bodies[note.digest] = remaining - 1
            excluded.insert(note.id)
            let current = EvidenceContext(discussionContent: ReviewVerdict.discussionContentDigest(discussions, excluding: excluded))
            if evidenceContext.binds(to: current, policy: .discussionContent) { return true }
        }
        return false
    }

    func covers(_ request: GitLabMergeRequest?) -> Bool {
        guard let request, request.isOpen else { return false }
        return evidenceContext.binds(to: request.evidenceContext(), policy: .requestText)
    }
}
