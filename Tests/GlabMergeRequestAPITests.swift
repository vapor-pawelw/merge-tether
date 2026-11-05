import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct GlabMergeRequestAPITests {
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
