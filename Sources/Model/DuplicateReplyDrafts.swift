import Foundation

/// Finds private drafts that repeat a reply already in the same thread. Publishing one would
/// post the same text twice, so it is never published automatically or by "Publish all".
enum DuplicateReplyDrafts {
    struct Reply: Hashable, Sendable {
        let discussionID: String
        let body: String
    }

    /// Whitespace-insensitive, so a reformatted copy still counts as the same reply.
    static func normalized(_ body: String?) -> String {
        (body ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func publishedReplies(in discussions: [GitLabMergeRequestDiscussion], userID: Int) -> Set<Reply> {
        guard userID > 0 else { return [] }
        var result: Set<Reply> = []
        for discussion in discussions {
            guard let id = discussion.id, !id.isEmpty else { continue }
            for note in discussion.notes where note.system != true && note.author?.id == userID {
                let body = normalized(note.body)
                if !body.isEmpty { result.insert(.init(discussionID: id, body: body)) }
            }
        }
        return result
    }

    /// Draft IDs repeating a published reply of the same thread, or an older draft of that thread.
    static func ids(in drafts: [GitLabDraftNote], published: Set<Reply>) -> Set<Int> {
        var seen: Set<Reply> = []
        var duplicates: Set<Int> = []
        for draft in drafts.sorted(by: { ($0.id ?? 0) < ($1.id ?? 0) }) {
            guard let id = draft.id, id > 0, let thread = draft.discussionID, !thread.isEmpty else { continue }
            let body = normalized(draft.note)
            guard !body.isEmpty else { continue }
            let reply = Reply(discussionID: thread, body: body)
            if published.contains(reply) || seen.contains(reply) { duplicates.insert(id) }
            seen.insert(reply)
        }
        return duplicates
    }
}
