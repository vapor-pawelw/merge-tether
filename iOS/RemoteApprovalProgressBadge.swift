import SwiftUI
import MergeTetherRemote

struct RemoteApprovalProgressBadge: View {
    let progress: RemoteApprovalProgress?
    var people: [RemoteApprovalPerson]? = nil
    var viewerApprovalID: Int? = nil
    var assignedReviewerCount: Int? = nil
    var approvedWithOpenFindings = false
    var personalApproval: RemotePersonalApprovalControl? = nil
    var reviewerEditing: ReviewerEditing? = nil
    var automaticApprovalOff = false
    @State private var showingPeople = false
    @State private var reviewerEditor = ReviewerEditorState()

    private var details: RemoteApprovalDetails {
        .init(progress: progress, people: people ?? [], viewerApprovalID: viewerApprovalID)
    }
    private var viewer: RemoteApprovalPerson? { details.viewerApproval }
    private var received: Int { progress?.received ?? progress?.completed ?? 0 }
    private var complete: Bool {
        progress.map { received > 0 && ($0.requirementsSatisfied ?? ($0.required == 0 || received >= $0.required)) } ?? false
    }
    private var approvalColor: ApprovalBadgeColor {
        .init(received: received, required: progress?.required, isSatisfied: complete)
    }
    private var requiredApprovalPending: Bool {
        guard let progress, progress.required > 0 else { return false }
        return !(progress.requirementsSatisfied ?? (received >= progress.required))
    }
    private var explanation: Text {
        let count = if let progress, progress.required == 0 { Text(.Board.boardApprovalsReceived(received)) }
            else if let progress { Text(.Board.boardApprovalsHelp(received, progress.required)) }
            else { Text(.Board.boardApprovalsUnavailable) }
        let reviewerDetails = assignedReviewerCount.map {
            count + Text(verbatim: " · ") + Text(.Board.boardApprovalsAssignedReviewers($0))
        } ?? count
        let status = requiredApprovalPending
            ? reviewerDetails + Text(verbatim: " · ") + Text(.Board.boardApprovalsRequiredPending)
            : reviewerDetails
        if let viewer {
            return Text(viewer.status == .approved ? .Board.boardApprovalsViewerApproved : .Board.boardApprovalsViewerNoLongerCounts)
                + Text(verbatim: " · ") + status
        }
        return status
    }

    var body: some View {
        if personalApproval != nil || reviewerEditing != nil || automaticApprovalOff
            || (progress.map { $0.required > 0 || received > 0 } ?? true) || viewer != nil || assignedReviewerCount != nil {
            Button { showingPeople = true } label: {
                HStack(spacing: 4) {
                    HStack(spacing: 3) {
                        Image(systemName: complete ? "checkmark.seal.fill" : "checkmark.seal")
                        if let progress, progress.required == 0 { Text(verbatim: "\(received)") }
                        else if let progress { Text(.Board.boardApprovalRatio(received, progress.required)) }
                        else { Text(.Board.boardApprovalsUnknownRatio) }
                        if let assignedReviewerCount {
                            Text(.Board.boardApprovalsReviewerCountBadge(assignedReviewerCount))
                        }
                    }
                    .font(.caption2).monospacedDigit().foregroundStyle(approvalColor)
                    if let viewer {
                        Divider().frame(height: 10)
                        PersonAvatar(url: viewer.avatarURL, size: 16)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: viewer.status == .approved ? "checkmark.circle.fill" : "arrow.counterclockwise.circle.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white, viewer.status == .approved ? Color.green : .orange)
                                    .background(Circle().fill(.background).padding(-1))
                                    .offset(x: 3, y: 2)
                            }
                            .padding(.trailing, 2)
                    }
                }
                .fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(explanation)
            .accessibilityIdentifier("remote.approvals.badge")
            .popover(isPresented: $showingPeople) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(.RemoteDetail.remoteDetailPeople).font(.headline)
                        if approvedWithOpenFindings { RemoteOpenFindingsApprovalNote() }
                        if progress == nil || people == nil {
                            Text(.Board.boardApprovalsUnavailable).font(.callout).foregroundStyle(.secondary)
                        }
                        if people?.isEmpty == true, progress != nil {
                            Text(.Board.boardApprovalsNoPeople).font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(details.orderedPeople) { person in
                            RemoteApprovalPersonRow(person: person, isViewer: person.id == viewer?.id,
                                reviewerEditor: reviewerEditing == nil ? nil : reviewerEditor)
                        }
                        if automaticApprovalOff {
                            Text(.Board.boardApprovalsAutomationOff).font(.callout).foregroundStyle(.secondary)
                        }
                        if let personalApproval {
                            Divider()
                            personalApproval
                        }
                        if let reviewerEditing {
                            Divider()
                            RemoteReviewerEditorControls(editing: reviewerEditing, people: details.people, state: reviewerEditor)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                .frame(width: 300, height: popoverHeight)
                .presentationCompactAdaptation(.popover)
                .modifier(ReviewerRemovalConfirmation(state: reviewerEditor, editing: reviewerEditing))
                .accessibilityIdentifier("remote.approvals.people")
            }
            .onChange(of: showingPeople) { _, visible in
                if !visible {
                    reviewerEditor.isEditing = false
                    reviewerEditor.isAdding = false
                    reviewerEditor.error = nil
                }
            }
        }
    }

    private var popoverHeight: CGFloat {
        let peopleHeight = CGFloat(max(people?.count ?? 0, 1)) * 80
        return min(380, peopleHeight + 60 + (approvedWithOpenFindings ? 60 : 0)
            + (personalApproval != nil ? 56 : 0) + (automaticApprovalOff ? 56 : 0)
            + (reviewerEditing == nil ? 0 : reviewerEditor.isAdding ? 205 : 70))
    }
}

struct RemotePersonalApprovalControl: View {
    let card: RemoteCard
    let action: RemoteAction
    let model: RemotePhoneModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation: Confirmation?
    @State private var needsRefresh = false

