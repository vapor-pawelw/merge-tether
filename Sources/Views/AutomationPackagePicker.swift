import SwiftUI

typealias AutomationPackageChoice = AutomationPreset

extension AutomationPreset {
    var requiresCLI: Bool { self != .manual }
    var title: LocalizedStringResource {
        switch self {
        case .full: .AutomationProfiles.maxTitle
        case .checkpoints: .Settings.settingsAutomationPackageRecommended
        case .manual: .AutomationProfiles.manualTitle
        case .safe: .AutomationProfiles.safeTitle
        case .trusted: .AutomationProfiles.trustedTitle
        }
    }
    var explanation: LocalizedStringResource {
        switch self {
        case .full: .AutomationProfiles.maxHelp
        case .checkpoints: .Settings.settingsAutomationPackageCheckpointsHelp
        case .manual: .AutomationProfiles.manualHelp
        case .safe: .AutomationProfiles.safeHelp
        case .trusted: .AutomationProfiles.trustedHelp
        }
    }
    func apply(to settings: inout AutomationSettings, assistant: AutomationAssistant?) {
        settings.applyPreset(self, for: assistant)
    }
}

struct AutomationPresetDescription: View {
    let preset: AutomationPreset

    enum KeyActionDefault: Hashable {
        case merge(Bool)
        case approve(Bool)
        case publish(AutomationPublicationMode, allowsBotReplies: Bool)

        var title: LocalizedStringResource {
            switch self {
            case .merge: .AutomationProfiles.presetAutoMerge
            case .approve: .AutomationProfiles.presetAutoApprove
            case .publish: .AutomationProfiles.presetAutoPublish
            }
        }

        var isEnabled: Bool {
            switch self {
            case .merge(let enabled), .approve(let enabled): enabled
            case .publish(let mode, _): mode != .manual
            }
        }

        var status: LocalizedStringResource {
            switch self {
            case .publish(.aiReplies, let allowsBotReplies):
                allowsBotReplies ? .AutomationProfiles.presetPublishAiAndBotReplies : .AutomationProfiles.presetPublishAiReplies
            case .publish(.all, _): .AutomationProfiles.presetPublishAll
            default: isEnabled ? .AutomationProfiles.presetOnByDefault : .AutomationProfiles.presetOffByDefault
            }
        }
    }

