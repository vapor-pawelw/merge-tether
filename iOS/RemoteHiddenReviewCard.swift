import Accessibility
import MergeTetherRemote
import SwiftUI
import UIKit

struct RemoteHiddenReviewCard: View {
    let card: RemoteCard
    let model: RemotePhoneModel

    @State private var reviewToLeave: RemoteCard?

    private let opacity = RemoteCardView.dimmedOpacity
    private var restoreAction: RemoteAction? {
        let pendingCard = model.pendingActionCard.flatMap { $0.id == card.id ? $0 : nil }
        return (pendingCard ?? card).actions.first { $0.id == RemoteAction.restoreHiddenReviewID }
    }
    private var canEdit: Bool {
        card.actions.contains { $0.kind == .editCard } && model.state.canAct()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        MRCardMetadataLayout(referenceToTitleSpacing: 6, titleToPeopleSpacing: 6, alignsActionsAtTop: true) {
            reference.opacity(opacity)
            Text(verbatim: card.title)
                .font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .opacity(opacity)
            people
            actions.fixedSize()
            Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(opacity), in: shape)
        .overlay {
            shape.strokeBorder(.primary.opacity(0.14), lineWidth: 1)
                .opacity(opacity).allowsHitTesting(false)
        }
        .contentShape(shape)
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote.card.\(card.id)")
        .environment(\.gitLabPersonSourceURL, nil)
        .confirmationDialog(Text(.Board.boardReviewAssignmentLeave), isPresented: Binding(
            get: { reviewToLeave != nil }, set: { if !$0 { reviewToLeave = nil } }
        ), titleVisibility: .visible, presenting: reviewToLeave) { selected in
            Button(.Board.boardReviewAssignmentLeave, role: .destructive) {
                Task { await model.changeCard(.leaveReview, card: selected) }
            }
        } message: { _ in
            Text(.Board.boardReviewAssignmentLeaveHiddenExplanation)
        }
    }

    private var reference: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(verbatim: card.repositoryName)
                .fontWeight(.medium).lineLimit(1).truncationMode(.middle).foregroundStyle(.tint)
            if let iid = card.mergeRequestIID {
                Text(verbatim: "!\(iid)").monospacedDigit().fixedSize()
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private var people: some View {
        HStack(spacing: 0) {
            if let author = card.presentation, author.author != nil {
                PersonLabel(person: .init(name: author.author, username: author.authorUsername, avatarURL: author.authorAvatarURL))
                    .font(.caption).foregroundStyle(.secondary).opacity(opacity)
            } else {
                PersonAvatar(url: nil, size: 16)
                    .opacity(opacity)
                    .accessibilityLabel(Text(.RemoteDetail.remoteDetailUnknownAuthor))
            }
            Spacer(minLength: 12)
            RemoteApprovalProgressBadge(progress: card.approvals, assignedReviewerCount: card.presentation?.assignedReviewerCount,
                readOnly: true)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .menuOrder(.fixed)
            .accessibilityLabel(Text(.CommandCenter.commandCenterActions))
            .accessibilityIdentifier("remote.card.menu.\(card.id)")
            if let action = restoreAction {
                Button { restore(action) } label: {
                    RemoteActionProgressLabel(running: model.pendingActionCard?.id == card.id
                        && model.state.pending?.actionID == action.id) {
                        Text(.Board.boardReviewAssignmentRestore)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .modifier(RemoteActionAvailability(state: model.state))
                .accessibilityIdentifier("remote.review.restore.\(card.id)")
            }
        }
    }

    @ViewBuilder private var menuItems: some View {
        if let url = card.gitLabActionURL {
            Link(destination: url) {
                Label(.CommandCenter.commandCenterOpenGitLab, systemImage: "arrow.up.right.square")
            }
            Button {
                UIPasteboard.general.url = url
                AccessibilityNotification.Announcement(String(localized: .CommandCenter.commandCenterLinkCopied)).post()
            } label: {
                Label(.CommandCenter.commandCenterCopyLink, systemImage: "link")
            }
            Button {
                Task { await model.changeCard(.refresh, card: card) }
            } label: {
                Label(.MRFreshness.mrFreshnessRefresh, systemImage: "arrow.clockwise")
            }
            .disabled(!canEdit)
        }
        Section {
            if let action = restoreAction {
                Button { restore(action) } label: {
                    Label(.Board.boardReviewAssignmentRestore, systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.state.canAct())
            }
            if card.canLeaveReview == true {
                Button(role: .destructive) { reviewToLeave = card } label: {
                    Label(.Board.boardReviewAssignmentLeave, systemImage: "person.badge.minus")
                }
                .disabled(!canEdit)
            }
        }
    }

    private func restore(_ action: RemoteAction) {
        Task { await model.perform(card: card, action: action) }
    }
}
