import Foundation
import Observation
import MergeTetherRemote

@MainActor @Observable final class RemoteHostController {
    private(set) var pairing: RemotePairing?
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
    private var connection: RemoteConnection?
    private var hostSession = UUID()
    private var account = ""
    private var accountRevision: UInt64?
    private var gate = RemoteCommandGate()

    init(monitor: TodoMonitorService,
         loadPairing: (@Sendable () async throws -> RemotePairing?)? = nil,
         savePairing: ((RemotePairing) throws -> Void)? = nil,
         removePairing: (() throws -> Void)? = nil,
         connectPairing: ((RemotePairing) -> Void)? = nil) {
        self.monitor = monitor
        let store = RemotePairingStore(service: (Bundle.main.bundleIdentifier ?? "MergeTether") + ".remote")
        self.store = store
        self.savePairing = savePairing ?? { try store.save($0) }
        self.removePairing = removePairing ?? { try store.remove() }
        self.connectPairing = connectPairing
        let load: @Sendable () async throws -> RemotePairing? = loadPairing ?? { try store.load() }
        loadStoredPairing(using: load)
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
            guard let url = URL(string: origin.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw RemoteProtocolError.invalid }
            let pair = try RemotePairing.generate(origin: url, access: invitation.trimmingCharacters(in: .whitespacesAndNewlines))
            try savePairing(pair)
            connection?.stop(); connection = nil
            pairing = pair; activatePairing(pair)
        } catch { failed = true }
    }
    func disable() {
        startupGeneration = UUID(); startupLoadTask?.cancel()
        do { try removePairing() } catch { failed = true; return }
        connection?.stop(); connection = nil; pairing = nil; connected = false
    }
    private func activatePairing(_ pair: RemotePairing) {
        if let connectPairing { connectPairing(pair); failed = false }
        else { start(pair) }
    }
    private func start(_ pair: RemotePairing) {
        do {
            hostSession = UUID(); gate = RemoteCommandGate()
            let connection = try RemoteConnection(pairing: pair, role: .host)
            connection.onStatus = { [weak self, weak connection] connected, fatal in
                self?.connected = connected; self?.failed = fatal
                if connected { Task { try? await connection?.send(.init(type: .hostReady)) } }
            }
            connection.onMessage = { [weak self] message in await self?.receive(message) }
            self.connection = connection; connection.start(); failed = false
        } catch { failed = true }
    }
    private func loadLocalOperatorSetup() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/MergeTether/remote-relay")
        guard let data = try? Data(contentsOf: folder.appending(path: "operator.json")),
              let values = try? JSONDecoder().decode([String: String].self, from: data),
              let origin = try? String(contentsOf: folder.appending(path: "origin.txt"), encoding: .utf8) else { return }
        self.origin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        invitation = values["RELAY_ACCESS_TOKEN"] ?? ""
    }
    private func receive(_ message: RemoteMessage) async {
        guard let active = connection else { return }
        switch message.type {
        case .hello:
            guard let challenge = message.challenge else { return }
            let fresh = await refreshSource(force: false, deadline: .now + .seconds(35))
            guard connection === active else { return }
            var board = snapshot()
            if !fresh { board.partial = true }
            do { try await active.send(.init(type: .snapshot, challenge: challenge, board: board)) }
            catch { failed = true; try? await active.send(.init(type: .unavailable)) }
        case .command:
            guard let command = message.command else { return }
            let fresh = await refreshSource(force: true, deadline: .now + .seconds(35))
            var board = snapshot()
            if !fresh { board.partial = true }
            guard connection === active else { return }
            var acceptanceSent = false
            let result = await gate.execute(command, board: board, accepted: {
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
            account = currentAccount; accountRevision = monitor.glab.accountRevision; hostSession = UUID(); gate = RemoteCommandGate()
        }
        return RemoteBoardAdapter.board(monitor: monitor, session: hostSession, account: account)
    }
    private func execute(_ card: RemoteCard, action: RemoteAction) async -> RemoteCommandResult.Status {
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
            await monitor.attention.retryReReview(item.id); return .completed
        default: return .changed
        }
    }
}
