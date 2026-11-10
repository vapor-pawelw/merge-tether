import Foundation

/// Completion evidence stays separate from the semantic feedback assessment.
struct CommentReviewSnapshot: Equatable, Sendable {
    let headSHA: String
    let semanticContext: String
    let discussionFingerprint: String

    init?(request: GitLabMergeRequest?, discussions: [GitLabMergeRequestDiscussion]?) {
        guard let request, request.state == "opened", let head = request.sha, !head.isEmpty,
              let discussions, let fingerprint = ReviewVerdict.fingerprint(discussions) else { return nil }
        headSHA = head
        semanticContext = request.semanticContextFingerprint
        discussionFingerprint = fingerprint
    }

    func matches(_ request: GitLabMergeRequest, discussions: [GitLabMergeRequestDiscussion],
                 publishedDrafts: [GitLabDraftNote] = [], userID: Int) -> Bool {
        guard request.state == "opened", request.sha == headSHA,
              request.semanticContextFingerprint == semanticContext else { return false }
        if ReviewVerdict.fingerprint(discussions) == discussionFingerprint { return true }
        // Permit only the new own comments this publication actually sent.
        let bodies = Set(publishedDrafts.compactMap(\.note).map(AICommentAssessmentStore.digest))
        let ownPublished = discussions.flatMap(\.notes).compactMap { note -> Int? in
            guard note.system != true, note.author?.id == userID, let body = note.body,
                  bodies.contains(AICommentAssessmentStore.digest(body)) else { return nil }
            return note.id
        }.sorted(by: >)
        var excluded = Set<Int>()
        for id in ownPublished {
            excluded.insert(id)
            if ReviewVerdict.fingerprint(discussions, excluding: excluded) == discussionFingerprint { return true }
        }
        return false
    }

    func covers(_ request: GitLabMergeRequest?) -> Bool {
        request?.state == "opened" && request?.sha == headSHA && request?.semanticContextFingerprint == semanticContext
    }
}
