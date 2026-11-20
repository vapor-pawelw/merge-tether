import Foundation
import Testing
import MergeTetherRemote
@testable import MergeTether

@MainActor @Suite struct RemoteMRControlsTests {
    @Test func inheritedCopiesOfOneConcernOfferOneIgnoreActionWithoutHidingDistinctConcerns() throws {
        var item = try item()
        let original = try #require(item.authorFeedbackStatus?.findings.first)
        let inherited = AuthorFeedbackPolicy.Finding(id: 50, discussionID: "another-summary", reviewerID: original.reviewerID,
            reviewerUsername: original.reviewerUsername, state: .needsVerification, reason: original.reason,
            waitingForReviewers: [], summary: original.summary, sourceNoteID: original.sourceNoteID)
        let distinctSource = AuthorFeedbackPolicy.Finding(id: 60, discussionID: "separate-source", reviewerID: original.reviewerID,
            reviewerUsername: original.reviewerUsername, state: .needsVerification, reason: original.reason,
            waitingForReviewers: [], summary: original.summary, sourceNoteID: 60)
        let distinctConcern = AuthorFeedbackPolicy.Finding(id: 70, discussionID: "separate-concern", reviewerID: original.reviewerID,
            reviewerUsername: original.reviewerUsername, state: .needsVerification,
            reason: "Cancellation should remain distinguishable from a transport failure", waitingForReviewers: [],
            summary: "Preserve the cancellation reason", sourceNoteID: original.sourceNoteID)
        item.authorFeedbackStatus?.findings += [inherited, distinctSource, distinctConcern]
        let suggestions = RemoteBoardAdapter.ignorableSuggestions(item)
        #expect(suggestions.count == 4)
        #expect(suggestions.filter { $0.noteID == 10 && $0.summary == original.summary }.count == 1)
        #expect(suggestions.contains { $0.noteID == 60 })
        #expect(suggestions.contains { $0.summary == distinctConcern.summary })
        #expect(item.authorFeedbackStatus?.findings.count == 7)
        #expect(item.authorFeedbackStatus?.displayFindings.count == 6)
    }

    @Test func distinctLongConcernsFromOneCommentRemainVisible() throws {
        var status = try #require(try item().authorFeedbackStatus)
        let original = try #require(status.findings.first)
        status.findings = ["retry", "cancellation"].enumerated().map { index, subject in
            .init(id: 80 + index, discussionID: "summary-\(index)", reviewerID: original.reviewerID,
                reviewerUsername: original.reviewerUsername, state: .needsVerification, reason: original.reason,
                waitingForReviewers: [], summary: String(repeating: "Contract evidence remains unavailable. ", count: 8) + subject,
                sourceNoteID: original.sourceNoteID)
        }
        #expect(status.displayFindings.count == 2)
    }

    @Test(arguments: ["eligible", "ready", "foreign", "closed", "stale", "busy", "head"])
    func phoneOffersMarkReadyUnderTheSameConditionsAsTheMac(_ scenario: String) throws {
        let suite = "RemoteMRControlsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.manual, for: .codex)
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: "gitlab.example.test", username: "me")
        settings.glabPath = glab.glabPath
        settings.resolvedHost = glab.resolvedHost
        let monitor = TodoMonitorService(settings: settings, glab: glab)
        defer { monitor.stopTimer() }
        var item = try item()
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item.mergeRequest)) as? [String: Any])
        fields["draft"] = scenario != "ready"
        if scenario == "closed" { fields["state"] = "closed" }
        if scenario == "foreign" { fields["author"] = ["id": 7, "username": "other", "name": "Other"] }
        if scenario == "head" { fields["sha"] = "short" }
        item.mergeRequest = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: fields))
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [],
            evidenceMatchesCatalogContext: scenario != "stale")
        let actions = RemoteBoardAdapter.mrControls(item: item, row: row, monitor: monitor,
            account: "me@gitlab.example.test", busy: scenario == "busy")
        let ready = actions.first { $0.kind.rawValue == "markReady" }
        #expect((ready != nil) == (scenario == "eligible"))
        if scenario == "eligible" {
            let action = try #require(ready)
            #expect(!action.token.isEmpty)
            #expect(action.confirmationText?.isEmpty == false)
        }
    }

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
