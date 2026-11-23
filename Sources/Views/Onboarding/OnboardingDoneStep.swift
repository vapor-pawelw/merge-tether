import SwiftUI

struct OnboardingDoneStep: View {
    let monitor: TodoMonitorService
    @Binding var isImporting: Bool
    @State private var importOutcome: ImportOutcome?

    private enum ImportOutcome {
        case imported(Int), failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(.Onboarding.onboardingDoneTitle)
                .font(.title3.weight(.semibold))

            Text(.Onboarding.onboardingDoneBody)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(.Onboarding.onboardingReviewImportBody)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(.Onboarding.onboardingReviewImportButton) {
                        importOutcome = nil
                        isImporting = true
                    }
                    .disabled(isImporting || monitor.glab.currentUsername == nil)

                    if isImporting {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(Text(.Onboarding.onboardingReviewImportInProgress))
                    }
                }

                switch importOutcome {
                case .imported(0):
                    Text(.Onboarding.onboardingReviewImportEmpty).foregroundStyle(.secondary)
                case .imported(let count):
                    Text(.Onboarding.onboardingReviewImportSuccess(count)).foregroundStyle(.secondary)
                case .failed:
                    Text(.Onboarding.onboardingReviewImportFailed).foregroundStyle(.red)
                case nil:
                    EmptyView()
                }
            }
        }
        .task(id: isImporting) {
            guard isImporting else { return }
            defer { isImporting = false }
            do {
                importOutcome = .imported(try await monitor.importAssignedReviews())
            } catch {
                if !Task.isCancelled { importOutcome = .failed }
            }
        }
        .onChange(of: monitor.glab.accountRevision) { importOutcome = nil }
    }
}
