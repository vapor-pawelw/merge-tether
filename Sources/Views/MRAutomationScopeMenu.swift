import SwiftUI

struct BoardAutomationToggle: View {
    let settings: SettingsManager
    let target: MRAutomationScope.Target
    var projectPath: String? = nil

    var body: some View {
        let status = settings.automation.scope.resolve(target)
        Button {
            scopeEnabledBinding(settings: settings, target: target, projectPath: projectPath).wrappedValue.toggle()
        } label: {
            Image(systemName: status.active ? "bolt.fill" : "bolt.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(status.active ? Color.accentColor : Color.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(scopeHelp(status))
        .accessibilityLabel(Text(.Menu.menuScopeTitle))
        .accessibilityValue(Text(status.active ? .Menu.menuScopeActive : .Menu.menuScopePaused))
    }
}

struct MRAutomationScopeMenu: View {
    let settings: SettingsManager
    let target: MRAutomationScope.Target
    var projectPath: String? = nil

    var body: some View {
        let status = settings.automation.scope.resolve(target)
        Menu {
            if target.iid != nil {
                Toggle(isOn: scopeEnabledBinding(settings: settings, target: target, projectPath: projectPath)) {
                    Label { Text(.Menu.menuScopeThisMR) } icon: { Image(systemName: "arrow.triangle.pull") }
                }
                .help(scopeHelp(status))
            }
            Toggle(isOn: scopeEnabledBinding(settings: settings, target: target.repository, projectPath: projectPath)) {
                Label { Text(.Menu.menuScopeRepositoryDefault) } icon: { Image(systemName: "folder") }
            }
            .help(Text(.Menu.menuScopeRepositoryDefaultHelp))
            if settings.automation.scope[target] != .inherit || settings.automation.scope[target.repository] != .inherit {
                Divider()
                Menu {
                    if target.iid != nil, settings.automation.scope[target] != .inherit {
                        Button { reset(target) } label: { Text(.Menu.menuScopeFollowRepository) }
                    }
                    if settings.automation.scope[target.repository] != .inherit {
                        Button { reset(target.repository) } label: { Text(.Menu.menuScopeFollowGlobal) }
                    }
                } label: { Text(.Menu.menuScopeDefaults) }
            }
        } label: {
            Label { Text(.Menu.menuScopeTitle) } icon: {
                Image(systemName: status.active ? "bolt.circle" : "pause.circle")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption)
        .help(scopeHelp(status))
    }

    private func reset(_ key: MRAutomationScope.Target) {
        settings.automation.scope[key] = .inherit
        settings.save()
    }
}

@MainActor
private func scopeEnabledBinding(settings: SettingsManager, target: MRAutomationScope.Target,
                                 projectPath: String?) -> Binding<Bool> {
    Binding(get: { settings.automation.scope.resolve(target).active }, set: { enabled in
        settings.automation.scope.setEnabled(enabled, for: target)
        if settings.automation.scope[target] != .inherit, let projectPath {
            settings.automation.scope.rememberRepository(projectPath, for: target)
        }
        settings.save()
    })
}

private func scopeHelp(_ status: (active: Bool, source: MRAutomationScope.Source)) -> Text {
    let source = String(localized: scopeSourceLabel(status.source))
    return Text(status.active ? .Menu.menuScopeEnabledHelp(source) : .Menu.menuScopePausedHelp(source))
}

private func scopeSourceLabel(_ source: MRAutomationScope.Source) -> LocalizedStringResource {
    switch source {
    case .global: .Menu.menuScopeSourceGlobal
    case .repository: .Menu.menuScopeSourceRepo
    case .mergeRequest: .Menu.menuScopeSourceMR
    }
}
