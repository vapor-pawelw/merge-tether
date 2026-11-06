import Foundation
import Testing
@testable import GitLabTodos

struct TodoMergeRequestURLTests {
    private let host = "gitlab.example.org"
    private let base = "https://gitlab.example.org/group/project/-/merge_requests/1223"

    @Test func canonicalizesOnlyMRBaseAndExactPipelineEventURL() throws {
        for suffix in ["", "#note_7", "?tab=details#note_7", "/pipelines", "/pipelines?scope=all#latest"] {
            let input = try #require(URL(string: base + suffix))
            #expect(input.gitLabTodoMergeRequestURL(host: host, iid: 1223)?.absoluteString == base)
        }
        let pipeline = try #require(URL(string: base + "/pipelines"))
        #expect(!pipeline.isGitLabMergeRequest(host: host, iid: 1223))
    }

    @Test func rejectsWrongHostIIDPortCredentialsAndExtraPaths() throws {
        for url in [base + "/pipelines/extra", base + "/pipelines/pipelines", base + "/pipelines/", base + "/notes",
                    "https://other.example.org/group/project/-/merge_requests/1223/pipelines",
                    "https://gitlab.example.org:8443/group/project/-/merge_requests/1223/pipelines",
                    "https://user@gitlab.example.org/group/project/-/merge_requests/1223/pipelines"] {
            #expect(try #require(URL(string: url)).gitLabTodoMergeRequestURL(host: host, iid: 1223) == nil)
        }
        #expect(try #require(URL(string: base + "/pipelines")).gitLabTodoMergeRequestURL(host: host, iid: 12) == nil)
        #expect(try #require(URL(string: base)).gitLabTodoMergeRequestURL(host: host, iid: 0) == nil)
    }
}
