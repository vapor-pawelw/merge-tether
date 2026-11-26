import SwiftUI

struct CrashReportingSettingsSection: View {
    @Environment(CrashReporting.self) private var reporting

    var body: some View {
        Section {
            if reporting.isAvailable {
                Toggle(isOn: Binding(get: { reporting.isEnabled }, set: { reporting.setEnabled($0) })) {
                    Text(.CrashReporting.crashReportingEnable)
                }
                .accessibilityIdentifier("crash-reporting.enabled")
            } else {
                Text(.CrashReporting.crashReportingUnavailable)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(.CrashReporting.crashReportingTitle)
        } footer: {
            if reporting.isAvailable { CrashReportingDetails() }
        }
    }
}

struct CrashReportingExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(.CrashReporting.crashReportingTitle)
                .font(.title3.weight(.semibold))
            CrashReportingDetails()
        }
    }
}

private struct CrashReportingDetails: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(.CrashReporting.crashReportingDetails)
                .foregroundStyle(.secondary)
            if let url = URL(string: "https://github.com/vapor-pawelw/merge-tether/blob/main/docs/building.md#crash-reporting-privacy") {
                Link(destination: url) { Text(.CrashReporting.crashReportingPrivacy) }
            }
        }
    }
}
