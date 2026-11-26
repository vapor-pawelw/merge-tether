import SwiftUI

struct MergeWorkflowSettingsSection: View {
    @Binding var settings: AutomationSettings
    let writeBlock: SettingsPolicyEditor.AutomaticWriteBlock?
    @State private var trigger: MergeWorkflowTrigger = .pipelineFailure

    var body: some View {
        Section {
            Picker(selection: $trigger) {
                ForEach(MergeWorkflowTrigger.allCases) { trigger in
                    Text(trigger.displayLabel).tag(trigger)
                }
            } label: { Text(.Settings.settingsAutomationWorkflowEvent) }
            Picker(selection: rule.mode) {
                ForEach(trigger.allowedModes, id: \.self) { mode in
                    Text(mode.displayLabel).tag(mode)
                }
            } label: { Text(.Settings.settingsAutomationWorkflowMode) }
            .disabled(!settings.hasAutomaticActionConsent)
        } header: { Text(.Settings.settingsAutomationPageWorkflow) }
        footer: {
            if trigger == .reviewWaiting { Text(.Settings.settingsAutomationWorkflowReviewWaitingHelp) }
            else { Text(.Settings.settingsAutomationWorkflowModesHelp) }
        }

        Section {
            TextField(text: rule.projects) { Text(.Settings.settingsAutomationWorkflowProjects) }
                .autocorrectionDisabled()
            TextField(text: rule.targetBranches) { Text(.Settings.settingsAutomationWorkflowTargetBranches) }
                .autocorrectionDisabled()
            TextField(text: rule.requiredLabel) { Text(.Settings.settingsAutomationWorkflowRequiredLabel) }
                .autocorrectionDisabled()
            if trigger == .reviewWaiting {
                Stepper(value: rule.waitHours, in: 1...720) {
                    Text(.Settings.settingsAutomationWorkflowWaitHours(rule.wrappedValue.waitHours))
                }
            }
        } header: { Text(.AutomationProfiles.eventFilters) }
        footer: { Text(.Settings.settingsAutomationWorkflowProjectsHelp) }

        if trigger == .pipelineFailure { pipelineActions }
    }

    private var pipelineActions: some View {
        Section {
            HStack {
                Toggle(isOn: $settings.autoClaimPipelineFailures) {
                    Text(.Settings.settingsAutomationPipelineOwnership)
                }
                .toggleStyle(.checkbox)
                Spacer()
                AutomationDefaultsResetButton(preset: settings.baselinePreset) {
                    settings.resetCheckpoint(.pipelineOwnership, to: $0)
                }
            }
            .disabled(!settings.hasAutomaticActionConsent)
            Text(.Settings.settingsAutomationPipelineOwnershipHelp).font(.caption).foregroundStyle(.secondary)
            Toggle(isOn: rule.retryInfrastructureFailure) {
                Text(.Settings.settingsAutomationWorkflowRetry)
            }
            .toggleStyle(.checkbox)
            .disabled(!settings.canConfigureInfrastructureRetry)
            if let writeBlock {
                Text(writeBlock.message).font(.caption).foregroundStyle(.secondary)
            } else if rule.wrappedValue.mode != .assistant {
                Text(.AutomationProfiles.pipelineRetryNeedsAgent).font(.caption).foregroundStyle(.secondary)
            } else if !settings.canConfigureInfrastructureRetry {
                Text(.AutomationProfiles.pipelineRetryNeedsProjects).font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text(.AutomationProfiles.pipelineSection) }
    }

    private var rule: Binding<MergeWorkflowRule> {
        let selected = trigger
        return Binding(get: { settings.workflowRules[selected] }, set: { settings.workflowRules[selected] = $0 })
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
