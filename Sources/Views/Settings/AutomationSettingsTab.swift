import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class SettingsPolicyEditor {
    var draft: AutomationSettings {
        didSet {
            if let custom = AutomationProfileSnapshot.custom(from: draft) { sessionCustom = custom }
        }
    }
    var sessionCustom: AutomationProfileSnapshot?
    private(set) var saveState: AutomationSettingsSaveState

    var selectedAssistant: AutomationAssistant? {
        get { draft.selectedAssistant }
        set {
            var updated = draft
            if newValue == nil { updated.assistant = saveState.accepted.assistant }
            updated.selectedAssistant = newValue
            draft = updated
        }
    }

    init(settings: SettingsManager) {
        let accepted = settings.acceptedAutomation
        draft = accepted
        sessionCustom = settings.automationProfileHistory.available(for: accepted)
        saveState = .init(accepted: accepted, runtimeSavePending: accepted != settings.automation.ignoringGlobalSuspension)
    }

    var hasIncompleteRule: Bool {
        [draft.reviewRequested, draft.authorFeedback].contains { $0.isEnabled && !$0.isConfigured }
    }

    enum AutomaticWriteBlock: Equatable {
        case savedDataUnavailable, globalPause, automationDisabled, privateMode

        var message: LocalizedStringResource {
            switch self {
            case .savedDataUnavailable: .AutomationProfiles.writesBlockedBySavedData
            case .globalPause: .AutomationProfiles.writesBlockedByGlobalPause
            case .automationDisabled: .AutomationProfiles.writesBlockedByProfile
            case .privateMode: .AutomationProfiles.writesBlockedByPrivateMode
            }
        }
    }

    func automaticWriteBlock(settings: SettingsManager) -> AutomaticWriteBlock? {
        if !settings.automaticActionsAllowed { return .savedDataUnavailable }
        if !settings.automationGloballyEnabled { return .globalPause }
        if !draft.hasAutomaticActionConsent { return .automationDisabled }
        if !draft.hasAutomaticPublicActionConsent { return .privateMode }
        return nil
    }

    func updateScope(from settings: SettingsManager) {
        draft = draft.preservingScope(from: settings.configuredAutomation)
        saveState.updateSavedScope(settings.acceptedAutomation.scope)
    }

    func updateAssistant(from settings: SettingsManager) {
        let assistant = settings.acceptedAutomation.selectedAssistant
        guard assistant != saveState.accepted.selectedAssistant else { return }
        if draft.selectedAssistant == saveState.accepted.selectedAssistant { draft.selectedAssistant = assistant }
        saveState.updateSavedAssistant(assistant)
    }

    func revert(settings: SettingsManager) {
        draft = saveState.revert()
        sessionCustom = settings.automationProfileHistory.available(for: draft)
    }

    func assistantRequiringSetup(comparedTo current: AutomationSettings) -> AutomationAssistant? {
        guard let assistant = draft.selectedAssistant else { return nil }
        if assistant != current.selectedAssistant || draft.requiresAssistantSetup(comparedTo: current) { return assistant }
        return nil
    }

    func apply(monitor: TodoMonitorService, navigation: SettingsNavigation = .shared) {
        let settings = monitor.settings
        let previousAssistant = settings.acceptedAutomation.selectedAssistant
        if draft.aiCommentCriteriaOverride == nil { draft.aiCommentCriteria = AICommentOriginAssessor.criteriaInstructions }
        let custom = AutomationProfileSnapshot.custom(from: draft) ?? sessionCustom
        saveState.begin()
        settings.automation = draft.preservingScope(from: settings.automation)
        let saved = monitor.applySettings()
        saveState.runtimeSaved(settings.automation.ignoringGlobalSuspension, succeeded: saved)
        guard saved else { return }
        if let custom {
            let historySaved = settings.automationProfileHistory.save(custom)
            saveState.historySaved(succeeded: historySaved)
            if historySaved { sessionCustom = custom }
        } else { saveState.historySaved(succeeded: true) }
        if let assistant = settings.acceptedAutomation.selectedAssistant, assistant != previousAssistant {
            finishAssistantSetup(assistant, monitor: monitor, navigation: navigation)
        }
    }

    func finishAssistantSetup(_ assistant: AutomationAssistant, monitor: TodoMonitorService, navigation: SettingsNavigation = .shared) {
        guard monitor.settings.acceptedAutomation.selectedAssistant == assistant,
              monitor.settings.automation.selectedAssistant == assistant else { return }
        if let hold = monitor.cliHealth.hold(for: assistant), hold.issue.kind == .loginRequired {
            _ = monitor.cliHealth.clear(assistant, expectedID: hold.id)
        }
        navigation.codingAgentConfigured()
    }
}

