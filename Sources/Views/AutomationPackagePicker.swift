import SwiftUI

enum AutomationPackageChoice: Hashable {
    case recommended, off

    func apply(to settings: inout AutomationSettings, assistant: AutomationAssistant) {
        settings.assistant = assistant
        switch self {
        case .recommended: settings.applyRecommended(for: assistant)
        case .off: settings.disableAssistantPackage()
        }
    }
}

struct AutomationPackagePicker: View {
    @Binding var selection: AutomationPackageChoice?
    let canUseRecommended: Bool

    var body: some View {
        Picker(selection: $selection) {
            Text(.Settings.settingsAutomationPackageChoose)
                .tag(nil as AutomationPackageChoice?)
                .disabled(true)
            Text(.Settings.settingsAutomationPackageRecommended)
                .tag(AutomationPackageChoice.recommended as AutomationPackageChoice?)
                .disabled(!canUseRecommended)
            Text(.Settings.settingsAutomationPackageOff)
                .tag(AutomationPackageChoice.off as AutomationPackageChoice?)
        } label: {
            Text(.Settings.settingsAutomationPackageTitle)
        }
    }
}

struct AutomationAssistantPicker: View {
    @Binding var assistant: AutomationAssistant
    let available: Set<AutomationAssistant>
    let onRefresh: () -> Void
    @State private var lastCheck: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(AutomationAssistant.allCases, id: \.self) { candidate in
                HStack {
                    Text(candidate.displayName)
                    Spacer()
                    if available.contains(candidate) {
                        Label(.Settings.settingsAutomationAssistantDetected, systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    } else {
                        Label(.Settings.settingsAutomationAssistantMissing, systemImage: "minus.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }

            Picker(selection: $assistant) {
                ForEach(AutomationAssistant.allCases, id: \.self) { candidate in
                    Text(candidate.displayName)
                        .tag(candidate)
                        .disabled(!available.contains(candidate))
                }
            } label: {
                Text(.Settings.settingsAutomationAssistantPicker)
            }

            HStack {
                Button(action: check) {
                    Text(.Settings.settingsAutomationPackageRecheck)
                }
                if let lastCheck {
                    Text(.Settings.settingsAutomationAssistantLastCheck(lastCheck.formatted(date: .omitted, time: .standard)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: check)
    }

    private func check() {
        onRefresh()
        lastCheck = Date()
    }
}
