import Foundation
import Testing
import MergeTetherRemote
@testable import GitLabTodos

@Suite struct PersonDirectoryTests {
    @Test func identityPrefersTheDisplayNameAndKeepsTheHandleForHover() {
        let person = PersonIdentity(name: "  Alice Example ", username: "@alice")
        #expect(person.displayName == "Alice Example")
        #expect(person.handle == "@alice")
        #expect(person.accessibilityName == "Alice Example, @alice")

        let bare = PersonIdentity(name: " ", username: "bob")
        #expect(bare.displayName == "bob")
        #expect(bare.handle == "@bob")
        #expect(bare.accessibilityName == "bob")

        let unknown = PersonIdentity(name: nil, username: "  ")
        #expect(unknown.displayName == nil && unknown.handle == nil && unknown.accessibilityName == nil)
    }

    @Test func avatarsAreLimitedToWebURLs() {
        #expect(PersonIdentity(name: nil, username: "a", avatarURL: URL(string: "https://gitlab.example.test/a.png")).hasAvatar)
        #expect(!PersonIdentity(name: nil, username: "a", avatarURL: URL(string: "file:///etc/passwd")).hasAvatar)
        #expect(!PersonIdentity(name: nil, username: "a").hasAvatar)
    }

    @Test func directoryResolvesHandlesCaseInsensitivelyAndFallsBackToTheHandle() {
        let avatar = URL(string: "https://gitlab.example.test/alice.png")
        var directory = PersonDirectory([.init(name: nil, username: "Alice", avatarURL: avatar)])
        directory.insert(.init(name: "Alice Example", username: "alice"))
        directory.insert(.init(name: "Someone Else", username: "ALICE"))

        let alice = directory.person(username: "@alice")
        #expect(alice.name == "Alice Example")
        #expect(alice.avatarURL == avatar)
        #expect(directory.displayName(username: "alice") == "Alice Example")
        #expect(directory.displayName(username: "carol") == "@carol")
        #expect(directory.displayNames(["@alice", "carol"]) == "Alice Example, @carol")
    }

    @Test func mergeRequestDirectoryIncludesTheAuthorReviewersApproversAndNoteAuthors() throws {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Feature","labels":[],"web_url":"https://gitlab.example.test/g/p/-/merge_requests/2","state":"opened","draft":false,"source_branch":"feature","target_branch":"main","reviewers":[{"id":4,"username":"rev","name":"Reviewer"}]}"#.utf8))
        let approvals = MergeRequestApprovalProgress(completed: 1, required: 1,
            approvedBy: [.init(id: 5, username: "approver", name: "Approver", avatarURL: nil)])
        let note = GitLabMergeRequestDiscussion.Note(id: 1, author: .init(id: 6, username: "commenter", name: "Commenter"),
            system: false, resolvable: true, resolved: false, resolvedBy: nil)
        let directory = request.personDirectory(approvals: approvals, notes: [note])
        #expect(directory.displayNames(["me", "rev", "approver", "commenter", "stranger"])
            == "Me, Reviewer, Approver, Commenter, @stranger")
    }

    @Test func resolutionWaitMessagesNameKnownPeople() {
        let people = PersonDirectory([.init(name: "Alice Example", username: "alice")])
        let message = AuthorFeedbackPolicy.resolutionWaitMessage(authors: ["@alice", "bob"], people: people)
        let text = String(localized: try! #require(message))
        #expect(text.contains("Alice Example, @bob"))
        #expect(!text.contains("@alice"))
    }

    @Test func remotePeopleRoundTripAndOlderPayloadsStillDecode() throws {
        let person = RemotePerson(name: "Alice Example", username: "alice", avatarURL: URL(string: "https://gitlab.example.test/a.png"))
        let field = RemoteDetailField(label: "Alice Example", value: "Waiting", person: person)
        let decoded = try JSONDecoder().decode(RemoteDetailField.self, from: JSONEncoder().encode(field))
        #expect(decoded.person == person)

        let legacy = try JSONDecoder().decode(RemoteDetailField.self, from: Data(#"{"label":"Author","value":"Alice"}"#.utf8))
        #expect(legacy.person == nil)
        let legacyNote = try JSONDecoder().decode(RemoteDetailNote.self, from: Data(#"{"id":"1","body":"Hi"}"#.utf8))
        #expect(legacyNote.avatarURL == nil)
        let legacyText = try JSONDecoder().decode(RemoteCardText.self,
            from: Data(#"{"author":"Alice","repository":"r","working":false,"chips":[]}"#.utf8))
        #expect(legacyText.authorUsername == nil && legacyText.authorAvatarURL == nil)
    }
}
