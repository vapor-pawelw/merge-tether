import AppKit
import SwiftUI

/// Applies per-MR and repository scope changes for the popover, the bolt shortcut and the scope menu alike.
@MainActor
struct MRAutomationScopeEditor {
    let monitor: TodoMonitorService
    let target: MRAutomationScope.Target
    var projectPath: String? = nil
    var isDraft = false
    /// Injected by tests; the app asks with a modal alert that outlives a dismissed menu or popover.
    var confirm: @MainActor (LocalizedStringResource) async -> Bool = { confirmDraftAutomation(message: $0) }

    var settings: SettingsManager { monitor.settings }

    /// Saved policy, ignoring the global switch, so choices made while it is off are visible and editable.
    var summary: MRAutomationControl.Summary {
        MRAutomationControl.summary(settings.configuredAutomation.scope, target: target, isDraft: isDraft)
    }

    var globallySuspended: Bool { !settings.automationGloballyEnabled }

    var isAvailable: Bool {
        let automation = settings.configuredAutomation
        return automation.hasEnabledAutomation
            || (automation.hasAutomaticPublicActionConsent && request != nil)
    }

    private var hasSavedActionOverrides: Bool {
        MRAutomaticAction.allCases.contains { settings.storedActionPreference($0, for: target) != .default }
    }

    private var hasLegacyActionOverrides: Bool {
        summary.choice == .inherit && !settings.configuredAutomation.scope.followsActionDefaults(for: target)
            && hasSavedActionOverrides
    }

    var choice: MRAutomationPreference {
        switch summary.choice {
        case .inherit: hasLegacyActionOverrides ? .on : .default
        case .active, .forceOn: .on
        case .paused: .off
        }
    }

    var boltColor: Color {
        guard choice == .default else { return .orange }
        return summary.active ? .accentColor : .secondary
    }

    var hasActionExceptions: Bool { choice == .on && hasSavedActionOverrides }

    func displayedPreference(for action: MRAutomaticAction) -> MRAutomationPreference {
        switch choice {
        case .on: return settings.storedActionPreference(action, for: target)
        case .off: return .off
        case .default:
            let automation = settings.configuredAutomation
            guard summary.active, automation.hasAutomaticPublicActionConsent else { return .off }
            let enabled = switch action {
            case .commentPublication:
                automation.publicationMode != .manual
                    && (automation.publicationMode != .filtered || automation.publicationRestrictions.hasConditions)
            case .merge:
                !isDraft && automation.permitsAutoMerge(project: projectPath ?? request?.webURL.gitLabProjectPath ?? "")
            case .approval: automation.autoApproveEnabled
            }
            return enabled ? .on : .off
        }
    }

    func choose(_ preference: MRAutomationPreference, for action: MRAutomaticAction) async {
        guard choice == .on else { return }
        await monitor.setAutomaticActionPreference(preference, for: action, target: target)
    }

    /// Cached, account-bound metadata only: rendering a menu or popover never starts a read.
    private var request: GitLabMergeRequest? {
        guard let iid = target.iid, monitor.glab.resolvedHost == target.host,
              monitor.glab.currentUsername == target.username else { return nil }
        return monitor.boardDisplayRequests.first {
            $0.projectID == target.projectID && $0.iid == iid && !$0.author.username.isEmpty
                && $0.webURL.isGitLabMergeRequest(host: target.host, iid: iid)
        }
    }

    var applicableActions: [MRAutomaticAction] {
        guard let request else { return [.commentPublication] }
        return [.commentPublication, request.author.username == target.username ? .merge : .approval]
    }

    /// Flips this MR's effective state, as the popover's main button and an Option-click do.
    func toggle() async {
        let enabled = !summary.active
        guard await apply(changing: target, message: draftAutomationMessage(target: target, projectPath: projectPath),
                          { $0.setEnabled(enabled, for: target, isDraft: isDraft) }) else { return }
        announceChange()
    }

    func choose(_ choice: MRAutomationScope.Choice) async {
        guard choice != summary.choice || (choice == .inherit && hasLegacyActionOverrides) else { return }
        await apply(changing: target,
            message: draftAutomationMessage(target: target, projectPath: projectPath, followsDefaults: choice == .inherit)) {
            $0.setManualChoice(choice, for: target)
        }
    }

