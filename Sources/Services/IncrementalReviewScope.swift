import Foundation

/// Digest of an MR diff's content that ignores blob IDs and hunk offsets, so a rebase that leaves
/// the MR's own changes intact keeps the same digest.
enum MergeRequestDiffDigest {
    static func normalized(_ diff: String) -> String {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> Substring? in
            if line.hasPrefix("index ") { return nil }
            if line.hasPrefix("@@") { return "@@" }
            return line
        }
        return UserAttentionSnapshot.digest(lines.joined(separator: "\n"))
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

extension GlabService {
    func fetchMergeRequestDiffDigest(projectID: Int, iid: Int, host: String) async throws -> String {
        let diff: Data = try await mergeRequestAPI("/projects/\(projectID)/merge_requests/\(iid)/raw_diffs", host: host, decode: { $0 })
        return MergeRequestDiffDigest.normalized(String(decoding: diff, as: UTF8.self))
    }
}

/// What a reviewer's follow-up pass on another author's MR may cover. A review pass assesses the MR once;
/// later passes look only at what changed since, so unrelated edits never reopen the whole MR.
struct IncrementalReviewScope: Equatable, Sendable {
    var reviewedHead: String?
    var currentHead: String?
    /// True when the MR's own changes are identical to the reviewed head's (a rebase or target merge only).
    var diffUnchanged = false
    var changedNoteIDs: [Int] = []
    var fullReview = false

    var instructions: String {
        if fullReview {
            return """
                Full review from scratch, explicitly requested by the user: review the entire current diff and every current \
                discussion as if for the first time. Earlier verdicts and scope limits do not apply. Still avoid duplicating \
                existing findings, published comments or drafts.
                """
        }
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
