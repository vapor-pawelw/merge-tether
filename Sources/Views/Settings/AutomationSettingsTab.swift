import SwiftUI
import UniformTypeIdentifiers

struct AutomationSettingsTab: View {
    let monitor: TodoMonitorService
    private var settings: SettingsManager { monitor.settings }

    @State private var draft: AutomationSettings
    @State private var trigger: Trigger = .reviewRequested
    @State private var page: Page = .checkpoints
    @State private var isChoosingWorkspace = false
    @State private var setupAction: SetupAction?
    @State private var sessionCustom: AutomationProfileSnapshot?
    @State private var saveState: AutomationSettingsSaveState
    private enum SetupAction: String, Identifiable {
        case enableVerification, apply
        var id: String { rawValue }
    }

    init(monitor: TodoMonitorService, initialPage: Page = .checkpoints) {
        self.monitor = monitor
        _page = State(initialValue: initialPage)
        let accepted = monitor.settings.acceptedAutomation
        _draft = State(initialValue: accepted)
        _saveState = State(initialValue: .init(accepted: accepted, runtimeSavePending: accepted != monitor.settings.automation))
        _sessionCustom = State(initialValue: monitor.settings.automationProfileHistory.available(for: accepted))
    }

    var body: some View {
        // Keep detailed automation controls readable in the sidebar.
        HStack(spacing: 0) {
            List(selection: $page) {
                ForEach(Page.allCases.filter { $0 != .scope || settings.automation.hasEnabledAutomation }, id: \.self) { page in
                    Label { Text(page.title) } icon: { Image(systemName: page.symbol) }
                        .tag(page)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 170)

            Divider()

            pageContent
        }
        .onChange(of: settings.automation.scope) { _, current in
            draft.scope = current
            saveState.updateSavedScope(settings.acceptedAutomation.scope)
        }
        .onChange(of: draft) { _, current in
            if let custom = AutomationProfileSnapshot.custom(from: current) { sessionCustom = custom }
        }
        .onChange(of: settings.automation.hasEnabledAutomation) { _, enabled in
            if !enabled, page == .scope { page = .checkpoints }
        }
        .sheet(item: $setupAction) { action in
            AssistantSetupView(assistant: draft.assistant, requireCLI: true) {
                if action == .enableVerification { draft.autoVerifyReReview = true }
                else { applyDraft() }
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
                    case .assistant:
                        assistantFields
                    case .workflow:
                        MergeWorkflowSettingsSection(rules: $draft.workflowRules)
                    case .todos:
                        todoFields
                    case .advanced:
                        advancedFields
                    case .scope:
                        EmptyView()
                    }
                }
                .formStyle(.grouped)

                Divider()

                HStack(alignment: .center, spacing: 16) {
                    if saveState.failed {
                        Text(.AutomationProfiles.saveFailed).foregroundStyle(.red).font(.caption)
                    } else if hasIncompleteRule {
                        Text(.Settings.settingsAutomationIncomplete)
                            .foregroundStyle(.red)
                            .font(.caption)
                    } else {
                        Text(.Settings.settingsAutomationApplyHelp)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }

                    Spacer(minLength: 0)

                    Button {
                        draft = saveState.revert()
                        sessionCustom = settings.automationProfileHistory.available(for: draft)
                    } label: { Text(.AutomationProfiles.revert) }
                    .disabled(draft == saveState.accepted && sessionCustom == settings.automationProfileHistory.available(for: saveState.accepted) && !saveState.failed)

                    Button {
                        if draft != settings.automation && (draft.usesAssistant || draft.autoReReviewEnabled || draft.autoMergeEnabled
                            || draft.autoApproveEnabled || draft.publishDraftsWithoutConfirmation
                            || draft.publishAIRepliesWithoutConfirmation) { setupAction = .apply }
                        else { applyDraft() }
                    } label: {
                        Text(.Settings.settingsAutomationApply)
                    }
                    .disabled(!saveState.canApply(draft: draft, custom: sessionCustom,
                        savedCustom: settings.automationProfileHistory.lastGood) || hasIncompleteRule)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
    }

    private var rule: Binding<AutomationRule> {
        switch trigger {
        case .reviewRequested: $draft.reviewRequested
        case .authorFeedback: $draft.authorFeedback
        }
    }

    private func applyDraft() {
        let custom = AutomationProfileSnapshot.custom(from: draft) ?? sessionCustom
        saveState.begin()
        settings.automation = draft.preservingScope(from: settings.automation)
        let saved = monitor.applySettings()
        saveState.runtimeSaved(settings.automation, succeeded: saved)
        guard saved else { return }
        if let custom {
            let historySaved = settings.automationProfileHistory.save(custom)
            saveState.historySaved(succeeded: historySaved)
            if historySaved { sessionCustom = custom }
        } else { saveState.historySaved(succeeded: true) }
    }

    private var hasIncompleteRule: Bool {
        [draft.reviewRequested, draft.authorFeedback].contains { $0.isEnabled && !$0.isConfigured }
    }

    private var checkpointFields: some View {
        Group {
            preparationFields
            MergeWorkflowPermissionSettingsSection(rules: $draft.workflowRules)
            publicationFields
            deliveryFields
            completionFields
        }
        .disabled(!draft.hasAutomaticActionConsent)
    }

    private var preparationFields: some View {
        Section {
            Toggle(isOn: $draft.reviewRequested.isEnabled) { Text(.Settings.settingsAutomationReviewRequested) }
                .toggleStyle(.checkbox).disabled(draft.reviewRequested.runner == .shell)
            Toggle(isOn: $draft.authorFeedback.isEnabled) { Text(.Settings.settingsAutomationAuthorFeedback) }
                .toggleStyle(.checkbox).disabled(draft.authorFeedback.runner == .shell)
            Toggle(isOn: Binding(get: { draft.autoVerifyReReview }, set: { enabled in
                if enabled { setupAction = .enableVerification }
                else { draft.autoVerifyReReview = false }
            })) { Text(.Settings.settingsVerificationEnabled) }
                .toggleStyle(.checkbox)
            Text(.Settings.settingsVerificationHelp).font(.caption).foregroundStyle(.secondary)
            checkpointToggle($draft.autoClaimPipelineFailures, .Settings.settingsAutomationPipelineOwnership,
                             help: .Settings.settingsAutomationPipelineOwnershipHelp, reset: .pipelineOwnership)
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $draft.conflictTasksEnabled) {
                    Text(.Settings.settingsAutomationConflictsToggle)
                }
                .toggleStyle(.checkbox)

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
                        Picker(selection: $draft.publicationMode) {
                            ForEach(AutomationPublicationMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        } label: { Text(.Settings.settingsAutomationPublicationTitle) }
                        Spacer()
                        AutomationDefaultsResetButton(preset: draft.baselinePreset) { draft.resetPublication(to: $0) }
                    }
                    Text(draft.publicationMode == .all ? .PublicationPolicy.publicationAutomaticAllHelp : draft.publicationMode.explanation)
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text(.Settings.settingsAutomationPublicationTitle) }
            PublicationRestrictionsSettingsView(restrictions: $draft.publicationRestrictions,
                mode: draft.publicationMode, glab: monitor.glab, preset: draft.baselinePreset)
        }
    }

