import SwiftUI
import MergeTetherRemote

struct BoardApprovalProgressBadge: View {
    struct Action {
        let change: PersonalMRApproval
        let isBusy: Bool
        let perform: () async -> MergeRequestAttentionMonitor.PersonalApprovalResult
    }

    let progress: MergeRequestApprovalProgress?
    var reviewers: [Todo.Author]? = nil
    /// Signed-in username; the viewer's own approval is shown only on MRs they review.
    var viewerUsername: String? = nil
    var isOwnMergeRequest = true
    var showsOpenFindingsApproval: () -> Bool = { false }
    var personalAction: Action? = nil
    var reviewerEditing: ReviewerEditing? = nil
    var automaticApprovalOff = false
    var readOnly = false
    @State private var showingPeople = false
    @State private var pinned = false
    @State private var badgeHovered = false
    @State private var peopleHovered = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var pendingAction: Action?
    @State private var actionError: LocalizedStringResource?
    @State private var reviewerEditor = ReviewerEditorState()

    private var assignedReviewers: [ReviewerCandidate] {
        (reviewers ?? []).map { .init(id: $0.id, name: $0.name, username: $0.username) }
    }

    private var people: [MergeRequestApprovalProgress.Participant] {
        let reviewers = reviewers ?? []
        let all = progress?.participants(reviewers: reviewers) ?? MergeRequestApprovalProgress.participants(reviewers: reviewers)
        guard let viewer = viewerApproval?.author else { return all }
        return all.filter { $0.id == viewer.id } + all.filter { $0.id != viewer.id }
    }
    private var viewerApproval: MergeRequestApprovalProgress.ViewerApproval? {
        progress?.viewerApproval(username: viewerUsername, reviewers: reviewers ?? [], isOwnMergeRequest: isOwnMergeRequest)
    }
    private var assignedReviewerCount: Int? { MergeRequestApprovalProgress.assignedReviewerCount(reviewers) }
    private var satisfied: Bool {
        progress?.isSatisfied ?? false
    }
    var approvalColor: ApprovalBadgeColor {
        .init(received: progress?.completed ?? 0, required: progress?.required, isSatisfied: satisfied)
    }
    private var requiredApprovalPending: Bool {
        guard let progress, progress.required > 0 else { return false }
        return !(progress.requirementsSatisfied ?? (progress.completed >= progress.required))
    }
    private var approvalCount: Text {
        if let progress, progress.required == 0 { Text(.Board.boardApprovalsReceived(progress.completed)) }
        else if let progress { Text(.Board.boardApprovalsHelp(progress.completed, progress.required)) }
        else { Text(.Board.boardApprovalsUnavailable) }
    }
    private var label: Text {
        let count = assignedReviewerCount.map {
            approvalCount + Text(verbatim: " · ") + Text(.Board.boardApprovalsAssignedReviewers($0))
        } ?? approvalCount
        let explanation = requiredApprovalPending
            ? count + Text(verbatim: " · ") + Text(.Board.boardApprovalsRequiredPending)
            : count
        switch viewerApproval {
        case .approved: return Text(.Board.boardApprovalsViewerApproved) + Text(verbatim: " · ") + explanation
        case .noLongerCounts: return Text(.Board.boardApprovalsViewerNoLongerCounts) + Text(verbatim: " · ") + explanation
        case nil: return explanation
        }
    }

