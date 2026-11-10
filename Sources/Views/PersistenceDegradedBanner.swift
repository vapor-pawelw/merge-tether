import SwiftUI

struct PersistenceDegradedBanner: View {
    let settings: SettingsManager

    var body: some View {
        if !settings.automaticActionsAllowed {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(.Settings.settingsPersistencePausedTitle).fontWeight(.semibold)
                    Text(.Settings.settingsPersistencePausedHelp)
                }
            }
            .font(.caption)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}
