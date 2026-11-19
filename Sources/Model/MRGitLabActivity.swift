import Foundation

struct MRGitLabActivity: Identifiable, Sendable {
    enum Resource: String, Sendable {
        case state, label, milestone
    }

    enum Kind: Sendable {
        case comment(noteID: Int, discussionID: String?)
        case systemNote(noteID: Int)
        case state(String)
        case label(action: String?, name: String?)
        case milestone(action: String?, title: String?)
    }

    let id: String
    let createdAt: Date
    let actor: String?
    let kind: Kind
    let body: String?

    var noteID: Int? {
        switch kind {
        case .comment(let id, _), .systemNote(let id): id
        default: nil
        }
    }

    var discussionID: String? {
        if case .comment(_, let id) = kind { return id }
        return nil
    }

    static func notes(in discussions: [GitLabMergeRequestDiscussion]) -> [Self] {
        var seen = Set<Int>()
        return discussions.flatMap { discussion in
            discussion.notes.compactMap { note in
                guard let id = note.id, id > 0, let date = activityDate(note.createdAt),
                      seen.insert(id).inserted else { return nil }
                let kind: Kind = note.system == true ? .systemNote(noteID: id)
                    : .comment(noteID: id, discussionID: discussion.id)
                return Self(id: "note/\(id)", createdAt: date, actor: actorName(note.author), kind: kind, body: note.body)
            }
        }
    }

    struct ResourceEvent: Decodable, Sendable {
        struct Label: Decodable, Sendable { let name: String? }
        struct Milestone: Decodable, Sendable { let title: String? }

        let id: Int
        let createdAt: String?
        let user: GitLabWorkflowUser?
        let action: String?
        let state: String?
        let label: Label?
        let milestone: Milestone?

        enum CodingKeys: String, CodingKey {
            case id, user, action, state, label, milestone
            case createdAt = "created_at"
        }

        func activity(for resource: Resource) -> MRGitLabActivity? {
            guard id > 0, let date = activityDate(createdAt) else { return nil }
            let kind: Kind
            switch resource {
            case .state:
                guard let state, !state.isEmpty else { return nil }
                kind = .state(state)
            case .label: kind = .label(action: action, name: label?.name)
            case .milestone: kind = .milestone(action: action, title: milestone?.title)
            }
            return .init(id: "\(resource.rawValue)/\(id)", createdAt: date, actor: actorName(user), kind: kind, body: nil)
        }
    }

    private static func actorName(_ user: GitLabWorkflowUser?) -> String? {
        guard let user else { return nil }
        return user.person.displayName
    }

    private static func activityDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }
}
