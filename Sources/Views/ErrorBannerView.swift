import SwiftUI

struct ErrorBannerView: View {
    let error: GlabError
    var authStatus: GlabService.AuthStatus = .unknown
    var isRetrying = false
    let onRetry: () -> Void
    let onOpenSetup: () -> Void
    let onOpenIntegration: () -> Void
    @State private var showingDetails = false

    private var presentation: GlabErrorPresentation { .init(error: error, authStatus: authStatus) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange).accessibilityHidden(true)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title).fontWeight(.semibold)
                    Text(presentation.message).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail = presentation.detail {
                    DisclosureGroup(isExpanded: $showingDetails) {
                        ScrollView {
                            Text(verbatim: detail).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                        .padding(.top, 4)
                    } label: { Text(.GitLabConnection.details).foregroundStyle(.secondary) }
                }
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        presentation.perform(onRetry: onRetry, onOpenSetup: onOpenSetup, onOpenIntegration: onOpenIntegration)
                    } label: {
                        HStack(spacing: 5) {
                            if isRetrying, presentation.action == .retry { ProgressView().controlSize(.mini) }
                            Text(presentation.actionTitle)
                        }
                    }
                    .controlSize(.small)
                    .disabled(isRetrying && presentation.action == .retry)
                }
            }
        }
        .font(.caption)
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.18)))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .onChange(of: error) { _, _ in showingDetails = false }
    }
}
