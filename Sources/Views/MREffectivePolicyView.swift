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
        let messages = presentation.clauses.map { String(localized: $0.message) }.filter { !excluding.contains($0) }
        VStack(alignment: .leading, spacing: 4) {
            if !messages.isEmpty {
                Text(verbatim: messages.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

private extension MREffectivePolicyPresentation.Clause {
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
