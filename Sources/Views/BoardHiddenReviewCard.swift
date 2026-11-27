import AppKit
import SwiftUI

struct BoardHiddenAssignmentCard: View {
    let review: HiddenReview
    let monitor: TodoMonitorService
    @Environment(\.colorScheme) private var colorScheme
    @State private var request: GitLabMergeRequest?
    @State private var approvals: MergeRequestApprovalProgress?
    @State private var metadataLoadID: UUID?

    var body: some View {
        let request = request ?? monitor.boardDisplayRequest(for: review.target, url: review.url)
        let repositoryPath = review.url.gitLabProjectPath
        let contentOpacity = 0.5
        let shape = RoundedRectangle(cornerRadius: 8)
        MRCardMetadataLayout(referenceToTitleSpacing: 6, titleToPeopleSpacing: 6, alignsActionsAtTop: true) {
            BoardMRReferenceLine(iid: review.target.iid, projectID: review.target.projectID,
                repositoryPath: repositoryPath, contentOpacity: contentOpacity)
            BoardCardTitle(title: request?.title ?? review.title, repositoryPath: repositoryPath, titleColor: .secondary)
                .opacity(contentOpacity)
            HStack(spacing: 0) {
                if let request {
                    BoardCardAuthor(author: request.author, assignees: request.displayAssignees, contentOpacity: contentOpacity)
                } else {
                    PersonAvatar(url: nil, size: 16)
                        .opacity(contentOpacity)
                        .help(Text(.ReviewingContext.reviewingAuthorUnknown))
                        .accessibilityLabel(Text(.ReviewingContext.reviewingAuthorUnknown))
                }
                Spacer(minLength: 16)
                BoardApprovalProgressBadge(progress: approvals, reviewers: request?.reviewers,
                    viewerUsername: review.target.username, isOwnMergeRequest: false, readOnly: true)
                    .fixedSize(horizontal: true, vertical: false)
            }
            HStack(spacing: 4) {
                BoardActionsMenu { menuItems }
                Button(.Board.boardReviewAssignmentRestore, action: restoreReview)
                    .buttonStyle(.bordered)
            }
            .fixedSize()
            Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            shape.fill(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(white: 0.95))
                .opacity(contentOpacity)
        }
        .overlay {
            shape.strokeBorder(.primary.opacity(0.14), lineWidth: 1)
                .opacity(contentOpacity)
                .allowsHitTesting(false)
        }
        .contentShape(shape)
        .contextMenu { menuItems }
        .environment(\.gitLabPersonSourceURL, nil)
        .task(id: monitor.glab.accountRevision) { await loadMetadata() }
    }

    @ViewBuilder private var menuItems: some View {
        OpenInGitLabMenuLink(url: review.url, showsOptionClick: false)
        CopyMergeRequestLinkButton(url: review.url)
        if let iid = review.target.iid {
            GitLabRefreshButton(monitor: monitor, itemID: .init(projectID: review.target.projectID, iid: iid)) {
                await loadMetadata()
            }
        }
        Divider()
        AssistantContextMenu(mergeRequestURL: review.url, settings: monitor.settings)
        Divider()
        Button(action: restoreReview) {
            Label(.Board.boardReviewAssignmentRestore, systemImage: "arrow.uturn.backward")
        }
        if let request {
            LeaveReviewButton(request: request, monitor: monitor,
                confirmationExplanation: .Board.boardReviewAssignmentLeaveHiddenExplanation, afterLeaving: loadMetadata)
        }
    }

    private func restoreReview() {
        monitor.restoreReviewedMergeRequests([review])
    }

    private func loadMetadata() async {
        let target = review.target
        let glab = monitor.glab
        let revision = glab.accountRevision
        guard let iid = target.iid, glab.resolvedHost == target.host, glab.currentUsername == target.username else { return }

        let loadID = UUID()
        let startedAt = Date()
        metadataLoadID = loadID
        request = nil
        approvals = nil
        async let liveRequest = try? glab.fetchMergeRequest(projectID: target.projectID, iid: iid, host: target.host)
        async let liveApprovals = try? glab.fetchMergeRequestApprovalProgress(projectID: target.projectID, iid: iid, host: target.host)
        let (loadedRequest, loadedApprovals) = await (liveRequest, liveApprovals)
        guard !Task.isCancelled, revision == glab.accountRevision, metadataLoadID == loadID else { return }
        if let loadedRequest, loadedRequest.webURL == review.url {
            request = loadedRequest
            monitor.recordHiddenReviewDisplay(review, request: loadedRequest, approvals: loadedApprovals,
                accountRevision: revision, readStartedAt: startedAt)
        }
        approvals = loadedApprovals
    }
}

struct BoardHiddenReviewCard: View {
    let review: HiddenReview
    let notice: HiddenReview.InboxNotification
    let monitor: TodoMonitorService
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Link(destination: review.url) {
                BoardCardTitle(title: review.title, repositoryPath: review.url.gitLabProjectPath)
            }
            .buttonStyle(.plain)
            .help(Text(.CommandCenter.commandCenterOpenGitLab))
            BoardMRReferenceLine(iid: review.target.iid, projectID: review.target.projectID,
                repositoryPath: review.url.gitLabProjectPath)

            Label(.ReviewIntake.reviewIntakeHiddenByVerifier, systemImage: "eye.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let reason = notice.reason, !reason.isEmpty {
                Text(verbatim: reason).font(.callout)
            }
            HStack {
                InboxUpdateTimestamp(date: notice.observedAt)
                Spacer()
                Button(.Board.boardReviewAssignmentRestore) {
                    monitor.restoreHiddenReviewNotification(id: notice.id)
                }
                .buttonStyle(.bordered)
                Button(.ReviewIntake.reviewIntakeMarkSeen) {
                    monitor.acknowledgeHiddenReviewNotifications([notice.id])
                }
                .buttonStyle(.borderedProminent)
                .help(Text(.ReviewIntake.reviewIntakeMarkSeenHelp))
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.12), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .gesture(TapGesture().modifiers(.option).onEnded { openURL(review.url) })
        .contextMenu { OpenInGitLabMenuLink(url: review.url) }
    }
}
