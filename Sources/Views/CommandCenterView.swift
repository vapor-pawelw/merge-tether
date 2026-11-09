import AppKit
import SwiftUI

struct CommandCenterView: View {
    let monitor: TodoMonitorService
    let updates: UpdateService
    @SceneStorage("commandCenter.showActivity") private var showActivity = false
    @State private var showingAdd = false
    @State private var showingInbox = false
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let initialRefresh = monitor.boardRefreshState
        VStack(spacing: 0) {
            statusBanners
            if !showActivity, initialRefresh == .syncing {
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
            if showActivity {
                VSplitView {
                    AssistantJobHistoryView(monitor: monitor).frame(minHeight: 250)
                    MergeWorkflowActivityView(entries: monitor.authoredMergeRequests.workflow.entries,
                                              onHandoff: monitor.authoredMergeRequests.workflow.confirmPipelineHandoff)
                        .frame(minHeight: 180)
                }
            } else {
                CommandCenterBoardView(monitor: monitor, refreshState: initialRefresh)
                    .id("\(monitor.glab.resolvedHost ?? "")|\(monitor.glab.currentUsername ?? "")")
            }
            if let todo = monitor.undoableTodo { undoBanner(todo) }
            accountFooter
        }
        .frame(minWidth: 1040, minHeight: 680)
        .overlay(alignment: .bottomTrailing) {
            if let event = monitor.autoHandledEventBanner {
                AutoHandledEventBannerView(event: event) { monitor.dismissAutoHandledEventBanner(event.id) }
                    .padding(18)
            }
        }
        .navigationTitle(Text(.Board.boardTitle))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker(selection: $showActivity) {
                    Text(.Board.boardTabBoard).tag(false)
                    Text(.Board.boardTabActivity).tag(true)
                } label: { Text(.Board.boardTitle) }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showingInbox.toggle() } label: {
                    Label {
                        Text(.Board.boardInboxButton)
                    } icon: {
                        Image(systemName: "tray")
                            .overlay(alignment: .topTrailing) {
                                let count = monitor.inboxItems.count
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
                .accessibilityLabel(Text(.Board.boardInboxAccessibilityCount(monitor.inboxItems.count)))
                .popover(isPresented: $showingInbox, arrowEdge: .top) {
                    CommandCenterInboxView(monitor: monitor)
                }
                Button { openWindow(id: "remote-access") } label: {
                    Label { Text(.Remote.remoteMacPairPhone) } icon: { Image(systemName: "iphone") }
                }
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
                Button { openSettings() } label: {
                    Label { Text(.CommandCenter.commandCenterSettings) } icon: { Image(systemName: "gearshape") }
                }
            }
        }
        .sheet(isPresented: $showingAdd) { CommandCenterAddMergeRequestView(monitor: monitor) }
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
                monitor.assistantDependencies.refresh(requireCLI: true)
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            monitor.refreshAvailableAssistants()
        }
        .onAppear {
            MainWindowPresentation.openWindow = { openWindow(id: "main") }
            monitor.authoredMergeRequests.setVisible(true)
            monitor.markMenuOpened()
        }
        .onDisappear { monitor.authoredMergeRequests.setVisible(false) }
    }

    @ViewBuilder
    private var statusBanners: some View {
        if let error = monitor.lastError {
            ErrorBannerView(error: error) { openWindow(id: "onboarding") }
        } else if !showActivity, monitor.boardRefreshState == .unavailable {
            HStack {
                Label { Text(.Board.boardInitialSyncFailed) } icon: { Image(systemName: "exclamationmark.triangle") }
                Spacer()
                Button { Task { await monitor.refreshManually() } } label: { Text(.CommandCenter.commandCenterRefresh) }
            }
            .font(.caption).foregroundStyle(.orange).padding(10)
        } else if monitor.attention.hasError || monitor.authoredMergeRequests.hasError {
            Label { Text(.Board.boardStale) } icon: { Image(systemName: "exclamationmark.triangle") }
                .font(.caption).foregroundStyle(.orange).padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let warning = monitor.assistantDependencyWarning {
            HStack {
                Label { Text(warning) } icon: { Image(systemName: "exclamationmark.triangle") }
                Spacer()
                Button { openSettings() } label: { Text(.Settings.settingsAssistantSetupAction) }
            }
            .font(.caption).padding(10).background(.orange.opacity(0.1))
        }
        if let error = monitor.assistantJobActionError {
            Text(verbatim: error).font(.caption).foregroundStyle(.orange).padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let id = monitor.failedAutomationTodoID {
            Text(.Menu.menuErrorAutomation(id)).font(.caption).padding(8).foregroundStyle(.orange)
        }
    }

    private var accountFooter: some View {
        HStack(spacing: 12) {
            Label {
                Text(verbatim: monitor.glab.currentUsername.map { "@\($0)" }
                     ?? String(localized: .CommandCenter.commandCenterAccountUnavailable))
            } icon: { Image(systemName: "person.crop.circle") }
            if let host = monitor.glab.resolvedHost { Text(verbatim: host).foregroundStyle(.secondary) }
            Spacer()
            Button { openSettings() } label: {
                HStack(spacing: 5) {
                    Text(monitor.settings.automation.assistant.displayName)
                    Image(systemName: monitor.availableAssistants.contains(monitor.settings.automation.assistant)
                          ? "checkmark.circle" : "exclamationmark.circle")
                }
            }
            .buttonStyle(.plain)
        }
        .font(.caption).padding(.horizontal, 18).padding(.vertical, 10)
        .background(.bar)
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
