import SwiftUI

/// Uses saved policy and account-bound display facts; rendering performs no reads or actions.
struct MREffectivePolicySummary: View {
    let row: MergeRequestBoardSnapshot.Row
    let monitor: TodoMonitorService
    var excluding: [String] = []
    /// Cards move routine rules into the automation toggle's help and keep only holds.
    var holdsOnly = false

    var body: some View {
        let (presentation, submissionTitle) = Self.presentation(row: row, monitor: monitor)
        MREffectivePolicyView(presentation: presentation, holdsOnly: holdsOnly,
            excluding: excluding + (submissionTitle.map { [String(localized: $0)] } ?? []),
            onAgentConfigured: { Task { await monitor.refreshFromGitLab(for: row.id) } })
    }

    static func presentation(row: MergeRequestBoardSnapshot.Row, monitor: TodoMonitorService)
        -> (MREffectivePolicyPresentation, LocalizedStringResource?) {
        let target = monitor.scopeTarget(projectID: row.id.projectID, iid: row.id.iid, url: row.item.url)
        let request = row.displayRequest
        let sameContext = row.evidenceMatchesCatalogContext
        let status: AuthoredMergeRequestStatus?
        if monitor.authoredMergeRequests.hasSyncedCurrentCatalog, sameContext, let request {
            let context = MergeRequestDependencySummary.Context(request)
            status = monitor.authoredMergeRequests.requests.first { status in
                let candidate = status.request
                guard candidate.projectID == row.id.projectID, candidate.iid == row.id.iid,
                      MergeRequestDependencySummary.Context(candidate) == context else { return false }
                return candidate.semanticContextFingerprint == request.semanticContextFingerprint && candidate.draft == request.draft
            }
        } else {
            status = nil
        }
        let catalogCurrent = monitor.attention.hasSyncedCurrentCatalog || monitor.authoredMergeRequests.hasSyncedCurrentCatalog
        let submission = status?.displayedSubmissionState ?? (catalogCurrent && request?.hasQueuedMerge == true ? .queued : .none)
        let readState = MREffectivePolicyPresentation.ReadState(catalogCurrent: catalogCurrent, row: row,
            input: monitor.boardRowInput(for: row))
        let input = MREffectivePolicyPresentation.Input(request: request, target: target, settings: monitor.settings,
            assistantReady: monitor.selectedAssistantReady || monitor.checkingSelectedAssistant,
            readState: readState, submission: submission,
            cliHold: monitor.settings.automation.selectedAssistant.flatMap { monitor.cliHealth.hold(for: $0)?.issue.kind })
        return (.init(input: input), status?.displayedSubmissionState.title)
    }
}

struct MREffectivePolicyView: View {
    let presentation: MREffectivePolicyPresentation
    var holdsOnly = false
    var excluding: [String] = []
    var onAgentConfigured: (() -> Void)?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let clauses = (holdsOnly ? presentation.cardClauses : presentation.clauses)
            .filter { !excluding.contains(String(localized: $0.message)) }
        if !clauses.isEmpty || presentation.settingsAction != nil { content(clauses) }
    }

    private func content(_ clauses: [MREffectivePolicyPresentation.Clause]) -> some View {
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
                Button {
                    switch action {
                    case .chooseAutomationSettings: SettingsNavigation.shared.perform(action) { openSettings() }
                    case .chooseCodingAgent:
                        SettingsNavigation.shared.showCodingAgent(openSettings: { openSettings() }, onConfigured: onAgentConfigured)
                    }
                } label: {
                    Text(action == .chooseCodingAgent ? .Settings.settingsAssistantResumeAction
                         : .EffectivePolicy.policyChooseAutomationSettings)
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

extension MREffectivePolicyPresentation.Clause {
    var symbol: String {
        switch self {
        case .publicationAfterChecks: "text.bubble"
        case .publicationManual, .approvalManual, .mergeManual, .deliveryManual: "hand.raised"
        case .mergeAfterChecks, .approvalAfterChecks, .requiresVerification: "checkmark.shield"
        case .draftPaused, .scopePaused, .automationOff: "pause.fill"
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
