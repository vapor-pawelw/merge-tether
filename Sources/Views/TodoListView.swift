import AppKit
import SwiftUI

struct TodoListView: View {
    @Bindable var monitor: TodoMonitorService
    let updates: UpdateService
    let inboxOnly: Bool
    @State private var section: Section
    @State private var setupOpenFailed = false
    @State private var dependencySetup: AutomationAssistant?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    init(monitor: TodoMonitorService, updates: UpdateService, inboxOnly: Bool = false) {
        self.monitor = monitor
        self.updates = updates
        self.inboxOnly = inboxOnly
        _section = State(initialValue: inboxOnly ? .inbox : Section.restored(from: monitor.settings.lastMenuSection))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !inboxOnly {
            header

            Picker(selection: $section) {
                ForEach(Section.allCases, id: \.self) { section in
                    Text(verbatim: tabLabel(section)).tag(section)
                }
            } label: {
                Text(.Menu.menuHeaderTitle)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            Divider()

            }

            assistantWarnings

            switch section {
            case .inbox:
                inboxWarnings
                inboxContent
                if let todo = monitor.undoableTodo { undoBanner(todo) }
            case .mergeRequests:
                MergeRequestsView(monitor: monitor)
            }

            if !inboxOnly {
                Divider()
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if !inboxOnly { await performFirstLaunchIfNeeded() }
        }
        .onAppear { showSection() }
        .task(id: section) {
            guard section == .inbox else { return }
            while !Task.isCancelled {
                await monitor.attention.refreshPendingDrafts()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .onChange(of: section) {
            monitor.settings.lastMenuSection = section.rawValue
            monitor.settings.save()
            showSection()
        }
        .onDisappear { if !inboxOnly { monitor.authoredMergeRequests.setVisible(false) } }
        .sheet(item: $dependencySetup) { assistant in
            AssistantSetupView(assistant: assistant, requireCLI: true) {
                monitor.assistantDependencies.refresh(requireCLI: monitor.requiresAssistantCLI, force: true)
            }
        }
    }

    private typealias Section = MainMenuSection

    private func count(for section: Section) -> Int {
        switch section {
        case .inbox: monitor.badgeCount
        case .mergeRequests: monitor.ownMergeRequestItems.count + monitor.reviewedMergeRequestItems.count
        }
    }

    private func tabLabel(_ section: Section) -> String {
        let title = String(localized: section.segmentTitle)
        let count = count(for: section)
        return count > 0 ? String(localized: .Menu.menuTabCount(title, count)) : title
    }

    private func showSection() {
        if !inboxOnly { monitor.authoredMergeRequests.setVisible(section == .mergeRequests) }
        if section == .inbox { monitor.markMenuOpened() }
        // Opening the menu or switching tabs shouldn't start a full glab sweep every time.
        guard monitor.lastRefresh.map({ Date().timeIntervalSince($0) > 30 }) ?? true else { return }
        Task { await monitor.refreshNow() }
    }

    private func performFirstLaunchIfNeeded() async {
        if !monitor.settings.onboardingCompleted {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "onboarding")
            updates.seedIfNeeded()
            return
        }

        if updates.shouldShowWhatsNew {
            updates.loadWhatsNew()
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "whats-new")
        } else {
            updates.seedIfNeeded()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.headline)
                headerSubtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                if section == .inbox {
                    Button {
                        NSWorkspace.shared.open(monitor.dashboardURL)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .help(Text(.Menu.menuHeaderOpenInBrowserTooltip))
                    .accessibilityLabel(Text(.Menu.menuHeaderOpenInBrowserTooltip))
                }

                Button {
                    Task { await monitor.refreshManually() }
                } label: {
                    ZStack {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .help(Text(.Menu.menuHeaderRefreshTooltip))
                .accessibilityLabel(Text(.Menu.menuHeaderRefreshTooltip))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var isRefreshing: Bool {
        monitor.showsGlobalRefreshProgress
    }

    @ViewBuilder
    private var headerSubtitle: some View {
        if let lastRefresh = monitor.lastRefresh {
            Text(.Menu.menuHeaderUpdated(RelativeTime.string(from: lastRefresh)))
        } else {
            Text(.Menu.menuHeaderNeverUpdated)
        }
    }

    private func todoRow(_ todo: Todo, inbox: InboxSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            TodoRowView(
                todo: todo, currentUsername: monitor.glab.currentUsername,
                automationState: monitor.automationAction(for: todo),
                scopeMenu: todo.targetType == .mergeRequest ? todo.target.iid.flatMap {
                    scopeMenu(projectID: todo.project.id, iid: $0, url: todo.targetURL, isDraft: todo.isDraft)
                } : nil,
                onAutomation: { Task { await monitor.runAutomationManually(for: todo) } },
                onMarkDone: { withAnimation { monitor.markDoneWithUndo(todo) } },
                onOpen: {
                    NSWorkspace.shared.open(todo.targetURL)
                    dismissMenuBarExtra()
                }
            )
            if todo.targetType == .mergeRequest {
                AssistantContextMenu(mergeRequestURL: todo.targetURL, title: todo.displayTitle,
                                     settings: monitor.settings)
                    .padding(.horizontal, 12)
            }
            if let id = inbox.todoApprovals[todo.id] {
                todoApproval(id)
            }
            if let group = monitor.manualAssistantGroup(for: todo),
               let handoff = monitor.manualHandoff(in: group) {
                assistantHandoffRow(handoff)
            }
        }
    }

    private func todoApproval(_ id: MergeRequestAttentionMonitor.Item.ID) -> some View {
        let state = monitor.attention.confirmationStates[id]
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { Task { await monitor.attention.approve(id) } } label: { Text(.Menu.menuConfirmApprove) }
                    .buttonStyle(.borderedProminent)
                    .disabled(state == .approving || state == .publishing)
                if state == .approving { ProgressView().controlSize(.small) }
            }
            if state == .failed { Text(.Menu.menuConfirmFailed).foregroundStyle(.orange) }
            if state == .changed { Text(.Menu.menuConfirmChanged).foregroundStyle(.orange) }
        }
        .font(.caption).controlSize(.small).padding(.horizontal, 12)
    }

    private func scopeMenu(projectID: Int, iid: Int, url: URL, isDraft: Bool) -> MRAutomationScopeMenu? {
        monitor.scopeTarget(projectID: projectID, iid: iid, url: url).map {
            MRAutomationScopeMenu(monitor: monitor, target: $0, projectPath: url.gitLabProjectPath, isDraft: isDraft)
        }
    }

    @ViewBuilder
    private var inboxWarnings: some View {
        if let error = monitor.lastError {
            ErrorBannerView(error: error) { openWindow(id: "onboarding") }
        } else if let id = monitor.failedAutomationTodoID {
            Text(.Menu.menuErrorAutomation(id)).font(.caption).padding(10).background(.red.opacity(0.12))
        }
    }

    @ViewBuilder
    private var assistantWarnings: some View {
        if let assistant = monitor.unavailableAssistant {
            assistantWarning(monitor.assistantDependencyWarning ?? .Menu.menuAssistantUnavailable(String(localized: assistant.displayName)),
                             button: .Settings.settingsAssistantSetupAction) { dependencySetup = assistant }
        }
    }

    @ViewBuilder
    private var inboxContent: some View {
        let inbox = monitor.inbox
        let items = inbox.attention
        if monitor.badgeCount == 0 && monitor.isLoading && monitor.lastRefresh == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if monitor.badgeCount == 0 && !monitor.attention.hasError && monitor.lastError == nil
                    && monitor.failedAutomationTodoID == nil {
            ContentUnavailableView {
                Label { Text(.Menu.menuInboxEmpty) } icon: { Image(systemName: "checkmark.circle") }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if monitor.attention.hasError {
                        Text(.Menu.menuAttentionPartial).font(.caption).foregroundStyle(.secondary)
                    }
                    let open = items.filter { $0.section != .draftMergeRequests }
                    let drafts = items.filter { $0.section == .draftMergeRequests }
                    // What the assistant prepared and only you can send comes first.
                    let ready = open.filter { $0.needsConfirmation && !$0.requiresDiscussionRecheck }
                    let other = open.filter { !$0.needsConfirmation || $0.requiresDiscussionRecheck }
                    if !ready.isEmpty {
                        groupHeader(.Menu.menuConfirmSection, symbol: "checkmark.seal", tint: .green)
                        attentionCards(ready)
                    }
                    if !other.isEmpty {
                        if !ready.isEmpty {
                            groupHeader(.Menu.menuAttentionTab, symbol: "exclamationmark.circle", tint: .orange)
                        }
                        attentionCards(other)
                    }
                    if !inbox.todos.isEmpty {
                        groupHeader(.Menu.menuInboxGitLabTodos, symbol: "tray", tint: .accentColor)
                        ForEach(inbox.todos) { todo in
                            todoRow(todo, inbox: inbox)
                            Divider()
                        }
                    }
                    if !monitor.standaloneManualAssistantGroups.isEmpty {
                        groupHeader(.Menu.menuInboxAssistantAction, symbol: "hand.raised", tint: .orange)
                        ForEach(monitor.standaloneManualAssistantGroups) { group in
                            if let handoff = monitor.manualHandoff(in: group) { assistantHandoffRow(handoff) }
                        }
                    }
                    if !drafts.isEmpty {
                        groupHeader(.Menu.menuAttentionDraftSection, symbol: "pencil.line", tint: .secondary)
                        attentionCards(drafts)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MRRowLayout.listInset)
                .padding(.vertical, MRRowLayout.verticalInset)
            }
        }
    }

    private func attentionCards(_ items: [MergeRequestAttentionMonitor.Item]) -> some View {
        ForEach(items) { item in
            if item.needsConfirmation {
                let publishSelected: (([GitLabDraftNote]) -> Void)? = publicationTarget(for: item).map { target in
                    { selected in Task { await monitor.attention.publishDrafts(selected, for: target) } }
                }
                ConfirmationQueueRow(
                    item: item, state: monitor.attention.confirmationStates[item.id],
                    onPublish: { Task { await monitor.attention.publishDrafts(of: item.id) } },
                    onApprove: { Task { await monitor.attention.approve(item.id) } },
                    onOpen: { NSWorkspace.shared.open(item.url); dismissMenuBarExtra() },
                    onManage: manageAction(for: item), onPublishSelected: publishSelected,
                    additionalActions: attentionActions(item)
                )
            } else {
                AttentionRow(item: item, onManage: manageAction(for: item), onOpen: {
                    NSWorkspace.shared.open(item.url)
                    dismissMenuBarExtra()
                }, additionalActions: attentionActions(item))
            }
        }
    }

    private func publicationTarget(for item: MergeRequestAttentionMonitor.Item) -> MRDiscussionTarget? {
        guard let host = monitor.glab.resolvedHost, let username = monitor.glab.currentUsername,
              item.url.isGitLabMergeRequest(host: host, iid: item.id.iid) else { return nil }
        return .init(host: host, username: username, projectID: item.id.projectID, iid: item.id.iid, url: item.url)
    }

    private func attentionActions(_ item: MergeRequestAttentionMonitor.Item) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            AssistantContextMenu(mergeRequestURL: item.url, title: item.title,
                                 settings: monitor.settings)
            ReReviewControls(item: item, monitor: monitor.attention)
            InboxAttentionActions(item: item, feedbackAction: monitor.attentionFeedbackAction(for: item),
                                  onFeedback: { Task { await monitor.runAttentionFeedback(for: item) } },
                                  onPipeline: { monitor.confirmPipelineHandoff(for: item.id) },
                                  onMerge: { NSWorkspace.shared.open(item.url); dismissMenuBarExtra() })
            if let group = monitor.manualAssistantGroup(for: item), let handoff = monitor.manualHandoff(in: group) {
                assistantHandoffRow(handoff)
            }
        }
    }