    func setRepositoryDefault(_ enabled: Bool) async {
        await apply(changing: target.repository, message: repositoryConfirmationMessage) {
            $0.setEnabled(enabled, for: target.repository)
        }
    }

    func followGeneralScope() async {
        await apply(changing: target.repository, message: repositoryConfirmationMessage) {
            $0.setManualChoice(.inherit, for: target.repository)
        }
    }

    var repositoryDefaultActive: Bool { settings.configuredAutomation.scope.resolve(target.repository).active }
    var repositoryHasOverride: Bool { settings.automation.scope[target.repository] != .inherit }

    private var repositoryConfirmationMessage: LocalizedStringResource {
        .Menu.menuScopeDraftConfirmationRepositoryMessage(
            projectPath ?? settings.automation.scope.repositoryLabel(for: target) ?? String(target.projectID))
    }

    /// Returns whether the change was saved; a declined Draft confirmation leaves the scope untouched.
    @discardableResult
    private func apply(changing key: MRAutomationScope.Target, message: LocalizedStringResource,
                       _ change: (inout MRAutomationScope) -> Void) async -> Bool {
        let current = settings.configuredAutomation.scope
        var proposed = current
        change(&proposed)
        if MRAutomationControl.requiresDraftConfirmation(from: current, to: proposed, changing: key,
                                                         target: target, isDraft: isDraft) {
            guard await confirm(message) else { return false }
        }
        change(&settings.automation.scope)
        if let projectPath { settings.automation.scope.rememberRepository(projectPath, for: key) }
        settings.save()
        return true
    }

    private func announceChange() {
        guard let iid = target.iid else { return }
        monitor.automationToggleNotices.post(.mergeRequest(iid: iid, projectPath: projectPath,
            active: settings.configuredAutomation.scope.resolve(target, isDraft: isDraft).active))
    }
}

/// The bolt in card and Details headers: a click explains this MR's automation, Option-click switches it.
struct BoardAutomationToggle: View {
    let monitor: TodoMonitorService
    let target: MRAutomationScope.Target
    var projectPath: String? = nil
    var isDraft = false
    /// Saved policy for this MR, shown in the popover instead of on the card.
    var policy: MREffectivePolicyPresentation? = nil
    @State private var showingDetails = false

    private var editor: MRAutomationScopeEditor {
        .init(monitor: monitor, target: target, projectPath: projectPath, isDraft: isDraft)
    }

    var body: some View {
        if editor.isAvailable {
            let summary = editor.summary
            let choice = editor.choice
            let help = Text(summary.active ? .Menu.menuScopeButtonHelpActive : .Menu.menuScopeButtonHelpPaused)
            Button {
                if NSEvent.modifierFlags.contains(.option) {
                    Task { await editor.toggle() }
                } else {
                    showingDetails.toggle()
                }
            } label: {
                Image(systemName: summary.active ? "bolt.fill" : "bolt.slash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(editor.boltColor)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .boardHeaderControlHover()
            .help(Text(choice.title) + Text(verbatim: " · ") + help)
            .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                MRAutomationPopover(editor: editor, policy: policy)
                    .onExitCommand { showingDetails = false }
            }
            .preference(key: BoardDetailPopoverPresentedKey.self, value: showingDetails)
            .accessibilityLabel(Text(.Menu.menuScopeTitle))
            .accessibilityValue(Text(choice.title) + Text(", ")
                + Text(summary.active ? .Menu.menuScopeActive : .Menu.menuScopePaused))
            .accessibilityHint(Text(.Menu.menuScopeButtonAccessibilityHint))
        }
    }
}

/// Everything that decides this MR's automation, readable without hovering, with the switch on top.
struct MRAutomationPopover: View {
    let editor: MRAutomationScopeEditor
    var policy: MREffectivePolicyPresentation? = nil

