import Foundation

/// The fingerprint and its exact conversation text always travel together.
struct MRDiscussionContent: Sendable {
    let discussions: [GitLabMergeRequestDiscussion]
    let fingerprint: String?

    init(_ discussions: [GitLabMergeRequestDiscussion]) {
        self.discussions = discussions
        fingerprint = ReviewVerdict.fingerprint(discussions)
    }
}

@MainActor
final class MRDiscussionPresentation {
    private struct RequestKey: Equatable {
        let projectID: Int
        let iid: Int
        let url: URL
        let head: String?
        let title: Data
        let body: Data?

        init(_ request: GitLabMergeRequest) {
            projectID = request.projectID; iid = request.iid; url = request.webURL; head = request.sha
            title = Data(request.title.utf8); body = request.description.map { Data($0.utf8) }
        }
    }
    private struct CitationKey: Equatable {
        let target: MRDiscussionTarget
        let accountRevision: UInt64
        let request: RequestKey?
    }
    private struct DraftKey: Equatable {
        let draft: GitLabDraftNote
        let exactText: [Data?]

        init(_ draft: GitLabDraftNote) {
            self.draft = draft
            exactText = [draft.note, draft.discussionID, draft.position?.newPath, draft.position?.oldPath,
                         draft.position?.baseSHA, draft.position?.headSHA, draft.position?.positionType]
                .map { $0.map { Data($0.utf8) } }
        }
    }
    private struct AssessmentNote: Equatable {
        let id: Int
        let state: ReReviewAssessment.Note.State
        let replyID: Int?

        init(_ note: ReReviewAssessment.Note) {
            id = note.noteID; state = note.state; replyID = note.publishedReplyNoteID
        }
    }
    private struct SnapshotKey: Equatable {
        let target: MRDiscussionTarget?
        let accountRevision: UInt64
        let drafts: [DraftKey]
        let assessment: [AssessmentNote]?
        let authorID: Int?
    }
    private var citationKey: CitationKey?
    private var citations = ObservedPresentationCache<MRCommentCitation.Context?>()
    private var snapshotKey: SnapshotKey?
    private var snapshot = ObservedPresentationCache<MRDiscussionSnapshot>()

    func citationContext(target: MRDiscussionTarget, request: GitLabMergeRequest?, accountRevision: UInt64,
                         makeContext: () -> MRCommentCitation.Context?) -> MRCommentCitation.Context? {
        let key = CitationKey(target: target, accountRevision: accountRevision, request: request.map(RequestKey.init))
        if citationKey != key {
            citationKey = key
            citations = ObservedPresentationCache()
        }
        return citations.value(makeContext)
    }

    func snapshot(target: MRDiscussionTarget?, accountRevision: UInt64, drafts: [GitLabDraftNote],
                  assessment: ReReviewAssessment?, authorID: Int?,
                  makeSnapshot: () -> MRDiscussionSnapshot) -> MRDiscussionSnapshot {
        let key = SnapshotKey(target: target, accountRevision: accountRevision, drafts: drafts.map(DraftKey.init),
            assessment: assessment?.notes.map(AssessmentNote.init), authorID: authorID)
        if snapshotKey != key {
            snapshotKey = key
            snapshot = ObservedPresentationCache()
        }
        return snapshot.value(makeSnapshot)
    }
}
