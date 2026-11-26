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

    func updateScope(from settings: SettingsManager) {
        draft.scope = settings.automation.ignoringGlobalSuspension.scope
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
            .disabled(!editor.saveState.canApply(draft: editor.draft, custom: editor.sessionCustom,
                savedCustom: monitor.settings.automationProfileHistory.lastGood) || editor.hasIncompleteRule
                || editor.draft.workerExecutionTimeout.hasInvalidOverrides)
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
}

struct AutomationSettingsTab: View {
    let monitor: TodoMonitorService
    private var settings: SettingsManager { monitor.settings }

    @Bindable private var editor: SettingsPolicyEditor
    @State private var trigger: Trigger = .reviewRequested
    @State private var page: Page = .checkpoints
    @State private var isChoosingWorkspace = false
    @State private var needsVerificationSetup = false

    init(monitor: TodoMonitorService, initialPage: Page = .checkpoints, editor: SettingsPolicyEditor? = nil) {
        self.monitor = monitor
        _page = State(initialValue: initialPage)
        self.editor = editor ?? SettingsPolicyEditor(settings: monitor.settings)
    }

    var body: some View {
        // Keep detailed automation controls readable in the sidebar.
        HStack(spacing: 0) {
            List(selection: $page) {
                ForEach(Page.allCases.filter { $0 != .scope || settings.configuredAutomation.hasEnabledAutomation }, id: \.self) { page in
                    Label { Text(page.title) } icon: { Image(systemName: page.symbol) }
                        .tag(page)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 170)

            Divider()

            pageContent
        }
        .onChange(of: settings.configuredAutomation.hasEnabledAutomation) { _, enabled in
            if !enabled, page == .scope { page = .checkpoints }
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
            if page == .scope {
                AutomationScopeSettingsView(monitor: monitor)
            } else {
                Form {
                    switch page {
                    case .checkpoints:
                        packageFields
                        checkpointFields
                    case .workflow:
                        MergeWorkflowSettingsSection(rules: $editor.draft.workflowRules)
                    case .todos:
                        todoFields
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

    private var rule: Binding<AutomationRule> {
        switch trigger {
        case .reviewRequested: $editor.draft.reviewRequested
        case .authorFeedback: $editor.draft.authorFeedback
        }
    }

    private var checkpointFields: some View {
        Group {
            Group {
                preparationFields
                MergeWorkflowPermissionSettingsSection(rules: $editor.draft.workflowRules,
                    infrastructureRetryAvailable: editor.draft.canConfigureInfrastructureRetry)
                publicationFields
            }
            .disabled(!editor.draft.hasAutomaticActionConsent)
            // Job permissions also govern jobs the user starts, so they stay editable in Manual.
            deliveryFields
            completionFields.disabled(!editor.draft.hasAutomaticActionConsent)
        }
    }

    private var preparationFields: some View {
        Section {
            effectToggle($editor.draft.reviewRequested.isEnabled, .Settings.settingsAutomationReviewRequested,
                         effect: editor.draft.reviewRequested.runner == .assistant ? .agent : nil)
                .disabled(editor.draft.reviewRequested.runner == .shell)
            checkpointToggle($editor.draft.startNewReviewsAutomatically, .Settings.settingsAutomationStartNewReviews,
                             help: .Settings.settingsAutomationStartNewReviewsHelp, reset: .startNewReviews, effect: .agent)
                .disabled(!editor.draft.reviewRequested.isEnabled || editor.draft.reviewRequested.runner != .assistant)
            Text(.Settings.settingsAutomationStartNewReviewsHelp).font(.caption).foregroundStyle(.secondary)
            effectToggle($editor.draft.authorFeedback.isEnabled, .Settings.settingsAutomationAuthorFeedback,
                         effect: editor.draft.authorFeedback.runner == .assistant ? .agent : nil)
                .disabled(editor.draft.authorFeedback.runner == .shell)
            effectToggle(Binding(get: { editor.draft.autoVerifyReReview }, set: { enabled in
                if enabled, let assistant = editor.draft.selectedAssistant,
                   assistant == settings.acceptedAutomation.selectedAssistant { needsVerificationSetup = true }
                else { editor.draft.autoVerifyReReview = enabled }
            }), .Settings.settingsVerificationEnabled, effect: .aiCheck)
            Text(.Settings.settingsVerificationHelp).font(.caption).foregroundStyle(.secondary)
            checkpointToggle($editor.draft.autoClaimPipelineFailures, .Settings.settingsAutomationPipelineOwnership,
                             help: .Settings.settingsAutomationPipelineOwnershipHelp, reset: .pipelineOwnership, effect: .agent)
            VStack(alignment: .leading, spacing: 4) {
                effectToggle($editor.draft.conflictTasksEnabled, .Settings.settingsAutomationConflictsToggle, effect: .agent)

                Text(.EffectivePolicy.settingsConflictsHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: { Text(.EffectivePolicy.settingsPreparation) }
        footer: { Text(.Settings.settingsAutomationAuthoredMergeRequestsPolling).font(.caption).foregroundStyle(.secondary) }
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
            PublicationRestrictionsSettingsView(restrictions: $editor.draft.publicationRestrictions,
                mode: editor.draft.publicationMode, glab: monitor.glab, settings: monitor.settings, preset: editor.draft.baselinePreset)
        }
    }

    private var deliveryFields: some View {
        Section {
            checkpointToggle($editor.draft.allowFollowUpPush, .Settings.settingsAutomationFollowUpPush,
                             help: .Settings.settingsAutomationFollowUpPushHelp, reset: .followUpPush)
            Text(.EffectivePolicy.settingsIndependentPush).font(.caption).foregroundStyle(.secondary)
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
            Toggle(isOn: $editor.draft.allowConflictPush) {
                Text(.Settings.settingsAutomationConflictsAllowPush)
            }
            .toggleStyle(.checkbox)
            .disabled(!editor.draft.allowAssistantTools)

            if !editor.draft.allowAssistantTools || !editor.draft.conflictTasksEnabled {
                Text(.EffectivePolicy.settingsConflictPushPrerequisites).font(.caption).foregroundStyle(.secondary)
            }
            if editor.draft.allowConflictPush || !editor.draft.conflictPushProjects.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TextField(text: $editor.draft.conflictPushProjects) {
                    Text(.Settings.settingsAutomationConflictsPushProjects)
                }
                .autocorrectionDisabled()
                .disabled(!editor.draft.allowAssistantTools || !editor.draft.allowConflictPush)
            }
            Divider()
            checkpointToggle($editor.draft.autoResolveOwnReviewThreads, .Settings.settingsAutomationResolveOwnReviewThreads,
                             help: .Settings.settingsAutomationResolveOwnReviewThreadsHelp, reset: .ownThreadResolution)
            Text(.EffectivePolicy.settingsJobPermissions).font(.caption).foregroundStyle(.secondary)
        } header: { Text(.EffectivePolicy.settingsDelivery) }
        footer: {
            Text(.Settings.settingsAutomationAuthoredMergeRequestsProjectsHelp).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var completionFields: some View {
        Section {
            checkpointToggle($editor.draft.autoApproveEnabled, .Settings.settingsAutomationCheckpointAutoApprove,
                             help: .Settings.settingsAutomationCheckpointAutoApproveHelp, reset: .approval)
            Picker(selection: $editor.draft.autoApprovalThreshold) {
                Text(.Settings.settingsAutomationApprovalNoMajorIssues).tag(AutoApprovalThreshold.noMajorIssues)
                Text(.Settings.settingsAutomationApprovalNoCodeIssues).tag(AutoApprovalThreshold.noCodeIssues)
                Text(.Settings.settingsAutomationApprovalNoIssues).tag(AutoApprovalThreshold.noIssues)
            } label: {
                Text(.Settings.settingsAutomationApprovalThreshold)
            }
            .help(Text(.Settings.settingsAutomationApprovalThresholdHelp))
            checkpointToggle($editor.draft.autoResolveAcceptedFeedback, .AuthorFeedback.authorFeedbackSetting,
                             help: .AuthorFeedback.authorFeedbackSettingHelp, reset: .acceptedFeedbackResolution)
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $editor.draft.autoReReviewEnabled) {
                    Text(.Settings.settingsAutomationAutoReReviewToggle)
                }
                .toggleStyle(.checkbox)

                Text(.Settings.settingsAutomationAutoReReviewHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $editor.draft.autoMergeEnabled) {
                    Text(.Settings.settingsAutomationAutoMergeToggle)
                }
                .toggleStyle(.checkbox)

                Text(.Settings.settingsAutomationAutoMergeHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if editor.draft.autoMergeEnabled {
                    TextField(text: $editor.draft.autoMergeProjects) {
                        Text(.Settings.settingsAutomationAutoMergeProjects)
                    }
                    .autocorrectionDisabled()
                }
            }

            DisclosureGroup {
                Toggle(isOn: $editor.draft.reviewRequested.markDoneOnSuccess) { Text(.AutomationProfiles.reviewHandlerAcknowledgement) }
                    .toggleStyle(.checkbox)
                Toggle(isOn: $editor.draft.authorFeedback.markDoneOnSuccess) { Text(.AutomationProfiles.feedbackHandlerAcknowledgement) }
                    .toggleStyle(.checkbox)
                Text(.AutomationProfiles.handlerAcknowledgementHelp).font(.caption).foregroundStyle(.secondary)
            } label: { Text(.AutomationProfiles.handlerAcknowledgements) }

        } header: { Text(.EffectivePolicy.settingsCompletion) }
        footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(.Settings.settingsAutomationProfilePermissionsHelp)
                if editor.draft.autoMergeEnabled { Text(.Settings.settingsAutomationAuthoredMergeRequestsProjectsHelp) }
            }.font(.caption).foregroundStyle(.secondary)
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
                Text(.Settings.settingsAutomationPackageTitle).font(.headline)
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
            PersistenceDegradedBanner(settings: settings)
            Toggle(isOn: Binding(get: { editor.draft.packageDecision == .enabled }, set: { editor.draft.packageDecision = $0 ? .enabled : .disabled })) {
                Text(.AutomationProfiles.automationEnabled)
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
        }
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
        } header: {
            Text(.CommandCenter.commandCenterAutomationToggle)
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
        Section {
            Text(.EffectivePolicy.settingsAdvancedRulesWarning).font(.caption).foregroundStyle(.secondary)
        }
        AutomationRuleTemplateSettings(rule: $editor.draft.reviewRequested, title: .Settings.settingsAutomationReviewRequested)
        AutomationRuleTemplateSettings(rule: $editor.draft.authorFeedback, title: .Settings.settingsAutomationAuthorFeedback)
    }

    private var todoFields: some View {
        Section {
            Picker(selection: $trigger) {
                Text(.Settings.settingsAutomationReviewRequested)
                    .tag(Trigger.reviewRequested)
                Text(.Settings.settingsAutomationAuthorFeedback)
                    .tag(Trigger.authorFeedback)
            } label: {
                Text(.Settings.settingsAutomationTrigger)
            }

            Text(.AutomationProfiles.permissionsLocation).font(.caption).foregroundStyle(.secondary)

            Picker(selection: rule.runner) {
                Text(.Settings.settingsAutomationRunnerAssistant)
                    .tag(AutomationRunner.assistant)
                if rule.wrappedValue.runner == .shell {
                    Text(.Settings.settingsAutomationRunnerShell).tag(AutomationRunner.shell)
                }
            } label: {
                Text(.Settings.settingsAutomationRunner)
            }

            TextField(text: rule.projects) {
                Text(.Settings.settingsAutomationTodoProjects)
            }
            .autocorrectionDisabled()

            if rule.wrappedValue.runner == .shell {
                Text(.Settings.settingsAutomationRunnerLegacyHelp)
                    .font(.caption).foregroundStyle(.orange)
                Text(.EffectivePolicy.settingsLegacyLocation).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(.EffectivePolicy.settingsTemplatesLocation).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(.Settings.settingsAutomationTodoSection)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(trigger.description)
                Text(.Settings.settingsAutomationOutcome)
                Text(.Settings.settingsAutomationTodoProjectsHelp)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    enum Page: CaseIterable {
        case checkpoints, scope, todos, workflow, advanced

        var symbol: String {
            switch self {
            case .checkpoints: "hand.raised"
            case .scope: "scope"
            case .todos: "tray"
            case .workflow: "bolt"
            case .advanced: "slider.horizontal.3"
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .checkpoints: .Settings.settingsAutomationPageCheckpoints
            case .scope: .Settings.settingsAutomationPageScope
            case .workflow: .Settings.settingsAutomationPageWorkflow
            case .todos: .EffectivePolicy.settingsPreparationRules
            case .advanced: .Settings.settingsAutomationPageAdvanced
            }
        }
    }

    private enum Trigger: Hashable {
        case reviewRequested
        case authorFeedback

        var description: LocalizedStringResource {
            switch self {
            case .reviewRequested: .Settings.settingsAutomationReviewRequestedDescription
            case .authorFeedback: .Settings.settingsAutomationAuthorFeedbackDescription
            }
        }
    }
}

/// Editing retained templates never changes the rule's runner or its enablement.
struct AutomationRuleTemplateSettings: View {
    @Binding var rule: AutomationRule
    let title: LocalizedStringResource

    var body: some View {
        Section {
            if rule.runner == .shell {
                Text(rule.isEnabled ? .EffectivePolicy.settingsLegacyEnabled : .EffectivePolicy.settingsLegacyDisabled)
                    .font(.caption).foregroundStyle(.orange)
                Text(.Settings.settingsAutomationCommand).font(.caption.weight(.semibold))
                Text(verbatim: rule.command)
                    .font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(.Settings.settingsAutomationRunnerLegacyHelp).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(rule.isEnabled ? .EffectivePolicy.settingsTemplateActive : .EffectivePolicy.settingsTemplateInactive)
                    .font(.caption).foregroundStyle(rule.isEnabled ? Color.orange : Color.secondary)
            }
            TextField(text: $rule.titleTemplate) { Text(.Settings.settingsAutomationTitle) }
                .autocorrectionDisabled()
            if rule.runner == .assistant {
                TextField(text: $rule.promptTemplate, axis: .vertical) { Text(.Settings.settingsAutomationPrompt) }
                    .lineLimit(5...8)
            }
            Text(.Settings.settingsAutomationTemplateHelp).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        } header: {
            Text(rule.runner == .shell ? .EffectivePolicy.settingsLegacyTitle : .EffectivePolicy.settingsTemplateTitle)
                + Text(" · ") + Text(title)
        }
    }
}
