import Foundation
import Observation
import MergeTetherRemote

@MainActor protocol RemoteHostTransport: AnyObject {
    var onMessage: (@MainActor (RemoteMessage) async -> Void)? { get set }
    var onPairingEstablished: (@MainActor (RemotePairing) throws -> Void)? { get set }
    var onStatus: (@MainActor (Bool, Bool) -> Void)? { get set }
    func start()
    func stop()
    func send(_ message: RemoteMessage) async throws
}

extension RemoteConnection: RemoteHostTransport {}

@MainActor @Observable final class RemoteHostController {
    typealias DetailReader = @MainActor (GitLabMergeRequest, [GitLabDraftNote], GlabService) async throws -> RemoteMRDetails
    private(set) var pairing: RemotePairing?
    let relayConfiguration: RemoteRelayConfiguration
    private(set) var relayMismatch = false
    var origin = ""
    var invitation = ""
    private(set) var failed = false
    private(set) var connected = false
    private let monitor: TodoMonitorService
    private let store: RemotePairingStore
    private let savePairing: (RemotePairing) throws -> Void
    private let removePairing: () throws -> Void
    private let connectPairing: ((RemotePairing) -> Void)?
    @ObservationIgnored private(set) var startupLoadTask: Task<Void, Never>?
    private var startupGeneration = UUID()
    private let makeConnection: (RemotePairing) throws -> any RemoteHostTransport
    private var connection: (any RemoteHostTransport)?
    private var hostSession = UUID()
    private var account = ""
    private var accountRevision: UInt64?
    private let gate: RemoteCommandGate
    private let now: () -> Date
    private var phoneSupportsCommentReview = false
    private var phoneSupportsMergeActions = false
    private var phoneSupportsDetails = false
    private var phoneSupportsDetailPreviews = false
    private var phoneSupportsOriginUpdates = false
    private var phoneSupportsMRControls = false
    private var phoneSupportsCommentOrigins = false
    private var phoneSupportsMarkReady = false
    private var originObserver: UUID?
    private var authorKindObserver: UUID?
    private var originSubscription: RemoteDetailOriginSubscription?
    @ObservationIgnored private var originUpdateTask: Task<Void, Never>?
    @ObservationIgnored private(set) var detailTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundRefresh: Task<Void, Never>?
    private let detailReader: DetailReader
    private var activeDetailRequest: RemoteDetailRequest?
    private var lastDetailRead = Date.distantPast
    @ObservationIgnored private var recentDetails: [String: (digest: String, details: RemoteMRDetails)] = [:]
    @ObservationIgnored private var resolutionPreviews: [String: ManualDiscussionResolution.Prepared] = [:]

    init(monitor: TodoMonitorService,
         relayConfiguration: RemoteRelayConfiguration = .bundled(),
         loadPairing: (@Sendable () async throws -> RemotePairing?)? = nil,
         savePairing: ((RemotePairing) throws -> Void)? = nil,
         removePairing: (() throws -> Void)? = nil,
         connectPairing: ((RemotePairing) -> Void)? = nil,
         commandGate: RemoteCommandGate? = nil,
         now: @escaping () -> Date = Date.init,
         detailReader: @escaping DetailReader = { try await RemoteMRDetailLoader.load(source: $0, drafts: $1, glab: $2) },
         makeConnection: @escaping (RemotePairing) throws -> any RemoteHostTransport = { try RemoteConnection(pairing: $0, role: .host) }) {
        self.monitor = monitor
        self.relayConfiguration = relayConfiguration
        origin = relayConfiguration.origin?.absoluteString ?? ""
        self.now = now
        self.detailReader = detailReader
        self.gate = commandGate ?? RemoteCommandGate(store: RemoteCommandReceiptStore(service: (Bundle.main.bundleIdentifier ?? "MergeTether") + ".remote"))
        let store = RemotePairingStore(service: (Bundle.main.bundleIdentifier ?? "MergeTether") + ".remote")
        self.store = store
        self.savePairing = savePairing ?? { try store.save($0) }
        self.removePairing = removePairing ?? { try store.remove() }
        self.connectPairing = connectPairing
        self.makeConnection = makeConnection
        let load: @Sendable () async throws -> RemotePairing? = loadPairing ?? { try store.load() }
        if relayConfiguration.status == .configured { loadStoredPairing(using: load) }
    }

