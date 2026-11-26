import Foundation
import MergeTetherRemote

/// Resolves the same account-scoped MR that the Mac board presents.
@MainActor struct RemoteCardActionContext {
    let target: MRAutomationScope.Target
    let url: URL
    let item: MergeRequestAttentionMonitor.Item?
    private let request: GitLabMergeRequest?
    let isDraft: Bool
    let isFinished: Bool
    let isReviewed: Bool
    let monitor: TodoMonitorService

    init?(card: RemoteCard, board: MergeRequestBoardSnapshot, monitor: TodoMonitorService) {
        let row = (board.own + board.reviewed + board.otherMergeRequests).first {
            card.id == "mr:\($0.id.projectID):\($0.id.iid)"
        }
        let proposal = board.proposals.first { card.id == RemoteBoardAdapter.boardOrderCardID($0.target) }
        guard let url = row?.displayURL ?? proposal?.url, card.url == url,
              let projectID = row?.id.projectID ?? proposal?.target.projectID,
              let iid = row?.id.iid ?? proposal?.target.iid,
              let target = monitor.scopeTarget(projectID: projectID, iid: iid, url: url) else { return nil }
        let request = row?.displayRequest ?? proposal?.item?.mergeRequest
        self.target = target
        self.url = url
        self.item = row?.item ?? proposal?.item
        self.request = request
        self.isDraft = row?.isDraft ?? (request?.isDraft ?? false)
        self.isFinished = request.map { $0.state != .opened } ?? false
        self.isReviewed = board.reviewed.contains { $0.id.projectID == projectID && $0.id.iid == iid }
        self.monitor = monitor
    }

    private var pin: BoardCardPin? {
        .mergeRequest(host: target.host, username: target.username, projectID: target.projectID, iid: target.iid ?? 0)
    }

    // The paired phone presents the target and asks for confirmation before submitting an edit.
    private var editor: MRAutomationScopeEditor {
        .init(monitor: monitor, target: target, projectPath: url.gitLabProjectPath, isDraft: isDraft, confirm: { _ in true })
    }

    func project(_ card: inout RemoteCard) {
        card.pinned = pin.map { monitor.settings.boardPins.contains($0) }
        if !isFinished, editor.isAvailable { card.automation = automation(editor) }
        card.canRemoveFromBoard = canRemove ? true : nil
        card.canLeaveReview = reviewToLeave == nil ? nil : true
        card.canAcknowledgeFinished = item.flatMap { monitor.canAcknowledgeFinishedMergeRequest($0) ? true : nil }
        guard let token = try? RemoteDigest.token([
            try RemoteDigest.token(target), card.url?.absoluteString ?? "", card.head ?? "",
            card.contextRevision ?? "", String(isDraft), String(isFinished),
            try RemoteDigest.token(card.pinned), try RemoteDigest.token(card.automation),
            try RemoteDigest.token(card.canRemoveFromBoard), try RemoteDigest.token(card.canLeaveReview),
            try RemoteDigest.token(card.canAcknowledgeFinished)
        ]) else { return }
        card.actions.append(.init(id: RemoteCardChange.actionID, kind: .editCard, token: token))
    }

    func execute(_ change: RemoteCardChange) async -> RemoteCommandResult.Status {
        let settings = monitor.settings
        switch change {
        case .pin(let pinned):
            guard let pin else { return .changed }
            return settings.setBoardPin(pin, pinned: pinned) ? .completed : .failed
        case .refresh:
            guard let iid = target.iid else { return .changed }
            await monitor.refreshFromGitLab(for: .init(projectID: target.projectID, iid: iid))
            guard monitor.scopeTarget(projectID: target.projectID, iid: iid, url: url) == target else { return .changed }
            return monitor.lastError == nil && !monitor.attention.hasError && !monitor.authoredMergeRequests.hasError
                ? .completed : .failed
        case .remove:
            guard canRemove, let item else { return .changed }
            return monitor.removeReviewedMergeRequest(item) ? .completed : .failed
        case .leaveReview:
            guard let request = reviewToLeave else { return .changed }
            return await monitor.leaveReview(request, accountRevision: monitor.glab.accountRevision)
        case .acknowledge:
            guard let item, monitor.canAcknowledgeFinishedMergeRequest(item) else { return .changed }
            return monitor.acknowledgeFinishedMergeRequest(item) ? .completed : .failed
        case .openAssistant(let destination, let message):
            guard let local = AssistantContextLauncher.Destination(rawValue: destination.rawValue),
                  AssistantContextLauncher.availableDestinations().contains(local) else { return .changed }
            do {
                try await AssistantContextLauncher.open(local, context: .init(url: url),
                    workspace: settings.automation.assistantWorkspace, message: message ?? "")
                return .completed
            } catch { return .failed }
        case .automation, .rule, .repository:
            guard !isFinished, editor.isAvailable, settings.automaticActionsAllowed else { return .changed }
            return await editAutomation(change, editor: editor)
        }
    }

    private var canRemove: Bool {
        guard !isFinished, isReviewed, let request = item?.mergeRequest else { return false }
        return !monitor.settings.owns(request, username: target.username) && request.projectID == target.projectID
            && request.iid == target.iid && request.webURL == url
    }

    private var reviewToLeave: GitLabMergeRequest? {
        guard isReviewed, let request, request.webURL == url,
              monitor.scopeTarget(projectID: request.projectID, iid: request.iid, url: request.webURL) == target,
              monitor.selfReviewerRemoval(for: request) != nil else { return nil }
        return request
    }

    private func automation(_ editor: MRAutomationScopeEditor) -> RemoteCardAutomation {
        let summary = editor.summary
        let rules = editor.applicableActions.compactMap { action -> RemoteCardAutomation.Rule? in
            guard let id = RemoteCardAutomation.Rule.Kind(rawValue: action.rawValue),
                  let preference = RemoteCardAutomation.Preference(rawValue: editor.displayedPreference(for: action).rawValue)
            else { return nil }
            return .init(id: id, preference: preference, editable: editor.canChoose(action))
        }
        return .init(active: summary.active, source: String(localized: MRAutomationControl.sourceLabel(summary.source)),
            globallySuspended: editor.globallySuspended,
            preference: RemoteCardAutomation.Preference(rawValue: editor.choice.rawValue) ?? .default,
            customized: editor.choice != .default || editor.hasActionExceptions, rules: rules,
            repositoryEnabled: editor.repositoryDefaultActive, repositoryInherits: !editor.repositoryHasOverride)
    }

    private func editAutomation(_ change: RemoteCardChange, editor: MRAutomationScopeEditor) async -> RemoteCommandResult.Status {
        let saved: Bool
        switch change {
        case .automation(let preference):
            let choice: MRAutomationScope.Choice = switch preference {
            case .default: .inherit
            case .on: .forceOn
            case .off: .paused
            }
            saved = await editor.choose(choice)
        case .rule(let kind, let preference):
            guard let action = MRAutomaticAction(rawValue: kind.rawValue), editor.applicableActions.contains(action),
                  editor.canChoose(action), let choice = MRAutomationPreference(rawValue: preference.rawValue) else { return .changed }
            saved = await editor.choose(choice, for: action)
        case .repository(let preference):
            switch preference {
            case .default: saved = await editor.followGeneralScope()
            case .on, .off: saved = await editor.setRepositoryDefault(preference == .on)
            }
        default: return .changed
        }
        return saved ? .completed : .failed
    }
}
