import SwiftUI

struct AssistantUsageMRDetailCost: View {
    let mergeRequest: AssistantUsageMergeRequest?

    @State private var total: AssistantUsageTotal?
    @State private var readGeneration = UUID()

    var body: some View {
        Group {
            if let mergeRequest {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(.AssistantUsage.assistantUsageMRLifetimeCost)
                        Spacer()
                        if let total {
                            AssistantUsageTotalAmount(total: total, noActivity: true, precise: true)
                        } else {
                            Text(.AssistantUsage.assistantUsageCostUnavailable).foregroundStyle(.secondary)
                        }
                    }
                    if let total, total.unknownCostRuns > 0 {
                        Text(.AssistantUsage.assistantUsageMRUnknownRuns(total.unknownCostRuns))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if total?.runs == 0 {
                        Text(.AssistantUsage.assistantUsageMRNotTrackedYet)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .task(id: mergeRequest.id) {
                    let generation = UUID()
                    readGeneration = generation
                    total = nil
                    await refresh(for: mergeRequest, generation: generation)
                }
                .onReceive(NotificationCenter.default.publisher(for: AssistantUsageStore.didChange)) { _ in
                    let generation = readGeneration
                    Task { await refresh(for: mergeRequest, generation: generation) }
                }
                .onChange(of: mergeRequest.id) { _, _ in
                    readGeneration = UUID()
                    total = nil
                }
            }
        }
        .textSelection(.enabled)
    }

    @MainActor
    private func refresh(for mergeRequest: AssistantUsageMergeRequest, generation: UUID) async {
        guard let snapshot = try? await AssistantUsageStore.shared.snapshot() else {
            guard !Task.isCancelled, generation == readGeneration else { return }
            total = nil
            return
        }
        guard !Task.isCancelled, generation == readGeneration else { return }
        total = snapshot.total(for: mergeRequest)
    }
}
