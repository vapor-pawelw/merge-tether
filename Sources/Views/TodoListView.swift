import AppKit
import SwiftUI

struct TodoListView: View {
    @Bindable var monitor: TodoMonitorService
    let updates: UpdateService
    @State private var section: Section
    @State private var setupOpenFailed = false
    @State private var showingAutomationActivity = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    init(monitor: TodoMonitorService, updates: UpdateService) {
        self.monitor = monitor
        self.updates = updates
        _section = State(initialValue: Section(rawValue: monitor.settings.lastMenuSection ?? "") ?? .todos)
    }

    var body: some View {
        VStack(spacing: 0) {
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

            switch section {
            case .todos:
                if let error = monitor.lastError {
                    ErrorBannerView(error: error) {
                        openWindow(id: "onboarding")
                    }
                } else if let id = monitor.failedAutomationTodoID {
                    Text(.Menu.menuErrorAutomation(id))
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.red.opacity(0.12))
                }
                todoContent
                if let todo = monitor.undoableTodo {
                    undoBanner(todo)
                }
            case .attention:
                if let assistant = monitor.unavailableAssistant {
                    assistantWarning(.Menu.menuAssistantUnavailable(String(localized: assistant.displayName)),
                                     button: .Menu.menuActionSettings, action: showSettings)
                } else if let warning = monitor.codexListenerWarning {
                    if monitor.codexPluginInstallation == .missing {
                        assistantWarning(warning, button: .Menu.menuActionSettings, action: showSettings)
                    } else if monitor.codexPluginInstallation != .disabled,
                              monitor.codexListenerHealth == .desktopClosed || monitor.codexListenerHealth == .dispatchBlocked {
                        assistantWarning(warning, button: .Menu.menuAssistantOpenCodex) {
                            Task { await monitor.openCodexForListener() }
                        }
                    } else {
                        assistantWarning(warning, button: monitor.codexPluginInstallation == .disabled
                                         ? .Menu.menuAssistantPluginEnable : .Menu.menuAssistantPluginSetup) {
                            Task { await openCodexPlugin() }
                        }
                    }
                }
                if setupOpenFailed, monitor.codexListenerWarning != nil {
                    Text(.Menu.menuAssistantSetupOpenFailed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                }
                attentionContent
            case .authored:
                AuthoredMergeRequestsView(
                    requests: monitor.authoredMergeRequests.requests,
                    isLoading: monitor.authoredMergeRequests.isLoading,
                    hasError: monitor.authoredMergeRequests.hasError,
                    scopeMenu: { scopeMenu(projectID: $0.projectID, iid: $0.iid, url: $0.webURL) }
                )
            case .activity:
                automationContent
            }

            Divider()

            footer
        }
        .frame(width: 420, height: 560)
        .task {
            await performFirstLaunchIfNeeded()
        }
        .onAppear { showSection() }
        .task(id: section) {
            guard section == .attention else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await monitor.attention.refreshPendingDrafts()
            }
        }
        .onChange(of: section) {
            monitor.settings.lastMenuSection = section.rawValue
            monitor.settings.save()
            showSection()
        }
        .onDisappear { monitor.authoredMergeRequests.setVisible(false) }
    }

    private enum Section: String, CaseIterable {
        case todos
        case attention
        case authored
        case activity

        /// Short label for the segmented control; `title` is used in the header.
        var segmentTitle: LocalizedStringResource {
            switch self {
            case .todos: .Menu.menuAuthoredTodosTab
            case .attention: .Menu.menuAttentionTab
            case .authored: .Menu.menuAuthoredTabShort
            case .activity: .Menu.menuScopeTitle
            }
        }

        var usesInboxRefresh: Bool { self != .authored }

        var title: LocalizedStringResource {
            switch self {
            case .todos: .Menu.menuHeaderTitle
            case .attention: .Menu.menuAttentionTab
            case .authored: .Menu.menuAuthoredTab
            case .activity: .Menu.menuScopeTitle
            }
        }
    }

    private func count(for section: Section) -> Int {
        switch section {
        case .todos: monitor.visibleTodos.count
        case .attention: monitor.attentionCount
        case .authored: monitor.authoredMergeRequests.requests.count
        case .activity: monitor.pipelineHandoffs.count
        }
    }

    private func tabLabel(_ section: Section) -> String {
        let title = String(localized: section.segmentTitle)
        let count = count(for: section)
        return count > 0 ? String(localized: .Menu.menuTabCount(title, count)) : title
    }

    private func showSection() {
        monitor.authoredMergeRequests.setVisible(section == .authored || section == .activity)
        if section == .todos { monitor.markMenuOpened() }
        if section.usesInboxRefresh {
            Task { await monitor.refreshNow() }
        }
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
                if section == .todos {
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
                    if section.usesInboxRefresh {
                        Task { await monitor.refreshNow() }
                    } else {
                        monitor.authoredMergeRequests.refreshIfNeeded()
                    }
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
                .help(Text(.Menu.menuHeaderRefreshTooltip))
                .accessibilityLabel(Text(.Menu.menuHeaderRefreshTooltip))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var isRefreshing: Bool {
        section.usesInboxRefresh ? monitor.isLoading : monitor.authoredMergeRequests.isLoading
    }

    @ViewBuilder
    private var headerSubtitle: some View {
        if let lastRefresh = section.usesInboxRefresh ? monitor.lastRefresh : monitor.authoredMergeRequests.lastRefresh {
            Text(.Menu.menuHeaderUpdated(RelativeTime.string(from: lastRefresh)))
        } else {
            Text(.Menu.menuHeaderNeverUpdated)
        }
    }

    @ViewBuilder
    private var todoContent: some View {
        if monitor.visibleTodos.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(.Menu.menuEmptyTitle)
                    .font(.headline)
                Text(.Menu.menuEmptySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(monitor.visibleTodos) { todo in
                        TodoRowView(
                            todo: todo,
                            currentUsername: monitor.glab.currentUsername,
                            automationState: monitor.automationAction(for: todo),
                            scopeMenu: todo.targetType == .mergeRequest ? todo.target.iid.flatMap {
                                scopeMenu(projectID: todo.project.id, iid: $0, url: todo.targetURL)
                            } : nil,
                            onAutomation: { Task { await monitor.runAutomationManually(for: todo) } },
                            onMarkDone: { withAnimation { monitor.markDoneWithUndo(todo) } },
                            onOpen: {
                                NSWorkspace.shared.open(todo.targetURL)
                                dismissMenuBarExtra()
                            }
                        )
                        Divider()
                    }
                }
            }
        }
    }

    private func scopeMenu(projectID: Int, iid: Int, url: URL) -> MRAutomationScopeMenu? {
        monitor.scopeTarget(projectID: projectID, iid: iid, url: url).map {
            MRAutomationScopeMenu(settings: monitor.settings, target: $0, projectPath: url.gitLabProjectPath)
        }
    }

    private var automationContent: some View {
        VStack(spacing: 8) {
            Picker(selection: $showingAutomationActivity) {
                Text(.Menu.menuScopeManaged).tag(false)
                Text(.Menu.menuWorkflowActivityTabShort).tag(true)
            } label: { Text(.Menu.menuScopeTitle) }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.top, 8)
            .padding(.horizontal, 14)

            if showingAutomationActivity {
                MergeWorkflowActivityView(entries: monitor.authoredMergeRequests.workflow.entries,
                                          onHandoff: monitor.authoredMergeRequests.workflow.confirmPipelineHandoff)
            } else {
                ManagedMergeRequestsView(monitor: monitor)
            }
        }
    }

    @ViewBuilder
    private var attentionContent: some View {
        let items = monitor.attentionItems
        let handoffs = monitor.assistantHandoffs
        if items.isEmpty && handoffs.isEmpty && !monitor.attention.hasError {
            ContentUnavailableView {
                Label {
                    Text(.Menu.menuAttentionEmpty)
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    let open = items.filter { $0.section == .open }
                    let confirmations = items.filter(\.needsConfirmation)
                    let drafts = items.filter { $0.section == .draftMergeRequests && !$0.needsConfirmation }
                    if !confirmations.isEmpty {
                        groupHeader(.Menu.menuConfirmSection, symbol: "hand.raised.fill", tint: .accentColor)
                        ForEach(confirmations) { item in
                            ConfirmationQueueRow(
                                item: item,
                                state: monitor.attention.confirmationStates[item.id],
                                onPublish: { Task { await monitor.attention.publishDrafts(of: item.id) } },
                                onApprove: { Task { await monitor.attention.approve(item.id) } },
                                onOpen: {
                                    NSWorkspace.shared.open(item.url)
                                    dismissMenuBarExtra()
                                },
                                onManage: manageAction(for: item)
                            )
                        }
                    }
                    if !open.isEmpty || monitor.attention.hasError {
                        attentionRows(open)
                    }
                    if !monitor.pipelineHandoffs.isEmpty {
                        Button {
                            section = .activity
                        } label: {
                            Text(.Menu.menuAttentionHandoffs(monitor.pipelineHandoffs.count))
                                .font(.subheadline)
                        }
                        .buttonStyle(.link)
                    }
                    if !handoffs.isEmpty { assistantRows(handoffs) }
                    if !drafts.isEmpty {
                        groupHeader(.Menu.menuAttentionDraftSection, symbol: "pencil.line", tint: .secondary)
                        attentionCards(drafts)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private func attentionRows(_ items: [MergeRequestAttentionMonitor.Item]) -> some View {
        Group {
            groupHeader(.Menu.menuAttentionTitle(items.count), symbol: "exclamationmark.circle.fill", tint: .orange)

            if monitor.attention.hasError {
                Text(.Menu.menuAttentionPartial)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            attentionCards(items)
        }
    }

    private func attentionCards(_ items: [MergeRequestAttentionMonitor.Item]) -> some View {
        ForEach(items) { item in
            AttentionRow(item: item, feedbackAction: monitor.attentionFeedbackAction(for: item), onFeedback: {
                Task { await monitor.runAttentionFeedback(for: item) }
            }, onManage: manageAction(for: item)) {
                NSWorkspace.shared.open(item.url)
                dismissMenuBarExtra()
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

    @ViewBuilder
    private func assistantRows(_ handoffs: [AssistantAutomationRunner.Handoff]) -> some View {
        Group {
            groupHeader(.Menu.menuAssistantQueue, symbol: "sparkles", tint: .accentColor)

            if monitor.desktopHandoffError {
                Text(.Menu.menuAssistantOpenError).font(.caption).foregroundStyle(.orange)
            }

            ForEach(handoffs) { handoff in
                assistantHandoffRow(handoff).font(.caption)
            }
        }
    }

    private func assistantHandoffRow(_ handoff: AssistantAutomationRunner.Handoff) -> some View {
        let usesRelay = AssistantAutomationRunner.usesRelay(handoff, settings: monitor.settings)
        let claimed = CodexDesktopRelay.hasClaim(handoff.id)
        let canRequest = CodexDesktopRelay.canRequestDispatch(handoff, settings: monitor.settings) && !claimed
        return VStack(alignment: .leading, spacing: 5) {
            Text(handoff.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            if handoff.relayComplete == true {
                Text(.Menu.menuAssistantChatCreated)
            } else if claimed {
                Text(.Menu.menuAssistantListenerClaimed)
            } else if canRequest && handoff.openedAt != nil {
                Text(.Menu.menuAssistantDraftAlreadyOpened)
            } else if usesRelay && handoff.openedAt == nil {
                Text(.Menu.menuAssistantListenerPending)
            } else if canRequest {
                Text(.Menu.menuAssistantDispatchAvailable)
            } else if handoff.chatID != nil {
                Text(.Menu.menuAssistantPastePrompt)
            } else {
                Text(.Menu.menuAssistantSendPrompt)
            }
            HStack {
                if canRequest {
                    Button {
                        monitor.requestCodexDispatch(handoff.id)
                    } label: {
                        Text(.Menu.menuAssistantSendViaPlugin)
                    }
                    .buttonStyle(.borderedProminent)
                    if !usesRelay {
                        Menu {
                            manualHandoffActions(handoff)
                        } label: {
                            Text(.Menu.menuAssistantManualOptions)
                        }
                    }
                } else if handoff.relayComplete == true || (!usesRelay && !claimed) {
                    manualHandoffActions(handoff)
                } else if !claimed {
                    Button {
                        Task { await monitor.openCodexForListener() }
                    } label: {
                        Text(.Menu.menuAssistantLaunchCodex)
                    }
                    .disabled(!monitor.availableAssistants.contains(.codex))
                }

                Spacer(minLength: 0)
                Button {
                    monitor.dismissAssistantHandoff(handoff.id)
                } label: {
                    Text(.Menu.menuAssistantClear)
                }
                .help(Text(.Menu.menuAssistantClearHelp))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private func manualHandoffActions(_ handoff: AssistantAutomationRunner.Handoff) -> some View {
        Button {
            Task { await monitor.openAssistantHandoff(handoff.id) }
        } label: {
            if handoff.key.assistant == .codex {
                Text(handoff.chatID == nil ? .Menu.menuAssistantOpenCodexDraft : .Menu.menuAssistantOpenCodexChat)
            } else {
                Text(handoff.chatID == nil ? .Menu.menuAssistantOpenClaude : .Menu.menuAssistantContinueClaude)
            }
        }
        .disabled(!monitor.availableAssistants.contains(handoff.key.assistant))
        Button {
            AssistantAutomationRunner.copyPrompt(handoff.prompt)
        } label: {
            Text(.Menu.menuAssistantCopyPrompt)
        }
    }

    private func openCodexPlugin() async {
        setupOpenFailed = false
        do {
            guard let url = try await CodexPluginInstaller.setupURL() else {
                showSettings()
                return
            }
            guard let app = AssistantAutomationRunner.desktopApplication(.codex) else {
                setupOpenFailed = true
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
        } catch {
            setupOpenFailed = true
        }
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
        case .todos:
            Text(.Menu.menuFooterPendingCount(monitor.visibleTodos.count))
        case .attention:
            Text(.Menu.menuFooterAttentionCount(monitor.attentionCount))
        case .authored:
            let requests = monitor.authoredMergeRequests.requests
            if !requests.isEmpty {
                let ready = requests.filter(\.blockers.isEmpty).count
                Text(.Menu.menuFooterAuthoredSummary(ready, requests.count - ready))
            }
        case .activity:
            if !monitor.pipelineHandoffs.isEmpty {
                Text(.Menu.menuFooterHandoffCount(monitor.pipelineHandoffs.count))
            }
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


private struct AttentionRow: View {
    let item: MergeRequestAttentionMonitor.Item
    let feedbackAction: TodoAutomationService.ActionState?
    let onFeedback: () -> Void
    let onManage: (() -> Void)?
    let onOpen: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            openButton
            if let onManage {
                Button(action: onManage) { Label { Text(.Menu.menuScopeAddManaged) } icon: { Image(systemName: "bolt.badge.plus") } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.leading, 12)
            }
            if feedbackAction == .running {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text(.Menu.menuTodoAutomationRunning).font(.caption)
                }
                .padding(.leading, 12)
            } else if feedbackAction == .ready(.assistant) || feedbackAction == .failed {
                if feedbackAction == .failed {
                    Text(.Menu.menuTodoAutomationFailed).font(.caption).foregroundStyle(.orange)
                        .padding(.leading, 12)
                }
                Button(action: onFeedback) { Text(.Menu.menuTodoAutomationPrepareFollowUp) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.leading, 12)
            }
        }
    }

    private var openButton: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.draftCount > 0 ? "text.bubble" : "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .frame(width: 24)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("!\(item.id.iid) · \(item.title)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
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
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isHovered ? Color.primary.opacity(0.10) : Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(.Menu.menuActionOpenInBrowser))
        .onHover { isHovered = $0 }
    }
}
