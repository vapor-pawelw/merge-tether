import Foundation

/// A quotation of one identified GitLab note, never a guessed thread or MR link.
struct MRCommentCitation: Identifiable, Sendable {
    let id: Int
    let discussionID: String?
    let note: GitLabMergeRequestDiscussion.Note
    let url: URL

    struct Context {
        let target: MRDiscussionTarget
        private let headSHA: String?
        private let semanticContextFingerprint: String
        private let discussionFingerprint: String?
        private let citations: [Int: MRCommentCitation]
        private let rootNoteIDs: [String: Int]

        init?(target: MRDiscussionTarget, loadedTarget: MRDiscussionTarget?, request: GitLabMergeRequest?,
              discussions: [GitLabMergeRequestDiscussion], hasLoaded: Bool, hasError: Bool) {
            guard hasLoaded, !hasError, loadedTarget == target, !target.username.isEmpty,
                  let request, request.projectID == target.projectID, request.iid == target.iid,
                  request.webURL == target.url,
                  target.url.isGitLabMergeRequest(host: target.host, iid: target.iid) else { return nil }
            self.target = target
            headSHA = request.sha
            semanticContextFingerprint = request.semanticContextFingerprint
            discussionFingerprint = ReviewVerdict.fingerprint(discussions)

            // Derive evidence once for this immutable load. Duplicate identities stay
            // ambiguous even when a later copy has otherwise valid quotation data.
            var citations: [Int: MRCommentCitation] = [:]
            var rootNoteIDs: [String: Int] = [:]
            var seenNoteIDs: Set<Int> = []
            var seenDiscussionIDs: Set<String> = []
            for discussion in discussions {
                if let id = discussion.id {
                    if seenDiscussionIDs.insert(id).inserted {
                        rootNoteIDs[id] = discussion.notes.first?.id
                    } else {
                        rootNoteIDs.removeValue(forKey: id)
                    }
                }
                for note in discussion.notes {
                    guard let id = note.id, id > 0 else { continue }
                    if seenNoteIDs.insert(id).inserted {
                        citations[id] = Self.citation(id, discussionID: discussion.id, note: note, target: target)
                    } else {
                        citations.removeValue(forKey: id)
                    }
                }
            }
            self.citations = citations
            self.rootNoteIDs = rootNoteIDs
        }

        func finding(_ finding: AuthorFeedbackPolicy.Finding, status: AuthorFeedbackStatus) -> MRCommentCitation? {
            guard status.phase == .complete || status.phase == .waitingPublication,
                  !status.head.isEmpty, status.head == headSHA,
                  status.semanticContextFingerprint == semanticContextFingerprint,
                  status.fingerprint == discussionFingerprint,
                  let id = finding.sourceNoteID else { return nil }
            return citations[id]
        }

        func comment(_ id: Int, fingerprint: String?) -> MRCommentCitation? {
            guard let fingerprint, fingerprint == discussionFingerprint else { return nil }
            return citations[id]
        }

        func reply(to draft: GitLabDraftNote, rootNoteID: Int? = nil) -> MRCommentCitation? {
            guard let id = draft.discussionID, !id.isEmpty else { return nil }
            guard let root = rootNoteIDs[id],
                  rootNoteID == nil || rootNoteID == root,
                  let source = citations[root], source.discussionID == id else { return nil }
            return source
        }

        @MainActor func followUp(_ job: AssistantAutomationRunner.Handoff) -> [MRCommentCitation] {
            guard job.workflow == .followUp, job.key.work.host == target.host,
                  job.key.username == target.username, job.key.work.projectID == target.projectID,
                  job.key.work.iid == target.iid, job.mergeRequestURL == target.url,
                  let head = job.expectedHeadSHA, !head.isEmpty, head == headSHA,
                  let state = job.operationalExecution?.state, [.failed, .blocked, .interrupted, .cancelled].contains(state),
                  let ids = job.feedbackNoteIDs, !ids.isEmpty, ids.allSatisfy({ $0 > 0 }),
                  Set(ids).count == ids.count else { return [] }
            let sources = ids.sorted().compactMap { citations[$0] }
            return sources.count == ids.count ? sources : []
        }

        private static func citation(_ id: Int, discussionID: String?, note: GitLabMergeRequestDiscussion.Note,
                                     target: MRDiscussionTarget) -> MRCommentCitation? {
            guard note.system == false, let author = note.author, author.id > 0,
                  let body = note.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var components = URLComponents(url: target.url, resolvingAgainstBaseURL: false)
            components?.fragment = "note_\(id)"
            guard let url = components?.url else { return nil }
            return .init(id: id, discussionID: discussionID, note: note, url: url)
        }
    }
}
