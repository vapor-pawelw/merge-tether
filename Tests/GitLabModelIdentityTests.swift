import Foundation
import Testing
@testable import MergeTether

struct GitLabModelIdentityTests {
    @Test func stateValuesRoundTripAsExactStrings() throws {
        try assertWireValue(GitLabMergeRequestState.opened, "opened")
        try assertWireValue(GitLabMergeRequestState.unknown("Opened"), "Opened")
        try assertWireValue(GitLabDetailedMergeStatus.draftStatus, "draft_status")
        try assertWireValue(GitLabDetailedMergeStatus.unknown("new_check"), "new_check")
        try assertWireValue(GitLabPipelineStatus.waitingForResource, "waiting_for_resource")
        try assertWireValue(GitLabPipelineStatus.unknown(""), "")
        try assertWireValue(GitLabReviewerState.reviewStarted, "review_started")
        try assertWireValue(GitLabReviewerState.unknown("future_review"), "future_review")
    }

    @Test func mergeRequestPayloadKeepsItsStringFields() throws {
        let original = try JSONSerialization.data(withJSONObject: [
            "project_id": 1, "iid": 2,
            "author": ["id": 3, "username": "me", "name": "Me"],
            "title": "Feature", "web_url": "https://gitlab.example.test/group/repo/-/merge_requests/2",
            "state": "locked", "source_branch": "feature", "target_branch": "main",
            "detailed_merge_status": "future_status", "labels": [],
            "head_pipeline": ["id": 4, "status": "future_pipeline"]
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: original)
        #expect(request.state == .locked)
        #expect(request.detailedMergeStatus == .unknown("future_status"))
        #expect(request.headPipeline?.status == .unknown("future_pipeline"))
        #expect(try encode(request) == original)
    }

    @Test func existingTodoFixtureKeepsItsMergeRequestTargetState() throws {
        let requestTodo = try #require(GlabServiceDecodingTests.todos.first { $0.id == 10001 })
        #expect(requestTodo.mergeRequestState == .opened)
        #expect(requestTodo.mergeRequestID == .init(projectID: requestTodo.project.id, iid: 1369))
        #expect(requestTodo.targetState == .open)
        let copy = try JSONDecoder().decode(Todo.Target.self, from: encode(requestTodo.target))
        #expect(copy == requestTodo.target)
    }

    @Test(arguments: [nil, false, true] as [Bool?], [nil, "mergeable", "draft_status"] as [String?])
    func draftUsesStatusOrExplicitFlagAndOnlyFallsBackForMissingFlag(_ draft: Bool?, _ status: String?) throws {
        let request = try mergeRequest(state: "opened", draft: draft, status: status)
        #expect(request.isDraft == (draft == true || status == "draft_status"))
        #expect(request.isDraft(fallback: true) == ((draft ?? true) || status == "draft_status"))
        #expect(request.isDraft(fallback: false) == request.isDraft)
        let scope = MRAutomationScope()
        #expect(scope.permits(request, host: "gitlab.example.test", username: "me")
            == (draft != nil && !request.isDraft))
    }

    @Test(arguments: ["opened", "open", "reopened", "locked", "merged", "closed", "Opened"])
    func openRequiresGitLabsExactOpenedState(_ state: String) throws {
        let request = try mergeRequest(state: state)
        #expect(request.isOpen == (state == "opened"))
    }

    @Test func normalizedAccountKeysIgnoreCaseAndRetainHostAndUsernameBoundaries() {
        let normalize = GitLabAccountIdentity.normalize
        #expect(normalize("GitLab.Example.Test:8443") == "gitlab.example.test:8443")
        #expect(normalize("SomeOne") == "someone")
        let account = GitLabAccountIdentity(host: "gitlab.example.test:8443", username: "someone")
        #expect(account != GitLabAccountIdentity(host: "gitlab.example.test", username: "someone"))
        #expect(account != GitLabAccountIdentity(host: "gitlab.example.test:8443", username: "other"))
    }

    @Test func scopeTargetsKeepLegacyKeySpellingAndDistinguishRepositoryFromMergeRequest() throws {
        let original = Data(#"[{"host":"GitLab.Example.Test","iid":2,"projectID":1,"username":"SomeOne"},"paused"]"#.utf8)
        let overrides = try JSONDecoder().decode([MRAutomationScope.Target: MRAutomationScope.Choice].self, from: original)
        let target = MRAutomationScope.Target.mergeRequest(host: "GitLab.Example.Test", username: "SomeOne", projectID: 1, iid: 2)
        let repository = MRAutomationScope.Target.repository(host: "GitLab.Example.Test", username: "SomeOne", projectID: 1)
        #expect(overrides[target] == .paused)
        #expect(overrides[repository] == nil)
        #expect(target.repository == repository)
        #expect(target.mergeRequestID == GitLabMergeRequestID(projectID: 1, iid: 2))
        #expect(repository.mergeRequestID == nil)
        #expect(try encode(overrides) == original)
    }

    private func assertWireValue<Value: Codable & Equatable>(_ value: Value, _ wireValue: String) throws {
        let original = try encode(wireValue)
        #expect(try JSONDecoder().decode(Value.self, from: original) == value)
        #expect(try encode(value) == original)
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func mergeRequest(state: String, draft: Bool? = nil, status: String? = nil) throws -> GitLabMergeRequest {
        var payload: [String: Any] = [
            "project_id": 1, "iid": 2,
            "author": ["id": 3, "username": "me", "name": "Me"],
            "title": "Feature", "web_url": "https://gitlab.example.test/group/repo/-/merge_requests/2",
            "state": state, "source_branch": "feature", "target_branch": "main", "labels": []
        ]
        payload["draft"] = draft
        payload["detailed_merge_status"] = status
        return try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}
