import SwiftUI

struct MRAutomationScopeMenu: View {
    let settings: SettingsManager
    let target: MRAutomationScope.Target
    var projectPath: String? = nil

    var body: some View {
        let status = settings.automation.scope.resolve(target)
        Menu {
            if target.iid == nil {
                choices(for: target)
            } else {
                Menu { choices(for: target) } label: { Text(.Menu.menuScopeThisMR) }
                Menu { choices(for: target.repository) } label: { Text(.Menu.menuScopeThisRepo) }
            }
        } label: {
            Label {
                HStack(spacing: 3) {
                    Text(status.active ? .Menu.menuScopeActive : .Menu.menuScopePaused)
                    Text("·")
                    Text(sourceLabel(status.source))
                }
            } icon: {
                Image(systemName: status.active ? "bolt.circle" : "pause.circle")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption)
    }

    private func choices(for key: MRAutomationScope.Target) -> some View {
        Picker(selection: Binding(
            get: { settings.automation.scope[key] },
            set: {
                settings.automation.scope[key] = $0
                if $0 != .inherit, let projectPath { settings.automation.scope.rememberRepository(projectPath, for: key) }
                settings.save()
            }
        )) {
            Text(.Menu.menuScopeInherit).tag(MRAutomationScope.Choice.inherit)
            Text(.Menu.menuScopeEnable).tag(MRAutomationScope.Choice.active)
            Text(.Menu.menuScopePause).tag(MRAutomationScope.Choice.paused)
        } label: {
            Text(.Menu.menuScopeTitle)
        }
        .pickerStyle(.inline)
    }

    private func sourceLabel(_ source: MRAutomationScope.Source) -> LocalizedStringResource {
        switch source {
        case .global: .Menu.menuScopeSourceGlobal
        case .repository: .Menu.menuScopeSourceRepo
        case .mergeRequest: .Menu.menuScopeSourceMR
        }
    }
}
