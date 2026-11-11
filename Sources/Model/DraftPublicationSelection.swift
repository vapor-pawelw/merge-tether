import Foundation

struct DraftPublicationRisk: Identifiable, Equatable, Sendable {
    let id: Int
    let discussionID: String?
    let hasPotentialQuickActions: Bool
    let resolvesDiscussion: Bool

    init?(draft: GitLabDraftNote) {
        guard let id = draft.id, id > 0 else { return nil }
        let hasPotentialQuickActions = (draft.note ?? "").split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("/")
        }
        let resolvesDiscussion = draft.resolveDiscussion == true
        guard hasPotentialQuickActions || resolvesDiscussion else { return nil }
        self.id = id
        discussionID = draft.discussionID
        self.hasPotentialQuickActions = hasPotentialQuickActions
        self.resolvesDiscussion = resolvesDiscussion
    }

    var messages: [LocalizedStringResource] {
        var result: [LocalizedStringResource] = []
        if hasPotentialQuickActions { result.append(.DraftPublication.draftPublicationQuickActions(id)) }
        if resolvesDiscussion { result.append(.DraftPublication.draftPublicationResolvesDiscussion(id)) }
        if let discussionID, !discussionID.isEmpty { result.append(.DraftPublication.draftPublicationThread(discussionID)) }
        return result
    }
}

/// Holds the exact draft snapshots chosen by the user, not just reusable note IDs.
struct DraftPublicationSelection {
    private var selected: [Int: GitLabDraftNote] = [:]

    init() {}

    init(selectingAll drafts: [GitLabDraftNote]) {
        for draft in drafts { setSelected(true, draft: draft) }
        reconcile(with: drafts)
    }

    static func canSelect(_ draft: GitLabDraftNote) -> Bool {
        (draft.id ?? 0) > 0 && draft.authorID > 0
            && draft.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func isSelected(_ draft: GitLabDraftNote) -> Bool {
        guard let id = draft.id, Self.canSelect(draft) else { return false }
        return selected[id] == draft
    }

    mutating func setSelected(_ enabled: Bool, draft: GitLabDraftNote) {
        guard let id = draft.id else { return }
        if enabled, Self.canSelect(draft) { selected[id] = draft }
        else { selected.removeValue(forKey: id) }
    }

    func selectedDrafts(from drafts: [GitLabDraftNote]) -> [GitLabDraftNote] {
        let counts = drafts.reduce(into: [Int: Int]()) { counts, draft in
            if let id = draft.id { counts[id, default: 0] += 1 }
        }
        return drafts.filter { isSelected($0) && $0.id.map { counts[$0] == 1 } == true }
    }

    mutating func reconcile(with drafts: [GitLabDraftNote]) {
        selected = Dictionary(uniqueKeysWithValues: selectedDrafts(from: drafts).compactMap { draft in
            draft.id.map { ($0, draft) }
        })
    }
}

/// Selection defaults belong to one presentation, never a poll or an account refresh.
struct DraftPublicationSession {
    var selection = DraftPublicationSelection()
    private var isOpen = false

    mutating func open(with drafts: [GitLabDraftNote], accountAvailable: Bool = true) {
        guard !isOpen else { return }
        isOpen = true
        selection = accountAvailable ? DraftPublicationSelection(selectingAll: drafts) : DraftPublicationSelection()
    }

    mutating func draftsChanged(_ drafts: [GitLabDraftNote]) { selection.reconcile(with: drafts) }
    mutating func clearSelection() { selection = DraftPublicationSelection() }
    mutating func close() { clearSelection(); isOpen = false }
}
