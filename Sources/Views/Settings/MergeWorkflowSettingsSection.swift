import SwiftUI

struct MergeWorkflowSettingsSection: View {
    @Binding var rules: MergeWorkflowRules
    @State private var trigger: MergeWorkflowTrigger = .pipelineFailure

    var body: some View {
        Section {
            Picker(selection: $trigger) {
                ForEach(MergeWorkflowTrigger.allCases) { trigger in
                    Text(trigger.displayLabel)
                        .tag(trigger)
                }
            } label: {
                Text(.Settings.settingsAutomationWorkflowEvent)
            }

            Picker(selection: rule.mode) {
                Text(.Settings.settingsAutomationWorkflowModeOff).tag(MergeWorkflowMode.off)
                Text(.Settings.settingsAutomationWorkflowModePreview).tag(MergeWorkflowMode.preview)
                Text(.Settings.settingsAutomationWorkflowModeNotify).tag(MergeWorkflowMode.notify)
                Text(.Settings.settingsAutomationWorkflowModeAssistant).tag(MergeWorkflowMode.assistant)
            } label: {
                Text(.Settings.settingsAutomationWorkflowMode)
            }

            TextField(text: rule.projects) {
                Text(.Settings.settingsAutomationWorkflowProjects)
            }
            .autocorrectionDisabled()

            TextField(text: rule.targetBranches) {
                Text(.Settings.settingsAutomationWorkflowTargetBranches)
            }
            .autocorrectionDisabled()

            TextField(text: rule.requiredLabel) {
                Text(.Settings.settingsAutomationWorkflowRequiredLabel)
            }
            .autocorrectionDisabled()

            if trigger == .pipelineFailure, rule.wrappedValue.mode == .assistant {
                Toggle(isOn: rule.retryInfrastructureFailure) {
                    Text(.Settings.settingsAutomationWorkflowRetry)
                }
                .toggleStyle(.checkbox)
            }

            if trigger == .reviewWaiting {
                Stepper(value: rule.waitHours, in: 1...720) {
                    Text(.Settings.settingsAutomationWorkflowWaitHours(rule.wrappedValue.waitHours))
                }
            }
        } header: {
            Text(.Settings.settingsAutomationWorkflowSection)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(.Settings.settingsAutomationWorkflowProjectsHelp)
                Text(.Settings.settingsAutomationWorkflowModesHelp)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var rule: Binding<MergeWorkflowRule> {
        let selected = trigger
        return Binding(get: { rules[selected] }, set: { rules[selected] = $0 })
    }
}

extension MergeWorkflowTrigger {
    var displayLabel: LocalizedStringResource {
        switch self {
        case .pipelineFailure: .Settings.settingsAutomationWorkflowPipelineFailure
        case .reviewUpdate: .Settings.settingsAutomationWorkflowReviewUpdate
        case .newDiscussion: .Settings.settingsAutomationWorkflowNewDiscussion
        case .blockerChange: .Settings.settingsAutomationWorkflowBlockerChange
        case .stackDependencyMerged: .Settings.settingsAutomationWorkflowStackDependencyMerged
        case .reviewWaiting: .Settings.settingsAutomationWorkflowReviewWaiting
        }
    }
}
