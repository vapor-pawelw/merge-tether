import Foundation
import MergeTetherRemote

struct MRGitLabActivity: Identifiable, Sendable {
    enum Resource: String, CaseIterable, Sendable {
        case state, label, milestone
    }

    enum Kind: Sendable {
        case comment(noteID: Int, discussionID: String?)
        case systemNote(noteID: Int)
        case state(GitLabMergeRequestState)
        case label(action: String?, name: String?)
        case milestone(action: String?, title: String?)
    }

    let id: String
    let createdAt: Date
    let person: PersonIdentity?
    let kind: Kind
    let body: String?
    var updatedAt: Date? = nil
    var location: String? = nil
    var resolved: Bool? = nil

    var actor: String? { person?.displayName }

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

    var title: LocalizedStringResource {
        switch kind {
        case .comment: .AutomationHistory.automationHistoryComment
        case .systemNote: .AutomationHistory.automationHistorySystemNote
        case .state(.opened): .AutomationHistory.automationHistoryOpened
        case .state(.reopened): .AutomationHistory.automationHistoryReopened
        case .state(.closed): .AutomationHistory.automationHistoryClosed
        case .state(.merged): .AutomationHistory.automationHistoryMerged
        case .state(let state): .AutomationHistory.automationHistoryStateChanged(state.rawValue)
        case .label("add", let name): .AutomationHistory.automationHistoryAddedLabel(name ?? "")
        case .label("remove", let name): .AutomationHistory.automationHistoryRemovedLabel(name ?? "")
        case .label(_, let name): .AutomationHistory.automationHistoryChangedLabel(name ?? "")
        case .milestone("add", let title): .AutomationHistory.automationHistoryAddedMilestone(title ?? "")
        case .milestone("remove", let title): .AutomationHistory.automationHistoryRemovedMilestone(title ?? "")
        case .milestone(_, let title): .AutomationHistory.automationHistoryChangedMilestone(title ?? "")
        }
    }

    var summary: String? {
        guard let line = body?.prefix(240).split(whereSeparator: \.isNewline).first else { return nil }
        return SafeInlineMarkdown.render(String(line)).map { String($0.characters) } ?? String(line)
    }

    var systemHeadline: String? {
        guard case .systemNote = kind, let summary else { return nil }
        return [actor, summary].compactMap { $0 }.joined(separator: " ")
    }

    static func notes(in discussions: [GitLabMergeRequestDiscussion]) -> [Self] {
        var seen = Set<Int>()
        return discussions.flatMap { discussion in
            discussion.notes.compactMap { note in
                guard let id = note.id, id > 0, let date = activityDate(note.createdAt),
                      seen.insert(id).inserted else { return nil }
                let kind: Kind = note.system == true ? .systemNote(noteID: id)
                    : .comment(noteID: id, discussionID: discussion.id)
                let updated = activityDate(note.updatedAt).flatMap { $0 > date ? $0 : nil }
                return Self(id: "note/\(id)", createdAt: date, person: note.author?.person, kind: kind, body: note.body,
                            updatedAt: updated, location: note.position?.location, resolved: note.resolved)
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
        let state: GitLabMergeRequestState?
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
                guard let state, !state.rawValue.isEmpty else { return nil }
                kind = .state(state)
            case .label: kind = .label(action: action, name: label?.name)
            case .milestone: kind = .milestone(action: action, title: milestone?.title)
            }
            return .init(id: "\(resource.rawValue)/\(id)", createdAt: date, person: user?.person, kind: kind, body: nil)
        }
    }

    private static func activityDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }
}
