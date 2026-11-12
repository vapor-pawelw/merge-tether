import Foundation
import Testing
import MergeTetherRemote
@testable import GitLabTodos

@MainActor @Suite struct RemoteMRDetailLoaderTests {
    @Test func phoneAuthorIdentityRoundTripsSeparatelyFromTextOrigin() throws {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.utf8))
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
            from: Data(#"[{"id":"thread","notes":[{"id":1,"author":{"id":7,"username":"reviewer"},"system":false,"body":"AI-assisted human feedback"},{"id":2,"author":{"id":8,"username":"automation"},"system":false,"body":"Deterministic automation output"}]}]"#.utf8))
        let details = RemoteMRDetailLoader.project(request: request, progress: nil, rules: nil, reviewers: nil,
            discussions: discussions, origins: [1: .assessed(evidence: "AI text"), 2: .humanLikely(evidence: "Manual text")],
            drafts: [], username: "owner", authorKinds: [7: .regular, 8: .automation])
        let notes = try #require(details.threads?.first?.notes)
        #expect(notes[0].authorKind == .regular && notes[0].origin == .ai)
        #expect(notes[1].authorKind == .automation && notes[1].origin == .human)
        let encoded = try JSONEncoder().encode(notes[1])
        let decoded = try JSONDecoder().decode(RemoteDetailNote.self, from: encoded)
        #expect(decoded.authorKind == .automation && decoded.origin == .human)
        let legacy = try JSONDecoder().decode(RemoteDetailNote.self, from: Data(#"{"id":"1","body":"Earlier client","origin":"ai"}"#.utf8))
        #expect(legacy.authorKind == nil && legacy.origin == .ai)
    }

    @Test func currentFeedbackProjectionKeepsAssessmentSeparateFromRepliesAndResolution() throws {
        let note = RemoteDetailNote(id: "11", author: "Reviewer", body: "Concern", origin: .human, authorID: 7)
        let reply = RemoteDetailNote(id: "12", author: "Owner", body: "Done", origin: .ai, authorID: 3)
        var details = RemoteMRDetails(checkedAt: .now, threads: [.init(id: "thread", state: .resolved,
            notes: [note, reply], reply: .published, draftCount: 1)])
        RemoteMRDetailSupplement.applyFeedback(to: &details, assessment: nil, authorID: 3)
        #expect(details.threads?.first?.feedback == .needsVerification)
        let assessment = ReReviewAssessment(notes: [.init(noteID: 11, state: .addressed, reason: "Verified current source")])
        RemoteMRDetailSupplement.applyFeedback(to: &details, assessment: assessment, authorID: 3)
        #expect(details.threads?.first?.feedback == .addressed)
        #expect(details.threads?.first?.reply == .published && details.threads?.first?.draftCount == 1)
        #expect(details.threads?.first?.origin == nil)
        RemoteMRDetailSupplement.applyFeedback(to: &details, assessment: nil, authorID: 3)
        #expect(details.threads?.first?.feedback == .needsVerification)
    }

    private let raw = #"{"project_id":1,"iid":2,"author":{"id":3,"username":"owner","name":"Owner"},"title":"Feature","description":"Complete MR description","labels":[],"web_url":"https://gitlab.example.test/g/p/-/merge_requests/2","state":"opened","draft":false,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_project_id":1,"target_project_id":1,"source_branch":"feature","target_branch":"main","detailed_merge_status":"mergeable","has_conflicts":false,"reviewers":[{"id":8,"username":"assigned","name":"Assigned"}]}"#

    @Test func detailsIncludeMetadataAllUniqueApproversRulesAndOrderedDiscussionsUsingOnlyReads() async throws {
        let f = InMemoryGitLab(); defer { f.close() }
        let glab = f.service(host: "gitlab.example.test", username: "me")
        let source = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.utf8))
        f.handler = { request in
            if request.endpoint == "/user" { return InMemoryGitLab.output(#"{"id":4,"username":"me"}"#) }
            if request.endpoint.hasSuffix("/approvals") {
                return InMemoryGitLab.output(#"{"approvals_required":2,"approvals_left":1,"approved_by":[{"user":{"id":5,"username":"approved","name":"Approved"}},{"user":{"id":5,"username":"approved","name":"Approved"}},{"user":{"id":6,"username":"second","name":"Second"}},{"user":{"id":7,"username":"third","name":"Third"}}]}"#)
            }
            if request.endpoint.hasSuffix("/approval_state") {
                return InMemoryGitLab.output(#"{"rules":[{"id":1,"name":"Security","approvals_required":1,"approved":false,"approved_by":[]},{"id":2,"name":"Owners","approvals_required":1,"approved":true,"approved_by":[{"username":"approved"}]}]}"#)
            }
            if request.endpoint.contains("/reviewers?") { return InMemoryGitLab.output("[]") }
            if request.endpoint.contains("/discussions?") {
                return InMemoryGitLab.output(#"[{"id":"general","notes":[{"id":10,"author":{"id":8,"username":"assigned"},"system":false,"body":"General note"}]},{"id":"resolved","notes":[{"id":11,"author":{"id":8,"username":"assigned"},"system":false,"resolvable":true,"resolved":true,"body":"Resolved concern"}]},{"id":"open","notes":[{"id":12,"author":{"id":8,"username":"assigned"},"system":false,"resolvable":true,"resolved":false,"body":"Open concern"},{"id":13,"author":{"id":4,"username":"me"},"system":false,"body":"Published reply"}]}]"#)
            }
            return InMemoryGitLab.output(self.raw)
        }
        let details = try await RemoteMRDetailLoader.load(source: source, drafts: [], glab: glab)
        #expect(details.description == "Complete MR description")
        #expect(details.branches == .init(source: "feature", target: "main"))
        #expect(details.metadata.contains { $0.value == "feature" })
        #expect(details.metadata.contains { $0.value == "main" })
        #expect(details.approvals?.progress?.received == 3)
        #expect(details.approvals?.requirementsSatisfied == false)
        #expect(details.approvals?.people.map(\.id) == [5, 6, 7, 8, 4])
        let replyAuthor = try #require(details.approvals?.people.first { $0.id == 4 })
        #expect(replyAuthor.username == "me")
        #expect(replyAuthor.status == .commented)
        #expect(details.approvals?.rules?.map(\.name) == ["Security", "Owners"])
        #expect(details.threads?.map(\.state) == [.open, .resolved, .general])
        #expect(details.threads?.first?.reply == .published)
        #expect(details.threads?.first?.notes.map(\.body) == ["Open concern", "Published reply"])
        #expect(f.requests.allSatisfy { $0.method == "GET" })
    }

    @Test func unavailableRulesAndDiscussionsRemainUnknownWithoutDiscardingMetadata() async throws {
        let f = InMemoryGitLab(); defer { f.close() }
        let glab = f.service(host: "gitlab.example.test", username: "me")
        let source = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.utf8))
        f.handler = { request in
            if request.endpoint == "/user" { return InMemoryGitLab.output(#"{"id":4,"username":"me"}"#) }
            if request.endpoint.hasSuffix("/2") { return InMemoryGitLab.output(self.raw) }
            return InMemoryGitLab.output("Forbidden", code: 1)
        }
        let details = try await RemoteMRDetailLoader.load(source: source, drafts: [], glab: glab)
        #expect(details.description == source.description)
        #expect(details.approvals?.progress == nil)
        #expect(details.approvals?.rules == nil)
        #expect(details.approvals?.requirementsSatisfied == nil)
        #expect(details.threads == nil)
        #expect(details.approvals?.historyAvailable == false)
        #expect(details.approvals?.people.first?.status == .assigned)
    }

    @Test(arguments: ["head", "target", "description", "account", "account-roundtrip"])
    func changingContextDuringTheReadRejectsTheResult(_ change: String) async throws {
        let f = InMemoryGitLab(); defer { f.close() }
        let glab = f.service(host: "gitlab.example.test", username: "me")
        let source = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.utf8))
        var reads = 0
        f.handler = { request in
            if request.endpoint == "/user" { return InMemoryGitLab.output(#"{"id":4,"username":"me"}"#) }
            if request.endpoint.hasSuffix("/2") {
                reads += 1
                if reads == 2 {
                    if change.hasPrefix("account") { glab.currentUsername = "other" }
                    if change == "account-roundtrip" { glab.currentUsername = "me" }
                    var fields = try #require(JSONSerialization.jsonObject(with: Data(self.raw.utf8)) as? [String: Any])
                    if !change.hasPrefix("account") { fields[change == "head" ? "sha" : change == "target" ? "target_branch" : "description"] = "changed" }
                    return try InMemoryGitLab.json(fields)
                }
                return InMemoryGitLab.output(self.raw)
            }
            return InMemoryGitLab.output("Unavailable", code: 1)
        }
        await #expect(throws: (any Error).self) {
            try await RemoteMRDetailLoader.load(source: source, drafts: [], glab: glab)
        }
    }

    @Test func missingRuleApprovalIsUnknownAndOriginBadgesRequireCurrentNoteEvidence() throws {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.utf8))
        let rules = try JSONDecoder().decode(RemoteApprovalRuleState.self,
            from: Data(#"{"rules":[{"id":1,"name":"Security","approvals_required":1}]}"#.utf8))
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
            from: Data(#"[{"id":"thread","notes":[{"id":10,"body":"Source","system":false},{"id":11,"body":"Reply","system":false}]}]"#.utf8))
        let details = RemoteMRDetailLoader.project(request: request, progress: nil, rules: rules,
            reviewers: nil, discussions: discussions, origins: [10: .appGenerated], drafts: [], username: "me")
        #expect(details.approvals?.requirementsSatisfied == nil)
        #expect(details.approvals?.rules?.first?.approved == nil)
        #expect(details.threads?.first?.notes.map(\.origin) == [.ai, nil])
    }
}
