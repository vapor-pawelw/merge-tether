import SwiftUI
import UniformTypeIdentifiers

struct AutomationSettingsTab: View {
    let monitor: TodoMonitorService
    private var settings: SettingsManager { monitor.settings }

    @State private var draft: AutomationSettings
    @State private var trigger: Trigger = .reviewRequested
    @State private var page: Page = .assistant
    @State private var packageChoice: AutomationPackageChoice?
    @State private var confirmRecommendedReset = false
    @State private var isChoosingWorkspace = false
    @State private var showTemplates = false

    init(monitor: TodoMonitorService) {
        self.monitor = monitor
        _draft = State(initialValue: monitor.settings.automation)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(selection: $page) {
                ForEach(Page.allCases, id: \.self) { page in
                    Text(page.title).tag(page)
                }
            } label: {
                Text(.Settings.settingsAutomationTab)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .padding(.top, 12)

            if page == .scope {
                AutomationScopeSettingsView(monitor: monitor)
            } else {
                Form {
                    switch page {
                    case .assistant:
                        assistantFields
                        checkpointFields
                    case .presets:
                        packageFields
                    case .workflow:
                        MergeWorkflowSettingsSection(rules: $draft.workflowRules)
                    case .authored:
                        authoredMergeRequestFields
                    case .todos:
                        todoFields
                        runnerFields
                    case .advanced:
                        advancedFields
                    case .scope:
                        EmptyView()
                    }
                }
                .formStyle(.grouped)

                Divider()

                HStack(alignment: .center, spacing: 16) {
                    if hasIncompleteRule {
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
                        settings.automation = draft.preservingScope(from: settings.automation)
                        settings.save()
                        monitor.refreshAssistantRelay()
                    } label: {
                        Text(.Settings.settingsAutomationApply)
                    }
                    .disabled(draft == settings.automation || hasIncompleteRule)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .onChange(of: settings.automation.scope) { _, current in
            draft.scope = current
        }
    }

    private var rule: Binding<AutomationRule> {
        switch trigger {
        case .reviewRequested: $draft.reviewRequested
        case .authorFeedback: $draft.authorFeedback
        }
    }

    private var hasIncompleteRule: Bool {
        [draft.reviewRequested, draft.authorFeedback].contains { $0.isEnabled && !$0.isConfigured }
    }

    private var checkpointFields: some View {
        Section {
            Toggle(isOn: $draft.allowFollowUpPush) {
                Text(.Settings.settingsAutomationFollowUpPush)
            }
            .toggleStyle(.checkbox)
            Text(.Settings.settingsAutomationFollowUpPushHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(isOn: $draft.publishDraftsWithoutConfirmation) {
                Text(.Settings.settingsAutomationCheckpointPublish)
            }
            .toggleStyle(.checkbox)
            Toggle(isOn: $draft.publishAIRepliesWithoutConfirmation) {
                Text(.Settings.settingsAutomationPublishAIReplies)
            }
            .toggleStyle(.checkbox)
            .disabled(draft.publishDraftsWithoutConfirmation)
            Text(.Settings.settingsAutomationPublishAIRepliesHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(isOn: $draft.autoResolveOwnReviewThreads) {
                Text(.Settings.settingsAutomationResolveOwnReviewThreads)
            }
            .toggleStyle(.checkbox)
            Text(.Settings.settingsAutomationResolveOwnReviewThreadsHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(isOn: $draft.autoApproveEnabled) {
                Text(.Settings.settingsAutomationCheckpointAutoApprove)
            }
            .toggleStyle(.checkbox)
        } header: {
            Text(.Settings.settingsAutomationCheckpointSection)
        } footer: {
            Text(.Settings.settingsAutomationCheckpointHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var packageFields: some View {
        Section {
            AutomationPackagePicker(
                selection: $packageChoice, canUseRecommended: monitor.availableAssistants.contains(draft.assistant)
            )

            Button {
                if packageChoice == .recommended {
                    confirmRecommendedReset = true
                } else if packageChoice == .off {
                    draft.disableAssistantPackage()
                }
            } label: {
                Text(.Settings.settingsAutomationPackageUseSelection)
            }
            .disabled(packageChoice == nil || (packageChoice == .recommended
                && !monitor.availableAssistants.contains(draft.assistant)))
            .confirmationDialog(
                Text(.Settings.settingsAutomationPackageReset),
                isPresented: $confirmRecommendedReset,
                titleVisibility: .visible
            ) {
                Button(role: .destructive) {
                    draft.applyRecommended(for: draft.assistant)
                } label: {
                    Text(.Settings.settingsAutomationPackageReset)
                }
            } message: {
                Text(.Settings.settingsAutomationPackageResetMessage)
            }
        } header: {
            Text(.Settings.settingsAutomationPackageTitle)
        } footer: {
            Text(.Settings.settingsAutomationPackageHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var assistantFields: some View {
        Section {
            AutomationAssistantPicker(
                assistant: $draft.assistant, available: monitor.availableAssistants,
                onRefresh: monitor.refreshAvailableAssistants
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

        if draft.assistant == .codex {
            Section {
                if monitor.availableAssistants.contains(.codex) { CodexPluginControls() }
                Toggle(isOn: $draft.codexRelayEnabled) {
                    Text(.Settings.settingsAutomationCodexRelay)
                }
                .toggleStyle(.checkbox)

                if settings.automation.codexRelayEnabled {
                    if let warning = monitor.codexListenerWarning {
                        Label { Text(warning) } icon: { Image(systemName: "exclamationmark.triangle") }
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if monitor.codexListenerHealth == .listening {
                        Label { Text(.Settings.settingsCodexPluginListening) } icon: { Image(systemName: "checkmark.circle") }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(.Settings.settingsAutomationCodexRelayHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(.Settings.settingsCodexPluginTitle)
            }
        } else if monitor.availableAssistants.contains(.claude) {
            Section {
                ClaudePluginControls()
            } header: {
                Text(.Settings.settingsClaudePluginTitle)
            } footer: {
                Text(.Settings.settingsClaudePluginHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            Toggle(isOn: $draft.reuseAssistantChats) {
                Text(.Settings.settingsAutomationReuseChats)
            }
            .toggleStyle(.checkbox)
        } footer: {
            Text(.Settings.settingsAutomationReuseChatsHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Toggle(isOn: $draft.allowAssistantTools) {
                Text(.Settings.settingsAutomationAssistantTools)
            }
            .toggleStyle(.checkbox)

            if draft.allowAssistantTools {
                TextField(text: $draft.assistantToolProjects) {
                    Text(.Settings.settingsAutomationToolProjects)
                }
                .autocorrectionDisabled()
            }
        } footer: {
            Text(.Settings.settingsAutomationAssistantToolsHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if draft.assistant == .codex {
            Section {
                Button {
                    AssistantAutomationRunner.copyPrompt(CodexDesktopRelay.setupPrompt)
                } label: {
                    Text(.Menu.menuAssistantCopyListener)
                }
            } header: {
                Text(.Settings.settingsCodexPluginManualSetup)
            }
        }
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

            Toggle(isOn: rule.isEnabled) {
                Text(.Settings.settingsAutomationEnable)
            }
            .toggleStyle(.checkbox)

            Picker(selection: rule.runner) {
                Text(.Settings.settingsAutomationRunnerAssistant)
                    .tag(AutomationRunner.assistant)
                Text(.Settings.settingsAutomationRunnerShell)
                    .tag(AutomationRunner.shell)
            } label: {
                Text(.Settings.settingsAutomationRunner)
            }

            TextField(text: rule.projects) {
                Text(.Settings.settingsAutomationTodoProjects)
            }
            .autocorrectionDisabled()

            Toggle(isOn: rule.markDoneOnSuccess) {
                Text(.Settings.settingsAutomationMarkDone)
            }
            .toggleStyle(.checkbox)
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

    private var authoredMergeRequestFields: some View {
        Section {
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

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $draft.conflictTasksEnabled) {
                    Text(.Settings.settingsAutomationConflictsToggle)
                }
                .toggleStyle(.checkbox)

                Text(.Settings.settingsAutomationConflictsHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if draft.conflictTasksEnabled, draft.allowAssistantTools {
                    Toggle(isOn: $draft.allowConflictPush) {
                        Text(.Settings.settingsAutomationConflictsAllowPush)
                    }
                    .toggleStyle(.checkbox)

                    if draft.allowConflictPush {
                        TextField(text: $draft.conflictPushProjects) {
                            Text(.Settings.settingsAutomationConflictsPushProjects)
                        }
                        .autocorrectionDisabled()
                    }
                }
            }
        } header: {
            Text(.Settings.settingsAutomationAuthoredMergeRequestsSection)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(.Settings.settingsAutomationAuthoredMergeRequestsPolling)
                if draft.autoMergeEnabled || (draft.conflictTasksEnabled && draft.allowAssistantTools && draft.allowConflictPush) {
                    Text(.Settings.settingsAutomationAuthoredMergeRequestsProjectsHelp)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var runnerFields: some View {
        Section {
            DisclosureGroup(isExpanded: $showTemplates) {
                templateFields
            } label: {
                Text(.Settings.settingsAutomationTodoCustomize)
            }
        }
    }

    private var templateFields: some View {
        Group {
            TextField(text: rule.titleTemplate) {
                Text(.Settings.settingsAutomationTitle)
            }
            .autocorrectionDisabled()

            if rule.wrappedValue.runner == .assistant {
                TextField(text: rule.promptTemplate, axis: .vertical) {
                    Text(.Settings.settingsAutomationPrompt)
                }
                .lineLimit(5...8)
            } else {
                TextField(text: rule.command, axis: .vertical) {
                    Text(.Settings.settingsAutomationCommand)
                }
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .lineLimit(3...6)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(.Settings.settingsAutomationTemplateHelp)

                if rule.wrappedValue.runner == .shell {
                    Text(.Settings.settingsAutomationCommandHelp)
                    Text(.Settings.settingsAutomationCommandExample)
                        .fontDesign(.monospaced)
                    Text(.Settings.settingsAutomationCommandVariables)
                        .fontDesign(.monospaced)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }

    private enum Page: CaseIterable {
        case assistant, presets, scope, todos, workflow, authored, advanced

        var title: LocalizedStringResource {
            switch self {
            case .assistant: .Settings.settingsAutomationPageAssistant
            case .presets: .Settings.settingsAutomationPagePresets
            case .scope: .Settings.settingsAutomationPageScope
            case .workflow: .Settings.settingsAutomationPageWorkflow
            case .authored: .Settings.settingsAutomationPageAuthored
            case .todos: .Settings.settingsAutomationPageTodos
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
