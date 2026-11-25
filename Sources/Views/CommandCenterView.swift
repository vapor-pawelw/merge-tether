import AppKit
import MergeTetherRemote
import SwiftUI

struct CommandCenterView: View {
    let monitor: TodoMonitorService
    let updates: UpdateService
    @State private var showingAdd = false
    @State private var showingInbox = false
    @State private var regenerationPresentation: DraftRegenerationPresentation?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let initialRefresh = monitor.boardRefreshState
        let display = monitor.commandCenterDisplayFrame
        VStack(spacing: 0) {
            statusBanners
            if initialRefresh == .syncing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(.Board.boardInitialSync)
                    Spacer()
                }
                .font(.caption).padding(10)
                .help(Text(.Board.boardInitialSyncHelp))
            }
            NotificationPermissionView(notifications: monitor.notifications,
                                       enabled: monitor.settings.notificationsEnabled)
                .padding(.horizontal, 18)
            CommandCenterBoardView(monitor: monitor, board: display.board, refreshState: initialRefresh)
                .id("\(monitor.glab.resolvedHost ?? "")|\(monitor.glab.currentUsername ?? "")")
            if let removal = monitor.undoableReviewRemoval { reviewRemovalBanner(removal) }
            if let todo = monitor.undoableTodo { undoBanner(todo) }
            accountFooter
        }
        .frame(minWidth: 640, minHeight: 680)
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 10) {
                if let notice = monitor.automationToggleNotices.current {
                    AutomationToggleNoticeView(notice: notice) { monitor.automationToggleNotices.dismiss(notice.id) }
                }
                if let event = monitor.autoHandledEventBanner {
                    AutoHandledEventBannerView(event: event) { monitor.dismissAutoHandledEventBanner(event.id) }
                }
            }
            .padding(18)
        }
        .navigationTitle(Text(.Board.boardTitle))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { openWindow(id: "remote-access") } label: {
                    Label { Text(.Remote.remoteMacPairPhone) } icon: { Image(systemName: "iphone") }
                }
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                globalAutomationToggle
                draftRegenerationButton
                Button { showingAdd = true } label: {
                    Label { Text(.Board.boardAdd) } icon: { Image(systemName: "plus") }
                }
                Button { Task { await monitor.refreshManually() } } label: {
                    Label { Text(.CommandCenter.commandCenterRefresh) } icon: {
                        if monitor.showsGlobalRefreshProgress { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(monitor.showsGlobalRefreshProgress)
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showingInbox.toggle() } label: {
                    Label {
                        Text(.Board.boardInboxButton)
                    } icon: {
                        Image(systemName: "tray")
                            .overlay(alignment: .topTrailing) {
                                let count = display.inbox.items.count
                                if count > 0 {
                                    Text(count > 99 ? "99+" : String(count))
                                        .font(.system(size: 9, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 3)
                                        .frame(minWidth: 14, minHeight: 14)
                                        .background(.red, in: Capsule())
                                        .offset(x: 7, y: -7)
                                        .accessibilityHidden(true)
                                }
                            }
                    }
                }
                .help(Text(.Board.boardInboxButton))
                .accessibilityLabel(
                    !display.inbox.items.isEmpty || monitor.inboxRefreshState == .current
                        ? Text(.Board.boardInboxAccessibilityCount(display.inbox.items.count))
                        : Text(.Board.boardInboxButton))
                .popover(isPresented: $showingInbox, arrowEdge: .top) {
                    CommandCenterInboxView(monitor: monitor)
                }
                Button { openSettings() } label: {
                    Label { Text(.CommandCenter.commandCenterSettings) } icon: { Image(systemName: "gearshape") }
                }
            }
        }
        .sheet(isPresented: $showingAdd) { CommandCenterAddMergeRequestView(monitor: monitor) }
        .sheet(item: $regenerationPresentation) { monitor.draftRegenerationSheet($0) }
        .onChange(of: monitor.glab.accountRevision) { _, _ in regenerationPresentation = nil }
        .alert(Text(.DraftMR.failed), isPresented: Binding(
            get: { monitor.markMergeRequestReadyError != nil },
            set: { if !$0 { monitor.markMergeRequestReadyError = nil } })) {
                Button(role: .cancel) { monitor.markMergeRequestReadyError = nil } label: { Text(.DraftMR.ok) }
            } message: {
                if let error = monitor.markMergeRequestReadyError { Text(verbatim: error) }
            }
        .task { await prepareWindow() }
        .task {
            while !Task.isCancelled {
                monitor.assistantDependencies.refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            monitor.refreshAvailableAssistants()
        }
        .onAppear {
            MainWindowPresentation.openWindow = { openWindow(id: "main") }
            SettingsNavigation.shared.openSettingsWindow = { openSettings() }
            monitor.authoredMergeRequests.setVisible(true)
            monitor.markMenuOpened()
        }
        .onDisappear { monitor.authoredMergeRequests.setVisible(false) }
    }

    @ViewBuilder
    private var draftRegenerationButton: some View {
        let regeneration = monitor.draftRegeneration
        if let phase = regeneration.batch?.phase {
            Button { regenerationPresentation = .init(scope: nil) } label: {
                Label(phase.regenerationTitle, systemImage: "wand.and.stars")
                    .overlay(alignment: .topTrailing) {
                        if phase == .ready {
                            Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                                .offset(x: 3, y: -3).accessibilityHidden(true)
                        }
                    }
            }
            .help(Text(phase.regenerationTitle))
            .accessibilityIdentifier("draft-regeneration.resume")
        } else if regeneration.count(for: .all) > 0 {
            Button {
                guard requireCodingAssistant(monitor) else { return }
                regenerationPresentation = .init(scope: .all)
            } label: {
                Label(.DraftRegeneration.draftRegenerationAllAction, systemImage: "wand.and.stars")
            }
            .disabled(!regeneration.isAvailable)
            .help(Text(.DraftRegeneration.draftRegenerationAllAction))
            .accessibilityIdentifier("draft-regeneration.all")
        }
    }

    /// App-wide killswitch: off overrides presets and per-MR choices without changing them.
    private var globalAutomationToggle: some View {
        let settings = monitor.settings
        let available = settings.configuredAutomationAvailable
        let active = settings.automationGloballyActive
        // A plain toolbar button keeps the standard chrome; the bolt alone shows the state.
        return Button { monitor.requestGlobalAutomationToggle(confirm: confirmGlobalAutomationChange) } label: {
            Label { Text(.CommandCenter.commandCenterAutomationToggle) } icon: {
                Image(systemName: active ? "bolt.fill" : "bolt.slash")
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
            }
        }
        .disabled(!available)
        .accessibilityAddTraits(active ? .isSelected : [])
        .help(Text(!available ? .CommandCenter.commandCenterAutomationHelpManual
            : active ? .CommandCenter.commandCenterAutomationHelpActive : .CommandCenter.commandCenterAutomationHelpSuspended))
    }

    private func confirmGlobalAutomationChange(enabling: Bool) -> TodoMonitorService.GlobalAutomationConfirmation {
        let alert = NSAlert()
        alert.alertStyle = enabling ? .informational : .warning
        alert.messageText = String(localized: enabling ? .CommandCenter.commandCenterAutomationConfirmResumeTitle
            : .CommandCenter.commandCenterAutomationConfirmPauseTitle)
        alert.informativeText = String(localized: enabling ? .CommandCenter.commandCenterAutomationConfirmResumeMessage
            : .CommandCenter.commandCenterAutomationConfirmPauseMessage)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: .CommandCenter.commandCenterAutomationConfirmDontAskAgain)
        let cancel = alert.addButton(withTitle: String(localized: .Menu.menuScopeCancel))
        cancel.keyEquivalent = "\r"
        alert.addButton(withTitle: String(localized: enabling ? .CommandCenter.commandCenterAutomationSuspendedResume
            : .CommandCenter.commandCenterAutomationConfirmPauseAction))
        guard alert.runModal() == .alertSecondButtonReturn else { return .cancel }
        return alert.suppressionButton?.state == .on ? .confirmAndSkipFuturePrompts : .confirm
    }

    @ViewBuilder
    private var statusBanners: some View {
        PersistenceDegradedBanner(settings: monitor.settings)
        if monitor.settings.configuredAutomationAvailable, !monitor.settings.automationGloballyEnabled {
            HStack(spacing: 10) {
                Label { Text(.CommandCenter.commandCenterAutomationSuspendedBanner) } icon: {
                    Image(systemName: "bolt.slash.fill")
                }
                Spacer()
                Button { monitor.setAutomationGloballyEnabled(true) } label: {
                    Text(.CommandCenter.commandCenterAutomationSuspendedResume)
                }
                .buttonStyle(.link)
            }
            .font(.caption).padding(10).background(.orange.opacity(0.1))
        }
        if let error = monitor.lastError {
            ErrorBannerView(error: error, authStatus: monitor.glab.authStatus, isRetrying: monitor.isLoading,
                onRetry: { Task { await monitor.refreshManually() } },
                onOpenSetup: { openWindow(id: "onboarding") },
                onOpenIntegration: { SettingsNavigation.shared.showIntegration { openSettings() } })
        } else if monitor.boardRefreshState == .unavailable {
            HStack {
                Label { Text(.Board.boardInitialSyncFailed) } icon: { Image(systemName: "exclamationmark.triangle") }
                Spacer()
                Button { Task { await monitor.refreshManually() } } label: { Text(.CommandCenter.commandCenterRefresh) }
            }
            .font(.caption).foregroundStyle(.orange).padding(10)
        } else if monitor.attention.hasError || monitor.authoredMergeRequests.hasError {
            HStack(spacing: 10) {
                Label { Text(.Board.boardStale) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(.orange)
                Spacer(minLength: 0)
                Button(.Board.boardStaleRetry) { Task { await monitor.refreshManually() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(monitor.showsGlobalRefreshProgress)
            }
            .font(.caption).padding(10)
        }
        if monitor.settings.onboardingCompleted {
            AssistantCLIHealthBanner(monitor: monitor)
        }
        if let error = monitor.assistantJobActionError {
            Text(verbatim: error).font(.caption).foregroundStyle(.orange).padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let id = monitor.failedAutomationTodoID {
            Text(.Menu.menuErrorAutomation(id)).font(.caption).padding(8).foregroundStyle(.orange)
        }
    }

    /// Your GitLab name and avatar come from an authored merge request when one is loaded.
    private var accountPerson: PersonIdentity {
        guard let username = monitor.glab.currentUsername else { return .init(name: nil, username: nil) }
        let own = monitor.authoredMergeRequests.requests.lazy.map(\.request.author)
            .first { $0.username.caseInsensitiveCompare(username) == .orderedSame }
        return own?.person ?? .init(name: nil, username: username)
    }

    private var accountFooter: some View {
        HStack(spacing: 12) {
            PersonLabel(person: accountPerson, fallback: Text(.CommandCenter.commandCenterAccountUnavailable))
            if let host = monitor.glab.resolvedHost { Text(verbatim: host).foregroundStyle(.secondary) }
            Spacer()
            if monitor.settings.onboardingCompleted {
                Button { SettingsNavigation.shared.showCodingAgent(openSettings: { openSettings() }) } label: {
                    HStack(spacing: 5) {
                        if let assistant = monitor.settings.automation.selectedAssistant {
                            Text(assistant.displayName)
                            Image(systemName: monitor.selectedAssistantReady ? "checkmark.circle" : "exclamationmark.circle")
                        } else {
                            Text(.Settings.settingsAssistantNone)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption).padding(.horizontal, 18).padding(.vertical, 10)
        .background(.bar)
    }

    private func reviewRemovalBanner(_ removal: TodoMonitorService.ReviewRemoval) -> some View {
        HStack {
            Text(.Board.boardReviewAssignmentHidden(removal.request.title)).lineLimit(1)
            Spacer()
            Button(.Board.boardReviewAssignmentRestore) { monitor.undoReviewRemoval(removal) }
        }
        .font(.caption).padding(12).background(Color.accentColor.opacity(0.08))
        .task(id: removal.id) {
            do { try await Task.sleep(for: TodoMonitorService.undoWindow) }
            catch { return }
            monitor.dismissReviewRemoval(removal.id)
        }
    }

    private func undoBanner(_ todo: Todo) -> some View {
        HStack {
            Text(.Board.boardEventRead(todo.displayTitle)).lineLimit(1)
            Spacer()
            Button { withAnimation { monitor.undoMarkDone() } } label: { Text(.Menu.menuUndoAction) }
                .keyboardShortcut("z", modifiers: .command)
        }
        .font(.caption).padding(12).background(Color.accentColor.opacity(0.08))
    }

    private func prepareWindow() async {
        monitor.refreshAvailableAssistants()
        if !monitor.settings.onboardingCompleted {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "onboarding")
            updates.seedIfNeeded()
        } else if updates.shouldShowWhatsNew {
            updates.loadWhatsNew()
            openWindow(id: "whats-new")
        } else {
            updates.seedIfNeeded()
        }
    }
}

extension TodoMonitorService {
    func draftRegenerationSheet(_ presentation: DraftRegenerationPresentation) -> some View {
        let coordinator = draftRegeneration
        return DraftRegenerationSheet(presentation: presentation, isAvailable: { coordinator.isAvailable },
            batch: { coordinator.batch }, count: { coordinator.count(for: $0) },
            mergeRequestCount: { coordinator.mergeRequestCount },
            start: { requireCodingAssistant(self) && coordinator.start($0, instructions: $1) },
            apply: { await coordinator.apply($0, batchID: $1) },
            discard: { coordinator.discard($0) })
    }
}
