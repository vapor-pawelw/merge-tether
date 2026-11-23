import Foundation
import MergeTetherRemote
import Testing
@testable import MergeTether

@MainActor
struct MRIssueCoordinatorTests {
    private let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "alice", projectID: 34, iid: 12)
    private let native = RemoteMRIssue(reference: "#42", title: "Prevent retries")

    @Test func nativeIssuesAreReusedAcrossRestartAndASuccessfulEmptyReadRemovesThem() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "issues.json")
        let mr = try request("Closes #42")
        var reads = 0
        let coordinator = MRIssueCoordinator(file: file, isCurrentAccount: { _, _ in true }, readClosing: { _ in
            reads += 1
            if reads == 2 { throw GlabError.timedOut }
            return reads == 1 ? [native] : []
        }, assess: { _, _ in
            Issue.record("A native closing issue needs no agent assessment")
            return nil
        })
        coordinator.observe(mr, target: target, revision: 1, at: Date(), assessExternal: true)
        try await settle(coordinator)
        #expect(coordinator.issues(for: mr, target: target, revision: 1) == [native])

        var now = Date().addingTimeInterval(1)
        let restarted = MRIssueCoordinator(file: file, now: { now }, isCurrentAccount: { _, _ in true }, readClosing: { _ in
            reads += 1
            if reads == 2 { throw GlabError.timedOut }
            return []
        }, assess: { _, _ in nil })
        #expect(restarted.issues(for: mr, target: target, revision: 1) == [native])
        restarted.observe(mr, target: target, revision: 1, at: now)
        try await settle(restarted)
        #expect(reads == 1)
        restarted.observe(mr, target: target, revision: 1, at: now, refreshClosing: true)
        try await settle(restarted)
        #expect(restarted.issues(for: mr, target: target, revision: 1) == [native])
        now.addTimeInterval(31)
        restarted.observe(mr, target: target, revision: 1, at: now, refreshClosing: true)
        try await settle(restarted)
        #expect(reads == 3)
        #expect(restarted.issues(for: mr, target: target, revision: 1).isEmpty)
    }

    @Test func newMRTextInvalidatesAnInFlightAssessmentAndCachesTheNewEmptyResult() async throws {
        let original = try request("This MR implements PAY-73")
        let current = try request("PAY-73 will be implemented later")
        var reads = 0
        var releaseOld: CheckedContinuation<Void, Never>?
        let coordinator = MRIssueCoordinator(file: nil, isCurrentAccount: { _, _ in true }, readClosing: { _ in [] },
            assess: { request, _ in
                reads += 1
                if request.description == original.description {
                    await withCheckedContinuation { releaseOld = $0 }
                    return [.init(reference: "PAY-73")]
                }
                return []
            })
        let start = Date()
        coordinator.observe(original, target: target, revision: 1, at: start, assessExternal: true)
        let deadline = ContinuousClock.now + .seconds(3)
        while releaseOld == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let release = try #require(releaseOld)
        coordinator.observe(current, target: target, revision: 1, at: start.addingTimeInterval(1), assessExternal: true)
        release.resume()
        try await settle(coordinator)
        #expect(reads == 2)
        #expect(coordinator.issues(for: original, target: target, revision: 1).isEmpty)
        #expect(coordinator.issues(for: current, target: target, revision: 1).isEmpty)
        coordinator.requestAssessment(for: current, target: target, revision: 1)
        try await settle(coordinator)
        #expect(reads == 2)
    }

    @Test func identicalIssueNumbersInDifferentProjectsRemainDistinct() async throws {
        let mr = try request("Closes two tasks")
        let first = RemoteMRIssue(reference: "#42", url: URL(string: "https://gitlab.example.test/a/p/-/issues/42"))
        let second = RemoteMRIssue(reference: "#42", url: URL(string: "https://gitlab.example.test/b/p/-/issues/42"))
        let coordinator = MRIssueCoordinator(file: nil, isCurrentAccount: { _, _ in true },
            readClosing: { _ in [first, second, first] }, assess: { _, _ in nil })
        coordinator.observe(mr, target: target, revision: 1, at: Date())
        try await settle(coordinator)
        #expect(coordinator.issues(for: mr, target: target, revision: 1) == [first, second])
    }

    @Test func onlyScopeFindingsWithSourceEvidenceAreDisplayedAndURLsMustBeInTheExcerpt() throws {
        let linked = "This MR implements PAY-73 [Export dates](https://jira.example.test/browse/PAY-73)."
        let plain = "This MR fixes OPS-17."
        let background = "For context see DOC-1."
        let mr = try request([linked, plain, background].joined(separator: "\n"))
        let input = MRIssueAssessor.Input(request: mr, host: target.host)
        let result = MRIssueAssessor.Response(issues: [
            .init(relation: .scope, reference: "PAY-73", title: "Export dates", url: "https://jira.example.test/browse/PAY-73", evidence: linked),
            .init(relation: .scope, reference: "OPS-17", title: nil, url: "https://wrong.example.test/OPS-17", evidence: plain),
            .init(relation: .context, reference: "DOC-1", title: nil, url: nil, evidence: background)
        ])
        let issues = try MRIssueAssessor.issues(from: result, input: input)
        #expect(issues.map(\.reference) == ["PAY-73", "OPS-17"])
        #expect(issues.first?.title == "Export dates")
        #expect(issues.first?.linkURL?.host == "jira.example.test")
        #expect(issues.last?.linkURL == nil)
        #expect(throws: MRIssueAssessor.Failure.invalidEvidence) {
            try MRIssueAssessor.issues(from: .init(issues: [
                .init(relation: .scope, reference: "OTHER-1", title: nil, url: nil, evidence: "This MR fixes OTHER-1.")
            ]), input: input)
        }
    }

    @Test func aLinkedGitHubIssueCanUseTheNumberFromItsURL() throws {
        let evidence = "This MR fixes https://github.com/example/project/issues/314."
        let input = MRIssueAssessor.Input(request: try request(evidence), host: target.host)
        let url = "https://github.com/example/project/issues/314"
        let findings = MRIssueAssessor.Response(issues: [
            .init(relation: .scope, reference: "#314", title: nil, url: url, evidence: evidence)
        ])
        let issues = try MRIssueAssessor.issues(from: findings, input: input)
        #expect(issues == [.init(reference: "#314", url: URL(string: url))])
    }

    private func request(_ description: String) throws -> GitLabMergeRequest {
        let value: [String: Any] = [
            "project_id": 34, "iid": 12, "title": "Example merge request", "description": description,
            "web_url": "https://gitlab.example.test/group/project/-/merge_requests/12",
            "state": "opened", "sha": "0123456789abcdef0123456789abcdef01234567", "source_branch": "feature",
            "target_branch": "main", "labels": [], "author": ["id": 7, "username": "alice", "name": "Alice"]
        ]
        return try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func settle(_ coordinator: MRIssueCoordinator) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while coordinator.isWorking, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!coordinator.isWorking)
    }
}