    private func manageAction(for item: MergeRequestAttentionMonitor.Item) -> (() -> Void)? {
        guard monitor.unmanagedTarget(for: item) != nil else { return nil }
        return { Task { await monitor.manageAttentionItem(item) } }
    }

    private func groupHeader(_ title: LocalizedStringResource, symbol: String, tint: Color) -> some View {
        Label {
            Text(title).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.caption.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
    }

    private func assistantWarning(
        _ message: LocalizedStringResource, button: LocalizedStringResource, action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(message)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            Button(action: action) {
                Text(button)
            }
            .buttonStyle(.link)
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }

    private func assistantHandoffRow(_ handoff: AssistantAutomationRunner.Handoff) -> some View {
        AssistantJobRow(handoff: handoff, monitor: monitor)
    }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func undoBanner(_ todo: Todo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(.Menu.menuUndoMarkedDone(todo.displayTitle))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                withAnimation { monitor.undoMarkDone() }
            } label: {
                Text(.Menu.menuUndoAction)
            }
            .keyboardShortcut("z", modifiers: .command)
            .controlSize(.small)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var footer: some View {
        HStack {
            footerSummary
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: showSettings) {
                Text(.Menu.menuActionSettings)
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text(.Menu.menuActionQuit)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var footerSummary: some View {
        switch section {
        case .inbox: Text(.Menu.menuInboxCount(monitor.badgeCount))
        case .mergeRequests: Text(.Menu.menuMrCount(monitor.ownMergeRequestItems.count, monitor.reviewedMergeRequestItems.count))
        }
    }

    private func dismissMenuBarExtra() {
        for window in NSApplication.shared.windows {
            let className = String(describing: type(of: window))
            if className.contains("MenuBarExtra") || className.contains("NSPopover") {
                window.orderOut(nil)
            }
        }
    }
}


private struct AttentionRow<AdditionalActions: View>: View {
    let item: MergeRequestAttentionMonitor.Item
    let onManage: (() -> Void)?
    let onOpen: () -> Void
    let additionalActions: AdditionalActions
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            openButton
            if let onManage {
                Button(action: onManage) { Label { Text(.Menu.menuScopeAddManaged) } icon: { Image(systemName: "bolt.badge.plus") } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            additionalActions
        }
        .mrRowContentPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? Color.primary.opacity(0.10) : Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 7))
    }

    private var openButton: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.draftCount > 0 ? "text.bubble" : "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .frame(width: 24)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    MergeRequestTitle(title: "!\(item.id.iid) · \(item.title)",
                                      isDraft: item.section == .draftMergeRequests)
                    RepositoryPathText(item.url.gitLabProjectPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    VStack(alignment: .leading, spacing: 1) {
                        if item.draftCount > 0 { Text(.Menu.menuAttentionDrafts(item.draftCount)) }
                        if item.reReviewUnconfirmed { Text(.Menu.menuAttentionReReviewUnconfirmed) }
                        if item.needsDiscussion || !item.feedback.isEmpty { Text(.Menu.menuAttentionDiscussions) }
                        if item.hasConflict { Text(.Menu.menuAttentionConflict) }
                        if item.needsChanges { Text(.Menu.menuAttentionChanges) }
                        if item.failedPipeline { Text(.Menu.menuAttentionPipeline) }
                        if item.needsPipelineHandoff { Text(.Menu.menuAttentionPipelineHandoff) }
                    }
                    .foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(.secondary)
                    .mrRowAccessoryFrame()
                    .accessibilityHidden(true)
            }
            .font(.caption)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(.Menu.menuActionOpenInBrowser))
        .onHover { isHovered = $0 }
    }
}

private extension MainMenuSection {
    var segmentTitle: LocalizedStringResource { self == .inbox ? .Menu.menuInboxTab : .Menu.menuMrTab }
    var title: LocalizedStringResource { segmentTitle }
}
