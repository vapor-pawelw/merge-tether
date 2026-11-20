import Foundation
import Testing
@testable import MergeTether

@MainActor
struct DuplicateReplyDraftsTests {
    private let me = 3

    private func note(_ id: Int, author: Int, body: String, system: Bool = false) -> GitLabMergeRequestDiscussion.Note {
        .init(id: id, author: .init(id: author, username: "user\(author)", name: nil), system: system,
              resolvable: true, resolved: false, resolvedBy: nil, body: body)
    }
    private func thread(_ id: String, _ notes: [GitLabMergeRequestDiscussion.Note]) -> GitLabMergeRequestDiscussion {
        .init(id: id, notes: notes)
    }
    private func draft(_ id: Int, _ text: String, thread: String? = "t1") -> GitLabDraftNote {
        .init(id: id, authorID: me, note: text, discussionID: thread, position: nil)
    }

    @Test func aDraftRepeatingMyPublishedReplyInTheSameThreadIsADuplicate() {
        let discussions = [thread("t1", [note(1, author: 9, body: "Please log this"),
                                         note(2, author: me, body: "Poprawione, dzięki.\n")])]
        let published = DuplicateReplyDrafts.publishedReplies(in: discussions, userID: me)
        #expect(DuplicateReplyDrafts.ids(in: [draft(11, "  Poprawione,   dzięki. ")], published: published) == [11])
    }

    @Test func otherThreadsOtherAuthorsSystemNotesAndNewTextAreNotDuplicates() {
        let discussions = [
            thread("t1", [note(1, author: 9, body: "Same text"), note(2, author: me, body: "Changed", system: true)]),
            thread("t2", [note(3, author: me, body: "Mine elsewhere")]),
        ]
        let published = DuplicateReplyDrafts.publishedReplies(in: discussions, userID: me)
        let drafts = [draft(11, "Same text"), draft(12, "Changed"), draft(13, "Mine elsewhere"),
                      draft(14, "Mine elsewhere", thread: nil), draft(15, "New reply")]
        #expect(DuplicateReplyDrafts.ids(in: drafts, published: published).isEmpty)
    }

    @Test func onlyTheNewerOfTwoIdenticalDraftsInAThreadIsADuplicate() {
        let drafts = [draft(21, "Fixed, thanks"), draft(20, "Fixed, thanks"), draft(22, "Fixed, thanks", thread: "t2")]
        #expect(DuplicateReplyDrafts.ids(in: drafts, published: []) == [21])
    }

    @Test func aDuplicateNeverOffersDirectPublicationAndStartsUnchecked() throws {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example MR",
            url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!)
        let duplicate = draft(11, "Fixed, thanks")
        let fresh = draft(12, "Other reply", thread: "t2")
        item.drafts = [duplicate, fresh]
        item.draftCount = 2
        item.ownPublishedReplies = DuplicateReplyDrafts.publishedReplies(
            in: [thread("t1", [note(2, author: me, body: "Fixed, thanks")])], userID: me)
        #expect(item.duplicateDraftIDs == [11])

        let action = try #require(MRHumanAction(row: .init(item: item, latestJob: nil, intents: []), assistantReady: true))
        #expect(action.kind == .duplicateDrafts)
        #expect(action.draftPublicationShortcut(for: item.drafts) == nil)

        var session = DraftPublicationSession()
        session.open(with: item.drafts, duplicateIDs: item.duplicateDraftIDs)
        #expect(session.selection.selectedDrafts(from: item.drafts) == [fresh])
    }

    @Test func unreadDiscussionsNeverMarkADuplicate() {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example MR",
            url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!)
        item.drafts = [draft(11, "Fixed, thanks")]
        #expect(item.duplicateDraftIDs.isEmpty)
    }
}
