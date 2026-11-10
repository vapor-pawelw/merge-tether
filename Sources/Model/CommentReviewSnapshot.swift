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
        var bodies = Dictionary(grouping: publishedDrafts.compactMap(\.note), by: AICommentAssessmentStore.digest)
            .mapValues(\.count)
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
            if ReviewVerdict.fingerprint(discussions, excluding: excluded) == discussionFingerprint { return true }
        }
        return false
    }

    func covers(_ request: GitLabMergeRequest?) -> Bool {
        request?.state == "opened" && request?.sha == headSHA && request?.semanticContextFingerprint == semanticContext
    }
}
