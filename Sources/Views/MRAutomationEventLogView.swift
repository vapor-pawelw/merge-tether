import SwiftUI

struct MRAutomationEventLogRow: View {
    let entry: MRAutomationHistory.Entry
    let runs: [AssistantAutomationRunner.Handoff]
    let monitor: TodoMonitorService
    let initiallyExpandedJobID: UUID?
    let readOnly: Bool
    @State private var detailsExpanded: Bool

    init(entry: MRAutomationHistory.Entry, runs: [AssistantAutomationRunner.Handoff], monitor: TodoMonitorService,
         initiallyExpandedJobID: UUID?, readOnly: Bool) {
        self.entry = entry; self.runs = runs; self.monitor = monitor
        self.initiallyExpandedJobID = initiallyExpandedJobID
        self.readOnly = readOnly
        if case .job(let job, _) = entry.source {
            _detailsExpanded = State(initialValue: job.id == initiallyExpandedJobID)
        } else { _detailsExpanded = State(initialValue: false) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $detailsExpanded) {
            if detailsExpanded { details.padding(.vertical, 5) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                MREventLogRowHeader(title: Text(title),
                    context: Text(stateLabel).foregroundColor(needsAttention ? .orange : .secondary), createdAt: entry.createdAt,
                    source: .mergeTether, isAutomatic: entry.isAutomatic)
                if case .workflow(let workflow) = entry.source,
                   let reason = ReviewLaunchReason.message(for: workflow.event.reviewUpdateReasons ?? []) {
                    Text(verbatim: reason).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .padding(.vertical, 3)
        .onChange(of: initiallyExpandedJobID) { _, id in
            if case .job(let job, _) = entry.source, job.id == id { detailsExpanded = true }
        }
    }

    private var title: LocalizedStringResource {
        switch entry.source {
        case .job(let job, let attempt):
            if job.taskIntent == .conflictResolution { return .AutomationHistory.automationHistoryActionConflict }
            if job.taskIntent == .pipelineDiagnosis || job.workflowEventKind == .pipelineFailure {
                return .Settings.settingsAutomationWorkflowPipelineFailure
            }
            switch job.workflow {
            case .review: return .AutomationHistory.automationHistoryActionReview
            case .followUp: return .AutomationHistory.automationHistoryActionFollowUp
            case .draftReply: return .AutomationHistory.automationHistoryActionDraftReply
            case nil: return .AutomationHistory.automationHistoryRun(attempt)
            }
        case .workflow(let workflow): return workflow.event.kind.displayLabel
        case .event(let event): return event.title
        case .gitLab: return .AutomationHistory.automationHistorySystemNote
        }
    }

    private var origin: LocalizedStringResource {
        switch entry.source {
        case .job(let job, _):
            if job.pipelineHandoffConfirmation != nil { return .AutomationHistory.automationHistoryOriginManual }
            if let manual = job.manual {
                return manual ? .AutomationHistory.automationHistoryOriginManual : .AutomationHistory.automationHistoryOriginAutomatic
            }
            return .AutomationHistory.automationHistoryOriginUnknown
        case .workflow: return .AutomationHistory.automationHistoryOriginAutomatic
        case .event(let event):
            return event.origin == .manual ? .AutomationHistory.automationHistoryOriginManual : .AutomationHistory.automationHistoryOriginAutomatic
        case .gitLab: return .AutomationHistory.automationHistoryOriginUnknown
        }
    }

    private var stateLabel: LocalizedStringResource {
        switch entry.source {
        case .job(let job, _):
            switch job.execution?.state {
            case .queued: .AssistantJobs.assistantJobsQueued
            case .running: .AssistantJobs.assistantJobsRunning
            case .succeeded: .AssistantJobs.assistantJobsSucceeded
            case .blocked: .AssistantJobs.assistantJobsBlocked
            case .failed: .AssistantJobs.assistantJobsFailed
            case .cancelled: .AssistantJobs.assistantJobsCancelled
            case .interrupted: .AssistantJobs.assistantJobsInterrupted
            case .feedbackResolved: .AssistantJobs.assistantJobsFeedbackResolved
            case nil: .AssistantJobs.assistantJobsStatusUnavailable
            }
        case .workflow(let workflow):
            switch workflow.state {
            case .preview: .Menu.menuWorkflowStatePreview
            case .notified: .Menu.menuWorkflowStateNotified
            case .awaitingPipelineHandoff: .Menu.menuWorkflowStateAwaitingPipelineHandoff
            case .alreadyRegistered: .Menu.menuWorkflowStateAlreadyRegistered
            case .queued: .Menu.menuWorkflowStateQueued
            case .running: .Menu.menuWorkflowStateRunning
            case .waitingForAssistant: .Menu.menuWorkflowStateWaitingForAssistant
            case .completed: .Menu.menuWorkflowStateCompleted
            case .failed: .Menu.menuWorkflowStateFailed
            case .skipped: .Menu.menuWorkflowStateSkipped
            }
        case .event(let event):
            switch event.state {
            case .requested: .AutomationHistory.automationHistoryStateRequested
            case .queued: .AssistantJobs.assistantJobsQueued
            case .failed: .AssistantJobs.assistantJobsFailed
            case .completed: .Menu.menuWorkflowStateCompleted
            case .blocked: .AssistantJobs.assistantJobsBlocked
            }
        case .gitLab: .AssistantJobs.assistantJobsStatusUnavailable
        }
    }

    private var needsAttention: Bool {
        switch entry.source {
        case .job(let job, _): [.blocked, .failed, .interrupted].contains(job.execution?.state)
        case .workflow(let workflow): workflow.state == .failed
        case .event(let event): event.state == .failed || event.state == .blocked
        case .gitLab: false
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch entry.source {
            case .job(let job, let attempt):
                Text(.AutomationHistory.automationHistoryRun(attempt)).fontWeight(.medium)
                AssistantJobRow(handoff: job, monitor: monitor, readOnly: readOnly)
                raw(.AutomationHistory.automationHistoryRunID, job.id.uuidString)
                timestamp(.AutomationHistory.automationHistoryQueuedAt, job.createdAt)
                if let execution = job.execution {
                    timestamp(.AutomationHistory.automationHistoryStartedAt, execution.startedAt)
                    timestamp(.AutomationHistory.automationHistoryFinishedAt, execution.finishedAt)
                }
                raw(.AutomationHistory.automationHistoryHead, job.expectedHeadSHA)
            case .workflow(let workflow):
                raw(.AutomationHistory.automationHistoryEventID, workflow.id)
                raw(.AutomationHistory.automationHistoryContext, workflow.event.context)
                raw(.AutomationHistory.automationHistorySummary, workflow.summary.map(AssistantJobExecutor.ExecutionError.displayMessage))
                raw(.AutomationHistory.automationHistoryRunID, workflow.assistantJobID?.uuidString)
            case .event(let event):
                raw(.AutomationHistory.automationHistoryEventID, event.id.uuidString)
                raw(.AutomationHistory.automationHistoryError, event.message.map(AssistantJobExecutor.ExecutionError.displayMessage))
                raw(.AutomationHistory.automationHistoryIntentID, event.intentID?.uuidString)
                raw(.AutomationHistory.automationHistoryRunID, event.jobID?.uuidString)
                raw(.AutomationHistory.automationHistoryPreviousRunID, event.relatedJobID?.uuidString)
            case .gitLab: EmptyView()
            }
            raw(.AutomationHistory.automationHistoryOrigin, String(localized: origin))
            if case .job = entry.source {} else {
                ForEach(runs) { job in MRAutomationLinkedRun(job: job, monitor: monitor, readOnly: readOnly) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func raw(_ label: LocalizedStringResource, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).fontWeight(.medium)
                Text(verbatim: GlabService.redactWorkflowEvidence(value))
                    .font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func timestamp(_ label: LocalizedStringResource, _ value: Date?) -> some View {
        if let value {
            HStack {
                Text(label).fontWeight(.medium)
                Text(value, format: .dateTime.year().month().day().hour().minute().second()).monospacedDigit()
            }
        }
    }
}

private struct MRAutomationLinkedRun: View {
    let job: AssistantAutomationRunner.Handoff
    let monitor: TodoMonitorService
    let readOnly: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded { AssistantJobRow(handoff: job, monitor: monitor, readOnly: readOnly).padding(.top, 6) }
        } label: {
            HStack {
                Text(.AutomationHistory.automationHistoryViewRun)
                Text(job.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                    .foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}
