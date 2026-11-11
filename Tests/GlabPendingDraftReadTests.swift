import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct GlabPendingDraftReadTests {
    @Test func independentReadsStartTogetherAndDecodePaginatedDraftsAndDiscussions() async throws {
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: "gitlab.example.test", username: "me")
        let request = try MRDependencyPresentationTests().request(2)
        let encoded = try JSONEncoder().encode(request)
        gitlab.handler = { call in
            try await gitlab.waitFor("release")
            if call.endpoint.contains("/draft_notes") {
                #expect(call.arguments.contains("--paginate"))
                return InMemoryGitLab.output(#"[{"id":1,"author_id":7,"note":"Mine"}]"# + "\n" + #"[{"id":2,"author_id":9,"note":"Other"}]"#)
            }
            if call.endpoint.contains("/discussions") {
                return InMemoryGitLab.output(#"[{"id":"one","notes":[]}]"# + "\n" + #"[{"id":"two","notes":[]}]"#)
            }
            return .init(stdout: encoded, stderr: "", exitCode: 0)
        }
        let reading = Task { await glab.fetchPendingDraftRead(projectID: request.projectID, iid: request.iid,
            host: "gitlab.example.test", userID: 7) }
        defer { reading.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while gitlab.requests.count < 3, ContinuousClock.now < deadline { await Task.yield() }
        try #require(gitlab.requests.count == 3)
        #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        gitlab.write("release")
        let result = await reading.value
        #expect(result.drafts?.map(\.id) == [1])
        #expect(result.discussions?.count == 2)
        #expect(result.request?.sha == request.sha)
    }

    @Test(arguments: ["wrong-request", "invalid-discussions", "failed-drafts"])
    func incompleteReadsRemainExplicitAndKeepIndependentEvidence(_ failure: String) async throws {
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: "gitlab.example.test", username: "me")
        let request = try MRDependencyPresentationTests().request(failure == "wrong-request" ? 3 : 2)
        let encoded = try JSONEncoder().encode(request)
        gitlab.handler = { call in
            if call.endpoint.contains("/draft_notes") {
                return failure == "failed-drafts" ? InMemoryGitLab.output(code: 1)
                    : InMemoryGitLab.output(#"[{"id":1,"author_id":7,"note":"Mine"}]"#)
            }
            if call.endpoint.contains("/discussions") {
                return InMemoryGitLab.output(failure == "invalid-discussions" ? "[invalid]" : "[]")
            }
            return .init(stdout: encoded, stderr: "", exitCode: 0)
        }
        let result = await glab.fetchPendingDraftRead(projectID: request.projectID, iid: 2,
            host: "gitlab.example.test", userID: 7)
        #expect((result.request == nil) == (failure == "wrong-request"))
        #expect((result.discussions == nil) == (failure == "invalid-discussions"))
        #expect((result.drafts == nil) == (failure == "failed-drafts"))
    }
}
