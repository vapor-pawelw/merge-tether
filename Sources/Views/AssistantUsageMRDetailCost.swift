import SwiftUI

struct AssistantUsageMRDetailCost: View {
    let mergeRequest: AssistantUsageMergeRequest?

    @State private var totals: [AssistantUsageRole: AssistantUsageTotal]?
    @State private var loadedIdentity: String?
    @State private var refreshID = UUID()
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let mergeRequest {
                VStack(alignment: .leading, spacing: 10) {
                    Text(.AssistantUsage.assistantUsageMRTitle).font(.subheadline.weight(.medium))
                    if loadedIdentity == mergeRequest.id, let totals {
                        HStack(alignment: .firstTextBaseline) {
                            Text(.AssistantUsage.assistantUsageMRLifetimeCost)
                            Spacer()
                            AssistantUsageTotalAmount(total: overall(totals), noActivity: true, precise: true)
                        }
                        roleRow(.AssistantUsage.assistantUsageMRVerifier,
                            detail: .AssistantUsage.assistantUsageVerificationDetail, total: totals[.verifier] ?? .init())
                        roleRow(.AssistantUsage.assistantUsageMRReviewer,
                            detail: .AssistantUsage.assistantUsageCodingAgentDetail, total: totals[.codingAgent] ?? .init())
                    } else if !loadFailed || loadedIdentity != mergeRequest.id {
                        ProgressView().controlSize(.small)
                    }
                    if loadFailed, loadedIdentity == mergeRequest.id {
                        Text(.AssistantUsage.assistantUsageUnavailable)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(.AssistantUsage.assistantUsageMRHistoryHelp)
                        .font(.caption).foregroundStyle(.secondary)
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
            HStack(alignment: .firstTextBaseline) {
                Text(title).fontWeight(.medium)
                Spacer()
                AssistantUsageTotalAmount(total: total, noActivity: true, precise: true)
            }
            Text(detail).foregroundStyle(.secondary)
            Text(.AssistantUsage.assistantUsageMRAgentRequests(total.runs))
                .monospacedDigit()
                .help(Text(.AssistantUsage.assistantUsageMRAgentRequestsHelp))
            if total.unknownCostRuns > 0 {
                Text(.AssistantUsage.assistantUsageMRUnknownRuns(total.unknownCostRuns)).foregroundStyle(.secondary)
            }
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
        .padding(10)
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
            loadFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
        }
    }
}
