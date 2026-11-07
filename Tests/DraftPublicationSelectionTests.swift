import Foundation
import Testing
@testable import GitLabTodos

struct DraftPublicationSelectionTests {
    private func draft(_ id: Int?, text: String = "Reviewed reply", discussion: String? = "thread") -> GitLabDraftNote {
        .init(id: id, authorID: 3, note: text, discussionID: discussion, position: nil)
    }

    @Test func selectionIsExplicitPreservesOrderAndNeverIncludesNewDrafts() {
        var selection = DraftPublicationSelection()
        let first = draft(11), second = draft(12), added = draft(13)
        #expect(selection.selectedDrafts(from: [first, second]).isEmpty)
        selection.setSelected(true, draft: second)
        selection.setSelected(true, draft: first)
        #expect(selection.isSelected(first))
        #expect(selection.selectedDrafts(from: [first, second, added]) == [first, second])
        selection.setSelected(false, draft: first)
        #expect(selection.selectedDrafts(from: [first, second, added]) == [second])
    }

    @Test(arguments: ["body", "thread", "removed", "duplicate"])
    func changedOrMissingDraftsLoseSelectionAndDoNotRegainIt(_ change: String) {
        var selection = DraftPublicationSelection()
        let original = draft(11), unchanged = draft(12)
        selection.setSelected(true, draft: original)
        selection.setSelected(true, draft: unchanged)
        let current: [GitLabDraftNote]
        switch change {
        case "body": current = [draft(11, text: "Edited reply"), unchanged]
        case "thread": current = [draft(11, discussion: "different"), unchanged]
        case "duplicate": current = [original, original, unchanged]
        default: current = [unchanged]
        }
        #expect(selection.selectedDrafts(from: current) == [unchanged])
        selection.reconcile(with: current)
        #expect(!selection.isSelected(original))
        #expect(selection.selectedDrafts(from: [original, unchanged]) == [unchanged])
    }

    @Test func draftsWithoutStablePositiveIDsCannotBeSelected() {
        var selection = DraftPublicationSelection()
        let valid = draft(12)
        for note in [draft(nil), draft(0), draft(-1), valid] { selection.setSelected(true, draft: note) }
        #expect(selection.selectedDrafts(from: [draft(nil), draft(0), draft(-1), valid]) == [valid])
    }
}
