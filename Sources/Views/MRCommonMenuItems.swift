import Accessibility
import AppKit
import SwiftUI

struct GitLabRefreshButton: View {
    enum Placement { case labeled, header }

    let monitor: TodoMonitorService
    var itemID: MergeRequestAttentionMonitor.Item.ID? = nil
    var placement: Placement = .labeled
    var afterRefresh: @MainActor () async -> Void = {}
    @State private var refreshing = false

    var body: some View {
        Button {
            if itemID != nil, !confirmMRAction(.refreshFromGitLab, title: .MRFreshness.mrFreshnessRefresh) { return }
            refreshing = true
            Task {
                defer { refreshing = false }
                if let itemID { await monitor.refreshFromGitLab(for: itemID) }
                else {
                    monitor.markBoardIssueRefresh()
                    await monitor.forceRefreshFromGitLab()
                }
                await afterRefresh()
            }
        } label: {
            if placement == .header {
                BoardCardActionIcon(systemName: "arrow.clockwise")
                    .opacity(refreshing ? 0 : 1)
                    .overlay { if refreshing { ProgressView().controlSize(.mini) } }
            } else {
                Label { Text(.MRFreshness.mrFreshnessRefresh) } icon: {
                    if refreshing { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .disabled(refreshing)
        .mrActionHelp(.refreshFromGitLab)
    }
}

struct MergeRequestLinkCopyFeedback {
    private(set) var confirmationID: UUID?

    mutating func copy(_ url: URL, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        confirmationID = pasteboard.setString(url.absoluteString, forType: .string) ? UUID() : nil
    }

    mutating func dismiss(_ id: UUID) {
        if confirmationID == id { confirmationID = nil }
    }
}

struct CopyMergeRequestLinkButton: View {
    enum Placement { case menu, header }

    let url: URL
    var placement: Placement = .menu
    var onClick: () -> Void = {}
    @State private var feedback = MergeRequestLinkCopyFeedback()

    var body: some View {
        switch placement {
        case .menu:
            Button(action: copy) {
                Label { Text(.CommandCenter.commandCenterCopyLink) } icon: { Image(systemName: "link") }
            }
        case .header:
            Button(action: copy) {
                BoardCardActionIcon(systemName: "link")
                    .foregroundStyle(feedback.confirmationID == nil ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .boardHeaderControlHover()
            .help(Text(.CommandCenter.commandCenterCopyLink))
            .accessibilityLabel(Text(.CommandCenter.commandCenterCopyLink))
            .onDisappear { feedback = MergeRequestLinkCopyFeedback() }
            .overlay(alignment: .bottomTrailing) {
                if let id = feedback.confirmationID {
                    Text(.CommandCenter.commandCenterLinkCopied)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
                        .fixedSize()
                        .alignmentGuide(.bottom) { $0[.top] - 4 }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .task(id: id) {
                            do { try await Task.sleep(for: .seconds(2)) } catch { return }
                            feedback.dismiss(id)
                        }
                }
            }
        }
    }

    private func copy() {
        onClick()
        feedback.copy(url, to: .general)
        if feedback.confirmationID != nil {
            AccessibilityNotification.Announcement(String(localized: .CommandCenter.commandCenterLinkCopied)).post()
        }
    }
}

/// One set of MR actions for the board card and its Details header.
struct MRCommonMenuItems: View {
    let item: MergeRequestAttentionMonitor.Item
    let monitor: TodoMonitorService
    var boardPin: BoardCardPin? = nil
    var onRemove: (() -> Void)? = nil
    @State private var startingReview = false
    private var isFinished: Bool { MergeRequestFinishedState(item.mergeRequest) != nil }

    var body: some View {
        Link(destination: item.url) {
            Label { Text(.CommandCenter.commandCenterOpenGitLab) } icon: { Image(systemName: "arrow.up.right.square") }
        }
        CopyMergeRequestLinkButton(url: item.url)
        GitLabRefreshButton(monitor: monitor, itemID: item.id)
        if isFinished {
            Button { monitor.acknowledgeFinishedMergeRequest(item) } label: {
                Label { Text(.MRLifecycle.seen) } icon: { Image(systemName: "checkmark") }
            }
        } else {
            MarkMergeRequestReadyButton(item: item, monitor: monitor)
        }
        Divider()
        if !isFinished, monitor.canRunReview(for: item) {
            Button {
                guard let consent = confirmManualReview(for: item, monitor: monitor) else { return }
                startingReview = true
                Task {
                    defer { startingReview = false }
                    await monitor.runReview(for: item, confirmed: consent)
                }
            } label: {
                MRActionLabel(title: .CommandCenter.commandCenterReviewRun, cta: .runReview)
            }
            .disabled(startingReview || !monitor.canRunReview(for: item))
            .mrActionHelp(.runReview)
            Button {
                guard let consent = confirmManualReview(for: item, monitor: monitor) else { return }
                startingReview = true
                Task {
                    defer { startingReview = false }
                    await monitor.runReview(for: item, fromScratch: true, confirmed: consent, readOnly: true)
                }
            } label: {
                Label { Text(.AssistantJobs.assistantJobsReadOnlyReview) } icon: { Image(systemName: "magnifyingglass") }
            }
            .disabled(startingReview || !monitor.canRunReview(for: item))
        }
        AssistantContextMenu(mergeRequestURL: item.url, title: item.title,
                             settings: monitor.settings)
        if let boardPin {
            Divider()
            BoardPinButton(pin: boardPin, settings: monitor.settings, placement: .menu)
        }
        if !isFinished,
           let target = monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) {
            MRAutomationScopeMenu(monitor: monitor, target: target, projectPath: item.url.gitLabProjectPath,
                isDraft: item.section == .draftMergeRequests, showsLeadingDivider: boardPin == nil)
        }
        if !isFinished, let onRemove {
            Divider()
            Button(role: .destructive, action: onRemove) {
                Label { Text(.Board.boardRemove) } icon: { Image(systemName: "minus.circle") }
            }
        }
    }
}

struct AssistantJobPreflightNotice: View {
    let jobID: UUID
    let monitor: TodoMonitorService

    var body: some View {
        if let notice = monitor.assistantJobActionNotices[jobID] {
            Text(verbatim: notice).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
func confirmManualReview(for item: MergeRequestAttentionMonitor.Item,
                         monitor: TodoMonitorService) -> TodoMonitorService.ManualReviewConsent? {
    confirmManualReview(for: item.mergeRequest, monitor: monitor)
}

@MainActor
func confirmManualReview(for request: GitLabMergeRequest?, monitor: TodoMonitorService,
                         action: MRActionCTA = .runReview, title: LocalizedStringResource = .CommandCenter.commandCenterReviewRun,
                         variant: String? = nil) -> TodoMonitorService.ManualReviewConsent? {
    guard requireCodingAssistant(monitor) else { return nil }
    let consent = monitor.manualReviewConsent(for: request)
    let variant = [variant, consent.publicationMode.rawValue].compactMap { $0 }.joined(separator: ".")
    return confirmMRAction(action, title: title, variant: variant,
        detail: String(localized: consent.publicationMode.reviewConfirmation)) ? consent : nil
}

@MainActor
func confirmAssistantRetry(_ job: AssistantAutomationRunner.Handoff, for item: MergeRequestAttentionMonitor.Item,
                           monitor: TodoMonitorService, title: LocalizedStringResource) -> Bool {
    guard requireCodingAssistant(monitor, for: job.key.assistant) else { return false }
    let variant = job.retryConfirmationVariant
    if job.workflow == .review {
        return confirmManualReview(for: item.mergeRequest, monitor: monitor, action: .retryRun,
            title: title, variant: variant) != nil
    }
    return confirmMRAction(.retryRun, title: title, variant: variant)
}

@MainActor
func runConfirmedIntent(_ intent: MRTodoIntent, monitor: TodoMonitorService,
                        title: LocalizedStringResource? = nil) async {
    let title = title ?? BoardMRIntentActions.action(intent.kind)
    let variant = intent.state == .failed ? "retry" : nil
    if intent.kind == .review {
        guard let consent = confirmManualReview(for: monitor.reviewRequest(for: intent), monitor: monitor,
            title: title, variant: variant) else { return }
        await monitor.runMRTodoIntent(id: intent.id, confirmedReview: consent)
    } else {
        let action = MRActionCTA(intent: intent.kind) ?? .refreshFromGitLab
        guard confirmMRAction(action, title: title, variant: variant, monitor: monitor) else { return }
        await monitor.runMRTodoIntent(id: intent.id)
    }
}
