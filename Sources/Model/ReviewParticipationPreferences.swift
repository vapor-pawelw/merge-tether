import Foundation

struct ReviewParticipationPreferences: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let host: String
        let username: String
        let reviewerID: Int
        let label: String
    }
    private(set) var entries: [Entry] = []
    private(set) var localAutomationAuthors: [Entry] = []

    private enum CodingKeys: String, CodingKey { case entries, localAutomationAuthors }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries = try values.decode([Entry].self, forKey: .entries)
        localAutomationAuthors = try values.decodeIfPresent([Entry].self, forKey: .localAutomationAuthors) ?? []
        let identities = localAutomationAuthors.map { "\($0.host)/\($0.username)/\($0.reviewerID)" }
        guard localAutomationAuthors.allSatisfy({
            !$0.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.reviewerID > 0 && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }), Set(identities).count == identities.count,
            Set(localAutomationAuthors.map(\.id)).count == localAutomationAuthors.count else {
            throw DecodingError.dataCorruptedError(forKey: .localAutomationAuthors, in: values,
                debugDescription: "Invalid local automation author identities")
        }
    }

    @discardableResult mutating func exclude(_ identity: PublicationIdentity, username: String) -> Bool {
        guard !identity.host.isEmpty, identity.entityID > 0, !username.isEmpty,
              !excludedIDs(host: identity.host, username: username).contains(identity.entityID) else { return false }
        entries.append(.init(id: UUID(), host: identity.host, username: username,
            reviewerID: identity.entityID, label: identity.label))
        return true
    }

    @discardableResult mutating func remove(_ id: UUID) -> Bool {
        guard entries.contains(where: { $0.id == id }) else { return false }
        entries.removeAll { $0.id == id }
        return true
    }

    func excludedIDs(host: String, username: String) -> Set<Int> {
        Set(entries.filter { $0.host == host && $0.username == username }.map(\.reviewerID))
    }

    func revision(host: String, username: String) -> String {
        let exclusions = excludedIDs(host: host, username: username).sorted().map(String.init).joined(separator: ",")
        let bots = botIDs(host: host, username: username)
        guard !bots.isEmpty else { return exclusions }
        return exclusions + "|bots:" + bots.sorted().map(String.init).joined(separator: ",")
    }

    @discardableResult mutating func markAutomationAuthor(_ identity: PublicationIdentity, host: String,
                                                         user: GitLabAuthenticatedUser) -> Bool {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, identity.host == host,
              user.id > 0, !user.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              identity.entityID > 0, identity.entityID != user.id,
              !identity.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isDeclaredAutomation(host: host, username: user.username, userID: identity.entityID) else { return false }
        localAutomationAuthors.append(.init(id: UUID(), host: host, username: user.username,
            reviewerID: identity.entityID, label: identity.label))
        return true
    }

    @discardableResult mutating func unmarkAutomationAuthor(_ id: UUID, host: String, username: String) -> Bool {
        guard localAutomationAuthors.contains(where: { $0.id == id && $0.host == host && $0.username == username }) else { return false }
        localAutomationAuthors.removeAll { $0.id == id && $0.host == host && $0.username == username }
        return true
    }

    func botIDs(host: String, username: String) -> Set<Int> {
        Set(localAutomationAuthors.filter { $0.host == host && $0.username == username }.map(\.reviewerID))
    }

    func isDeclaredAutomation(host: String, username: String, userID: Int) -> Bool {
        userID > 0 && botIDs(host: host, username: username).contains(userID)
    }

    func permitsAutomaticReply(_ draft: GitLabDraftNote, discussions: [GitLabMergeRequestDiscussion],
                               requestAuthorID: Int, userID: Int, host: String, username: String,
                               selectedFeedbackNoteIDs: [Int] = [], semanticOptOutIDs: Set<Int> = []) -> Bool {
        let excluded = excludedIDs(host: host, username: username).union(semanticOptOutIDs)
        guard !excluded.isEmpty else { return true }
        if requestAuthorID != userID && excluded.contains(requestAuthorID) { return false }
        let selected = draft.discussionID == nil ? Set(selectedFeedbackNoteIDs) : []
        if draft.discussionID == nil, selected.isEmpty,
           discussions.flatMap(\.notes).contains(where: { $0.system != true && $0.author.map { excluded.contains($0.id) } == true }) {
            return false
        }
        return !discussions.contains { discussion in
            discussion.notes.contains { note in
                note.system != true && note.author.map { excluded.contains($0.id) } == true
                    && (discussion.id == draft.discussionID && draft.discussionID != nil
                        || note.id.map(selected.contains) == true)
            }
        }
    }

    func workerInstructions(host: String, username: String) -> String {
        let excluded = entries.filter { $0.host == host && $0.username == username }
        guard !excluded.isEmpty else { return "" }
        let identities = excluded.map { "\($0.reviewerID) (\($0.label))" }.joined(separator: ", ")
        return """


        The user has excluded these GitLab participants from automatic review communication: \(identities).
        Do not create or edit private replies, publish replies, acknowledge/react to their comments, resolve
        their discussions, assign them as reviewers, request re-review, or recommend inviting them.
        Their opt-out alone requires no reply or code change. Independently assess any genuine technical
        issue they reported; this preference never waives a defect, test, merge condition or acceptance.
        If a real fix is needed, keep all ordinary implementation and verification requirements, but report
        the outcome in the run result without a draft/reply to that participant. Do not manufacture file proof.
        """
    }
}
