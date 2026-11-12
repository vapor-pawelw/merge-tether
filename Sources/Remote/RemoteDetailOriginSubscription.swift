import Foundation
import MergeTetherRemote

/// One open, read-only Details destination; pending annotations also cover the initial send window.
@MainActor final class RemoteDetailOriginSubscription {
    let request: RemoteDetailRequest
    let source: GitLabMergeRequest
    let accountRevision: UInt64
    private struct Note {
        let threadID: String
        var note: RemoteDetailNote
    }
    private var full: [Int: Note] = [:]
    private var rendered: [Int: Note] = [:]
    private var sourceDigests: [Int: String] = [:]
    private var pending: [Int: AICommentDisplayCoordinator.PersistedOrigin] = [:]
    private var latest: [Int: UInt64] = [:]
    private(set) var isDelivered = false

    init(request: RemoteDetailRequest, source: GitLabMergeRequest, accountRevision: UInt64) {
        self.request = request; self.source = source; self.accountRevision = accountRevision
    }

    func delivered(full: RemoteMRDetails, rendered: RemoteMRDetails) {
        self.rendered = notes(in: rendered)
        self.full = notes(in: full).filter { self.rendered[$0.key] != nil }
        isDelivered = true
    }

    func record(_ event: AICommentDisplayCoordinator.PersistedOrigins) -> Bool {
        guard event.accountRevision == accountRevision, event.target.projectID == source.projectID,
              event.target.iid == source.iid, request.account == "\(event.target.username)@\(event.target.host)",
              let context = RemoteBoardAdapter.contextRevision(source), RemoteBoardAdapter.contextRevision(event.request) == context,
              !event.origins.isEmpty, event.origins.count <= 100,
              Set(event.origins.map(\.noteID)).count == event.origins.count else { return false }
        var changed = false
        for origin in event.origins where origin.revision > latest[origin.noteID, default: 0] {
            pending[origin.noteID] = origin; latest[origin.noteID] = origin.revision; changed = true
        }
        return changed
    }

    func nextUpdate() -> RemoteDetailOrigins? {
        guard isDelivered else { return nil }
        var changes: [RemoteDetailOriginChange] = []
        let envelope = RemoteMessage(type: .details, detailOrigins: .init(request: request, changes: []))
        guard let base = try? JSONEncoder().encode(envelope).count else { return nil }
        var bytes = base
        for origin in pending.values.sorted(by: { $0.noteID < $1.noteID }) {
            guard let change = change(for: origin), rendered[origin.noteID]?.note.origin != change.origin else {
                pending.removeValue(forKey: origin.noteID); continue
            }
            guard let cost = try? JSONEncoder().encode(change).count else { pending.removeValue(forKey: origin.noteID); continue }
            if bytes + cost + 1 > RemoteCipher.maximumPayloadBytes {
                if changes.isEmpty { pending.removeValue(forKey: origin.noteID); continue }
                break
            }
            changes.append(change)
            bytes += cost + 1
            if changes.count == 100 { break }
        }
        return changes.isEmpty ? nil : .init(request: request, changes: changes)
    }

    func recordSent(_ update: RemoteDetailOrigins) {
        guard update.request == request else { return }
        for change in update.changes {
            guard let id = Int(change.noteID), rendered[id]?.note.originIdentity(in: change.threadID) == change.identity else { continue }
            if let origin = pending[id], self.change(for: origin) == change { pending.removeValue(forKey: id) }
            rendered[id]?.note.origin = change.origin
        }
    }

    private func change(for origin: AICommentDisplayCoordinator.PersistedOrigin) -> RemoteDetailOriginChange? {
        guard let original = full[origin.noteID], let visible = rendered[origin.noteID], original.threadID == visible.threadID,
              original.note.authorID == origin.authorID, visible.note.authorID == origin.authorID else { return nil }
        let digest = sourceDigests[origin.noteID] ?? AICommentAssessmentStore.digest(original.note.body)
        sourceDigests[origin.noteID] = digest
        guard digest == origin.bodySHA256, let identity = visible.note.originIdentity(in: visible.threadID) else { return nil }
        let badge: RemoteDetailNote.Origin = origin.classification == .aiAssisted && origin.confidence != .uncertain ? .ai
            : origin.classification == .manualLikely && origin.confidence != .uncertain ? .human : .uncertain
        return .init(threadID: visible.threadID, noteID: visible.note.id, identity: identity, origin: badge, revision: origin.revision)
    }

    private func notes(in details: RemoteMRDetails) -> [Int: Note] {
        var result: [Int: Note] = [:], duplicates: Set<Int> = []
        for thread in details.threads ?? [] {
            for note in thread.notes {
                guard let id = Int(note.id), id > 0 else { continue }
                if result[id] != nil { duplicates.insert(id) }
                result[id] = .init(threadID: thread.id, note: note)
            }
        }
        for id in duplicates { result.removeValue(forKey: id) }
        return result
    }
}
