import SwiftUI

struct CodingAgentSettingsTab: View {
    enum Page: Hashable { case settings, usage }

    let monitor: TodoMonitorService
    @Bindable var editor: SettingsPolicyEditor
    @Binding var page: Page

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
                assistant: Binding(
                    get: { monitor.settings.automation.selectedAssistant },
                    set: { assistant in
                        monitor.settings.automation.selectedAssistant = assistant
                        let saved = monitor.applySettings()
                        if saved, let assistant {
                            if let hold = monitor.cliHealth.hold(for: assistant), hold.issue.kind == .loginRequired {
                                _ = monitor.cliHealth.clear(assistant, expectedID: hold.id)
                            }
                            SettingsNavigation.shared.codingAgentConfigured()
                        }
                    }),
                available: monitor.availableAssistants,
                onRefresh: monitor.refreshAvailableAssistants,
                statuses: monitor.assistantDependencies.statuses
            )
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
                Picker(selection: $editor.draft.codexReviewModel) {
                    ForEach(CodexReviewModel.allCases, id: \.self) { model in
                        Text(verbatim: model.name).tag(model)
                    }
                } label: {
                    Text(.Settings.settingsAutomationReviewModel)
                }
                Picker(selection: $editor.draft.codexReviewThinking) {
                    ForEach(CodexReviewThinking.allCases, id: \.self) { effort in
                        Text(effort.name).tag(effort)
                    }
                } label: {
                    Text(.Settings.settingsAutomationReviewThinking)
                }
            } else {
                Picker(selection: $editor.draft.claudeCodingModel) {
                    ForEach(ClaudeCodingModel.allCases, id: \.self) { model in
                        Text(verbatim: model.name).tag(model)
                    }
                } label: {
                    Text(.Settings.settingsAutomationReviewModel)
                }
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
            Text(.Settings.settingsVerificationHelp).font(.caption).foregroundStyle(.secondary)
            if assistant == .codex {
                Picker(selection: $editor.draft.codexVerificationModel) {
                    ForEach(CodexReviewModel.allCases, id: \.self) { Text(verbatim: $0.name).tag($0) }
                } label: { Text(.Settings.settingsVerificationModel) }
                .disabled(!editor.draft.autoVerifyReReview)
            } else {
                Picker(selection: $editor.draft.claudeVerificationModel) {
                    ForEach(ClaudeVerificationModel.allCases, id: \.self) { Text(verbatim: $0.name).tag($0) }
                } label: { Text(.Settings.settingsVerificationModel) }
                .disabled(!editor.draft.autoVerifyReReview)
            }
            Picker(selection: $editor.draft.verificationThinking) {
                ForEach(VerificationThinking.allCases, id: \.self) { thinking in
                    Text(thinking.name).tag(thinking)
                }
            } label: { Text(.Settings.settingsVerificationThinking) }
        } header: { Text(.Settings.settingsVerificationTitle) }
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
