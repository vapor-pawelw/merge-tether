import Foundation

/// Holds the exact draft snapshots chosen by the user, not just reusable note IDs.
struct DraftPublicationSelection {
    private var selected: [Int: GitLabDraftNote] = [:]

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
