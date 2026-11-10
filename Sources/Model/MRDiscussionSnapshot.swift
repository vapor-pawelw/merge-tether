import Foundation

struct MRDiscussionTarget: Hashable, Sendable {
    let host: String
    let username: String
    let projectID: Int
    let iid: Int
    let url: URL
}

/// A read-only conversation projection. AI origin belongs to a single current note.
struct MRDiscussionSnapshot {
    enum Origin: Equatable, Sendable {
        case verifiedAssistant
        case assessed(evidence: String)
    }
    enum State: Equatable { case open, resolved, general }
    struct Thread: Identifiable {
        let id: String
        let discussionID: String?
        let notes: [GitLabMergeRequestDiscussion.Note]
        let drafts: [GitLabDraftNote]
        let state: State
        let location: String?
        let origins: [Int: Origin]
    }
    var threads: [Thread] = []
    var standaloneDrafts: [GitLabDraftNote] = []

    var pendingPublication: Self {
        var snapshot = self
        snapshot.threads = threads.filter { !$0.drafts.isEmpty }
        return snapshot
    }

    var remainingDiscussions: Self {
        var snapshot = self
        snapshot.threads = threads.filter { $0.drafts.isEmpty }
        snapshot.standaloneDrafts = []
        return snapshot
    }

    init(discussions: [GitLabMergeRequestDiscussion], drafts: [GitLabDraftNote], origins: [Int: Origin]) {
        var matchedDrafts: Set<Int> = []
        for (index, discussion) in discussions.enumerated() {
            let notes = discussion.notes.filter { $0.system != true }
            guard !notes.isEmpty else { continue }
            let pending = drafts.enumerated().filter { _, draft in
                guard let id = discussion.id, !id.isEmpty else { return false }
                return draft.discussionID == id
            }
            matchedDrafts.formUnion(pending.map(\.offset))
            let resolvable = notes.filter { $0.resolvable == true }
            let state: State = resolvable.isEmpty ? .general
                : resolvable.allSatisfy { $0.resolved == true } ? .resolved : .open
            let position = notes.compactMap(\.position).first
            let path = position?.newPath ?? position?.oldPath
            let line = position?.newLine ?? position?.oldLine
            let location = path.map { path in line.map { "\(path):\($0)" } ?? path }
            let noteIDs = Set(notes.compactMap(\.id))
            threads.append(.init(id: discussion.id.map { "discussion/\($0)" } ?? "unidentified/\(index)",
                discussionID: discussion.id, notes: notes, drafts: pending.map(\.element), state: state,
                location: location, origins: origins.filter { noteIDs.contains($0.key) }))
        }
        // Group by GitLab state without changing server order within a group.
        threads = [State.open, .resolved, .general].flatMap { state in
            threads.filter { $0.state == state }
        }
        standaloneDrafts = drafts.enumerated().filter { !matchedDrafts.contains($0.offset) }.map(\.element)
    }
}
