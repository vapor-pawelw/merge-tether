import Foundation
import MergeTetherRemote

extension Todo.Author {
    var person: PersonIdentity { .init(name: name, username: username, avatarURL: avatarURL) }
}

extension GitLabWorkflowUser {
    var person: PersonIdentity { .init(name: name, username: username, avatarURL: avatarURL) }
}

extension PersonIdentity {
    var remotePerson: RemotePerson { .init(name: displayName, username: normalizedUsername, avatarURL: avatarURL) }
}

extension Todo.Author {
    var remotePerson: RemotePerson { person.remotePerson }
}

/// Resolves bare GitLab usernames to the people the merge request already knows,
/// so sentences can name them instead of printing @handles.
struct PersonDirectory: Sendable {
    private var people: [String: PersonIdentity] = [:]

    init(_ people: [PersonIdentity] = []) {
        for person in people { insert(person) }
    }

    init(authors: [Todo.Author]) { self.init(authors.map(\.person)) }

    mutating func insert(_ person: PersonIdentity) {
        guard let key = person.normalizedUsername?.lowercased() else { return }
        // The first entry with a real display name wins; later duplicates only fill gaps.
        if let existing = people[key], existing.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            if existing.avatarURL == nil, person.avatarURL != nil { people[key]?.avatarURL = person.avatarURL }
            return
        }
        people[key] = .init(name: person.name, username: person.normalizedUsername,
                            avatarURL: person.avatarURL ?? people[key]?.avatarURL)
    }

    func person(username: String) -> PersonIdentity {
        let bare = PersonIdentity(name: nil, username: username)
        guard let key = bare.normalizedUsername?.lowercased() else { return bare }
        return people[key] ?? bare
    }

    /// The display name for a username, or the @handle when the person is unknown.
    func displayName(username: String) -> String {
        let person = person(username: username)
        guard person.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return person.handle ?? username
        }
        return person.displayName ?? username
    }

    func displayNames(_ usernames: [String]) -> String {
        usernames.map(displayName(username:)).joined(separator: ", ")
    }
}

extension GitLabMergeRequest {
    /// Author, reviewers, everyone in the approval history and the authors of the given notes.
    func personDirectory(approvals: MergeRequestApprovalProgress? = nil,
                         notes: [GitLabMergeRequestDiscussion.Note] = []) -> PersonDirectory {
        var authors = [author] + (reviewers ?? [])
        if let approvals {
            authors += approvals.approvedBy + approvals.reviewHistory.activities.values.compactMap(\.author).sorted { $0.id < $1.id }
        }
        var directory = PersonDirectory(authors: authors)
        for note in notes { if let person = note.author?.person { directory.insert(person) } }
        return directory
    }
}

extension MergeRequestAttentionMonitor.Item {
    var personDirectory: PersonDirectory {
        mergeRequest?.personDirectory(approvals: approvalProgress, notes: feedback)
            ?? PersonDirectory(feedback.compactMap { $0.author?.person })
    }
}
