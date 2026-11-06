import AppKit
import SwiftUI

enum CommandCenterMRDetailSection: Hashable {
    case overview, drafts, assistantRuns, feedback
}

struct CommandCenterMRDetail: View {
    let item: MergeRequestAttentionMonitor.Item
    let monitor: TodoMonitorService
    var initialSection: CommandCenterMRDetailSection = .overview
    @State private var isStartingReview = false

    private enum Anchor: Hashable { case overview, drafts, assistantRuns, feedbackStatus, comments, automation }

    private var initialAnchor: Anchor {
        switch initialSection {
        case .overview: .overview
        case .drafts: item.needsConfirmation ? .drafts : .overview
        case .assistantRuns: work != nil ? .assistantRuns : .overview
        case .feedback:
            item.canConfirmReReview ? .automation : item.authorFeedbackStatus != nil ? .feedbackStatus : .comments
        }
    }

    private var target: MRAutomationScope.Target? {
        monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url)
    }

    private var work: AssistantAutomationRunner.MergeRequestWork? {
        guard let target else { return nil }
        return .init(host: target.host, projectID: item.id.projectID, iid: item.id.iid)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header.id(Anchor.overview)
                    AuthorFeedbackView(item: item, monitor: monitor)
                        .id(Anchor.feedbackStatus)
                    if item.needsConfirmation {
                        ConfirmationQueueRow(
                            item: item, state: monitor.attention.confirmationStates[item.id],
                            onPublish: { Task { await monitor.attention.publishDrafts(of: item.id) } },
                            onApprove: { Task { await monitor.attention.approve(item.id) } },
                            onOpen: { NSWorkspace.shared.open(item.url) }, initiallyExpanded: initialSection == .drafts,
                            additionalActions: EmptyView()
                        )
                        .id(Anchor.drafts)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            if let request = item.mergeRequest {
                                metadata(.CommandCenter.commandCenterAuthor, value: "@\(request.author.username)")
                                metadata(.CommandCenter.commandCenterSource, value: request.sourceBranch)
                                metadata(.CommandCenter.commandCenterTarget, value: request.targetBranch)
                                if let sha = request.sha { metadata(.CommandCenter.commandCenterCommit, value: sha, monospaced: true) }
                                metadata(.CommandCenter.commandCenterMergeState,
                                         value: request.detailedMergeStatus?.replacingOccurrences(of: "_", with: " ")
                                            ?? String(localized: .CommandCenter.commandCenterStatusUnavailable))
                                metadata(.CommandCenter.commandCenterPipeline,
                                         value: request.headPipeline?.status.replacingOccurrences(of: "_", with: " ")
                                            ?? String(localized: .CommandCenter.commandCenterNoPipeline))
                            }
                            statusReasons
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    } label: { Text(.CommandCenter.commandCenterOverview).font(.headline) }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            BoardMRIntentActions(row: .init(item: item, latestJob: nil,
                                intents: monitor.mrTodoIntents(for: item)), monitor: monitor)
                            if !item.isAuthored && !monitor.mrTodoIntents(for: item).contains(where: { $0.kind == .review }) {
                                Button {
                                    isStartingReview = true
                                    Task {
                                        defer { isStartingReview = false }
                                        await monitor.runReview(for: item)
                                    }
                                } label: {
                                    Label {
                                        Text(isStartingReview ? .CommandCenter.commandCenterReviewStarting : .CommandCenter.commandCenterReviewRun)
                                    } icon: { Image(systemName: "text.magnifyingglass") }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isStartingReview || !monitor.canRunReview(for: item))
                                .help(Text(.CommandCenter.commandCenterReviewHelp))
                            }
                            if let error = monitor.assistantJobActionError {
                                Text(verbatim: error).font(.caption).foregroundStyle(.orange)
                            }
                            if let target {
                                MRAutomationScopeMenu(settings: monitor.settings, target: target,
                                                      projectPath: item.url.gitLabProjectPath)
                                if !item.isAuthored, monitor.settings.automation.autoApproveEnabled {
                                    Toggle(isOn: approvalBinding(target)) {
                                        Text(.CommandCenter.commandCenterAutoApprove)
                                    }
                                    .toggleStyle(.checkbox)
                                    .help(Text(.Menu.menuScopeAutoApproveHelp))
                                }
                            }
                            ReReviewControls(item: item, monitor: monitor.attention)
                            InboxAttentionActions(item: item, feedbackAction: monitor.attentionFeedbackAction(for: item),
                                onFeedback: { Task { await monitor.runAttentionFeedback(for: item) } },
                                onPipeline: { monitor.confirmPipelineHandoff(for: item.id) },
                                onMerge: { NSWorkspace.shared.open(item.url) })
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    } label: { Text(.CommandCenter.commandCenterAutomation).font(.headline) }
                    .id(Anchor.automation)

                    feedback.id(Anchor.comments)
                    if let work {
                        AssistantJobHistoryView(monitor: monitor, work: work, embedded: true)
                            .id(Anchor.assistantRuns)
                    }
                    workflowActivity
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background)
            .task(id: initialSection) {
                guard initialSection != .overview else { return }
                await Task.yield()
                proxy.scrollTo(initialAnchor, anchor: .top)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: "!\(item.id.iid)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Text(verbatim: item.url.gitLabProjectPath).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                AssistantContextMenu(mergeRequestURL: item.url, title: item.title,
                                     workspace: monitor.settings.automation.assistantWorkspace)
            }
            Text(verbatim: item.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            HStack {
                Label {
                    Text(item.section == .draftMergeRequests ? .CommandCenter.commandCenterStatusDraft
                         : item.needsAttention ? .CommandCenter.commandCenterStatusAttention
                         : .CommandCenter.commandCenterStatusMonitoring)
                } icon: {
                    Image(systemName: item.needsAttention ? "exclamationmark.circle" : "arrow.triangle.pull")
                }
                .font(.subheadline)
                .foregroundStyle(item.needsAttention ? .orange : .secondary)
                Spacer()
                Link(destination: item.url) {
                    Label { Text(.CommandCenter.commandCenterOpenGitLab) } icon: {
                        Image(systemName: "arrow.up.right.square")
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func metadata(_ label: LocalizedStringResource, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(verbatim: value)
                .font(monospaced ? .caption.monospaced() : .subheadline)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var statusReasons: some View {
        if item.hasConflict { reason(.Menu.menuAttentionConflict) }
        if item.failedPipeline { reason(.Menu.menuAttentionPipeline) }
        if item.needsChanges { reason(.Menu.menuAttentionChanges) }
        if item.needsDiscussion { reason(.Menu.menuAttentionDiscussions) }
        if item.reReviewRequested { reason(.Menu.menuScopeReReviewRequested) }
        if item.reReviewUnconfirmed { reason(.Menu.menuAttentionReReviewUnconfirmed) }
    }

    private func reason(_ text: LocalizedStringResource) -> some View {
        Label { Text(text) } icon: { Image(systemName: "exclamationmark.circle") }
            .font(.subheadline).foregroundStyle(.orange)
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.CommandCenter.commandCenterFeedback).font(.headline)
            if item.feedback.isEmpty {
                Text(.CommandCenter.commandCenterFeedbackEmpty).font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(Array(item.feedback.enumerated()), id: \.offset) { _, note in
                    VStack(alignment: .leading, spacing: 6) {
                        if let author = note.author?.username {
                            Text(verbatim: "@\(author)").font(.subheadline.weight(.medium))
                        }
                        Text(verbatim: note.body ?? "").font(.subheadline).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var workflowActivity: some View {
        let entries = monitor.authoredMergeRequests.workflow.entries.filter {
            $0.event.mergeRequest.projectID == item.id.projectID && $0.event.mergeRequest.iid == item.id.iid
                && $0.event.mergeRequest.webURL == item.url
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text(.CommandCenter.commandCenterActivity).font(.headline)
            if entries.isEmpty {
                Text(.CommandCenter.commandCenterActivityEmpty).font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(entries.prefix(10)) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(entry.event.kind.displayLabel).font(.subheadline.weight(.medium))
                            Spacer()
                            Text(entry.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(verbatim: entry.summary ?? entry.event.context)
                            .font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Divider()
                }
            }
        }
    }

    private func approvalBinding(_ target: MRAutomationScope.Target) -> Binding<Bool> {
        Binding(get: { !monitor.settings.autoApproveOptOuts.contains(target) }, set: { enabled in
            if enabled { monitor.settings.autoApproveOptOuts.remove(target) }
            else { monitor.settings.autoApproveOptOuts.insert(target) }
            monitor.settings.save()
        })
    }
}
