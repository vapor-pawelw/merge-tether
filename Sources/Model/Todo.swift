import Foundation

struct Todo: Identifiable, Codable, Hashable, Sendable {
    let id: Int
    let actionName: ActionName
    let targetType: TargetType
    let targetURL: URL
    let body: String
    let createdAt: Date
    var updatedAt: Date? = nil
    let state: String
    let project: Project
    let author: Author
    let target: Target

    struct Project: Codable, Hashable, Sendable {
        let id: Int
        let nameWithNamespace: String
        let pathWithNamespace: String

        enum CodingKeys: String, CodingKey {
            case id
            case nameWithNamespace = "name_with_namespace"
            case pathWithNamespace = "path_with_namespace"
        }
    }

    struct Author: Codable, Hashable, Sendable {
        let id: Int
        let username: String
        let name: String
        let avatarURL: URL?

        var shortName: String {
            let names = name.split(whereSeparator: \.isWhitespace)
            guard let firstName = names.first else { return username }
            guard names.count > 1, let lastInitial = names.last?.first else { return String(firstName) }
            return "\(firstName) \(lastInitial)"
        }

        func assistantTitleName(viewerUsername: String) -> String {
            username == viewerUsername ? String(localized: .Actions.actionAssistantTitleOwn) : shortName
        }

        enum CodingKeys: String, CodingKey {
            case id
            case username
            case name
            case avatarURL = "avatar_url"
        }
    }

    struct Target: Codable, Hashable, Sendable {
        let id: Int?
        let iid: Int?
        let title: String?
        let state: String?
        let draft: Bool?
        let workInProgress: Bool?
        let author: Author?

        enum CodingKeys: String, CodingKey {
            case id
            case iid
            case title
            case state
            case draft
            case workInProgress = "work_in_progress"
            case author
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decodeIfPresent(Int.self, forKey: .id)
            self.iid = try c.decodeIfPresent(Int.self, forKey: .iid)
            self.title = try c.decodeIfPresent(String.self, forKey: .title)
            self.state = try c.decodeIfPresent(String.self, forKey: .state)
            self.draft = try c.decodeIfPresent(Bool.self, forKey: .draft)
            self.workInProgress = try c.decodeIfPresent(Bool.self, forKey: .workInProgress)
            self.author = try? c.decodeIfPresent(Author.self, forKey: .author)
        }

        init(
            id: Int?,
            iid: Int?,
            title: String?,
            state: String?,
            draft: Bool?,
            workInProgress: Bool?,
            author: Author? = nil
        ) {
            self.id = id
            self.iid = iid
            self.title = title
            self.state = state
            self.draft = draft
            self.workInProgress = workInProgress
            self.author = author
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case actionName = "action_name"
        case targetType = "target_type"
        case targetURL = "target_url"
        case body
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case state
        case project
        case author
        case target
    }

    var isDraft: Bool {
        target.draft == true || target.workInProgress == true
    }

    var targetState: TargetState {
        TargetState(rawState: target.state, isDraft: isDraft)
    }

    /// Short-form identifier used in the row badge, e.g. "!1369" for a merge
    /// request or "#42" for an issue. Empty when the target type has no iid.
    var relativeIdentifier: String {
        guard let iid = target.iid else { return "" }
        let prefix = targetType.identifierPrefix
        guard !prefix.isEmpty else { return "" }
        return "\(prefix)\(iid)"
    }

    /// Primary display text for the row.
    var displayTitle: String {
        target.title ?? body
    }

    var linkedNoteID: Int? {
        guard let fragment = targetURL.fragment, fragment.hasPrefix("note_"),
              let id = Int(fragment.dropFirst("note_".count)), id > 0 else { return nil }
        return id
    }

    struct FeedbackIdentity: Codable, Hashable, Sendable {
        let id: Int
        let targetURL: URL
        let actorID: Int
        let action: ActionName
        let createdAt: Date
        let updatedAt: Date?
    }

    var feedbackIdentity: FeedbackIdentity {
        .init(id: id, targetURL: targetURL, actorID: author.id, action: actionName, createdAt: createdAt, updatedAt: updatedAt)
    }
}
