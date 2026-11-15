import Foundation
import Testing
import MergeTetherRemote
@testable import GitLabTodos

@MainActor @Suite struct RemoteMRControlsTests {
    private func item(phase: AuthorFeedbackStatus.Phase = .complete, staleHead: Bool = false) throws -> MergeRequestAttentionMonitor.Item {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Feature","labels":[],"web_url":"https://gitlab.example.test/g/p/-/merge_requests/2","state":"opened","draft":false,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_branch":"feature","target_branch":"main"}"#.utf8))
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: request.title,
            url: request.webURL, humanActionRequired: true, mergeRequest: request, isAuthored: true)
        item.observedDiscussionFingerprint = "conversation"
        item.authorFeedbackStatus = .init(head: staleHead ? String(repeating: "b", count: 40) : request.sha!,
            fingerprint: "conversation", semanticContextFingerprint: request.semanticContextFingerprint, phase: phase,
            findings: [
                .init(id: 10, discussionID: "a", reviewerID: 7, reviewerUsername: "alice", state: .needsChanges,
                      reason: "Rename the retry helper", waitingForReviewers: [], summary: "Rename helper", sourceNoteID: 10),
                .init(id: 20, discussionID: "b", reviewerID: 7, reviewerUsername: "alice", state: .needsChanges,
                      reason: "  ", waitingForReviewers: [], sourceNoteID: 20),
                .init(id: 30, discussionID: "c", reviewerID: 7, reviewerUsername: "alice", state: .ready,
                      reason: "Already answered", waitingForReviewers: [], sourceNoteID: 30),
                .init(id: 40, discussionID: "d", reviewerID: 7, reviewerUsername: "alice", state: .ready,
                      reason: "Reply to the naming question", waitingForReviewers: [], sourceNoteID: 40),
            ], replyNoteIDs: [40])
        return item
    }

    @Test func onlyCurrentExplainedFindingsThatStillAskForWorkCanBeIgnored() throws {
        let suggestions = RemoteBoardAdapter.ignorableSuggestions(try item())
        #expect(suggestions.map(\.findingID) == [10, 40])
        #expect(suggestions.first?.summary == "Rename helper")
        #expect(suggestions.last?.summary == "Reply to the naming question")
    }

    @Test(arguments: ["checking", "failed", "staleHead", "staleConversation"])
    func anUnsettledOrStaleAssessmentOffersNothingToIgnore(_ state: String) throws {
        var item = try item(phase: state == "checking" ? .checking : state == "failed" ? .failed : .complete,
                            staleHead: state == "staleHead")
        if state == "staleConversation" { item.observedDiscussionFingerprint = "edited" }
        #expect(RemoteBoardAdapter.ignorableSuggestions(item).isEmpty)
    }
}
