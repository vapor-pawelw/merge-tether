import SwiftUI

struct ReReviewControls: View {
    let item: MergeRequestAttentionMonitor.Item
    let monitor: MergeRequestAttentionMonitor
    @State private var confirm = false
    @State private var isWorking = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let readiness = item.reReviewReadiness {
            VStack(alignment: .leading, spacing: 6) {
                Label { Text(readiness.message) } icon: {
                    Image(systemName: readiness == .checking ? "hourglass" : "exclamationmark.triangle")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                if let blockers = blockers(for: readiness) {
                    DisclosureGroup {
                        ForEach(blockers, id: \.noteID) { blocker in
                            VStack(alignment: .leading, spacing: 2) {
                                if blocker.isPrivateCodeQuestion {
                                    Text(.AuthorFeedback.authorFeedbackCodeReviewQuestion).foregroundStyle(.secondary)
                                    Link(destination: noteURL(blocker.noteID)) { Text(.AuthorFeedback.authorFeedbackCodeReviewContext) }
                                } else {
                                    Text(readiness.isUncertain || blocker.isUncertain ? .FeedbackSuggestions.feedbackSuggestionsUnverifiedConcern
                                        : .FeedbackSuggestions.feedbackSuggestionsConfirmedConcern).foregroundStyle(.secondary)
                                    Link(destination: noteURL(blocker.noteID)) { Text(.Menu.menuReReviewNote(blocker.noteID)) }
                                }
                                if let summary = AgentExplanation.summary(blocker.summary) { Text(verbatim: summary) }
                                AgentDiagnosticDetails(reason: blocker.reason)
                            }
                            .font(.caption)
                        }
                    } label: { Text(.Board.boardCompactDetails) }
                    .font(.caption)
                }
                if monitor.confirmationStates[item.id] == .changed {
                    Text(.Menu.menuReReviewChanged).font(.caption).foregroundStyle(.orange)
                }
                if monitor.confirmationStates[item.id] == .failed {
                    Text(.Menu.menuConfirmFailed).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    if item.canConfirmReReview {
                        Button { confirm = true } label: { Text(.Menu.menuReReviewConfirm) }
                            .buttonStyle(.borderedProminent)
                    }
                    if readiness != .checking {
                        Button {
                            isWorking = true
                            Task { await monitor.retryReReview(item.id); isWorking = false }
                        } label: { Text(readiness == .manual ? .Settings.settingsAssistantSetupRecheck : .Menu.menuReReviewRetry) }
                    }
                }
                .controlSize(.small)
                .disabled(isWorking)
                if readiness == .unavailable || readiness == .failed {
                    Button { openSettings() } label: { Text(.Menu.menuActionSettings) }
                        .buttonStyle(.link).font(.caption)
                }
            }
            .confirmationDialog(Text(.Menu.menuReReviewConfirm), isPresented: $confirm, titleVisibility: .visible) {
                Button {
                    guard let head = item.mergeRequest?.sha, let fingerprint = item.reReviewFingerprint else { return }
                    isWorking = true
                    Task {
                        await monitor.confirmReReview(item.id, head: head, fingerprint: fingerprint)
                        isWorking = false
                    }
                } label: { Text(.Menu.menuReReviewConfirm) }
            } message: { Text(.Menu.menuReReviewConfirmMessage) }
        }
    }

    private func noteURL(_ id: Int) -> URL {
        var components = URLComponents(url: item.url, resolvingAgainstBaseURL: false)
        components?.fragment = "note_\(id)"
        return components?.url ?? item.url
    }

    private func blockers(for readiness: ReReviewReadiness) -> [ReReviewReadiness.Blocker]? {
        switch readiness {
        case .blocked(let blockers), .uncertain(let blockers): blockers
        default: nil
        }
    }
}
