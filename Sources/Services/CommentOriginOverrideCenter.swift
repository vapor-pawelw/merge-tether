import Foundation
import Observation

/// Applies the user's comment-origin verdicts. A verdict that would let automation publish
/// drafts waits a short grace period first, so the user can undo it before anything happens.
@MainActor @Observable
final class CommentOriginOverrideCenter {
    typealias Note = GitLabMergeRequestDiscussion.Note
    typealias Classification = AICommentOriginOverride.Classification
    /// Drafts automation would newly publish if these note IDs counted as AI.
    typealias Gain = @MainActor (MRAutomationScope.Target, [GitLabMergeRequestDiscussion], Set<Int>) async -> Int
    /// Re-evaluates automation for the MR after a change takes effect.
    typealias Resume = @MainActor (MRAutomationScope.Target) async -> Void
    typealias Sleep = @Sendable (Duration) async throws -> Void

    enum ChangeError: Error, Equatable { case invalidTarget, unknownComment, automatedAuthor, storage }

    struct Change: Identifiable, Equatable {
        let id: UUID
        let target: MRAutomationScope.Target
        /// `nil` returns the comments to automatic assessment.
        let classification: Classification?
        let noteIDs: [Int]
        /// Drafts that automation will publish once the grace period ends.
        let resumingDrafts: Int
        let resumesAt: Date?
        fileprivate let previous: [AICommentOriginOverrideStore.Key: AICommentOriginOverride?]
        fileprivate let written: [AICommentOriginOverrideStore.Key: AICommentOriginOverride?]
    }

    static let gracePeriod: Duration = .seconds(10)

    let directory: URL
    private let grace: Duration
    private let gain: Gain
    private let resume: Resume
    private let sleep: Sleep
    private let now: @MainActor () -> Date
    /// Changes still inside their undo window, newest last.
    private(set) var pending: [Change] = []
    /// Bumped on every write so open conversations reload their badges.
    private(set) var revision: UInt64 = 0
    @ObservationIgnored private var timers: [UUID: Task<Void, Never>] = [:]

    init(directory: URL, grace: Duration = gracePeriod, gain: @escaping Gain, resume: @escaping Resume,
         sleep: @escaping Sleep = { try await Task.sleep(for: $0) }, now: @escaping @MainActor () -> Date = { Date() }) {
        self.directory = directory; self.grace = grace; self.gain = gain; self.resume = resume
        self.sleep = sleep; self.now = now
    }

    func pending(for target: MRAutomationScope.Target) -> Change? {
        pending.last { $0.target == target }
    }

