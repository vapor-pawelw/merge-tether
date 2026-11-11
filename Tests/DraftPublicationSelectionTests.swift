import Foundation
import Testing
@testable import GitLabTodos

struct DraftPublicationSelectionTests {
    @Test(arguments: ["/merge", "Reply\n  /approve", "```\n/close\n```", "Reply\r\n\t/merge"])
    func manualPreviewWarnsAboutPotentialCommandsWithoutBlockingSelection(_ body: String) throws {
        let note = draft(11, text: body)
        let risk = try #require(DraftPublicationRisk(draft: note))
        #expect(risk.id == 11 && risk.discussionID == "thread")
        #expect(risk.hasPotentialQuickActions && !risk.resolvesDiscussion)
        #expect(!risk.messages.isEmpty)
        #expect(DraftPublicationSelection(selectingAll: [note]).selectedDrafts(from: [note]) == [note])
        #expect(!AutomaticPublicationPolicy.safeForAutomaticPublication(note))
    }

    @Test func selectedWarningsFollowExactDraftContentAndNeverIncludeUnselectedOrNewDrafts() throws {
        let ordinary = draft(11, text: "See https://example.test/path and /merge documentation")
        var resolving = draft(12)
        resolving.resolveDiscussion = true
        let unselected = draft(14, text: "/close")
        let unseen = draft(13, text: "/merge")
        var selection = DraftPublicationSelection(selectingAll: [ordinary, resolving, unselected])
        selection.setSelected(false, draft: unselected)
        #expect(DraftPublicationRisk(draft: ordinary) == nil)
        let risks = selection.selectedDrafts(from: [ordinary, resolving, unselected, unseen]).compactMap(DraftPublicationRisk.init)
        #expect(risks.map(\.id) == [12])
        #expect(risks.first?.resolvesDiscussion == true)
        #expect(risks.first?.hasPotentialQuickActions == false)
        let edited = draft(12, text: "/close")
        #expect(selection.selectedDrafts(from: [ordinary, edited, unseen]).compactMap(DraftPublicationRisk.init).isEmpty)
    }

    @Test func resolvingCommandDraftShowsBothWarningsWithItsCurrentThread() throws {
        var note = draft(11, text: "/approve", discussion: "current-thread")
        note.resolveDiscussion = true
        let risk = try #require(DraftPublicationRisk(draft: note))
        #expect(risk.hasPotentialQuickActions && risk.resolvesDiscussion)
        let messages = risk.messages.map { String(localized: $0) }
        #expect(messages.count == 3)
        #expect(messages.contains { $0.contains("11") && $0.contains("quick actions") })
        #expect(messages.contains { $0.contains("11") && $0.contains("resolve") })
        #expect(messages.contains { $0.contains("current-thread") })
    }

    @Test func anEmptyWindowNeverAutomaticallySelectsLaterDrafts() {
        var session = DraftPublicationSession()
        let later = draft(11)
        session.open(with: [])
        session.draftsChanged([later])
        #expect(session.selection.selectedDrafts(from: [later]).isEmpty)
        session.close()
        session.open(with: [later])
        #expect(session.selection.selectedDrafts(from: [later]) == [later])
    }

    @Test func appearingAgainOrRestoringAnAccountCannotOverrideChoicesInAnOpenWindow() {
        // given
        var session = DraftPublicationSession()
        let drafts = [draft(11), draft(12)]
        session.open(with: drafts)
        session.selection.setSelected(false, draft: drafts[0])
        // when + then
        session.open(with: drafts)
        #expect(session.selection.selectedDrafts(from: drafts) == [drafts[1]])
        session.clearSelection()
        session.draftsChanged(drafts + [draft(13)])
        session.open(with: drafts)
        #expect(session.selection.selectedDrafts(from: drafts).isEmpty)
        session.close()
        session.open(with: drafts)
        #expect(session.selection.selectedDrafts(from: drafts) == drafts)
    }

    @Test func aWindowWithoutAnAccountHasNoPublishableDefaults() {
        var session = DraftPublicationSession()
        let drafts = [draft(11)]
        session.open(with: drafts, accountAvailable: false)
        #expect(session.selection.selectedDrafts(from: drafts).isEmpty)
    }

    @Test func openingDetailsSelectsAllCurrentDraftsAndReopeningResetsLocalChoices() {
        // given
        let first = draft(11), second = draft(12), addedLater = draft(13)
        var selection = DraftPublicationSelection(selectingAll: [first, second])
        #expect(selection.selectedDrafts(from: [first, second]) == [first, second])
        // when
        selection.setSelected(false, draft: first)
        selection.reconcile(with: [first, second, addedLater])
        // then
        #expect(selection.selectedDrafts(from: [first, second, addedLater]) == [second])
        selection = DraftPublicationSelection(selectingAll: [first, second, addedLater])
        #expect(selection.selectedDrafts(from: [first, second, addedLater]) == [first, second, addedLater])
    }

    @Test func defaultSelectionExcludesAmbiguousAndInvalidDrafts() {
        let first = draft(11), valid = draft(12)
        let drafts = [first, first, draft(nil), draft(0), draft(13, text: " "), valid]
        let selection = DraftPublicationSelection(selectingAll: drafts)
        #expect(selection.selectedDrafts(from: drafts) == [valid])
    }

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
