import Foundation
import MergeTetherRemote
import Testing
@testable import MergeTether

@MainActor
struct MRIssueCoordinatorTests {
    private let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "alice", projectID: 34, iid: 12)
    private let secondTarget = MRAutomationScope.Target(host: "gitlab.example.test", username: "alice", projectID: 34, iid: 13)
    private let native = RemoteMRIssue(reference: "#42", title: "Prevent retries")

    @Test func nativeIssuesRequireAssessmentAndConfirmedResultsSurviveRestartAndReadFailure() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "issues.json")
        let mr = try request("Closes #42")
        var reads = 0, assessments = 0
        let coordinator = MRIssueCoordinator(file: file, isCurrentAccount: { _, _ in true }, readCandidates: { _, _ in
            reads += 1
            return [.init(issue: native, relation: .closing)]
        }, assess: { batch in
            assessments += 1
            #expect(batch.first?.evidence.candidates.map(\.relation) == [.closing])
            return [target: [native]]
        })
        coordinator.requestAssessment(for: mr, target: target, revision: 1)
        try await settle(coordinator)
        #expect(assessments == 1)
        #expect(coordinator.issues(for: mr, target: target, revision: 1) == [native])

        let restarted = MRIssueCoordinator(file: file, isCurrentAccount: { _, _ in true }, readCandidates: { _, _ in
            reads += 1
            if reads == 2 { throw GlabError.timedOut }
            return []
        }, assess: { _ in [target: []] })
        restarted.requestAssessment(for: mr, target: target, revision: 1)
        try await settle(restarted)
        #expect(restarted.issues(for: mr, target: target, revision: 1) == [native])
        #expect(reads == 1)
        restarted.requestAssessment(for: mr, target: target, revision: 1, force: true)
        try await settle(restarted)
        #expect(restarted.issues(for: mr, target: target, revision: 1) == [native])
        restarted.requestAssessment(for: mr, target: target, revision: 1, force: true)
        try await settle(restarted)
        #expect(reads == 3)
        #expect(restarted.issues(for: mr, target: target, revision: 1).isEmpty)
    }

    @Test func boardBatchesCandidatesOnceAndAForcedSingleRefreshOnlyAssessesItsMR() async throws {
        let first = try request("Prevents retry duplication")
        let second = try request("Shows the confirmation", iid: 13)
        var batches: [[Int]] = []
        let coordinator = MRIssueCoordinator(file: nil, isCurrentAccount: { _, _ in true }, readCandidates: { request, _ in
            request.iid == 12 ? [.init(issue: native, relation: .related)] : []
        }, assess: { batch in
            batches.append(batch.map(\.request.iid))
            return Dictionary(uniqueKeysWithValues: batch.map {
                ($0.target, $0.target == target ? [native] : [])
            })
        })
        let date = Date()
        coordinator.observe(first, target: target, revision: 1, at: date)
        coordinator.observe(second, target: secondTarget, revision: 1, at: date)
        coordinator.requestBoardAssessment(for: [target, secondTarget, target], revision: 1, force: true)
        try await settle(coordinator)
        #expect(batches == [[12, 13]])
        #expect(coordinator.issues(for: first, target: target, revision: 1) == [native])
        #expect(coordinator.issues(for: second, target: secondTarget, revision: 1).isEmpty)
        coordinator.requestBoardAssessment(for: [target, secondTarget], revision: 1)
        try await settle(coordinator)
        #expect(batches == [[12, 13]])
        coordinator.requestAssessment(for: second, target: secondTarget, revision: 1, force: true)
        try await settle(coordinator)
        #expect(batches == [[12, 13], [13]])
    }

    @Test func refreshingOneDraftReturnsWhileItsBackgroundIssueReadIsStillPending() async throws {
        let mr = try request("Completes retry handling for !13. Relates to #42. See !13 and another/project!17.", draft: true)
        let predecessorJSON = try JSONEncoder().encode(request("Implements the new retry policy for #42", iid: 13))
        let gitlab = InMemoryGitLab()
        let suite = "MRIssueCoordinatorTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { gitlab.close(); defaults.removePersistentDomain(forName: suite) }
        let glab = gitlab.service(host: target.host, username: target.username)
        let settings = SettingsManager(defaults: defaults)
        settings.glabPath = glab.glabPath
        settings.resolvedHost = target.host
        settings.automation.packageDecision = .enabled
        let requestJSON = String(decoding: try JSONEncoder().encode(mr), as: UTF8.self)
        gitlab.write("pause-detail")
        gitlab.handler = { command in
            switch command.arguments.first {
            case "config": return InMemoryGitLab.output(target.host)
            case "auth": return InMemoryGitLab.output("Logged in to \(target.host) as \(target.username)")
            default: break
            }
            switch command.endpoint {
            case "/projects/34/merge_requests/12":
                try await gitlab.pause(ifPresent: "pause-detail", entered: "detail-entered", until: "release-detail")
                return InMemoryGitLab.output(requestJSON)
            case "/projects/34/merge_requests/13":
                gitlab.write("referenced-mr-entered")
                return InMemoryGitLab.output(String(decoding: predecessorJSON, as: UTF8.self))
            case "graphql":
                gitlab.write("relations-entered")
                return InMemoryGitLab.output(#"{"data":{"project":{"mergeRequest":{"workItemRelations":{"nodes":[{"linkType":"MENTIONED","workItem":{"iid":"42","title":"Production investigation","webUrl":"https://gitlab.example.test/group/project/-/work_items/42"}}]}}}}}"#)
            default: return InMemoryGitLab.output("[]")
            }
        }
        let monitor = TodoMonitorService(settings: settings, glab: glab,
                                         assistantDependencies: .init(probe: { _ in .missingCLI }))
        let coordinator = monitor.makeIssueCoordinator()
        monitor.mergeRequestIssues = coordinator
        #expect(!settings.automation.scope.permits(mr, host: target.host, username: target.username))
        let refresh = Task {
            await monitor.refreshFromGitLab(for: .init(projectID: 34, iid: 12))
            gitlab.write("foreground-complete")
        }
        defer { refresh.cancel() }
        var deadline = ContinuousClock.now + .seconds(3)
        while !(gitlab.has("detail-entered") && gitlab.has("foreground-complete")), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(gitlab.has("detail-entered"))
        #expect(gitlab.has("foreground-complete"))
        gitlab.write("release-detail")
        await refresh.value
        deadline = ContinuousClock.now + .seconds(3)
        while !gitlab.has("relations-entered"), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gitlab.has("relations-entered"))
        try await settle(coordinator)
        #expect(gitlab.has("referenced-mr-entered"))
        #expect(gitlab.requests.filter { $0.endpoint == "/projects/34/merge_requests/13" }.count == 1)
        #expect(!gitlab.requests.contains { $0.endpoint == "/projects/34/merge_requests/17" })
    }

    @Test func anOrdinaryPollReusesUnchangedEvidenceAndReassessesChangedRelations() async throws {
        let mr = try request("Prevents retry duplication")
        var now = Date(), reads = 0, assessments = 0
        let coordinator = MRIssueCoordinator(file: nil, now: { now }, isCurrentAccount: { _, _ in true },
            readCandidates: { _, _ in
                reads += 1
                return reads <= 2 ? [.init(issue: native, relation: .related)] : []
            }, assess: { batch in
                assessments += 1
                return [target: batch[0].evidence.candidates.map(\.issue)]
            })
        coordinator.observe(mr, target: target, revision: 1, at: now)
        for _ in 0..<3 {
            coordinator.requestBoardAssessment(for: [target], revision: 1)
            try await settle(coordinator)
            now.addTimeInterval(601)
        }
        #expect(reads == 3)
        #expect(assessments == 2)
        #expect(coordinator.issues(for: mr, target: target, revision: 1).isEmpty)
    }

    @Test func newMRTextInvalidatesAnInFlightAssessmentAndCachesTheNewEmptyResult() async throws {
        let original = try request("This MR implements PAY-73")
        let current = try request("PAY-73 will be implemented later")
        var runs = 0
        var releaseOld: CheckedContinuation<Void, Never>?
        let coordinator = MRIssueCoordinator(file: nil, isCurrentAccount: { _, _ in true }, readCandidates: { _, _ in [] },
            assess: { batch in
                runs += 1
                if batch.first?.request.description == original.description {
                    await withCheckedContinuation { releaseOld = $0 }
                    return [target: [.init(reference: "PAY-73")]]
                }
                return [target: []]
            })
        coordinator.requestAssessment(for: original, target: target, revision: 1)
        let deadline = ContinuousClock.now + .seconds(3)
        while releaseOld == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let release = try #require(releaseOld)
        coordinator.observe(current, target: target, revision: 1, at: Date())
        coordinator.requestAssessment(for: current, target: target, revision: 1)
        release.resume()
        try await settle(coordinator)
        #expect(runs == 2)
        #expect(coordinator.issues(for: original, target: target, revision: 1).isEmpty)
        #expect(coordinator.issues(for: current, target: target, revision: 1).isEmpty)
        coordinator.requestAssessment(for: current, target: target, revision: 1)
        try await settle(coordinator)
        #expect(runs == 2)
    }

    @Test func onlySelectedCandidatesAndGroundedScopeFindingsAreDisplayedPerMR() throws {
        let issueURL = "https://gitlab.example.test/group/project/-/work_items/42"
        let scope = "This MR fixes #42 as described in https://gitlab.example.test/group/project/-/issues/42#note_8."
        let external = "This MR also implements PAY-73."
        let background = "For context see DOC-1."
        let mr = try request([scope, external, background].joined(separator: "\n"))
        let candidate = RemoteMRIssue(reference: "#42", title: "Prevent retries", url: URL(string: issueURL))
        let inputs = [
            MRIssueAssessor.Input(request: mr, candidates: [
                .init(issue: candidate, relation: .related),
                .init(issue: .init(reference: "#43", title: "Future work"), relation: .mentioned)
            ]),
            MRIssueAssessor.Input(request: try request("For information only", iid: 13))
        ]
        let response = MRIssueAssessor.Response(requests: [
            .init(id: 2, candidateIDs: [], issues: []),
            .init(id: 1, candidateIDs: [1, 1], issues: [
                .init(relation: .scope, reference: "#42", title: nil,
                      url: "https://gitlab.example.test/group/project/-/issues/42#note_8", evidence: scope),
                .init(relation: .scope, reference: "PAY-73", title: nil, url: nil, evidence: external),
                .init(relation: .context, reference: "DOC-1", title: nil, url: nil, evidence: background)
            ])
        ])
        let results = try MRIssueAssessor.issues(from: response, inputs: inputs)
        #expect(results == [[candidate, .init(reference: "PAY-73")], []])
        let invalidCandidate = MRIssueAssessor.Response(requests: [
            .init(id: 1, candidateIDs: [1], issues: []), .init(id: 2, candidateIDs: [1], issues: [])
        ])
        #expect(try MRIssueAssessor.issues(from: invalidCandidate, inputs: inputs) == [[candidate], nil])
        #expect(throws: MRIssueAssessor.Failure.invalidEvidence) {
            try MRIssueAssessor.issues(from: .init(requests: [.init(id: 1, candidateIDs: [1], issues: [])]), inputs: inputs)
        }
    }

    @Test func distinctGitLabProjectsKeepTheirIdenticallyNumberedIssues() {
        let first = RemoteMRIssue(reference: "#42", url: URL(string: "https://gitlab.example.test/a/p/-/issues/42"))
        let second = RemoteMRIssue(reference: "#42", url: URL(string: "https://gitlab.example.test/b/p/-/issues/42"))
        let alias = RemoteMRIssue(reference: "a/p#42", url: URL(string: "https://gitlab.example.test/a/p/-/work_items/42?view=full"))
        #expect(MRIssueAssessor.uniqueIssues([first, second, alias, .init(reference: "a/p#42"), .init(reference: "#42"), first]) == [first, second])
    }

    @Test func aLinkedGitHubIssueCanUseTheNumberFromItsURL() throws {
        let evidence = "This MR fixes https://github.com/example/project/issues/314."
        let input = MRIssueAssessor.Input(request: try request(evidence))
        let url = "https://github.com/example/project/issues/314"
        let findings: [MRIssueAssessor.Response.Finding] = [
            .init(relation: .scope, reference: "#314", title: nil, url: url, evidence: evidence)
        ]
        let issues = try MRIssueAssessor.issues(from: findings, input: input)
        #expect(issues == [.init(reference: "#314", url: URL(string: url))])
    }

    private func request(_ description: String, iid: Int = 12, draft: Bool = false) throws -> GitLabMergeRequest {
        let value: [String: Any] = [
            "project_id": 34, "iid": iid, "title": "Example merge request", "description": description,
            "web_url": "https://gitlab.example.test/group/project/-/merge_requests/\(iid)",
            "state": "opened", "draft": draft, "sha": "0123456789abcdef0123456789abcdef01234567", "source_branch": "feature",
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
