import Foundation

/// Immutable display values, never evidence for a command.
@MainActor
struct CommandCenterDisplayFrame {
    struct Inbox {
        let items: [MergeRequestBoardSnapshot.OtherCard]
        let triage: [MergeRequestBoardSnapshot.OtherCard]
        let jobs: [MergeRequestBoardSnapshot.OtherCard]
        let updates: [MergeRequestBoardSnapshot.OtherCard]
        let notificationIDs: [BoardCardPin]

        init(items: [MergeRequestBoardSnapshot.OtherCard]) {
            self.items = items
            var triage: [MergeRequestBoardSnapshot.OtherCard] = []
            var jobs: [MergeRequestBoardSnapshot.OtherCard] = []
            var updates: [MergeRequestBoardSnapshot.OtherCard] = []
            var notificationIDs: [BoardCardPin] = []
            for item in items {
                switch item.content {
                case .proposal: triage.append(item)
                case .todo:
                    triage.append(item)
                    notificationIDs.append(item.id)
                case .job: jobs.append(item)
                case .completion, .hiddenReview:
                    updates.append(item)
                    notificationIDs.append(item.id)
                }
            }
            self.triage = triage
            self.jobs = jobs
            self.updates = updates
            self.notificationIDs = notificationIDs
        }
    }

    struct Detail {
        let row: MergeRequestBoardSnapshot.Row?
        let item: MergeRequestAttentionMonitor.Item
        let isReviewed: Bool

        init(item: MergeRequestAttentionMonitor.Item, board: MergeRequestBoardSnapshot, host: String?, username: String?) {
            let row = board.row(matching: item, host: host, username: username)
            let selected = row?.item ?? item
            self.row = row
            self.item = selected
            isReviewed = row != nil && board.isReviewed(selected)
        }
    }

    let board: MergeRequestBoardSnapshot
    let inbox: Inbox

    init(board: MergeRequestBoardSnapshot, jobs: [AssistantAutomationRunner.Handoff],
         host: String?, username: String?, pinnedCards: Set<BoardCardPin>) {
        self.board = board
        inbox = .init(items: board.otherCards(jobs: jobs, host: host, username: username, pinnedCards: pinnedCards))
    }
}