    /// Every note must be a current comment of `discussions`; the verdict binds its author and body.
    @discardableResult
    func apply(_ classification: Classification?, to notes: [Note], in discussions: [GitLabMergeRequestDiscussion],
               target: MRAutomationScope.Target) async throws -> Change {
        guard let iid = target.iid, iid > 0, target.projectID > 0, !target.host.isEmpty, !target.username.isEmpty else {
            throw ChangeError.invalidTarget
        }
        let current = discussions.flatMap(\.notes).filter { $0.system != true }
        var selected: [Note] = []
        for note in notes {
            guard let id = note.id, id > 0, (note.author?.id ?? 0) > 0, note.body?.isEmpty == false,
                  !selected.contains(where: { $0.id == id }) else { continue }
            let matches = current.filter { $0.id == id }
            guard matches.count == 1, matches[0].body == note.body, matches[0].author?.id == note.author?.id else {
                throw ChangeError.unknownComment
            }
            selected.append(note)
        }
        guard !selected.isEmpty else { throw ChangeError.unknownComment }
        let key = { (id: Int) in AICommentOriginOverrideStore.Key(host: target.host, projectID: target.projectID, iid: iid, noteID: id) }
        let directory = directory
        var becomingAI: Set<Int> = []
        if classification == .ai {
            for note in selected where !AICommentAssessmentStore.isAI(note, host: target.host, projectID: target.projectID,
                                                                      iid: iid, in: directory, now: now()) {
                becomingAI.insert(note.id!)
            }
        }
        let drafts = becomingAI.isEmpty ? 0 : await gain(target, discussions, becomingAI)
        let start = wholeSecond(now())
        let activatesAt = drafts > 0 ? start.addingTimeInterval(grace.seconds) : start
        var previous: [AICommentOriginOverrideStore.Key: AICommentOriginOverride?] = [:]
        var written: [AICommentOriginOverrideStore.Key: AICommentOriginOverride?] = [:]
        for note in selected {
            let id = note.id!
            // `updateValue` keeps an explicit `nil`: "no override" is a state to restore, not a missing entry.
            previous.updateValue(AICommentOriginOverrideStore.stored(key(id), in: directory), forKey: key(id))
            written.updateValue(classification.map {
                AICommentOriginOverride(version: 1, host: target.host, username: target.username, projectID: target.projectID,
                    iid: iid, noteID: id, authorID: note.author!.id, bodySHA256: AICommentAssessmentStore.digest(note.body!),
                    classification: $0, createdAt: start, activatesAt: activatesAt)
            }, forKey: key(id))
        }
        do {
            for (key, record) in written {
                try AICommentOriginOverrideStore.restore(key, to: record, in: directory)
            }
        } catch {
            for (key, record) in previous { try? AICommentOriginOverrideStore.restore(key, to: record, in: directory) }
            revision &+= 1
            throw ChangeError.storage
        }
        // A newer verdict on the same comments replaces an older one's undo window.
        for older in pending where older.target == target && !Set(older.noteIDs).isDisjoint(with: selected.compactMap(\.id)) {
            cancelTimer(older.id)
        }
        pending.removeAll { older in older.target == target && !Set(older.noteIDs).isDisjoint(with: selected.compactMap(\.id)) }
        let change = Change(id: UUID(), target: target, classification: classification, noteIDs: selected.compactMap(\.id).sorted(),
                            resumingDrafts: drafts, resumesAt: drafts > 0 ? activatesAt : nil, previous: previous, written: written)
        revision &+= 1
        if drafts > 0 {
            pending.append(change)
            let sleep = sleep, grace = grace
            timers[change.id] = Task { [weak self] in
                do { try await sleep(grace) } catch { return }
                await self?.finish(change.id)
            }
        } else {
            await resume(target)
        }
        return change
    }

    /// Restores what each comment had before the change, unless a later verdict already replaced it.
    func undo(_ id: UUID) throws {
        guard let change = pending.first(where: { $0.id == id }) else { return }
        cancelTimer(id)
        pending.removeAll { $0.id == id }
        defer { revision &+= 1 }
        var failed = false
        for (key, written) in change.written where AICommentOriginOverrideStore.stored(key, in: directory) == written {
            do { try AICommentOriginOverrideStore.restore(key, to: change.previous[key] ?? nil, in: directory) }
            catch { failed = true }
        }
        if failed { throw ChangeError.storage }
    }

    /// Ends the grace period early.
    func continueNow(_ id: UUID) async {
        guard let change = pending.first(where: { $0.id == id }) else { return }
        cancelTimer(id)
        let start = wholeSecond(now())
        for (key, written) in change.written {
            guard let written, AICommentOriginOverrideStore.stored(key, in: directory) == written else { continue }
            let active = AICommentOriginOverride(version: written.version, host: written.host, username: written.username,
                projectID: written.projectID, iid: written.iid, noteID: written.noteID, authorID: written.authorID,
                bodySHA256: written.bodySHA256, classification: written.classification, createdAt: written.createdAt,
                activatesAt: min(written.activatesAt, start))
            try? AICommentOriginOverrideStore.save(active, in: directory)
        }
        await finish(id)
    }

    func cancelAll() {
        for id in Array(timers.keys) { cancelTimer(id) }
        pending.removeAll()
    }

    private func finish(_ id: UUID) async {
        guard let change = pending.first(where: { $0.id == id }) else { return }
        timers.removeValue(forKey: id)
        pending.removeAll { $0.id == id }
        revision &+= 1
        await resume(change.target)
    }

    /// Records store ISO 8601 seconds; whole seconds let a re-read record compare equal to the one written.
    private func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private func cancelTimer(_ id: UUID) {
        timers.removeValue(forKey: id)?.cancel()
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
