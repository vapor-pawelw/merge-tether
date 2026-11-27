import SwiftUI

struct RemoteCrashReportingPrompt: View {
    let onReview: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onReview) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 36, height: 36)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(.CrashReporting.crashReportingTitle)
                            .font(.headline)
                        Text(.CrashReporting.crashReportingReviewOptions)
                            .font(.subheadline)
                            .foregroundStyle(.tint)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("crash-reporting.review")

            Button(action: onDecline) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.quaternary, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(.CrashReporting.crashReportingDecline))
            .accessibilityIdentifier("crash-reporting.decline")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }
}
