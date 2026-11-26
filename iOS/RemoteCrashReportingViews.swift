import SwiftUI

struct RemoteCrashReportingConsentView: View {
    let reporting: CrashReporting

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                CrashReportingExplanation()

                Button(.CrashReporting.crashReportingEnable) { reporting.setEnabled(true) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("crash-reporting.allow")

                Button(.CrashReporting.crashReportingDecline) { reporting.setEnabled(false) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("crash-reporting.decline")
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

struct RemoteCrashReportingSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { CrashReportingSettingsSection() }
                .navigationTitle(Text(.CrashReporting.crashReportingSettings))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button(.Remote.remoteClose) { dismiss() } }
                }
        }
    }
}
