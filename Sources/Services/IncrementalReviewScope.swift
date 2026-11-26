import Foundation

/// Digest of an MR diff's content that ignores text blob IDs and hunk offsets. Binary summaries
/// rely on their index lines to distinguish revisions.
enum MergeRequestDiffDigest {
    static func normalized(_ diff: String) -> String {
        var binaryFile = false
        // Walk backwards because Git writes the index before the binary marker.
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).reversed().compactMap { line -> Substring? in
            if line.hasPrefix("diff --git ") { binaryFile = false }
            if line == "GIT binary patch" || (line.hasPrefix("Binary files ") && line.hasSuffix(" differ")) {
                binaryFile = true
            }
            if line.hasPrefix("index ") && !binaryFile { return nil }
            if line.hasPrefix("@@") { return "@@" }
            return line
        }
        return UserAttentionSnapshot.digest(lines.reversed().joined(separator: "\n"))
    }

    /// Text revision of every non-system note, used to tell which notes changed since a review pass.
    static func noteRevisions(_ discussions: [GitLabMergeRequestDiscussion], excludingAuthor excluded: Int? = nil) -> [Int: String] {
        var revisions: [Int: String] = [:]
        for note in discussions.flatMap(\.notes) where note.system != true {
            guard let id = note.id, id > 0, let author = note.author?.id, author != excluded else { continue }
            revisions[id] = UserAttentionSnapshot.digest("\(author)\n\(note.body ?? "")")
        }
        return revisions
    }

    static func changedNotes(from previous: [Int: String], to current: [Int: String]) -> [Int] {
        current.filter { previous[$0.key] != $0.value }.keys.sorted()
    }
}

struct ReviewDiffSnapshot: Codable, Equatable {
    let headSHA: String
    let digest: String
}

extension GlabService {
    func fetchReviewDiffSnapshot(for request: GitLabMergeRequest, host: String) async throws -> ReviewDiffSnapshot {
        guard let head = request.sha, !head.isEmpty else { throw AssistantJobExecutor.ExecutionError.headChanged }
        let diff: Data = try await mergeRequestAPI(
            "/projects/\(request.projectID)/merge_requests/\(request.iid)/raw_diffs", host: host, decode: { $0 })
        // GitLab returns the latest raw diff. Check the head after reading it against the prior observation.
        let current = try await fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
        guard current.state == .opened, current.sha == head else { throw AssistantJobExecutor.ExecutionError.headChanged }
        return ReviewDiffSnapshot(headSHA: head, digest: MergeRequestDiffDigest.normalized(String(decoding: diff, as: UTF8.self)))
    }
}

/// What a reviewer's follow-up pass on another author's MR may cover. A review pass assesses the MR once;
/// later passes look only at what changed since, so unrelated edits never reopen the whole MR.
struct IncrementalReviewScope: Equatable, Sendable {
    static let manualReviewIntroduction = "Perform an explicit user-requested review or re-review of this merge request."
    static let metadataReviewInstructions = """
        Your recorded review does not cover the current MR title and description. Check the current requirements \
        against the diff and discussions, then record a fresh verdict. Save warranted private drafts without duplicates.
        """
    static let fullReviewInstructions = """
        Full review from scratch, explicitly requested by the user: review the entire current diff and every current \
        discussion as if for the first time. Earlier verdicts and scope limits do not apply. Still avoid duplicating \
        existing findings, published comments or drafts.
        """

    var reviewedHead: String?
    var currentHead: String?
    /// True when the MR's own changes are identical to the reviewed head's (a rebase or target merge only).
    var diffUnchanged = false
    var changedNoteIDs: [Int] = []
    var fullReview = false

    var instructions: String {
        if fullReview { return Self.fullReviewInstructions }
        var parts: [String] = []
        if let reviewedHead, currentHead == nil {
            parts.append("""
                Your earlier recorded review covered head \(reviewedHead). If the current head differs, this is an incremental \
                re-review: compare the MR diff version whose head_commit_sha is \(reviewedHead) with the latest version \
                (/projects/:id/merge_requests/:iid/versions), raise new findings only for code added or modified since that \
                review, and recheck whether your existing findings still apply.
                """)
        } else if let reviewedHead, let currentHead, reviewedHead != currentHead {
            if diffUnchanged {
                parts.append("""
                    Your earlier review covered head \(reviewedHead). The MR's own changes are identical at \(currentHead) \
                    (a rebase or target-branch update only). Do not review the code again and raise no new code findings: \
                    confirm that your existing findings still apply to the new head and record the verdict.
                    """)
            } else {
                parts.append("""
                    Incremental re-review. Your earlier review covered head \(reviewedHead); the current head is \(currentHead). \
                    Review only what changed since \(reviewedHead): use the MR diff versions \
                    (/projects/:id/merge_requests/:iid/versions) to compare the version whose head_commit_sha is \(reviewedHead) \
                    with the latest version, so a rebase does not count unrelated target-branch commits. Raise new findings only \
                    for code added or modified since that review. Recheck whether your existing findings still apply.
                    """)
            }
        }
        if !changedNoteIDs.isEmpty {
            parts.append("""
                Discussion notes new or edited since your review: \(changedNoteIDs.map(String.init).joined(separator: ", ")). \
                Assess only these notes and whether they change your existing findings; you may refer to earlier discussions \
                for context. Do not review unchanged code again.
                """)
        }
        guard !parts.isEmpty else { return "" }
        parts.append("""
            Do not raise new findings about code or discussions you already assessed and that did not change, and do not \
            re-raise points you already made or chose not to raise.
            """)
        return parts.joined(separator: " ")
    }
}
