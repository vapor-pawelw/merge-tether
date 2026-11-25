import SwiftUI

struct AssistantUsageMRDetailCost: View {
    let mergeRequest: AssistantUsageMergeRequest?

    @State private var totals: [AssistantUsageRole: AssistantUsageTotal]?
    @State private var agentTotals: [AutomationAssistant: AssistantUsageTotal] = [:]
    @State private var verifierTotals: [AssistantUsagePurpose: AssistantUsageTotal] = [:]
    @State private var recentVerifierRequests: [AssistantUsageEntry] = []
    @State private var loadedIdentity: String?
    @State private var refreshID = UUID()
    @State private var loadFailed = false
    private let rowInset: CGFloat = 10

    var body: some View {
        Group {
            if let mergeRequest {
                VStack(alignment: .leading, spacing: 10) {
                    if loadedIdentity == mergeRequest.id, let totals {
                        AssistantUsageCostRow(amount: .init(total: overall(totals), noActivity: true, precise: true)) {
                            Text(.AssistantUsage.assistantUsageMRLifetimeCost).fontWeight(.semibold)
                        }
                        .font(.callout)
                        .padding(.horizontal, rowInset)
                        roleRow(.AssistantUsage.assistantUsageMRVerifier,
                            detail: .AssistantUsage.assistantUsageVerificationDetail, total: totals[.verifier] ?? .init())
                        roleRow(.AssistantUsage.assistantUsageMRReviewer,
                            detail: .AssistantUsage.assistantUsageCodingAgentDetail, total: totals[.codingAgent] ?? .init())
                        Text(.AssistantUsage.assistantUsageByAgentTitle).font(.caption.weight(.medium))
                            .help(Text(.AssistantUsage.assistantUsageByAgentHelp))
                            .padding(.horizontal, rowInset)
                        ForEach(AutomationAssistant.allCases) { assistant in
                            roleRow(assistant.usageLabel, detail: .AssistantUsage.assistantUsageByAgentCardDetail,
                                total: agentTotals[assistant] ?? .init())
                        }
                        AssistantUsageVerifierBreakdown(totals: verifierTotals, recentRequests: recentVerifierRequests)
                            .padding(.horizontal, rowInset)
                    } else if !loadFailed || loadedIdentity != mergeRequest.id {
                        ProgressView().controlSize(.small)
                    }
                    if loadFailed, loadedIdentity == mergeRequest.id {
                        Text(.AssistantUsage.assistantUsageUnavailable)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(.AssistantUsage.assistantUsageMRHistoryHelp)
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, rowInset)
                }
                .task(id: "\(mergeRequest.id)/\(refreshID)") {
                    guard !Task.isCancelled else { return }
                    if loadedIdentity != mergeRequest.id {
                        totals = nil
                        loadedIdentity = mergeRequest.id
                        loadFailed = false
                    }
                    await refresh(for: mergeRequest)
                }
                .onReceive(NotificationCenter.default.publisher(for: AssistantUsageStore.didChange).receive(on: RunLoop.main)) { _ in
                    refreshID = UUID()
                }
            }
        }
        .textSelection(.enabled)
    }

    private func roleRow(_ title: LocalizedStringResource, detail: LocalizedStringResource,
                         total: AssistantUsageTotal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AssistantUsageCostRow(amount: .init(total: total, noActivity: true, precise: true)) {
                Text(title).fontWeight(.medium)
            }
            Text(detail).foregroundStyle(.secondary)
            Text(.AssistantUsage.assistantUsageMRAgentRequests(total.runs))
                .monospacedDigit()
                .help(Text(.AssistantUsage.assistantUsageMRAgentRequestsHelp))
            AssistantUsageEstimateIssues(total: total)
            if total.runs > 0 {
                if total.inputTokens > 0 || total.outputTokens > 0 || total.tokensUnavailable != true {
                    Text(.AssistantUsage.assistantUsageTokens(total.inputTokens, total.cachedInputTokens, total.outputTokens))
                        .foregroundStyle(.secondary)
                    if total.tokensUnavailable == true {
                        Text(.AssistantUsage.assistantUsageTokensPartial).foregroundStyle(.secondary)
                    }
                } else {
                    Text(.AssistantUsage.assistantUsageTokensUnavailable).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .padding(rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func overall(_ totals: [AssistantUsageRole: AssistantUsageTotal]) -> AssistantUsageTotal {
        var result = AssistantUsageTotal()
        for role in AssistantUsageRole.allCases { result.add(totals[role] ?? .init()) }
        return result
    }

    @MainActor
    private func refresh(for mergeRequest: AssistantUsageMergeRequest) async {
        do {
            let snapshot = try await AssistantUsageStore.shared.snapshot()
            guard !Task.isCancelled else { return }
            totals = Dictionary(uniqueKeysWithValues: AssistantUsageRole.allCases.map {
                ($0, snapshot.total(for: mergeRequest, role: $0))
            })
            agentTotals = Dictionary(uniqueKeysWithValues: AutomationAssistant.allCases.map {
                ($0, snapshot.total(for: mergeRequest, assistant: $0))
            })
            verifierTotals = snapshot.verifierTotalsByPurpose(for: mergeRequest)
            recentVerifierRequests = snapshot.recentVerifierRequests(for: mergeRequest)
            loadFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
        }
    }
}
