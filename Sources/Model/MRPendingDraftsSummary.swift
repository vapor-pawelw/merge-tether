import Foundation

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

    var message: LocalizedStringResource {
        let base: LocalizedStringResource = count == 1 ? .Board.boardPendingDraftsSingle : .Board.boardPendingDrafts(count)
        guard !awaitingReply.isEmpty else { return base }
        let drafts = String(localized: base)
        let names = awaitingReply.prefix(3).compactMap(\.displayName).joined(separator: ", ")
        return awaitingReply.count > 3
            ? .Board.boardPendingDraftsAwaitingReplyMore(drafts, names, awaitingReply.count - 3)
            : .Board.boardPendingDraftsAwaitingReply(drafts, names)
    }
}
