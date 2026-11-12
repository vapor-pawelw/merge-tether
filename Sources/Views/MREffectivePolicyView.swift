import SwiftUI

/// Uses saved policy and account-bound display facts; rendering performs no reads or actions.
struct MREffectivePolicySummary: View {
    let row: MergeRequestBoardSnapshot.Row
    let monitor: TodoMonitorService
    var excluding: [String] = []

    var body: some View {
        let target = monitor.scopeTarget(projectID: row.id.projectID, iid: row.id.iid, url: row.item.url)
        let request = row.displayRequest
        let sameContext = row.evidenceMatchesCatalogContext
        let status = monitor.authoredMergeRequests.hasSyncedCurrentCatalog && sameContext
            ? monitor.authoredMergeRequests.requests.first { status in
                status.request.projectID == row.id.projectID && status.request.iid == row.id.iid
                    && request.map { current in
                        MergeRequestDependencySummary.Context(status.request) == .init(current)
                            && status.request.semanticContextFingerprint == current.semanticContextFingerprint
                            && status.request.draft == current.draft
                    } == true
            } : nil
        let catalogCurrent = monitor.attention.hasSyncedCurrentCatalog || monitor.authoredMergeRequests.hasSyncedCurrentCatalog
        let submission = status?.submissionState ?? (catalogCurrent && request?.hasQueuedMerge == true ? .queued : .none)
        let input = MREffectivePolicyPresentation.Input(request: request, target: target, settings: monitor.settings,
            assistantReady: monitor.assistantDependencies.available.contains(monitor.settings.automation.assistant),
            readState: .init(catalogCurrent: catalogCurrent, row: row, input: monitor.boardRowInput(for: row)),
            submission: submission,
            cliHold: monitor.cliHealth.hold(for: monitor.settings.automation.assistant)?.issue.kind)
        MREffectivePolicyView(presentation: .init(input: input),
            excluding: excluding + (status?.submissionState.title.map { [String(localized: $0)] } ?? []))
    }
}

struct MREffectivePolicyView: View {
    let presentation: MREffectivePolicyPresentation
    var excluding: [String] = []
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let clauses = presentation.clauses.filter { !excluding.contains(String(localized: $0.message)) }
        VStack(alignment: .leading, spacing: 6) {
            if !clauses.isEmpty {
                // Separate pills keep each rule scannable instead of one run-on sentence.
                StatusFlowLayout(spacing: 5) {
                    ForEach(Array(clauses.enumerated()), id: \.offset) { _, clause in
                        MREffectivePolicyPill(message: clause.message, symbol: clause.symbol, isHold: clause.isHold)
                    }
                }
            }
            if let action = presentation.settingsAction {
                Button { SettingsNavigation.shared.perform(action) { openSettings() } } label: {
                    Text(.EffectivePolicy.policyChooseAutomationSettings)
                }
                .font(.caption).buttonStyle(.link)
            }
        }
    }
}

private struct MREffectivePolicyPill: View {
    let message: LocalizedStringResource
    let symbol: String
    let isHold: Bool

    var body: some View {
        let tint: Color = isHold ? .orange : .secondary
        Label { Text(message).foregroundStyle(isHold ? Color.primary : Color.secondary) } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.caption)
        .labelStyle(PolicyPillLabelStyle())
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(tint.opacity(isHold ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 6))
        .fixedSize(horizontal: false, vertical: true)
        .help(Text(message))
    }
}

private struct PolicyPillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

private extension MREffectivePolicyPresentation.Clause {
    var symbol: String {
        switch self {
        case .publicationAfterChecks: "text.bubble"
        case .publicationManual, .approvalManual, .mergeManual, .deliveryManual: "hand.raised"
        case .mergeAfterChecks, .approvalAfterChecks, .requiresVerification: "checkmark.shield"
        case .draftPaused, .scopePaused: "pause.circle"
        case .automationOff: "bolt.slash"
        case .automationDecisionRequired: "questionmark.circle"
        case .privateWork: "lock"
        case .savedDataHold, .assistantUnavailable, .loginRequired, .rateLimited: "exclamationmark.triangle"
        case .finishCommentReview: "text.bubble"
        case .mergeSubmission: "arrow.triangle.merge"
        }
    }

    /// Conditions that stop automatic work stand out from routine policy facts.
    var isHold: Bool {
        switch self {
        case .savedDataHold, .assistantUnavailable, .loginRequired, .rateLimited, .automationDecisionRequired: true
        default: false
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .publicationAfterChecks(let mode):
            switch mode {
            case .all: .EffectivePolicy.policyPublicationAll
            case .aiReplies: .EffectivePolicy.policyPublicationAi
            case .filtered: .EffectivePolicy.policyPublicationFiltered
            case .manual: .EffectivePolicy.policyPublicationManual
            }
        case .publicationManual: .EffectivePolicy.policyPublicationManual
        case .mergeManual: .EffectivePolicy.policyMergeManual
        case .mergeAfterChecks: .EffectivePolicy.policyMergeChecks
        case .approvalManual: .EffectivePolicy.policyApprovalManual
        case .approvalAfterChecks: .EffectivePolicy.policyApprovalChecks
        case .deliveryManual: .EffectivePolicy.policyDeliveryManual
        case .draftPaused: .EffectivePolicy.policyDraftPaused
        case .scopePaused: .EffectivePolicy.policyScopePaused
        case .automationOff: .EffectivePolicy.policyOff
        case .automationDecisionRequired: .EffectivePolicy.policyAutomationDecision
        case .privateWork: .AutomationProfiles.privateWork
        case .savedDataHold: .EffectivePolicy.policySavedData
        case .requiresVerification: .EffectivePolicy.policyVerification
        case .assistantUnavailable: .EffectivePolicy.policyAssistant
        case .loginRequired: .EffectivePolicy.policyLogin
        case .rateLimited: .EffectivePolicy.policyLimit
        case .finishCommentReview: .EffectivePolicy.policyCommentReview
        case .mergeSubmission(let state): state.title ?? .EffectivePolicy.policyVerification
        }
    }
}
