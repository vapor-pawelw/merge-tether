import SwiftUI

struct IncomingReviewFilterNoticeView: View {
    let notice: IncomingReviewFilterNotice

    var body: some View {
        Label {
            Text(notice.localizedMessage).lineLimit(2)
        } icon: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .font(.caption).foregroundStyle(.secondary)
        .help(Text(notice.localizedMessage))
    }
}

struct ReviewRemovalBanner: View {
    let removal: TodoMonitorService.ReviewRemoval
    let monitor: TodoMonitorService
    @State private var showingReviews = false

    private struct Dismissal: Hashable {
        let id: UUID
        let showingReviews: Bool
    }

    private var title: LocalizedStringResource {
        if !removal.automatic { return .Board.boardReviewAssignmentHidden(removal.reviews.first?.title ?? "") }
        if removal.reviews.count == 1 {
            return .ReviewIntake.reviewIntakeAutomaticallyHidden(removal.reviews[0].title)
        }
        return .ReviewIntake.reviewIntakeAutomaticallyHiddenCount(removal.reviews.count)
    }

    var body: some View {
        HStack {
            Text(title).lineLimit(1).help(Text(title))
            Spacer()
            if removal.reviews.count > 1 {
                Button(.ReviewIntake.reviewIntakeShowHidden) { showingReviews.toggle() }
                    .popover(isPresented: $showingReviews) { hiddenReviews }
            }
            Button(.Board.boardReviewAssignmentRestore) { monitor.undoReviewRemoval(removal) }
        }
        .font(.caption).padding(12).background(Color.accentColor.opacity(0.08))
        .task(id: Dismissal(id: removal.id, showingReviews: showingReviews)) {
            guard !showingReviews else { return }
            do { try await Task.sleep(for: removal.automatic ? .seconds(10) : TodoMonitorService.undoWindow) }
            catch { return }
            monitor.dismissReviewRemoval(removal.id)
        }
    }

    private var hiddenReviews: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(removal.reviews) { review in
                    VStack(alignment: .leading, spacing: 2) {
                        Link(review.title, destination: review.url)
                        Text(verbatim: "\(review.url.gitLabProjectPath) !\(review.target.iid ?? 0)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .frame(width: 360, height: min(300, 24 + CGFloat(removal.reviews.count) * 50))
    }
}
