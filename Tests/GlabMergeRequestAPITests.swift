import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct GlabMergeRequestAPITests {
    @Test func unavailableApprovalsStillDeduplicateAssignedReviewers() {
        let reviewer = Todo.Author(id: 8, username: "waiting", name: "Waiting", avatarURL: nil)
        let invalid = Todo.Author(id: 0, username: "invalid", name: "Invalid", avatarURL: nil)
        let people = MergeRequestApprovalProgress.participants(reviewers: [reviewer, reviewer, invalid])
        #expect(people.map(\.author.id) == [8])
        #expect(people.map(\.approved) == [false])
    }
    @Test(arguments: [(0, 0, false), (2, 0, true), (0, 2, false), (1, 2, false), (2, 2, true)])
    func approvalSatisfactionDependsOnlyOnTheApprovalRequirement(_ example: (Int, Int, Bool)) throws {
        let progress = try #require(MergeRequestApprovalProgress(completed: example.0, required: example.1))
        #expect(progress.isSatisfied == example.2)
    }
    @Test func optionalApprovalsCountActualApproversWithoutARequiredDenominator() throws {
        let counts = try JSONDecoder().decode(GitLabMergeRequestApprovalCounts.self, from: Data(#"{"approvals_required":0,"approvals_left":0,"approved_by":[{"user":{"id":7,"username":"reviewer","name":"Reviewer","avatar_url":"https://gitlab.example.test/avatar.png"}},{"user":{"id":8,"username":"other","name":"Other"}}]}"#.utf8))
        let progress = try #require(counts.progress(projectID: 34, iid: 12))
        #expect(progress.completed == 2)
        #expect(progress.required == 0)
    }

    @Test func approvalPeopleAreApprovedFirstAndAssignedReviewersAppearOnce() throws {
        // given
        let counts = try JSONDecoder().decode(GitLabMergeRequestApprovalCounts.self, from: Data(#"{"approvals_required":2,"approvals_left":1,"approved_by":[{"user":{"id":7,"username":"approved","name":"Approved","avatar_url":"https://gitlab.example.test/avatar.png"}},{"user":{"id":9,"username":"unassigned","name":"Unassigned"}},{"user":{"id":7,"username":"approved","name":"Approved"}}]}"#.utf8))
        let progress = try #require(counts.progress(projectID: 34, iid: 12))
        let assigned = [Todo.Author(id: 8, username: "waiting", name: "Waiting", avatarURL: nil),
                        Todo.Author(id: 7, username: "approved", name: "Approved", avatarURL: nil)]
        // when
        let people = progress.participants(reviewers: assigned + assigned)
        // then
        #expect(people.map(\.author.id) == [7, 9, 8])
        #expect(people.map(\.approved) == [true, true, false])
        #expect(people.first?.author.avatarURL?.absoluteString == "https://gitlab.example.test/avatar.png")
        #expect(progress.completed == 1)
    }
    @Test func requiredApprovalProgressUsesGitLabsRemainingCountInsteadOfAllApprovers() throws {
        let data = Data(#"{"project_id":34,"iid":12,"approvals_required":2,"approvals_left":1,"approved_by":[{"user":{"id":1}},{"user":{"id":2}},{"user":{"id":3}}]}"#.utf8)
        let counts = try JSONDecoder().decode(GitLabMergeRequestApprovalCounts.self, from: data)
        let progress = try #require(counts.progress(projectID: 34, iid: 12))
        #expect(progress.completed == 1 && progress.required == 2)
        #expect(counts.progress(projectID: 35, iid: 12) == nil)
        #expect(counts.progress(projectID: 34, iid: 13) == nil)
    }

    @Test func noRequiredApprovalsIsKnownZeroRatherThanUnavailableData() throws {
        let counts = try JSONDecoder().decode(GitLabMergeRequestApprovalCounts.self,
            from: Data(#"{"approvals_required":0,"approvals_left":0}"#.utf8))
        let progress = try #require(counts.progress(projectID: 34, iid: 12))
        #expect(progress.completed == 0 && progress.required == 0)
    }

    @Test(arguments: [#"{}"#, #"{"approvals_required":2}"#, #"{"approvals_left":1}"#,
        #"{"approvals_required":-1,"approvals_left":0}"#, #"{"approvals_required":2,"approvals_left":-1}"#,
        #"{"approvals_required":2,"approvals_left":3}"#])
    func unavailableOrInvalidApprovalCountsNeverInventProgress(_ json: String) throws {
        let counts = try JSONDecoder().decode(GitLabMergeRequestApprovalCounts.self, from: Data(json.utf8))
        #expect(counts.progress(projectID: 34, iid: 12) == nil)
    }

    @Test func approvalProgressUsesTheReadOnlyMRApprovalEndpointAndExplicitHost() async throws {
        try await withFakeGlab { glab in
            let result = try await glab.fetchMergeRequestApprovalProgress(projectID: 34, iid: 12, host: host)
            let progress = try #require(result)
            #expect(progress.completed == 1 && progress.required == 2)
        }
    }
    private let host = "gitlab.example.test"
    private let sha = "0123456789abcdef0123456789abcdef01234567"

    @Test func readsAuthoredMergeRequestsAndTheirCurrentChecks() async throws {
        try await withFakeGlab { glab in
            let user = try await glab.fetchAuthenticatedUser(host: host, expectedUsername: "author")
            #expect(user.id == 7)
            let authored = try await glab.fetchAuthoredMergeRequests(host: host)
            #expect(authored.map(\.iid) == [12, 13])
            let current = try await glab.fetchMergeRequest(projectID: 34, iid: 12, host: host)
            #expect(current.author.id == user.id)
            #expect(current.detailedMergeStatus == "mergeable")
            #expect(current.canMerge == true)
            #expect(current.headPipeline?.status == "success")
            #expect(current.blockingDiscussionsResolved == true)
            let approvals = try await glab.fetchMergeRequestApprovalState(projectID: 34, iid: 12, host: host)
            #expect(approvals.hasRequiredRules)
            #expect(approvals.allRequiredRulesApproved)
            #expect(try await glab.projectRequiresResolvedDiscussions(projectID: 34, host: host))
            // The detail flag can be stale. A resolvable note without a resolved
            // value cannot prove all of the discussions are resolved.
            #expect(try await !glab.mergeRequestDiscussionsAreResolved(projectID: 34, iid: 12, host: host))
            #expect(try await glab.fetchBranchHeadSHA(projectID: 34, branch: "release/next+patch", host: host) == sha)
        }
    }

    @Test func mergesOnlyAfterRecheckingAccountAndPinsSourceHead() async throws {
        try await withFakeGlab(expectMerge: true) { glab in
            let user = try await glab.fetchAuthenticatedUser(host: host, expectedUsername: "author")
            try await glab.mergeMergeRequest(projectID: 34, iid: 12, headSHA: sha, host: host, expectedUser: user)
        }
    }

    @Test func workItemProposalUsesTheSingleExplicitMRReference() async throws {
        try await withFakeGlab { glab in
            let request = try await glab.fetchMergeRequest(projectID: 34, iid: 12, host: host)
            let item = try await glab.singleLinkedWorkItem(for: request, host: host)
            #expect(item?.absoluteString == "https://\(host)/group/repo/-/work_items/19")
        }
    }

    @Test func managedRepositoryURLResolvesToTheCanonicalProjectID() async throws {
        try await withFakeGlab { glab in
            let project = try await glab.resolveAutomationProject(path: "group/repo", host: host)
            #expect(project == 34)
        }
    }

    @Test func rejectsSameUsernameWithDifferentAccountIDBeforeMerge() async throws {
        try await withFakeGlab { glab in
            let otherUser = GitLabAuthenticatedUser(id: 999, username: "author")
            await #expect(throws: GlabError.notAuthenticated) {
                try await glab.mergeMergeRequest(projectID: 34, iid: 12, headSHA: sha, host: host, expectedUser: otherUser)
            }
        }
    }

    @Test func cancelsBeforeMergeWhenAutomationWasDisabledDuringRecheck() async throws {
        try await withFakeGlab { glab in
            let user = try await glab.fetchAuthenticatedUser(host: host, expectedUsername: "author")
            await #expect(throws: CancellationError.self) {
                try await glab.mergeMergeRequest(
                    projectID: 34, iid: 12, headSHA: sha, host: host, expectedUser: user,
                    shouldProceed: { false }
                )
            }
        }
    }

    @Test func zeroApprovalRulesAndUnknownRuleStatesStayDistinguishable() throws {
        let decoder = JSONDecoder()
        let noRules = try decoder.decode(GitLabMergeRequestApprovalState.self, from: Data(#"{"rules":[]}"#.utf8))
        #expect(!noRules.hasRequiredRules)
        #expect(noRules.allRequiredRulesApproved)
        let unknown = try decoder.decode(GitLabMergeRequestApprovalState.self, from: Data(#"{"rules":[{"approvals_required":1}]}"#.utf8))
        #expect(unknown.hasRequiredRules)
        #expect(!unknown.allRequiredRulesApproved)
    }

    @Test func marksOnlyTheCurrentOwnDraftReadyUsingTheDocumentedCLIAction() async throws {
        try await withReadyGlab(expectWrites: 1) { glab, _ in
            let updated = try await glab.markMergeRequestReady(projectID: 34, iid: 12, headSHA: sha,
                host: host, expectedUser: .init(id: 7, username: "author"))
            #expect(updated.draft == false && updated.sha == sha && updated.author.id == 7)
        }
    }

    @Test func markingAnAlreadyReadyOwnMRIsIdempotent() async throws {
        try await withReadyGlab(overrides: ["draft": false]) { glab, _ in
            let updated = try await glab.markMergeRequestReady(projectID: 34, iid: 12, headSHA: sha,
                host: host, expectedUser: .init(id: 7, username: "author"))
            #expect(updated.draft == false)
        }
    }

    @Test(arguments: ["foreign", "closed", "head"])
    func readyActionRejectsChangedOwnershipStateOrHead(reason: String) async throws {
        let overrides: [String: Any] = switch reason {
        case "foreign": ["author": ["id": 8, "username": "someone_else", "name": "Other Author"]]
        case "closed": ["state": "closed"]
        default: ["sha": String(repeating: "b", count: 40)]
        }
        try await withReadyGlab(overrides: overrides) { glab, _ in
            await #expect(throws: CancellationError.self) {
                _ = try await glab.markMergeRequestReady(projectID: 34, iid: 12, headSHA: sha,
                    host: host, expectedUser: .init(id: 7, username: "author"))
            }
        }
    }

    @Test func readyActionRejectsTheSameUsernameWithAnotherAccountID() async throws {
        try await withReadyGlab { glab, _ in
            await #expect(throws: GlabError.notAuthenticated) {
                _ = try await glab.markMergeRequestReady(projectID: 34, iid: 12, headSHA: sha,
                    host: host, expectedUser: .init(id: 999, username: "author"))
            }
        }
    }

    @Test func readyActionHonorsTheCallersFinalFence() async throws {
        try await withReadyGlab { glab, _ in
            await #expect(throws: CancellationError.self) {
                _ = try await glab.markMergeRequestReady(projectID: 34, iid: 12, headSHA: sha,
                    host: host, expectedUser: .init(id: 7, username: "author"), shouldProceed: { false })
            }
        }
    }

    @Test func accountRoundTripDuringTheReadyPreflightCannotWrite() async throws {
        try await withReadyGlab(gateRead: true) { glab, directory in
            let release = directory.appending(path: "release")
            let task = Task { try await glab.markMergeRequestReady(projectID: 34, iid: 12, headSHA: sha,
                host: host, expectedUser: .init(id: 7, username: "author")) }
            defer { task.cancel(); try? Data().write(to: release) }
            let entered = directory.appending(path: "entered")
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: entered.path) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(FileManager.default.fileExists(atPath: entered.path))
            glab.currentUsername = "other"
            glab.currentUsername = "author"
            try Data().write(to: release)
            await #expect(throws: GlabError.notAuthenticated) { _ = try await task.value }
        }
    }

    @Test func readyActionRequiresLiveConfirmationAfterTheWrite() async throws {
        try await withReadyGlab(resultStillDraft: true, expectWrites: 1) { glab, _ in
            await #expect(throws: (any Error).self) {
                _ = try await glab.markMergeRequestReady(projectID: 34, iid: 12, headSHA: sha,
                    host: host, expectedUser: .init(id: 7, username: "author"))
            }
        }
    }

    private func withReadyGlab(
        overrides: [String: Any] = [:], resultStillDraft: Bool = false, gateRead: Bool = false,
        expectWrites: Int = 0, _ body: (GlabService, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var request: [String: Any] = ["project_id": 34, "iid": 12,
            "author": ["id": 7, "username": "author", "name": "Author"], "title": "Draft: Sample MR",
            "web_url": "https://\(host)/group/repo/-/merge_requests/12", "state": "opened", "draft": true,
            "sha": sha, "source_project_id": 34, "source_branch": "feature", "target_branch": "main", "labels": []]
        for (key, value) in overrides { request[key] = value }
        try JSONSerialization.data(withJSONObject: request).write(to: directory.appending(path: "mr.json"))
        request["draft"] = resultStillDraft
        request["title"] = "Sample MR"
        try JSONSerialization.data(withJSONObject: request).write(to: directory.appending(path: "ready.json"))
        if gateRead { try Data().write(to: directory.appending(path: "gate")) }
        let executable = directory.appending(path: "glab")
        try Data("""
        #!/bin/sh
        set -eu
        root="$(dirname "$0")"
        case "$*" in
          'api /user --hostname \(host)')
            printf 'x' >> "$root/user-checks"
            printf '%s' '{"id":7,"username":"author"}' ;;
          'api /projects/34/merge_requests/12 --hostname \(host)')
            if [ -f "$root/gate" ]; then
              touch "$root/entered"
              while [ ! -f "$root/release" ]; do sleep 0.01; done
            fi
            cat "$root/mr.json" ;;
          'mr update 12 --ready --yes --repo https://\(host)/group/repo')
            test -s "$root/user-checks"
            printf '%s\\n' "$*" >> "$root/writes"
            cp "$root/ready.json" "$root/mr.json"
            printf '%s' 'Merge request is ready' ;;
          *) printf '%s' 'Unexpected fake glab command' >&2; exit 20 ;;
        esac
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let glab = GlabService()
        glab.glabPath = executable
        glab.resolvedHost = host
        glab.currentUsername = "author"
        try await body(glab, directory)
        let writes = (try? String(contentsOf: directory.appending(path: "writes"), encoding: .utf8)) ?? ""
        #expect(writes.split(separator: "\n").count == expectWrites)
    }

    private func withFakeGlab(
        expectMerge: Bool = false,
        _ body: (GlabService) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "glab")
        let request = """
        {"project_id":34,"iid":12,"author":{"id":7,"username":"author","name":"Author A"},
        "title":"Sample MR","description":"Related to #19","web_url":"https://\(host)/group/repo/-/merge_requests/12","state":"opened",
        "draft":false,"sha":"\(sha)","source_project_id":34,"source_branch":"feature",
        "target_project_id":34,"target_branch":"release/next+patch","detailed_merge_status":"mergeable",
        "has_conflicts":false,"labels":["auto merge"],"blocking_discussions_resolved":true,
        "head_pipeline":{"status":"success","sha":"\(sha)"},"user":{"can_merge":true}}
        """
        try Data("""
        #!/bin/sh
        set -eu
        case "$*" in
          'api /user --hostname \(host)')
            printf 'x' >> "$0-user-checks"
            printf '%s' '{"id":7,"username":"author"}'
            ;;
          'api /merge_requests?scope=created_by_me&state=opened&with_merge_status_recheck=true&per_page=100 --hostname \(host) --paginate')
            printf '%s\\n' '[\(request)]' '[\(request.replacingOccurrences(of: "\"iid\":12", with: "\"iid\":13"))]'
            ;;
          'api /projects/34/merge_requests/12 --hostname \(host)')
            printf '%s' '\(request)'
            ;;
          'api /projects/34/merge_requests/12/approval_state --hostname \(host)')
            printf '%s' '{"rules":[{"approvals_required":1,"approved":true},{"approvals_required":0,"approved":false}]}'
            ;;
          'api /projects/34/merge_requests/12/approvals --hostname \(host)')
            printf '%s' '{"project_id":34,"iid":12,"approvals_required":2,"approvals_left":1,"approved_by":[]}'
            ;;
          'api /projects/34/merge_requests/12/closes_issues?per_page=100 --hostname \(host) --paginate')
            printf '%s' '[]'
            ;;
          'api /projects/34/merge_requests/12/related_issues?per_page=100 --hostname \(host) --paginate')
            printf '%s' '[{"iid":19,"project_id":34,"web_url":"https://\(host)/group/repo/-/work_items/19"},{"iid":23,"project_id":34,"web_url":"https://\(host)/group/repo/-/work_items/23"}]'
            ;;
          'api /projects/34 --hostname \(host)')
            printf '%s' '{"only_allow_merge_if_all_discussions_are_resolved":true}'
            ;;
          'api /projects/group%2Frepo --hostname \(host)')
            printf '%s' '{"id":34,"path_with_namespace":"group/repo"}'
            ;;
          'api /projects/34/merge_requests/12/discussions?per_page=100 --hostname \(host) --paginate')
            printf '%s\\n' '[{"notes":[{"resolvable":false},{"resolvable":true,"resolved":true}]}]' '[{"notes":[{"resolvable":true}]}]'
            ;;
          'api /projects/34/repository/branches/release%2Fnext%2Bpatch --hostname \(host)')
            printf '%s' '{"commit":{"id":"\(sha)"}}'
            ;;
          'api /projects/34/merge_requests/12/merge --hostname \(host) --method PUT --raw-field sha=\(sha)')
            test "$(cat "$0-user-checks")" = 'xx'
            touch "$0-merged"
            printf '%s' '{"project_id":34,"iid":12,"state":"merged"}'
            ;;
          *) printf '%s' 'Unexpected glab command' >&2; exit 20 ;;
        esac
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let glab = GlabService()
        glab.glabPath = executable
        try await body(glab)
        #expect(FileManager.default.fileExists(atPath: executable.path + "-merged") == expectMerge)
    }
}
