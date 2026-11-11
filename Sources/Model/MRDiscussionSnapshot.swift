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
        case assessed(evidence: String)
        case uncertain(evidence: String)
        case humanLikely(evidence: String)

        var badge: OriginBadge {
            switch self {
            case .verifiedAssistant, .appGenerated, .assessed: .ai
            case .uncertain: .uncertain
            case .humanLikely: .human
            }
        }
    }
    enum OriginBadge: Equatable { case ai, uncertain, human }
    enum State: Equatable { case open, resolved, general }
    struct Thread: Identifiable {
        let id: String
        let discussionID: String?
        let notes: [GitLabMergeRequestDiscussion.Note]
        let drafts: [GitLabDraftNote]
        let state: State
        let location: String?
        let origins: [Int: Origin]

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
        }

        func replySummary(currentUsername: String?) -> ReplySummary {
            guard let currentUsername, !currentUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .init(publishedReply: .unavailable, draftCount: drafts.count)
            }
            let replies = notes.filter { $0.system != true }.dropFirst()
            let latestOwnReply = replies.lastIndex { $0.author?.username == currentUsername }
            let state: ReplySummary.PublishedReply
            if let latestOwnReply {
                state = latestOwnReply == replies.indices.last ? .published : .earlier
            } else {
                state = replies.contains { $0.author?.username?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }
                    ? .unknown : .none
            }
            return .init(publishedReply: state, draftCount: drafts.count)
        }
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

    init(discussions: [GitLabMergeRequestDiscussion], drafts: [GitLabDraftNote], origins: [Int: Origin]) {
        var draftsByDiscussion: [String: [(offset: Int, element: GitLabDraftNote)]] = [:]
        for entry in drafts.enumerated() {
            guard let id = entry.element.discussionID, !id.isEmpty else { continue }
            draftsByDiscussion[id, default: []].append(entry)
        }
        var matchedDrafts: Set<Int> = []
        for (index, discussion) in discussions.enumerated() {
            let notes = discussion.notes.filter { $0.system != true }
            guard !notes.isEmpty else { continue }
            let pending = discussion.id.flatMap { draftsByDiscussion[$0] } ?? []
            matchedDrafts.formUnion(pending.map(\.offset))
            let resolvable = notes.filter { $0.resolvable == true }
            let state: State = resolvable.isEmpty ? .general
                : resolvable.allSatisfy { $0.resolved == true } ? .resolved : .open
            let position = notes.compactMap(\.position).first
            let location = MRDiscussionLocation(position: position)?.full
            var threadOrigins: [Int: Origin] = [:]
            for note in notes {
                if let id = note.id, let origin = origins[id] { threadOrigins[id] = origin }
            }
            threads.append(.init(id: discussion.id.map { "discussion/\($0)" } ?? "unidentified/\(index)",
                discussionID: discussion.id, notes: notes, drafts: pending.map(\.element), state: state,
                location: location, origins: threadOrigins))
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
        guard let path = position?.newPath ?? position?.oldPath else { return nil }
        let line = position?.newLine ?? position?.oldLine
        full = line.map { "\(path):\($0)" } ?? path
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
