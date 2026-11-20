import CryptoKit
import Foundation

struct MRDiscussionTarget: Hashable, Sendable {
    let host: String
    let username: String
    let projectID: Int
    let iid: Int
    let url: URL
}

/// A read-only conversation projection. Origin evidence belongs to a single current note.
struct MRDiscussionSnapshot {
    enum Origin: Equatable, Sendable {
        case verifiedAssistant
        case appGenerated
        case botAccount
        case assessed(evidence: String)
        case uncertain(evidence: String)
        case humanLikely(evidence: String)
        /// The user's own verdict; it replaces every automatic signal for this comment.
        case manual(OriginBadge)

        var isManual: Bool {
            if case .manual = self { return true }
            return false
        }

        var badge: OriginBadge {
            switch self {
            case .manual(let badge): badge
            case .verifiedAssistant, .appGenerated, .botAccount, .assessed: .ai
            case .uncertain: .uncertain
            case .humanLikely: .human
            }
        }
    }
    enum OriginBadge: Equatable, Sendable { case ai, uncertain, human }
    enum State: Equatable { case open, resolved, general }
    enum Feedback: String, Equatable, Sendable {
        case addressed, pending, needsVerification, informational, ignored, partlyIgnored, notApplicable

        /// The caller supplies an assessment already bound to the current head, context and discussion text.
        static func summarize(notes: [(id: Int?, authorID: Int?)], assessment: ReReviewAssessment?, authorID: Int?) -> Self {
            guard let authorID, authorID > 0, notes.allSatisfy({ ($0.authorID ?? 0) > 0 }) else { return .needsVerification }
            let external = notes.filter { $0.authorID != authorID }
            guard !external.isEmpty else { return .notApplicable }
            guard let assessment else { return .needsVerification }
            let ids = external.compactMap(\.id)
            guard ids.count == external.count, ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count else { return .needsVerification }
            let verdicts = Dictionary(grouping: assessment.notes, by: \.noteID)
            let states = ids.compactMap { id in verdicts[id]?.count == 1 ? verdicts[id]?.first?.state : nil }
            if states.contains(.blocking) { return .pending }
            guard states.count == ids.count, !states.contains(.uncertain) else { return .needsVerification }
            if states.allSatisfy({ $0 == .ignoredByUser }) { return .ignored }
            if states.contains(.ignoredByUser) { return .partlyIgnored }
            if states.allSatisfy({ $0 == .informational }) { return .informational }
            return .addressed
        }
    }
    struct Thread: Identifiable {
        let id: String
        let discussionID: String?
        let notes: [GitLabMergeRequestDiscussion.Note]
        let drafts: [GitLabDraftNote]
        let state: State
        let location: String?
        let origins: [Int: Origin]
        var authorKinds: [Int: AuthorFeedbackPolicy.AccountKind] = [:]
        let feedback: Feedback?
        /// Nil means coverage is unverified; an empty array means no substantive answer is required.
        var verifiedReplyAuthors: [String]? = nil

        var originBadge: OriginBadge? {
            var aggregate: OriginBadge?
            for note in notes where note.system != true {
                guard let id = note.id, let badge = origins[id]?.badge else { return nil }
                if let previous = aggregate, previous != badge {
                    guard previous != .human, badge != .human else { return nil }
                    aggregate = .uncertain
                } else {
                    aggregate = badge
                }
            }
            return aggregate
        }

        struct ReplySummary {
            enum PublishedReply: Equatable { case none, published, earlier, unknown, unavailable }
            let publishedReply: PublishedReply
            let draftCount: Int
            var showsPublishedReply: Bool { draftCount == 0 && publishedReply == .published }
        }

