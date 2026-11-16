import SwiftUI

/// Shown while a comment-origin change waits before letting automation publish drafts.
struct CommentOriginResumeBanner: View {
    let change: CommentOriginOverrideCenter.Change
    let onUndo: () -> Void
    let onContinue: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "hourglass").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(.MRDiscussions.mrDiscussionsOriginResume(change.resumingDrafts)).font(.callout.weight(.medium))
                if let resumesAt = change.resumesAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(.MRDiscussions.mrDiscussionsOriginResumeCountdown(
                            max(0, Int(resumesAt.timeIntervalSince(context.date).rounded(.up)))))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            Spacer(minLength: 8)
            Button(action: onContinue) { Text(.MRDiscussions.mrDiscussionsOriginContinueNow) }
            Button(action: onUndo) { Text(.MRDiscussions.mrDiscussionsOriginUndo) }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.25), lineWidth: 0.5) }
        .padding(.horizontal, 24).padding(.top, 8)
        .accessibilityElement(children: .contain)
    }
}
