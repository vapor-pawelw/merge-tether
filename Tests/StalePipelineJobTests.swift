import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct StalePipelineJobTests {
    private static let sha = String(repeating: "a", count: 40)
    private static let host = "gitlab.example.test"

    private func request(status: String = "success", pipelineID: Int = 10, head: String = Self.sha,
                         host: String = Self.host) throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: Data("""
            {"project_id":7,"iid":11,"author":{"id":1,"username":"me","name":"Me"},
             "title":"Fixture","web_url":"https://\(host)/team/repo/-/merge_requests/11",
             "state":"opened","draft":false,"sha":"\(head)","source_branch":"feature","target_branch":"main","labels":[],
             "head_pipeline":{"id":\(pipelineID),"project_id":7,"status":"\(status)","sha":"\(head)"}}
            """.utf8))
    }

    private func job(host: String = Self.host, createdAt: Date = Date(timeIntervalSince1970: 80)) -> AssistantAutomationRunner.Handoff {
        .init(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: host, projectID: 7, iid: 11), username: "me", workspace: "", access: .gitLabRead),
            title: "Pipeline diagnosis", prompt: "Diagnose the failed pipeline", createdAt: createdAt, allowsPush: false,
            pipelineReservation: .init(host: host, projectID: 7, mergeRequestIID: 11, pipelineID: 10),
            execution: .init(state: .blocked, blocker: "Pipeline 10 failed"), taskPrompt: "Diagnose pipeline 10",
            mergeRequestURL: URL(string: "https://\(host)/team/repo/-/merge_requests/11"), workflow: .followUp,
            expectedHeadSHA: Self.sha)
    }

    @Test(arguments: ["passed", "superseded", "running"], ["none", "draft", "feedback", "intent", "oldPipelineIntent", "independentFollowUp"])
    func freshPipelineEvidenceRetiresOnlyTheObsoleteStoppedRun(_ pipeline: String, _ independent: String) throws {
        let request = try request(status: pipeline == "passed" ? "success" : pipeline == "running" ? "running" : "failed",
                                  pipelineID: pipeline == "superseded" ? 11 : 10)
        let job = job()
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 7, iid: 11), title: request.title,
            url: request.webURL, mergeRequest: request, isAuthored: true)
        item.draftCount = independent == "draft" ? 1 : 0
        item.needsDiscussion = independent == "feedback"
        let hasIntent = ["intent", "oldPipelineIntent", "independentFollowUp"].contains(independent)
        let intents: [MRTodoIntent] = hasIntent ? [.init(id: UUID(),
            target: .init(host: Self.host, username: "me", projectID: 7, iid: 11),
            kind: independent == "oldPipelineIntent" ? .pipeline : independent == "independentFollowUp" ? .followUp : .conflict,
            state: .failed, todoIDs: [], noteIDs: [], sourceEvents: [], request: request, headSHA: Self.sha,
            jobID: independent == "intent" ? nil : job.id,
            error: "Verification failed", updatedAt: Date())] : []
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: job, intents: intents)

        #expect(!row.stoppedJobNeedsAttention)
        #expect(row.needsAttention == !["none", "oldPipelineIntent"].contains(independent))
        #expect(MRHumanAction(row: row, assistantReady: true)?.action != .retryRun)
        if independent == "draft" { #expect(MRHumanAction(row: row, assistantReady: true)?.action == .reviewDrafts) }
        #expect(row.latestJob?.execution?.state == .blocked)
        #expect(row.latestJob?.execution?.blocker == "Pipeline 10 failed")
    }

    @Test(arguments: ["matching", "differentHead", "differentSource", "differentTarget", "differentText", "wrongAuthor", "oldRead", "unknownRead"])
    func detailPipelineEvidenceEnrichesOnlyReconciliationWithoutReplacingCatalogOrDraftContext(_ scenario: String) throws {
        let detail = try request()
        var catalogPayload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(detail)) as? [String: Any])
        catalogPayload.removeValue(forKey: "head_pipeline")
        let catalog = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: catalogPayload))
        var evidencePayload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(detail)) as? [String: Any])
        switch scenario {
        case "differentHead": evidencePayload["sha"] = String(repeating: "b", count: 40)
        case "differentSource": evidencePayload["source_branch"] = "other-feature"
        case "differentTarget": evidencePayload["target_branch"] = "release"
        case "differentText": evidencePayload["description"] = "A different current contract"
        case "wrongAuthor": evidencePayload["author"] = ["id":2,"username":"other","name":"Other"]
        default: break
        }
        let evidence = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: evidencePayload))
        var job = job()
        job.execution?.finishedAt = Date(timeIntervalSince1970: 100)
        var catalogItem = MergeRequestAttentionMonitor.Item(id: .init(projectID: 7, iid: 11), title: catalog.title,
            url: catalog.webURL, mergeRequest: catalog, isAuthored: true)
        catalogItem.draftCount = 1
        catalogItem.drafts = try JSONDecoder().decode([GitLabDraftNote].self,
            from: Data(#"[{"id":123,"author_id":1,"note":"Keep my draft"}]"#.utf8))
        catalogItem.requiresDiscussionRecheck = true
        catalogItem.observedDiscussionFingerprint = "current-discussions"
        let board = MergeRequestBoardSnapshot(own: [catalogItem], reviewed: [], todos: [], attention: [catalogItem],
            handoffs: [job], host: Self.host, username: "me", pipelineEvidence: [evidence],
            pipelineEvidenceCheckedAt: scenario == "unknownRead" ? nil
                : Date(timeIntervalSince1970: scenario == "oldRead" ? 50 : 200))
        let row = try #require(board.own.first)
        #expect(row.stoppedJobNeedsAttention == (scenario != "matching"))
        if scenario == "matching" { #expect(MRHumanAction(row: row, assistantReady: true)?.action == .reviewDrafts) }
        #expect(row.item.mergeRequest?.headPipeline == nil)
        #expect(row.item.mergeRequest?.sourceBranch == "feature")
        #expect(row.item.drafts.map(\.id) == [123])
        #expect(row.item.requiresDiscussionRecheck && row.item.observedDiscussionFingerprint == "current-discussions")
        #expect(row.latestJob?.execution?.state == .blocked)
    }

    @Test func passedPipelineStopsBlockingAutomationWithoutRewritingItsHistoricalRun() throws {
        let job = job()
        let current = try request()
        #expect(!AssistantJobExecution.hasUnfinishedWork(in: [job], for: job.key.work, username: "me", currentRequest: current))
        #expect(AssistantJobExecution.hasUnfinishedWork(in: [job], for: job.key.work, username: "me"))
        #expect(job.execution?.state == .blocked && job.execution?.blocker == "Pipeline 10 failed")
    }

    @Test(arguments: ["failed", "unknown", "succeeded"])
    func retiringTheNewestPipelineKeepsTheLatestRemainingIndependentWork(_ remaining: String) throws {
        let retired = job(createdAt: Date(timeIntervalSince1970: 100))
        let older = AssistantAutomationRunner.Handoff(id: UUID(), key: retired.key, title: "Independent work", prompt: "Work",
            createdAt: Date(timeIntervalSince1970: 90), allowsPush: false,
            execution: remaining == "unknown" ? nil : .init(state: remaining == "failed" ? .failed : .succeeded))
        #expect(AssistantJobExecution.hasUnfinishedWork(in: [older, retired], for: retired.key.work, username: "me",
            currentRequest: try request()) == (remaining != "succeeded"))
        #expect(older.execution?.state == (remaining == "unknown" ? nil : remaining == "failed" ? .failed : .succeeded))
    }

    @Test func aRealLatestSuccessStillCompletesItsEarlierWork() throws {
        let retired = job(createdAt: Date(timeIntervalSince1970: 100))
        let older = AssistantAutomationRunner.Handoff(id: UUID(), key: retired.key, title: "Earlier work", prompt: "Work",
            createdAt: Date(timeIntervalSince1970: 90), allowsPush: false, execution: .init(state: .failed))
        let completed = AssistantAutomationRunner.Handoff(id: UUID(), key: retired.key, title: "Completed work", prompt: "Work",
            createdAt: Date(timeIntervalSince1970: 110), allowsPush: false, execution: .init(state: .succeeded))
        #expect(!AssistantJobExecution.hasUnfinishedWork(in: [older, retired, completed], for: retired.key.work, username: "me",
            currentRequest: try request()))
    }

    @Test(arguments: ["genericFailure", "active", "mixedFeedback", "wrongHead", "wrongAccount", "wrongHost", "newerGenericFailure"])
    func unfinishedWorkFilterPreservesIndependentFailuresAndCurrentAccountHeadGuards(_ scenario: String) throws {
        var historical = job()
        if scenario == "genericFailure" { historical.pipelineReservation = nil }
        if scenario == "active" { historical.execution?.state = .running }
        if scenario == "mixedFeedback" { historical.feedbackNoteIDs = [20] }
        var current = try request(head: scenario == "wrongHead" ? String(repeating: "b", count: 40) : Self.sha,
                                  host: scenario == "wrongHost" ? "another.example.test" : Self.host)
        if scenario == "wrongAccount" {
            var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
            payload["author"] = ["id":2,"username":"other","name":"Other"]
            current = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        var jobs = [historical]
        if scenario == "newerGenericFailure" {
            jobs.append(.init(id: UUID(), key: historical.key, title: "Independent work", prompt: "Work",
                createdAt: Date(timeIntervalSince1970: 90), allowsPush: false,
                execution: .init(state: .failed, blocker: "Independent verification failed")))
        }
        #expect(AssistantJobExecution.hasUnfinishedWork(in: jobs, for: historical.key.work, username: "me", currentRequest: current))
    }

    @Test(arguments: ["failed", "unknown", "differentHead", "differentHost", "mixedFeedback"])
    func missingOrUnrelatedEvidenceNeverRetiresAnUnfinishedRun(_ scenario: String) throws {
        var job = job()
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 7, iid: 11), title: "Fixture",
            url: URL(string: "https://\(Self.host)/team/repo/-/merge_requests/11")!, isAuthored: true)
        if scenario != "unknown" {
            item.mergeRequest = try request(status: scenario == "failed" ? "failed" : "success",
                head: scenario == "differentHead" ? String(repeating: "b", count: 40) : Self.sha,
                host: scenario == "differentHost" ? "another.example.test" : Self.host)
        }
        if scenario == "mixedFeedback" { job.feedbackNoteIDs = [20] }
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: job, intents: [])
        #expect(row.stoppedJobNeedsAttention && row.needsAttention)
    }

    @Test func failedPipelineRetryCarriesItsVerifiedHeadIntoTheReplacementAndPrompt() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "StalePipelineRetryBinding.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.full, for: .codex)
        let host = "gitlab-\(UUID().uuidString.lowercased()).example.test"
        let old = job(host: host)
        var retryReservation: ExistingPipelineWorkDetector.Key?
        defer {
            if let reservation = retryReservation {
                try? ExistingPipelineWorkDetector().finishHandoff(for: reservation)
            }
        }
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request(status: "failed", host: host))) as? [String: Any])
        payload["source_project_id"] = 7
        payload["target_project_id"] = 7
        var pipeline = try #require(payload["head_pipeline"] as? [String: Any])
        pipeline["ref"] = "feature"
        payload["head_pipeline"] = pipeline
        try JSONSerialization.data(withJSONObject: payload).write(to: directory.appending(path: "request.json"))
        try JSONSerialization.data(withJSONObject: pipeline).write(to: directory.appending(path: "pipeline.json"))
        let executable = directory.appending(path: "glab")
        try Data("""
            #!/bin/sh
            case "$*" in
              'config get host') printf '%s' '\(host)' ;;
              'auth status') printf '%s' 'Logged in to \(host) as me' >&2 ;;
              'api /user '*) printf '%s' '{"id":1,"username":"me"}' ;;
              'api /projects/7/merge_requests/11 '*) cat "${0%/*}/request.json" ;;
              'api /projects/7/pipelines/10 '*) cat "${0%/*}/pipeline.json" ;;
              'api /projects/7/repository/branches/feature '*) printf '%s' '{"commit":{"id":"\(Self.sha)"}}' ;;
              *) exit 20 ;;
            esac
            """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        settings.glabPath = executable
        settings.assistantHandoffs = [old]
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            .init(result: .init(status: .blocked, summary: "Fixture worker", blocker: "No external commands"), output: "")
        })
        defer { coordinator.prepareForTermination(settings: settings) }

        let replacement = try await AssistantAutomationRunner.retry(old.id, settings: settings, jobCoordinator: coordinator)
        retryReservation = replacement.pipelineReservation

        #expect(replacement.expectedHeadSHA == Self.sha)
        #expect(replacement.prompt.contains("Expected head: \(Self.sha)"))
        #expect(settings.assistantHandoffs.first(where: { $0.id == replacement.id })?.expectedHeadSHA == Self.sha)
        #expect(settings.assistantHandoffs.first(where: { $0.id == old.id })?.execution?.state == .blocked)
    }

    @Test(arguments: ["passed", "superseded", "running", "missingPipeline", "missingPipelineID", "manual", "changedHead", "olderPipeline"])
    func retryPreflightExplainsTheCurrentPipelineWithoutStartingAWorker(_ scenario: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "StalePipelineJobTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let host = "gitlab-\(UUID().uuidString.lowercased()).example.test"
        let request = try request(status: scenario == "passed" ? "success" : scenario == "running" ? "running"
            : scenario == "manual" ? "manual" : "failed",
            pipelineID: ["superseded", "changedHead"].contains(scenario) ? 11 : scenario == "olderPipeline" ? 9 : 10,
            head: scenario == "changedHead" ? String(repeating: "b", count: 40) : Self.sha, host: host)
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        if scenario == "missingPipeline" { payload.removeValue(forKey: "head_pipeline") }
        if scenario == "missingPipelineID", var pipeline = payload["head_pipeline"] as? [String: Any] {
            pipeline.removeValue(forKey: "id")
            payload["head_pipeline"] = pipeline
        }
        try JSONSerialization.data(withJSONObject: payload).write(to: directory.appending(path: "request.json"))
        let executable = directory.appending(path: "glab")
        try Data("""
            #!/bin/sh
            case "$*" in
              'config get host') printf '%s' '\(host)' ;;
              'auth status') printf '%s' 'Logged in to \(host) as me' >&2 ;;
              'api /user '*) printf '%s' '{"id":1,"username":"me"}' ;;
              'api /projects/7/merge_requests/11 '*) cat "${0%/*}/request.json" ;;
              *) exit 20 ;;
            esac
            """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        settings.glabPath = executable
        settings.assistantHandoffs = [job(host: host)]
        var ran = false
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            ran = true
            return .init(result: .init(status: .succeeded, summary: "Unexpected worker"), output: "")
        })
        do {
            _ = try await AssistantAutomationRunner.retry(settings.assistantHandoffs[0].id, settings: settings,
                                                          jobCoordinator: coordinator)
            Issue.record("A stale pipeline task must not start")
        } catch {
            if scenario == "changedHead" {
                #expect(error as? AssistantJobExecutor.ExecutionError == .headChanged)
            } else {
                let message = error.localizedDescription.lowercased()
                #expect(message.contains("pipeline"))
                let expected = scenario == "passed" ? "passed" : scenario == "superseded" ? "newer"
                    : scenario == "running" ? "running" : scenario == "manual" ? "manual" : "unknown"
                #expect(message.contains(expected))
                if scenario.hasPrefix("missing") || scenario == "olderPipeline" { #expect(!message.contains("newer")) }
                #expect(!message.contains("cli"))
            }
        }
        #expect(!ran && settings.assistantHandoffs.count == 1)
        #expect(settings.assistantHandoffs[0].execution?.state == .blocked)
    }
}