    var body: some View {
        if personalAction != nil || reviewerEditing != nil || automaticApprovalOff
            || (progress.map { $0.required > 0 || $0.completed > 0 } ?? true)
            || viewerApproval != nil || assignedReviewerCount != nil {
            if readOnly {
                badge
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label)
                    .help(label)
            } else {
                interactiveBadge
            }
        }
    }

    private var badge: some View {
        HStack(spacing: 4) {
            HStack(spacing: 3) {
                Image(systemName: satisfied ? "checkmark.seal.fill" : "checkmark.seal").accessibilityHidden(true)
                if let progress, progress.required == 0 {
                    Text(verbatim: "\(progress.completed)")
                } else if let progress {
                    Text(.Board.boardApprovalRatio(progress.completed, progress.required))
                } else { Text(.Board.boardApprovalsUnknownRatio) }
                if let assigned = assignedReviewerCount { Text(.Board.boardApprovalsReviewerCountBadge(assigned)) }
            }
            .font(.caption2).monospacedDigit().foregroundStyle(approvalColor)
            if let viewerApproval { viewerSegment(viewerApproval) }
        }
        .fixedSize()
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var interactiveBadge: some View {
        let confirmationTitle: LocalizedStringResource = pendingAction?.change == .remove
            ? .Board.boardApprovalsRemoveWarningTitle : .Board.boardApprovalsApprove
        return Button {
            hoverTask?.cancel()
            pinned = true
            showingPeople = true
        } label: {
            badge
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
        .onHover { badgeHovered = $0; updateHover() }
        .popover(isPresented: $showingPeople, arrowEdge: .bottom) {
            approvalPopover.onHover { peopleHovered = $0; updateHover() }
        }
        .onChange(of: showingPeople) { _, visible in
            if !visible {
                hoverTask?.cancel(); peopleHovered = false; pinned = false
                reviewerEditor.finishAdding()
            }
        }
        .onDisappear { hoverTask?.cancel(); showingPeople = false; reviewerEditor.finishAdding() }
        .modifier(ReviewerSaveErrorAlert(state: reviewerEditor, editorClosed: !showingPeople))
        .alert(Text(confirmationTitle), isPresented: Binding(
            get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }
        ), presenting: pendingAction) { action in
            Button(role: action.change == .remove ? .destructive : nil) {
                Task {
                    switch await action.perform() {
                    case .completed: break
                    case .changed: actionError = .Menu.menuConfirmChanged
                    case .failed, .uncertain: actionError = .Menu.menuConfirmFailed
                    }
                }
            } label: { Text(action.change.title) }
            Button(role: .cancel) { } label: { Text(.Remote.remoteCancel) }
        } message: { action in
            Text(action.change.confirmation)
        }
        .alert(Text(actionError ?? .Menu.menuConfirmFailed), isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) {
            Button(.Remote.remoteClose) { actionError = nil }
        }
    }

    /// Your avatar with a corner glyph, after a divider, so it reads as part of the approvals badge.
    private func viewerSegment(_ approval: MergeRequestApprovalProgress.ViewerApproval) -> some View {
        HStack(spacing: 4) {
            Divider().frame(height: 10)
            AvatarView(url: approval.author.avatarURL, size: 14)
                .overlay(alignment: .bottomTrailing) {
                    Group {
                        switch approval {
                        case .approved:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green)
                        case .noLongerCounts:
                            Image(systemName: "arrow.counterclockwise.circle.fill").foregroundStyle(.white, .orange)
                        }
                    }
                    .font(.system(size: 8, weight: .bold))
                    .background(Circle().fill(.background).padding(-1))
                    .offset(x: 3, y: 3)
                }
                .padding(.trailing, 2)
        }
        .accessibilityHidden(true)
    }

    private var approvalPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsOpenFindingsApproval() {
                Text(.AutomationHistory.automationHistoryActionApproval)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                Divider()
            }
            peopleList
            if personalAction != nil || reviewerEditing != nil || automaticApprovalOff {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if automaticApprovalOff {
                        Text(.Board.boardApprovalsAutomationOff)
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let action = personalAction {
                        Button(role: action.change == .remove ? .destructive : nil) {
                            hoverTask?.cancel()
                            pendingAction = action
                            showingPeople = false
                        } label: { Text(action.change.title) }
                        .disabled(action.isBusy)
                    }
                    if let reviewerEditing {
                        if reviewerEditor.isAdding {
                            ReviewerPicker(editing: reviewerEditing, assigned: assignedReviewers, state: reviewerEditor) {
                                showingPeople = false
                            }
                        } else {
                            Button(.Board.boardReviewersAdd) {
                                pinPeople()
                                reviewerEditor.startAdding(using: reviewerEditing)
                            }
                            .disabled(reviewerEditor.isSaving)
                        }
                    }
                    if reviewerEditor.isSaving { ProgressView().controlSize(.small) }
                    if let error = reviewerEditor.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(12)
            }
        }
        .frame(width: 280)
        .modifier(ReviewerRemovalConfirmation(state: reviewerEditor, editing: reviewerEditing))
    }

    private var peopleList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if progress == nil {
                    Text(.Board.boardApprovalsUnavailable).font(.caption).foregroundStyle(.secondary).padding(12)
                }
                if people.isEmpty {
                    Text(.Board.boardApprovalsNoPeople).font(.callout).padding(12)
                }
                ForEach(people) { person in
                    let assigned = reviewerEditing == nil ? nil : assignedReviewers.first { $0.id == person.id }
                    BoardApprovalPersonRow(reviewer: assigned, editor: reviewerEditor, onSelect: pinPeople) {
                        PersonLabel(person: person.author.person, avatarSize: 20)
                            .font(.callout).foregroundStyle(.primary)
                        if person.id == viewerApproval?.author.id {
                            Text(.Board.boardPersonViewerSuffix).font(.callout).foregroundStyle(.secondary)
                        }
                    } status: {
                        switch person.status {
                        case .approved:
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                                .accessibilityLabel(Text(.Board.boardApprovalsApproved))
                                .help(Text(.Board.boardApprovalsApproved))
                        case .previouslyApproved:
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.orange)
                                .accessibilityLabel(Text(.Board.boardApprovalsPreviouslyApproved))
                                .help(Text(.Board.boardApprovalsPreviouslyApproved))
                        case .commented:
                            Image(systemName: "bubble.left").foregroundStyle(.secondary)
                                .accessibilityLabel(Text(.Board.boardApprovalsCommented))
                                .help(Text(.Board.boardApprovalsCommented))
                        case .assigned: EmptyView()
                        }
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(360, CGFloat(max(people.count, 1)) * 36 + (progress == nil ? 48 : 0)))
    }

    private func pinPeople() {
        hoverTask?.cancel()
        pinned = true
    }

    private func updateHover() {
        hoverTask?.cancel()
        guard !pinned else { return }
        let hovering = badgeHovered || peopleHovered
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(hovering ? 250 : 180))
            guard !Task.isCancelled else { return }
            showingPeople = hovering
        }
    }
}

