import Foundation
import Testing
@testable import GitLabTodos

struct ManualMergeRequestReviewTests {
    private let target = ManualReviewTarget(host: "gitlab.example.org", username: "reviewer", projectID: 7, iid: 12,
        url: URL(string: "https://gitlab.example.org/group/app/-/merge_requests/12")!)

    private func request(state: String = "opened", author: String = "author", projectID: Int = 7,
                         iid: Int = 12, url: String = "https://gitlab.example.org/group/app/-/merge_requests/12",
                         sha: String? = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") throws -> GitLabMergeRequest {
        var object: [String: Any] = ["project_id": projectID, "iid": iid, "title": "Improve logging",
            "author": ["id": 2, "username": author, "name": "Author"], "state": state, "web_url": url,
            "source_branch": "fix", "target_branch": "main", "labels": []]
        if let sha { object["sha"] = sha }
        return try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func acceptsFreshOpenedReviewTargetWithoutAutomationScope() throws {
        #expect(target.accepts(try request()))
        #expect(target.matchesAccount(host: "gitlab.example.org", username: "reviewer"))
    }

    @Test func rejectsClosedMergedOwnAndMissingHeadRequests() throws {
        #expect(!target.accepts(try request(state: "closed")))
        #expect(!target.accepts(try request(state: "merged")))
        #expect(!target.accepts(try request(author: "reviewer")))
        #expect(!target.accepts(try request(sha: nil)))
        #expect(!target.accepts(try request(sha: "")))
    }

    @Test func rejectsDifferentProjectNumberHostAndURL() throws {
        #expect(!target.accepts(try request(projectID: 8)))
        #expect(!target.accepts(try request(iid: 13)))
        #expect(!target.accepts(try request(url: "https://other.example.org/group/app/-/merge_requests/12")))
        #expect(!target.accepts(try request(url: "https://gitlab.example.org/other/app/-/merge_requests/12")))
        #expect(!target.accepts(try request(url: "https://gitlab.example.org:8443/group/app/-/merge_requests/12")))
    }

    @Test func accountSwitchInvalidatesCapturedTarget() {
        #expect(!target.matchesAccount(host: "other.example.org", username: "reviewer"))
        #expect(!target.matchesAccount(host: "gitlab.example.org", username: "other"))
        #expect(!target.matchesAccount(host: nil, username: nil))
    }
}
