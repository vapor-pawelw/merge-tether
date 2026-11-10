import Foundation
import Testing
@testable import GitLabTodos

struct WorkflowExecutionProjectionTests {
    @Test(arguments: ["running", "mismatched", "unexecuted"])
    func indexedJobsKeepTheFirstDuplicateEvenWhenALaterJobWouldMatch(_ first: String) throws {
        // given
        let id = UUID()
        let stored = try entry(id)
        var original = job(id, state: .running, username: first == "mismatched" ? "other" : "author7")
        if first == "unexecuted" { original.execution = nil }
        let jobs = WorkflowExecutionProjection.JobIndex([original, job(id, state: .succeeded)])

        // when
        let visible = jobs.entry(stored)

        // then
        let expected: MergeWorkflowActivityState = first == "mismatched" ? .skipped
            : first == "unexecuted" ? .waitingForAssistant : .running
        #expect(visible.state == expected)
        #expect(!jobs.hasTerminalExecution(stored))
        #expect(stored.state == .waitingForAssistant && stored.summary == "Local admission")
    }

    @Test func indexedProjectionKeepsOrderFallbacksAndExactlyLinkedResultsAcrossLargeHistory() throws {
        // given
        let ids = (0..<512).map { _ in UUID() }
        let history = ids.reversed().map { job($0, state: .succeeded) }
        var stored = try (ids + [UUID()]).map { try entry($0) }
        stored.append(try entry(nil))
        let jobs = WorkflowExecutionProjection.JobIndex(history)

        // when
        let visible = stored.map(jobs.entry)

        // then
        #expect(visible.map(\.assistantJobID) == stored.map(\.assistantJobID))
        #expect(visible.prefix(ids.count).allSatisfy { $0.state == .completed && $0.summary == "Current run outcome" })
        #expect(visible[ids.count].state == .skipped)
        #expect(visible.last?.state == .waitingForAssistant && visible.last?.summary == "Local admission")
        #expect(stored.prefix(ids.count).allSatisfy(jobs.hasTerminalExecution))
        #expect(!jobs.hasTerminalExecution(stored[ids.count]))
        #expect(stored.allSatisfy { $0.state == .waitingForAssistant && $0.summary == "Local admission" })
    }

    @Test(arguments: [AssistantJobExecution.State.queued, .running, .succeeded, .blocked, .failed, .interrupted, .cancelled])
    func anExactlyLinkedExecutionIsProjectedWithoutChangingAdmission(_ state: AssistantJobExecution.State) throws {
        let id = UUID()
        let stored = try entry(id)
        let run = job(id, state: state)
        let visible = WorkflowExecutionProjection.entry(stored, job: run)
        let expected: MergeWorkflowActivityState = switch state {
        case .queued: .waitingForAssistant
        case .running: .running
        case .succeeded: .completed
        case .blocked, .failed, .interrupted: .failed
        case .cancelled: .skipped
        }
        #expect(visible.state == expected && visible.summary == "Current run outcome")
        #expect(stored.state == .waitingForAssistant && stored.summary == "Local admission")
        #expect(visible.assistantJobID == id)
        #expect(WorkflowExecutionProjection.hasTerminalExecution(stored, job: run) == !state.isActive)
    }

    @Test(arguments: ["missing", "id", "host", "username", "project", "iid"])
    func anUnavailableLinkNeverPresentsAnotherRunsSuccessOrOldSummary(_ mismatch: String) throws {
        let id = UUID()
        var stored = try entry(id)
        stored.state = .completed
        var run: AssistantAutomationRunner.Handoff? = job(mismatch == "id" ? UUID() : id, state: .succeeded,
            host: mismatch == "host" ? "other.test" : "gitlab.example.test",
            username: mismatch == "username" ? "other" : "author7",
            project: mismatch == "project" ? 99 : 34, iid: mismatch == "iid" ? 99 : 2)
        if mismatch == "missing" { run = nil }
        let visible = WorkflowExecutionProjection.entry(stored, job: run)
        #expect(visible.state == .skipped)
        #expect(visible.summary == String(localized: .AutomationHistory.automationHistoryExecutionUnavailable))
        #expect(visible.assistantJobID == id)
        #expect(!WorkflowExecutionProjection.hasTerminalExecution(stored, job: run))
    }

    @Test func unlinkedDesktopAndExistingUnexecutedHistoryKeepTheirLocalFallback() throws {
        let unlinked = try entry(nil)
        #expect(WorkflowExecutionProjection.entry(unlinked, job: nil).summary == "Local admission")
        let id = UUID()
        let stored = try entry(id)
        var historical = job(id, state: .running)
        historical.execution = nil
        let visible = WorkflowExecutionProjection.entry(stored, job: historical)
        #expect(visible.state == .waitingForAssistant && visible.summary == "Local admission")
        #expect(!WorkflowExecutionProjection.hasTerminalExecution(stored, job: historical))
    }

    @Test func cancellingARetiredReminderDoesNotReplaceItsLocalPreviewDecision() throws {
        let id = UUID()
        var stored = try entry(id, kind: .reviewWaiting)
        stored.state = .preview
        var retired = job(id, state: .cancelled)
        retired.workflow = .draftReply
        let visible = WorkflowExecutionProjection.entry(stored, job: retired)
        #expect(visible.state == .preview && visible.summary == "Local admission")
    }

    private func entry(_ id: UUID?, kind: MergeWorkflowTrigger = .blockerChange) throws -> MergeWorkflowActivityEntry {
        let request = try MRDependencyPresentationTests().request(2)
        return .init(id: "activity", event: .init(kind: kind, mergeRequest: request, identity: "activity", context: "Context"),
            createdAt: Date(timeIntervalSince1970: 0), host: "gitlab.example.test", user: .init(id: 7, username: "author7"),
            state: .waitingForAssistant, summary: "Local admission", assistantJobID: id)
    }
    private func job(_ id: UUID, state: AssistantJobExecution.State, host: String = "gitlab.example.test",
                     username: String = "author7", project: Int = 34, iid: Int = 2) -> AssistantAutomationRunner.Handoff {
        .init(id: id, key: .init(assistant: .codex, work: .init(host: host, projectID: project, iid: iid),
            username: username, workspace: "", access: .gitLabRead), title: "Work", prompt: "Work", createdAt: Date(),
            allowsPush: false, execution: .init(state: state, summary: "Current run outcome"))
    }
}
