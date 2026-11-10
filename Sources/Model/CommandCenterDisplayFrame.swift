import Foundation

/// Values prepared for one render, never retained as evidence for a command.
@MainActor
struct CommandCenterDisplayFrame {
    struct Inbox {
        let items: [MergeRequestBoardSnapshot.OtherCard]
        let triage: [MergeRequestBoardSnapshot.OtherCard]
        let jobs: [MergeRequestBoardSnapshot.OtherCard]
        let updates: [MergeRequestBoardSnapshot.OtherCard]

        init(items: [MergeRequestBoardSnapshot.OtherCard]) {
            self.items = items
            var triage: [MergeRequestBoardSnapshot.OtherCard] = []
            var jobs: [MergeRequestBoardSnapshot.OtherCard] = []
            var updates: [MergeRequestBoardSnapshot.OtherCard] = []
            for item in items {
                switch item.content {
                case .proposal, .todo: triage.append(item)
                case .job: jobs.append(item)
                case .completion: updates.append(item)
                }
            }
            self.triage = triage
            self.jobs = jobs
            self.updates = updates
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
