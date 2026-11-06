import Foundation
import Observation

@MainActor
@Observable
final class TodoMonitorService {
    let settings: SettingsManager
    let glab: GlabService
    let notifications: NotificationService
    let attention: MergeRequestAttentionMonitor
    let authoredMergeRequests: AuthoredMergeRequestMonitor

    private(set) var allTodos: [Todo] = []
    private(set) var lastError: GlabError?
    private(set) var failedAutomationTodoID: Int?
    private(set) var lastRefresh: Date?
    private(set) var isLoading = false
    var assistantJobActionError: String?
    private(set) var desktopHandoffError = false
    let assistantDependencies = AssistantDependencyMonitor()
    var availableAssistants: Set<AutomationAssistant> { assistantDependencies.available }
    private(set) var codexListenerHealth: CodexDesktopRelay.ListenerHealth = .off
    private(set) var codexPluginInstallation: CodexPluginInstaller.Installation?
    private var lastListenerCheck: Date?
    private var lastPluginCheck: Date?
    private var isCheckingCodexPlugin = false

    private var optimisticallyDone: Set<Int> = []
    private var pendingMarkDoneTask: Task<Void, Never>?
    private(set) var undoableTodo: Todo?
    static let undoWindow: Duration = .seconds(4)
    private var acknowledgedDuringFetch: Set<Int> = []
    private var inboxHost: String?
    private var isAutomating = false
    private let automation: TodoAutomationService
    @ObservationIgnored private lazy var mrTodoRouter = MergeRequestTodoRouter(settings: settings, glab: glab, canAutomate: { [weak self] in
        guard let self else { return false }
        return await AssistantCLI.detect(self.settings.automation.assistant, requireCLI: true).isReady
    })
    private let cancelPolicyJob: @MainActor (UUID, SettingsManager) -> Void
    private var runningAttentionFeedback: Set<AssistantAutomationRunner.MergeRequestWork> = []
    private var failedAttentionFeedback: Set<AssistantAutomationRunner.MergeRequestWork> = []
    private var timer: Timer?
    private var unreadReminderTimer: Timer?
    private var hasCompletedFirstFetch = false
    @ObservationIgnored private var legacyGUIQueueRetired = false

    init(
        settings: SettingsManager = SettingsManager(),
        glab: GlabService = GlabService(),
        notifications: NotificationService = NotificationService(),
        automation: TodoAutomationService = TodoAutomationService(),
        cancelPolicyJob: @escaping @MainActor (UUID, SettingsManager) -> Void = {
            AssistantAutomationRunner.cancel($0, settings: $1)
        }
    ) {
        self.settings = settings
        self.glab = glab
        self.notifications = notifications
        self.automation = automation
        self.cancelPolicyJob = cancelPolicyJob
        self.attention = MergeRequestAttentionMonitor(glab: glab, settings: settings,
                                                       reportDirectory: CodexDesktopRelay.directory)
        self.authoredMergeRequests = AuthoredMergeRequestMonitor(settings: settings, glab: glab, notifications: notifications)
        attention.onAutoApproved = { [settings, notifications] request in
            if settings.notificationsEnabled { notifications.deliverAutoApproved(request) }
        }
        attention.onRefreshed = { [weak self] in
            Task { await self?.prepareAutomaticAttentionFeedback() }
        }
        assistantDependencies.onRecovered = { [weak self] assistant in
            guard let self, self.settings.automation.autoVerifyReReview,
                  self.settings.automation.assistant == assistant else { return }
            Task { await self.attention.retryFailedReReviews() }
        }

        // Hydrate the service from any previously persisted state so the
        // glab wrapper survives a cold launch without needing onboarding.
        self.glab.glabPath = settings.glabPath
        self.glab.resolvedHost = settings.resolvedHost
        AssistantAutomationRunner.synchronizeInterruptedRuns(settings: settings)
        AssistantAutomationRunner.onJobFinished = { [weak self] handoff in
            if let reservation = handoff.pipelineReservation, reservation.reservationID != nil {
                try? ExistingPipelineWorkDetector().finishHandoff(for: reservation)
            }
            guard let self else { return }
            FollowUpVerificationStore.synchronizeRuns(settings: self.settings)
            self.authoredMergeRequests.workflow.synchronizeAssistantJobs()
            Task { await self.refreshNow() }
        }

        settings.onAutomationChanged = { [weak self] previous in
            self?.automationConfigurationChanged(previous: previous)
        }
        Task { [weak self] in
            await self?.bootstrap()
        }
    }

    private func retireLegacyGUIQueueIfNeeded() {
        guard !legacyGUIQueueRetired else { return }
        do { legacyGUIQueueRetired = try CodexDesktopRelay.retirePendingGUIJobs(in: CodexDesktopRelay.directory) }
        catch { Log.monitor.error("Could not retire legacy GUI queue: \(String(describing: error), privacy: .private)") }
    }

    /// Runs at app launch: probes glab, refreshes persisted state, and kicks
    /// off the first fetch + polling timer if onboarding is already done so
    /// the menu bar count reflects the real inbox without waiting for the
    /// user to open the dropdown.
    func refreshAvailableAssistants() {
        assistantDependencies.refresh(requireCLI: requiresAssistantCLI, force: true)
    }

    var requiresAssistantCLI: Bool { true }

    func bootstrap() async {
        retireLegacyGUIQueueIfNeeded()
        refreshAvailableAssistants()
        if glab.glabPath == nil {
            glab.glabPath = await OnboardingDetector.findGlabExecutable()
            settings.glabPath = glab.glabPath
        }
        await glab.recheck()
        settings.glabPath = glab.glabPath
        settings.resolvedHost = glab.resolvedHost
        settings.save()

        if settings.onboardingCompleted, timer == nil {
            if lastRefresh == nil {
                start()
            } else {
                restartTimer()
                authoredMergeRequests.refreshIfNeeded()
            }
        }
    }

