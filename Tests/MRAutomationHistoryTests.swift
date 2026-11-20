import Foundation
import Testing
@testable import MergeTether

@MainActor
struct MRAutomationHistoryTests {
    private let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 7, iid: 13)
    private let start = Date(timeIntervalSince1970: 100)

    @Test func interleavesGitLabActivityWithLocalRunsAndKeepsRepliesNavigable() throws {
        let run = job(at: .init(timeIntervalSince1970: 120))
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data("""
        [{"id":"diff-thread","notes":[
            {"id":10,"system":false,"body":"Check this","created_at":"1970-01-01T00:01:40Z"},
            {"id":11,"system":false,"body":"Updated","created_at":"1970-01-01T00:02:20.000Z"}
        ]},{"id":"system-thread","notes":[
            {"id":12,"system":true,"body":"reset approvals from @alice","created_at":"1970-01-01T00:02:10Z"}
        ]},{"id":"duplicate","notes":[
            {"id":11,"system":false,"body":"Updated","created_at":"1970-01-01T00:02:20Z"}
        ]}]
        """.utf8))
        let gitLab = MRGitLabActivity.notes(in: discussions)
        let history = MRAutomationHistory(target: target, handoffs: [run], workflows: [], events: [], gitLab: gitLab)
        #expect(history.entries.map(\.id) == ["note/11", "note/12", "job/\(run.id)", "note/10"])
        #expect(history.entries.map(\.isAutomatic) == [false, false, false, false])
        #expect(gitLab.first { $0.id == "note/11" }?.discussionID == "diff-thread")
        #expect(gitLab.first { $0.id == "note/12" }?.discussionID == nil)
        #expect(gitLab.first { $0.id == "note/12" }?.body == "reset approvals from @alice")
    }

    @Test func fetchesPaginatedMRActivityAndPreservesOtherEventsWhenOneResourceFails() async throws {
        let gitLab = InMemoryGitLab()
        defer { gitLab.close() }
        var labelsUnavailable = false
        gitLab.handler = { request in
            #expect(request.method == "GET")
            if request.endpoint == "/user" { return InMemoryGitLab.output(#"{"id":1,"username":"me"}"#) }
            #expect(request.arguments.contains("--paginate"))
            let prefix = "/projects/7/merge_requests/13/"
            switch request.endpoint {
            case prefix + "resource_state_events?per_page=100":
                return InMemoryGitLab.output("""
                [{"id":1,"state":"opened","created_at":"2026-11-19T10:00:00Z"}]
                [{"id":2,"state":"merged","created_at":"2026-11-19T10:01:00Z"}]
                """)
            case prefix + "resource_label_events?per_page=100":
                if labelsUnavailable { return InMemoryGitLab.output(error: "HTTP 503", code: 1) }
                return InMemoryGitLab.output("""
                [{"id":1,"action":"add","label":{"name":"Ready"},"created_at":"2026-11-19T10:00:01Z"}]
                """)
            case prefix + "resource_milestone_events?per_page=100":
                return InMemoryGitLab.output(error: "HTTP 503", code: 1)
            default: return try gitLab.unexpected(request)
            }
        }
        let glab = gitLab.service(host: target.host, username: target.username)
        let request = MRDiscussionTarget(host: target.host, username: target.username, projectID: 7, iid: 13,
            url: try #require(URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/13")))
        let store = MRGitLabActivityStore()
        await store.refresh(target: request, glab: glab)
        let snapshot = store.snapshot(target: request, revision: glab.accountRevision)
        #expect(Set(snapshot.entries.map(\.id)) == ["state/1", "state/2", "label/1"])
        #expect(snapshot.hasError)
        labelsUnavailable = true
        await store.refresh(target: request, glab: glab)
        #expect(Set(store.snapshot(target: request, revision: glab.accountRevision).entries.map(\.id))
            == ["state/1", "state/2", "label/1"])
        glab.currentUsername = "other"
        #expect(store.snapshot(target: request, revision: glab.accountRevision).entries.isEmpty)
    }

    @Test func attributesOnlyMatchingCommentsAndKeepsUnmatchedApplicationReceipts() throws {
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data("""
        [{"id":"thread","notes":[
            {"id":10,"system":false,"body":"Manual","created_at":"1970-01-01T00:01:40Z"},
            {"id":11,"system":false,"body":"Automatic","created_at":"1970-01-01T00:01:41Z"},
            {"id":12,"system":false,"body":"External","created_at":"1970-01-01T00:01:42Z"}
        ]}]
        """.utf8))
        let activity = MRGitLabActivity.notes(in: discussions)
        let manual = MRAutomationEvent(id: UUID(), target: target, createdAt: start,
            action: .publication, origin: .manual, state: .completed, message: nil, publishedNoteID: 10)
        let automatic = MRAutomationEvent(id: UUID(), target: target, createdAt: start,
            action: .publication, origin: .automatic, state: .completed, message: nil, publishedNoteID: 11)
        let unmatched = MRAutomationEvent(id: UUID(), target: target, createdAt: start,
            action: .publication, origin: .manual, state: .completed, message: nil)
        let otherTarget = MRAutomationScope.Target(host: target.host, username: "other", projectID: 7, iid: 13)
        let otherAccount = MRAutomationEvent(id: UUID(), target: otherTarget, createdAt: start,
            action: .publication, origin: .automatic, state: .completed, message: nil, publishedNoteID: 12)
        let history = MRAutomationHistory(target: target, handoffs: [], workflows: [],
            events: [manual, automatic, unmatched, otherAccount], gitLab: activity)
        #expect(history.entries.count == 4)
        #expect(history.entries.contains { $0.id == "event/\(unmatched.id)" })
        #expect(history.entries.filter(\.isAutomatic).map(\.id) == ["note/11"])
        let appIDs = history.entries.compactMap { entry -> UUID? in
            guard case .gitLab(_, let appEvent) = entry.source else { return nil }
            return appEvent?.id
        }
        #expect(Set(appIDs) == [manual.id, automatic.id])
    }

    private func job(username: String = "me", host: String = "gitlab.example.test", projectID: Int = 7,
                     iid: Int = 13, at: Date, state: AssistantJobExecution.State = .failed,
                     finished: Date? = nil) -> AssistantAutomationRunner.Handoff {
        .init(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: host, projectID: projectID, iid: iid), username: username, workspace: "", access: .gitLabRead),
            title: "Follow up", prompt: "", createdAt: at, allowsPush: false,
            execution: .init(state: state, finishedAt: finished, error: "Process exited with status 1"))
    }

    private func workflow(username: String = "me", host: String = "gitlab.example.test") throws -> MergeWorkflowActivityEntry {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":7,"iid":13,"author":{"id":1,"username":"me","name":"Me"},"title":"Sample","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/13","state":"opened","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
        return .init(id: UUID().uuidString, event: .init(kind: .newDiscussion, mergeRequest: request,
            identity: "new-note", context: "Reviewer replied"), createdAt: start.addingTimeInterval(3),
            host: host, user: .init(id: 1, username: username), state: .failed)
    }

    @Test func chronologyIncludesApplicationFailureAfterSuccessfulWorkerAndKeepsAttemptNumbers() throws {
        let first = job(at: start)
        let second = job(at: start.addingTimeInterval(1), state: .succeeded, finished: start.addingTimeInterval(5))
        let event = MRAutomationEvent(id: UUID(), target: target, createdAt: start.addingTimeInterval(6),
            action: .followUp, origin: .automatic, state: .failed, message: "Fresh remote evidence is missing.", jobID: second.id)
        let workflow = try workflow()
        let history = MRAutomationHistory(target: target, handoffs: [second, first], workflows: [workflow], events: [event])
        #expect(history.entries.map(\.createdAt) == [event.createdAt, second.execution!.finishedAt!, workflow.createdAt, first.createdAt])
        let attempts = history.entries.compactMap { entry -> Int? in
            guard case .job(_, let attempt) = entry.source else { return nil }
            return attempt
        }
        #expect(attempts == [2, 1])
        guard case .event(let failure)? = history.entries.first?.source else { Issue.record("Missing application failure"); return }
        #expect(failure.message == "Fresh remote evidence is missing.")
        #expect(failure.jobID == second.id)
    }

    @Test func accountAndMergeRequestFenceApplyToEverySource() throws {
        let current = job(at: start)
        let excluded = [job(username: "other", at: start), job(host: "other.example.test", at: start),
                        job(projectID: 9, at: start), job(iid: 14, at: start)]
        let otherTarget = MRAutomationScope.Target(host: target.host, username: "other", projectID: 7, iid: 13)
        let event = MRAutomationEvent(id: UUID(), target: otherTarget, createdAt: start,
            action: .retry, origin: .manual, state: .failed, message: "Private diagnostic")
        let history = MRAutomationHistory(target: target, handoffs: excluded + [current],
            workflows: [try workflow(username: "other"), try workflow(host: "other.example.test")], events: [event])
        #expect(history.entries.count == 1)
        guard case .job(let visible, let attempt)? = history.entries.first?.source else { Issue.record("Missing current run"); return }
        #expect(visible.id == current.id)
        #expect(attempt == 1)
    }

    @Test func rejectedRetrySurvivesReloadWithoutAWorkerRunAndHistoryIsBounded() {
        let suite = "MRAutomationHistoryTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        for index in 0..<105 {
            settings.automationEvents.append(.init(id: UUID(), target: target,
                createdAt: start.addingTimeInterval(Double(index)), action: .retry, origin: .manual,
                state: .requested, message: nil))
        }
        settings.recordAutomationEvent(target: target, action: .retry, origin: .manual, state: .failed,
            message: "The selected account changed before retry.", now: start.addingTimeInterval(200))
        let reloaded = SettingsManager(defaults: defaults)
        #expect(reloaded.automationEvents.count == 100)
        #expect(reloaded.automationEvents.first?.message == "The selected account changed before retry.")
        #expect(reloaded.assistantHandoffs.isEmpty)
        for index in 0..<1_005 {
            let other = MRAutomationScope.Target(host: target.host, username: "me", projectID: index + 10, iid: 1)
            settings.automationEvents.append(.init(id: UUID(), target: other,
                createdAt: start.addingTimeInterval(Double(index)), action: .retry, origin: .manual,
                state: .requested, message: nil))
        }
        settings.recordAutomationEvent(target: target, action: .retry, origin: .manual, state: .failed,
            message: "Already running", now: start.addingTimeInterval(2_000))
        #expect(SettingsManager(defaults: defaults).automationEvents.count == 1_000)
    }

    @Test func linkedWorkflowAndRetryResolveOlderScopedRunsBeyondTheVisiblePrefix() throws {
        let old = job(at: start)
        let latest = job(at: start.addingTimeInterval(30))
        var linkedWorkflow = try workflow()
        linkedWorkflow.assistantJobID = old.id
        let retry = MRAutomationEvent(id: UUID(), target: target, createdAt: start.addingTimeInterval(31),
            action: .retry, origin: .manual, state: .queued, message: nil, jobID: latest.id, relatedJobID: old.id)
        let history = MRAutomationHistory(target: target,
            handoffs: [old, latest] + (1...12).map { job(at: start.addingTimeInterval(Double($0))) },
            workflows: [linkedWorkflow], events: [retry])
        let workflowEntry = try #require(history.entries.first { if case .workflow = $0.source { true } else { false } })
        let retryEntry = try #require(history.entries.first { if case .event = $0.source { true } else { false } })
        #expect(!history.entries.prefix(8).contains { $0.id == "job/\(old.id)" })
        #expect(history.associatedRuns(for: workflowEntry).map(\.id) == [old.id])
        #expect(history.associatedRuns(for: retryEntry).map(\.id) == [latest.id, old.id])
    }

    @Test func linkedIdentifiersCannotExposeAnotherAccountHostProjectOrMergeRequest() {
        let excluded = [job(username: "another", at: start), job(host: "other.example.test", at: start),
                        job(projectID: 99, at: start), job(iid: 99, at: start)]
        let events = excluded.map { MRAutomationEvent(id: UUID(), target: target, createdAt: start,
            action: .retry, origin: .manual, state: .failed, message: nil, jobID: $0.id, relatedJobID: $0.id) }
        let history = MRAutomationHistory(target: target, handoffs: excluded, workflows: [], events: events)
        #expect(history.entries.count == excluded.count)
        #expect(history.entries.allSatisfy { history.associatedRuns(for: $0).isEmpty })
    }

    @Test func automatedBadgeReflectsOnlyKnownLaunchOrRecordedOrigin() throws {
        var automaticJob = job(at: start)
        automaticJob.manual = false
        var manualJob = job(at: start.addingTimeInterval(1))
        manualJob.manual = true
        let unknownJob = job(at: start.addingTimeInterval(2))
        var confirmedPipelineJob = job(at: start.addingTimeInterval(3))
        confirmedPipelineJob.manual = false
        confirmedPipelineJob.pipelineHandoffConfirmation = .init(target: target, pipelineID: 14,
            headSHA: String(repeating: "a", count: 40), reservationID: UUID())
        let automaticEvent = MRAutomationEvent(id: UUID(), target: target, createdAt: start,
            action: .followUp, origin: .automatic, state: .completed, message: nil)
        let manualEvent = MRAutomationEvent(id: UUID(), target: target, createdAt: start,
            action: .retry, origin: .manual, state: .queued, message: nil)
        let workflow = try workflow()
        let history = MRAutomationHistory(target: target,
            handoffs: [automaticJob, manualJob, unknownJob, confirmedPipelineJob],
            workflows: [workflow], events: [automaticEvent, manualEvent])
        let automaticIDs = Set(history.entries.filter(\.isAutomatic).map(\.id))
        #expect(automaticIDs == ["job/\(automaticJob.id)", "event/\(automaticEvent.id)", "workflow/\(workflow.id)"])
    }
}
