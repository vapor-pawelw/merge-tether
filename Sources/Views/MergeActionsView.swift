import SwiftUI

/// Status and results precede the shared action row on both cards and Details.
struct MergeActionsView<AdditionalActions: View>: View {
    let item: MergeRequestAttentionMonitor.Item
    let monitor: TodoMonitorService
    var evidenceMatchesCatalogContext = true
    var actionsBlocked = false
    @ViewBuilder var additionalActions: () -> AdditionalActions
    @State private var showingConfirmation = false
    @State private var working = false
    @State private var result: MergeSubmissionState?
    @State private var prepared: ManualDiscussionResolution.Prepared?
    @State private var resolutionMessage: String?

    private var status: AuthoredMergeRequestStatus? {
        guard evidenceMatchesCatalogContext, monitor.authoredMergeRequests.hasSyncedCurrentCatalog,
              let request = item.mergeRequest, request.webURL == item.url else { return nil }
        return monitor.authoredMergeRequests.requests.first { $0.matchesCurrentRequest(request) }
    }
    private var owned: Bool {
        item.isAuthored && item.mergeRequest?.state == "opened" && item.mergeRequest?.author.username == monitor.glab.currentUsername
    }
    private var state: MergeSubmissionState { result ?? status?.submissionState ?? .none }
    private var hasDiscussionBlock: Bool { status?.blockers.contains(.discussions) == true || item.mergeRequest?.blockingDiscussionsResolved == false }
    private var needsGitLabCheck: Bool { state == .uncertain || state == .changed || status?.action == nil && status != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if owned {
                if let conflict = status?.request.mergeTrainConflict {
                    Link(destination: conflict.noteURL) {
                        Label { Text(.MergeActions.mergeActionsTrainRebaseConflict) } icon: { Image(systemName: "arrow.triangle.branch") }
                    }.foregroundStyle(.orange)
                } else if status?.request.mergeTrainEvidenceUnavailable == true {
                    Text(.MergeActions.mergeActionsTrainEvidenceUnavailable).foregroundStyle(.orange)
                } else if let title = state.title {
                    Label { Text(title) } icon: { Image(systemName: state.isDelegated ? "clock" : "exclamationmark.circle") }
                        .foregroundStyle(state.isDelegated ? Color.secondary : .orange)
                } else if let status, status.action == nil {
                    Text(.MergeActions.mergeActionsUnavailable).foregroundStyle(.secondary)
                }
                if hasDiscussionBlock { Text(.Menu.menuAuthoredBlockerDiscussions).foregroundStyle(.orange) }
                if let resolutionMessage { Text(verbatim: resolutionMessage).foregroundStyle(.secondary).textSelection(.enabled) }
                if result == .changed, status?.request.mergeTrainConflict == nil { Text(.MergeActions.mergeActionsBlocked).foregroundStyle(.orange) }
            }
            HStack(spacing: 8) {
                if owned {
                    if evidenceMatchesCatalogContext, state == .none, let status, item.canOfferManualMerge(using: status), let action = status.action {
                        Button { prepared = nil; showingConfirmation = true } label: {
                            if working { ProgressView().controlSize(.small) }
                            else { Text(action.title) }
                        }
                        .buttonStyle(.borderedProminent).disabled(actionsBlocked || working)
                    }
                    if hasDiscussionBlock {
                        Button { prepareResolution() } label: {
                            if working { ProgressView().controlSize(.small) }
                            else { Text(.MergeActions.mergeActionsResolveAll) }
                        }
                        .buttonStyle(.bordered).disabled(working || actionsBlocked)
                    }
                    if needsGitLabCheck { Link(destination: item.url) { Text(.MergeActions.mergeActionsCheckGitLab) } }
                }
                additionalActions()
            }
        }
        .font(.caption)
        .alert(Text(prepared == nil ? .MergeActions.mergeActionsConfirmMerge : .MergeActions.mergeActionsResolveTitle),
               isPresented: $showingConfirmation) {
            if let prepared {
                if !prepared.plan.eligibleIDs.isEmpty {
                    Button { resolve(prepared) } label: { Text(.MergeActions.mergeActionsResolveConfirm) }
                }
            } else {
                Button { merge() } label: { Text(status?.action?.title ?? .MergeActions.mergeActionsMergeNow) }
            }
            Button(role: .cancel) { prepared = nil } label: { Text(.MergeActions.mergeActionsCancel) }
        } message: {
            if let prepared {
                Text(.MergeActions.mergeActionsResolvePreview(prepared.plan.eligibleIDs.count, prepared.plan.heldIDs.count))
                + Text(verbatim: "\n\n" + prepared.plan.confirmationDetails + "\n\n")
                + Text(.MergeActions.mergeActionsResolveHelp)
            } else { Text(.MergeActions.mergeActionsConfirmHelp) }
        }
        .onChange(of: item.mergeRequest?.sha) { _, _ in result = nil; prepared = nil; showingConfirmation = false }
        .onChange(of: monitor.authoredMergeRequests.lastRefresh) { _, _ in result = nil }
    }

    private func merge() {
        guard let request = item.mergeRequest, !working else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            result = await monitor.authoredMergeRequests.mergeManually(request)
            if result == .merged || result?.isDelegated == true { await monitor.refreshNow() }
        }
    }
    private func prepareResolution() {
        guard let request = item.mergeRequest else { return }
        working = true; resolutionMessage = nil
        Task { @MainActor in
            defer { working = false }
            do {
                prepared = try await ManualDiscussionResolution.prepare(request, monitor: monitor)
                showingConfirmation = true
            } catch { resolutionMessage = String(localized: .MergeActions.mergeActionsFailed) }
        }
    }
    private func resolve(_ confirmed: ManualDiscussionResolution.Prepared) {
        prepared = nil; working = true
        Task { @MainActor in
            defer { working = false }
            let result = await ManualDiscussionResolution.resolve(confirmed, glab: monitor.glab, settings: monitor.settings)
            resolutionMessage = String(localized: .MergeActions.mergeActionsResolveResult(result.resolved, result.selected, result.held))
            await monitor.refreshNow()
        }
    }
}

extension MergeActionsView where AdditionalActions == EmptyView {
    init(item: MergeRequestAttentionMonitor.Item, monitor: TodoMonitorService,
         evidenceMatchesCatalogContext: Bool = true, actionsBlocked: Bool = false) {
        self.item = item; self.monitor = monitor; self.actionsBlocked = actionsBlocked
        self.evidenceMatchesCatalogContext = evidenceMatchesCatalogContext
        self.additionalActions = { EmptyView() }
    }
}
