import Foundation

public struct RemoteBoardOrderGroup: Codable, Equatable, Sendable {
    public let automationEnabled: Bool
    public let pinned: Bool
    public let revision: String

    public init?(lane: RemoteLaneID, automationEnabled: Bool, pinned: Bool, cardIDs: [String]) {
        guard let revision = try? RemoteDigest.token(
            [lane.rawValue, String(automationEnabled), String(pinned)] + cardIDs
        ) else { return nil }
        self.automationEnabled = automationEnabled
        self.pinned = pinned
        self.revision = revision
    }
}

public struct RemoteBoardOrderMove: Codable, Equatable, Sendable {
    public struct Source: Codable, Equatable, Sendable {
        public let cardID: String
        public let account: String
        public let hostSession: UUID
        public let revision: String
    }

    public let source: Source
    public let destinationID: String

    public init(source: Source, destinationID: String) {
        self.source = source
        self.destinationID = destinationID
    }
}

extension RemoteBoard {
    public func orderSource(for card: RemoteCard) -> RemoteBoardOrderMove.Source? {
        guard !partial, let group = card.orderGroup,
              lanes.contains(where: { lane in
                  lane.cards.contains { $0.id != card.id && $0.orderGroup == group }
                      && lane.cards.contains { $0.id == card.id && $0.orderGroup == group }
              }) else { return nil }
        return .init(cardID: card.id, account: account, hostSession: hostSession, revision: group.revision)
    }

    public func permitsOrderMove(_ move: RemoteBoardOrderMove) -> Bool {
        let source = move.source
        guard !partial, source.account == account, source.hostSession == hostSession,
              source.cardID != move.destinationID else { return false }
        return lanes.contains { lane in
            guard let group = lane.cards.first(where: { $0.id == source.cardID })?.orderGroup,
                  group.revision == source.revision else { return false }
            return lane.cards.contains { $0.id == move.destinationID && $0.orderGroup == group }
        }
    }
}