        func replySummary(currentUsername: String?) -> ReplySummary {
            guard let currentUsername, !currentUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .init(publishedReply: .unavailable, draftCount: drafts.count)
            }
            let state: ReplySummary.PublishedReply
            if let verifiedReplyAuthors {
                state = verifiedReplyAuthors.isEmpty ? .none
                    : verifiedReplyAuthors.allSatisfy { $0 == currentUsername } ? .published : .unknown
            } else {
                state = .unknown
            }
            return .init(publishedReply: state, draftCount: drafts.count)
        }
    }
    struct ReplyEvidence {
        let id: Int?
        let authorID: Int?
        let username: String?
        let body: String?

        static func from(_ note: GitLabMergeRequestDiscussion.Note) -> Self {
            .init(id: note.id, authorID: note.author?.id, username: note.author?.username, body: note.body)
        }
    }

    /// Uses only a current, source-bound semantic assessment supplied by the caller. This is display
    /// evidence; it never waives the workflow's independent own-thread reply or publication checks.
    static func replyAuthorsCoveringFeedback(notes: [ReplyEvidence], allNotes: [ReplyEvidence],
                                             assessment: ReReviewAssessment?, authorID: Int?) -> [String]? {
        guard let authorID, authorID > 0, let assessment,
              notes.allSatisfy({ ($0.authorID ?? 0) > 0 }) else { return nil }
        let external = notes.filter { $0.authorID != authorID }
        let ids = external.compactMap(\.id)
        guard ids.count == external.count, ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count else { return nil }
        let verdicts = Dictionary(grouping: assessment.notes, by: \.noteID)
        var replyAuthors: [String] = []
        for id in ids {
            guard let matches = verdicts[id], matches.count == 1, let verdict = matches.first else { return nil }
            if verdict.state == .informational || verdict.state == .ignoredByUser { continue }
            guard [.addressed, .rejected].contains(verdict.state),
                  let replyID = verdict.publishedReplyNoteID, replyID > id else { return nil }
            let replies = allNotes.filter { $0.id == replyID }
            guard replies.count == 1, let reply = replies.first, reply.authorID == authorID,
                  let username = reply.username, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  reply.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
            replyAuthors.append(username)
        }
        return replyAuthors
    }

    var threads: [Thread] = []
    var standaloneDrafts: [GitLabDraftNote] = []

    var pendingPublication: Self {
        var snapshot = self
        snapshot.threads = threads.filter { !$0.drafts.isEmpty }
        return snapshot
    }

    var remainingDiscussions: Self {
        var snapshot = self
        snapshot.threads = threads.filter { $0.drafts.isEmpty }
        snapshot.standaloneDrafts = []
        return snapshot
    }

    init(discussions: [GitLabMergeRequestDiscussion], drafts: [GitLabDraftNote], origins: [Int: Origin],
         assessment: ReReviewAssessment? = nil, authorID: Int? = nil,
         authorKinds: [Int: AuthorFeedbackPolicy.AccountKind] = [:]) {
        var draftsByDiscussion: [String: [(offset: Int, element: GitLabDraftNote)]] = [:]
        for entry in drafts.enumerated() {
            guard let id = entry.element.discussionID, !id.isEmpty else { continue }
            draftsByDiscussion[id, default: []].append(entry)
        }
        var matchedDrafts: Set<Int> = []
        let allReplyEvidence = discussions.flatMap(\.notes).filter { $0.system != true }.map(ReplyEvidence.from)
        for (index, discussion) in discussions.enumerated() {
            let notes = discussion.notes.filter { $0.system != true }
            guard !notes.isEmpty else { continue }
            let pending = discussion.id.flatMap { draftsByDiscussion[$0] } ?? []
            matchedDrafts.formUnion(pending.map(\.offset))
            let resolvable = notes.filter { $0.resolvable == true }
            let state: State = resolvable.isEmpty ? .general
                : resolvable.allSatisfy { $0.resolved == true } ? .resolved : .open
            let feedback = Feedback.summarize(notes: notes.map { ($0.id, $0.author?.id) },
                assessment: assessment, authorID: authorID)
            let position = notes.compactMap(\.position).first
            let location = MRDiscussionLocation(position: position)?.full
            var threadOrigins: [Int: Origin] = [:]
            for note in notes {
                guard let id = note.id else { continue }
                if let authorID = note.author?.id, authorKinds[authorID] == .automation {
                    threadOrigins[id] = .botAccount
                } else if let origin = origins[id] {
                    threadOrigins[id] = origin
                }
            }
            threads.append(.init(id: discussion.id.map { "discussion/\($0)" } ?? "unidentified/\(index)",
                discussionID: discussion.id, notes: notes, drafts: pending.map(\.element), state: state,
                location: location, origins: threadOrigins,
                authorKinds: authorKinds.filter { id, _ in notes.contains { $0.author?.id == id } },
                feedback: state == .resolved && feedback == .needsVerification ? nil : feedback,
                verifiedReplyAuthors: Self.replyAuthorsCoveringFeedback(notes: notes.map(ReplyEvidence.from),
                    allNotes: allReplyEvidence, assessment: assessment, authorID: authorID)))
        }
        // Group by GitLab state without changing server order within a group.
        threads = [State.open, .resolved, .general].flatMap { state in
            threads.filter { $0.state == state }
        }
        standaloneDrafts = drafts.enumerated().filter { !matchedDrafts.contains($0.offset) }.map(\.element)
    }
}

