import SwiftUI

struct BoardAutomationToggle: View {
    let settings: SettingsManager
    let target: MRAutomationScope.Target
    var projectPath: String? = nil
    var isDraft = false

    var body: some View {
        if settings.automation.hasEnabledAutomation {
            let status = settings.automation.scope.resolve(target, isDraft: isDraft)
            let choice = settings.automation.scope.manualChoice(for: target)
            Button {
                scopeEnabledBinding(settings: settings, target: target, projectPath: projectPath,
                                    isDraft: isDraft).wrappedValue.toggle()
            } label: {
                Image(systemName: status.active ? "bolt.fill" : "bolt.slash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(status.active ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24)
                    .overlay(alignment: .bottomTrailing) {
                        if choice == .forceOn || choice == .paused {
                            Circle().fill(.secondary).frame(width: 3, height: 3)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .boardHeaderControlHover()
            .help(scopeHelp(status, choice: choice, hasActionExceptions: hasActionExceptions(settings, target: target)))
            .accessibilityLabel(Text(.Menu.menuScopeTitle))
            .accessibilityValue(Text(scopeChoiceLabel(choice)) + Text(", ")
                + Text(status.active ? .Menu.menuScopeActive : .Menu.menuScopePaused))
        }
    }
}

struct MRAutomationScopeMenu: View {
    let monitor: TodoMonitorService
    let target: MRAutomationScope.Target
    var projectPath: String? = nil
    var isDraft = false
    private var settings: SettingsManager { monitor.settings }

    var body: some View {
        if settings.automation.hasEnabledAutomation {
            let status = settings.automation.scope.resolve(target, isDraft: isDraft)
            let choice = settings.automation.scope.manualChoice(for: target)
            Menu {
                if target.iid != nil {
                    choiceButton(.inherit)
                    choiceButton(.forceOn)
                    choiceButton(.paused)
                    Divider()
                    ForEach(applicableActions, id: \.self) { action in
                        Toggle(isOn: Binding(get: {
                            settings.actionIsAutomatic(action, for: target)
                        }, set: { enabled in
                            Task { await monitor.setAutomaticAction(action, enabled: enabled, for: target) }
                        })) {
                            Text(actionLabel(action))
                        }
                        .help(Text(.AutomaticActions.automaticActionsInheritHelp))
                    }
                    Divider()
                }
                Toggle(isOn: scopeEnabledBinding(settings: settings, target: target.repository,
                                                  projectPath: projectPath)) {
                    Label { Text(.Menu.menuScopeRepositoryDefault) } icon: { Image(systemName: "folder") }
                }
                .help(Text(.Menu.menuScopeRepositoryDefaultHelp))
                if settings.automation.scope[target.repository] != .inherit {
                    Button {
                        settings.automation.scope.setManualChoice(.inherit, for: target.repository)
                        settings.save()
                    } label: { Text(.Menu.menuScopeFollowGlobal) }
                }
            } label: {
                Label { Text(.Menu.menuScopeTitle) } icon: {
                    Image(systemName: status.active ? "bolt.circle" : "pause.circle")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
            .help(scopeHelp(status, choice: choice, hasActionExceptions: hasActionExceptions(settings, target: target)))
        }
    }

    /// Cached, account-bound metadata only: rendering a menu never starts a read.
    private var applicableActions: [MRAutomaticAction] {
        guard let iid = target.iid, monitor.glab.resolvedHost == target.host,
              monitor.glab.currentUsername == target.username,
              let request = monitor.boardDisplayRequests.first(where: {
                  $0.projectID == target.projectID && $0.iid == iid
                      && $0.webURL.isGitLabMergeRequest(host: target.host, iid: iid)
              }), !request.author.username.isEmpty else { return [.commentPublication] }
        return [.commentPublication, request.author.username == target.username ? .merge : .approval]
    }

    private func actionLabel(_ action: MRAutomaticAction) -> LocalizedStringResource {
        switch action {
        case .commentPublication: .AutomaticActions.automaticActionsPublication
        case .merge: .AutomaticActions.automaticActionsMerge
        case .approval: .AutomaticActions.automaticActionsApproval
        }
    }

    private func choiceButton(_ choice: MRAutomationScope.Choice) -> some View {
        Button {
            settings.automation.scope.setManualChoice(choice, for: target)
            if let projectPath { settings.automation.scope.rememberRepository(projectPath, for: target) }
            settings.save()
        } label: {
            Label { Text(scopeChoiceLabel(choice)) } icon: {
                if settings.automation.scope.manualChoice(for: target) == choice {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}

@MainActor
private func scopeEnabledBinding(settings: SettingsManager, target: MRAutomationScope.Target,
                                 projectPath: String?, isDraft: Bool = false) -> Binding<Bool> {
    Binding(get: { settings.automation.scope.resolve(target, isDraft: isDraft).active }, set: { enabled in
        settings.automation.scope.setEnabled(enabled, for: target, isDraft: isDraft)
        if settings.automation.scope[target] != .inherit, let projectPath {
            settings.automation.scope.rememberRepository(projectPath, for: target)
        }
        settings.save()
    })
}

@MainActor
private func hasActionExceptions(_ settings: SettingsManager, target: MRAutomationScope.Target) -> Bool {
    target.iid != nil && MRAutomaticAction.allCases.contains { !settings.actionIsAutomatic($0, for: target) }
}

private func scopeHelp(_ status: (active: Bool, source: MRAutomationScope.Source),
                       choice: MRAutomationScope.Choice, hasActionExceptions: Bool = false) -> Text {
    let source = String(localized: scopeSourceLabel(status.source))
    return Text(scopeChoiceLabel(choice)) + Text("\n")
        + Text(status.active ? .Menu.menuScopeEnabledHelp(source) : .Menu.menuScopePausedHelp(source))
        + Text("\n") + Text(.Menu.menuScopeDraftSafetyHelp)
        + (hasActionExceptions ? Text("\n") + Text(.AutomaticActions.automaticActionsExceptionsHelp) : Text(""))
}

private func scopeChoiceLabel(_ choice: MRAutomationScope.Choice) -> LocalizedStringResource {
    switch choice {
    case .inherit, .active: .Menu.menuScopeAuto
    case .forceOn: .Menu.menuScopeAlwaysOn
    case .paused: .Menu.menuScopeAlwaysOff
    }
}

private func scopeSourceLabel(_ source: MRAutomationScope.Source) -> LocalizedStringResource {
    switch source {
    case .global: .Menu.menuScopeSourceGlobal
    case .repository: .Menu.menuScopeSourceRepo
    case .mergeRequest: .Menu.menuScopeSourceMR
    case .draft: .Menu.menuScopeSourceDraft
    }
}
