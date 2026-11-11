import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct MergeWorkflowMonitorTests {
    @Test func corruptWorkflowBaselinesCannotBeOverwrittenOrReplayFailureWork() async throws {
        // given
        let suite = "CorruptWorkflowBaselines.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "automation.mergeWorkflowBaselines.v1"
        let raw = Data("unsupported baseline history".utf8)
        defaults.set(raw, forKey: key)
        let gitlab = persistenceGitLab()
        let glab = gitlab.service(host: "gitlab.example.test", username: "owner")
        let failed = try JSONDecoder().decode(GitLabMergeRequest.self,
            from: Data(mergeRequest(11, sha: String(repeating: "a", count: 40), pipeline: "failed").utf8))
        var events: [MergeWorkflowEvent] = []

        // when
        for _ in 0..<2 {
            let monitor = MergeWorkflowMonitor(defaults: defaults)
            await monitor.poll(glab: glab, host: "gitlab.example.test", user: .init(id: 1, username: "owner"),
                authored: [failed], enabled: [.pipelineFailure], reviewSLA: 7_200) { events.append($0) }
        }

        // then
        #expect(events.isEmpty)
        #expect(defaults.data(forKey: key) == raw)
        #expect(!SettingsManager(defaults: defaults).automaticActionsAllowed)
        #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
    }

    @Test func workflowEventsWaitForTheirBaselineWriteAndStayHeldAfterRestart() async throws {
        // given
        let suite = "FailedWorkflowBaselineWrite.\(UUID())"
        let defaults = try #require(PersistenceFaultDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.rejectedKey = "automation.mergeWorkflowBaselines.v1"
        let gitlab = persistenceGitLab()
        let glab = gitlab.service(host: "gitlab.example.test", username: "owner")
        let failed = try JSONDecoder().decode(GitLabMergeRequest.self,
            from: Data(mergeRequest(11, sha: String(repeating: "a", count: 40), pipeline: "failed").utf8))
        var events: [MergeWorkflowEvent] = []
        let monitor = MergeWorkflowMonitor(defaults: defaults)

        // when
        await monitor.poll(glab: glab, host: "gitlab.example.test", user: .init(id: 1, username: "owner"),
            authored: [failed], enabled: [.pipelineFailure], reviewSLA: 7_200) { events.append($0) }
        defaults.rejectedKey = nil
        let restarted = MergeWorkflowMonitor(defaults: defaults)
        await restarted.poll(glab: glab, host: "gitlab.example.test", user: .init(id: 1, username: "owner"),
            authored: [failed], enabled: [.pipelineFailure], reviewSLA: 7_200) { events.append($0) }

        // then
        #expect(events.isEmpty)
        #expect(!SettingsManager(defaults: defaults).automaticActionsAllowed)
    }

    private func persistenceGitLab() -> InMemoryGitLab {
        let gitlab = InMemoryGitLab()
        gitlab.handler = { call in
            if call.endpoint.contains("/pipelines/310/jobs") {
                return InMemoryGitLab.output(#"[{"id":42,"status":"failed","allow_failure":false,"failure_reason":"script_failure"}]"#)
            }
            return try gitlab.unexpected(call)
        }
        return gitlab
    }

    @Test func pausedDraftFailureIsNotConsumedBeforeExplicitOptInEvenAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "DraftWorkflowPause.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let executable = directory.appending(path: "glab")
        try write("""
        #!/bin/sh
        case "$2" in
          */pipelines/310/jobs*) printf '%s' '[{"id":42,"status":"failed","allow_failure":false,"failure_reason":"script_failure"}]' ;;
          *) exit 20 ;;
        esac
        """, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let glab = GlabService()
        glab.glabPath = executable
        let failed = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(
            mergeRequest(11, sha: String(repeating: "a", count: 40), pipeline: "failed")
                .replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#).utf8))
        var scope = MRAutomationScope()
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "owner", projectID: 7, iid: 11)
        // A legacy active override represents tracking, not explicit Draft permission.
        scope[target] = .active
        var events: [MergeWorkflowEvent] = []
        let monitor = MergeWorkflowMonitor(defaults: defaults)
        await monitor.poll(glab: glab, host: target.host, user: .init(id: 1, username: target.username),
            authored: [failed], enabled: [.pipelineFailure], reviewSLA: 7_200, automationScope: scope) { events.append($0) }
        #expect(events.isEmpty)
        events.removeAll()

        scope.setEnabled(true, for: target, isDraft: true)
        let restarted = MergeWorkflowMonitor(defaults: defaults)
        await restarted.poll(glab: glab, host: target.host, user: .init(id: 1, username: target.username),
            authored: [failed], enabled: [.pipelineFailure], reviewSLA: 7_200, automationScope: scope) { events.append($0) }
        #expect(events.count == 1 && events.first?.mergeRequest.draft == true)
        await restarted.poll(glab: glab, host: target.host, user: .init(id: 1, username: target.username),
            authored: [failed], enabled: [.pipelineFailure], reviewSLA: 7_200, automationScope: scope) { events.append($0) }
        #expect(events.count == 1)
    }

    @Test func optingOutDuringWorkflowReadsPreservesThePendingEventForLaterOptIn() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "DraftWorkflowPolicyRace.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let executable = directory.appending(path: "glab")
        try write("""
        #!/bin/sh
        cd "$(dirname "$0")"
        case "$2" in
          */pipelines/310/jobs*)
            touch started
            while [ ! -e release ]; do sleep 0.02; done
            printf '%s' '[{"id":42,"status":"failed","allow_failure":false,"failure_reason":"script_failure"}]' ;;
          *) exit 20 ;;
        esac
        """, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let glab = GlabService()
        glab.glabPath = executable
        let failed = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(
            mergeRequest(11, sha: String(repeating: "a", count: 40), pipeline: "failed")
                .replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#).utf8))
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "owner", projectID: 7, iid: 11)
        var scope = MRAutomationScope()
        scope.setEnabled(true, for: target, isDraft: true)
        let admittedScope = scope
        var events: [MergeWorkflowEvent] = []
        let monitor = MergeWorkflowMonitor(defaults: defaults)
        let polling = Task {
            await monitor.poll(glab: glab, host: target.host, user: .init(id: 1, username: target.username),
                authored: [failed], enabled: [.pipelineFailure], reviewSLA: 7_200, automationScope: admittedScope,
                isCurrent: { scope == admittedScope }) { events.append($0) }
        }
        let started = directory.appending(path: "started")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: started.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        scope.setEnabled(false, for: target, isDraft: true)
        try Data().write(to: directory.appending(path: "release"))
        await polling.value
        #expect(FileManager.default.fileExists(atPath: started.path))
        #expect(events.isEmpty)
        events.removeAll()
        scope.setEnabled(true, for: target, isDraft: true)
        let restarted = MergeWorkflowMonitor(defaults: defaults)
        await restarted.poll(glab: glab, host: target.host, user: .init(id: 1, username: target.username),
            authored: [failed], enabled: [.pipelineFailure], reviewSLA: 7_200, automationScope: scope) { events.append($0) }
        #expect(events.count == 1)
    }

    @Test func existingFailedPipelineIsDiscoveredOnFirstPollAndNotReplayedAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "MergeWorkflowColdPipeline.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let executable = directory.appending(path: "glab")
        try write("""
        #!/bin/sh
        case "$2" in
          */pipelines/310/jobs*) printf '%s' '[{"id":42,"status":"failed","allow_failure":false,"failure_reason":"script_failure"}]' ;;
          *) exit 20 ;;
        esac
        """, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let glab = GlabService()
        glab.glabPath = executable
        let failed = try JSONDecoder().decode(GitLabMergeRequest.self,
            from: Data(mergeRequest(11, sha: String(repeating: "a", count: 40), pipeline: "failed").utf8))
        var events: [MergeWorkflowEvent] = []
        for _ in 0..<2 {
            let monitor = MergeWorkflowMonitor(defaults: defaults)
            await monitor.poll(glab: glab, host: "gitlab.example.test", user: .init(id: 1, username: "owner"),
                               authored: [failed], enabled: [.pipelineFailure], reviewSLA: 7_200) { events.append($0) }
        }
        #expect(events.count == 1)
        #expect(events.first?.pipelineID == 310)
        #expect(events.first?.jobID == 42)
    }

    @Test func staleCurrentHeadVerdictSchedulesOneReviewPerDiscussionRevision() async throws {
        let fixture = try FreshnessFixture(request: mergeRequest(13, sha: String(repeating: "a", count: 40), author: 2))
        defer { fixture.cleanUp() }
        var events: [MergeWorkflowEvent] = []
        let monitor = MergeWorkflowMonitor(defaults: fixture.defaults, verdictDirectory: fixture.verdictDirectory)
        await fixture.poll(monitor) { events.append($0) }
        #expect(events.count == 1)
        #expect(events.first?.kind == .reviewUpdate)
        #expect(events.first?.context.contains("discussion") == true)
        await fixture.poll(monitor) { events.append($0) }
        let restarted = MergeWorkflowMonitor(defaults: fixture.defaults, verdictDirectory: fixture.verdictDirectory)
        await fixture.poll(restarted) { events.append($0) }
        #expect(events.count == 1)

        // Resolution changes do not invalidate the verdict's text or start another run.
        try fixture.write("threads", fixture.liveThreads.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true"))
        await fixture.poll(restarted) { events.append($0) }
        #expect(events.count == 1)
        let edited = fixture.liveThreads.replacingOccurrences(of: "Other reviewer's condition", with: "Additional requirement")
        try fixture.write("threads", edited)
        await fixture.poll(restarted) { events.append($0) }
        #expect(events.count == 2)
        #expect(Set(events.map(\.identity)).count == 2)
        try fixture.recordVerdict(threads: edited)
        await fixture.poll(restarted) { events.append($0) }
        #expect(events.count == 2)
    }

    @Test(arguments: ["our-open-thread", "pending-draft"])
    func freshnessReviewWaitsForOurResolvedFindingsAndNoDrafts(_ blocker: String) async throws {
        let fixture = try FreshnessFixture(request: mergeRequest(13, sha: String(repeating: "a", count: 40), author: 2))
        defer { fixture.cleanUp() }
        if blocker == "our-open-thread" {
            try fixture.write("threads", fixture.liveThreads.replacingOccurrences(of: "\"resolved\":true", with: "\"resolved\":false"))
        } else {
            try fixture.write("drafts", #"[{"id":301,"author_id":1,"note":"Private finding"}]"#)
        }
        let monitor = MergeWorkflowMonitor(defaults: fixture.defaults, verdictDirectory: fixture.verdictDirectory)
        var events: [MergeWorkflowEvent] = []
        await fixture.poll(monitor) { events.append($0) }
        #expect(events.isEmpty)
        try fixture.write("threads", fixture.liveThreads)
        try fixture.write("drafts", "[]")
        await fixture.poll(monitor) { events.append($0) }
        #expect(events.count == 1)
    }

    @Test func publishingKnownOwnDraftsDoesNotTriggerARedundantFreshnessReview() async throws {
        let fixture = try FreshnessFixture(request: mergeRequest(13, sha: String(repeating: "a", count: 40), author: 2))
        defer { fixture.cleanUp() }
        let body = "My published review summary"
        let live = String(fixture.reviewedThreads.dropLast())
            + #",{"id":"published","notes":[{"id":200,"author":{"id":1},"system":false,"body":"My published review summary"}]}]"#
        try fixture.write("threads", live)
        ReviewVerdictStore.rememberDrafts([.init(id: 301, authorID: 1, note: body, discussionID: nil, position: nil)],
            host: "gitlab.example.test", projectID: 7, iid: 13, in: fixture.verdictDirectory)
        let monitor = MergeWorkflowMonitor(defaults: fixture.defaults, verdictDirectory: fixture.verdictDirectory)
        var events: [MergeWorkflowEvent] = []
        await fixture.poll(monitor) { events.append($0) }
        await fixture.poll(monitor) { events.append($0) }
        #expect(events.isEmpty)
    }

    @Test func freshReviewCoverageStartsANewDurableAttemptEpochWhenDiscussionBodiesCycle() async throws {
        let fixture = try FreshnessFixture(request: mergeRequest(13, sha: String(repeating: "a", count: 40), author: 2))
        defer { fixture.cleanUp() }
        let contextA = fixture.liveThreads.replacingOccurrences(of: "Other reviewer's condition", with: "Baseline condition")
        try fixture.recordVerdict(threads: contextA)
        var events: [MergeWorkflowEvent] = []
        let monitor = MergeWorkflowMonitor(defaults: fixture.defaults, verdictDirectory: fixture.verdictDirectory)
        await fixture.poll(monitor) { events.append($0) }
        #expect(events.count == 1)

        try fixture.recordVerdict(threads: fixture.liveThreads)
        await fixture.poll(monitor) { events.append($0) }
        await fixture.poll(monitor) { events.append($0) }
        #expect(events.count == 1)
        try fixture.write("threads", contextA)
        await fixture.poll(monitor) { events.append($0) }
        #expect(events.count == 2)

        // A fresh manual review of A must permit a later A→B refresh, even though
        // head, note IDs, bodies and receipt fingerprint now repeat the first case.
        try fixture.recordVerdict(threads: contextA)
        await fixture.poll(monitor) { events.append($0) }
        await fixture.poll(monitor) { events.append($0) }
        let restarted = MergeWorkflowMonitor(defaults: fixture.defaults, verdictDirectory: fixture.verdictDirectory)
        await fixture.poll(restarted) { events.append($0) }
        #expect(events.count == 2)
        try fixture.write("threads", fixture.liveThreads)
        await fixture.poll(restarted) { events.append($0) }
        #expect(events.count == 3)
        #expect(Set(events.map(\.identity)).count == 3)
        await fixture.poll(restarted) { events.append($0) }
        #expect(events.count == 3)
    }

    @Test func changedReviewReceiptsPermitDiscussionCyclesWithoutAnIntermediateCoveredPoll() async throws {
        let fixture = try FreshnessFixture(request: mergeRequest(13, sha: String(repeating: "a", count: 40), author: 2))
        defer { fixture.cleanUp() }
        let contextA = fixture.liveThreads.replacingOccurrences(of: "Other reviewer's condition", with: "Baseline condition")
        try fixture.recordVerdict(threads: contextA)
        let monitor = MergeWorkflowMonitor(defaults: fixture.defaults, verdictDirectory: fixture.verdictDirectory)
        var events: [MergeWorkflowEvent] = []
        await fixture.poll(monitor) { events.append($0) }
        #expect(events.count == 1)

        // Each worker saves a fresh verdict, but the next discussion edit wins
        // the race before any poll can observe that verdict covering live text.
        try fixture.recordVerdict(threads: fixture.liveThreads)
        try fixture.write("threads", contextA)
        await fixture.poll(monitor) { events.append($0) }
        #expect(events.count == 2)
        try fixture.recordVerdict(threads: contextA)
        try fixture.write("threads", fixture.liveThreads)
        let restarted = MergeWorkflowMonitor(defaults: fixture.defaults, verdictDirectory: fixture.verdictDirectory)
        await fixture.poll(restarted) { events.append($0) }
        #expect(events.count == 3)
        #expect(Set(events.map(\.identity)).count == 3)
        await fixture.poll(restarted) { events.append($0) }
        #expect(events.count == 3)
    }

    @MainActor private final class FreshnessFixture {
        let directory: URL
        let defaults: UserDefaults
        let suite = "ReviewFreshness.\(UUID())"
        let glab = GlabService()
        var verdictDirectory: URL { directory.appending(path: "verdicts") }
        let reviewedThreads = #"[{"id":"mine","notes":[{"id":100,"author":{"id":1},"system":false,"body":"Use a safe fallback","resolvable":true,"resolved":true},{"id":101,"author":{"id":2},"system":false,"body":"Fallback implemented"}]}]"#
        var liveThreads: String {
            String(reviewedThreads.dropLast()) + #",{"id":"other","notes":[{"id":200,"author":{"id":3},"system":false,"body":"Other reviewer's condition","resolvable":true,"resolved":false}]}]"#
        }

        init(request: String) throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defaults = try #require(UserDefaults(suiteName: suite))
            try write("request", request)
            try write("threads", liveThreads)
            try write("drafts", "[]")
            try recordVerdict(threads: reviewedThreads)
            let executable = directory.appending(path: "glab")
            try write("glab", """
                #!/bin/sh
                case "$2" in
                  *scope=all*reviewer_id=1*) printf '['; cat "${0%/*}/request"; printf ']'; exit ;;
                  */reviewers*) printf '%s' '[{"user":{"id":1},"state":"review_started"}]'; exit ;;
                  */discussions*) file=threads ;;
                  */draft_notes*) file=drafts ;;
                  */merge_requests/13) file=request ;;
                  *) exit 100 ;;
                esac
                cat "${0%/*}/$file"
                """)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            glab.glabPath = executable
        }

        func recordVerdict(threads: String) throws {
            let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(threads.utf8))
            let verdict = ReviewVerdict(version: 1, host: "gitlab.example.test", projectID: 7, iid: 13,
                headSHA: String(repeating: "a", count: 40), verdict: .noObjections,
                discussionFingerprint: ReviewVerdict.fingerprint(discussions), username: "owner", userID: 1)
            let file = ReviewVerdictStore.fileURL(host: "gitlab.example.test", projectID: 7, iid: 13, in: verdictDirectory)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(verdict).write(to: file)
        }

        func poll(_ monitor: MergeWorkflowMonitor, deliver: @MainActor (MergeWorkflowEvent) -> Void) async {
            await monitor.poll(glab: glab, host: "gitlab.example.test", user: .init(id: 1, username: "owner"),
                authored: [], enabled: [.reviewUpdate], reviewSLA: 3600, deliver: deliver)
        }
        func write(_ name: String, _ content: String) throws { try Data(content.utf8).write(to: directory.appending(path: name)) }
        func cleanUp() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    }

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
        let historical = #"{"id":"historical","notes":[{"id":90,"author":{"id":1},"system":false,"resolvable":true,"resolved":true},{"id":91,"author":{"id":2},"system":false,"resolvable":true,"resolved":true}]}"#
        let before = "[" + historical + #",{"id":"mine","notes":[{"id":100,"author":{"id":1},"system":false,"resolvable":true,"resolved":false}]}]"#
        let after = "[" + historical + #",{"id":"mine","notes":[{"id":100,"author":{"id":1},"system":false,"resolvable":true,"resolved":false},{"id":101,"author":{"id":2},"system":false}]}]"#
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
