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
    @ObservationIgnored private(set) var detailTask: Task<Void, Never>?
    private let detailReader: DetailReader
    private var activeDetailRequest: RemoteDetailRequest?
    private var lastDetailRead = Date.distantPast
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
            pairing = pair; relayMismatch = false; activatePairing(pair)
        } catch { failed = true }
    }
    func disable() {
        startupGeneration = UUID(); startupLoadTask?.cancel()
        connection?.stop(); connection = nil; pairing = nil; connected = false
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
        detailTask?.cancel(); detailTask = nil; activeDetailRequest = nil
        lastDetailRead = .distantPast
    }
    private func start(_ pair: RemotePairing) {
        do {
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
            let fresh = await refreshSource(force: false, deadline: .now + .seconds(35))
            guard connection === active else { return }
            var board = snapshot()
            if !fresh { board.partial = true }
            do { try await active.send(.init(type: .snapshot, challenge: challenge, board: board,
                capabilities: [RemoteMessage.detailsCapability])) }
            catch { failed = true; try? await active.send(.init(type: .unavailable)) }
        case .receipt:
            guard let command = message.command, let challenge = message.challenge, let pairing else { return }
            let result = gate.receipt(for: command, account: snapshot().account, pairingSession: pairing.sessionID)
            try? await active.send(.init(type: .receiptResult, challenge: challenge, result: result))
        case .detailRequest:
            guard phoneSupportsDetails, let request = message.detailRequest else { return }
            beginDetails(request, connection: active)
        case .cancelDetails:
            if message.detailRequest == activeDetailRequest {
                detailTask?.cancel(); detailTask = nil; activeDetailRequest = nil
            }
        case .command:
            guard let command = message.command, let pairing else { return }
            let fresh = await refreshSource(force: true, deadline: .now + .seconds(35))
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
                guard acceptanceSent, self.connection === active, self.snapshot() == board else { return .changed }
                return await self.execute(card, action: action)
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
              board.cards.first(where: { $0.id == request.cardID })?.contextRevision == RemoteBoardAdapter.contextRevision(source) else {
            Task { try? await active.send(.init(type: .details, detailResponse: .init(request: request, status: .changed))) }
            return
        }
        guard now().timeIntervalSince(lastDetailRead) >= 1 else {
            Task { try? await active.send(.init(type: .details, detailResponse: .init(request: request, status: .unavailable))) }
            return
        }
        detailTask?.cancel(); activeDetailRequest = request; lastDetailRead = now()
        let revision = monitor.glab.accountRevision
        detailTask = Task { [weak self, weak active] in
            guard let self, let active else { return }
            defer {
                if activeDetailRequest == request { activeDetailRequest = nil; detailTask = nil }
            }
            let response: RemoteDetailResponse
            do {
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
            do {
                try await active.send(.init(type: .details, detailResponse: checked))
                guard !Task.isCancelled, phoneSupportsDetails, connection === active,
                      self.pairing?.sessionID == pairingSession, monitor.glab.accountRevision == revision,
                      activeDetailRequest == request, request.matches(snapshot()) else { return }
                if checked.status == .current, let details = response.details {
                    RemoteMRDetailSupplement.scheduleDisplayOrigins(in: details, request: source, monitor: monitor, accountRevision: revision)
                }
            } catch {}
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
        return board.forClient(supportsCommentReview: phoneSupportsCommentReview, supportsMergeActions: phoneSupportsMergeActions)
    }
    private func execute(_ card: RemoteCard, action: RemoteAction) async -> RemoteCommandResult.Status {
        if card.id.hasPrefix("completion:") {
            return RemoteBoardAdapter.acknowledgeCompletion(card, action: action, monitor: monitor, account: account)
                ? .completed : .changed
        }
        if action.id.hasPrefix("intent:"), let id = UUID(uuidString: String(action.id.dropFirst(7))) {
            await monitor.runMRTodoIntent(id: id)
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
        switch action.kind {
        case .merge, .enqueueMerge:
            guard phoneSupportsMergeActions, let request = item.authoredRequest else { return .changed }
            let outcome = await monitor.authoredMergeRequests.mergeManually(request)
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
            await monitor.runAttentionFeedback(for: item)
            return monitor.attentionFeedbackAction(for: item) == .failed ? .failed : .completed
        case .handoff:
            monitor.confirmPipelineHandoff(for: item.id); return .completed
        case .reReview:
            guard let head = card.head, let fingerprint = item.reReviewFingerprint else { return .changed }
            await monitor.attention.confirmReReview(item.id, head: head, fingerprint: fingerprint)
            return monitor.attention.currentOpenItems.first(where: { $0.id == item.id })?.reReviewRequested == true ? .completed : .uncertain
        case .verify:
            if item.draftProofRecoveryFailure != nil {
                monitor.attention.retryDraftProofRecovery(item.id)
                return .completed
            }
            await monitor.attention.retryReReview(item.id); return .completed
        default: return .changed
        }
    }
}
