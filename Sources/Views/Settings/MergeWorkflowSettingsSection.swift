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

            LabeledContent { Text(rule.wrappedValue.mode.displayLabel) } label: {
                Text(.Settings.settingsAutomationWorkflowMode)
            }
            Text(.AutomationProfiles.permissionsLocation).font(.caption).foregroundStyle(.secondary)

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
                if trigger == .reviewWaiting { Text(.Settings.settingsAutomationWorkflowReviewWaitingHelp) }
                else { Text(.Settings.settingsAutomationWorkflowModesHelp) }
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

struct MergeWorkflowPermissionSettingsSection: View {
    @Binding var rules: MergeWorkflowRules

    var body: some View {
        Section {
            ForEach(MergeWorkflowTrigger.allCases) { trigger in
                Picker(selection: Binding(get: { rules[trigger].mode }, set: { rules[trigger].mode = $0 })) {
                    ForEach(trigger.allowedModes, id: \.self) { mode in Text(mode.displayLabel).tag(mode) }
                } label: { Text(trigger.displayLabel) }
            }
            Toggle(isOn: Binding(get: { rules[.pipelineFailure].retryInfrastructureFailure },
                                 set: { rules[.pipelineFailure].retryInfrastructureFailure = $0 })) {
                Text(.Settings.settingsAutomationWorkflowRetry)
            }
            .toggleStyle(.checkbox)
            Text(.AutomationProfiles.pipelineRetryHelp).font(.caption).foregroundStyle(.secondary)
        } header: { Text(.Settings.settingsAutomationWorkflowSection) }
        footer: { Text(.AutomationProfiles.eventFiltersLocation).font(.caption).foregroundStyle(.secondary) }
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


private extension MergeWorkflowMode {
    var displayLabel: LocalizedStringResource {
        switch self {
        case .off: .Settings.settingsAutomationWorkflowModeOff
        case .preview: .Settings.settingsAutomationWorkflowModePreview
        case .notify: .Settings.settingsAutomationWorkflowModeNotify
        case .assistant: .Settings.settingsAutomationWorkflowModeAssistant
        }
    }
}
