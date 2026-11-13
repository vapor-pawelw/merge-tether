import SwiftUI

struct MarkMergeRequestReadyButton: View {
    let item: MergeRequestAttentionMonitor.Item
    let monitor: TodoMonitorService
    @State private var working = false

    var body: some View {
        if monitor.canMarkMergeRequestReady(item) {
            Button {
                working = true
                Task {
                    defer { working = false }
                    do { try await monitor.markMergeRequestReady(for: item) }
                    catch is CancellationError { monitor.markMergeRequestReadyError = String(localized: .DraftMR.changed) }
                    catch GlabError.notAuthenticated { monitor.markMergeRequestReadyError = String(localized: .DraftMR.accountChanged) }
                    catch {
                        monitor.markMergeRequestReadyError = String(localized: .DraftMR.failedHelp)
                        if let detail = errorDetail(error) { monitor.markMergeRequestReadyError? += "\n\n" + detail }
                    }
                }
            } label: {
                MRActionLabel(title: working ? .DraftMR.markingReady : .DraftMR.markReady, cta: .markReady, working: working)
            }
            .disabled(working)
            .mrActionHelp(.markReady)
        }
    }

    private func errorDetail(_ error: Error) -> String? {
        switch error {
        case GlabError.network(let detail), GlabError.decoding(let detail),
             GlabError.nonZeroExit(_, let detail), GlabError.unknown(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default: return nil
        }
    }
}
