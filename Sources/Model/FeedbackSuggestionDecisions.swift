import Foundation

struct IgnoredFeedbackSuggestion: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let target: MRAutomationScope.Target
    let sourceNoteID: Int
    let sourceAuthorID: Int
    var sourceAuthorUsername: String? = nil
    var sourceAuthorName: String? = nil
    let sourceBody: String
    let sourceRevision: String
    let concernSummary: String
    let concernReason: String
    let createdAt: Date

    func matches(_ note: GitLabMergeRequestDiscussion.Note) -> Bool {
        note.id == sourceNoteID && note.author?.id == sourceAuthorID && note.body == sourceBody
            && Self.revision(of: note) == sourceRevision
    }

    static func revision(of note: GitLabMergeRequestDiscussion.Note) -> String? {
        guard let id = note.id, id > 0, let author = note.author, author.id > 0,
              note.system == false, let body = note.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return UserAttentionSnapshot.digest("\(author.id)\n" + body)
    }
}

struct FeedbackSuggestionDecisions: Codable, Equatable, Sendable {
    private var decisions: [IgnoredFeedbackSuggestion] = []
    private struct Epoch: Codable, Equatable, Sendable {
        let target: MRAutomationScope.Target
        var id: UUID
    }
    private var epochs: [Epoch]? = nil

    func entries(for target: MRAutomationScope.Target) -> [IgnoredFeedbackSuggestion] {
        decisions.filter { $0.target == target }
    }

    func applicable(in discussions: [GitLabMergeRequestDiscussion], for target: MRAutomationScope.Target) -> [IgnoredFeedbackSuggestion] {
        let notes = discussions.flatMap(\.notes)
        return entries(for: target).filter { entry in
            let sources = notes.filter { $0.id == entry.sourceNoteID }
            return sources.count == 1 && entry.matches(sources[0])
        }
    }

    /// Only an untouched empty ledger preserves the legacy no-exception context.
    func revision(for target: MRAutomationScope.Target) -> String {
        let active = entries(for: target).sorted { $0.id.uuidString < $1.id.uuidString }
        let epoch = epochs?.first(where: { $0.target == target })?.id.uuidString ?? ""
        guard !active.isEmpty else { return epoch }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(active) else { return "invalid" }
        return epoch + UserAttentionSnapshot.digest(String(decoding: data, as: UTF8.self))
    }

    @discardableResult
    mutating func ignore(_ note: GitLabMergeRequestDiscussion.Note, concernSummary: String, concernReason: String,
                         for target: MRAutomationScope.Target, id: UUID = UUID(), now: Date = Date()) -> IgnoredFeedbackSuggestion? {
        let summary = concernSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = concernReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.host.isEmpty, !target.username.isEmpty, target.projectID > 0, (target.iid ?? 0) > 0,
              !summary.isEmpty, !reason.isEmpty, let revision = IgnoredFeedbackSuggestion.revision(of: note),
              let noteID = note.id, let author = note.author, author.username != target.username, let body = note.body else { return nil }
        if let existing = entries(for: target).first(where: {
            $0.sourceNoteID == noteID && $0.sourceRevision == revision && $0.concernSummary == summary && $0.concernReason == reason
        }) { return existing }
        let entry = IgnoredFeedbackSuggestion(id: id, target: target, sourceNoteID: noteID, sourceAuthorID: author.id,
            sourceAuthorUsername: author.username, sourceAuthorName: author.name,
            sourceBody: body, sourceRevision: revision, concernSummary: summary, concernReason: reason, createdAt: now)
        decisions.append(entry)
        advanceEpoch(for: target)
        return entry
    }

    @discardableResult mutating func remove(_ id: UUID, for target: MRAutomationScope.Target) -> Bool {
        guard let index = decisions.firstIndex(where: { $0.id == id && $0.target == target }) else { return false }
        decisions.remove(at: index)
        advanceEpoch(for: target)
        return true
    }
    @discardableResult mutating func reset(for target: MRAutomationScope.Target) -> Int {
        let count = entries(for: target).count
        decisions.removeAll { $0.target == target }
        if count > 0 { advanceEpoch(for: target) }
        return count
    }

    private mutating func advanceEpoch(for target: MRAutomationScope.Target) {
        var current = epochs ?? []
        if let index = current.firstIndex(where: { $0.target == target }) { current[index].id = UUID() }
        else { current.append(.init(target: target, id: UUID())) }
        epochs = current
    }
}
