import Foundation
import Testing
@testable import GitLabTodos

struct InboxSnapshotTests {
    private let host = "gitlab.example.org"
    private func todo(_ id: Int = 1, action: ActionName, noteID: Int? = nil, projectID: Int = 1,
                      iid: Int = 42, host: String = "gitlab.example.org", targetType: TargetType = .mergeRequest) -> Todo {
        Todo(id: id, actionName: action, targetType: targetType,
             targetURL: URL(string: "https://\(host)/g/p/-/merge_requests/\(iid)" + (noteID.map { "#note_\($0)" } ?? ""))!,
             body: "Fix", createdAt: Date(), state: "pending",
             project: .init(id: projectID, nameWithNamespace: "Group / Project", pathWithNamespace: "g/p"),
             author: .init(id: 7, username: "reviewer", name: "Reviewer", avatarURL: nil),
             target: .init(id: 1, iid: iid, title: "Fix", state: "opened", draft: false, workInProgress: false))
    }
    private func attention() -> MergeRequestAttentionMonitor.Item {
        .init(id: .init(projectID: 1, iid: 42), title: "Fix", url: URL(string: "https://\(host)/g/p/-/merge_requests/42")!)
    }
    private func snapshot(_ todos: [Todo], _ items: [MergeRequestAttentionMonitor.Item]) -> InboxSnapshot {
        .init(todos: todos, attention: items, host: host, username: "me")
    }

    @Test func samePipelineOrConflictIsCountedOnlyAsItsGitLabTodo() {
        var item = attention()
        item.failedPipeline = true
        item.hasConflict = true
        let result = snapshot([todo(action: .buildFailed), todo(2, action: .unmergeable)], [item])
        #expect(result.count == 2)
        #expect(result.attention.isEmpty)
        #expect(item.failedPipeline && item.hasConflict)
    }

    @Test func draftsApprovalAndOtherActionsSurviveAnUnrelatedTodoOnTheSameMR() {
        var item = attention()
        item.hasConflict = true
        item.draftCount = 2
        item.canApprove = true
        item.reReviewUnconfirmed = true
        let result = snapshot([todo(action: .unmergeable)], [item])
        #expect(result.count == 2)
        let visible = result.attention.first
        #expect(visible?.hasConflict == false)
        #expect(visible?.draftCount == 2 && visible?.canApprove == true && visible?.reReviewUnconfirmed == true)
    }

    @Test func onlyCoveredFeedbackDisappearsAndMarkingTodoReadRevealsItsReason() {
        var item = attention()
        item.needsDiscussion = true
        item.feedback = [42, 43].map {
            .init(id: $0, author: .init(id: 7, username: "reviewer", name: "Reviewer"), system: false,
                  resolvable: true, resolved: false, resolvedBy: nil)
        }
        let result = snapshot([todo(action: .mentioned, noteID: 42)], [item])
        #expect(result.attention.first?.feedback.compactMap(\.id) == [43])
        #expect(result.attention.first?.needsDiscussion == true)
        let both = snapshot([todo(action: .mentioned, noteID: 42), todo(2, action: .directlyAddressed, noteID: 43)], [item])
        #expect(both.attention.isEmpty && both.count == 2)
        #expect(snapshot([], [item]).attention.first?.feedback.count == 2)
    }

    @Test func targetIdentityIncludesHostProjectAndTargetType() {
        var item = attention()
        item.hasConflict = true
        for other in [todo(action: .unmergeable, projectID: 9), todo(action: .unmergeable, iid: 9),
                      todo(action: .unmergeable, host: "other.example.org"), todo(action: .unmergeable, targetType: .issue)] {
            #expect(snapshot([other], [item]).attention.first?.hasConflict == true)
        }
    }

    @Test func notificationDoesNotHidePipelineOwnershipConfirmationOrUnverifiedThreads() {
        var item = attention()
        item.failedPipeline = true
        item.needsPipelineHandoff = true
        item.needsDiscussion = true
        let result = snapshot([todo(action: .buildFailed), todo(2, action: .marked)], [item])
        #expect(result.attention.first?.failedPipeline == false)
        #expect(result.attention.first?.needsPipelineHandoff == true && result.attention.first?.needsDiscussion == true)
    }

    @Test func approvalTodoKeepsItsVerifiedApproveActionWithoutAnExtraAttentionCard() {
        var item = attention()
        item.canApprove = true
        let result = snapshot([todo(action: .approvalRequired)], [item])
        #expect(result.count == 1 && result.attention.isEmpty)
        #expect(result.todoApprovals[1] == item.id)
        #expect(snapshot([], [item]).attention.first?.canApprove == true)
        #expect(snapshot([todo(action: .reviewRequested)], [item]).count == 2)
    }

    @Test func submittedReviewCoversTheSameRequestedChangesButKeepsUnpublishedDrafts() {
        var item = attention()
        item.needsChanges = true
        item.needsDiscussion = true
        item.draftCount = 1
        item.feedback = [.init(id: 42, author: .init(id: 7, username: "reviewer", name: "Reviewer"),
                               system: false, resolvable: true, resolved: false, resolvedBy: nil)]
        let result = snapshot([todo(action: .reviewSubmitted)], [item])
        #expect(result.attention.first?.needsChanges == false)
        #expect(result.attention.first?.needsDiscussion == false)
        #expect(result.attention.first?.draftCount == 1)
    }
}