private struct BoardApprovalPersonRow<Name: View, Status: View>: View {
    let reviewer: ReviewerCandidate?
    let editor: ReviewerEditorState
    let onSelect: () -> Void
    @ViewBuilder let name: Name
    @ViewBuilder let status: Status
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            name
            if let reviewer {
                ReviewerRemovalButton(person: reviewer, revealed: hovered, state: editor, onSelect: onSelect)
            }
            Spacer(minLength: 18)
            status
        }
        .frame(minHeight: 36)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityElement(children: reviewer == nil ? .combine : .contain)
    }
}

struct BoardMRApprovalBadge: View {
    let row: MergeRequestBoardSnapshot.Row
    let monitor: TodoMonitorService

    var body: some View {
        let target = monitor.scopeTarget(projectID: row.id.projectID, iid: row.id.iid, url: row.displayURL)
        BoardApprovalProgressBadge(progress: row.displayItem.approvalProgress, reviewers: row.displayRequest?.reviewers,
            viewerUsername: monitor.glab.currentUsername,
            isOwnMergeRequest: row.isOwnMergeRequest(viewer: monitor.glab.currentUsername),
            showsOpenFindingsApproval: {
                guard let target, let head = row.displayRequest?.sha else { return false }
                return monitor.settings.hasAutomaticApprovalWithOpenFindings(for: target, head: head)
            }, personalAction: action, reviewerEditing: reviewerEditing,
            automaticApprovalOff: target.flatMap { monitor.settings.independentApprovalPreferences[$0] } == .off)
    }

    private var reviewerEditing: ReviewerEditing? {
        guard let request = row.displayRequest, monitor.canEditReviewers(of: request) else { return nil }
        let revision = monitor.glab.accountRevision
        return .init(search: { query in
            try await monitor.searchReviewers(of: request, query: query, accountRevision: revision)
        }, change: { changes in
            await monitor.changeReviewers(changes, of: request, accountRevision: revision)
        })
    }

    private var action: BoardApprovalProgressBadge.Action? {
        guard let request = row.displayRequest, let change = monitor.attention.personalApprovalAction(for: row) else { return nil }
        let revision = monitor.glab.accountRevision
        return .init(change: change, isBusy: monitor.attention.confirmationStates[row.id]?.isBusy == true) {
            await monitor.changePersonalApproval(change, for: request, accountRevision: revision)
        }
    }
}
