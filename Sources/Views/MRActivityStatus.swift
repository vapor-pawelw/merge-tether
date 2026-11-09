import SwiftUI

/// Tick only the activity label, leaving the board and its polling state untouched.
struct MRActivityStatus: View {
    let status: String
    let startedAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            if let startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(.AutomationProgress.progressTimedStatus(status,
                        MRActivity.elapsed(since: startedAt, now: context.date)))
                        .monospacedDigit()
                }
            } else {
                Text(verbatim: status)
            }
        }
    }
}
