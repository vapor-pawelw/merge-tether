import Foundation
import Observation
import MergeTetherRemote

@MainActor protocol RemotePhoneTransport: AnyObject {
    var onMessage: (@MainActor (RemoteMessage) async -> Void)? { get set }
    var onStatus: (@MainActor (Bool, Bool) -> Void)? { get set }
    func start()
    func stop()
    func send(_ message: RemoteMessage) async throws
}
extension RemoteConnection: RemotePhoneTransport {}

enum RemotePhoneConnectionStatus { case unpaired, connecting, connected, offline, failed }

@MainActor @Observable final class RemotePhoneModel {
    let relayConfiguration: RemoteRelayConfiguration
    private(set) var relayMismatch = false
    var state = RemotePhoneState()
    let detailState = RemoteDetailState()
    private(set) var supportsDetails = false
    private(set) var supportsDetailContext = false
    private(set) var supportsDetailPreviews = false
    private(set) var supportsOriginUpdates = false
    private(set) var isSynchronizingDetails = false
    private(set) var isManuallyRefreshingContent = false
    private var viewedCardID: String?
    private var needsDetailReload = false
    private var detailRecoveryAttempts = 0
    @ObservationIgnored private var contentRefresh: Task<Void, Never>?
    var paired = false
    var error = false
    private(set) var pairingRevision = UUID()
    var pairingCandidate: RemotePairing?
    private var pairing: RemotePairing?
    private var connection: (any RemotePhoneTransport)?
    private let savePairing: (RemotePairing) throws -> Void
    private let saveRecovery: (RemoteCommandRecovery) throws -> Void
    private let removeRecovery: () throws -> Void
    private var recovery: RemoteCommandRecovery?
    private var recoveryUnavailable = false
    private var shouldRecoverCommand = false
    private var receiptChallenge: UUID?
    private var receiptRevision: UUID?
    private let makeConnection: (RemotePairing) throws -> any RemotePhoneTransport
    private var connectionRevision = UUID()
    private struct ApprovalConfirmation {
        let id: UUID
        let card: RemoteCard
        let action: RemoteAction
        let hostSession: UUID
        let account: String
        let connectionRevision: UUID
        let state: RemotePhoneState
        let expiresAt: Date
    }
    private var approvalConfirmation: ApprovalConfirmation?
    private(set) var expiredApprovalCardID: String?
    private var connectingUntil = Date.distantPast
    private var connectionFailed = false
    private let now: () -> Date
    init(
        relayConfiguration: RemoteRelayConfiguration = .bundled(),
        loadPairing: () throws -> RemotePairing? = { try RemotePairingStore(service: "com.vaporpw.MergeTether.iOS.remote").load() },
        savePairing: @escaping (RemotePairing) throws -> Void = { try RemotePairingStore(service: "com.vaporpw.MergeTether.iOS.remote").save($0) },
        loadRecovery: () throws -> RemoteCommandRecovery? = { try RemoteCommandRecoveryStore(service: "com.vaporpw.MergeTether.iOS.remote").load() },
        saveRecovery: @escaping (RemoteCommandRecovery) throws -> Void = { try RemoteCommandRecoveryStore(service: "com.vaporpw.MergeTether.iOS.remote").save($0) },
        removeRecovery: @escaping () throws -> Void = { try RemoteCommandRecoveryStore(service: "com.vaporpw.MergeTether.iOS.remote").remove() },
        makeConnection: @escaping (RemotePairing) throws -> any RemotePhoneTransport = { try RemoteConnection(pairing: $0, role: .phone) },
        now: @escaping () -> Date = Date.init
    ) {
        self.relayConfiguration = relayConfiguration
        self.savePairing = savePairing; self.makeConnection = makeConnection; self.now = now
        self.saveRecovery = saveRecovery; self.removeRecovery = removeRecovery
        guard relayConfiguration.status == .configured else { bindResultAcknowledgement(); return }
        do {
            let loaded = try loadPairing()
            guard loaded == nil || loaded?.role == .phone else { throw RemoteProtocolError.invalid }
            if let loaded, !relayConfiguration.accepts(origin: loaded.origin) {
                relayMismatch = true; bindResultAcknowledgement(); return
            }
            pairing = loaded; paired = loaded != nil
            if let loaded, let previous = try loadRecovery(), previous.pairingSession == loaded.sessionID {
                recovery = previous; shouldRecoverCommand = true
                state.recoverResult(.init(id: previous.command.id, status: .uncertain))
            }
        } catch { self.error = true; recoveryUnavailable = true }
        bindResultAcknowledgement()
    }
    func offerPairing(_ raw: String) {
        do {
            guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw RemoteProtocolError.invalid }
            let candidate = try RemotePairing(url: url, now: now())
            guard relayConfiguration.accepts(origin: candidate.origin) else {
                pairingCandidate = nil; relayMismatch = true; error = true; return
            }
            pairingCandidate = candidate; relayMismatch = false; error = false
        } catch { pairingCandidate = nil; self.error = true }
    }
    @discardableResult func acceptPairing() -> Bool {
        guard let pairing = pairingCandidate, pairing.role == .phone, pairing.invitationIsValid(now: now()),
              relayConfiguration.accepts(origin: pairing.origin) else {
            error = true; return false
        }
        do { try savePairing(pairing) } catch { self.error = true; return false }
        disconnect(); detailState.reset(); self.pairing = pairing; state = RemotePhoneState(); paired = true; error = false
        recovery = nil; shouldRecoverCommand = false; recoveryUnavailable = false; relayMismatch = false
        bindResultAcknowledgement()
        pairingCandidate = nil; pairingRevision = UUID(); connect()
        // Trust was saved even if the transport cannot start yet.
        return true
    }
    func connectionStatus(now: Date = Date()) -> RemotePhoneConnectionStatus {
        guard paired else { return .unpaired }
        if connectionFailed { return .failed }
        if state.isConnected(now: now) { return .connected }
        if now < connectingUntil { return .connecting }
        return .offline
    }
    func reconnect() {
        guard paired, connectionStatus(now: now()) != .connecting else { return }
        disconnect(); connect()
    }
    func connect() {
        guard connection == nil, let pairing, relayConfiguration.accepts(origin: pairing.origin) else { return }
        connectingUntil = now().addingTimeInterval(45); connectionFailed = false; error = false
        do {
            let connection = try makeConnection(pairing)
            connection.onStatus = { [weak self, weak connection] connected, fatal in
                guard let self, let connection, self.connection === connection else { return }
                if !connected {
                    self.connectionRevision = UUID(); self.cancelApproval(); self.state.disconnected()
                    self.detailState.disconnect(); self.supportsDetails = false; self.supportsOriginUpdates = false
                    self.supportsDetailContext = false; self.supportsDetailPreviews = false
                    self.isSynchronizingDetails = false; self.isManuallyRefreshingContent = false
                    self.contentRefresh?.cancel(); self.contentRefresh = nil
                    self.shouldRecoverCommand = self.recovery != nil
                    self.receiptChallenge = nil; self.receiptRevision = nil
                }
                self.error = fatal; self.connectionFailed = fatal
                if connected {
                    let revision = self.connectionRevision
                    Task { [weak self, weak connection] in
                        guard let self, let connection, self.connection === connection, self.connectionRevision == revision else { return }
                        await self.refresh()
                    }
                }
            }
            connection.onMessage = { [weak self, weak connection] message in
                guard let self, let connection, self.connection === connection else { return }
                if message.type == .hostReady { await self.refresh(force: true); return }
                if message.type == .unavailable {
                    self.state.refreshFailed(); self.error = true; self.connectionFailed = true
                    self.isSynchronizingDetails = false; return
                }
                if message.type == .receiptResult {
                    guard let result = message.result, result.id == self.recovery?.command.id,
                          let challenge = self.receiptChallenge, message.challenge == challenge,
                          self.receiptRevision == self.connectionRevision,
                          self.state.board?.account == self.recovery?.command.account else { return }
                    self.receiptChallenge = nil; self.receiptRevision = nil
                    self.state.recoverResult(result)
                    self.shouldRecoverCommand = result.status == .running
                    if result.status != .running { await self.refreshAfterAction(self.recovery?.command) }
                    return
                }
                if message.type == .details {
                    guard self.supportsDetails, let board = self.state.board else { return }
                    if let origins = message.detailOrigins {
                        guard self.supportsOriginUpdates, message.detailResponse == nil else { return }
                        self.detailState.receiveOrigins(origins, board: board)
                        return
                    }
                    guard let response = message.detailResponse else { return }
                    guard response.request == self.detailState.pending else { return }
                    if response.isPreview == true {
                        if self.supportsDetailPreviews { self.detailState.receive(response, board: board) }
                        return
                    }
                    if response.status == .changed, self.detailRecoveryAttempts < 2 {
                        self.detailRecoveryAttempts += 1
                        self.detailState.prepareToReload()
                        self.needsDetailReload = true
                        self.isSynchronizingDetails = true
                        if self.state.pending == nil { await self.refresh(force: true, fromGitLab: true) }
                        return
                    }
                    self.detailState.receive(response, board: board)
                    self.isSynchronizingDetails = false
                    if response.status == .current { self.detailRecoveryAttempts = 0 }
                    return
                }
                let accepted = self.state.receive(message, now: self.now())
                if accepted, message.type == .snapshot, self.state.isConnected(now: self.now()) {
                    self.supportsDetails = message.capabilities?.contains(RemoteMessage.detailsCapability) == true
                    self.supportsDetailContext = self.supportsDetails && message.capabilities?.contains(RemoteMessage.detailContextCapability) == true
                    self.supportsDetailPreviews = self.supportsDetails && message.capabilities?.contains(RemoteMessage.detailPreviewCapability) == true
                    self.supportsOriginUpdates = self.supportsDetails && message.capabilities?.contains(RemoteMessage.detailOriginsCapability) == true
                    if let board = self.state.board { self.detailState.update(board: board) }
                    if self.viewedCardID != nil, self.detailState.failure == .changed { self.isSynchronizingDetails = true }
                    self.error = self.recoveryUnavailable; self.connectionFailed = false; self.connectingUntil = .distantPast
                    await self.recoverLastCommand()
                    await self.refreshViewedDetails()
                    // A slow reply can consume most of its lease; renew before the next timer tick.
                    if self.state.needsRefresh(now: self.now()) { await self.refresh() }
                }
                if accepted, message.type == .result, let result = message.result, result.status != .running {
                    self.shouldRecoverCommand = false
                    let command = self.recovery?.command
                    await self.refreshAfterAction(command?.id == result.id ? command : nil)
                }
            }
            self.connection = connection; connection.start()
        } catch { self.error = true; connectionFailed = true }
    }
    func disconnect() {
        let old = connection; connection = nil; connectionRevision = UUID()
        old?.stop(); cancelApproval(); state.disconnected(); connectingUntil = .distantPast
        detailState.disconnect(); supportsDetails = false; supportsOriginUpdates = false
        supportsDetailContext = false; supportsDetailPreviews = false
        isSynchronizingDetails = false; isManuallyRefreshingContent = false
        contentRefresh?.cancel(); contentRefresh = nil
        shouldRecoverCommand = recovery != nil; receiptChallenge = nil; receiptRevision = nil
    }
    /// An explicit false requests the host snapshot after an action that already refreshed its MR.
    func refresh(force: Bool = false, fromGitLab: Bool? = nil) async {
        let requestState = state
        guard let connection, let challenge = requestState.beginRefresh(force: force || fromGitLab == true, now: now()) else { return }
        do { try await connection.send(.init(type: .hello, challenge: challenge,
            capabilities: [RemoteMessage.commentReviewCapability, RemoteMessage.mergeActionsCapability, RemoteMessage.detailsCapability,
                           RemoteMessage.detailOriginsCapability, RemoteMessage.mrControlsCapability,
                           RemoteMessage.commentOriginCapability, RemoteMessage.markReadyCapability, RemoteMessage.detailPreviewCapability],
            refresh: fromGitLab)) }
        catch {
            guard !Task.isCancelled, self.connection === connection, self.state === requestState else { return }
            if requestState.refreshFailed(challenge: challenge) {
                self.error = true; self.connectionFailed = true; self.isSynchronizingDetails = false
            }
        }
    }
    func refreshContent() async {
        if let contentRefresh { await contentRefresh.value; return }
        isManuallyRefreshingContent = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.detailRecoveryAttempts = 0
            self.needsDetailReload = self.viewedCardID != nil
            self.isSynchronizingDetails = self.viewedCardID != nil
            self.detailState.prepareToReload()
            let revision = self.connectionRevision
            let deadline = ContinuousClock.now + .seconds(45)
            await self.refresh(force: true, fromGitLab: true)
            while !Task.isCancelled, self.connectionRevision == revision, ContinuousClock.now < deadline,
                  self.state.isRefreshing(now: self.now()) || self.detailState.isLoading(now: self.now()) {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            if self.connectionRevision == revision { self.isSynchronizingDetails = false }
        }
        contentRefresh = task
        await task.value
        if !task.isCancelled { contentRefresh = nil; isManuallyRefreshingContent = false }
    }

    private func refreshAfterAction(_ command: RemoteCommand?) async {
        needsDetailReload = viewedCardID != nil
        isSynchronizingDetails = viewedCardID != nil
        detailRecoveryAttempts = 0
        detailState.prepareToReload()
        await refresh(force: true, fromGitLab: command?.isFeedbackSuggestionDecision != true)
    }

    private func refreshViewedDetails() async {
        guard supportsDetails, let id = viewedCardID, let card = state.board?.cards.first(where: { $0.id == id }) else {
            isSynchronizingDetails = false; return
        }
        await requestDetails(card: card, force: needsDetailReload)
    }

    func requestDetails(card: RemoteCard, force: Bool = false) async {
        guard state.board?.cards.contains(where: { $0.id == card.id }) == true else { return }
        if viewedCardID != card.id { detailRecoveryAttempts = 0 }
        viewedCardID = card.id
        if state.pending != nil || (state.isRefreshing(now: now()) && (needsDetailReload || isManuallyRefreshingContent)) {
            needsDetailReload = true; isSynchronizingDetails = true; return
        }
        guard supportsDetails, state.isConnected(now: now()), let board = state.board, let connection,
              force || detailState.openRequest == nil || detailState.details(for: card, board: board) == nil,
              let request = detailState.begin(card: card, board: board, now: now(), force: force,
                  presentationIndependent: supportsDetailContext) else { return }
        needsDetailReload = false; isSynchronizingDetails = false
        let revision = connectionRevision
        do { try await connection.send(.init(type: .detailRequest, detailRequest: request)) }
        catch {
            guard self.connection === connection, connectionRevision == revision, let current = state.board else { return }
            detailState.receive(.init(request: request, status: .unavailable), board: current)
        }
    }
    func cancelDetails() {
        let request = detailState.openRequest ?? detailState.pending
        detailState.disconnect()
        viewedCardID = nil; needsDetailReload = false; isSynchronizingDetails = false; detailRecoveryAttempts = 0
        guard supportsDetails, let request, let connection else { return }
        Task { try? await connection.send(.init(type: .cancelDetails, detailRequest: request)) }
    }
    func prepareApproval(card: RemoteCard, action: RemoteAction) -> UUID? {
        cancelApproval()
        guard connection != nil, !recoveryUnavailable, recovery == nil, action.kind == .approve, card.head != nil,
              state.canAct(now: now()), let board = state.board,
              board.cards.contains(where: { $0.hasSameActionContext(as: card) && $0.actions.contains(action) }) else { return nil }
        let id = UUID()
        approvalConfirmation = .init(id: id, card: card, action: action, hostSession: board.hostSession,
            account: board.account, connectionRevision: connectionRevision, state: state, expiresAt: now().addingTimeInterval(30))
        return id
    }
    func cancelApproval() {
        approvalConfirmation = nil
        expiredApprovalCardID = nil
    }
    func reloadAfterApprovalExpiry(cardID: String) async {
        guard expiredApprovalCardID == cardID else { return }
        cancelApproval()
        await refreshContent()
    }
    /// Sends a comment-origin change, then re-reads the details so the badges and any undo window show.
    func setCommentOrigin(_ request: RemoteCommentOriginRequest, card: RemoteCard) async {
        guard let action = card.actions.first(where: { $0.kind == .setCommentOrigin }),
              let argument = request.argument else { return }
        await perform(card: card, action: action, argument: argument)
    }
    func perform(card: RemoteCard, action: RemoteAction, approvalID: UUID? = nil, argument: String? = nil) async {
        if action.kind == .approve {
            let confirmation = approvalConfirmation
            approvalConfirmation = nil
            guard let confirmation, confirmation.id == approvalID, confirmation.card == card, confirmation.action == action,
                  confirmation.state === state, confirmation.connectionRevision == connectionRevision,
                  let board = state.board, board.hostSession == confirmation.hostSession, board.account == confirmation.account else { return }
            guard now() < confirmation.expiresAt else {
                expiredApprovalCardID = card.id
                return
            }
            guard board.cards.contains(where: { $0.hasSameActionContext(as: card) && $0.actions.contains(action) }) else { return }
        }
        let requestState = state, revision = connectionRevision
        guard !recoveryUnavailable, recovery == nil, let pairing, let connection,
              let command = requestState.command(card: card, action: action, argument: argument, now: now()) else { return }
        let pending = RemoteCommandRecovery(pairingSession: pairing.sessionID, command: command)
        do { try saveRecovery(pending); recovery = pending }
        catch {
            self.error = true; requestState.recoverResult(.init(id: command.id, status: .failed)); return
        }
        do {
            try await connection.send(.init(type: .command, command: command))
        } catch {
            guard self.connection === connection, state === requestState, connectionRevision == revision else { return }
            requestState.disconnected(); shouldRecoverCommand = true; return
        }
        while state === requestState && requestState.pending?.id == command.id {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            requestState.checkCommandTimeout(now: now())
        }
        if state === requestState, requestState.result?.id == command.id, requestState.result?.status == .uncertain {
            shouldRecoverCommand = true
        }
    }
    private func recoverLastCommand() async {
        guard shouldRecoverCommand, let recovery, let pairing, recovery.pairingSession == pairing.sessionID,
              let connection else { return }
        guard state.board?.account == recovery.command.account else {
            state.recoverResult(.init(id: recovery.command.id, status: .uncertain)); return
        }
        let challenge = UUID(), revision = connectionRevision
        receiptChallenge = challenge; receiptRevision = revision
        do { try await connection.send(.init(type: .receipt, challenge: challenge, command: recovery.command)) }
        catch {
            guard self.connection === connection, connectionRevision == revision, receiptChallenge == challenge else { return }
            self.error = true
        }
    }
    private func bindResultAcknowledgement() {
        state.onResultAcknowledgement = { [weak self] result in
            guard let self, self.recovery?.command.id == result.id else { return }
            guard result.status != .running else { throw RemoteProtocolError.invalid }
            do { try self.removeRecovery() }
            catch { self.error = true; throw error }
            self.recovery = nil; self.shouldRecoverCommand = false
        }
    }

}