    var keyActionDefaults: [KeyActionDefault] {
        var defaults = AutomationSettings()
        defaults.applyPreset(preset, for: nil)
        return [
            .merge(defaults.autoMergeEnabled),
            .approve(defaults.autoApproveEnabled),
            .publish(defaults.publicationMode, allowsBotReplies: defaults.publicationRestrictions.allowBotReplies)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preset.explanation)
            keyActions
            Text(.AutomationProfiles.presetCustomizationHelp)
            if preset == .safe || preset == .trusted {
                Label { Text(preset == .safe ? .AutomationProfiles.safeDoes : .AutomationProfiles.trustedDoes) }
                    icon: { Image(systemName: "checkmark") }
                Label { Text(preset == .safe ? .AutomationProfiles.safeDoesNot : .AutomationProfiles.trustedDoesNot) }
                    icon: { Image(systemName: "hand.raised") }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var keyActions: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(keyActionDefaults, id: \.self) { action in
                GridRow(alignment: .firstTextBaseline) {
                    Text(action.title)
                        .fontWeight(.semibold)
                        .accessibilityValue(Text(action.status))
                    Label { Text(action.status) } icon: {
                        Image(systemName: action.isEnabled ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(action.isEnabled ? Color.green : Color.secondary)
                    }
                    .accessibilityHidden(true)
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.primary)
    }
}

struct AutomationCustomProfileDescription: View {
    let configuration: AutomationSettings

    var publicSummary: LocalizedStringResource? {
        guard configuration.hasAutomaticPublicActionConsent else { return nil }
        func status(_ enabled: Bool) -> String {
            String(localized: enabled ? .AutomationProfiles.automatic : .AutomationProfiles.manualAction)
        }
        func status(_ mode: AutomaticActionMode) -> String {
            mode == .prompt ? String(localized: .Settings.settingsAutomationActionByPrompt) : status(mode == .on)
        }
        return .AutomationProfiles.customPublicSummary(status(configuration.autoApproveMode),
            status(configuration.allowFollowUpPush),
            status(configuration.allowConflictPush && configuration.conflictTasksEnabled && configuration.allowAssistantTools),
            status(configuration.autoMergeMode))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !configuration.hasAutomaticActionConsent {
                Text(.AutomationProfiles.manualHelp)
            } else if let publicSummary {
                Text(configuration.publicationMode == .all ? .PublicationPolicy.publicationAutomaticAllHelp
                    : configuration.publicationMode == .filtered && !configuration.publicationRestrictions.hasConditions
                        ? .PublicationPolicy.publicationNoConditions : configuration.publicationMode.explanation)
                Text(publicSummary)
            } else {
                Text(.AutomationProfiles.customPrivateHelp)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
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

struct AutomationSettingsProfilePicker: View {
    enum Selection: Hashable { case preset(AutomationPreset), custom }
    @Binding var draft: AutomationSettings
    @Binding var lastCustom: AutomationProfileSnapshot?
    let canUseAutomatic: Bool
    var hasCustomOption: Bool { lastCustom != nil || AutomationProfileSnapshot.custom(from: draft) != nil }

    static func selection(for draft: Binding<AutomationSettings>, lastCustom: Binding<AutomationProfileSnapshot?>) -> Binding<Selection?> {
        Binding(get: {
            if let preset = draft.wrappedValue.matchingPreset { return .preset(preset) }
            return AutomationProfileSnapshot.custom(from: draft.wrappedValue) == nil ? nil : .custom
        }, set: { selection in
            guard let selection else { return }
            var updated = draft.wrappedValue
            switch selection {
            case .preset(let preset):
                lastCustom.wrappedValue = AutomationProfileSnapshot.custom(from: updated) ?? lastCustom.wrappedValue
                updated.applyPreset(preset, for: updated.selectedAssistant)
            case .custom:
                guard let snapshot = lastCustom.wrappedValue ?? AutomationProfileSnapshot.custom(from: updated) else { return }
                snapshot.apply(to: &updated)
            }
            draft.wrappedValue = updated
        })
    }

    var body: some View {
        Picker(selection: Self.selection(for: $draft, lastCustom: $lastCustom)) {
            Text(.Settings.settingsAutomationPackageChoose).tag(nil as Selection?).disabled(true)
            ForEach(AutomationPreset.allCases, id: \.self) { preset in
                Text(preset.title).tag(Selection.preset(preset) as Selection?)
                    .disabled(preset.requiresCLI && !canUseAutomatic)
            }
            if hasCustomOption {
                Text(.AutomationProfiles.customizedTitle).tag(Selection.custom as Selection?)
            }
        } label: { Text(.Settings.settingsAutomationPackageTitle) }
    }
}

struct AutomationAssistantPicker: View {
    @Binding var assistant: AutomationAssistant?
    let available: Set<AutomationAssistant>
    let onRefresh: () -> Void
    var statuses: [AutomationAssistant: AssistantDependencyStatus] = [:]
    var verifySelectionImmediately = true
    var onSetupReady: ((AutomationAssistant) -> Void)?
    @State private var lastCheck: Date?
    @State private var setupCandidate: AutomationAssistant?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(AutomationAssistant.allCases, id: \.self) { candidate in
                HStack {
                    CodingProviderIcon(provider: candidate.glyph)
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

            Picker(selection: Binding(get: { assistant }, set: { candidate in
                if verifySelectionImmediately, let candidate { setupCandidate = candidate }
                else { assistant = candidate }
            })) {
                Text(.Settings.settingsAssistantNone).tag(nil as AutomationAssistant?)
                ForEach(AutomationAssistant.allCases, id: \.self) { candidate in
                    Text(candidate.displayName)
                        .tag(candidate as AutomationAssistant?)
                }
            } label: {
                Text(.Settings.settingsAutomationAssistantPicker)
            }

            HStack {
                Button(action: check) {
                    Text(.Settings.settingsAutomationPackageRecheck)
                }
                if let assistant {
                    Button { setupCandidate = assistant } label: { Text(.Settings.settingsAssistantSetupAction) }
                }
                if let lastCheck {
                    Text(.Settings.settingsAutomationAssistantLastCheck(lastCheck.formatted(date: .omitted, time: .standard)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: check)
        .sheet(item: $setupCandidate) { candidate in
            AssistantSetupView(assistant: candidate) {
                if verifySelectionImmediately { assistant = candidate }
                onSetupReady?(candidate)
                check()
            }
        }
    }

    private func check() {
        onRefresh()
        lastCheck = Date()
    }
}