struct MRDiscussionLocation: Equatable {
    let full: String

    var compact: String {
        let filename = full.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init)
        return filename.flatMap { $0.isEmpty ? nil : $0 } ?? full
    }

    init(full: String) { self.full = full }

    init?(position: GitLabDraftNote.Position?) {
        guard let position else { return nil }
        let oldSide = position.newLine == nil && position.oldLine != nil
        let path = oldSide ? position.oldPath ?? position.newPath : position.newPath ?? position.oldPath
        guard let path else { return nil }
        let line = position.newLine ?? position.oldLine
        full = line.map { "\(path):\($0)" } ?? path
    }
}

struct MRDiscussionCodeAnchor: Hashable {
    enum Side: Hashable { case old, new }

    let path: String
    let line: Int
    let revision: String
    let side: Side

    init?(_ position: GitLabDraftNote.Position?) {
        guard let position, position.positionType == nil || position.positionType == "text" else { return nil }
        side = position.newLine == nil ? .old : .new
        guard let path = side == .new ? position.newPath : position.oldPath,
              let line = side == .new ? position.newLine : position.oldLine, line > 0,
              let revision = side == .new ? position.headSHA : position.baseSHA,
              GlabService.isFullGitSHA(revision) else { return nil }
        self.path = path
        self.line = line
        self.revision = revision
    }

    struct Line: Identifiable, Equatable {
        let number: Int
        let text: String
        var id: Int { number }
    }

    func excerpt(from data: Data) -> [Line] {
        guard data.count <= 1_048_576, !data.contains(0), let source = String(data: data, encoding: .utf8) else { return [] }
        let lines = source.utf8.split(separator: 10, omittingEmptySubsequences: false)
        let count = lines.count - (lines.last?.isEmpty == true ? 1 : 0)
        guard line <= count else { return [] }
        return (max(1, line - 2)...min(count, line + 2)).map { number in
            let bytes = lines[number - 1]
            let text = String(decoding: bytes.last == 13 ? bytes.dropLast() : bytes, as: UTF8.self)
            let prefix = text.prefix(500)
            return Line(number: number, text: prefix.count == text.count ? text : prefix + "…")
        }
    }

    static func changesURL(for position: GitLabDraftNote.Position, mergeRequestURL: URL) -> URL {
        let changes = mergeRequestURL.appending(path: "diffs")
        guard let path = position.newPath ?? position.oldPath,
              var components = URLComponents(url: changes, resolvingAgainstBaseURL: false) else { return changes }
        components.query = nil
        components.fragment = Insecure.SHA1.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return components.url ?? changes
    }
}

@MainActor
enum MRDiscussionTimestamp {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeSeconds = ISO8601DateFormatter()

    static func display(_ raw: String) -> String {
        let date = fractional.date(from: raw) ?? wholeSeconds.date(from: raw)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? raw
    }
}
