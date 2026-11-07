import SwiftUI

struct MRAutomationEventLogView: View {
    let target: MRAutomationScope.Target?
    let monitor: TodoMonitorService
    @State private var expanded = false
    @State private var showAll = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                let entries = target.map {
                    MRAutomationHistory(target: $0, handoffs: monitor.assistantHandoffs,
                        workflows: monitor.authoredMergeRequests.workflow.entries,
                        events: monitor.settings.automationEvents).entries
                } ?? []
                VStack(alignment: .leading, spacing: 12) {
                    Text(.AutomationHistory.automationHistoryExplanation).font(.caption).foregroundStyle(.secondary)
                    if entries.isEmpty {
                        Text(.AutomationHistory.automationHistoryEmpty).foregroundStyle(.secondary)
                    }
                    ForEach(showAll ? entries : Array(entries.prefix(8))) { entry in
                        MRAutomationEventLogRow(entry: entry)
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
    }
}

private struct MRAutomationEventLogRow: View {
    let entry: MRAutomationHistory.Entry
    @State private var detailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).fontWeight(.medium)
                Spacer(minLength: 8)
                Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 8) {
                Text(stateLabel).foregroundStyle(needsAttention ? .orange : .secondary)
                Text(origin).foregroundStyle(.secondary)
            }
            .font(.caption)
            if let summary {
                Text(verbatim: String(summary.prefix(280)))
                    .foregroundStyle(needsAttention ? .orange : .secondary)
                    .lineLimit(3).textSelection(.enabled)
            }
            DisclosureGroup(isExpanded: $detailsExpanded) {
                if detailsExpanded { details.padding(.top, 6) }
            } label: { Text(.AutomationHistory.automationHistoryDetails) }
            .font(.caption)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                raw(.AutomationHistory.automationHistoryTask, job.title)
                raw(.AutomationHistory.automationHistoryRunID, job.id.uuidString)
                raw(.AutomationHistory.automationHistoryAgent, String(localized: job.key.assistant.displayName))
                timestamp(.AutomationHistory.automationHistoryQueuedAt, job.createdAt)
                if let execution = job.execution {
                    timestamp(.AutomationHistory.automationHistoryStartedAt, execution.startedAt)
                    timestamp(.AutomationHistory.automationHistoryFinishedAt, execution.finishedAt)
                    raw(.AutomationHistory.automationHistoryBlocker, execution.blocker)
                    raw(.AutomationHistory.automationHistoryError, execution.error)
                    raw(.AutomationHistory.automationHistorySummary, execution.summary)
                    raw(.AssistantJobs.assistantJobsTranscript, execution.output)
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