    // MARK: - Derived state

    var visibleTodos: [Todo] {
        allTodos
            .filter { !optimisticallyDone.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var pipelineHandoffs: [MergeWorkflowActivityEntry] {
        authoredMergeRequests.workflow.pendingPipelineHandoffs
    }

    var assistantGroups: [AssistantTaskGroup] {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return [] }
        return AssistantTaskGroup.groups(from: settings.assistantHandoffs, host: host, username: username)
    }

    private var mergeRequestBrowser: MergeRequestBrowserSnapshot? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return nil }
        return MergeRequestBrowserSnapshot(openItems: attention.currentOpenItems,
            authored: authoredMergeRequests.requests, host: host, username: username, scope: settings.automation.scope,
            ownCatalogIsAuthoritative: attention.hasCurrentOwnListing)
    }

    var currentMRTodoIntents: [MRTodoIntent] {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return [] }
        return settings.mrActionIntents.filter { $0.target.host == host && $0.target.username == username }
    }

    var routedMRTodoIDs: Set<Int> {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return [] }
        return Set(allTodos.filter { todo in
            guard let iid = todo.target.iid, todo.targetType == .mergeRequest,
                  todo.targetURL.gitLabTodoMergeRequestURL(host: host, iid: iid) != nil else { return false }
            let target = MRAutomationScope.Target(host: host, username: username, projectID: todo.project.id, iid: iid)
            return settings.routedMRTodoReceipts.contains { $0.target == target && $0.event == todo.feedbackIdentity }
                || currentMRTodoIntents.contains { $0.target == target && $0.sourceEvents.contains(todo.feedbackIdentity) }
        }.map(\.id))
    }

    var otherTodos: [Todo] { visibleTodos.filter { !routedMRTodoIDs.contains($0.id) } }

    func mrTodoIntents(for item: MergeRequestAttentionMonitor.Item) -> [MRTodoIntent] {
        currentMRTodoIntents.filter { $0.target.projectID == item.id.projectID && $0.target.iid == item.id.iid && $0.state != .completed }
    }

    func runMRTodoIntent(id: UUID) async {
        await mrTodoRouter.run(id, manual: true)
    }

    func dismissMRTodoIntent(id: UUID) { mrTodoRouter.dismiss(id) }

    func adoptMRTodoProposal(_ todo: Todo) async {
        guard let iid = todo.target.iid, let host = glab.resolvedHost,
              let canonical = todo.targetURL.gitLabTodoMergeRequestURL(host: host, iid: iid),
              let target = scopeTarget(projectID: todo.project.id, iid: iid, url: canonical) else { return }
        settings.ignoredMergeRequests.remove(target)
        settings.automation.scope[target] = .active
        settings.automation.scope.rememberRepository(todo.project.pathWithNamespace, for: target)
        settings.save()
        await routeMRTodos(host: target.host, username: target.username)
        guard !Task.isCancelled else { return }
        for intent in currentMRTodoIntents where intent.target == target && intent.state != .completed {
            await mrTodoRouter.run(intent.id, manual: true)
        }
        await refreshNow()
    }

    private func trackedReviewTarget(_ target: MRAutomationScope.Target) -> Bool {
        settings.automation.scope[target] == .active
            || settings.mrActionIntents.contains { $0.target == target }
            || settings.assistantChats.keys.contains {
                $0.work.host == target.host && $0.username == target.username && $0.work.projectID == target.projectID && $0.work.iid == target.iid
            }
            || settings.assistantHandoffs.contains {
                $0.key.work.host == target.host && $0.key.username == target.username
                    && $0.key.work.projectID == target.projectID && $0.key.work.iid == target.iid
            }
    }

    private func routeMRTodos(host: String, username: String) async {
        let managed = Set(reviewedMergeRequestItems.compactMap {
            scopeTarget(projectID: $0.id.projectID, iid: $0.id.iid, url: $0.url)
        })
        let acknowledged = await mrTodoRouter.process(allTodos, host: host, username: username, managed: managed)
        guard glab.resolvedHost == host, glab.currentUsername == username else { return }
        allTodos.removeAll { acknowledged.contains($0.id) }
        acknowledgedDuringFetch.formUnion(acknowledged)
        if let error = mrTodoRouter.acknowledgementError { assistantJobActionError = error.localizedDescription }
    }

    var ownMergeRequestItems: [MergeRequestAttentionMonitor.Item] { mergeRequestBrowser?.own ?? [] }
    var reviewedMergeRequestItems: [MergeRequestAttentionMonitor.Item] {
        (mergeRequestBrowser?.reviewed ?? []).filter { item in
            guard let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) else { return false }
            return !settings.ignoredMergeRequests.contains(target) && trackedReviewTarget(target)
        }
    }

    func assistantChatLinks(for item: MergeRequestAttentionMonitor.Item) -> [AssistantChatLink] {
        guard let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) else { return [] }
        let work = AssistantAutomationRunner.MergeRequestWork(host: target.host, projectID: target.projectID, iid: item.id.iid)
        let group = assistantGroups.first { $0.id == work }
        let preferred = settings.automation.assistant
        return ([preferred] + AutomationAssistant.allCases.filter { $0 != preferred }).compactMap { assistant in
            let key = AssistantAutomationRunner.ChatKey(assistant: assistant, work: work, username: target.username,
                                                        workspace: "", access: .gitLabRead)
            let recorded = key.reusableChat(in: settings.assistantChats) ?? settings.assistantChats.first {
                $0.key.assistant == assistant && $0.key.work == work && $0.key.username == target.username
            }?.value
            let candidates = [recorded] + (group?.handoffs.filter {
                $0.key.assistant == assistant && $0.relayComplete == true
            }.map(\.chatID) ?? [])
            let url = candidates.compactMap { chatID in
                chatID.flatMap(assistant == .codex
                    ? AssistantAutomationRunner.codexChatURL : AssistantAutomationRunner.claudeSessionURL)
            }.first
            return url.map { AssistantChatLink(assistant: assistant, url: $0) }
        }
    }

    var inbox: InboxSnapshot {
        InboxSnapshot(todos: visibleTodos, attention: attentionItems, host: glab.resolvedHost, username: glab.currentUsername)
    }

    var manualAssistantGroups: [AssistantTaskGroup] {
        assistantGroups.filter { group in
            guard let execution = group.handoffs.first(where: { $0.execution != nil })?.execution else { return false }
            return [.failed, .blocked, .interrupted, .cancelled].contains(execution.state)
        }
    }

    func manualHandoff(in group: AssistantTaskGroup) -> AssistantAutomationRunner.Handoff? {
        group.handoffs.first { handoff in
            guard let execution = handoff.execution else { return false }
            return [.failed, .blocked, .interrupted, .cancelled].contains(execution.state)
        }
    }

    private func matches(_ todo: Todo, work: AssistantAutomationRunner.MergeRequestWork) -> Bool {
        todo.targetType == .mergeRequest && todo.project.id == work.projectID && todo.target.iid == work.iid
            && todo.targetURL.gitLabTodoMergeRequestURL(host: work.host, iid: work.iid) != nil
    }

    func manualAssistantGroup(for todo: Todo) -> AssistantTaskGroup? {
        manualAssistantGroups.first { group in
            matches(todo, work: group.id) && visibleTodos.first(where: { matches($0, work: group.id) })?.id == todo.id
        }
    }

    func manualAssistantGroup(for item: MergeRequestAttentionMonitor.Item) -> AssistantTaskGroup? {
        manualAssistantGroups.first { group in
            group.id.projectID == item.id.projectID && group.id.iid == item.id.iid
                && !visibleTodos.contains(where: { matches($0, work: group.id) })
        }
    }

    var standaloneManualAssistantGroups: [AssistantTaskGroup] {
        let attention = inbox.attention
        return manualAssistantGroups.filter { group in
            !visibleTodos.contains(where: { matches($0, work: group.id) })
                && !attention.contains(where: { $0.id.projectID == group.id.projectID && $0.id.iid == group.id.iid })
        }
    }

    var hasAssistantAction: Bool {
        unavailableAssistant != nil
    }

    func confirmPipelineHandoff(for id: MergeRequestAttentionMonitor.Item.ID) {
        guard let entry = pipelineHandoffs.first(where: { $0.event.mergeRequest.projectID == id.projectID
            && $0.event.mergeRequest.iid == id.iid }) else { return }
        authoredMergeRequests.workflow.confirmPipelineHandoff(entry.id)
    }

    func scopeTarget(projectID: Int, iid: Int, url: URL) -> MRAutomationScope.Target? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername,
              url.isGitLabMergeRequest(host: host, iid: iid) else { return nil }
        return .init(host: host, username: username, projectID: projectID, iid: iid)
    }

    /// The selected assistant's chat for this MR: a Codex thread or a Claude Code session.
    func existingCodexChat(for target: MRAutomationScope.Target) -> URL? {
        guard let iid = target.iid else { return nil }
        let assistant = settings.automation.assistant
        let work = AssistantAutomationRunner.MergeRequestWork(host: target.host, projectID: target.projectID, iid: iid)
        let key = AssistantAutomationRunner.ChatKey(assistant: assistant, work: work, username: target.username,
                                                     workspace: "", access: .gitLabRead)
        let chatID = key.reusableChat(in: settings.assistantChats) ?? settings.assistantChats.first {
            $0.key.assistant == assistant && $0.key.work == work && $0.key.username == target.username
        }?.value ?? assistantHandoffs.last {
            $0.key.work == work && $0.key.assistant == assistant && $0.chatID != nil
        }?.chatID
        return chatID.flatMap(assistant == .codex ? AssistantAutomationRunner.codexChatURL
                                                  : AssistantAutomationRunner.claudeSessionURL)
    }

    func addAutomationTarget(from address: String) async throws {
        let result = try await resolveAutomationTarget(from: address)
        enableAutomationTarget(result.target, projectPath: result.projectPath)
        await refreshNow()
    }

    /// Removes a foreign MR locally, retaining GitLab assignments, drafts and history.
    /// A persisted pause prevents global discovery from adding it back on the next poll.
    func removeReviewedMergeRequest(_ item: MergeRequestAttentionMonitor.Item) {
        guard let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url),
              let request = item.mergeRequest, request.author.username != target.username,
              request.projectID == target.projectID, request.iid == target.iid,
              request.webURL == item.url else { return }
        settings.ignoredMergeRequests.insert(target)
        settings.automation.scope[target] = .paused
        settings.save()
        let work = AssistantAutomationRunner.MergeRequestWork(host: target.host, projectID: target.projectID, iid: item.id.iid)
        for job in assistantHandoffs where job.key.work == work && job.execution?.state.isActive == true {
            AssistantAutomationRunner.cancel(job.id, settings: settings)
        }
    }

    func ignoreMergeRequestProposal(projectID: Int, iid: Int, url: URL) async {
        guard projectID > 0, iid > 0, let target = scopeTarget(projectID: projectID, iid: iid, url: url) else { return }
        do {
            async let user = glab.fetchAuthenticatedUser(host: target.host, expectedUsername: target.username)
            async let request = glab.fetchMergeRequest(projectID: projectID, iid: iid, host: target.host)
            let (currentUser, currentRequest) = try await (user, request)
            guard glab.resolvedHost == target.host, glab.currentUsername == target.username,
                  currentRequest.projectID == projectID, currentRequest.iid == iid,
                  currentRequest.webURL.isGitLabMergeRequest(host: target.host, iid: iid),
                  currentRequest.author.id != currentUser.id else { return }
        } catch {
            lastError = error as? GlabError ?? .unknown(String(describing: error))
            return
        }
        settings.ignoredMergeRequests.insert(target)
        settings.automation.scope[target] = .paused
        settings.save()
        let work = AssistantAutomationRunner.MergeRequestWork(host: target.host, projectID: projectID, iid: iid)
        for job in assistantHandoffs where job.key.work == work && job.execution?.state.isActive == true {
            AssistantAutomationRunner.cancel(job.id, settings: settings)
        }
        for todo in visibleTodos where todo.targetType == .mergeRequest && todo.project.id == projectID
            && todo.target.iid == iid && todo.targetURL.gitLabTodoMergeRequestURL(host: target.host, iid: iid) != nil {
            guard glab.resolvedHost == target.host, glab.currentUsername == target.username else { return }
            await markDone(todo)
        }
    }

    func addManagedMergeRequest(from address: String, projectID: Int? = nil) async throws -> GitLabMergeRequest {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = raw.hasPrefix("!") ? String(raw.dropFirst()) : raw
        let target: MRAutomationScope.Target
        let request: GitLabMergeRequest
        if let iid = Int(number), iid > 0, let projectID,
           let host = glab.resolvedHost, let username = glab.currentUsername {
            request = try await glab.fetchMergeRequest(projectID: projectID, iid: iid, host: host)
            guard request.projectID == projectID, request.iid == iid, request.state == "opened",
                  request.webURL.isGitLabMergeRequest(host: host, iid: iid),
                  glab.resolvedHost == host, glab.currentUsername == username else { throw CancellationError() }
            target = .init(host: host, username: username, projectID: projectID, iid: iid)
        } else {
            let result = try await resolveAutomationTarget(from: raw)
            guard let resolved = result.request else { throw GlabError.decoding("Enter a merge request URL, or a number and repository") }
            request = resolved
            target = result.target
        }
        enableAutomationTarget(target, projectPath: request.webURL.gitLabProjectPath)
        await refreshNow()
        return request
    }

    private func enableAutomationTarget(_ target: MRAutomationScope.Target, projectPath: String) {
        settings.ignoredMergeRequests.remove(target)
        settings.automation.scope[target] = .active
        settings.automation.scope.rememberRepository(projectPath, for: target)
        settings.save()
    }

    private func resolveAutomationTarget(from address: String) async throws -> (target: MRAutomationScope.Target, projectPath: String, request: GitLabMergeRequest?) {
        guard let host = glab.resolvedHost, let username = glab.currentUsername,
              let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let expected = URLComponents(string: "https://\(host)"),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme, ["https", "http"].contains(scheme),
              parts.host?.lowercased() == expected.host?.lowercased(), parts.user == nil, parts.password == nil,
              (parts.port ?? (scheme == "https" ? 443 : 80)) == (expected.port ?? (scheme == "https" ? 443 : 80))
        else { throw GlabError.decoding("Use a URL on the current GitLab host") }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = path.components(separatedBy: "/-/merge_requests/")
        let projectPath = components[0]
        guard (components.count == 1 || components.count == 2), projectPath.contains("/"),
              !projectPath.contains("/-/"), !projectPath.hasSuffix(".git") else {
            throw GlabError.decoding("Enter a GitLab repository or merge request URL")
        }
        let projectID = try await glab.resolveAutomationProject(path: projectPath, host: host)
        var iid: Int? = nil
        var verified: GitLabMergeRequest?
        if components.count == 2 {
            guard let number = Int(components[1]), number > 0 else {
                throw GlabError.decoding("Invalid merge request URL")
            }
            let request = try await glab.fetchMergeRequest(projectID: projectID, iid: number, host: host)
            guard request.projectID == projectID, request.iid == number, request.state == "opened", request.webURL.isGitLabMergeRequest(host: host, iid: number) else {
                throw GlabError.decoding("The merge request is no longer open")
            }
            iid = number
            verified = request
        }
        guard glab.resolvedHost == host, glab.currentUsername == username else { throw CancellationError() }
        let target = MRAutomationScope.Target(host: host, username: username, projectID: projectID, iid: iid)
        return (target, projectPath, verified)
    }

    var attentionItems: [MergeRequestAttentionMonitor.Item] {
        var items = attention.currentItems.compactMap { item -> MergeRequestAttentionMonitor.Item? in
            guard let host = glab.resolvedHost, let username = glab.currentUsername, !item.feedback.isEmpty else { return item }
            let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: item.id.projectID, iid: item.id.iid)
            let remaining = Set(AssistantAutomationRunner.unhandledFeedback(
                item.feedback.compactMap(\.id), work: work, username: username, settings: settings
            ))
            var item = item
            item.feedback.removeAll { $0.id.map { !remaining.contains($0) } ?? false }
            if item.feedback.isEmpty { item.needsDiscussion = item.hasOtherUnresolvedDiscussions }
            return item.needsAttention ? item : nil
        }
        let handoffs = pipelineHandoffs
        for handoff in handoffs {
            let mr = handoff.event.mergeRequest
            let id = MergeRequestAttentionMonitor.Item.ID(projectID: mr.projectID, iid: mr.iid)
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].needsPipelineHandoff = true
                if items[index].mergeRequest == nil { items[index].mergeRequest = mr }
            } else {
                items.append(.init(id: id, title: mr.title, url: mr.webURL, needsPipelineHandoff: true, mergeRequest: mr))
            }
        }
        if !attention.hasError, !authoredMergeRequests.hasError, let host = glab.resolvedHost, let username = glab.currentUsername {
            for status in authoredMergeRequests.requests where status.blockers.isEmpty && status.request.isReadyForMergeChecks {
                let request = status.request
                guard request.author.username == username,
                      request.webURL.isGitLabMergeRequest(host: host, iid: request.iid),
                      let current = attention.currentOpenItems.first(where: {
                          $0.id.projectID == request.projectID && $0.id.iid == request.iid
                      }), current.mergeRequest?.author.username == username, current.canOfferMerge(using: status)
                else { continue }
                let id = MergeRequestAttentionMonitor.Item.ID(projectID: request.projectID, iid: request.iid)
                guard (items.first(where: { $0.id == id })?.draftCount ?? 0) == 0 else { continue }
                let automatic = status.mayAutoMerge && settings.automation.permitsAutoMerge(project: request.webURL.gitLabProjectPath)
                    && settings.automation.scope.permits(request, host: host, username: username)
                    && !AssistantJobExecution.hasUnfinishedWork(in: settings.assistantHandoffs,
                        for: .init(host: host, projectID: id.projectID, iid: id.iid), username: username)
                guard !automatic else { continue }
                if let index = items.firstIndex(where: { $0.id == id }) { items[index].needsMerge = true }
                else { items.append(.init(id: id, title: request.title, url: request.webURL, needsMerge: true, mergeRequest: request, isAuthored: true)) }
            }
        }
        let visible = items.compactMap { item -> MergeRequestAttentionMonitor.Item? in
            guard let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) else { return item }
            let work = AssistantAutomationRunner.MergeRequestWork(host: target.host, projectID: item.id.projectID, iid: item.id.iid)
            let currentEvents = authoredMergeRequests.workflow.entries.filter {
                $0.event.mergeRequest.projectID == item.id.projectID && $0.event.mergeRequest.iid == item.id.iid
                    && $0.event.mergeRequest.sha == item.mergeRequest?.sha
            }
            var failures = Set(MergeWorkflowTrigger.allCases.filter { trigger in
                currentEvents.first { $0.event.kind == trigger }?.state == .failed
            })
            if failedAttentionFeedback.contains(work) { failures.insert(.newDiscussion) }
            let conflictFailed = item.mergeRequest.map { authoredMergeRequests.conflictTaskFailed(for: $0) } ?? false
            let pipelineState = currentEvents.first { $0.event.kind == .pipelineFailure
                && $0.event.pipelineID == item.mergeRequest?.headPipeline?.id }?.state
            let pipelineOwned = pipelineState.map { [.queued, .running, .waitingForAssistant, .completed, .alreadyRegistered].contains($0) } ?? false
            let feedbackState = currentEvents.first { $0.event.kind == .newDiscussion }?.state
            let feedbackOwned = feedbackState.map { [.queued, .running, .waitingForAssistant, .completed].contains($0) } ?? false
            let visible = item.requiringUserAttention(automation: settings.automation, target: target,
                                                     failedTriggers: failures, conflictTaskFailed: conflictFailed,
                                                     pipelineOwnedAutomatically: pipelineOwned, feedbackOwnedAutomatically: feedbackOwned)
            return visible.needsAttention ? visible : nil
        }
        return MergeRequestAttentionMonitor.Item.ordered(visible)
    }

    func unmanagedTarget(for item: MergeRequestAttentionMonitor.Item) -> MRAutomationScope.Target? {
        guard let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url),
              !settings.automation.scope.resolve(target).active else { return nil }
        return target
    }

    func manageAttentionItem(_ item: MergeRequestAttentionMonitor.Item) async {
        guard let target = unmanagedTarget(for: item) else { return }
        settings.automation.scope[target] = .active
        settings.automation.scope.rememberRepository(item.url.gitLabProjectPath, for: target)
        settings.save()
        if automaticallyHandlesFeedback(item) { await runAttentionFeedback(for: item, manual: false) }
        await refreshNow()
    }

    private func automaticallyHandlesFeedback(_ item: MergeRequestAttentionMonitor.Item) -> Bool {
        guard let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url),
              settings.automation.scope.resolve(target).active,
              let request = item.authoredRequest, request.state == "opened", request.draft == false,
              request.author.username == target.username else { return false }
        let rule = settings.automation.workflowRules[.newDiscussion]
        let feedback = settings.automation.authorFeedback
        guard feedback.runner == .assistant, feedback.isConfigured, feedback.includes(project: item.url.gitLabProjectPath) else { return false }
        return feedback.isEnabled || (rule.mode == .assistant && rule.includes(request))
    }

    private func prepareAutomaticAttentionFeedback() async {
        // This also picks up existing feedback when an MR becomes managed, after the
        // event monitor has already seeded its baseline. Shared handoffs deduplicate it.
        for item in attention.currentItems where automaticallyHandlesFeedback(item) {
            guard let host = glab.resolvedHost else { return }
            let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: item.id.projectID, iid: item.id.iid)
            guard !failedAttentionFeedback.contains(work) else { continue }
            await runAttentionFeedback(for: item, manual: false)
        }
    }

    var assistantHandoffs: [AssistantAutomationRunner.Handoff] {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return [] }
        return settings.assistantHandoffs.filter { $0.key.work.host == host && $0.key.username == username }
    }

    var unavailableAssistant: AutomationAssistant? {
        let assistant = settings.automation.assistant
        if (settings.automation.usesAssistant || settings.automation.autoReReviewEnabled
            || settings.automation.autoMergeEnabled || settings.automation.autoApproveEnabled
            || settings.automation.publishDraftsWithoutConfirmation || settings.automation.publishAIRepliesWithoutConfirmation),
           let status = assistantDependencies.statuses[assistant], !status.isReady { return assistant }
        return assistantHandoffs.first { handoff in
            handoff.execution?.state.isActive == true && assistantDependencies.statuses[handoff.key.assistant].map { !$0.isReady } == true
        }?.key.assistant
    }

    var assistantDependencyWarning: LocalizedStringResource? {
        guard let assistant = unavailableAssistant else { return nil }
        return assistantDependencies.statuses[assistant]?.message(for: assistant)
    }

    // Retained for decoding old integration state; desktop listeners no longer execute work.
    func checkCodexListener(force: Bool = false, now: Date = Date()) {}
    var codexListenerWarning: LocalizedStringResource? { nil }

    var attentionCount: Int { inbox.attention.count + standaloneManualAssistantGroups.count + (hasAssistantAction ? 1 : 0) }
    var badgeCount: Int { inbox.count + standaloneManualAssistantGroups.count + (hasAssistantAction ? 1 : 0) }

    var hasUnseenTodos: Bool {
        guard !visibleTodos.isEmpty else { return false }
        guard let lastOpened = settings.lastMenuOpenedAt else { return false }
        return visibleTodos.contains { $0.createdAt > lastOpened }
    }

    var dashboardURL: URL {
        glab.dashboardTodosURL ?? URL(string: "https://gitlab.com/dashboard/todos")!
    }

    // MARK: - Lifecycle

    func start() {
        Task { await refreshNow() }
        restartTimer()
    }

    func restartTimer() {
        timer?.invalidate()
        let interval = settings.refreshInterval.seconds
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshNow()
            }
        }
        restartUnreadReminderTimer()
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
        stopUnreadReminderTimer()
    }

    func markMenuOpened() {
        settings.lastMenuOpenedAt = Date()
        settings.save()
        stopUnreadReminderTimer()
    }

    func restartUnreadReminderTimer() {
        guard settings.notificationsEnabled,
              hasUnseenTodos,
              let interval = settings.unreadReminderInterval.seconds
        else {
            stopUnreadReminderTimer()
            return
        }

        // Refreshes can happen more often than reminders. Keep an active
        // reminder's deadline unless the reminder interval changed.
        guard unreadReminderTimer?.timeInterval != interval else { return }
        stopUnreadReminderTimer()
        unreadReminderTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendUnreadReminderIfNeeded()
            }
        }
    }

    private func stopUnreadReminderTimer() {
        unreadReminderTimer?.invalidate()
        unreadReminderTimer = nil
    }

    private func sendUnreadReminderIfNeeded() {
        guard settings.notificationsEnabled,
              hasUnseenTodos,
              settings.unreadReminderInterval.seconds != nil
        else {
            stopUnreadReminderTimer()
            return
        }

        notifications.deliverUnreadReminder(
            todoCount: visibleTodos.count,
            dashboardURL: dashboardURL,
            sound: settings.unreadReminderSound
        )
    }

    // MARK: - Commands

    func refreshNow() async {
        retireLegacyGUIQueueIfNeeded()
        refreshAvailableAssistants()
        refreshAssistantRelay()
        authoredMergeRequests.refreshIfNeeded()
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            acknowledgedDuringFetch.removeAll()
            lastRefresh = Date()
        }

        let username = glab.currentUsername
        let host = username == nil ? nil : glab.resolvedHost
        let result = await glab.fetchTodos(host: host)
        switch result {
        case .success(let fetched):
            let fetchedFiltered = fetched.filter { !acknowledgedDuringFetch.contains($0.id) }
            let fetchedIDs = Set(fetchedFiltered.map(\.id))
            glab.resolveHostFromTodos(fetchedFiltered)
            settings.resolvedHost = glab.resolvedHost
            inboxHost = host

            if let failedAutomationTodoID, !fetchedIDs.contains(failedAutomationTodoID) {
                self.failedAutomationTodoID = nil
            }

            if let host, let username, !isAutomating {
                automation.prune(fetchedIDs: fetchedIDs, host: host, username: username, settings: settings)
            }

            let newIDs = TodoDiff.newIDs(
                fetched: fetchedFiltered,
                lastSeen: settings.lastSeenTodoIDs,
                isFirstFetch: !hasCompletedFirstFetch
            )

            if settings.notificationsEnabled && !newIDs.isEmpty {
                let newTodos = fetchedFiltered.filter {
                    newIDs.contains($0.id) && !optimisticallyDone.contains($0.id)
                }
                notifications.deliver(newTodos: newTodos, dashboardURL: glab.dashboardTodosURL)
            }

            settings.lastSeenTodoIDs = fetchedIDs
            settings.save()

            allTodos = fetchedFiltered
            lastError = nil
            hasCompletedFirstFetch = true
            restartUnreadReminderTimer()
            if let host, let username {
                if settings.onboardingCompleted {
                    attention.refresh(host: host, username: username, todos: fetchedFiltered)
                }
                await routeMRTodos(host: host, username: username)
                await acknowledgeHandledTodos(host: host, username: username)
                scheduleAutomation(host: host, username: username)
            }

        case .failure(let err):
            Log.monitor.error("Refresh failed: \(String(describing: err), privacy: .public)")
            lastError = err
            // Intentionally keep allTodos as-is: a stale list is more useful
            // than an empty one while the user fixes their glab auth.
        }
    }

    private func scheduleAutomation(host: String, username: String) {
        guard !isAutomating,
              settings.onboardingCompleted,
              settings.automation.reviewRequested.isEnabled || settings.automation.authorFeedback.isEnabled
        else { return }

        let candidates = visibleTodos.reversed().compactMap { todo in
            // MR events are classified exclusively by the durable router. Unknown
            // mentions must not fall through to the former broad automation path.
            guard todo.targetType != .mergeRequest else { return Optional<(Todo, TodoAutomationEvent)>.none }
            return TodoAutomationEvent(todo: todo, username: username).map { (todo, $0) }
        }
        guard !candidates.isEmpty else { return }

        isAutomating = true
        Task {
            defer { isAutomating = false }
            for (todo, event) in candidates {
                await runAutomation(todo, event: event, host: host, username: username, manual: false)
            }
        }
    }

    func automationAction(for todo: Todo) -> TodoAutomationService.ActionState? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername, inboxHost == host else { return nil }
        return automation.actionState(
            for: todo, host: host, username: username, settings: settings, available: availableAssistants
        )
    }

    func attentionFeedbackAction(for item: MergeRequestAttentionMonitor.Item) -> TodoAutomationService.ActionState? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername, inboxHost == host,
              let request = item.authoredRequest, request.author.username == username,
              availableAssistants.contains(settings.automation.assistant) else { return nil }
        let rule = settings.automation.authorFeedback
        guard rule.runner == .assistant, rule.isConfigured, rule.includes(project: item.url.gitLabProjectPath) else { return nil }
        let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: item.id.projectID, iid: item.id.iid)
        if runningAttentionFeedback.contains(work) { return .running }
        guard !attentionFeedbackNoteIDs(for: item, work: work, username: username).isEmpty else { return nil }
        return failedAttentionFeedback.contains(work) ? .failed : .ready(.assistant)
    }

    private func attentionFeedbackNoteIDs(
        for item: MergeRequestAttentionMonitor.Item, work: AssistantAutomationRunner.MergeRequestWork, username: String
    ) -> [Int] {
        let notes = TodoAutomationEvent.feedbackWithoutTodo(
            item.feedback, todos: allTodos, host: work.host, projectID: work.projectID, iid: work.iid, username: username
        ).compactMap(\.id)
        return AssistantAutomationRunner.unhandledFeedback(notes, work: work, username: username, settings: settings)
    }

    func runAttentionFeedback(for item: MergeRequestAttentionMonitor.Item, manual: Bool = true) async {
        guard let action = attentionFeedbackAction(for: item), action == .ready(.assistant) || action == .failed,
              let host = glab.resolvedHost, let username = glab.currentUsername else { return }
        let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: item.id.projectID, iid: item.id.iid)
        guard runningAttentionFeedback.insert(work).inserted else { return }
        defer { runningAttentionFeedback.remove(work) }
        failedAttentionFeedback.remove(work)
        let notes = attentionFeedbackNoteIDs(for: item, work: work, username: username)
        do {
            try await automation.prepareFeedback(work: work, noteIDs: notes, username: username, settings: settings, glab: glab, manual: manual) {
                self.glab.resolvedHost == host && self.glab.currentUsername == username && self.inboxHost == host
                    && self.attentionFeedbackNoteIDs(for: item, work: work, username: username) == notes
                    && (manual || self.automaticallyHandlesFeedback(item))
            }
        } catch {
            failedAttentionFeedback.insert(work)
            Log.monitor.error("Could not prepare MR feedback: \(String(describing: error), privacy: .private)")
        }
    }

    private func acknowledgeHandledTodos(host: String, username: String) async {
        var handled = Set(assistantHandoffs.flatMap(\.deliveredFeedbackTodos))
        handled.formUnion(settings.pendingTodoAcknowledgements.lazy
            .filter { $0.host == host && $0.username == username }.map(\.todo))
        for todo in visibleTodos where handled.contains(todo.feedbackIdentity) {
            if todo.targetType == .mergeRequest,
               !settings.routedMRTodoReceipts.contains(where: { $0.target.host == host && $0.target.username == username && $0.event == todo.feedbackIdentity }),
               !settings.pendingTodoAcknowledgements.contains(where: { $0.host == host && $0.username == username && $0.todo == todo.feedbackIdentity }) { continue }
            guard glab.resolvedHost == host, glab.currentUsername == username, inboxHost == host else { return }
            await markDone(todo)
        }
    }

    func runAutomationManually(for todo: Todo) async {
        guard case .ready = automationAction(for: todo),
              let host = glab.resolvedHost, let username = glab.currentUsername,
              let event = TodoAutomationEvent(todo: todo, username: username) else { return }
        await runAutomation(todo, event: event, host: host, username: username, manual: true)
    }

    private func runAutomation(
        _ todo: Todo, event: TodoAutomationEvent, host: String, username: String, manual: Bool
    ) async {
        @MainActor func isPending() -> Bool {
            glab.resolvedHost == host && glab.currentUsername == username && inboxHost == host
                && !optimisticallyDone.contains(todo.id) && allTodos.contains { $0.id == todo.id }
        }

        guard isPending() else { return }
        do {
            let shouldAcknowledge = try await automation.prepareToAcknowledge(
                todo, event: event, host: host, username: username,
                settings: settings, glab: glab, manual: manual, isPending: isPending
            )
            if failedAutomationTodoID == todo.id,
               settings.automationReceipts.contains(.init(host: host, username: username, todoID: todo.id)) {
                failedAutomationTodoID = nil
            }
            if shouldAcknowledge, isPending() { await markDone(todo) }
        } catch {
            if isPending() { failedAutomationTodoID = todo.id }
            Log.monitor.error("Automation failed for todo \(todo.id, privacy: .public): \(String(describing: error), privacy: .private)")
        }
    }

    func prepareForTermination() {
        attention.automationConfigurationChanged()
        automation.cancelRunningScripts()
        AssistantAutomationRunner.prepareForTermination(settings: settings)
        FollowUpVerificationStore.synchronizeRuns(settings: settings)
    }

    func automationConfigurationChanged(previous: AutomationSettings) {
        let current = settings.automation
        guard previous != current else { return }
        let scopeOnly = previous.preservingScope(from: current) == current
        // Revoke the helper's persisted permission before stopping an in-flight worker.
        FollowUpVerificationStore.synchronizeRuns(settings: settings)
        automation.cancelRunningScripts(outsideScope: scopeOnly ? current.scope : nil)
        for handoff in settings.assistantHandoffs where handoff.execution?.state.isActive == true {
            if scopeOnly {
                let target = MRAutomationScope.Target(host: handoff.key.work.host, username: handoff.key.username,
                    projectID: handoff.key.work.projectID, iid: handoff.key.work.iid)
                guard handoff.manual != true, !current.scope.resolve(target).active else { continue }
            }
            cancelPolicyJob(handoff.id, settings)
        }
        attention.automationConfigurationChanged(outsideScope: scopeOnly ? current.scope : nil)
        assistantDependencies.refresh(requireCLI: true, force: !scopeOnly)
        authoredMergeRequests.workflow.synchronizeAssistantJobs()
        if let host = glab.resolvedHost, let username = glab.currentUsername {
            attention.refresh(host: host, username: username, todos: visibleTodos)
        }
    }

    func refreshAssistantRelay() {
        FollowUpVerificationStore.synchronizeRuns(settings: settings)
        assistantDependencies.refresh(requireCLI: true)
    }

    func retryAssistantJob(_ id: UUID) async {
        guard assistantHandoffs.contains(where: { $0.id == id }) else { return }
        assistantJobActionError = nil
        do {
            let replacement = try await AssistantAutomationRunner.retry(id, settings: settings)
            mrTodoRouter.rebindJob(oldID: id, replacement: replacement)
            authoredMergeRequests.workflow.synchronizeAssistantJobs()
        } catch {
            assistantJobActionError = String(localized: .AssistantJobs.assistantJobsActionFailed)
            Log.monitor.error("Could not retry assistant job: \(String(describing: error), privacy: .private)")
        }
    }

    func cancelAssistantJob(_ id: UUID) {
        guard assistantHandoffs.contains(where: { $0.id == id }) else { return }
        AssistantAutomationRunner.cancel(id, settings: settings)
    }

    // Compatibility for old unmounted views. Manual opening is now a separate per-MR menu.
    func openAssistantHandoff(_ id: UUID) async { await retryAssistantJob(id) }
    func openCodexForListener() async {}
    func requestCodexDispatch(_ id: UUID) { Task { await retryAssistantJob(id) } }

    func dismissAssistantHandoff(_ id: UUID) {
        guard let handoff = assistantHandoffs.first(where: { $0.id == id }) else { return }
        if let reservation = handoff.pipelineReservation {
            try? ExistingPipelineWorkDetector().finishHandoff(for: reservation)
        }
        AssistantAutomationRunner.cancel(id, settings: settings)
        settings.assistantHandoffs.removeAll { $0.id == id }
        settings.save()
    }

    func markDone(_ todo: Todo) async {
        guard optimisticallyDone.insert(todo.id).inserted else { return }
        await performMarkDone(todo)
    }

    /// Hides the to-do immediately but waits `undoWindow` before calling GitLab,
    /// so a misclick can be reverted with `undoMarkDone()`.
    func markDoneWithUndo(_ todo: Todo) {
        commitPendingMarkDone()
        guard optimisticallyDone.insert(todo.id).inserted else { return }
        undoableTodo = todo
        pendingMarkDoneTask = Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            self?.commitPendingMarkDone()
        }
    }

    func undoMarkDone() {
        guard let todo = undoableTodo else { return }
        pendingMarkDoneTask?.cancel()
        pendingMarkDoneTask = nil
        undoableTodo = nil
        optimisticallyDone.remove(todo.id)
    }

    private func commitPendingMarkDone() {
        guard let todo = undoableTodo else { return }
        pendingMarkDoneTask?.cancel()
        pendingMarkDoneTask = nil
        undoableTodo = nil
        Task { await performMarkDone(todo) }
    }

    /// Expects `todo.id` to already be in `optimisticallyDone`.
    private func performMarkDone(_ todo: Todo) async {
        let host = inboxHost
        let username = glab.currentUsername
        let result = await glab.markAsDone(id: todo.id, host: host)
        optimisticallyDone.remove(todo.id)
        guard inboxHost == host, glab.currentUsername == username else { return }
        switch result {
        case .success:
            if isLoading { acknowledgedDuringFetch.insert(todo.id) }
            allTodos.removeAll { $0.id == todo.id }
            if failedAutomationTodoID == todo.id { failedAutomationTodoID = nil }
            settings.lastSeenTodoIDs.remove(todo.id)
            if let host, let username {
                settings.pendingTodoAcknowledgements.remove(.init(host: host, username: username, todo: todo.feedbackIdentity))
            }
            settings.save()
        case .failure(let err):
            lastError = err
            Log.monitor.error("Mark-as-done failed for \(todo.id, privacy: .public): \(String(describing: err), privacy: .public)")
        }
        restartUnreadReminderTimer()
    }

    /// Re-runs glab detection and pushes the resolved state into settings so a
    /// Re-check button in Settings or Onboarding updates the monitor live.
    func recheckIntegration() async {
        if let error = await glab.recheck() {
            lastError = error
        } else {
            lastError = nil
        }
        settings.resolvedHost = glab.resolvedHost
        settings.save()
        authoredMergeRequests.refreshIfNeeded()
    }
}
