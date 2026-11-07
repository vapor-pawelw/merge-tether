import Foundation
import Testing
@testable import GitLabTodos

struct MRDependencyPresentationTests {
    @Test(arguments: ["gitlab.example.test", "gitlab.example.test:8443"])
    func combinesTheOpenStackParentAndGitLabBlockerIntoOnePredecessor(_ host: String) throws {
        let base = try request(1, source: "base", target: "main", author: 9, host: host)
        let middle = try request(2, source: "middle", target: "base", host: host)
        let leaf = try request(3, source: "leaf", target: "middle", host: host)
        let summary = MergeRequestDependencySummary(request: middle,
            stack: .init(requests: [leaf, base, middle], defaultBranch: "main"),
            dependencies: .init(requests: [base], hasHiddenDependency: false))
        #expect(summary.stackPosition == "2/3")
        #expect(summary.predecessors.count == 1)
        #expect(summary.predecessors.first?.iid == 1)
        #expect(summary.predecessors.first?.sources == [.gitLab, .stack])
        #expect(summary.issues.isEmpty)
    }

    @Test func onlyCurrentlyOpenDependenciesCountIncludingCrossProjectDrafts() throws {
        let current = try request(10)
        let draft = try request(4, project: 77, state: "opened", draft: true)
        let merged = try request(5, state: "merged")
        let closed = try request(6, state: "closed")
        let summary = MergeRequestDependencySummary(request: current,
            stack: .init(requests: [current], defaultBranch: "main"),
            dependencies: .init(requests: [merged, draft, closed, draft], hasHiddenDependency: false))
        #expect(summary.stackPosition == nil)
        #expect(summary.predecessors.map(\.projectID) == [77])
        #expect(summary.predecessors.first?.reference(relativeTo: current.projectID) == "repo77 !4")
        #expect(summary.predecessors.first?.url == draft.webURL)
    }

    @Test func descriptionsAndTitlesNeverCreateDependencies() throws {
        let current = try request(10, title: "Part 2/3 after !1", description: "Depends on !1 and group/repo!2")
        let unrelated = try request(1, source: "unrelated")
        let summary = MergeRequestDependencySummary(request: current,
            stack: .init(requests: [current, unrelated], defaultBranch: "main"),
            dependencies: .init(requests: [], hasHiddenDependency: false))
        #expect(summary.stackPosition == nil)
        #expect(summary.predecessors.isEmpty)
        #expect(summary.issues.isEmpty)
    }

    @Test func incompleteAndForkedStacksDoNotInventATotal() throws {
        let middle = try request(2, source: "middle", target: "missing")
        let leaf = try request(3, source: "leaf", target: "middle")
        let partial = MergeRequestDependencySummary(request: leaf,
            stack: .init(requests: [middle, leaf], defaultBranch: "main"),
            dependencies: .init(requests: [], hasHiddenDependency: false))
        #expect(partial.stackPosition == nil)
        #expect(partial.predecessors.map(\.iid) == [2])
        #expect(partial.issues.contains(.stackIncomplete))
        let base = try request(1, source: "base")
        let child = try request(2, source: "middle", target: "base")
        let sibling = try request(4, source: "sibling", target: "base")
        for current in [base, child, sibling] {
            let forked = MergeRequestDependencySummary(request: current,
                stack: .init(requests: [base, child, sibling], defaultBranch: "main"),
                dependencies: .init(requests: [], hasHiddenDependency: false))
            #expect(forked.stackPosition == nil)
            #expect(forked.issues.contains(.stackAmbiguous))
        }
    }

    @Test func ambiguousParentsAndCyclesAreUncertainRatherThanArbitrary() throws {
        let parent = try request(1, source: "base")
        let duplicate = try request(4, source: "base", author: 9)
        let child = try request(2, source: "child", target: "base")
        let ambiguous = MergeRequestDependencySummary(request: child,
            stack: .init(requests: [parent, duplicate, child], defaultBranch: "main"),
            dependencies: .init(requests: [], hasHiddenDependency: false))
        #expect(ambiguous.stackPosition == nil)
        #expect(ambiguous.predecessors.isEmpty)
        #expect(ambiguous.issues.contains(.stackAmbiguous))
        let cycle = try request(1, source: "base", target: "child")
        let cyclic = MergeRequestDependencySummary(request: child,
            stack: .init(requests: [cycle, child], defaultBranch: "main"),
            dependencies: .init(requests: [], hasHiddenDependency: false))
        #expect(cyclic.stackPosition == nil)
        #expect(cyclic.issues.contains(.stackAmbiguous))
    }

    @Test func missingSourceProjectAndForeignHostNeverBecomeVerifiedParents() throws {
        let child = try request(2, source: "child", target: "base")
        let unknown = try request(1, source: "base", sourceProject: nil)
        let foreign = try request(3, host: "other.example.test")
        let summary = MergeRequestDependencySummary(request: child,
            stack: .init(requests: [unknown, child], defaultBranch: "main"),
            dependencies: .init(requests: [foreign], hasHiddenDependency: false))
        #expect(summary.predecessors.isEmpty)
        #expect(summary.stackPosition == nil)
        #expect(summary.issues.contains(.dependenciesUnavailable))
    }

    @Test func hiddenOrFailedDependencyReadsRemainExplicitlyUnknown() throws {
        let current = try request(10)
        let hidden = MergeRequestDependencySummary(request: current,
            stack: .init(requests: [current], defaultBranch: "main"),
            dependencies: .init(requests: [], hasHiddenDependency: true))
        #expect(hidden.predecessors.isEmpty)
        #expect(hidden.issues.contains(.hiddenDependency))
        let failed = MergeRequestDependencySummary(request: current, stack: nil, dependencies: nil)
        #expect(failed.issues.contains(.dependenciesUnavailable))
        #expect(failed.issues.contains(.stackUnavailable))
    }

    func request(_ iid: Int, project: Int = 34, source: String = "feature", target: String = "main",
                 author: Int = 7, state: String = "opened", draft: Bool = false,
                 sourceProject: Int? = 34, host: String = "gitlab.example.test",
                 title: String = "Example MR", description: String = "") throws -> GitLabMergeRequest {
        var fields: [String: Any] = ["project_id": project, "iid": iid, "title": title,
            "description": description, "author": ["id": author, "username": "author\(author)", "name": "Author"],
            "web_url": "https://\(host)/group/repo\(project)/-/merge_requests/\(iid)",
            "state": state, "draft": draft, "sha": String(repeating: "a", count: 40),
            "source_branch": source, "target_project_id": project, "target_branch": target, "labels": []]
        if let sourceProject { fields["source_project_id"] = sourceProject == 34 ? project : sourceProject }
        return try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: fields))
    }
}
