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
                Label {
                    if working { Text(.DraftMR.markingReady) }
                    else { Text(.DraftMR.markReady) }
                } icon: {
                    if working { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "checkmark.circle") }
                }
            }
            .disabled(working)
            .help(Text(.DraftMR.markReadyHelp))
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
