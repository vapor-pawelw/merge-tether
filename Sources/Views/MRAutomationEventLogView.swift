import SwiftUI

struct MRAutomationEventLogView: View {
    let target: MRAutomationScope.Target?
    let monitor: TodoMonitorService
    let initiallyExpanded: Bool
    let initiallyExpandedJobID: UUID?
    @State private var expanded: Bool
    @State private var showAll: Bool

    init(target: MRAutomationScope.Target?, monitor: TodoMonitorService, initiallyExpanded: Bool = false,
         initiallyExpandedJobID: UUID? = nil) {
        self.target = target; self.monitor = monitor
        self.initiallyExpanded = initiallyExpanded; self.initiallyExpandedJobID = initiallyExpandedJobID
        _expanded = State(initialValue: initiallyExpanded || initiallyExpandedJobID != nil)
        _showAll = State(initialValue: initiallyExpandedJobID != nil)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                let history = target.map {
                    MRAutomationHistory(target: $0, handoffs: monitor.assistantHandoffs,
                        workflows: monitor.authoredMergeRequests.workflow.entries,
                        events: monitor.settings.automationEvents)
                }
                let entries = history?.entries ?? []
                VStack(alignment: .leading, spacing: 12) {
                    Text(.AutomationHistory.automationHistoryExplanation).font(.caption).foregroundStyle(.secondary)
                    if entries.isEmpty {
                        Text(.AutomationHistory.automationHistoryEmpty).foregroundStyle(.secondary)
                    }
                    ForEach(showAll ? entries : Array(entries.prefix(8))) { entry in
                        MRAutomationEventLogRow(entry: entry, runs: history?.associatedRuns(for: entry) ?? [],
                            monitor: monitor, initiallyExpandedJobID: initiallyExpandedJobID)
                            .id(entry.id)
                        Divider()
                    }
                    if entries.count > 8 {
                        Button { showAll.toggle() } label: {
                            Text(showAll ? .CommandCenter.commandCenterShowLess : .CommandCenter.commandCenterShowAll)
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(.top, 12)
            }
        } label: { Text(.AutomationHistory.automationHistoryTitle).font(.headline) }
        .onChange(of: initiallyExpanded) { _, value in if value { expanded = true } }
        .onChange(of: initiallyExpandedJobID) { _, id in
            if id != nil { expanded = true; showAll = true }
        }
    }
}

private struct MRAutomationEventLogRow: View {
    let entry: MRAutomationHistory.Entry
    let runs: [AssistantAutomationRunner.Handoff]
    let monitor: TodoMonitorService
    let initiallyExpandedJobID: UUID?
    @State private var detailsExpanded: Bool

    init(entry: MRAutomationHistory.Entry, runs: [AssistantAutomationRunner.Handoff], monitor: TodoMonitorService,
         initiallyExpandedJobID: UUID?) {
        self.entry = entry; self.runs = runs; self.monitor = monitor
        self.initiallyExpandedJobID = initiallyExpandedJobID
        if case .job(let job, _) = entry.source {
            _detailsExpanded = State(initialValue: job.id == initiallyExpandedJobID)
        } else { _detailsExpanded = State(initialValue: false) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).fontWeight(.medium)
                if entry.isAutomatic {
                    Image(systemName: "gearshape").font(.caption).foregroundStyle(.secondary)
                        .help(Text(.AutomationHistory.automationHistoryOriginAutomatic))
                        .accessibilityLabel(Text(.AutomationHistory.automationHistoryOriginAutomatic))
                }
                Spacer(minLength: 8)
                Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(stateLabel).foregroundStyle(needsAttention ? .orange : .secondary).font(.caption)
            if let summary {
                Text(verbatim: String(summary.prefix(280)))
                    .foregroundStyle(needsAttention ? .orange : .secondary)
                    .lineLimit(3).textSelection(.enabled)
            }
            DisclosureGroup(isExpanded: $detailsExpanded) {
                if detailsExpanded { details.padding(.top, 6) }
            } label: {
                if case .job = entry.source { Text(.AutomationHistory.automationHistoryViewRun) }
                else { Text(.AutomationHistory.automationHistoryDetails) }
            }
            .font(.caption)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: initiallyExpandedJobID) { _, id in
            if case .job(let job, _) = entry.source, job.id == id { detailsExpanded = true }
        }
    }

    private var title: LocalizedStringResource {
        switch entry.source {
        case .job(_, let attempt): .AutomationHistory.automationHistoryRun(attempt)
        case .workflow(let workflow): workflow.event.kind.displayLabel
        case .event(let event):
            switch event.action {
            case .retry: .AutomationHistory.automationHistoryActionRetry
            case .review: .AutomationHistory.automationHistoryActionReview
            case .followUp: .AutomationHistory.automationHistoryActionFollowUp
            case .draftReply: .AutomationHistory.automationHistoryActionDraftReply
            case .verification: .AutomationHistory.automationHistoryActionVerification
            case .pipeline: .Settings.settingsAutomationWorkflowPipelineFailure
            case .conflict: .AutomationHistory.automationHistoryActionConflict
            case .refresh: .AutomationHistory.automationHistoryActionRefresh
            }
        }
    }

    private var origin: LocalizedStringResource {
        switch entry.source {
        case .job(let job, _):
            if let manual = job.manual {
                manual ? .AutomationHistory.automationHistoryOriginManual : .AutomationHistory.automationHistoryOriginAutomatic
            } else { .AutomationHistory.automationHistoryOriginUnknown }
        case .workflow: .AutomationHistory.automationHistoryOriginAutomatic
        case .event(let event):
            event.origin == .manual ? .AutomationHistory.automationHistoryOriginManual : .AutomationHistory.automationHistoryOriginAutomatic
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
            case nil: .AssistantJobs.assistantJobsLegacy
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
        }
    }

    private var needsAttention: Bool {
        switch entry.source {
        case .job(let job, _): [.blocked, .failed, .interrupted].contains(job.execution?.state)
        case .workflow(let workflow): workflow.state == .failed
        case .event(let event): event.state == .failed || event.state == .blocked
        }
    }

    private var summary: String? {
        let text: String?
        switch entry.source {
        case .job(let job, _): text = job.execution?.attentionExplanation ?? job.execution?.error ?? job.execution?.summary
        case .workflow(let workflow): text = workflow.summary ?? workflow.event.context
        case .event(let event): text = event.message
        }
        return text.map(GlabService.redactWorkflowEvidence)
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch entry.source {
            case .job(let job, _):
                AssistantJobRow(handoff: job, monitor: monitor)
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
                raw(.AutomationHistory.automationHistorySummary, workflow.summary)
                raw(.AutomationHistory.automationHistoryRunID, workflow.assistantJobID?.uuidString)
            case .event(let event):
                raw(.AutomationHistory.automationHistoryEventID, event.id.uuidString)
                raw(.AutomationHistory.automationHistoryError, event.message)
                raw(.AutomationHistory.automationHistoryIntentID, event.intentID?.uuidString)
                raw(.AutomationHistory.automationHistoryRunID, event.jobID?.uuidString)
                raw(.AutomationHistory.automationHistoryPreviousRunID, event.relatedJobID?.uuidString)
            }
            raw(.AutomationHistory.automationHistoryOrigin, String(localized: origin))
            if case .job = entry.source {} else {
                ForEach(runs) { job in MRAutomationLinkedRun(job: job, monitor: monitor) }
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
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded { AssistantJobRow(handoff: job, monitor: monitor).padding(.top, 6) }
        } label: {
            HStack {
                Text(.AutomationHistory.automationHistoryViewRun)
                Text(job.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                    .foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}
