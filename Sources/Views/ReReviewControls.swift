import SwiftUI

struct ReReviewControls: View {
    let item: MergeRequestAttentionMonitor.Item
    let monitor: MergeRequestAttentionMonitor
    let requireAssistant: () -> Bool
    let assistant: AutomationAssistant
    /// While a new feedback check runs, an earlier verdict and its retry are out of date.
    var hidesStaleResult = false
    @State private var isWorking = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let readiness = item.reReviewReadiness, !hidesStaleResult || readiness == .checking {
            VStack(alignment: .leading, spacing: 6) {
                if readiness == .checking {
                    MRActivityStatus(status: MRActivity.agentStatus(readiness.message, assistant: assistant),
                        startedAt: nil, effect: .aiCheck)
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                } else {
                    Label { Text(readiness.message) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
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
                    if let blocker = blockers(for: readiness)?.first {
                        Link(destination: noteURL(blocker.noteID)) {
                            Text(blocker.isPrivateCodeQuestion ? .AuthorFeedback.authorFeedbackCodeReviewContext
                                : .FeedbackSuggestions.feedbackSuggestionsOpenComment)
                        }.buttonStyle(.borderedProminent)
                        retryButton(readiness).buttonStyle(.bordered)
                    } else if readiness == .manual {
                        if item.canConfirmReReview { confirmationButton.buttonStyle(.borderedProminent) }
                        retryButton(readiness).buttonStyle(.bordered)
                    } else if readiness != .checking {
                        retryButton(readiness).buttonStyle(.borderedProminent)
                        if item.canConfirmReReview { confirmationButton.buttonStyle(.bordered) }
                    }
                }
                .controlSize(.small)
                .disabled(isWorking)
                if readiness == .unavailable || readiness == .failed {
                    Button {
                        SettingsNavigation.shared.showCodingAgent(openSettings: { openSettings() })
                    } label: { Text(.Menu.menuActionSettings) }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private var confirmationButton: some View {
        Button {
            guard let head = item.mergeRequest?.sha, let fingerprint = item.reReviewFingerprint else { return }
            let details = ([String(localized: .Menu.menuReReviewConfirmMessage)]
                + (item.reReviewReadiness?.manualConfirmationDetails ?? [])).joined(separator: "\n\n")
            guard confirmMRAction(.requestReReview, title: .Menu.menuReReviewConfirm, detail: details) else { return }
            isWorking = true
            Task {
                defer { isWorking = false }
                await monitor.confirmReReview(item.id, head: head, fingerprint: fingerprint)
            }
        } label: { Text(.Menu.menuReReviewConfirm) }
        .mrActionHelp(.requestReReview)
    }

    private func retryButton(_ readiness: ReReviewReadiness) -> some View {
        Button {
            let isManual = readiness == .manual
            guard isManual || requireAssistant() else { return }
            guard confirmMRAction(.verifyReReview, title: isManual ? .Settings.settingsAssistantSetupRecheck : .Menu.menuReReviewRetry,
                variant: isManual ? "manual" : nil) else { return }
            isWorking = true
            Task { await monitor.retryReReview(item.id); isWorking = false }
        } label: {
            if readiness == .manual { Text(.Settings.settingsAssistantSetupRecheck) }
            else { MRActionLabel(title: .Menu.menuReReviewRetry, cta: .verifyReReview) }
        }
        .mrActionHelp(readiness == .manual ? nil : .verifyReReview)
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
