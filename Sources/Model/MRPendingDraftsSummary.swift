import Foundation
import MergeTetherRemote

/// Unpublished drafts on an MR and the people whose threads they answer. Display only:
/// it never grants publication or resolution permission.
struct MRPendingDraftsSummary: Equatable {
    let count: Int
    /// Other participants of threads that only have a draft reply so far, in thread order.
    let awaitingReply: [PersonIdentity]

    init?(item: MergeRequestAttentionMonitor.Item) {
        let count = max(item.draftCount, item.drafts.count)
        guard count > 0 else { return nil }
        self.count = count
        var seen: Set<String> = []
        awaitingReply = item.drafts.compactMap(\.discussionID).flatMap { item.replyRecipients[$0] ?? [] }.filter {
            guard let key = $0.normalizedUsername?.lowercased() else { return false }
            return seen.insert(key).inserted
        }
    }

    private var draftCountMessage: LocalizedStringResource {
        count == 1 ? .Board.boardPendingDraftsSingle : .Board.boardPendingDrafts(count)
    }

    var peopleMessage: RemotePeopleMessage? {
        .init(.Board.boardPendingDraftsForPeoplePrefix(String(localized: draftCountMessage)), people: awaitingReply)
    }

    var message: LocalizedStringResource { peopleMessage?.resource ?? draftCountMessage }
}
