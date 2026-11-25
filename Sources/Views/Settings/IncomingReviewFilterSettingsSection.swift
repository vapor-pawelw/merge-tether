import SwiftUI

struct IncomingReviewFilterSettingsSection: View {
    let monitor: TodoMonitorService
    @Environment(\.openSettings) private var openSettings
    @State private var draft: IncomingReviewFilterSettings
    @State private var example: LocalizedStringResource = .ReviewIntake.reviewIntakeExampleDraft
    @State private var saveFailed = false

    init(monitor: TodoMonitorService) {
        self.monitor = monitor
        _draft = State(initialValue: monitor.settings.incomingReviewFilterSettings)
    }

    var body: some View {
        Section {
            Toggle(isOn: $draft.enabled) { Text(.ReviewIntake.reviewIntakeToggle) }
            if draft.enabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text(.ReviewIntake.reviewIntakeCriteria)
                    TextEditor(text: $draft.criteria)
                        .font(.body)
                        .frame(minHeight: 85)
                        .overlay(alignment: .topLeading) {
                            if draft.criteria.isEmpty {
                                Text(example)
                                    .foregroundStyle(Color(nsColor: .placeholderTextColor))
                                    .padding(.horizontal, 5)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel(Text(.ReviewIntake.reviewIntakeCriteria))
                        .accessibilityHint(Text(example))
                        .onAppear {
                            example = [
                                .ReviewIntake.reviewIntakeExampleDraft,
                                .ReviewIntake.reviewIntakeExampleProject,
                                .ReviewIntake.reviewIntakeExampleBranch,
                                .ReviewIntake.reviewIntakeExampleDisplayName
                            ].randomElement() ?? example
                        }
                }
                Toggle(isOn: $draft.showHiddenReviewsInInbox) {
                    Text(.ReviewIntake.reviewIntakeShowHiddenInInbox)
                }
                .toggleStyle(.checkbox)
                .help(Text(.ReviewIntake.reviewIntakeShowHiddenInInboxHelp))
                agentStatus
            }
            if draft != monitor.settings.incomingReviewFilterSettings {
                HStack {
                    Spacer()
                    Button(.ReviewIntake.reviewIntakeSave) {
                        let criteriaChanged = draft.activeCriteria != monitor.settings.incomingReviewFilterSettings.activeCriteria
                        saveFailed = !monitor.settings.saveIncomingReviewFilterSettings(draft)
                        if !saveFailed && criteriaChanged { monitor.incomingReviewFilter.configurationChanged() }
                    }
                    .disabled(draft.enabled && draft.activeCriteria == nil)
                }
            }
            if saveFailed { Text(.ReviewIntake.reviewIntakeSaveFailed).foregroundStyle(.red) }
        } header: {
            Text(.ReviewIntake.reviewIntakeTitle)
        } footer: {
            Text(.ReviewIntake.reviewIntakeHelp)
        }
    }

    @ViewBuilder private var agentStatus: some View {
        let automation = monitor.settings.automation
        if let assistant = automation.selectedAssistant {
            let model = assistant == .codex ? automation.codexVerificationModel.name : automation.claudeVerificationModel.name
            Text(.ReviewIntake.reviewIntakeVerifier(String(localized: assistant.displayName), model))
                .foregroundStyle(.secondary)
        }
        if !monitor.settings.automationGloballyEnabled {
            Text(.ReviewIntake.reviewIntakePaused).foregroundStyle(.secondary)
        } else if monitor.checkingSelectedAssistant && !monitor.selectedAssistantReady {
            Text(.ReviewIntake.reviewIntakeChecking).foregroundStyle(.secondary)
        } else if !monitor.selectedAssistantReady {
            HStack {
                Text(.ReviewIntake.reviewIntakeUnavailable).foregroundStyle(.orange)
                Spacer()
                Button(.ReviewIntake.reviewIntakeAgentSettings) {
                    SettingsNavigation.shared.showCodingAgent(openSettings: { openSettings() })
                }
            }
        }
    }

}
