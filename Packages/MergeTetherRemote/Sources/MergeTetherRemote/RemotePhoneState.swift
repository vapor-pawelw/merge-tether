import Foundation
import Observation

@MainActor @Observable public final class RemotePhoneState {
    public private(set) var board: RemoteBoard?
    public private(set) var pending: RemoteCommand?
    public private(set) var result: RemoteCommandResult?
    @ObservationIgnored public var onResultAcknowledgement: (@MainActor (RemoteCommandResult) throws -> Void)?
    private var expected: UUID?
    private var pendingUntil: Date = .distantPast
    private var challengeUntil: Date = .distantPast
    private var validUntil: Date = .distantPast
    private var connectedUntil: Date = .distantPast
    public init() {}
    public func beginRefresh(force: Bool = false, now: Date = Date()) -> UUID? {
        guard force || expected == nil || now >= challengeUntil else { return nil }
        if force { validUntil = .distantPast }
        return challenge(now: now)
    }
    public func checkCommandTimeout(now: Date = Date()) {
        if pending != nil && now >= pendingUntil { disconnected() }
    }
    public func challenge(now: Date = Date()) -> UUID {
        let keepConnectionVisible = expected == nil && isConnected(now: now)
        let value = UUID(); expected = value; challengeUntil = now.addingTimeInterval(45)
        // The response deadline may retain the status, never permission to write.
        if keepConnectionVisible { connectedUntil = challengeUntil }
        return value
    }
    public func receive(_ message: RemoteMessage, now: Date = Date()) {
        switch message.type {
        case .snapshot:
            guard let board = message.board, let expected, message.challenge == expected else { return }
            self.board = board
            self.expected = nil
            validUntil = challengeUntil
            connectedUntil = challengeUntil
        case .accepted:
            guard message.result?.id == pending?.id, pending != nil else { return }
            pendingUntil = now.addingTimeInterval(120)
        case .result:
            guard let result = message.result, result.id == pending?.id else { return }
            self.result = result
            if result.status != .running { pending = nil }
        default: break
        }
    }
    public func disconnected() {
        refreshFailed()
        if let pending { result = .init(id: pending.id, status: .uncertain); self.pending = nil }
    }
    public func isConnected(now: Date = Date()) -> Bool { now < connectedUntil }
    public func isRefreshing(now: Date = Date()) -> Bool { expected != nil && now < challengeUntil }
    public func needsRefresh(now: Date = Date()) -> Bool {
        expected == nil && now >= validUntil.addingTimeInterval(-20)
    }
    @discardableResult public func refreshFailed(challenge: UUID? = nil) -> Bool {
        if let challenge, expected != challenge { return false }
        expected = nil; validUntil = .distantPast; connectedUntil = .distantPast
        return true
    }
    public func canAct(now: Date = Date()) -> Bool {
        now < validUntil && board?.partial == false && pending == nil && result == nil
    }
    public func command(card: RemoteCard, action: RemoteAction, now: Date = Date()) -> RemoteCommand? {
        guard canAct(now: now), let board,
              board.cards.contains(where: { $0 == card && $0.actions.contains(action) }) else { return nil }
        let command = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: card.id, actionID: action.id, token: action.token)
        pending = command; pendingUntil = now.addingTimeInterval(45)
        return command
    }
    public func recoverResult(_ result: RemoteCommandResult) {
        guard pending == nil || pending?.id == result.id else { return }
        self.result = result
        if result.status != .running { pending = nil }
    }
    public func acknowledgeResult() {
        guard let result else { return }
        do { try onResultAcknowledgement?(result) } catch { return }
        self.result = nil
    }
}