    private var deliveryFields: some View {
        Section {
            checkpointToggle($draft.allowFollowUpPush, .Settings.settingsAutomationFollowUpPush,
                             help: .Settings.settingsAutomationFollowUpPushHelp, reset: .followUpPush)
            Text(.EffectivePolicy.settingsIndependentPush).font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle(isOn: $draft.allowAssistantTools) {
                Text(.Settings.settingsAutomationAssistantTools)
            }
            .toggleStyle(.checkbox)

            if draft.allowAssistantTools || !draft.assistantToolProjects.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TextField(text: $draft.assistantToolProjects) {
                    Text(.Settings.settingsAutomationToolProjects)
                }
                .autocorrectionDisabled()
                .disabled(!draft.allowAssistantTools)
            }
            Text(.Settings.settingsAutomationAssistantToolsHelp).font(.caption).foregroundStyle(.secondary)
            Toggle(isOn: $draft.allowConflictPush) {
                Text(.Settings.settingsAutomationConflictsAllowPush)
            }
            .toggleStyle(.checkbox)
            .disabled(!draft.conflictTasksEnabled || !draft.allowAssistantTools)

            if !draft.conflictTasksEnabled || !draft.allowAssistantTools {
                Text(.EffectivePolicy.settingsConflictPushPrerequisites).font(.caption).foregroundStyle(.secondary)
            }
            if draft.allowConflictPush || !draft.conflictPushProjects.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TextField(text: $draft.conflictPushProjects) {
                    Text(.Settings.settingsAutomationConflictsPushProjects)
                }
                .autocorrectionDisabled()
                .disabled(!draft.conflictTasksEnabled || !draft.allowAssistantTools || !draft.allowConflictPush)
            }
        } header: { Text(.EffectivePolicy.settingsDelivery) }
        footer: {
            Text(.Settings.settingsAutomationAuthoredMergeRequestsProjectsHelp).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var completionFields: some View {
        Section {
            checkpointToggle($draft.autoApproveEnabled, .Settings.settingsAutomationCheckpointAutoApprove,
                             help: .Settings.settingsAutomationCheckpointAutoApproveHelp, reset: .approval)
            checkpointToggle($draft.autoResolveOwnReviewThreads, .Settings.settingsAutomationResolveOwnReviewThreads,
                             help: .Settings.settingsAutomationResolveOwnReviewThreadsHelp, reset: .ownThreadResolution)
            checkpointToggle($draft.autoResolveAcceptedFeedback, .AuthorFeedback.authorFeedbackSetting,
                             help: .AuthorFeedback.authorFeedbackSettingHelp, reset: .acceptedFeedbackResolution)
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $draft.autoReReviewEnabled) {
                    Text(.Settings.settingsAutomationAutoReReviewToggle)
                }
                .toggleStyle(.checkbox)

                Text(.Settings.settingsAutomationAutoReReviewHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $draft.autoMergeEnabled) {
                    Text(.Settings.settingsAutomationAutoMergeToggle)
                }
                .toggleStyle(.checkbox)

                Text(.Settings.settingsAutomationAutoMergeHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if draft.autoMergeEnabled {
                    TextField(text: $draft.autoMergeProjects) {
                        Text(.Settings.settingsAutomationAutoMergeProjects)
                    }
                    .autocorrectionDisabled()
                }
            }

            DisclosureGroup {
                Toggle(isOn: $draft.reviewRequested.markDoneOnSuccess) { Text(.AutomationProfiles.reviewHandlerAcknowledgement) }
                    .toggleStyle(.checkbox)
                Toggle(isOn: $draft.authorFeedback.markDoneOnSuccess) { Text(.AutomationProfiles.feedbackHandlerAcknowledgement) }
                    .toggleStyle(.checkbox)
                Text(.AutomationProfiles.handlerAcknowledgementHelp).font(.caption).foregroundStyle(.secondary)
            } label: { Text(.AutomationProfiles.handlerAcknowledgements) }

        } header: { Text(.EffectivePolicy.settingsCompletion) }
        footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(.Settings.settingsAutomationProfilePermissionsHelp)
                if draft.autoMergeEnabled { Text(.Settings.settingsAutomationAuthoredMergeRequestsProjectsHelp) }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private func checkpointToggle(
        _ isOn: Binding<Bool>, _ title: LocalizedStringResource, help: LocalizedStringResource,
        reset: AutomationCheckpoint? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Toggle(isOn: isOn) { Text(title) }.toggleStyle(.checkbox)
                if let reset {
                    Spacer()
                    AutomationDefaultsResetButton(preset: draft.baselinePreset) {
                        draft.resetCheckpoint(reset, to: $0)
                    }
                }
            }
        }
        .help(Text(help))
    }

    @ViewBuilder
    private var packageFields: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text(.Settings.settingsAutomationPackageTitle).font(.headline)
                AutomationSettingsProfilePicker(draft: $draft, lastCustom: $sessionCustom,
                    canUseAutomatic: monitor.availableAssistants.contains(draft.assistant))
                    .controlSize(.large)
                if let preset = draft.matchingPreset {
                    AutomationPresetDescription(preset: preset)
                } else if draft.packageDecision == .undecided {
                    Text(.AutomationProfiles.chooseHelp).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(.AutomationProfiles.customizedTitle).font(.caption.weight(.semibold))
                    AutomationCustomProfileDescription(configuration: draft)
                    Text(draft.baselinePreset == .checkpoints ? .AutomationProfiles.legacyHelp : .AutomationProfiles.customizedHelp)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if settings.automationProfileHistory.failure == .read {
                    Text(.AutomationProfiles.historyReadFailed).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            PersistenceDegradedBanner(settings: settings)
            Toggle(isOn: Binding(get: { draft.packageDecision == .enabled }, set: { draft.packageDecision = $0 ? .enabled : .disabled })) {
                Text(.AutomationProfiles.automationEnabled)
            }
            .toggleStyle(.checkbox)
            if !draft.hasAutomaticActionConsent {
                Text(.AutomationProfiles.enableFirst).font(.caption).foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(get: { !draft.allowAutomaticPublicActions }, set: { draft.allowAutomaticPublicActions = !$0 })) {
                Text(.AutomationProfiles.privateToggle)
            }
            .toggleStyle(.checkbox)
            .disabled(!draft.hasAutomaticActionConsent)
            Text(.AutomationProfiles.privateHelp).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var assistantFields: some View {
        Section {
            AutomationAssistantPicker(
                assistant: $draft.assistant, available: monitor.availableAssistants,
                onRefresh: monitor.refreshAvailableAssistants, requireCLI: true,
                statuses: monitor.assistantDependencies.statuses
            )
        } header: {
            Text(.Settings.settingsAutomationPageAssistant)
        } footer: {
            Text(draft.assistant == .codex
                 ? .Settings.settingsAutomationCodexHelp
                 : .Settings.settingsAutomationClaudeHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            Text(.Settings.settingsVerificationHelp).font(.caption).foregroundStyle(.secondary)
            if draft.assistant == .codex {
                Picker(selection: $draft.codexVerificationModel) {
                    ForEach(CodexReviewModel.allCases, id: \.self) { Text(verbatim: $0.name).tag($0) }
                } label: { Text(.Settings.settingsVerificationModel) }
                .disabled(!draft.autoVerifyReReview)
            } else {
                Picker(selection: $draft.claudeVerificationModel) {
                    ForEach(ClaudeVerificationModel.allCases, id: \.self) { Text(verbatim: $0.name).tag($0) }
                } label: { Text(.Settings.settingsVerificationModel) }
                .disabled(!draft.autoVerifyReReview)
            }
            Picker(selection: $draft.verificationThinking) {
                ForEach(VerificationThinking.allCases, id: \.self) { thinking in
                    Text(thinking.name).tag(thinking)
                }
            } label: { Text(.Settings.settingsVerificationThinking) }
        } header: { Text(.Settings.settingsVerificationTitle) }

        Section {
            if draft.assistant == .codex {
                Picker(selection: $draft.codexReviewModel) {
                    ForEach(CodexReviewModel.allCases, id: \.self) { model in
                        Text(verbatim: model.name).tag(model)
                    }
                } label: {
                    Text(.Settings.settingsAutomationReviewModel)
                }
                Picker(selection: $draft.codexReviewThinking) {
                    ForEach(CodexReviewThinking.allCases, id: \.self) { effort in
                        Text(effort.name).tag(effort)
                    }
                } label: {
                    Text(.Settings.settingsAutomationReviewThinking)
                }
                Text(.Settings.settingsAutomationReviewModelHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(.Settings.settingsAutomationClaudeReviewModelHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(.Settings.settingsAutomationReviewModel)
        }

    }

    @ViewBuilder
    private var advancedFields: some View {
        Section {
            HStack {
                TextField(text: $draft.assistantWorkspace) {
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
                if case .success(let url) = result { draft.assistantWorkspace = url.path }
            }
        } footer: {
            Text(.Settings.settingsAutomationWorkspaceHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section {
            Text(.EffectivePolicy.settingsAdvancedRulesWarning).font(.caption).foregroundStyle(.secondary)
        }
        AutomationRuleTemplateSettings(rule: $draft.reviewRequested, title: .Settings.settingsAutomationReviewRequested)
        AutomationRuleTemplateSettings(rule: $draft.authorFeedback, title: .Settings.settingsAutomationAuthorFeedback)
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
        case checkpoints, assistant, scope, todos, workflow, advanced

        var symbol: String {
            switch self {
            case .checkpoints: "hand.raised"
            case .assistant: "sparkles"
            case .scope: "scope"
            case .todos: "tray"
            case .workflow: "bolt"
            case .advanced: "slider.horizontal.3"
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .checkpoints: .Settings.settingsAutomationPageCheckpoints
            case .assistant: .Settings.settingsAutomationPageAssistant
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
