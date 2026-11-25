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
    private(set) var avatarThumbnails: [URL: Data] = [:]
    private var avatarSnapshotChallenge: UUID?
    private var detailAvatarURLs: Set<URL> = []
    let detailState = RemoteDetailState()
    private(set) var supportsDetails = false
    private(set) var supportsDetailContext = false
    private(set) var supportsDetailPreviews = false
    private var supportsCachedDetails = false
    private(set) var supportsOriginUpdates = false
    private(set) var supportsDraftRegeneration = false
    /// The Mac accepts structured style presets. Free-form instructions are never sent from the phone.
    private(set) var supportsDraftRegenerationStyles = false
    private(set) var supportsReviewerBatches = false
    var boardOrderMoveRejected = false
    private(set) var draftRegenerationLoadFailed = false
    private var draftRegenerationPreviewBatchID: UUID?
    private var draftRegenerationPreviewToken: String?
    private var failedDraftRegenerationPreview: RemoteDraftRegenerationPageRequest?
    private var draftRegenerationPreview: [DraftRegenerationProposal] = []
    @ObservationIgnored private var draftRegenerationRead: DraftRegenerationRead?
    @ObservationIgnored private var draftRegenerationReadTimeout: Task<Void, Never>?
    @ObservationIgnored private var draftRegenerationPoll: Task<Void, Never>?

    private final class DraftRegenerationRead {
        var request: RemoteDraftRegenerationPageRequest
        var challenge = UUID()
        var bytes = Data()
        var expectedBytes: Int?

        init(request: RemoteDraftRegenerationPageRequest) { self.request = request }
    }
    private(set) var isSynchronizingDetails = false
    private(set) var isManuallyRefreshingContent = false
    private var viewedCardID: String?
    private var issueRefreshCardID: String?
    private var pendingActionPresentation: (id: UUID, card: RemoteCard)?
    var pendingActionCard: RemoteCard? {
        guard let pending = state.pending, pendingActionPresentation?.id == pending.id,
              state.board?.account == pending.account, state.board?.hostSession == pending.hostSession else { return nil }
        return pendingActionPresentation?.card
    }
    private var needsDetailReload = false
    private var needsLiveDetailReload = false
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
    private var lastPersonalApproval: (id: UUID, kind: RemoteActionKind)?
    @ObservationIgnored private var reviewerSearch: RemoteReviewerSearch?
    @ObservationIgnored private var reviewerResults: RemoteReviewerResults?
    @ObservationIgnored private var reviewerAvatars: (request: RemoteReviewerSearch, urls: Set<URL>)?

    var completedPersonalApproval: RemoteActionKind? {
        guard let result = state.result else { return nil }
        guard result.status == .completed, let lastPersonalApproval, lastPersonalApproval.id == result.id else {
            return nil
        }
        return lastPersonalApproval.kind
    }

    var showsAutomaticApprovalOffResult: Bool { completedPersonalApproval == .removeApproval }
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
        disconnect(); detailState.reset(); resetDraftRegenerationConnection()
        self.pairing = pairing; state = RemotePhoneState(); paired = true; error = false
        avatarThumbnails.removeAll()
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
    /// App visibility, independent of SwiftUI so the policy can be tested on the host.
    enum ScenePresence { case active, inactive, background }

    /// `.inactive` also covers Control Center, Notification Center, system alerts and the app switcher.
    /// Keep the connection (and any command in flight) until the app really moves to the background.
    func sceneChanged(_ presence: ScenePresence) {
        switch presence {
        case .active: connect()
        case .background: disconnect()
        case .inactive: break
        }
    }

    func connect() {
        guard connection == nil, let pairing, relayConfiguration.accepts(origin: pairing.origin) else { return }
        connectingUntil = now().addingTimeInterval(45); connectionFailed = false; error = false
        do {
            let connection = try makeConnection(pairing)
            connection.onStatus = { [weak self, weak connection] connected, fatal in
                guard let self, let connection, self.connection === connection else { return }
                if !connected {
                    self.avatarSnapshotChallenge = nil
                    self.connectionRevision = UUID(); self.cancelApproval(); self.state.disconnected()
                    self.detailState.disconnect(); self.supportsDetails = false; self.supportsOriginUpdates = false
                    self.supportsDetailContext = false; self.supportsDetailPreviews = false; self.supportsCachedDetails = false
                    self.supportsReviewerBatches = false; self.reviewerAvatars = nil; self.pruneAvatarThumbnails()
                    self.suspendDraftRegenerationReads()
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
                    if result.status != .running {
                        let command = self.recovery?.command
                        await self.finishAction(result)
                        if command?.isDraftRegeneration == true, result.status == .completed || result.status == .partial,
                           self.state.result?.id == result.id {
                            self.state.acknowledgeResult()
                        }
                    }
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
                        self.needsLiveDetailReload = response.request.cachedOnly != true
                        self.isSynchronizingDetails = true
                        if self.state.pending == nil { await self.refresh(force: true) }
                        return
                    }
                    self.detailState.receive(response, board: board)
                    if response.request == self.detailState.openRequest, response.status == .current {
                        self.detailAvatarURLs = Set(response.details?.avatarThumbnailURLs ?? [])
                        self.pruneAvatarThumbnails()
                    }
                    self.isSynchronizingDetails = false
                    if response.status == .current { self.detailRecoveryAttempts = 0 }
                    return
                }
                if message.type == .draftRegenerationPage {
                    guard let page = message.draftRegenerationPage, let challenge = message.challenge else { return }
                    await self.receiveDraftRegenerationPage(page, challenge: challenge)
                    return
                }
                if message.type == .avatarThumbnails {
                    self.receiveAvatarThumbnails(message)
                    return
                }
                if message.type == .reviewerResults {
                    if let result = message.reviewerResults, let search = self.reviewerSearch, result.id == search.id,
                       let board = self.state.board, search.matches(board) {
                        self.reviewerResults = result
                        self.reviewerAvatars = (search, Set(result.avatarThumbnailURLs))
                        self.pruneAvatarThumbnails()
                    }
                    return
                }
                let previousBoard = self.state.board
                let accepted = self.state.receive(message, now: self.now())
                if accepted, message.type == .snapshot {
                    if let applied = message.boardOrderApplied {
                        self.boardOrderMoveRejected = !applied
                    } else if self.state.board?.hostSession != previousBoard?.hostSession ||
                        self.state.board?.account != previousBoard?.account {
                        self.boardOrderMoveRejected = false
                    }
                    self.avatarSnapshotChallenge = self.state.isConnected(now: self.now()) ? message.challenge : nil
                    if self.state.board?.account != previousBoard?.account {
                        self.avatarThumbnails.removeAll()
                    }
                    if self.state.board?.hostSession != previousBoard?.hostSession ||
                        self.state.board?.account != previousBoard?.account {
                        self.detailAvatarURLs.removeAll()
                    }
                    self.pruneAvatarThumbnails()
                }
                if accepted, message.type == .snapshot, self.state.isConnected(now: self.now()) {
                    self.supportsDetails = message.capabilities?.contains(RemoteMessage.detailsCapability) == true
                    self.supportsDetailContext = self.supportsDetails && message.capabilities?.contains(RemoteMessage.detailContextCapability) == true
                    self.supportsDetailPreviews = self.supportsDetails && message.capabilities?.contains(RemoteMessage.detailPreviewCapability) == true
                    self.supportsCachedDetails = self.supportsDetails && message.capabilities?.contains(RemoteMessage.cachedDetailsCapability) == true
                    self.supportsOriginUpdates = self.supportsDetails && message.capabilities?.contains(RemoteMessage.detailOriginsCapability) == true
                    if self.state.board?.hostSession != previousBoard?.hostSession || self.state.board?.account != previousBoard?.account {
                        self.resetDraftRegenerationConnection()
                    }
                    self.supportsDraftRegeneration = message.capabilities?.contains(RemoteMessage.draftRegenerationCapability) == true
                    self.supportsDraftRegenerationStyles = self.supportsDraftRegeneration
                        && message.capabilities?.contains(RemoteMessage.draftRegenerationStylesCapability) == true
                    self.supportsReviewerBatches = message.capabilities?.contains(RemoteMessage.reviewerBatchCapability) == true
                    await self.synchronizeDraftRegeneration()
                    if let board = self.state.board { self.detailState.update(board: board) }
                    if self.viewedCardID != nil, self.detailState.failure == .changed { self.isSynchronizingDetails = true }
                    self.error = self.recoveryUnavailable; self.connectionFailed = false; self.connectingUntil = .distantPast
                    await self.recoverLastCommand()
                    await self.refreshViewedDetails()
                    // A slow reply can consume most of its lease; renew before the next timer tick.
                    if self.state.needsRefresh(now: self.now()) { await self.refresh() }
                }
                if accepted, message.type == .result, let result = message.result, result.status != .running {
                    await self.finishAction(result)
                }
                if accepted, message.type == .accepted, let command = self.state.pending,
                   command.isDraftRegeneration, command.actionID == RemoteDraftRegenerationControl.applyID {
                    await self.refresh(fromGitLab: false)
                }
            }
            self.connection = connection; connection.start()
        } catch { self.error = true; connectionFailed = true }
    }
    func disconnect() {
        let old = connection; connection = nil; connectionRevision = UUID()
        old?.stop(); cancelApproval(); state.disconnected(); connectingUntil = .distantPast
        avatarSnapshotChallenge = nil
        boardOrderMoveRejected = false
        detailState.disconnect(); supportsDetails = false; supportsOriginUpdates = false
        supportsDetailContext = false; supportsDetailPreviews = false; supportsCachedDetails = false
        supportsReviewerBatches = false; reviewerAvatars = nil; pruneAvatarThumbnails()
        suspendDraftRegenerationReads()
        isSynchronizingDetails = false; isManuallyRefreshingContent = false
        contentRefresh?.cancel(); contentRefresh = nil
        shouldRecoverCommand = recovery != nil; receiptChallenge = nil; receiptRevision = nil
    }
    func refresh(force: Bool = false, fromGitLab: Bool = false) async {
        let requestState = state
        guard let connection, let challenge = requestState.beginRefresh(force: force || fromGitLab, now: now()) else { return }
        do { try await connection.send(.init(type: .hello, challenge: challenge,
            capabilities: [RemoteMessage.commentReviewCapability, RemoteMessage.mergeActionsCapability, RemoteMessage.detailsCapability,
                           RemoteMessage.detailOriginsCapability, RemoteMessage.mrControlsCapability, RemoteMessage.personalApprovalCapability,
                           RemoteMessage.commentOriginCapability, RemoteMessage.markReadyCapability, RemoteMessage.detailPreviewCapability,
                           RemoteMessage.draftRegenerationCapability, RemoteMessage.boardAvatarsCapability,
                           RemoteMessage.detailAvatarsCapability, RemoteMessage.boardOrderCapability,
                           RemoteMessage.reviewerEditingCapability, RemoteMessage.reviewerBatchCapability,
                           RemoteMessage.cardActionsCapability],
            refresh: fromGitLab, cachedAvatarURLs: Array((state.board?.avatarThumbnailURLs ?? [])
                .filter { avatarThumbnails[$0] != nil }.prefix(64)))) }
        catch {
            guard !Task.isCancelled, self.connection === connection, self.state === requestState else { return }
            if requestState.refreshFailed(challenge: challenge) {
                self.error = true; self.connectionFailed = true; self.isSynchronizingDetails = false
            }
        }
    }

    func moveBoardCard(_ move: RemoteBoardOrderMove) async {
        guard let connection, state.canAct(now: now()), let board = state.board else { return }
        guard board.permitsOrderMove(move) else {
            boardOrderMoveRejected = true
            return
        }
        let requestState = state
        guard let challenge = requestState.beginRefresh(force: true, now: now()) else { return }
        do {
            try await connection.send(.init(type: .boardOrderRequest, challenge: challenge, boardOrderMove: move))
        } catch {
            guard self.connection === connection, state === requestState else { return }
            if requestState.refreshFailed(challenge: challenge) {
                boardOrderMoveRejected = true
                await refresh()
            }
        }
    }

    private func receiveAvatarThumbnails(_ message: RemoteMessage) {
        guard let challenge = message.challenge, let board = state.board, let thumbnails = message.avatarThumbnails,
              thumbnails.count <= RemoteAvatarThumbnail.batchSize else { return }
        let urls: Set<URL>
        if challenge == avatarSnapshotChallenge {
            urls = Set(board.avatarThumbnailURLs)
        } else if let request = detailState.openRequest, request.id == challenge, request.matches(board),
                  detailState.pending == nil {
            urls = detailAvatarURLs
        } else if let reviewers = reviewerAvatars, reviewers.request.id == challenge, reviewers.request.matches(board) {
            urls = reviewers.urls
        } else { return }
        for thumbnail in thumbnails where urls.contains(thumbnail.url) &&
            !thumbnail.jpeg.isEmpty && thumbnail.jpeg.count <= RemoteAvatarThumbnail.maximumBytes {
            avatarThumbnails[thumbnail.url] = thumbnail.jpeg
        }
    }

    private func pruneAvatarThumbnails() {
        if let reviewers = reviewerAvatars, state.board.map(reviewers.request.matches) != true { reviewerAvatars = nil }
        let visible = detailAvatarURLs.union(state.board?.avatarThumbnailURLs ?? []).union(reviewerAvatars?.urls ?? [])
        avatarThumbnails = avatarThumbnails.filter { visible.contains($0.key) }
    }
    func refreshContent(fromGitLab: Bool = false) async {
        await refreshManually { model in
            model.prepareDetailsReload()
            await model.refresh(force: true, fromGitLab: fromGitLab)
        }
    }

    func refreshDetailsFromGitLab(card: RemoteCard) async {
        await refreshManually { model in
            model.detailRecoveryAttempts = 0
            model.issueRefreshCardID = card.id
            await model.requestDetails(card: card, force: true, fromGitLab: true)
        }
    }

    private func refreshManually(_ operation: @escaping @MainActor (RemotePhoneModel) async -> Void) async {
        if let contentRefresh { await contentRefresh.value; return }
        isManuallyRefreshingContent = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let revision = self.connectionRevision
            let deadline = ContinuousClock.now + .seconds(45)
            await operation(self)
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

    private func prepareDetailsReload() {
        needsDetailReload = viewedCardID != nil
        needsLiveDetailReload = false
        isSynchronizingDetails = viewedCardID != nil
        detailRecoveryAttempts = 0
        detailState.prepareToReload()
    }

    private func finishAction(_ result: RemoteCommandResult) async {
        shouldRecoverCommand = false
        if let command = recovery?.command, command.id == result.id,
           let kind = RemoteActionKind(rawValue: command.actionID), kind.isPersonalApproval {
            lastPersonalApproval = (result.id, kind)
        }
        if result.status == .completed, let command = recovery?.command,
           command.id == result.id, command.isCompletionAcknowledgement {
            state.acknowledgeResult()
        }
        if let command = recovery?.command, command.id == result.id, command.isDraftRegeneration,
           command.actionID != RemoteDraftRegenerationControl.applyID {
            await refresh(force: true)
            return
        }
        prepareDetailsReload()
        await refresh(force: true)
    }

    private func refreshViewedDetails() async {
        guard supportsDetails, let id = viewedCardID, let card = state.board?.cards.first(where: { $0.id == id }) else {
            isSynchronizingDetails = false; return
        }
        await requestDetails(card: card, force: needsDetailReload, fromGitLab: needsLiveDetailReload)
    }

    func requestDetails(card: RemoteCard, force: Bool = false, fromGitLab: Bool? = nil) async {
        guard supportsDetails, state.board?.cards.contains(where: { $0.id == card.id }) == true else { return }
        let opening = viewedCardID != card.id
        if opening {
            detailRecoveryAttempts = 0
            needsLiveDetailReload = false
            if issueRefreshCardID != card.id { issueRefreshCardID = nil }
        }
        viewedCardID = card.id
        // Older Macs only have the original live detail read. Keep it for opening Details.
        let live = fromGitLab ?? (needsLiveDetailReload || (opening && !supportsCachedDetails))
        if state.pending != nil || (state.isRefreshing(now: now()) && (needsDetailReload || isManuallyRefreshingContent)) {
            needsDetailReload = true; needsLiveDetailReload = needsLiveDetailReload || live
            isSynchronizingDetails = true; return
        }
        guard live || supportsCachedDetails else {
            needsDetailReload = false; isSynchronizingDetails = false; return
        }
        guard state.isConnected(now: now()), let board = state.board, let connection,
              force || detailState.openRequest == nil,
              let request = detailState.begin(card: card, board: board, now: now(), force: force,
                  presentationIndependent: supportsDetailContext, cachedOnly: live ? nil : true) else { return }
        needsDetailReload = false; needsLiveDetailReload = false; isSynchronizingDetails = false
        let revision = connectionRevision
        let refreshIssues = live && issueRefreshCardID == card.id
        if refreshIssues { issueRefreshCardID = nil }
        do { try await connection.send(.init(type: .detailRequest, detailRequest: request,
            cachedAvatarURLs: Array(avatarThumbnails.keys.prefix(64)), refreshDetailIssues: refreshIssues ? true : nil)) }
        catch {
            guard self.connection === connection, connectionRevision == revision, let current = state.board else { return }
            detailState.receive(.init(request: request, status: .unavailable), board: current)
        }
    }
    func cancelDetails() {
        let request = detailState.openRequest ?? detailState.pending
        detailState.disconnect()
        detailAvatarURLs.removeAll()
        pruneAvatarThumbnails()
        viewedCardID = nil; needsDetailReload = false; needsLiveDetailReload = false
        issueRefreshCardID = nil
        isSynchronizingDetails = false; detailRecoveryAttempts = 0
        guard supportsDetails, let request, let connection else { return }
        Task { try? await connection.send(.init(type: .cancelDetails, detailRequest: request)) }
    }
    func prepareApproval(card: RemoteCard, action: RemoteAction) -> UUID? {
        cancelApproval()
        guard connection != nil, !recoveryUnavailable, recovery == nil, action.kind.requiresApprovalConfirmation, card.head != nil,
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
    func perform(card: RemoteCard, action: RemoteAction, approvalID: UUID? = nil, argument: String? = nil,
                 onApprovalConfirmed: (() -> Void)? = nil) async {
        if action.kind.requiresApprovalConfirmation {
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
            onApprovalConfirmed?()
        }
        await submitCommand(card: card, action: action, argument: argument)
    }

    @discardableResult
    private func submitCommand(card: RemoteCard, action: RemoteAction, argument: String?) async -> RemoteCommandResult? {
        let requestState = state, revision = connectionRevision
        guard !recoveryUnavailable, recovery == nil, let pairing, let connection,
              let command = requestState.command(card: card, action: action, argument: argument, now: now()) else { return nil }
        let pending = RemoteCommandRecovery(pairingSession: pairing.sessionID, command: command.receiptIdentity)
        do { try saveRecovery(pending); recovery = pending }
        catch {
            self.error = true
            let result = RemoteCommandResult(id: command.id, status: .failed)
            requestState.recoverResult(result)
            return result
        }
        pendingActionPresentation = (command.id, card)
        defer {
            if pendingActionPresentation?.id == command.id, state.pending?.id != command.id {
                pendingActionPresentation = nil
            }
        }
        do {
            try await connection.send(.init(type: .command, command: command))
        } catch {
            guard self.connection === connection, state === requestState, connectionRevision == revision else { return nil }
            requestState.disconnected(); shouldRecoverCommand = true
            return requestState.result
        }
        while state === requestState && requestState.pending?.id == command.id {
            do { try await Task.sleep(for: .seconds(1)) } catch { return nil }
            requestState.checkCommandTimeout(now: now())
        }
        guard state === requestState, let result = requestState.result, result.id == command.id else { return nil }
        if result.status == .uncertain { shouldRecoverCommand = true }
        return result
    }
    func searchReviewers(card: RemoteCard, action: RemoteAction, query: String) async throws -> [ReviewerCandidate] {
        guard state.isConnected(now: now()), let board = state.board, let connection else { throw RemoteProtocolError.invalid }
        let request = RemoteReviewerSearch(board: board, card: card, action: action, query: query)
        guard request.matches(board) else { throw RemoteProtocolError.invalid }
        let revision = connectionRevision
        reviewerSearch = request
        reviewerResults = nil
        defer {
            if reviewerSearch == request { reviewerSearch = nil; reviewerResults = nil }
        }
        try await connection.send(.init(type: .reviewerSearch, cachedAvatarURLs: Array(avatarThumbnails.keys.prefix(64)),
            reviewerSearch: request))
        let deadline = ContinuousClock.now + .seconds(18)
        while ContinuousClock.now < deadline, revision == connectionRevision, reviewerSearch == request {
            try Task.checkCancellation()
            if let results = reviewerResults {
                guard let candidates = results.candidates else { throw RemoteProtocolError.invalid }
                return candidates
            }
            try await Task.sleep(for: .milliseconds(75))
        }
        throw RemoteProtocolError.invalid
    }

    func changeReviewers(_ changes: [ReviewerChange], card: RemoteCard, action: RemoteAction) async -> RemoteCommandResult.Status {
        let argument: String?
        if changes.count == 1 {
            argument = changes.first?.argument
        } else {
            guard supportsReviewerBatches else { return .changed }
            argument = ReviewerChange.Batch(changes)?.argument
        }
        guard let argument else { return .failed }
        guard let result = await submitCommand(card: card, action: action, argument: argument) else { return .changed }
        if result.status != .uncertain, state.result?.id == result.id { state.acknowledgeResult() }
        return result.status
    }

    func changeCard(_ change: RemoteCardChange, card: RemoteCard, inSheet: Bool = false) async -> RemoteCommandResult.Status {
        guard let action = card.actions.first(where: { $0.kind == .editCard }),
              let argument = change.argument,
              let result = await submitCommand(card: card, action: action, argument: argument) else { return .changed }
        if inSheet, result.status != .uncertain, state.result?.id == result.id { state.acknowledgeResult() }
        return result.status
    }

    // MARK: - Draft regeneration

    var draftRegenerationIsAvailable: Bool {
        supportsDraftRegeneration && state.board?.draftRegeneration != nil
            && !recoveryUnavailable && recovery == nil && state.canAct(now: now())
    }

    var draftRegenerationBatch: DraftRegenerationBatch? {
        guard supportsDraftRegeneration, let control = state.board?.draftRegeneration, var batch = control.batch else { return nil }
        if batch.id == draftRegenerationPreviewBatchID,
           batch.phase != .ready || control.previewToken == draftRegenerationPreviewToken {
            batch.proposals = draftRegenerationPreview
        }
        return batch
    }

    var draftRegenerationIsLoading: Bool {
        guard supportsDraftRegeneration, let control = state.board?.draftRegeneration, control.proposalCount > 0,
              let token = control.previewToken else { return false }
        return (control.batch?.id != draftRegenerationPreviewBatchID || token != draftRegenerationPreviewToken)
            && !draftRegenerationLoadFailed
    }

    var draftRegenerationMergeRequestCount: Int { state.board?.draftRegeneration?.mergeRequestCount ?? 0 }

    func draftRegenerationCount(for scope: DraftRegenerationScope) -> Int {
        guard supportsDraftRegeneration, let board = state.board, let control = board.draftRegeneration else { return 0 }
        switch scope {
        case .all: return control.count
        case .mergeRequest(let projectID, let iid):
            return regenerationDraftIDs(projectID: projectID, iid: iid, board: board).count
        case .draft(let projectID, let iid, let draftID):
            return regenerationDraftIDs(projectID: projectID, iid: iid, board: board).contains(draftID) ? 1 : 0
        }
    }

    private func regenerationDraftIDs(projectID: Int, iid: Int, board: RemoteBoard) -> Set<Int> {
        guard let card = board.cards.first(where: { $0.id == "mr:\(projectID):\(iid)" }),
              card.head != nil else { return [] }
        let grouped = Dictionary(grouping: card.drafts, by: \.id)
        return Set(grouped.compactMap { id, drafts in
            guard id > 0, drafts.count == 1,
                  drafts.first?.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
            return id
        })
    }

    func startDraftRegeneration(_ scope: DraftRegenerationScope, style: DraftRegenerationStyle?) async -> Bool {
        let count = draftRegenerationCount(for: scope)
        // A Mac that predates style presets would ignore the field, so never send one it did not announce.
        guard count > 0, style == nil || supportsDraftRegenerationStyles else { return false }
        return await performDraftRegeneration(.start(scope: scope, count: count, instructions: nil, style: style),
                                              kind: .startDraftRegeneration) == .completed
    }

    func applyDraftRegeneration(_ ids: Set<String>, batchID: UUID) async -> RemoteCommandResult.Status {
        guard let batch = draftRegenerationBatch, batch.id == batchID, batch.phase == .ready,
              !ids.isEmpty, ids.isSubset(of: Set(batch.proposals.compactMap { $0.replacement != nil && $0.issue == nil ? $0.id : nil }))
        else { return .changed }
        return await performDraftRegeneration(.apply(batchID: batchID, proposalIDs: ids.sorted()), kind: .applyDraftRegeneration)
    }

    func discardDraftRegeneration(_ batchID: UUID) async -> Bool {
        guard draftRegenerationBatch?.id == batchID else { return false }
        return await performDraftRegeneration(.discard(batchID: batchID), kind: .discardDraftRegeneration) == .completed
    }

    private func performDraftRegeneration(_ operation: RemoteDraftRegenerationOperation,
                                          kind: RemoteActionKind) async -> RemoteCommandResult.Status {
        guard draftRegenerationIsAvailable, let board = state.board, let card = board.draftRegeneration?.card,
              let action = card.actions.first(where: { $0.kind == kind }) else { return .changed }
        guard let argument = operation.argument else { return .limit }
        guard let result = await submitCommand(card: card, action: action, argument: argument) else { return .changed }
        guard state.board?.account == board.account, state.board?.hostSession == board.hostSession else { return .changed }
        if state.result?.id == result.id, result.status != .uncertain, result.status != .running {
            state.acknowledgeResult()
        }
        if result.status == .completed || result.status == .partial
            || (kind == .applyDraftRegeneration && result.status != .uncertain) {
            let deadline = ContinuousClock.now + .seconds(6)
            while state.board?.account == board.account, state.board?.hostSession == board.hostSession,
                  ContinuousClock.now < deadline, state.isRefreshing(now: now()) {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
        }
        return result.status
    }

    func reloadDraftRegeneration() async {
        resetDraftRegenerationPreview()
        if state.isConnected(now: now()) {
            await refresh(fromGitLab: false)
        } else if paired {
            reconnect()
        }
    }

    private func synchronizeDraftRegeneration() async {
        guard supportsDraftRegeneration, let board = state.board, let control = board.draftRegeneration,
              let batch = control.batch else {
            resetDraftRegenerationPreview()
            return
        }
        if batch.phase == .generating || batch.phase == .saving {
            resetDraftRegenerationPreview(keepingBatch: batch.id)
            if draftRegenerationPoll == nil {
                draftRegenerationPoll = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    guard let self else { return }
                    draftRegenerationPoll = nil
                    await refresh(fromGitLab: false)
                }
            }
            return
        }
        draftRegenerationPoll?.cancel(); draftRegenerationPoll = nil
        guard control.proposalCount > 0 else {
            resetDraftRegenerationPreview()
            return
        }
        guard let token = control.previewToken else {
            resetDraftRegenerationPreview()
            draftRegenerationLoadFailed = true
            return
        }
        if batch.id == draftRegenerationPreviewBatchID, token == draftRegenerationPreviewToken { return }
        guard (token != failedDraftRegenerationPreview?.previewToken || batch.id != failedDraftRegenerationPreview?.batchID),
              (token != draftRegenerationRead?.request.previewToken || batch.id != draftRegenerationRead?.request.batchID)
        else { return }
        resetDraftRegenerationPreview(keepingBatch: batch.id)
        let request = RemoteDraftRegenerationPageRequest(hostSession: board.hostSession, account: board.account,
            batchID: batch.id, previewToken: token, offset: 0)
        let read = DraftRegenerationRead(request: request)
        draftRegenerationRead = read
        await requestDraftRegenerationPage(read)
    }

    private func requestDraftRegenerationPage(_ read: DraftRegenerationRead) async {
        guard let connection, let active = draftRegenerationRead, active === read else { return }
        let challenge = UUID()
        read.challenge = challenge
        draftRegenerationReadTimeout?.cancel()
        draftRegenerationReadTimeout = Task { [weak self, weak read] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, let read, draftRegenerationRead === read, read.challenge == challenge else { return }
            failDraftRegenerationPreview()
        }
        do {
            try await connection.send(.init(type: .draftRegenerationRequest, challenge: challenge,
                draftRegenerationRequest: read.request))
        } catch {
            guard draftRegenerationRead === read, read.challenge == challenge else { return }
            failDraftRegenerationPreview()
        }
    }

    private func receiveDraftRegenerationPage(_ page: RemoteDraftRegenerationPage, challenge: UUID) async {
        guard supportsDraftRegeneration, let read = draftRegenerationRead, page.request == read.request,
              challenge == read.challenge, let board = state.board, let control = board.draftRegeneration,
              page.request.hostSession == board.hostSession, page.request.account == board.account,
              page.request.batchID == control.batch?.id, page.request.previewToken == control.previewToken else { return }
        draftRegenerationReadTimeout?.cancel()
        guard let bytes = page.data, page.totalBytes > read.bytes.count,
              page.totalBytes <= RemoteDraftRegenerationPage.maximumBytes,
              read.expectedBytes == nil || read.expectedBytes == page.totalBytes,
              bytes.count == min(RemoteDraftRegenerationPage.pageBytes, page.totalBytes - read.bytes.count) else {
            failDraftRegenerationPreview()
            return
        }
        read.expectedBytes = page.totalBytes
        read.bytes.append(bytes)
        if read.bytes.count == page.totalBytes {
            guard RemoteDraftRegenerationPage.token(read.bytes) == page.request.previewToken,
                  let proposals = try? JSONDecoder().decode([DraftRegenerationProposal].self, from: read.bytes),
                  proposals.count == control.proposalCount, Set(proposals.map(\.id)).count == proposals.count else {
                failDraftRegenerationPreview()
                return
            }
            draftRegenerationPreview = proposals
            draftRegenerationPreviewBatchID = page.request.batchID
            draftRegenerationPreviewToken = page.request.previewToken
            draftRegenerationRead = nil
            draftRegenerationLoadFailed = false
        } else {
            read.request = .init(hostSession: board.hostSession, account: board.account,
                batchID: page.request.batchID, previewToken: page.request.previewToken, offset: read.bytes.count)
            await requestDraftRegenerationPage(read)
        }
    }

    private func failDraftRegenerationPreview() {
        failedDraftRegenerationPreview = draftRegenerationRead?.request
        stopDraftRegenerationRead()
        draftRegenerationLoadFailed = true
    }

    private func resetDraftRegenerationPreview(keepingBatch batchID: UUID? = nil) {
        stopDraftRegenerationRead()
        if batchID == nil || batchID != draftRegenerationPreviewBatchID {
            draftRegenerationPreviewBatchID = nil
            draftRegenerationPreviewToken = nil
            draftRegenerationPreview = []
        }
        failedDraftRegenerationPreview = nil
        draftRegenerationLoadFailed = false
    }

    private func stopDraftRegenerationRead() {
        draftRegenerationReadTimeout?.cancel(); draftRegenerationReadTimeout = nil
        draftRegenerationRead = nil
    }

    private func suspendDraftRegenerationReads() {
        draftRegenerationPoll?.cancel(); draftRegenerationPoll = nil
        stopDraftRegenerationRead()
    }

    private func resetDraftRegenerationConnection() {
        supportsDraftRegeneration = false
        supportsDraftRegenerationStyles = false
        suspendDraftRegenerationReads()
        resetDraftRegenerationPreview()
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
