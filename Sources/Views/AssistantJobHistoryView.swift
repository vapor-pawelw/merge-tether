import SwiftUI

struct AssistantJobHistoryView: View {
    let monitor: TodoMonitorService
    var work: AssistantAutomationRunner.MergeRequestWork? = nil
    var embedded = false

    private var handoffs: [AssistantAutomationRunner.Handoff] {
        monitor.assistantHandoffs.filter { work == nil || $0.key.work == work }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        if embedded {
            content
        } else {
            ScrollView { content.padding(20) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.AssistantJobs.assistantJobsTitle).font(.headline)
            Text(.AssistantJobs.assistantJobsExplanation).font(.caption).foregroundStyle(.secondary)
            if let error = monitor.assistantJobActionError {
                Text(verbatim: error).font(.caption).foregroundStyle(.orange)
            }
            if handoffs.isEmpty {
                Text(.AssistantJobs.assistantJobsEmpty).foregroundStyle(.secondary).padding(.vertical, 16)
            } else {
                ForEach(handoffs) { handoff in AssistantJobRow(handoff: handoff, monitor: monitor) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AssistantJobRow: View {
    let handoff: AssistantAutomationRunner.Handoff
    let monitor: TodoMonitorService
    var readOnly = false
    private var finished: Bool {
        let target = MRAutomationScope.Target(host: handoff.key.work.host, username: handoff.key.username,
            projectID: handoff.key.work.projectID, iid: handoff.key.work.iid)
        return readOnly || MergeRequestFinishedState(monitor.settings.mrLifecycleLedger.request(for: target)
            ?? monitor.currentRequest(for: handoff)) != nil
    }
    @State private var isRetrying = false
    @State private var promptExpanded = false
    @State private var transcriptExpanded = false
    @State private var retryError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: handoff.title).font(.subheadline.weight(.semibold))
                    HStack(spacing: 8) {
                        Text(handoff.key.assistant.displayName)
                        Text(handoff.createdAt, style: .relative)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if !finished, handoff.execution?.state.isActive == true { ProgressView().controlSize(.small) }
                Text(stateLabel).font(.caption.weight(.medium))
            }
            DisclosureGroup(isExpanded: $promptExpanded) {
                if promptExpanded {
                    Text(verbatim: GlabService.redactWorkflowEvidence(handoff.prompt))
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } label: { Text(.AssistantJobs.assistantJobsPrompt) }
            if let execution = handoff.execution {
                if execution.state == .interrupted || execution.state == .cancelled {
                    Text(.AssistantJobs.assistantJobsInterruptedHelp).font(.caption).foregroundStyle(.secondary)
                }
                if let blocker = execution.attentionExplanation {
                    Text(verbatim: blocker).foregroundStyle(.orange).textSelection(.enabled)
                }
                if let summary = execution.summary, summary != execution.attentionExplanation {
                    Text(verbatim: GlabService.redactWorkflowEvidence(summary)).textSelection(.enabled)
                }
                if let error = execution.error, error != execution.attentionExplanation {
                    Text(verbatim: GlabService.redactWorkflowEvidence(error)).foregroundStyle(.orange).textSelection(.enabled)
                }
                if let output = execution.output, !output.isEmpty {
                    DisclosureGroup(isExpanded: $transcriptExpanded) {
                        if transcriptExpanded {
                            Text(verbatim: GlabService.redactWorkflowEvidence(output)).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } label: { Text(.AssistantJobs.assistantJobsTranscript) }
                }
            } else {
                Text(.AssistantJobs.assistantJobsLegacyExplanation).font(.caption).foregroundStyle(.secondary)
            }
            if let retryError {
                Text(verbatim: GlabService.redactWorkflowEvidence(retryError)).foregroundStyle(.orange).textSelection(.enabled)
            }
            if !finished { AssistantJobPreflightNotice(jobID: handoff.id, monitor: monitor) }
            HStack {
                if let execution = handoff.execution {
                    if !finished, execution.state.isActive {
                        Button(role: .destructive) { monitor.cancelAssistantJob(handoff.id) } label: {
                            Text(.AssistantJobs.assistantJobsStop)
                        }
                    } else if PipelineJobReconciliation.isObsolete(handoff, request: monitor.currentRequest(for: handoff)) {
                        Text(.MRFreshness.mrFreshnessHistoricalRun).font(.caption).foregroundStyle(.secondary)
                    } else if !finished, execution.state != .succeeded && !handoff.isObsoleteReminder {
                        Button {
                            isRetrying = true
                            retryError = nil
                            Task {
                                defer { isRetrying = false }
                                await monitor.retryAssistantJob(handoff.id)
                                retryError = monitor.assistantJobActionError
                            }
                        } label: { Text(.AssistantJobs.assistantJobsRetry) }
                        .disabled(isRetrying || !monitor.availableAssistants.contains(handoff.key.assistant)
                                  || AssistantAutomationRunner.isWorking(on: handoff.key.work))
                    }
                    if let path = execution.workingDirectory {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        } label: { Text(.AssistantJobs.assistantJobsFiles) }
                    }
                }
                Button { AssistantAutomationRunner.copyPrompt(handoff.prompt) } label: {
                    Text(.AssistantJobs.assistantJobsCopy)
                }
            }
            .controlSize(.small)
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var stateLabel: LocalizedStringResource {
        guard let execution = handoff.execution else { return .AssistantJobs.assistantJobsLegacy }
        switch execution.state {
        case .queued: return .AssistantJobs.assistantJobsQueued
        case .running: return .AssistantJobs.assistantJobsRunning
        case .succeeded: return .AssistantJobs.assistantJobsSucceeded
        case .blocked: return .AssistantJobs.assistantJobsBlocked
        case .failed: return .AssistantJobs.assistantJobsFailed
        case .cancelled: return .AssistantJobs.assistantJobsCancelled
        case .interrupted: return .AssistantJobs.assistantJobsInterrupted
        }
    }
}
