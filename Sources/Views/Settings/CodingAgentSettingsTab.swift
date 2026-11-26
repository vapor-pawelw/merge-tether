import SwiftUI

struct CodingAgentSettingsTab: View {
    enum Page: Hashable { case settings, usage }

    let monitor: TodoMonitorService
    @Bindable var editor: SettingsPolicyEditor
    @Binding var page: Page
    @State private var showAllModels = false

    var body: some View {
        VStack(spacing: 0) {
            Picker(selection: $page) {
                Text(.Settings.settingsCodingAgentPreferences).tag(Page.settings)
                Text(.AssistantUsage.assistantUsageDashboardTitle).tag(Page.usage)
            } label: { Text(.Settings.settingsCodingAgentTab) }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 10)

            if page == .settings {
                Form {
                    provider
                    conversationDestination
                    powerSettings
                    if let assistant = editor.draft.selectedAssistant {
                        assistantModelFields(assistant)
                        Section {
                            Toggle(isOn: $showAllModels) { Text(.Settings.settingsCodingAgentShowNonRecommendedModels) }
                                .toggleStyle(.checkbox)
                        }
                    }
                    WorkerExecutionTimeoutSettingsView(policy: $editor.draft.workerExecutionTimeout, repositories: timeoutRepositories)
                }
                .formStyle(.grouped)
                SettingsPolicyFooter(monitor: monitor, editor: editor)
            } else {
                Form {
                    Section { AssistantUsageSettingsContent() }
                }
                .formStyle(.grouped)
            }
        }
    }

    private var provider: some View {
        Section {
            AutomationAssistantPicker(
                assistant: $editor.selectedAssistant,
                available: monitor.availableAssistants,
                onRefresh: monitor.refreshAvailableAssistants,
                statuses: monitor.assistantDependencies.statuses,
                verifySelectionImmediately: false,
                onSetupReady: { editor.finishAssistantSetup($0, monitor: monitor) }
            )
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(.Settings.settingsAssistantApplyNotice)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            PersistenceDegradedBanner(settings: monitor.settings)
        } footer: {
            Text(.Settings.settingsAssistantUseHelp)
        }
    }

    private var conversationDestination: some View {
        Section {
            Picker(selection: Binding(
                get: { monitor.settings.conversationDestination },
                set: { monitor.settings.conversationDestination = $0; monitor.settings.save() }
            )) {
                ForEach(AssistantContextLauncher.Destination.allCases) { destination in
                    Text(destination.label).tag(destination)
                }
            } label: { Text(.AssistantContext.assistantContextDefault) }
        } header: {
            Text(.AssistantContext.assistantContextSettingsTitle)
        } footer: {
            Text(.AssistantContext.assistantContextSettingsHelp)
        }
    }

    private var powerSettings: some View {
        Section {
            Toggle(isOn: Binding(
                get: { monitor.settings.keepMacAwakeDuringAgentTasks },
                set: { monitor.setKeepMacAwakeDuringAgentTasks($0) }
            )) {
                Text(.Settings.settingsAutomationKeepMacAwake)
            }
        } footer: {
            Text(.Settings.settingsAutomationKeepMacAwakeHelp)
        }
    }

    @ViewBuilder
    private func assistantModelFields(_ assistant: AutomationAssistant) -> some View {
        Section {
            if assistant == .codex {
                modelPicker(.Settings.settingsAutomationReviewModel, selection: $editor.draft.codexReviewModel,
                            recommended: CodexReviewModel.recommendedForCoding)
                Picker(selection: $editor.draft.codexReviewThinking) {
                    ForEach(CodexReviewThinking.allCases, id: \.self) { effort in
                        Text(effort.name).tag(effort)
                    }
                } label: {
                    Text(.Settings.settingsAutomationReviewThinking)
                }
            } else {
                modelPicker(.Settings.settingsAutomationReviewModel, selection: $editor.draft.claudeCodingModel,
                            recommended: ClaudeModel.recommendedForCoding)
                Picker(selection: $editor.draft.claudeCodingThinking) {
                    ForEach(CodexReviewThinking.allCases, id: \.self) { effort in
                        Text(effort.name).tag(effort)
                    }
                } label: {
                    Text(.Settings.settingsAutomationReviewThinking)
                }
            }
            Text(.Settings.settingsAutomationReviewModelHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(.Settings.settingsAutomationReviewModel)
        }

        Section {
            Text(.Settings.settingsVerificationModelHelp).font(.caption).foregroundStyle(.secondary)
            if assistant == .codex {
                modelPicker(.Settings.settingsVerificationModel, selection: $editor.draft.codexVerificationModel,
                            recommended: CodexReviewModel.recommendedForVerification)
            } else {
                modelPicker(.Settings.settingsVerificationModel, selection: $editor.draft.claudeVerificationModel,
                            recommended: ClaudeModel.recommendedForVerification)
            }
            Picker(selection: $editor.draft.verificationThinking) {
                ForEach(VerificationThinking.allCases, id: \.self) { thinking in
                    Text(thinking.name).tag(thinking)
                }
            } label: { Text(.Settings.settingsVerificationThinking) }
        } header: { Text(.Settings.settingsVerificationTitle) }
    }

    private func modelPicker<Model: AgentModel>(_ title: LocalizedStringResource, selection: Binding<Model>,
                                                recommended: [Model]) -> some View {
        Picker(selection: selection) {
            ForEach(selection.wrappedValue.pickerOptions(recommended: recommended, showAll: showAllModels), id: \.self) { model in
                Text(verbatim: model.name).tag(model)
            }
        } label: { Text(title) }
    }

    private var timeoutRepositories: [PublicationIdentity] {
        var repositories: [String: PublicationIdentity] = [:]
        func remember(host: String, projectID: Int, path: String) {
            guard projectID > 0, !path.isEmpty else { return }
            let identity = PublicationIdentity(host: host, entityID: projectID, label: path)
            repositories[identity.id] = identity
        }
        for item in monitor.attention.currentOpenItems {
            if let repository = WorkerExecutionTimeoutSettingsView.repositoryChoice(projectID: item.id.projectID, url: item.url) {
                repositories[repository.id] = repository
            }
        }
        for status in monitor.authoredMergeRequests.requests {
            if let repository = WorkerExecutionTimeoutSettingsView.repositoryChoice(projectID: status.request.projectID, url: status.request.webURL) {
                repositories[repository.id] = repository
            }
        }
        if let host = monitor.glab.resolvedHost, let username = monitor.glab.currentUsername {
            let scope = editor.draft.scope
            for target in scope.repositoryOverrides(host: host, username: username) + scope.individualTargets(host: host, username: username) {
                if let path = scope.repositoryLabel(for: target) {
                    remember(host: host, projectID: target.projectID, path: path)
                }
            }
        }
        return repositories.values.sorted { ($0.label, $0.host, $0.entityID) < ($1.label, $1.host, $1.entityID) }
    }
}