    private struct Confirmation {
        let id: UUID
        let card: RemoteCard
        let action: RemoteAction
        let account: String
    }

    var body: some View {
        let confirmingKind = confirmation?.action.kind ?? action.kind
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Button(role: action.kind == .removeApproval ? .destructive : nil) {
                guard let board = model.state.board,
                      let latest = board.cards.first(where: { $0.hasSameActionContext(as: card) && $0.actions.contains(action) }),
                      let id = model.prepareApproval(card: latest, action: action) else { return }
                confirmation = .init(id: id, card: latest, action: action, account: board.account)
            } label: {
                Label(action.kind.title, systemImage: action.kind == .removeApproval ? "minus.circle" : "checkmark.seal")
                    .frame(minHeight: 44)
            }
            .disabled(!model.state.canAct(now: context.date))
            .accessibilityIdentifier("remote.approvals.personalAction")
        }
        .alert(Text(confirmingKind == .removeApproval ? .Board.boardApprovalsRemoveWarningTitle : confirmingKind.title), isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), presenting: confirmation) { request in
            Button(role: request.action.kind == .removeApproval ? .destructive : nil) {
                Task {
                    await model.perform(card: request.card, action: request.action, approvalID: request.id,
                        onApprovalConfirmed: { dismiss() })
                    if model.expiredApprovalCardID == request.card.id { needsRefresh = true }
                }
            } label: { Text(request.action.kind.title) }
            Button(.Remote.remoteCancel, role: .cancel) { model.cancelApproval() }
        } message: { request in
            Text(request.action.kind == .removeApproval ? .Board.boardApprovalsRemoveHelp : .Board.boardApprovalsApproveHelp)
                + Text(verbatim: "\n" + request.card.project + "\n" + request.card.title + "\n")
                + Text(.RemoteSecurity.remoteSecurityCommit) + Text(verbatim: " " + (request.card.head ?? "") + "\n")
                + Text(.RemoteSecurity.remoteSecurityAccount) + Text(verbatim: " " + request.account)
        }
        if needsRefresh {
            Button(.Remote.remoteRefresh) {
                Task { await model.reloadAfterApprovalExpiry(cardID: card.id); needsRefresh = false }
            }
        }
    }
}

extension RemoteCard {
    func reviewerEditing(model: RemotePhoneModel?) -> ReviewerEditing? {
        guard let model, let action = actions.first(where: { $0.kind == .editReviewers }) else { return nil }
        return .init(search: { query in
            try await model.searchReviewers(card: self, action: action, query: query)
        }, change: { change in
            await model.changeReviewer(change, card: self, action: action)
        })
    }

    func personalApprovalControl(model: RemotePhoneModel?) -> RemotePersonalApprovalControl? {
        guard let model, let action = actions.first(where: { $0.kind.isPersonalApproval }) else { return nil }
        return .init(card: self, action: action, model: model)
    }
}

struct CardControlHitArea: Shape {
    var anchor: UnitPoint = .center

    func path(in rect: CGRect) -> Path {
        let height = max(44, rect.height)
        let top = rect.minY - (height - rect.height) * anchor.y
        return Rectangle().path(in: CGRect(x: rect.minX, y: top, width: rect.width, height: height))
    }
}
