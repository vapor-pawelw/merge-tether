import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct GlabWriteAuthorizationTests {
    private struct Response: Decodable { let id: Int }

    @Test func theReadTransportStillReturnsAuthenticatedReadEvidence() async throws {
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: "gitlab.example.test", username: "me")
        gitlab.handler = { _ in InMemoryGitLab.output(#"{"id":17}"#) }
        let value: Response = try await glab.mergeRequestAPI("/projects/1", host: "gitlab.example.test")
        #expect(value.id == 17)
        #expect(gitlab.requests.count == 1 && gitlab.requests[0].method == "GET")
    }

    @Test(arguments: ["POST", "PUT", "DELETE", "PATCH", "graphql", "field", "raw-field", "input"])
    func theReadTransportCannotSilentlyLaunchAMutation(_ method: String) async {
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: "gitlab.example.test", username: "me")
        gitlab.handler = { _ in InMemoryGitLab.output(#"{"id":17}"#) }
        let arguments: [String]
        switch method {
        case "graphql": arguments = ["--raw-field", "query=mutation { write }"]
        case "field", "raw-field": arguments = ["--" + method, "value=write"]
        case "input": arguments = ["--input", "/unused/fixture-body.json"]
        default: arguments = ["--method", method]
        }
        var rejected = false
        do {
            let _: Response = try await glab.mergeRequestAPI(method == "graphql" ? "graphql" : "/projects/1",
                host: "gitlab.example.test", arguments: arguments)
        } catch { rejected = true }
        #expect(rejected)
        #expect(gitlab.requests.isEmpty)
    }

    enum Write: CaseIterable, Sendable {
        case publish, delete, resolve, thumbsUp, markDone, rereview, newReviewer
    }

    @MainActor private final class Admission {
        var allowed = true
    }

    private func write(_ operation: Write, using glab: GlabService, admission: Admission) async throws {
        let host = "gitlab.example.test"
        let proceed: @MainActor @Sendable () -> Bool = { admission.allowed }
        switch operation {
        case .publish:
            try await glab.publishDraftNote(projectID: 1, iid: 2, draftID: 3, host: host, shouldProceed: proceed)
        case .delete:
            try await glab.deleteDraftNote(projectID: 1, iid: 2, draftID: 3, host: host, shouldProceed: proceed)
        case .resolve:
            try await glab.resolveAcceptedDiscussion(projectID: 1, iid: 2, discussionID: "thread", host: host, shouldProceed: proceed)
        case .thumbsUp:
            try await glab.addOwnThumbsUp(projectID: 1, iid: 2, noteID: 3, host: host, userID: 7, shouldProceed: proceed)
        case .markDone:
            try await glab.markAsDone(id: 3, host: host, shouldProceed: proceed).get()
        case .rereview, .newReviewer:
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":7,"username":"me","name":"Me"},"title":"Change","web_url":"https://gitlab.example.test/group/project/-/merge_requests/2","state":"opened","source_branch":"topic","target_branch":"main","labels":[]}"#.utf8))
            try await glab.requestReview(of: request, userID: 8, username: "reviewer",
                alreadyAssigned: operation == .rereview, host: host, shouldProceed: proceed)
        }
    }

    private func respond(to request: InMemoryGitLab.Request) -> ProcessRunner.Output {
        if request.endpoint == "graphql" {
            return InMemoryGitLab.output(#"{"data":{"mergeRequestReviewerRereview":{"mergeRequest":{"iid":"2"},"errors":[]}}}"#)
        }
        if request.endpoint.contains("discussions/") {
            return InMemoryGitLab.output(#"{"id":"thread","notes":[{"id":3,"resolvable":true,"resolved":true}]}"#)
        }
        if request.endpoint.contains("award_emoji") {
            let award = #"{"id":9,"name":"thumbsup","user":{"id":7,"username":"me"}}"#
            return InMemoryGitLab.output(request.method == "POST" ? award : "[" + award + "]")
        }
        return InMemoryGitLab.output()
    }

    @Test(arguments: Write.allCases)
    func explicitAdmissionAllowsAConfirmedWriteEvenWhenItClosesAfterTheResponse(_ operation: Write) async throws {
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: "gitlab.example.test", username: "me")
        let admission = Admission()
        gitlab.handler = { request in
            admission.allowed = false
            return respond(to: request)
        }
        try await write(operation, using: glab, admission: admission)
        #expect(!admission.allowed)
        #expect(gitlab.requests.count == (operation == .thumbsUp ? 2 : 1))
        if operation == .thumbsUp { #expect(gitlab.requests.last?.method == "GET") }
        let first = try #require(gitlab.requests.first)
        switch operation {
        case .publish: #expect(first.method == "PUT" && first.endpoint.hasSuffix("/draft_notes/3/publish"))
        case .delete: #expect(first.method == "DELETE" && first.endpoint.hasSuffix("/draft_notes/3"))
        case .resolve: #expect(first.method == "PUT" && first.command.contains("resolved=true"))
        case .thumbsUp: #expect(first.method == "POST" && first.command.contains("name=thumbsup"))
        case .markDone: #expect(first.method == "POST" && first.endpoint == "/todos/3/mark_as_done")
        case .rereview: #expect(first.command.contains("mergeRequestReviewerRereview") && first.command.contains("userId=gid://gitlab/User/8"))
        case .newReviewer: #expect(first.command.contains("operationMode: APPEND") && first.command.contains("username=reviewer"))
        }
    }

    @Test(arguments: Write.allCases)
    func deniedAdmissionNeverReachesTheCommandBoundary(_ operation: Write) async {
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: "gitlab.example.test", username: "me")
        let admission = Admission()
        admission.allowed = false
        do {
            try await write(operation, using: glab, admission: admission)
            Issue.record("A denied write succeeded")
        } catch {}
        #expect(gitlab.requests.isEmpty)
    }

    @Test(arguments: Write.allCases)
    func revokingAdmissionWhileTheTransportWaitsPreventsEveryWrite(_ operation: Write) async throws {
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: "gitlab.example.test", username: "me")
        let admission = Admission()
        gitlab.beforeCommand = { _ in
            gitlab.write("queued")
            try await gitlab.waitFor("release")
        }
        let pending = Task { try await write(operation, using: glab, admission: admission) }
        try await gitlab.waitFor("queued")
        admission.allowed = false
        gitlab.write("release")
        do { try await pending.value; Issue.record("A queued denied write succeeded") } catch {}
        #expect(gitlab.requests.isEmpty)
    }

    @Test(arguments: ["account", "executable", "cancellation"])
    func transportRechecksTheOriginatingSessionAfterScheduling(_ change: String) async throws {
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: "gitlab.example.test", username: "me")
        let admission = Admission()
        gitlab.beforeCommand = { _ in
            gitlab.write("queued")
            try await gitlab.waitFor("release")
        }
        let pending = Task { try await write(.publish, using: glab, admission: admission) }
        try await gitlab.waitFor("queued")
        switch change {
        case "account": glab.currentUsername = "other"; glab.currentUsername = "me"
        case "executable": glab.glabPath = URL(fileURLWithPath: "/other/glab")
        default: pending.cancel()
        }
        gitlab.write("release")
        do { try await pending.value; Issue.record("A stale or cancelled write succeeded") } catch is CancellationError {}
        #expect(gitlab.requests.isEmpty)
    }


    @Test func approvalRechecksAdmissionAfterItsAuthenticatedRead() async throws {
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: "gitlab.example.test", username: "me")
        let admission = Admission()
        gitlab.handler = { request in
            #expect(request.endpoint == "/user" && request.method == "GET")
            admission.allowed = false
            return InMemoryGitLab.output(#"{"id":7,"username":"me"}"#)
        }
        do {
            try await glab.approveMergeRequest(projectID: 1, iid: 2, headSHA: String(repeating: "a", count: 40),
                host: "gitlab.example.test", userID: 7, shouldProceed: { admission.allowed })
            Issue.record("Approval succeeded after admission closed during authentication")
        } catch is CancellationError {}
        #expect(gitlab.requests.count == 1 && gitlab.requests[0].method == "GET")
    }

}