    private func loadStoredPairing(using load: @escaping @Sendable () async throws -> RemotePairing?) {
        let generation = startupGeneration
        let initialOrigin = origin, initialInvitation = invitation
        // Keychain may wait for user consent. Optional companion setup must never
        // hold the main actor while the Mac board and automation are starting.
        let read = Task.detached(priority: .utility) { try await load() }
        startupLoadTask = Task { [weak self] in
            do {
                let loaded = try await read.value
                guard !Task.isCancelled, let self,
                      startupGeneration == generation, origin == initialOrigin, invitation == initialInvitation else { return }
                guard loaded == nil || loaded?.role == .host else { throw RemoteProtocolError.invalid }
                if let loaded, !relayConfiguration.accepts(origin: loaded.origin) {
                    relayMismatch = true
                    return
                }
                pairing = loaded
                if let loaded {
                    origin = loaded.origin.absoluteString; invitation = loaded.access
                    activatePairing(loaded)
                } else { loadLocalOperatorSetup() }
            } catch {
                guard !Task.isCancelled, let self,
                      startupGeneration == generation, origin == initialOrigin, invitation == initialInvitation else { return }
                failed = true
            }
        }
    }

    func enable() {
        startupGeneration = UUID(); startupLoadTask?.cancel()
        do {
            guard let url = URL(string: origin.trimmingCharacters(in: .whitespacesAndNewlines)),
                  relayConfiguration.accepts(origin: url), let configured = relayConfiguration.origin else { throw RemoteProtocolError.invalid }
            let pair = try RemotePairing.generate(origin: configured, access: invitation.trimmingCharacters(in: .whitespacesAndNewlines), now: now())
            try savePairing(pair)
            connection?.stop(); connection = nil; resetConnectionSession()
            recentDetails.removeAll()
            pairing = pair; relayMismatch = false; activatePairing(pair)
        } catch { failed = true }
    }
    func disable() {
        if let originObserver { monitor.attention.displayAIOriginCoordinator?.removeOriginObserver(originObserver) }
        originObserver = nil
        if let authorKindObserver { monitor.glab.removeFeedbackAccountObserver(authorKindObserver) }
        authorKindObserver = nil
        startupGeneration = UUID(); startupLoadTask?.cancel()
        connection?.stop(); connection = nil; pairing = nil; connected = false
        recentDetails.removeAll()
        resetConnectionSession()
        do { try removePairing(); failed = false } catch { failed = true }
    }
    private func activatePairing(_ pair: RemotePairing) {
        if let connectPairing { connectPairing(pair); failed = false }
        else { start(pair) }
    }
    private func resetConnectionSession() {
        hostSession = UUID()
        resolutionPreviews.removeAll()
        phoneSupportsCommentReview = false
        phoneSupportsMergeActions = false
        phoneSupportsDetails = false
        phoneSupportsDetailPreviews = false
        phoneSupportsOriginUpdates = false
        phoneSupportsMRControls = false
        phoneSupportsCommentOrigins = false
        phoneSupportsMarkReady = false
        clearOriginSubscription()
        detailTask?.cancel(); detailTask = nil; activeDetailRequest = nil
        lastDetailRead = .distantPast
    }
    private func start(_ pair: RemotePairing) {
        do {
            if authorKindObserver == nil {
                authorKindObserver = monitor.glab.observeFeedbackAccountKinds { [weak self] event in
                    self?.receiveFeedbackAccountKind(event)
                }
            }
            if originObserver == nil, let coordinator = monitor.attention.displayAIOriginCoordinator {
                originObserver = coordinator.observePersistedOrigins { [weak self] event in
                    self?.receivePersistedOrigins(event)
                }
            }
            resetConnectionSession()
            let connection = try makeConnection(pair)
            connection.onPairingEstablished = { [weak self, weak connection] established in
                guard let self, let connection, self.connection === connection,
                      self.pairing?.sessionID == established.sessionID else { throw RemoteProtocolError.invalid }
                try self.savePairing(established)
                self.pairing = established
            }
            connection.onStatus = { [weak self, weak connection] connected, fatal in
                guard let self, let connection, self.connection === connection else { return }
                self.resetConnectionSession()
                self.connected = connected; self.failed = fatal
                if connected {
                    Task { [weak self, weak connection] in
                        guard let self, let connection, self.connection === connection else { return }
                        try? await connection.send(.init(type: .hostReady))
                    }
                }
            }
            connection.onMessage = { [weak self, weak connection] message in
                guard let self, let connection, self.connection === connection else { return }
                await self.receive(message)
            }
            self.connection = connection; connection.start(); failed = false
        } catch { failed = true }
    }
    private func loadLocalOperatorSetup() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/MergeTether/remote-relay")
        guard let data = try? Data(contentsOf: folder.appending(path: "operator.json")),
              let values = try? JSONDecoder().decode([String: String].self, from: data),
              let origin = try? String(contentsOf: folder.appending(path: "origin.txt"), encoding: .utf8) else { return }
        guard let url = URL(string: origin.trimmingCharacters(in: .whitespacesAndNewlines)),
              relayConfiguration.accepts(origin: url) else { return }
        invitation = values["RELAY_ACCESS_TOKEN"] ?? ""
    }
    private func receive(_ message: RemoteMessage) async {
        guard let active = connection else { return }
        switch message.type {
        case .hello:
            guard let challenge = message.challenge else { return }
            phoneSupportsCommentReview = message.capabilities?.contains(RemoteMessage.commentReviewCapability) == true
            phoneSupportsMergeActions = message.capabilities?.contains(RemoteMessage.mergeActionsCapability) == true
            phoneSupportsDetails = message.capabilities?.contains(RemoteMessage.detailsCapability) == true
            phoneSupportsDetailPreviews = phoneSupportsDetails && message.capabilities?.contains(RemoteMessage.detailPreviewCapability) == true
            phoneSupportsMRControls = message.capabilities?.contains(RemoteMessage.mrControlsCapability) == true
            phoneSupportsMarkReady = message.capabilities?.contains(RemoteMessage.markReadyCapability) == true
            phoneSupportsCommentOrigins = phoneSupportsDetails && message.capabilities?.contains(RemoteMessage.commentOriginCapability) == true
            phoneSupportsOriginUpdates = phoneSupportsDetails && message.capabilities?.contains(RemoteMessage.detailOriginsCapability) == true
            if !phoneSupportsOriginUpdates { clearOriginSubscription() }
            let fresh: Bool
            if message.refresh == true || (message.refresh == nil && monitor.lastRefresh == nil) {
                // An explicit refresh, or a Mac that has not loaded GitLab yet, waits for current data.
                fresh = await refreshSource(force: message.refresh == true, deadline: .now + .seconds(35))
            } else {
                // A snapshot-only hello after a suggestion decision does not trigger a stale-board poll.
                let settled = await RemoteRefreshBarrier.refresh(deadline: .now + .seconds(4), isRefreshing: {
                    self.monitor.isLoading || self.monitor.attention.isLoading || self.monitor.authoredMergeRequests.isLoading
                }, refresh: {}, validate: { true })
                fresh = settled && monitor.lastRefresh != nil
                if message.refresh == nil { refreshInBackgroundIfStale() }
            }
            guard connection === active else { return }
            var board = snapshot()
            if !fresh { board.partial = true }
            do { try await active.send(.init(type: .snapshot, challenge: challenge, board: board,
                capabilities: [RemoteMessage.detailsCapability, RemoteMessage.detailContextCapability, RemoteMessage.detailOriginsCapability, RemoteMessage.mrControlsCapability,
                               RemoteMessage.commentOriginCapability, RemoteMessage.markReadyCapability, RemoteMessage.detailPreviewCapability])) }
            catch { failed = true; try? await active.send(.init(type: .unavailable)) }
        case .receipt:
            guard let command = message.command, let challenge = message.challenge, let pairing else { return }
            let result = gate.receipt(for: command, account: snapshot().account, pairingSession: pairing.sessionID)
            try? await active.send(.init(type: .receiptResult, challenge: challenge, result: result))
        case .detailRequest:
            guard phoneSupportsDetails, let request = message.detailRequest else { return }
            beginDetails(request, connection: active)
        case .cancelDetails:
            if message.detailRequest == originSubscription?.request { clearOriginSubscription() }
            if message.detailRequest == activeDetailRequest {
                detailTask?.cancel(); detailTask = nil; activeDetailRequest = nil
            }
        case .command:
            guard let command = message.command, let pairing else { return }
            // Suggestion decisions validate live evidence for their own MR before saving locally.
            let fresh = if command.isFeedbackSuggestionDecision { true } else {
                await refreshSource(force: true, deadline: .now + .seconds(35))
            }
            var board = snapshot()
            if !fresh { board.partial = true }
            guard connection === active else { return }
            var acceptanceSent = false
            let result = await gate.execute(command, board: board, pairingSession: pairing.sessionID, accepted: {
                do {
                    try await active.send(.init(type: .accepted, result: .init(id: command.id, status: .running)))
                    acceptanceSent = true
                } catch { /* Never begin a new write when acceptance cannot even be sent. */ }
            }) { [weak self] card, action in
                guard let self else { return .uncertain }
                // Main-actor state may change during an awaited acceptance send.
                guard acceptanceSent, self.connection === active else { return .changed }
                let settled = await RemoteRefreshBarrier.refresh(deadline: .now + .seconds(35), isRefreshing: {
                    self.monitor.isLoading || self.monitor.attention.isLoading || self.monitor.authoredMergeRequests.isLoading
                }, refresh: {}, validate: { true })
                let current = self.snapshot()
                guard settled, self.connection === active, !current.partial,
                      current.hostSession == board.hostSession, current.account == board.account,
                      current.cards.contains(where: { $0.hasSameActionContext(as: card) && $0.actions.contains(action) }) else { return .changed }
                return await self.execute(card, action: action, argument: command.argument)
            }
            try? await active.send(.init(type: .result, result: result))
        default: break
        }
    }
    private func beginDetails(_ request: RemoteDetailRequest, connection active: any RemoteHostTransport) {
        guard request.isValid, activeDetailRequest != request else { return }
        let board = snapshot()
        let sourceBoard = monitor.boardSnapshot
        let proposals = sourceBoard.proposals.compactMap { proposal in
            proposal.item.map { MergeRequestBoardSnapshot.Row(item: $0, latestJob: proposal.latestJob, intents: proposal.intents) }
        }
        let rows = sourceBoard.own + sourceBoard.reviewed + sourceBoard.otherMergeRequests + proposals
        guard request.matches(board), let pairingSession = pairing?.sessionID,
              let row = rows.first(where: { "mr:\($0.id.projectID):\($0.id.iid)" == request.cardID }),
              let source = row.displayRequest,
              let card = board.cards.first(where: { $0.id == request.cardID }),
              card.contextRevision == RemoteBoardAdapter.contextRevision(source) else {
            Task { try? await active.send(.init(type: .details, detailResponse: .init(request: request, status: .changed))) }
            return
        }
        clearOriginSubscription()
        let nextRead = lastDetailRead.addingTimeInterval(1)
        let digest = card.detailContextDigest
        detailTask?.cancel(); activeDetailRequest = request
        let revision = monitor.glab.accountRevision
        let subscription = phoneSupportsOriginUpdates
            ? RemoteDetailOriginSubscription(request: request, source: source, accountRevision: revision) : nil
        originSubscription = subscription
        detailTask = Task { [weak self, weak active] in
            guard let self, let active else { return }
            defer {
                if activeDetailRequest == request { activeDetailRequest = nil; detailTask = nil }
            }
            let response: RemoteDetailResponse
            do {
                if phoneSupportsDetailPreviews, let username = monitor.glab.currentUsername {
                    let preview = await detailPreview(request, source: source, row: row, username: username,
                        digest: digest, checkedAt: board.updatedAt ?? now())
                    guard !Task.isCancelled, phoneSupportsDetails, connection === active,
                          self.pairing?.sessionID == pairingSession, monitor.glab.accountRevision == revision,
                          activeDetailRequest == request else { return }
                    if phoneSupportsDetailPreviews, request.matches(snapshot()) {
                        try? await active.send(.init(type: .details, detailResponse: preview))
                    }
                }
                let delay = nextRead.timeIntervalSince(now())
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled, phoneSupportsDetails, connection === active,
                      self.pairing?.sessionID == pairingSession, monitor.glab.accountRevision == revision,
                      activeDetailRequest == request else { return }
                guard request.matches(snapshot()) else { throw RemoteMRDetailLoader.ReadError.changed }
                lastDetailRead = now()
                var details = try await detailReader(source, row.evidenceMatchesCatalogContext ? row.item.drafts : [], monitor.glab)
                let usage = try? await AssistantUsageStore.shared.snapshot()
                try Task.checkCancellation()
                RemoteMRDetailSupplement.append(to: &details, row: row, monitor: monitor, usage: usage)
                response = .init(request: request, status: .current, details: details)
            } catch RemoteMRDetailLoader.ReadError.changed { response = .init(request: request, status: .changed) }
            catch { response = .init(request: request, status: .unavailable) }
            let bounded = await Task.detached(priority: .utility) { response.bounded() }.value
            guard !Task.isCancelled, phoneSupportsDetails, connection === active, self.pairing?.sessionID == pairingSession,
                  monitor.glab.accountRevision == revision, activeDetailRequest == request else { return }
            var checked = bounded
            if !request.matches(snapshot()) { checked = .init(request: request, status: .changed) }
            if checked.status == .current, let digest, let details = checked.details {
                recentDetails[request.cardID] = (digest, details)
                if recentDetails.count > 16, let oldest = recentDetails.min(by: { $0.value.details.checkedAt < $1.value.details.checkedAt })?.key {
                    recentDetails.removeValue(forKey: oldest)
                }
            }
            do {
                try await active.send(.init(type: .details, detailResponse: checked))
                guard !Task.isCancelled, phoneSupportsDetails, connection === active,
                      self.pairing?.sessionID == pairingSession, monitor.glab.accountRevision == revision,
                      activeDetailRequest == request, request.matches(snapshot()) else { return }
                if checked.status == .current, let details = response.details {
                    if let subscription, originSubscription === subscription, let delivered = checked.details {
                        subscription.delivered(full: details, rendered: delivered)
                        flushOriginUpdates()
                    }
                    RemoteMRDetailSupplement.scheduleDisplayOrigins(in: details, request: source, monitor: monitor, accountRevision: revision)
                }
            } catch {}
        }
    }

    private func detailPreview(_ request: RemoteDetailRequest, source: GitLabMergeRequest, row: MergeRequestBoardSnapshot.Row,
                               username: String, digest: String?, checkedAt: Date) async -> RemoteDetailResponse {
        if let cached = recentDetails[request.cardID], cached.digest == digest {
            let response = RemoteDetailResponse(request: request, status: .current, details: cached.details, isPreview: true)
            return await Task.detached(priority: .userInitiated) { response.bounded() }.value
        }
        let discussions = monitor.glab.cachedDiscussions(projectID: source.projectID, iid: source.iid)
        let item = row.evidenceMatchesCatalogContext ? row.item : row.displayItem
        var details = await Task.detached(priority: .userInitiated) {
            RemoteMRDetailLoader.project(request: source, progress: item.approvalProgress, rules: nil, reviewers: nil,
                discussions: discussions, drafts: item.drafts, username: username, checkedAt: checkedAt)
        }.value
        RemoteMRDetailSupplement.append(to: &details, row: row, monitor: monitor, usage: nil)
        let response = RemoteDetailResponse(request: request, status: .current, details: details, isPreview: true)
        return await Task.detached(priority: .userInitiated) { response.bounded() }.value
    }

    private func clearOriginSubscription() {
        originUpdateTask?.cancel(); originUpdateTask = nil; originSubscription = nil
    }

    func receivePersistedOrigins(_ event: AICommentDisplayCoordinator.PersistedOrigins) {
        guard let subscription = originSubscription, subscription.record(event) else { return }
        flushOriginUpdates()
    }

    func receiveFeedbackAccountKind(_ event: FeedbackAccountKindUpdate) {
        guard let subscription = originSubscription, subscription.recordAuthorKind(event) else { return }
        flushOriginUpdates()
    }

    private func flushOriginUpdates() {
        guard originUpdateTask == nil, phoneSupportsOriginUpdates, phoneSupportsDetails, connected,
              let active = connection, let pairingSession = pairing?.sessionID,
              let subscription = originSubscription, subscription.isDelivered else { return }
        guard subscription.accountRevision == monitor.glab.accountRevision,
              subscription.request.matches(snapshot()), originSubscription === subscription else {
            clearOriginSubscription(); return
        }
        guard let update = subscription.nextUpdate() else { return }
        originUpdateTask = Task { [weak self, weak active] in
            guard let self, let active else { return }
            defer {
                if originSubscription === subscription { originUpdateTask = nil; flushOriginUpdates() }
            }
            do {
                guard !Task.isCancelled, connected, phoneSupportsOriginUpdates, phoneSupportsDetails,
                      connection === active, pairing?.sessionID == pairingSession,
                      originSubscription === subscription, subscription.accountRevision == monitor.glab.accountRevision,
                      subscription.request.matches(snapshot()), originSubscription === subscription else { return }
                try await active.send(.init(type: .details, detailOrigins: update))
                guard !Task.isCancelled, connected, phoneSupportsOriginUpdates, phoneSupportsDetails,
                      connection === active, pairing?.sessionID == pairingSession,
                      originSubscription === subscription, subscription.accountRevision == monitor.glab.accountRevision,
                      subscription.request.matches(snapshot()), originSubscription === subscription else { return }
                subscription.recordSent(update)
            } catch {
                if originSubscription === subscription { clearOriginSubscription() }
            }
        }
    }
    /// Keeps an open phone current without making it wait: a later lease renewal carries the result.
    private func refreshInBackgroundIfStale() {
        guard backgroundRefresh == nil, !monitor.isLoading,
              monitor.lastRefresh.map({ now().timeIntervalSince($0) > 120 }) ?? true else { return }
        backgroundRefresh = Task { [weak self] in
            await self?.monitor.refreshNow()
            self?.backgroundRefresh = nil
        }
    }

    private func refreshSource(force: Bool, deadline: ContinuousClock.Instant) async -> Bool {
        await RemoteRefreshBarrier.refresh(deadline: deadline, isRefreshing: {
            self.monitor.isLoading || self.monitor.attention.isLoading || self.monitor.authoredMergeRequests.isLoading
        }, refresh: {
            if force || (self.monitor.lastRefresh.map({ Date().timeIntervalSince($0) > 30 }) ?? true) {
                await self.monitor.refreshNow()
            }
        }, validate: {
            await self.monitor.attention.refreshPendingDrafts()
            return self.monitor.lastError == nil && !self.monitor.attention.hasError && !self.monitor.authoredMergeRequests.hasError
        })
    }

    private func snapshot() -> RemoteBoard {
        let currentAccount = "\(monitor.glab.currentUsername ?? "")@\(monitor.glab.resolvedHost ?? "")"
        if account != currentAccount || accountRevision != monitor.glab.accountRevision {
            clearOriginSubscription()
            recentDetails.removeAll()
            account = currentAccount; accountRevision = monitor.glab.accountRevision; hostSession = UUID()
            resolutionPreviews.removeAll()
        }
        var board = RemoteBoardAdapter.board(monitor: monitor, session: hostSession, account: account)
        if !board.partial {
            let items = monitor.boardSnapshot.own.map(\.item)
            for lane in board.lanes.indices {
                for index in board.lanes[lane].cards.indices {
                    let card = board.lanes[lane].cards[index]
                    if let prepared = resolutionPreviews[card.id],
                       let item = items.first(where: { "mr:\($0.id.projectID):\($0.id.iid)" == card.id }) {
                        board.lanes[lane].cards[index] = RemoteBoardAdapter.resolutionPreview(card, item: item, prepared: prepared, monitor: monitor)
                    }
                }
            }
        }
        return board.forClient(supportsCommentReview: phoneSupportsCommentReview, supportsMergeActions: phoneSupportsMergeActions,
            supportsMRControls: phoneSupportsMRControls, supportsCommentOrigins: phoneSupportsCommentOrigins,
            supportsMarkReady: phoneSupportsMarkReady)
    }
    private func execute(_ card: RemoteCard, action: RemoteAction, argument: String? = nil) async -> RemoteCommandResult.Status {
        if card.id.hasPrefix("completion:") {
            return RemoteBoardAdapter.acknowledgeCompletion(card, action: action, monitor: monitor, account: account)
                ? .completed : .changed
        }
        if action.id.hasPrefix("intent:"), let id = UUID(uuidString: String(action.id.dropFirst(7))) {
            guard let intent = monitor.currentMRTodoIntents.first(where: { $0.id == id }) else { return .changed }
            let consent = intent.kind == .review ? monitor.manualReviewConsent(for: monitor.reviewRequest(for: intent)) : nil
            await monitor.runMRTodoIntent(id: id, confirmedReview: consent)
            return monitor.currentMRTodoIntents.first(where: { $0.id == id })?.state == .failed ? .failed : .completed
        }
        if action.kind == .retryJob, let id = UUID(uuidString: String(action.id.dropFirst(4))) {
            await monitor.retryAssistantJob(id)
            return monitor.assistantJobActionError == nil ? .completed : .failed
        }
        if card.id.hasPrefix("todo:"), let todo = monitor.currentAccountTodos.first(where: { "todo:\($0.id)" == card.id }) {
            switch action.kind {
            case .markDone:
                await monitor.markDone(todo)
                return monitor.allTodos.contains(where: { $0.id == todo.id }) ? .uncertain : .completed
            case .prepare:
                await monitor.runAutomationManually(for: todo)
                return monitor.automationAction(for: todo) == .failed ? .failed : .completed
            default: return .changed
            }
        }
        let board = monitor.boardSnapshot
        guard let item = (board.own + board.reviewed).map(\.item)
            .first(where: { "mr:\($0.id.projectID):\($0.id.iid)" == card.id }),
              RemoteBoardAdapter.card(item, account: account).drafts == card.drafts,
              item.mergeRequest?.sha == card.head else { return .changed }
        if action.kind == .setCommentOrigin {
            guard phoneSupportsCommentOrigins, let request = RemoteCommentOriginRequest(argument: argument) else { return .changed }
            return await executeCommentOrigin(request, item: item)
        }
        if RemoteActionKind.mrControls.contains(action.kind) {
            guard phoneSupportsMRControls else { return .changed }
            let row = (board.own + board.reviewed).first { $0.item.id == item.id }
            return await executeControl(action, item: item, row: row)
        }
        switch action.kind {
        case .markReady:
            guard phoneSupportsMarkReady, action.id == "markReady", monitor.canMarkMergeRequestReady(item) else { return .changed }
            do {
                try await monitor.markMergeRequestReady(for: item)
                return .completed
            } catch is CancellationError { return .changed }
            catch GlabError.notAuthenticated { return .changed }
            catch { return .uncertain }
        case .merge, .enqueueMerge:
            guard phoneSupportsMergeActions, let request = item.authoredRequest else { return .changed }
            let mode: MergeSubmissionAction = action.kind == .merge ? .mergeNow : .enqueue
            let outcome = await monitor.authoredMergeRequests.mergeManually(request,
                action: mode, verificationAssistant: monitor.settings.automation.assistant)
            switch outcome {
            case .merged: return .completed
            case .queued: return .queued
            case .inTrain: return .inTrain
            case .uncertain: return .uncertain
            case .none, .changed: return .changed
            }
        case .checkThreads:
            guard phoneSupportsMergeActions, let request = item.authoredRequest else { return .changed }
            do {
                resolutionPreviews[card.id] = try await ManualDiscussionResolution.prepare(request, monitor: monitor,
                    expectedFingerprint: item.observedDiscussionFingerprint)
                return .checked
            } catch { return .changed }
        case .resolveThreads:
            guard phoneSupportsMergeActions, let prepared = resolutionPreviews[card.id],
                  action.id == ManualDiscussionResolution.actionID(prepared.plan.eligibleIDs),
                  !prepared.plan.eligibleIDs.isEmpty else { return .changed }
            resolutionPreviews[card.id] = nil
            let result = await ManualDiscussionResolution.resolve(prepared, glab: monitor.glab, settings: monitor.settings)
            return result.isComplete ? .completed : result.resolved > 0 ? .partial : .changed
        case .finishCommentReview:
            return await monitor.attention.finishCommentReview(item) ? .completed
                : (monitor.attention.confirmationStates[item.id] == .failed ? .failed : .changed)
        case .deleteDraft:
            guard action.id.hasPrefix("deleteDraft:"), let id = Int(action.id.dropFirst("deleteDraft:".count)),
                  let draft = item.drafts.first(where: { $0.id == id }) else { return .changed }
            await monitor.attention.deleteDraft(draft, from: item.id)
            if monitor.attention.confirmationStates[item.id] == .failed { return .uncertain }
            return monitor.attention.currentOpenItems.first(where: { $0.id == item.id })?.drafts.contains(draft) == false
                ? .completed : .changed
        case .publish:
            guard let head = card.head else { return .changed }
            switch await monitor.attention.publishRemoteDrafts(of: item.id, head: head, expectedDrafts: item.drafts) {
            case .completed: return .completed
            case .changed: return .changed
            case .uncertain: return .uncertain
            case .partial: return .partial
            }
        case .approve:
            guard let head = card.head else { return .changed }
            if await monitor.attention.approveRemotely(item.id, expectedHead: head) { return .completed }
            return monitor.attention.confirmationStates[item.id] == .failed ? .uncertain : .changed
        case .prepare:
            guard action.id == "prepare" else { return .changed }
            await monitor.handleFeedbackManually(for: item)
            return monitor.attentionFeedbackAction(for: item) == .failed ? .failed : .completed
        case .handoff:
            monitor.confirmPipelineHandoff(for: item.id); return .completed
        case .reReview:
            guard let head = card.head, let fingerprint = item.reReviewFingerprint else { return .changed }
            await monitor.attention.confirmReReview(item.id, head: head, fingerprint: fingerprint)
            return monitor.attention.currentOpenItems.first(where: { $0.id == item.id })?.reReviewRequested == true ? .completed : .uncertain
        case .verify:
            guard let retry = MRVerificationRetry(rawValue: action.id), retry.isAvailable(for: item) else { return .changed }
            switch retry {
            case .authorFeedback: monitor.attention.retryAuthorFeedback(item.id)
            case .drafts: monitor.attention.retryDraftProofRecovery(item.id)
            case .reReview: await monitor.attention.retryReReview(item.id)
            }
            return .completed
        default: return .changed
        }
    }

    /// Applies the phone's origin verdict only to comments that still match what the phone displayed.
    private func executeCommentOrigin(_ request: RemoteCommentOriginRequest,
                                      item: MergeRequestAttentionMonitor.Item) async -> RemoteCommandResult.Status {
        guard let target = monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) else { return .changed }
        let center = monitor.commentOrigins
        switch request.operation {
        case .undo, .continueNow:
            guard let id = request.changeID.flatMap(UUID.init(uuidString:)),
                  let change = center.pending.first(where: { $0.id == id }), change.target == target else { return .changed }
            if request.operation == .undo {
                do { try center.undo(id) } catch { return .failed }
            } else {
                await center.continueNow(id)
            }
            return .completed
        case .set:
            guard !request.notes.isEmpty else { return .changed }
            do {
                let discussions = try await monitor.glab.fetchMergeRequestDiscussions(
                    projectID: item.id.projectID, iid: item.id.iid, host: target.host)
                guard let notes = RemoteCommentOriginMatcher.notes(request.notes, in: discussions) else { return .changed }
                let classification: AICommentOriginOverride.Classification? = switch request.origin {
                case .ai: .ai
                case .uncertain: .uncertain
                case .human: .human
                case nil: nil
                }
                try await monitor.setCommentOrigin(classification, notes: notes, in: discussions, for: target)
                return .completed
            } catch is CommentOriginOverrideCenter.ChangeError { return .changed }
            catch { return .failed }
        }
    }

    /// Runs one MR control after the gate matched its token against the host board.
    private func executeControl(_ action: RemoteAction, item: MergeRequestAttentionMonitor.Item,
                                row: MergeRequestBoardSnapshot.Row?) async -> RemoteCommandResult.Status {
        func suffix(_ prefix: String) -> String? {
            action.id.hasPrefix(prefix) ? String(action.id.dropFirst(prefix.count)) : nil
        }
        guard let target = monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) else { return .changed }
        switch action.kind {
        case .stopJob:
            guard let id = suffix("stopJob:").flatMap(UUID.init(uuidString:)), row?.latestJob?.id == id,
                  row?.latestJob?.execution?.state.isActive == true else { return .changed }
            monitor.cancelAssistantJob(id)
            return .completed
        case .runReview:
            guard action.id == "runReview", monitor.canRunReview(for: item) else { return .changed }
            await monitor.runReview(for: item, confirmed: monitor.manualReviewConsent(for: item))
            return monitor.assistantJobActionError == nil ? .completed : .failed
        case .publishDraft:
            guard let id = suffix("publishDraft:").flatMap(Int.init),
                  let draft = item.drafts.first(where: { $0.id == id }), DraftPublicationRisk(draft: draft) == nil,
                  let host = monitor.glab.resolvedHost, let username = monitor.glab.currentUsername else { return .changed }
            await monitor.attention.publishDrafts([draft], for: .init(host: host, username: username,
                projectID: item.id.projectID, iid: item.id.iid, url: item.url))
            switch monitor.attention.confirmationStates[item.id] {
            case .failed: return .uncertain
            case .changed: return .changed
            default:
                return monitor.attention.currentOpenItems.first(where: { $0.id == item.id })?.drafts.contains(draft) == false
                    ? .completed : .uncertain
            }
        case .ignoreSuggestion:
            guard let findingID = suffix("ignoreSuggestion:").flatMap(Int.init),
                  let suggestion = RemoteBoardAdapter.ignorableSuggestions(item).first(where: { $0.findingID == findingID }),
                  let request = item.mergeRequest,
                  let fingerprint = item.authorFeedbackStatus?.fingerprint else { return .changed }
            do {
                try await monitor.ignoreFeedbackSuggestion(noteID: suggestion.noteID, concernSummary: suggestion.summary,
                    concernReason: suggestion.reason, for: target,
                    confirmation: .init(request: request, discussionFingerprint: fingerprint))
                return .completed
            } catch let error as FeedbackSuggestionDecisionError {
                return error == .unavailable ? .failed : .changed
            } catch { return .failed }
        case .restoreSuggestion:
            guard let id = suffix("restoreSuggestion:").flatMap(UUID.init(uuidString:)),
                  let request = item.mergeRequest, let fingerprint = item.observedDiscussionFingerprint,
                  monitor.settings.feedbackSuggestionDecisions.entries(for: target).contains(where: { $0.id == id }) else {
                return .changed
            }
            do {
                try await monitor.restoreFeedbackSuggestion(id, for: target,
                    confirmation: .init(request: request, discussionFingerprint: fingerprint))
                return .completed
            } catch { return .changed }
        default: return .changed
        }
    }
}
