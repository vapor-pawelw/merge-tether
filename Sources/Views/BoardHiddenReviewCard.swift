import SwiftUI

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