    var body: some View {
        let summary = editor.summary
        VStack(alignment: .leading, spacing: 12) {
            header(summary)
            if editor.globallySuspended {
                caption(.Menu.menuScopePopoverGloballySuspended)
            }
            Button { Task { await editor.toggle() } } label: {
                Text(primaryTitle(summary)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            if editor.target.iid != nil {
                Divider()
                mergeRequestSection
            }
            if let policy, !policy.clauses.isEmpty || policy.settingsAction != nil {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle(.EffectivePolicy.policyAutomationRules)
                    MREffectivePolicyView(presentation: policy)
                }
            }
            Divider()
            repositorySection
            Text(.Menu.menuScopePopoverOptionClickHint)
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private func header(_ summary: MRAutomationControl.Summary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: summary.active ? "bolt.fill" : "bolt.slash")
                .foregroundStyle(editor.boltColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.active ? .Menu.menuScopeActive : .Menu.menuScopePaused).font(.headline)
                Text(.Menu.menuScopePopoverSource(String(localized: MRAutomationControl.sourceLabel(summary.source))))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var mergeRequestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    sectionTitle(.Menu.menuScopeTitle)
                    AutomationPreferencePicker(title: .Menu.menuScopeTitle,
                        selection: Binding(get: { editor.choice }, set: { preference in
                            Task { await editor.choose(preference.scopeChoice) }
                        }))
                }
                ForEach(editor.applicableActions, id: \.self) { action in
                    GridRow {
                        Text(action.title)
                        MRAutomaticActionControl(action: action, editor: editor)
                    }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            caption(.Menu.menuScopeDraftSafetyHelp)
        }
    }

    private var repositorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(.Menu.menuScopePopoverRepository)
            Toggle(isOn: Binding(get: { editor.repositoryDefaultActive }, set: { enabled in
                Task { await editor.setRepositoryDefault(enabled) }
            })) { Text(.Menu.menuScopeRepositoryDefault) }
            .toggleStyle(.checkbox)
            caption(.Menu.menuScopeRepositoryDefaultHelp)
            if editor.repositoryHasOverride {
                Button { Task { await editor.followGeneralScope() } } label: { Text(.Menu.menuScopeFollowGlobal) }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    private func primaryTitle(_ summary: MRAutomationControl.Summary) -> LocalizedStringResource {
        switch (editor.target.iid != nil, summary.active) {
        case (true, true): .Menu.menuScopePopoverPauseMergeRequest
        case (true, false): .Menu.menuScopePopoverEnableMergeRequest
        case (false, true): .Menu.menuScopePopoverPauseRepository
        case (false, false): .Menu.menuScopePopoverEnableRepository
        }
    }

    private func sectionTitle(_ title: LocalizedStringResource) -> some View {
        Text(title).font(.subheadline.weight(.semibold))
    }

    private func caption(_ text: LocalizedStringResource) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// The same choices in context and action menus, where a popover cannot open.
struct MRAutomationScopeMenu: View {
    let monitor: TodoMonitorService
    let target: MRAutomationScope.Target
    var projectPath: String? = nil
    var isDraft = false
    var showsLeadingDivider = false

    private var editor: MRAutomationScopeEditor {
        .init(monitor: monitor, target: target, projectPath: projectPath, isDraft: isDraft)
    }

    var body: some View {
        if editor.isAvailable {
            if showsLeadingDivider { Divider() }
            let summary = editor.summary
            Menu {
                if target.iid != nil {
                    ForEach(MRAutomationPreference.allCases, id: \.self) { choice in
                        choiceButton(choice)
                    }
                    Divider()
                    ForEach(editor.applicableActions, id: \.self) { action in
                        MRAutomaticActionControl(action: action, editor: editor)
                            .pickerStyle(.menu)
                    }
                    Divider()
                }
                Toggle(isOn: Binding(get: { editor.repositoryDefaultActive }, set: { enabled in
                    Task { await editor.setRepositoryDefault(enabled) }
                })) {
                    Label { Text(.Menu.menuScopeRepositoryDefault) } icon: { Image(systemName: "folder") }
                }
                .help(Text(.Menu.menuScopeRepositoryDefaultHelp))
                if editor.repositoryHasOverride {
                    Button { Task { await editor.followGeneralScope() } } label: { Text(.Menu.menuScopeFollowGlobal) }
                }
            } label: {
                Label { Text(.Menu.menuScopeTitle) } icon: {
                    Image(systemName: summary.active ? "bolt.circle" : "pause.circle")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
            .help(scopeHelp(summary, hasActionExceptions: editor.hasActionExceptions))
        }
    }

    private func choiceButton(_ choice: MRAutomationPreference) -> some View {
        Button { Task { await editor.choose(choice.scopeChoice) } } label: {
            Label { Text(choice.title) } icon: {
                if editor.choice == choice { Image(systemName: "checkmark") }
            }
        }
    }
}

private struct MRAutomaticActionControl: View {
    let action: MRAutomaticAction
    let editor: MRAutomationScopeEditor

    var body: some View {
        AutomationPreferencePicker(title: action.title, selection: Binding(get: {
            editor.displayedPreference(for: action)
        }, set: { preference in
            Task { await editor.choose(preference, for: action) }
        }))
        .disabled(editor.choice != .on)
        .help(Text(action.help))
    }
}

private struct AutomationPreferencePicker: View {
    let title: LocalizedStringResource
    @Binding var selection: MRAutomationPreference

    var body: some View {
        Picker(selection: $selection) {
            ForEach(MRAutomationPreference.allCases, id: \.self) { preference in
                Text(preference.title).tag(preference)
            }
        } label: {
            Text(title)
        }
    }
}

private extension MRAutomaticAction {
    var title: LocalizedStringResource {
        switch self {
        case .commentPublication: .AutomaticActions.automaticActionsPublication
        case .merge: .AutomaticActions.automaticActionsMerge
        case .approval: .AutomaticActions.automaticActionsApproval
        }
    }

    var help: LocalizedStringResource {
        switch self {
        case .commentPublication: .AutomaticActions.automaticActionsPublicationHelp
        case .merge: .AutomaticActions.automaticActionsMergeHelp
        case .approval: .AutomaticActions.automaticActionsApprovalHelp
        }
    }
}

private extension MRAutomationPreference {
    var title: LocalizedStringResource {
        switch self {
        case .default: .Menu.menuScopeDefault
        case .on: .AutomaticActions.automaticActionsOn
        case .off: .AutomaticActions.automaticActionsOff
        }
    }

    var scopeChoice: MRAutomationScope.Choice {
        switch self {
        case .default: .inherit
        case .on: .forceOn
        case .off: .paused
        }
    }
}

private func scopeHelp(_ summary: MRAutomationControl.Summary, hasActionExceptions: Bool = false) -> Text {
    let source = String(localized: MRAutomationControl.sourceLabel(summary.source))
    return Text(scopeChoiceLabel(summary.choice)) + Text("\n")
        + Text(summary.active ? .Menu.menuScopeEnabledHelp(source) : .Menu.menuScopePausedHelp(source))
        + Text("\n") + Text(.Menu.menuScopeDraftSafetyHelp)
        + (hasActionExceptions ? Text("\n") + Text(.AutomaticActions.automaticActionsExceptionsHelp) : Text(""))
}

private func scopeChoiceLabel(_ choice: MRAutomationScope.Choice) -> LocalizedStringResource {
    switch choice {
    case .inherit: .Menu.menuScopeDefault
    case .active: .Menu.menuScopeIndividualOptIn
    case .forceOn: .Menu.menuScopeAlwaysOn
    case .paused: .Menu.menuScopeAlwaysOff
    }
}

private func draftAutomationMessage(target: MRAutomationScope.Target, projectPath: String?, followsDefaults: Bool = false) -> LocalizedStringResource {
    let reference = "\(projectPath ?? String(target.projectID)) !\(target.iid ?? 0)"
    return followsDefaults ? .Menu.menuScopeDraftConfirmationAutoMessage(reference) : .Menu.menuScopeDraftConfirmationMessage(reference)
}

/// Native menus dispose their SwiftUI content after a selection; the alert owns its window.
@MainActor
func confirmDraftAutomation(message: LocalizedStringResource) -> Bool {
    let alert = NSAlert()
    alert.messageText = String(localized: .Menu.menuScopeDraftConfirmationTitle)
    alert.informativeText = String(localized: message)
    alert.addButton(withTitle: String(localized: .Menu.menuScopeDraftConfirmationEnable))
    alert.addButton(withTitle: String(localized: .Menu.menuScopeCancel))
    NSApp.activate()
    return alert.runModal() == .alertFirstButtonReturn
}
