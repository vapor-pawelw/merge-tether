import Foundation
import MergeTetherRemote

extension RemoteApprovalDetails {
    init(progress: MergeRequestApprovalProgress?, reviewers: [Todo.Author], viewerUsername: String?,
         isOwnMergeRequest: Bool, rules: [RemoteApprovalRule]? = nil,
         requirementsSatisfied: Bool? = nil, historyAvailable: Bool = false,
         reviewHistory: MergeRequestReviewHistory = .init()) {
        let people = progress?.participants(reviewers: reviewers)
            ?? MergeRequestApprovalProgress.participants(reviewers: reviewers, history: reviewHistory)
        let viewer = progress?.viewerApproval(username: viewerUsername, reviewers: reviewers,
            isOwnMergeRequest: isOwnMergeRequest)?.author
        self.init(progress: progress.flatMap {
            .init(completed: min($0.completed, $0.required), required: $0.required,
                received: $0.completed, requirementsSatisfied: $0.requirementsSatisfied)
        }, people: people.map {
            .init(id: $0.id, name: $0.author.name, username: $0.author.username,
                status: .init(rawValue: String(describing: $0.status)) ?? .assigned,
                changedAt: $0.changedAt, avatarURL: $0.author.avatarURL)
        }, rules: rules, requirementsSatisfied: requirementsSatisfied, historyAvailable: historyAvailable,
            viewerApprovalID: viewer?.id)
        self.people = orderedPeople
    }
}