struct SettingsPolicyFooter: View {
    let monitor: TodoMonitorService
    let editor: SettingsPolicyEditor
    @State private var assistantToVerify: AutomationAssistant?

    var body: some View {
        Divider()
        HStack(alignment: .center, spacing: 16) {
            if editor.saveState.failed {
                Text(.AutomationProfiles.saveFailed).foregroundStyle(.red).font(.caption)
            } else if editor.draft.workerExecutionTimeout.hasInvalidOverrides {
                Text(.WorkerTimeout.invalidOverrides).foregroundStyle(.red).font(.caption)
            } else if editor.hasIncompleteRule {
                Text(.Settings.settingsAutomationIncomplete).foregroundStyle(.red).font(.caption)
            } else if hasUnappliedChanges {
                Text(.AutomationProfiles.unsavedChanges).font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                editor.revert(settings: monitor.settings)
            } label: { Text(.AutomationProfiles.revert) }
            .disabled(editor.draft == editor.saveState.accepted
                && editor.sessionCustom == monitor.settings.automationProfileHistory.available(for: editor.saveState.accepted)
                && !editor.saveState.failed)

            Button {
                if let assistant = editor.assistantRequiringSetup(comparedTo: monitor.settings.acceptedAutomation) {
                    assistantToVerify = assistant
                } else { editor.apply(monitor: monitor) }
            } label: { Text(.Settings.settingsAutomationApply) }
            .disabled(!hasUnappliedChanges || editor.hasIncompleteRule || editor.draft.workerExecutionTimeout.hasInvalidOverrides)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .sheet(item: $assistantToVerify) { assistant in
            AssistantSetupView(assistant: assistant) {
                guard editor.draft.selectedAssistant == assistant else { return }
                editor.apply(monitor: monitor)
            }
        }
    }

    private var hasUnappliedChanges: Bool {
        editor.saveState.canApply(draft: editor.draft, custom: editor.sessionCustom,
            savedCustom: monitor.settings.automationProfileHistory.lastGood)
    }
}

struct AutomationSettingsTab: View {
    let monitor: TodoMonitorService
    private var settings: SettingsManager { monitor.settings }

    @Bindable private var editor: SettingsPolicyEditor
    @State private var page: Page = .checkpoints
    @State private var isChoosingWorkspace = false
    @State private var needsVerificationSetup = false

    init(monitor: TodoMonitorService, initialPage: Page = .checkpoints, editor: SettingsPolicyEditor? = nil) {
        self.monitor = monitor
        _page = State(initialValue: initialPage)
        self.editor = editor ?? SettingsPolicyEditor(settings: monitor.settings)
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $page) {
                ForEach(Page.allCases, id: \.self) { page in
                    Label { Text(page.title) } icon: { Image(systemName: page.symbol) }
                        .tag(page)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 190)

            Divider()

            pageContent
        }
        .sheet(isPresented: $needsVerificationSetup) {
            let assistant = editor.draft.assistant
            AssistantSetupView(assistant: assistant) {
                guard editor.draft.selectedAssistant == assistant else { return }
                editor.draft.autoVerifyReReview = true
            }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        VStack(spacing: 0) {
            globalStatus
            if page == .scope {
                AutomationScopeSettingsView(monitor: monitor)
            } else {
                Form {
                    switch page {
                    case .checkpoints:
                        packageFields
                    case .todos:
                        reviewFields
                        feedbackFields
                    case .workflow:
                        MergeWorkflowSettingsSection(settings: $editor.draft, writeBlock: automaticWriteBlock)
                        conflictFields
                    case .publication:
                        publicationFields
                        mergeFields
                    case .advanced:
                        advancedFields
                    case .scope:
                        EmptyView()
                    }
                }
                .formStyle(.grouped)

                SettingsPolicyFooter(monitor: monitor, editor: editor)
            }
        }
    }

    private var automaticWriteBlock: SettingsPolicyEditor.AutomaticWriteBlock? {
        editor.automaticWriteBlock(settings: settings)
    }

