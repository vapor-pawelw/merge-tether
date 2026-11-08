import Foundation

/// Semantic assessment is content-bound. The app, rather than the model, selects recipients
/// and performs a final live account/head/discussion/draft check before notifying anyone.
struct ReReviewAssessment: Codable, Sendable {
    struct Note: Codable, Sendable {
        enum State: String, Codable, Sendable { case addressed, informational, blocking, uncertain }
        let noteID: Int
        let state: State
        let reason: String
        var summary: String? = nil
        var acceptanceNoteID: Int? = nil
        // Legacy assessments omit this field and never authorize a reaction or informational closure.
        var informationalAcknowledgementSafe: Bool? = nil
    }
    let notes: [Note]

    /// Addressed code does not replace an explanation still owed in an open thread.
    /// Discussion notes are published evidence; private drafts never satisfy it.
    func missingPublishedReplyNoteIDs(in discussions: [GitLabMergeRequestDiscussion], authorID: Int) -> Set<Int> {
        let addressed = Set(notes.filter { $0.state == .addressed }.map(\.noteID))
        return Set(discussions.flatMap { thread in
            thread.notes.compactMap { note -> Int? in
                guard let id = note.id, addressed.contains(id), note.resolvable == true, note.resolved == false,
                      !thread.notes.contains(where: {
                          $0.system == false && $0.author?.id == authorID && ($0.id ?? 0) > id
                      }) else { return nil }
                return id
            }
        })
    }

    /// The thread root anchors presentation, while each owed note remains the worker's scope.
    func missingPublishedRepliesByThread(in discussions: [GitLabMergeRequestDiscussion], authorID: Int) -> [Int: Set<Int>] {
        let owed = missingPublishedReplyNoteIDs(in: discussions, authorID: authorID)
        var threads: [Int: Set<Int>] = [:]
        for discussion in discussions {
            guard let rootID = discussion.notes.first?.id else { continue }
            let scoped = Set(discussion.notes.compactMap(\.id)).intersection(owed)
            if !scoped.isEmpty { threads[rootID, default: []].formUnion(scoped) }
        }
        return threads
    }

    enum ValidationError: Error { case incompleteEvidence }
    func reviewers(in discussions: [GitLabMergeRequestDiscussion], authorID: Int) throws -> [Int: Int] {
        let external = discussions.flatMap(\.notes).filter { $0.system != true && $0.author?.id != authorID }
        guard external.allSatisfy({ ($0.id ?? 0) > 0 && ($0.author?.id ?? 0) > 0 && $0.body != nil }),
              Set(external.compactMap(\.id)).count == external.count,
              notes.count == external.count, Set(notes.map(\.noteID)) == Set(external.compactMap(\.id)),
              notes.allSatisfy({ !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.reason.count <= 600 })
        else { throw ValidationError.incompleteEvidence }
        let byID = Dictionary(uniqueKeysWithValues: notes.map { ($0.noteID, $0) })
        var ready: [Int: Int] = [:]
        var blocked: Set<Int> = []
        for note in external {
            guard let id = note.id, let reviewer = note.author?.id, let assessment = byID[id] else {
                throw ValidationError.incompleteEvidence
            }
            switch assessment.state {
            case .addressed: ready[reviewer] = max(ready[reviewer] ?? 0, id)
            case .blocking, .uncertain: blocked.insert(reviewer)
            case .informational: break
            }
        }
        return ready.filter { !blocked.contains($0.key) }
    }
}
