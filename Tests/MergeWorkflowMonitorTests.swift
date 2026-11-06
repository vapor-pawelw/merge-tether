import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct MergeWorkflowMonitorTests {
    @Test func renumbersStackFromTheBaseAndDropsPositionForTheLastMR() throws {
        let decoder = JSONDecoder()
        let base = try decoder.decode(GitLabMergeRequest.self, from: Data(mergeRequest(1, sha: "a", source: "base", target: "main").utf8))
        let middle = try decoder.decode(GitLabMergeRequest.self, from: Data(mergeRequest(2, sha: "b", source: "middle", target: "base").utf8))
        let leaf = try decoder.decode(GitLabMergeRequest.self, from: Data(mergeRequest(3, sha: "c", source: "leaf", target: "middle").utf8))
        let sibling = try decoder.decode(GitLabMergeRequest.self, from: Data(mergeRequest(4, sha: "d", source: "sibling", target: "base").utf8))
        #expect(MergeRequestStackSnapshot(requests: [leaf, base, sibling, middle], defaultBranch: "main").positions
            == [1: "1/3", 2: "2/3", 3: "3/3", 4: "2/2"])
        #expect(MergeRequestStackSnapshot(requests: [leaf, middle], defaultBranch: "main").positions
            == [2: "1/2", 3: "2/2"])
        #expect(MergeRequestStackSnapshot(requests: [leaf], defaultBranch: "main").positions.isEmpty)
        #expect(MergeRequestStackSnapshot.title("[MT] repo !3 (Own)", iid: 3, position: "2/2") == "[MT] repo !3 2/2 (Own)")
    }

    @Test func discoversNewEventsOnceAcrossPollsAndAppRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "MergeWorkflowMonitorTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let host = "gitlab.example.test"
        let user = GitLabAuthenticatedUser(id: 1, username: "owner")
        let sha1 = String(repeating: "a", count: 40)
        let sha2 = String(repeating: "b", count: 40)
        let created = try #require(ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        let decoder = JSONDecoder()
        let selected = Set(MergeWorkflowTrigger.allCases)
        let executable = directory.appending(path: "glab")
        try write("""
        #!/bin/sh
        case "$2" in
          *scope=all*reviewer_id=1*) file=assigned ;;
          */11/discussions*) file=discussions ;;
          */11/reviewers*) file=waiting ;;
          */13/reviewers*) file=reviewer ;;
          */pipelines/310/jobs*) file=jobs ;;
          */merge_trains[?]*) file=train ;;
          */merge_requests/12) file=parent ;;
          */merge_requests/14) file=release ;;
          /projects/7) file=project ;;
          */blocks*|*/discussions*|*/reviewers*) printf '%s' '[]'; exit ;;
          *) exit 20 ;;
        esac
        cat "${0%/*}/$file"
        """, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let glab = GlabService()
        glab.glabPath = executable

        func fixture(_ name: String, _ json: String) throws { try write(json, to: directory.appending(path: name)) }
        let parentJSON = mergeRequest(12, sha: sha1, source: "parent", target: "main")
        let parent = try decoder.decode(GitLabMergeRequest.self, from: Data(parentJSON.utf8))
        let release = try decoder.decode(GitLabMergeRequest.self, from: Data(
            mergeRequest(14, sha: sha1, source: "main", target: "release").utf8
        ))
        let ordinary = try decoder.decode(GitLabMergeRequest.self, from: Data(
            mergeRequest(15, sha: sha1, source: "ordinary", target: "main").utf8
        ))
        try fixture("project", #"{"default_branch":"main"}"#)
        try fixture("assigned", "[\(mergeRequest(13, sha: sha1, author: 2))]")
        try fixture("reviewer", #"[{"user":{"id":1},"state":"reviewed","created_at":"2026-01-01T00:00:00Z"}]"#)
        try fixture("waiting", #"[{"user":{"id":3},"state":"unreviewed","created_at":"2026-01-01T00:00:00Z"}]"#)
        try fixture("discussions", #"[{"notes":[{"id":100,"author":{"id":3},"system":false,"resolvable":true,"resolved":false}]}]"#)
        try fixture("train", #"[{"merge_request":{"iid":11,"project_id":7}}]"#)

        let running = mergeRequest(11, sha: sha1, pipeline: "running")
        let child = try decoder.decode(GitLabMergeRequest.self, from: Data(running.utf8))
        let monitor = MergeWorkflowMonitor(defaults: defaults)
        var delivered: [MergeWorkflowEvent] = []
        await monitor.poll(glab: glab, host: host, user: user, authored: [child, parent, release, ordinary],
                           enabled: selected, reviewSLA: 7_200, now: created.addingTimeInterval(3_600)) {
            delivered.append($0)
        }
        #expect(delivered.isEmpty)

        try fixture("assigned", "[\(mergeRequest(13, sha: sha2, author: 2))]")
        try fixture("reviewer", #"[{"user":{"id":1},"state":"unreviewed","created_at":"2026-01-01T00:00:00Z"}]"#)
        try fixture("discussions", """
        [{"notes":[{"id":100,"author":{"id":3},"system":false,"resolvable":true,"resolved":false},
                   {"id":101,"author":{"id":3},"system":false,"resolvable":true,"resolved":false},
                   {"id":102,"author":{"id":1},"system":false,"resolvable":true,"resolved":false}]}]
        """)
        try fixture("train", "[]")
        try fixture("parent", mergeRequest(12, sha: sha1, source: "parent", target: "main", state: "merged"))
        try fixture("release", mergeRequest(14, sha: sha1, source: "main", target: "release", state: "merged"))
        try fixture("jobs", #"[{"id":42,"status":"failed","allow_failure":false,"failure_reason":"runner_system_failure"}]"#)
        let blocked = mergeRequest(11, sha: sha1, blocker: "requested_changes", pipeline: "failed")
        let updated = try decoder.decode(GitLabMergeRequest.self, from: Data(blocked.utf8))
        let now = created.addingTimeInterval(10_800)
        await monitor.poll(glab: glab, host: host, user: user, authored: [updated, ordinary],
                           enabled: selected, reviewSLA: 7_200, now: now) {
            delivered.append($0)
        }
        #expect(delivered.count == 6)
        #expect(Set(delivered.map(\.kind)) == selected)
        let failure = try #require(delivered.first { $0.kind == .pipelineFailure })
        #expect(failure.pipelineProjectID == 7)
        #expect(failure.pipelineID == 310)
        #expect(failure.jobID == 42)
        #expect(failure.isInfrastructureFailure)
        let discussion = try #require(delivered.first { $0.kind == .newDiscussion })
        #expect(discussion.noteIDs == [101])
        #expect(delivered.first { $0.kind == .reviewUpdate }?.mergeRequest.sha == sha2)

        let restarted = MergeWorkflowMonitor(defaults: defaults)
        delivered.removeAll()
        await restarted.poll(glab: glab, host: host, user: user, authored: [updated, ordinary],
                             enabled: selected, reviewSLA: 7_200, now: now) {
            delivered.append($0)
        }
        #expect(delivered.isEmpty)
    }

    private func mergeRequest(
        _ iid: Int,
        sha: String,
        author: Int = 1,
        source: String = "child",
        target: String = "parent",
        state: String = "opened",
        blocker: String = "mergeable",
        pipeline: String? = nil
    ) -> String {
        let head = pipeline.map { #"{"id":310,"project_id":7,"status":"\#($0)","sha":"\#(sha)"}"# } ?? "null"
        return """
        {"project_id":7,"iid":\(iid),"author":{"id":\(author),"username":"owner","name":"Owner"},
        "title":"Sample","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/\(iid)","state":"\(state)",
        "draft":false,"sha":"\(sha)","source_project_id":7,"source_branch":"\(source)",
        "target_project_id":7,"target_branch":"\(target)","detailed_merge_status":"\(blocker)",
        "has_conflicts":false,"labels":[],"head_pipeline":\(head),"user":{"can_merge":true}}
        """
    }

    private func write(_ content: String, to url: URL) throws {
        try Data(content.utf8).write(to: url)
    }
    @Test(arguments: [true, false]) func authorRepliesTriggerReReviewWithoutANewCommitAndSurviveRestart(assigned: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "AuthorReplyReReview.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = "gitlab.example.test"
        let user = GitLabAuthenticatedUser(id: 1, username: "owner")
        let request = mergeRequest(13, sha: String(repeating: "a", count: 40), author: 2)
        try write(assigned ? "[\(request)]" : "[]", to: directory.appending(path: "assigned"))
        try write(request, to: directory.appending(path: "request"))
        try write(assigned ? #"[{"user":{"id":1},"state":"reviewed"}]"# : "[]", to: directory.appending(path: "reviewer"))
        let before = #"[{"id":"mine","notes":[{"id":100,"author":{"id":1},"system":false,"resolvable":true,"resolved":false}]}]"#
        let after = #"[{"id":"mine","notes":[{"id":100,"author":{"id":1},"system":false,"resolvable":true,"resolved":false},{"id":101,"author":{"id":2},"system":false}]}]"#
        try write(before, to: directory.appending(path: "threads"))
        let executable = directory.appending(path: "glab")
        try write("""
        #!/bin/sh
        case "$2" in
          *scope=all*reviewer_id=1*) file=assigned ;;
          */reviewers*) file=reviewer ;;
          */discussions*) file=threads ;;
          */merge_requests/13) file=request ;;
          *) exit 1 ;;
        esac
        cat "${0%/*}/$file"
        """, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let glab = GlabService()
        glab.glabPath = executable
        let monitor = MergeWorkflowMonitor(defaults: defaults)
        var events: [MergeWorkflowEvent] = []
        await monitor.poll(glab: glab, host: host, user: user, authored: [], enabled: [.reviewUpdate], reviewSLA: 3600, trackedReviews: [.init(host: host, projectID: 7, iid: 13)]) { events.append($0) }
        #expect(events.isEmpty)
        try write(after, to: directory.appending(path: "threads"))
        await monitor.poll(glab: glab, host: host, user: user, authored: [], enabled: [.reviewUpdate], reviewSLA: 3600, trackedReviews: [.init(host: host, projectID: 7, iid: 13)]) { events.append($0) }
        #expect(events.count == 1)
        #expect(events.first?.kind == .reviewUpdate)
        #expect(events.first?.noteIDs == [101])
        events.removeAll()
        let restarted = MergeWorkflowMonitor(defaults: defaults)
        await restarted.poll(glab: glab, host: host, user: user, authored: [], enabled: [.reviewUpdate], reviewSLA: 3600, trackedReviews: [.init(host: host, projectID: 7, iid: 13)]) { events.append($0) }
        #expect(events.isEmpty)
    }

}
