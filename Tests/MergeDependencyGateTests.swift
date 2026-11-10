import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct MergeDependencyGateTests {
    @Test(arguments: ["opened", "closed", "locked", "unknown", "merged", "hidden", "failed", "laterPage"])
    func mergeBoundaryRequiresEveryDependencyToBeVerifiablyMerged(_ state: String) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.dependencyState = state

        do {
            try await fixture.merge()
        } catch { }

        #expect(fixture.merged == (state == "merged" ? [2] : []))
    }

    @Test(arguments: ["opened", "merged", "closed"])
    func childCannotMergeIntoItsParentBranchEvenAfterRestart(_ parentState: String) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.childTarget = "base"
        fixture.parentState = parentState

        try await fixture.poll()

        #expect(fixture.merged.isEmpty)
        #expect(fixture.monitor.requests.first?.mayAutoMerge == false)
        #expect(fixture.monitor.requests.first?.dependencyReadiness.holdReason != nil)
    }

    @Test func stackMergesInOrderAfterTheChildIsRetargeted() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.includeParent = true
        fixture.parentState = "opened"
        fixture.childTarget = "base"
        fixture.dependencyState = "opened"

        try await fixture.poll()
        #expect(fixture.merged == [1])

        fixture.parentState = "merged"
        fixture.dependencyState = "merged"
        try await fixture.poll()
        #expect(fixture.merged == [1])

        fixture.childTarget = "main"
        try await fixture.poll()
        #expect(fixture.merged == [1, 2])
        #expect(fixture.gitlab.requests.filter { $0.method != "GET" }.allSatisfy { $0.endpoint.hasSuffix("/merge") })
    }

    @Test(arguments: ["dependency", "hidden", "failed", "target", "head", "stack", "account"])
    func finalLiveCheckRejectsDependencyOrBranchDriftAfterReadiness(_ drift: String) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.beforeMerge = {
            switch drift {
            case "dependency": fixture.dependencyState = "closed"
            case "hidden": fixture.dependencyState = "hidden"
            case "failed": fixture.dependencyState = "failed"
            case "target": fixture.childTarget = "release"
            case "head": fixture.childHead = String(repeating: "b", count: 40)
            case "account":
                fixture.glab.currentUsername = "other"
                fixture.glab.currentUsername = "me"
            default: fixture.stackUnavailable = true
            }
        }

        try await fixture.poll()

        #expect(fixture.merged.isEmpty)
    }

    @Test(arguments: ["stack", "defaultBranch", "context"])
    func incompleteStackEvidenceCannotAuthorizeAutomaticMerge(_ missing: String) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.stackUnavailable = missing == "stack"
        fixture.defaultBranchUnavailable = missing == "defaultBranch"
        fixture.stackContextStale = missing == "context"

        try await fixture.poll()

        #expect(fixture.merged.isEmpty)
        #expect(fixture.monitor.requests.first?.mayAutoMerge == false)
    }

    @Test func nonStackReleaseTargetRemainsEligible() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.childTarget = "release/next+patch"

        try await fixture.poll()

        #expect(fixture.merged == [2])
        #expect(fixture.gitlab.requests.contains { $0.endpoint.contains("source_branch=release%2Fnext%2Bpatch") })
    }

    @Test func reusedBranchWithAHistoricalMergeRequiresTargetReview() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.parentState = "merged"
        fixture.childTarget = "base"

        try await fixture.poll()

        #expect(fixture.merged.isEmpty)
        #expect(fixture.monitor.requests.first?.blockers.contains(.stackTarget) == true)
    }

    @Test func retargetDuringDependencyReadsInvalidatesTheFinalMergeContext() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.beforeMerge = { fixture.changeTargetDuringDependencies = true }

        try await fixture.poll()

        #expect(fixture.merged.isEmpty)
    }

    @Test(arguments: ["opened", "closed", "hidden", "failed", "merged"])
    func restoringPerMRMergeAutoRechecksDependencies(_ state: String) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let target = MRAutomationScope.Target(host: fixture.host, username: "me", projectID: 1, iid: 2)
        fixture.settings.autoMergeOptOuts.insert(target)
        try await fixture.poll()
        #expect(fixture.merged.isEmpty)
        fixture.dependencyState = state
        fixture.settings.autoMergeOptOuts.remove(target)

        await fixture.monitor.resumeAutomaticMerge(for: target)

        #expect(fixture.merged == (state == "merged" ? [2] : []))
    }

    @MainActor private final class Fixture {
        let gitlab = InMemoryGitLab()
        let defaults: UserDefaults
        let suite = "MergeDependencyGateTests.\(UUID())"
        let settings: SettingsManager
        let glab: GlabService
        var monitor: AuthoredMergeRequestMonitor!
        var dependencyState = "merged"
        var parentState: String?
        var includeParent = false
        var childTarget = "main"
        var childHead = String(repeating: "a", count: 40)
        var stackUnavailable = false
        var defaultBranchUnavailable = false
        var stackContextStale = false
        var beforeMerge: (() -> Void)?
        var changeTargetDuringDependencies = false
        var merged: [Int] = []
        let host = "gitlab.example.test"

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            settings = SettingsManager(defaults: defaults)
            glab = gitlab.service(host: host, username: "me")
            settings.onboardingCompleted = true
            settings.notificationsEnabled = false
            settings.automation.autoMergeEnabled = true
            settings.automation.autoMergeProjects = "group/repo"
            gitlab.handler = { [unowned self] call in
                switch call.endpoint {
                case "/user": return InMemoryGitLab.output(#"{"id":3,"username":"me"}"#)
                case let path where path.hasPrefix("/merge_requests?"):
                    return try InMemoryGitLab.json((includeParent && parentState == "opened" ? [request(1)] : []) + [request(2)])
                case "/projects/1/merge_requests/1": return try InMemoryGitLab.json(request(1))
                case "/projects/1/merge_requests/2": return try InMemoryGitLab.json(request(2))
                case let path where path.contains("/approval_state"):
                    return InMemoryGitLab.output(#"{"rules":[{"approvals_required":1,"approved":true}]}"#)
                case let path where path.contains("/discussions?") || path.contains("/draft_notes?"):
                    return InMemoryGitLab.output("[]")
                case let path where path.contains("/blocks?"):
                    if changeTargetDuringDependencies { childTarget = "release" }
                    if path.contains("/1/blocks?") { return InMemoryGitLab.output("[]") }
                    if dependencyState == "failed" { return InMemoryGitLab.output(code: 1) }
                    if dependencyState == "hidden" { return InMemoryGitLab.output("[{}]") }
                    var dependency = request(9)
                    dependency["state"] = dependencyState == "laterPage" ? "closed" : dependencyState
                    if dependencyState == "laterPage" {
                        var mergedDependency = request(8)
                        mergedDependency["state"] = "merged"
                        let first = try InMemoryGitLab.json([["blocking_merge_request": mergedDependency]])
                        let second = try InMemoryGitLab.json([["blocking_merge_request": dependency]])
                        return InMemoryGitLab.output(String(decoding: first.stdout, as: UTF8.self)
                            + "\n" + String(decoding: second.stdout, as: UTF8.self))
                    }
                    return try InMemoryGitLab.json([["blocking_merge_request": dependency]])
                case let path where path.hasPrefix("/projects/1/merge_requests?state=opened"):
                    if stackUnavailable { return InMemoryGitLab.output(code: 1) }
                    var child = request(2)
                    if stackContextStale { child["target_branch"] = "stale" }
                    return try InMemoryGitLab.json([child] + (parentState == "opened" ? [request(1)] : []))
                case let path where path.hasPrefix("/projects/1/merge_requests?state=all"):
                    return try InMemoryGitLab.json(parentState == nil ? [] : [request(1)])
                case "/projects/1":
                    return try InMemoryGitLab.json(["default_branch": defaultBranchUnavailable ? NSNull() : "main" as Any,
                        "merge_trains_enabled": false, "only_allow_merge_if_all_discussions_are_resolved": true, "reset_approvals_on_push": true])
                case let path where path.hasSuffix("/merge"):
                    let iid = path.contains("/merge_requests/1/merge") ? 1 : 2
                    merged.append(iid)
                    if iid == 1 { parentState = "merged" }
                    return try InMemoryGitLab.json(["project_id": 1, "iid": iid, "state": "merged"])
                default: return try gitlab.unexpected(call)
                }
            }
            monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, notifications: NotificationService(),
                canAutomate: { [unowned self] _ in beforeMerge?(); return true })
        }

        func request(_ iid: Int) -> [String: Any] {
            ["project_id": 1, "iid": iid, "author": ["id": 3, "username": "me", "name": "Me"],
             "title": "Part \(iid)", "labels": [], "web_url": "https://\(host)/group/repo/-/merge_requests/\(iid)",
             "source_project_id": 1, "target_project_id": 1, "source_branch": iid == 1 ? "base" : "part-\(iid)",
             "target_branch": iid == 2 ? childTarget : "main", "state": iid == 1 ? parentState ?? "opened" : "opened",
             "sha": iid == 2 ? childHead : String(repeating: "a", count: 40), "draft": false,
             "detailed_merge_status": "mergeable", "has_conflicts": false, "user": ["can_merge": true]]
        }

        func merge() async throws {
            try await glab.mergeMergeRequest(projectID: 1, iid: 2, headSHA: childHead, host: host,
                expectedUser: .init(id: 3, username: "me"), shouldProceed: { true })
        }

        func poll() async throws {
            monitor.refreshIfNeeded()
            let deadline = ContinuousClock.now + .seconds(5)
            while monitor.isLoading && ContinuousClock.now < deadline { await Task.yield() }
            try #require(!monitor.isLoading)
        }

        func close() {
            gitlab.close()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
