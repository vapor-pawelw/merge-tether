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
    typealias DetailReader = @MainActor (GitLabMergeRequest, [GitLabDraftNote], GlabService, String?) async throws -> RemoteMRDetails
    private(set) var pairing: RemotePairing?
    let relayConfiguration: RemoteRelayConfiguration
    private(set) var relayMismatch = false
    var origin = ""
    var invitation = ""
    private(set) var failed = false
    private(set) var connected = false
    /// Set by the first authenticated (decrypted) phone message on the current socket.
    private(set) var phoneSeenAt: Date?

    enum PhoneLink: Equatable { case reconnecting, waitingForPhone, phoneConnected }
    /// `connected` only means the socket was opened; only a decrypted message proves the phone is reachable.
    var phoneLink: PhoneLink {
        guard connected else { return .reconnecting }
        return phoneSeenAt == nil ? .waitingForPhone : .phoneConnected
    }
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
    private var phoneSupportsPersonalApproval = false
    private var phoneSupportsReviewerEditing = false
    private var phoneSupportsReviewerBatches = false
    @ObservationIgnored private var reviewerSearchTask: Task<Void, Never>?
    private var phoneSupportsCommentOrigins = false
    private var phoneSupportsMarkReady = false
    private var phoneSupportsDraftRegeneration = false
    private var phoneSupportsBoardOrder = false
    private var phoneSupportsCardActions = false
    private static let boardCapabilities = [
        RemoteMessage.detailsCapability, RemoteMessage.detailContextCapability, RemoteMessage.detailOriginsCapability,
        RemoteMessage.mrControlsCapability, RemoteMessage.commentOriginCapability, RemoteMessage.markReadyCapability,
        RemoteMessage.detailPreviewCapability, RemoteMessage.cachedDetailsCapability, RemoteMessage.draftRegenerationCapability,
        RemoteMessage.boardOrderCapability, RemoteMessage.personalApprovalCapability, RemoteMessage.reviewerEditingCapability,
        RemoteMessage.reviewerBatchCapability, RemoteMessage.cardActionsCapability,
        RemoteMessage.draftRegenerationStylesCapability
    ]
    private let readAvatarThumbnail: @Sendable (URL) async -> Data?
    @ObservationIgnored private(set) var avatarTask: Task<Void, Never>?
    private var avatarChallenge: UUID?
    private var phoneSupportsDetailAvatars = false
    @ObservationIgnored private(set) var detailAvatarTask: Task<Void, Never>?
    private var detailAvatarRequest: UUID?
    private var regenerationPreview: DraftRegenerationPreview?

    private struct DraftRegenerationPreview {
        let batchID: UUID
        let proposals: [DraftRegenerationProposal]
        let bytes: Data?
        let token: String?

        init(batch: DraftRegenerationBatch) {
            batchID = batch.id
            proposals = batch.proposals
            if let encoded = try? JSONEncoder().encode(proposals), encoded.count <= RemoteDraftRegenerationPage.maximumBytes {
                bytes = encoded
                token = RemoteDraftRegenerationPage.token(encoded)
            } else {
                bytes = nil
                token = nil
            }
        }
    }
    private var originObserver: UUID?
    private var authorKindObserver: UUID?
    private var originSubscription: RemoteDetailOriginSubscription?
    @ObservationIgnored private var originUpdateTask: Task<Void, Never>?
    @ObservationIgnored private(set) var detailTask: Task<Void, Never>?
    private let detailReader: DetailReader
    private var activeDetailRequest: RemoteDetailRequest?
    private var lastDetailRead = Date.distantPast
    @ObservationIgnored private var recentDetails: [String: (digest: String, criteriaOverride: String?, readAt: Date, details: RemoteMRDetails)] = [:]
    @ObservationIgnored private var resolutionPreviews: [String: ManualDiscussionResolution.Prepared] = [:]

    init(monitor: TodoMonitorService,
         relayConfiguration: RemoteRelayConfiguration = .bundled(),
         loadPairing: (@Sendable () async throws -> RemotePairing?)? = nil,
         savePairing: ((RemotePairing) throws -> Void)? = nil,
         removePairing: (() throws -> Void)? = nil,
         connectPairing: ((RemotePairing) -> Void)? = nil,
         commandGate: RemoteCommandGate? = nil,
         now: @escaping () -> Date = Date.init,
         detailReader: @escaping DetailReader = { try await RemoteMRDetailLoader.load(source: $0, drafts: $1, glab: $2, criteriaOverride: $3) },
         readAvatarThumbnail: @escaping @Sendable (URL) async -> Data? = { await RemoteAvatarLoader.shared.thumbnail(for: $0) },
         makeConnection: @escaping (RemotePairing) throws -> any RemoteHostTransport = { try RemoteConnection(pairing: $0, role: .host) }) {
        self.monitor = monitor
        self.relayConfiguration = relayConfiguration
        origin = relayConfiguration.origin?.absoluteString ?? ""
        self.now = now
        self.detailReader = detailReader
        self.readAvatarThumbnail = readAvatarThumbnail
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
                    loadLocalOperatorSetup()
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
        avatarTask?.cancel(); avatarTask = nil; avatarChallenge = nil
        cancelDetailAvatars()
        phoneSupportsDetailAvatars = false
        hostSession = UUID()
        phoneSeenAt = nil
        resolutionPreviews.removeAll()
        phoneSupportsCommentReview = false
        phoneSupportsMergeActions = false
        phoneSupportsDetails = false
        phoneSupportsDetailPreviews = false
        phoneSupportsOriginUpdates = false
        phoneSupportsMRControls = false
        phoneSupportsPersonalApproval = false
        phoneSupportsReviewerEditing = false
        phoneSupportsReviewerBatches = false
        reviewerSearchTask?.cancel(); reviewerSearchTask = nil
        phoneSupportsCommentOrigins = false
        phoneSupportsMarkReady = false
        phoneSupportsDraftRegeneration = false
        phoneSupportsBoardOrder = false
        regenerationPreview = nil
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
        invitation = Self.localOperatorInvitation(for: relayConfiguration, in: folder) ?? ""
    }
    static func localOperatorInvitation(for configuration: RemoteRelayConfiguration, in folder: URL) -> String? {
        guard let configured = configuration.origin else { return nil }
        if let pairing = try? String(contentsOf: folder.appending(path: "pairing.txt"), encoding: .utf8) {
            let lines = pairing.components(separatedBy: "\n")
            if lines.count == 3, lines[2].isEmpty, !lines[1].isEmpty,
               RemoteRelayConfiguration(rawOrigin: lines[0]).origin == configured {
                return lines[1]
            }
        }

        func read(_ file: URL) -> [String: String]? {
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode([String: String].self, from: data)
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        let prefills = files.compactMap { file -> (file: URL, modified: Date)? in
            guard file.lastPathComponent.hasPrefix("prefill-"), file.pathExtension == "json",
                  let properties = try? file.resourceValues(forKeys: keys), properties.isRegularFile == true else { return nil }
            return (file, properties.contentModificationDate ?? .distantPast)
        }.sorted {
            ($0.modified, $0.file.lastPathComponent) > ($1.modified, $1.file.lastPathComponent)
        }
        for prefill in prefills {
            if let values = read(prefill.file), RemoteRelayConfiguration(rawOrigin: values["origin"]).origin == configured,
               let token = values["RELAY_ACCESS_TOKEN"], !token.isEmpty {
                return token
            }
        }

        guard let values = read(folder.appending(path: "operator.json")),
              let origin = try? String(contentsOf: folder.appending(path: "origin.txt"), encoding: .utf8),
              RemoteRelayConfiguration(rawOrigin: origin).origin == configured else { return nil }
        return values["RELAY_ACCESS_TOKEN"]
    }
    private func receive(_ message: RemoteMessage) async {
        guard let active = connection else { return }
        if phoneSeenAt == nil { phoneSeenAt = now() }
        switch message.type {
        case .hello:
            guard let challenge = message.challenge else { return }
            avatarTask?.cancel(); avatarTask = nil; avatarChallenge = challenge
            phoneSupportsCommentReview = message.capabilities?.contains(RemoteMessage.commentReviewCapability) == true
            phoneSupportsMergeActions = message.capabilities?.contains(RemoteMessage.mergeActionsCapability) == true
            phoneSupportsDetails = message.capabilities?.contains(RemoteMessage.detailsCapability) == true
            phoneSupportsDetailAvatars = phoneSupportsDetails && message.capabilities?.contains(RemoteMessage.detailAvatarsCapability) == true
            phoneSupportsDetailPreviews = phoneSupportsDetails && message.capabilities?.contains(RemoteMessage.detailPreviewCapability) == true
            phoneSupportsMRControls = message.capabilities?.contains(RemoteMessage.mrControlsCapability) == true
            phoneSupportsPersonalApproval = message.capabilities?.contains(RemoteMessage.personalApprovalCapability) == true
            phoneSupportsReviewerEditing = message.capabilities?.contains(RemoteMessage.reviewerEditingCapability) == true
            phoneSupportsReviewerBatches = message.capabilities?.contains(RemoteMessage.reviewerBatchCapability) == true
            phoneSupportsMarkReady = message.capabilities?.contains(RemoteMessage.markReadyCapability) == true
            phoneSupportsDraftRegeneration = message.capabilities?.contains(RemoteMessage.draftRegenerationCapability) == true
            phoneSupportsBoardOrder = message.capabilities?.contains(RemoteMessage.boardOrderCapability) == true
            phoneSupportsCardActions = message.capabilities?.contains(RemoteMessage.cardActionsCapability) == true
            phoneSupportsCommentOrigins = phoneSupportsDetails && message.capabilities?.contains(RemoteMessage.commentOriginCapability) == true
            phoneSupportsOriginUpdates = phoneSupportsDetails && message.capabilities?.contains(RemoteMessage.detailOriginsCapability) == true
            if !phoneSupportsOriginUpdates { clearOriginSubscription() }
            let fresh: Bool
            if message.refresh == true {
                monitor.markBoardIssueRefresh()
                fresh = await refreshSource(deadline: .now + .seconds(35))
            } else {
                let settled = await RemoteRefreshBarrier.refresh(deadline: .now + .seconds(4), isRefreshing: {
                    self.monitor.isLoading || self.monitor.attention.isLoading || self.monitor.authoredMergeRequests.isLoading
                }, refresh: {}, validate: { true })
                fresh = settled && monitor.lastRefresh != nil
            }
            guard connection === active else { return }
            var board = snapshot()
            if !fresh { board.partial = true }
            do { try await active.send(.init(type: .snapshot, challenge: challenge, board: board,
                capabilities: Self.boardCapabilities).fittingIssueTags()) }
            catch { failed = true; try? await active.send(.init(type: .unavailable)); return }
            if message.capabilities?.contains(RemoteMessage.boardAvatarsCapability) == true {
                guard avatarChallenge == challenge else { return }
                avatarTask = deliverAvatarThumbnails(board.avatarThumbnailURLs, challenge: challenge, session: board.hostSession,
                    excluding: message.cachedAvatarURLs ?? [], over: active) { $0.avatarChallenge == challenge }
            }
        case .boardOrderRequest:
            guard phoneSupportsBoardOrder, let challenge = message.challenge, let move = message.boardOrderMove else { return }
            var board = snapshot()
            if monitor.lastRefresh == nil { board.partial = true }
            let applied = board.permitsOrderMove(move) && applyBoardOrderMove(move)
            if applied { board = snapshot() }
            do { try await active.send(.init(type: .snapshot, challenge: challenge, board: board,
                capabilities: Self.boardCapabilities, boardOrderApplied: applied).fittingIssueTags()) }
            catch { failed = true; try? await active.send(.init(type: .unavailable)) }
        case .receipt:
            guard let command = message.command, let challenge = message.challenge, let pairing else { return }
            let result = gate.receipt(for: command, account: snapshot().account, pairingSession: pairing.sessionID)
            try? await active.send(.init(type: .receiptResult, challenge: challenge, result: result))
        case .detailRequest:
            guard phoneSupportsDetails, let request = message.detailRequest else { return }
            beginDetails(request, cachedAvatarURLs: message.cachedAvatarURLs ?? [],
                refreshIssueAssessment: message.refreshDetailIssues == true, connection: active)
        case .cancelDetails:
            if message.detailRequest?.id == detailAvatarRequest { cancelDetailAvatars() }
            if message.detailRequest == originSubscription?.request { clearOriginSubscription() }
            if message.detailRequest == activeDetailRequest {
                detailTask?.cancel(); detailTask = nil; activeDetailRequest = nil
            }
        case .reviewerSearch:
            guard phoneSupportsReviewerEditing, let request = message.reviewerSearch else { return }
            reviewerSearchTask?.cancel()
            reviewerSearchTask = Task { [weak self, weak active] in
                guard let self, let active else { return }
                await searchReviewers(request, cachedAvatarURLs: message.cachedAvatarURLs ?? [], connection: active)
            }
        case .draftRegenerationRequest:
            guard phoneSupportsDraftRegeneration, let request = message.draftRegenerationRequest,
                  let challenge = message.challenge else { return }
            let page = draftRegenerationPage(for: request)
            do { try await active.send(.init(type: .draftRegenerationPage, challenge: challenge, draftRegenerationPage: page)) }
            catch { return }
        case .command:
            guard let command = message.command, let pairing else { return }
            // Inbox updates validate their local receipt. Draft regeneration and suggestion decisions validate their own context.
            let handlesInboxUpdate = command.isCompletionAcknowledgement
                || (command.cardID.hasPrefix("completion:") && command.actionID == "restore")
            let cardChange = command.isCardChange ? RemoteCardChange(argument: command.argument) : nil
            let refreshesItself: Bool = switch cardChange {
            case .pin, .refresh: true
            default: false
            }
            let fresh = if handlesInboxUpdate || command.isFeedbackSuggestionDecision || command.isDraftRegeneration || refreshesItself { true } else {
                await refreshSource(deadline: .now + .seconds(35))
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
                      current.commandCards.contains(where: { $0.hasSameActionContext(as: card) && $0.actions.contains(action) }) else { return .changed }
                return await self.execute(card, action: action, argument: command.argument)
            }
            try? await active.send(.init(type: .result, result: result))
        default: break
        }
    }

    private func searchReviewers(_ search: RemoteReviewerSearch, cachedAvatarURLs: [URL], connection active: any RemoteHostTransport) async {
        let board = snapshot()
        let revision = monitor.glab.accountRevision
        var candidates: [ReviewerCandidate]?
        if search.matches(board), let request = reviewerEditingRequest(cardID: search.cardID) {
            candidates = try? await monitor.searchReviewers(of: request, query: search.query, accountRevision: revision)
        }
        guard !Task.isCancelled, connection === active, revision == monitor.glab.accountRevision else { return }
        if !search.matches(snapshot()) { candidates = nil }
        let results = RemoteReviewerResults(id: search.id, candidates: candidates)
        do { try await active.send(.init(type: .reviewerResults, reviewerResults: results)) }
        catch { return }
        guard !Task.isCancelled, phoneSupportsDetailAvatars,
              let thumbnails = deliverAvatarThumbnails(results.avatarThumbnailURLs, challenge: search.id,
                  session: search.hostSession, excluding: cachedAvatarURLs, over: active,
                  isCurrent: { search.matches($0.snapshot()) }) else { return }
        await withTaskCancellationHandler { await thumbnails.value } onCancel: { thumbnails.cancel() }
    }

    private func reviewerEditingRequest(cardID: String) -> GitLabMergeRequest? {
        monitor.boardSnapshot.own.first { "mr:\($0.id.projectID):\($0.id.iid)" == cardID }?.displayRequest
    }
    private func deliverAvatarThumbnails(_ candidates: [URL], challenge: UUID, session: UUID, excluding cached: [URL],
                                         over active: any RemoteHostTransport,
                                         isCurrent: @escaping @MainActor (RemoteHostController) -> Bool) -> Task<Void, Never>? {
        guard connection === active, hostSession == session,
              accountRevision == monitor.glab.accountRevision,
              let host = monitor.glab.resolvedHost, let gitLab = URLComponents(string: "https://\(host)") else { return nil }
        let revision = monitor.glab.accountRevision
        let cached = Set(cached)
        let urls = candidates.filter { url in
            guard let hostname = url.host?.lowercased(), url.user == nil, url.password == nil, !cached.contains(url)
            else { return false }
            let port = url.port ?? 443
            let gitLabAvatar = hostname == gitLab.host?.lowercased() && port == (gitLab.port ?? 443)
            let gravatar = ["gravatar.com", "www.gravatar.com", "secure.gravatar.com"].contains(hostname)
                && port == 443 && url.path.hasPrefix("/avatar/")
            return gitLabAvatar || gravatar
        }
        guard !urls.isEmpty else { return nil }
        return Task { [weak self, weak active, readAvatarThumbnail] in
            for start in stride(from: 0, to: urls.count, by: RemoteAvatarThumbnail.batchSize) {
                guard !Task.isCancelled else { return }
                let batch = urls.dropFirst(start).prefix(RemoteAvatarThumbnail.batchSize)
                let thumbnails = await withTaskGroup(of: RemoteAvatarThumbnail?.self) { group in
                    for url in batch {
                        group.addTask {
                            guard let jpeg = await readAvatarThumbnail(url), !jpeg.isEmpty,
                                  jpeg.count <= RemoteAvatarThumbnail.maximumBytes else { return nil }
                            return .init(url: url, jpeg: jpeg)
                        }
                    }
                    var thumbnails: [RemoteAvatarThumbnail] = []
                    for await thumbnail in group {
                        if let thumbnail { thumbnails.append(thumbnail) }
                    }
                    return thumbnails
                }
                guard !Task.isCancelled, let self, let active, connection === active,
                      isCurrent(self), hostSession == session,
                      monitor.glab.accountRevision == revision else { return }
                guard !thumbnails.isEmpty else { continue }
                do { try await active.send(.init(type: .avatarThumbnails, challenge: challenge, avatarThumbnails: thumbnails)) }
                catch { return }
            }
        }
    }

    private func cancelDetailAvatars() {
        detailAvatarTask?.cancel()
        detailAvatarTask = nil
        detailAvatarRequest = nil
    }

    private func beginDetails(_ request: RemoteDetailRequest, cachedAvatarURLs: [URL], refreshIssueAssessment: Bool,
                              connection active: any RemoteHostTransport) {
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
        cancelDetailAvatars()
        clearOriginSubscription()
        let cachedOnly = request.cachedOnly == true
        if refreshIssueAssessment, !cachedOnly,
           let host = monitor.glab.resolvedHost, let username = monitor.glab.currentUsername {
            monitor.enqueueIssueMetadataRefresh(projectID: source.projectID, iid: source.iid, host: host, username: username)
        } else {
            monitor.requestIssueAssessment(for: source)
        }
        let nextRead = lastDetailRead.addingTimeInterval(1)
        let digest = card.detailContextDigest
        detailTask?.cancel(); activeDetailRequest = request
        let revision = monitor.glab.accountRevision
        let subscription = phoneSupportsOriginUpdates && !cachedOnly
            ? RemoteDetailOriginSubscription(request: request, source: source, accountRevision: revision) : nil
        originSubscription = subscription
        detailTask = Task { [weak self, weak active] in
            guard let self, let active else { return }
            defer {
                if activeDetailRequest == request { activeDetailRequest = nil; detailTask = nil }
            }
            let response: RemoteDetailResponse
            let criteriaOverride = monitor.settings.automation.aiCommentCriteriaOverride
            do {
                if cachedOnly {
                    guard let username = monitor.glab.currentUsername else { throw RemoteMRDetailLoader.ReadError.changed }
                    let details = await cachedDetails(request, source: source, row: row, username: username,
                        digest: digest, checkedAt: board.updatedAt ?? now())
                    response = .init(request: request, status: .current, details: details)
                } else {
                    if phoneSupportsDetailPreviews, let username = monitor.glab.currentUsername {
                        let details = await cachedDetails(request, source: source, row: row, username: username,
                            digest: digest, checkedAt: board.updatedAt ?? now())
                        let preview = RemoteDetailResponse(request: request, status: .current, details: details, isPreview: true)
                        let bounded = await Task.detached(priority: .userInitiated) { preview.bounded() }.value
                        guard !Task.isCancelled, phoneSupportsDetails, connection === active,
                              self.pairing?.sessionID == pairingSession, monitor.glab.accountRevision == revision,
                              activeDetailRequest == request else { return }
                        if phoneSupportsDetailPreviews, request.matches(snapshot()) {
                            try? await active.send(.init(type: .details, detailResponse: bounded))
                        }
                    }
                    let delay = nextRead.timeIntervalSince(now())
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    guard !Task.isCancelled, phoneSupportsDetails, connection === active,
                          self.pairing?.sessionID == pairingSession, monitor.glab.accountRevision == revision,
                          activeDetailRequest == request else { return }
                    guard request.matches(snapshot()) else { throw RemoteMRDetailLoader.ReadError.changed }
                    lastDetailRead = now()
                    var details = try await detailReader(source, row.evidenceMatchesCatalogContext ? row.item.drafts : [],
                        monitor.glab, criteriaOverride)
                    let usage = try? await AssistantUsageStore.shared.snapshot()
                    try Task.checkCancellation()
                    RemoteMRDetailSupplement.append(to: &details, row: row, monitor: monitor, usage: usage)
                    response = .init(request: request, status: .current, details: details)
                }
            } catch RemoteMRDetailLoader.ReadError.changed { response = .init(request: request, status: .changed) }
            catch { response = .init(request: request, status: .unavailable) }
            let bounded = await Task.detached(priority: .utility) { response.bounded() }.value
            guard !Task.isCancelled, phoneSupportsDetails, connection === active, self.pairing?.sessionID == pairingSession,
                  monitor.glab.accountRevision == revision, activeDetailRequest == request else { return }
            var checked = bounded
            if !request.matches(snapshot()) || monitor.settings.automation.aiCommentCriteriaOverride != criteriaOverride {
                checked = .init(request: request, status: .changed)
            }
            if !cachedOnly, checked.status == .current, let digest, let details = checked.details {
                recentDetails[request.cardID] = (digest, criteriaOverride, Date(), details)
                if recentDetails.count > 16, let oldest = recentDetails.min(by: { $0.value.readAt < $1.value.readAt })?.key {
                    recentDetails.removeValue(forKey: oldest)
                }
            }
            do {
                try await active.send(.init(type: .details, detailResponse: checked))
                guard !Task.isCancelled, phoneSupportsDetails, connection === active,
                      self.pairing?.sessionID == pairingSession, monitor.glab.accountRevision == revision,
                      activeDetailRequest == request, request.matches(snapshot()) else { return }
                if phoneSupportsDetailAvatars, checked.status == .current, let delivered = checked.details {
                    detailAvatarRequest = request.id
                    detailAvatarTask = deliverAvatarThumbnails(delivered.avatarThumbnailURLs, challenge: request.id,
                        session: request.hostSession, excluding: cachedAvatarURLs, over: active) { $0.detailAvatarRequest == request.id }
                }
                if !cachedOnly, checked.status == .current, let details = response.details {
                    if let subscription, originSubscription === subscription, let delivered = checked.details {
                        subscription.delivered(full: details, rendered: delivered)
                        flushOriginUpdates()
                    }
                    RemoteMRDetailSupplement.scheduleDisplayOrigins(in: details, request: source, monitor: monitor, accountRevision: revision)
                }
            } catch {}
        }
    }

    private func cachedDetails(_ request: RemoteDetailRequest, source: GitLabMergeRequest, row: MergeRequestBoardSnapshot.Row,
                               username: String, digest: String?, checkedAt: Date) async -> RemoteMRDetails {
        let criteriaOverride = monitor.settings.automation.aiCommentCriteriaOverride
        let cached = recentDetails[request.cardID].flatMap { $0.digest == digest && $0.criteriaOverride == criteriaOverride ? $0 : nil }
        let discussionRead = monitor.glab.cachedDiscussions(projectID: source.projectID, iid: source.iid)
        let newerDiscussions = discussionRead.map { $0.readAt > (cached?.readAt ?? .distantPast) } ?? false
        if let cached, !newerDiscussions, checkedAt <= cached.readAt {
            var details = cached.details
            details.issues = monitor.issueTags(for: source)
            return details
        }
        let item = row.evidenceMatchesCatalogContext ? row.item : row.displayItem
        var details = await Task.detached(priority: .userInitiated) {
            RemoteMRDetailLoader.project(request: source, progress: item.approvalProgress, rules: nil, reviewers: nil,
                discussions: newerDiscussions ? discussionRead?.discussions : nil, drafts: item.drafts, username: username,
                checkedAt: max(checkedAt, discussionRead?.readAt ?? .distantPast))
        }.value
        if let cached, !newerDiscussions {
            details.threads = cached.details.threads
            details.discussionFingerprint = cached.details.discussionFingerprint
            details.activeDiscussionFingerprint = cached.details.activeDiscussionFingerprint
            details.draftContexts = cached.details.draftContexts
            details.proposedSolutionDraftIDs = cached.details.proposedSolutionDraftIDs
            details.approvals = cached.details.approvals ?? details.approvals
        }
        RemoteMRDetailSupplement.append(to: &details, row: row, monitor: monitor, usage: nil)
        details.usage = cached?.details.usage
        details.approvals?.rules = cached?.details.approvals?.rules
        return details
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
    private func refreshSource(deadline: ContinuousClock.Instant) async -> Bool {
        await RemoteRefreshBarrier.refresh(deadline: deadline, isRefreshing: {
            self.monitor.isLoading || self.monitor.attention.isLoading || self.monitor.authoredMergeRequests.isLoading
        }, refresh: { await self.monitor.refreshNow() }, validate: {
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
            regenerationPreview = nil
        }
        var board = RemoteBoardAdapter.board(monitor: monitor, session: hostSession, account: account,
            includesBoardOrder: phoneSupportsBoardOrder, includesCardActions: phoneSupportsCardActions)
        if phoneSupportsCardActions {
            let preferred = monitor.settings.conversationDestination
            let available = AssistantContextLauncher.availableDestinations()
            let ordered = available.filter { $0 == preferred } + available.filter { $0 != preferred }
            board.cardAssistants = ordered.compactMap { RemoteCardAssistant(rawValue: $0.rawValue) }
        }
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
        if phoneSupportsDraftRegeneration {
            board.draftRegeneration = draftRegenerationControl(isPartial: board.partial)
        }
        return board.forClient(supportsCommentReview: phoneSupportsCommentReview, supportsMergeActions: phoneSupportsMergeActions,
            supportsMRControls: phoneSupportsMRControls, supportsCommentOrigins: phoneSupportsCommentOrigins,
            supportsMarkReady: phoneSupportsMarkReady, supportsDraftRegeneration: phoneSupportsDraftRegeneration,
            supportsPersonalApproval: phoneSupportsPersonalApproval, supportsReviewerEditing: phoneSupportsReviewerEditing,
            supportsCardActions: phoneSupportsCardActions)
    }

    private func applyBoardOrderMove(_ move: RemoteBoardOrderMove) -> Bool {
        let targets = monitor.boardSnapshot.manualOrderEntries.map(\.target)
        guard let source = targets.first(where: { RemoteBoardAdapter.boardOrderCardID($0) == move.source.cardID }),
              let destination = targets.first(where: { RemoteBoardAdapter.boardOrderCardID($0) == move.destinationID }) else {
            return false
        }
        return monitor.moveBoardCard(source, to: destination, accountRevision: monitor.glab.accountRevision)
    }

    private func draftRegenerationControl(isPartial: Bool) -> RemoteDraftRegenerationControl? {
        let coordinator = monitor.draftRegeneration
        let batch = coordinator.batch
        let count = coordinator.count(for: .all)
        guard coordinator.isAvailable || batch != nil else { return nil }
        var actions: [RemoteAction] = []
        if let batch {
            if (batch.phase == .ready || batch.phase == .finished), !batch.proposals.isEmpty {
                if regenerationPreview?.batchID != batch.id || regenerationPreview?.proposals != batch.proposals {
                    regenerationPreview = DraftRegenerationPreview(batch: batch)
                }
            } else {
                regenerationPreview = nil
            }
            if !isPartial {
                if batch.phase == .ready, batch.proposals.contains(where: { $0.replacement != nil && $0.issue == nil }),
                   let token = regenerationPreview?.token {
                    actions.append(.init(id: RemoteDraftRegenerationControl.applyID, kind: .applyDraftRegeneration, token: token))
                }
                if batch.phase != .saving {
                    actions.append(.init(id: RemoteDraftRegenerationControl.discardID, kind: .discardDraftRegeneration,
                        token: batch.id.uuidString))
                }
            }
        } else {
            regenerationPreview = nil
            if !isPartial, coordinator.isAvailable, count > 0, let token = coordinator.scopeToken(for: .all) {
                actions.append(.init(id: RemoteDraftRegenerationControl.startID, kind: .startDraftRegeneration, token: token))
            }
        }
        return RemoteDraftRegenerationControl(
            card: .init(id: RemoteDraftRegenerationControl.cardID, title: "", project: "", url: nil, actions: actions),
            count: count, batch: batch.map {
                .init(id: $0.id, scope: $0.scope, total: $0.total, completed: $0.completed, phase: $0.phase,
                      savingTotal: $0.savingTotal, savingCompleted: $0.savingCompleted)
            }, previewToken: regenerationPreview?.token, proposalCount: batch?.proposals.count ?? 0,
            mergeRequestCount: coordinator.mergeRequestCount)
    }

    private func draftRegenerationPage(for request: RemoteDraftRegenerationPageRequest) -> RemoteDraftRegenerationPage {
        let currentAccount = "\(monitor.glab.currentUsername ?? "")@\(monitor.glab.resolvedHost ?? "")"
        guard request.hostSession == hostSession, request.account == account, account == currentAccount,
              accountRevision == monitor.glab.accountRevision, let batch = monitor.draftRegeneration.batch,
              batch.id == request.batchID, batch.phase == .ready || batch.phase == .finished,
              let preview = regenerationPreview, preview.batchID == batch.id, preview.proposals == batch.proposals,
              preview.token == request.previewToken, let bytes = preview.bytes,
              (0..<bytes.count).contains(request.offset),
              request.offset.isMultiple(of: RemoteDraftRegenerationPage.pageBytes) else {
            return .init(request: request)
        }
        let end = min(request.offset + RemoteDraftRegenerationPage.pageBytes, bytes.count)
        return .init(request: request, data: bytes.subdata(in: request.offset..<end), totalBytes: bytes.count)
    }

    private func executeDraftRegeneration(_ action: RemoteAction, argument: String?) async -> RemoteCommandResult.Status {
        guard phoneSupportsDraftRegeneration, let operation = RemoteDraftRegenerationOperation(argument: argument) else { return .changed }
        let coordinator = monitor.draftRegeneration
        switch (action.kind, operation) {
        case (.startDraftRegeneration, .start(let scope, let count, let instructions, let style)):
            // Free-form text from the phone would become assistant instructions; only Mac-defined styles are accepted.
            guard instructions == nil, count > 0, count == coordinator.count(for: scope),
                  coordinator.scopeToken(for: .all) == action.token,
                  let scopeToken = coordinator.scopeToken(for: scope) else { return .changed }
            return coordinator.startRemote(scope, instructions: nil, style: style, expectedToken: scopeToken)
                ? .completed : .changed
        case (.applyDraftRegeneration, .apply(let batchID, let proposalIDs)):
            let ids = Set(proposalIDs)
            guard ids.count == proposalIDs.count, !ids.isEmpty, let batch = coordinator.batch,
                  batch.id == batchID, batch.phase == .ready, regenerationPreview?.token == action.token,
                  ids.isSubset(of: Set(batch.proposals.compactMap { $0.replacement != nil && $0.issue == nil ? $0.id : nil }))
            else { return .changed }
            return await coordinator.apply(ids, batchID: batchID)
        case (.discardDraftRegeneration, .discard(let batchID)):
            guard batchID.uuidString == action.token else { return .changed }
            return coordinator.discard(batchID) ? .completed : .changed
        default: return .changed
        }
    }

    private func execute(_ card: RemoteCard, action: RemoteAction, argument: String? = nil) async -> RemoteCommandResult.Status {
        if action.kind == .editCard {
            guard phoneSupportsCardActions, let change = RemoteCardChange(argument: argument),
                  let context = RemoteCardActionContext(card: card, board: monitor.boardSnapshot, monitor: monitor)
            else { return .changed }
            return await context.execute(change)
        }
        if card.id == RemoteDraftRegenerationControl.cardID {
            return await executeDraftRegeneration(action, argument: argument)
        }
        if card.id.hasPrefix("completion:") {
            let handled = RemoteBoardAdapter.acknowledgeCompletion(card, action: action, monitor: monitor, account: account)
                || RemoteBoardAdapter.handleHiddenReviewNotification(card, action: action, monitor: monitor, account: account)
            return handled ? .completed : .changed
        }
        if action.id.hasPrefix("intent:"), let id = UUID(uuidString: String(action.id.dropFirst(7))) {
            guard let intent = monitor.currentMRTodoIntents.first(where: { $0.id == id }) else { return .changed }
            let consent = intent.kind == .review ? monitor.manualReviewConsent(for: monitor.reviewRequest(for: intent)) : nil
            await monitor.runMRTodoIntent(id: id, confirmedReview: consent)
            return monitor.currentMRTodoIntents.first(where: { $0.id == id })?.state == .failed ? .failed : .completed
        }
        if action.kind == .retryJob, let id = UUID(uuidString: String(action.id.dropFirst(4))) {
            switch await monitor.retryAssistantJob(id) {
            case .queued, .obsolete: return .completed
            case .unavailable: return .changed
            case .failed: return .failed
            }
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
        guard let row = (board.own + board.reviewed).first(where: { "mr:\($0.id.projectID):\($0.id.iid)" == card.id }),
              RemoteBoardAdapter.card(row.item, account: account).drafts == card.drafts,
              row.item.mergeRequest?.sha == card.head else { return .changed }
        let item = row.item
        if action.kind == .setCommentOrigin {
            guard phoneSupportsCommentOrigins, let request = RemoteCommentOriginRequest(argument: argument) else { return .changed }
            return await executeCommentOrigin(request, item: item)
        }
        if RemoteActionKind.mrControls.contains(action.kind) {
            guard phoneSupportsMRControls else { return .changed }
            return await executeControl(action, item: item, row: row)
        }
        if action.kind == .editReviewers {
            guard phoneSupportsReviewerEditing,
                  let request = reviewerEditingRequest(cardID: card.id) else { return .changed }
            let changes: [ReviewerChange]
            if let single = ReviewerChange(argument: argument) {
                changes = [single]
            } else if phoneSupportsReviewerBatches, let batch = ReviewerChange.Batch(argument: argument) {
                changes = batch.changes
            } else { return .changed }
            recentDetails[card.id] = nil
            let result = await monitor.changeReviewers(changes, of: request, accountRevision: monitor.glab.accountRevision)
            recentDetails[card.id] = nil
            return result
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
        case .personalApprove, .removeApproval:
            guard phoneSupportsPersonalApproval, let request = item.mergeRequest else { return .changed }
            let change: PersonalMRApproval = action.kind == .personalApprove ? .approve : .remove
            switch await monitor.changePersonalApproval(change, for: request, accountRevision: monitor.glab.accountRevision) {
            case .completed: return .completed
            case .changed: return .changed
            case .failed: return .failed
            case .uncertain: return .uncertain
            }
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
            guard let retry = MRVerificationRetry(rawValue: action.id) else { return .changed }
            let followUp: MRHumanAction.FailedFollowUp? = if retry == .authorFeedback {
                RemoteBoardAdapter.failedFollowUp(in: row, monitor: monitor,
                    presentation: .init(row: row, monitor: monitor, allowsRemoval: !item.isAuthored))
            } else { nil }
            guard retry != .authorFeedback || !row.hasFollowUpInProgress,
                  retry.isAvailable(for: item, failedFollowUp: followUp) else { return .changed }
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
            return await monitor.runReview(for: item, confirmed: monitor.manualReviewConsent(for: item)) ? .completed : .failed
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
