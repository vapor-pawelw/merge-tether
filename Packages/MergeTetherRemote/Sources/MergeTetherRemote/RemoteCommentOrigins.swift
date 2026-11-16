import Foundation

/// Parameters of a `setCommentOrigin` command. The host re-reads GitLab and accepts only notes whose
/// identity still matches what the phone displayed.
public struct RemoteCommentOriginRequest: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable { case set, undo, continueNow }
    public struct Note: Codable, Equatable, Sendable {
        public let threadID: String
        public let noteID: String
        public let identity: String
        public init(threadID: String, noteID: String, identity: String) {
            self.threadID = threadID; self.noteID = noteID; self.identity = identity
        }
    }
    public let operation: Operation
    /// For `set`; `nil` returns the notes to automatic assessment.
    public let origin: RemoteDetailNote.Origin?
    public let notes: [Note]
    /// For `undo` and `continueNow`.
    public let changeID: String?

    public init(operation: Operation, origin: RemoteDetailNote.Origin? = nil, notes: [Note] = [], changeID: String? = nil) {
        self.operation = operation; self.origin = origin; self.notes = notes; self.changeID = changeID
    }

    public static func set(_ origin: RemoteDetailNote.Origin?, notes: [RemoteDetailNote], in threadID: String) -> Self? {
        let identified = notes.compactMap { note in
            note.originIdentity(in: threadID).map { Note(threadID: threadID, noteID: note.id, identity: $0) }
        }
        guard !identified.isEmpty, identified.count == notes.count else { return nil }
        return .init(operation: .set, origin: origin, notes: identified)
    }

    public static let maximumNotes = 30

    public var argument: String? {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) }
    }

    public init?(argument: String?) {
        guard let argument, argument.utf8.count <= 16_384,
              let value = try? JSONDecoder().decode(Self.self, from: Data(argument.utf8)),
              value.notes.count <= Self.maximumNotes else { return nil }
        self = value
    }
}

public struct RemoteOriginResume: Codable, Equatable, Sendable {
    public let changeID: String
    public let resumesAt: Date
    public let drafts: Int
    public init(changeID: String, resumesAt: Date, drafts: Int) {
        self.changeID = changeID; self.resumesAt = resumesAt; self.drafts = drafts
    }
}
