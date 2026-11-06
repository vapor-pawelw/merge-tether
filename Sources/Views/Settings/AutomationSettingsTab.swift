import SwiftUI
import UniformTypeIdentifiers

struct AutomationSettingsTab: View {
    let monitor: TodoMonitorService
    private var settings: SettingsManager { monitor.settings }

    @State private var draft: AutomationSettings
    @State private var trigger: Trigger = .reviewRequested
    @State private var page: Page = .checkpoints
    @State private var packageChoice: AutomationPackageChoice?
    @State private var confirmRecommendedReset = false
    @State private var isChoosingWorkspace = false
    @State private var showTemplates = false
    @State private var setupAction: SetupAction?
    private enum SetupAction: String, Identifiable {
        case enableVerification, apply
        var id: String { rawValue }
    }

    init(monitor: TodoMonitorService) {
        self.monitor = monitor
        _draft = State(initialValue: monitor.settings.automation)
    }

    var body: some View {
        // Eight pages don't fit a segmented control; a sidebar keeps every name readable.
        HStack(spacing: 0) {
            List(selection: $page) {
                ForEach(Page.allCases, id: \.self) { page in
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
                        checkpointFields
                    case .assistant:
                        assistantFields
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
                        if draft.usesAssistant || draft.autoReReviewEnabled || draft.autoMergeEnabled
                            || draft.autoApproveEnabled || draft.publishDraftsWithoutConfirmation
                            || draft.publishAIRepliesWithoutConfirmation { setupAction = .apply }
                        else { applyDraft() }
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
    }

    private var rule: Binding<AutomationRule> {
        switch trigger {
        case .reviewRequested: $draft.reviewRequested
        case .authorFeedback: $draft.authorFeedback
        }
    }

    private func applyDraft() {
        settings.automation = draft.preservingScope(from: settings.automation)
        settings.save()
    }

    private var hasIncompleteRule: Bool {
        [draft.reviewRequested, draft.authorFeedback].contains { $0.isEnabled && !$0.isConfigured }
    }

    private var checkpointFields: some View {
        Group {
            Section {
                checkpointToggle($draft.publishDraftsWithoutConfirmation, .Settings.settingsAutomationCheckpointPublish,
                                 help: .Settings.settingsAutomationCheckpointPublishHelp)
                checkpointToggle($draft.autoApproveEnabled, .Settings.settingsAutomationCheckpointAutoApprove,
                                 help: .Settings.settingsAutomationCheckpointAutoApproveHelp)
                checkpointToggle($draft.allowFollowUpPush, .Settings.settingsAutomationFollowUpPush,
                                 help: .Settings.settingsAutomationFollowUpPushHelp)
            } header: {
                Text(.Settings.settingsAutomationCheckpointSection)
            } footer: {
                Text(.Settings.settingsAutomationCheckpointHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                checkpointToggle($draft.publishAIRepliesWithoutConfirmation, .Settings.settingsAutomationPublishAIReplies,
                                 help: .Settings.settingsAutomationPublishAIRepliesHelp)
                    .disabled(draft.publishDraftsWithoutConfirmation)
                checkpointToggle($draft.autoResolveOwnReviewThreads, .Settings.settingsAutomationResolveOwnReviewThreads,
                                 help: .Settings.settingsAutomationResolveOwnReviewThreadsHelp)
            } footer: {
                Link(destination: URL(string: "https://github.com/vapor-pawelw/merge-tether/blob/main/docs/automation.md")!) {
                    Text(.Settings.settingsAutomationLearnMore)
                }
                .font(.caption)
            }
        }
    }

    private func checkpointToggle(
        _ isOn: Binding<Bool>, _ title: LocalizedStringResource, help: LocalizedStringResource
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: isOn) { Text(title) }
                .toggleStyle(.checkbox)
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
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
            Toggle(isOn: Binding(get: { draft.autoVerifyReReview }, set: { enabled in
                if enabled { setupAction = .enableVerification }
                else { draft.autoVerifyReReview = false }
            })) { Text(.Settings.settingsVerificationEnabled) }
                .toggleStyle(.checkbox)
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
            .disabled(rule.wrappedValue.runner == .shell)

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
                Text(.Settings.settingsAutomationCommand).font(.caption.weight(.semibold))
                Text(verbatim: rule.wrappedValue.command)
                    .font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(.Settings.settingsAutomationRunnerLegacyHelp)
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(.Settings.settingsAutomationTemplateHelp)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }

    private enum Page: CaseIterable {
        case checkpoints, assistant, scope, todos, workflow, authored, presets, advanced

        var symbol: String {
            switch self {
            case .checkpoints: "hand.raised"
            case .assistant: "sparkles"
            case .scope: "scope"
            case .todos: "tray"
            case .workflow: "bolt"
            case .authored: "person.crop.circle"
            case .presets: "square.stack"
            case .advanced: "slider.horizontal.3"
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .checkpoints: .Settings.settingsAutomationPageCheckpoints
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