    @ViewBuilder
    private var globalStatus: some View {
        let paused = !settings.automationGloballyEnabled
        if paused || (page == .checkpoints && settings.configuredAutomationAvailable && settings.automaticActionsAllowed) {
            HStack(spacing: 12) {
                Label {
                    Text(paused ? .AutomationProfiles.globallyPaused : .AutomationProfiles.globallyEnabled)
                } icon: {
                    Image(systemName: paused ? "pause.fill" : "play.fill")
                }
                .fontWeight(.medium)
                Spacer()
                if settings.configuredAutomationAvailable {
                    Button {
                        monitor.requestGlobalAutomationToggle(confirm: confirmGlobalAutomationChange)
                    } label: {
                        Text(paused ? .CommandCenter.commandCenterAutomationSuspendedResume
                            : .CommandCenter.commandCenterAutomationConfirmPauseAction)
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(paused ? Color.orange.opacity(0.1) : Color.secondary.opacity(0.06))
        }
        PersistenceDegradedBanner(settings: settings)
    }

    @ViewBuilder
    private var reviewFields: some View {
        Section {
            effectToggle($editor.draft.reviewRequested.isEnabled, .AutomationProfiles.handleReviewRequests,
                         effect: editor.draft.reviewRequested.runner == .assistant ? .agent : nil)
                .disabled(!editor.draft.hasAutomaticActionConsent || editor.draft.reviewRequested.runner == .shell)
            checkpointToggle($editor.draft.startNewReviewsAutomatically, .Settings.settingsAutomationStartNewReviews,
                             help: .Settings.settingsAutomationStartNewReviewsHelp, reset: .startNewReviews, effect: .agent)
                .disabled(!editor.draft.hasAutomaticActionConsent || !editor.draft.reviewRequested.isEnabled
                    || editor.draft.reviewRequested.runner != .assistant)
            Text(.Settings.settingsAutomationStartNewReviewsHelp).font(.caption).foregroundStyle(.secondary)
            AutomationRuleTemplateSettings(rule: $editor.draft.reviewRequested)
        } header: { Text(.AutomationProfiles.reviewRequestsSection) }

        Section {
            Group {
                HStack {
                    automaticActionPicker($editor.draft.autoApproveMode, .Settings.settingsAutomationCheckpointAutoApprove)
                        .help(Text(.Settings.settingsAutomationCheckpointAutoApproveHelp))
                    AutomationDefaultsResetButton(preset: editor.draft.baselinePreset) {
                        editor.draft.resetCheckpoint(.approval, to: $0)
                    }
                }
                if editor.draft.autoApproveMode == .prompt {
                    actionPromptEditor($editor.draft.autoApprovePrompt.criteria, .Settings.settingsAutomationApprovalPrompt)
                }
            }
            .disabled(!editor.draft.hasAutomaticActionConsent)
            Picker(selection: $editor.draft.autoApprovalThreshold) {
                Text(.Settings.settingsAutomationApprovalNoMajorIssues).tag(AutoApprovalThreshold.noMajorIssues)
                Text(.Settings.settingsAutomationApprovalNoCodeIssues).tag(AutoApprovalThreshold.noCodeIssues)
                Text(.Settings.settingsAutomationApprovalNoIssues).tag(AutoApprovalThreshold.noIssues)
            } label: {
                Text(.Settings.settingsAutomationApprovalThreshold)
            }
            .help(Text(.Settings.settingsAutomationApprovalThresholdHelp))
            .disabled(!editor.draft.hasAutomaticActionConsent)
            checkpointToggle($editor.draft.autoResolveOwnReviewThreads, .Settings.settingsAutomationResolveOwnReviewThreads,
                             help: .Settings.settingsAutomationResolveOwnReviewThreadsHelp, reset: .ownThreadResolution)
            if settings.automaticActionsAllowed, editor.draft.permitsOwnThreadResolution(manual: true),
               automaticWriteBlock != nil {
                Text(.AutomationProfiles.manualJobsCanResolveThreads).font(.caption).foregroundStyle(.secondary)
            }
            Toggle(isOn: $editor.draft.reviewRequested.markDoneOnSuccess) {
                Text(.AutomationProfiles.reviewHandlerAcknowledgement)
            }
            .toggleStyle(.checkbox)
            .disabled(!editor.draft.hasAutomaticActionConsent)
        } header: { Text(.AutomationProfiles.reviewerActionsSection) }
        footer: { automaticWriteNote }
    }

    @ViewBuilder
    private var feedbackFields: some View {
        Section {
            effectToggle($editor.draft.authorFeedback.isEnabled, .AutomationProfiles.handleAuthorFeedback,
                         effect: editor.draft.authorFeedback.runner == .assistant ? .agent : nil)
                .disabled(!editor.draft.hasAutomaticActionConsent || editor.draft.authorFeedback.runner == .shell)
            AutomationRuleTemplateSettings(rule: $editor.draft.authorFeedback)
            checkpointToggle($editor.draft.allowFollowUpPush, .Settings.settingsAutomationFollowUpPush,
                             help: .Settings.settingsAutomationFollowUpPushHelp, reset: .followUpPush)
            if settings.automaticActionsAllowed, editor.draft.permitsFollowUpPush(manual: true), automaticWriteBlock != nil {
                Text(.AutomationProfiles.manualJobsCanPush).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(.Settings.settingsAutomationFollowUpPushHelp).font(.caption).foregroundStyle(.secondary)
            }
            Toggle(isOn: $editor.draft.authorFeedback.markDoneOnSuccess) {
                Text(.AutomationProfiles.feedbackHandlerAcknowledgement)
            }
            .toggleStyle(.checkbox)
            .disabled(!editor.draft.hasAutomaticActionConsent)
        } header: { Text(.AutomationProfiles.authorFeedbackSection) }
        footer: { automaticWriteNote }

        Section {
            Group {
                effectToggle(Binding(get: { editor.draft.autoVerifyReReview }, set: { enabled in
                    if enabled, let assistant = editor.draft.selectedAssistant,
                       assistant == settings.acceptedAutomation.selectedAssistant { needsVerificationSetup = true }
                    else { editor.draft.autoVerifyReReview = enabled }
                }), .Settings.settingsVerificationEnabled, effect: .aiCheck)
                Text(.Settings.settingsVerificationHelp).font(.caption).foregroundStyle(.secondary)
                Toggle(isOn: $editor.draft.autoReReviewEnabled) {
                    Text(.Settings.settingsAutomationAutoReReviewToggle)
                }
                .toggleStyle(.checkbox)
                Text(.Settings.settingsAutomationAutoReReviewHelp).font(.caption).foregroundStyle(.secondary)
                checkpointToggle($editor.draft.autoResolveAcceptedFeedback, .AuthorFeedback.authorFeedbackSetting,
                                 help: .AuthorFeedback.authorFeedbackSettingHelp, reset: .acceptedFeedbackResolution)
            }
            .disabled(!editor.draft.hasAutomaticActionConsent)
        } header: { Text(.AutomationProfiles.authorReviewCompletionSection) }
        footer: { automaticWriteNote }
    }

    @ViewBuilder
    private var automaticWriteNote: some View {
        if let automaticWriteBlock {
            Text(automaticWriteBlock.message).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var publicationFields: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top) {
                        Picker(selection: $editor.draft.publicationMode) {
                            ForEach(AutomationPublicationMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        } label: { Text(.Settings.settingsAutomationPublicationTitle) }
                        Spacer()
                        AutomationDefaultsResetButton(preset: editor.draft.baselinePreset) { editor.draft.resetPublication(to: $0) }
                    }
                    Text(editor.draft.publicationMode == .all ? .PublicationPolicy.publicationAutomaticAllHelp : editor.draft.publicationMode.explanation)
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text(.Settings.settingsAutomationPublicationTitle) }
            footer: { automaticWriteNote }
            PublicationRestrictionsSettingsView(restrictions: $editor.draft.publicationRestrictions,
                mode: editor.draft.publicationMode, glab: monitor.glab, preset: editor.draft.baselinePreset)
        }
        .disabled(!editor.draft.hasAutomaticActionConsent)
    }

    private var conflictFields: some View {
        Section {
            effectToggle($editor.draft.conflictTasksEnabled, .Settings.settingsAutomationConflictsToggle, effect: .agent)
                .disabled(!editor.draft.hasAutomaticActionConsent)
            Toggle(isOn: $editor.draft.allowConflictPush) {
                Text(.Settings.settingsAutomationConflictsAllowPush)
            }
            .toggleStyle(.checkbox)
            .disabled(!editor.draft.allowAssistantTools)
            if !editor.draft.allowAssistantTools {
                Text(.AutomationProfiles.conflictPushNeedsProjectPermission).font(.caption).foregroundStyle(.secondary)
            } else if settings.automaticActionsAllowed && editor.draft.allowConflictPush
                && editor.draft.packageDecision != .undecided
                && (automaticWriteBlock != nil || !editor.draft.conflictTasksEnabled) {
                Text(.AutomationProfiles.manualConflictJobsCanPush).font(.caption).foregroundStyle(.secondary)
            }
            if editor.draft.allowConflictPush || !editor.draft.conflictPushProjects.isEmpty {
                TextField(text: $editor.draft.conflictPushProjects) {
                    Text(.Settings.settingsAutomationConflictsPushProjects)
                }
                .autocorrectionDisabled()
                .disabled(!editor.draft.allowAssistantTools || !editor.draft.allowConflictPush)
            }
            Divider()
            Toggle(isOn: $editor.draft.allowAssistantTools) {
                Text(.Settings.settingsAutomationAssistantTools)
            }
            .toggleStyle(.checkbox)

            if editor.draft.allowAssistantTools || !editor.draft.assistantToolProjects.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TextField(text: $editor.draft.assistantToolProjects) {
                    Text(.Settings.settingsAutomationToolProjects)
                }
                .autocorrectionDisabled()
                .disabled(!editor.draft.allowAssistantTools)
            }
            Text(.Settings.settingsAutomationAssistantToolsHelp).font(.caption).foregroundStyle(.secondary)
            Text(.Settings.settingsAutomationAuthoredMergeRequestsProjectsHelp).font(.caption).foregroundStyle(.secondary)
        } header: { Text(.AutomationProfiles.conflictSection) }
        footer: { automaticWriteNote }
    }

    private var mergeFields: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                automaticActionPicker($editor.draft.autoMergeMode, .Settings.settingsAutomationAutoMergeToggle)

                if editor.draft.autoMergeMode == .prompt {
                    actionPromptEditor($editor.draft.autoMergePrompt.criteria, .Settings.settingsAutomationMergePrompt)
                }
                Toggle(isOn: $editor.draft.autoMergeAuthorOnly) {
                    Text(.Settings.settingsAutomationMergeAuthorOnly)
                }
                .toggleStyle(.checkbox)
                .help(Text(.Settings.settingsAutomationMergeAuthorOnlyHelp))

                Text(.Settings.settingsAutomationAutoMergeHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if editor.draft.autoMergeEnabled {
                    Toggle(isOn: $editor.draft.autoMergeWithOtherAssignees) {
                        Text(.Settings.settingsAutomationAutoMergeWithOtherAssignees)
                    }
                    .toggleStyle(.checkbox)
                    TextField(text: $editor.draft.autoMergeProjects) {
                        Text(.Settings.settingsAutomationAutoMergeProjects)
                    }
                    .autocorrectionDisabled()
                }
            }

        } header: { Text(.AutomationProfiles.mergeSection) }
        footer: {
            VStack(alignment: .leading, spacing: 4) {
                automaticWriteNote
                if editor.draft.autoMergeEnabled { Text(.Settings.settingsAutomationAuthoredMergeRequestsProjectsHelp) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!editor.draft.hasAutomaticActionConsent)
    }

    private func automaticActionPicker(_ mode: Binding<AutomaticActionMode>, _ title: LocalizedStringResource) -> some View {
        Picker(selection: mode) {
            Text(.Settings.settingsAutomationActionOff).tag(AutomaticActionMode.off)
            Text(.Settings.settingsAutomationActionOn).tag(AutomaticActionMode.on)
            Text(.Settings.settingsAutomationActionByPrompt).tag(AutomaticActionMode.prompt)
        } label: { Text(title) }
        .pickerStyle(.segmented)
    }

    private func actionPromptEditor(_ criteria: Binding<String>, _ title: LocalizedStringResource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(text: criteria, axis: .vertical) { Text(title) }
                .lineLimit(3...8)
            Text(.Settings.settingsAutomationActionPromptHelp).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func effectToggle(_ isOn: Binding<Bool>, _ title: LocalizedStringResource,
                              effect: MRActionEffect?, detail: LocalizedStringResource? = nil) -> some View {
        let help = [effect?.actionDescription, detail].compactMap { $0 }
            .map { String(localized: $0) }.joined(separator: "\n")
        return Toggle(isOn: isOn) {
            HStack(spacing: 4) {
                Text(title)
                if effect == .agent || effect == .aiCheck {
                    CodingProviderIcon().foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .help(help)
        .accessibilityHint(help)
    }

    private func checkpointToggle(
        _ isOn: Binding<Bool>, _ title: LocalizedStringResource, help: LocalizedStringResource,
        reset: AutomationCheckpoint? = nil, effect: MRActionEffect? = nil
    ) -> some View {
        HStack {
            effectToggle(isOn, title, effect: effect, detail: help)
            if let reset {
                Spacer()
                AutomationDefaultsResetButton(preset: editor.draft.baselinePreset) {
                    editor.draft.resetCheckpoint(reset, to: $0)
                }
            }
        }
    }

    @ViewBuilder
    private var packageFields: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                AutomationSettingsProfilePicker(draft: $editor.draft, lastCustom: $editor.sessionCustom,
                    canUseAutomatic: editor.draft.selectedAssistant.map(monitor.availableAssistants.contains) ?? true)
                    .controlSize(.large)
                if let preset = editor.draft.matchingPreset {
                    AutomationPresetDescription(preset: preset)
                } else if editor.draft.packageDecision == .undecided {
                    Text(.AutomationProfiles.chooseHelp).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(.AutomationProfiles.customizedTitle).font(.caption.weight(.semibold))
                    AutomationCustomProfileDescription(configuration: editor.draft)
                    Text(editor.draft.baselinePreset == .checkpoints ? .AutomationProfiles.legacyHelp : .AutomationProfiles.customizedHelp)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if settings.automationProfileHistory.failure == .read {
                    Text(.AutomationProfiles.historyReadFailed).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            Toggle(isOn: Binding(get: { editor.draft.packageDecision == .enabled }, set: { editor.draft.packageDecision = $0 ? .enabled : .disabled })) {
                Text(.AutomationProfiles.enableProfileRules)
            }
            .toggleStyle(.checkbox)
            if !editor.draft.hasAutomaticActionConsent {
                Text(.AutomationProfiles.enableFirst).font(.caption).foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(get: { !editor.draft.allowAutomaticPublicActions }, set: { editor.draft.allowAutomaticPublicActions = !$0 })) {
                Text(.AutomationProfiles.privateToggle)
            }
            .toggleStyle(.checkbox)
            .disabled(!editor.draft.hasAutomaticActionConsent)
            Text(.AutomationProfiles.privateHelp).font(.caption).foregroundStyle(.secondary)

            Toggle(isOn: $editor.draft.requiresAssignmentClaim) {
                Text(.Settings.settingsAutomationRequireAssignmentClaim)
            }
            .toggleStyle(.checkbox)
            .disabled(!editor.draft.hasAutomaticActionConsent)
            Text(.Settings.settingsAutomationRequireAssignmentClaimHelp).font(.caption).foregroundStyle(.secondary)
        } header: { Text(.AutomationProfiles.profileRulesSection) }

        Section {
            Text(.AutomationProfiles.scopeOverview).font(.caption).foregroundStyle(.secondary)
            Button {
                page = .scope
            } label: { Text(.AutomationProfiles.openScope) }
        } header: { Text(.Settings.settingsAutomationPageScope) }
    }

    @ViewBuilder
    private var advancedFields: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.confirmGlobalAutomationChanges },
                set: { enabled in
                    settings.confirmGlobalAutomationChanges = enabled
                    settings.save()
                }
            )) {
                Text(.CommandCenter.commandCenterAutomationConfirmPreference)
            }
            .toggleStyle(.checkbox)
        } header: {
            Text(.CommandCenter.commandCenterAutomationToggle)
        } footer: {
            Text(.AutomationProfiles.savesImmediately)
        }
        ReviewParticipationSettingsSection(monitor: monitor)
        Section {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text(.PublicationPolicy.publicationAiCommentCriteriaHelp)
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $editor.draft.aiCommentCriteria)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 210)
                        .accessibilityLabel(Text(.PublicationPolicy.publicationAiCommentCriteria))
                    Button {
                        editor.draft.aiCommentCriteria = AICommentOriginAssessor.criteriaInstructions
                    } label: {
                        Text(.PublicationPolicy.publicationRestoreAICommentCriteria)
                    }
                    .disabled(editor.draft.aiCommentCriteria == AICommentOriginAssessor.criteriaInstructions)
                }
            } label: {
                Text(.PublicationPolicy.publicationAiCommentCriteria)
            }
        }
        Section {
            HStack {
                TextField(text: $editor.draft.assistantWorkspace) {
                    Text(.Settings.settingsAutomationWorkspace)
                }
                .autocorrectionDisabled()
                Button {
                    isChoosingWorkspace = true
                } label: {
                    Text(.Settings.settingsAutomationWorkspaceChoose)
                }
            }
            .fileImporter(isPresented: $isChoosingWorkspace, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { editor.draft.assistantWorkspace = url.path }
            }
        } footer: {
            Text(.Settings.settingsAutomationWorkspaceHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    enum Page: CaseIterable {
        case checkpoints, scope, todos, workflow, publication, advanced

        var symbol: String {
            switch self {
            case .checkpoints: "hand.raised"
            case .scope: "scope"
            case .todos: "tray"
            case .workflow: "play.fill"
            case .publication: "arrow.up.forward"
            case .advanced: "slider.horizontal.3"
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .checkpoints: .Settings.settingsAutomationPageCheckpoints
            case .scope: .Settings.settingsAutomationPageScope
            case .workflow: .Settings.settingsAutomationPageWorkflow
            case .publication: .AutomationProfiles.publicationPage
            case .todos: .EffectivePolicy.settingsPreparationRules
            case .advanced: .Settings.settingsAutomationPageAdvanced
            }
        }
    }

}

@MainActor
func confirmGlobalAutomationChange(enabling: Bool) -> TodoMonitorService.GlobalAutomationConfirmation {
    let alert = NSAlert()
    alert.alertStyle = enabling ? .informational : .warning
    alert.messageText = String(localized: enabling ? .CommandCenter.commandCenterAutomationConfirmResumeTitle
        : .CommandCenter.commandCenterAutomationConfirmPauseTitle)
    alert.informativeText = String(localized: enabling ? .CommandCenter.commandCenterAutomationConfirmResumeMessage
        : .CommandCenter.commandCenterAutomationConfirmPauseMessage)
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = String(localized: .CommandCenter.commandCenterAutomationConfirmDontAskAgain)
    let cancel = alert.addButton(withTitle: String(localized: .Menu.menuScopeCancel))
    cancel.keyEquivalent = "\r"
    alert.addButton(withTitle: String(localized: enabling ? .CommandCenter.commandCenterAutomationSuspendedResume
        : .CommandCenter.commandCenterAutomationConfirmPauseAction))
    guard alert.runModal() == .alertSecondButtonReturn else { return .cancel }
    return alert.suppressionButton?.state == .on ? .confirmAndSkipFuturePrompts : .confirm
}

struct AutomationRuleTemplateSettings: View {
    @Binding var rule: AutomationRule

    var body: some View {
        if rule.runner == .shell {
            Picker(selection: $rule.runner) {
                Text(.Settings.settingsAutomationRunnerAssistant).tag(AutomationRunner.assistant)
                Text(.Settings.settingsAutomationRunnerShell).tag(AutomationRunner.shell)
            } label: { Text(.Settings.settingsAutomationRunner) }
            Text(.Settings.settingsAutomationRunnerLegacyHelp).font(.caption).foregroundStyle(.orange)
        }
        DisclosureGroup {
            TextField(text: $rule.projects) { Text(.Settings.settingsAutomationTodoProjects) }
                .autocorrectionDisabled()
            Text(.Settings.settingsAutomationTodoProjectsHelp).font(.caption).foregroundStyle(.secondary)
            Divider()
            TextField(text: $rule.titleTemplate) { Text(.Settings.settingsAutomationTitle) }
                .autocorrectionDisabled()
            if rule.runner == .shell {
                Text(rule.isEnabled ? .EffectivePolicy.settingsLegacyEnabled : .EffectivePolicy.settingsLegacyDisabled)
                    .font(.caption).foregroundStyle(.orange)
                Text(.Settings.settingsAutomationCommand).font(.caption.weight(.semibold))
                Text(verbatim: rule.command)
                    .font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(text: $rule.promptTemplate, axis: .vertical) { Text(.Settings.settingsAutomationPrompt) }
                    .lineLimit(5...8)
            }
            Text(.Settings.settingsAutomationTemplateHelp).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        } label: {
            Text(.AutomationProfiles.ruleDetails)
        }
    }
}
