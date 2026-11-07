import SwiftUI

typealias AutomationPackageChoice = AutomationPreset

extension AutomationPreset {
    var requiresCLI: Bool { self != .manual }
    var title: LocalizedStringResource {
        switch self {
        case .full: .Settings.settingsAutomationPackageFull
        case .checkpoints: .Settings.settingsAutomationPackageRecommended
        case .manual: .Settings.settingsAutomationPackageOff
        }
    }
    var explanation: LocalizedStringResource {
        switch self {
        case .full: .Settings.settingsAutomationPackageFullHelp
        case .checkpoints: .Settings.settingsAutomationPackageCheckpointsHelp
        case .manual: .Settings.settingsAutomationPackageManualHelp
        }
    }
    func apply(to settings: inout AutomationSettings, assistant: AutomationAssistant) {
        settings.applyPreset(self, for: assistant)
    }
}

extension AutomationPublicationMode {
    var title: LocalizedStringResource {
        switch self {
        case .all: .Settings.settingsAutomationPublicationAll
        case .filtered: .PublicationPolicy.publicationFiltered
        case .aiReplies: .Settings.settingsAutomationPublicationAiReplies
        case .manual: .Settings.settingsAutomationPublicationManual
        }
    }
    var explanation: LocalizedStringResource {
        switch self {
        case .all: .Settings.settingsAutomationPublicationAllHelp
        case .filtered: .PublicationPolicy.publicationFilteredHelp
        case .aiReplies: .Settings.settingsAutomationPublicationAiRepliesHelp
        case .manual: .Settings.settingsAutomationPublicationManualHelp
        }
    }
}

struct AutomationPackagePicker: View {
    @Binding var selection: AutomationPackageChoice?
    let canUseAutomatic: Bool

    var body: some View {
        Picker(selection: $selection) {
            Text(.Settings.settingsAutomationPackageChoose)
                .tag(nil as AutomationPackageChoice?)
                .disabled(true)
            ForEach(AutomationPreset.allCases, id: \.self) { choice in
                Text(choice.title).tag(choice as AutomationPackageChoice?)
                    .disabled(choice.requiresCLI && !canUseAutomatic)
            }
        } label: {
            Text(.Settings.settingsAutomationPackageTitle)
        }
    }
}

struct AutomationAssistantPicker: View {
    @Binding var assistant: AutomationAssistant
    let available: Set<AutomationAssistant>
    let onRefresh: () -> Void
    var requireCLI = true
    var statuses: [AutomationAssistant: AssistantDependencyStatus] = [:]
    @State private var lastCheck: Date?
    @State private var setupCandidate: AutomationAssistant?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(AutomationAssistant.allCases, id: \.self) { candidate in
                HStack {
                    Text(candidate.displayName)
                    Spacer()
                    if let status = statuses[candidate], !status.isReady {
                        Text(status.message(for: candidate)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if available.contains(candidate) {
                        Label(.Settings.settingsAutomationAssistantDetected, systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    } else {
                        Label(.Settings.settingsAutomationAssistantMissing, systemImage: "minus.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }

            Picker(selection: Binding(get: { assistant }, set: { setupCandidate = $0 })) {
                ForEach(AutomationAssistant.allCases, id: \.self) { candidate in
                    Text(candidate.displayName)
                        .tag(candidate)
                }
            } label: {
                Text(.Settings.settingsAutomationAssistantPicker)
            }

            HStack {
                Button(action: check) {
                    Text(.Settings.settingsAutomationPackageRecheck)
                }
                Button { setupCandidate = assistant } label: { Text(.Settings.settingsAssistantSetupAction) }
                if let lastCheck {
                    Text(.Settings.settingsAutomationAssistantLastCheck(lastCheck.formatted(date: .omitted, time: .standard)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: check)
        .sheet(item: $setupCandidate) { candidate in
            AssistantSetupView(assistant: candidate, requireCLI: true) {
                assistant = candidate
                check()
            }
        }
    }

    private func check() {
        onRefresh()
        lastCheck = Date()
    }
}
