import Foundation
import Testing
import MergeTetherRemote
@testable import MergeTether

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

    @Test func viewerSuffixIdentifiesTheSignedInAccountByUsername() {
        let viewer = PersonIdentity(name: "Sam Reviewer", username: " @Sam ")
        let namesake = PersonIdentity(name: "Sam Reviewer", username: "another-sam")
        let unknown = PersonIdentity(name: "Sam Reviewer", username: nil)

        #expect(viewer.viewerSuffix(for: "sam").map { String(localized: $0) } == "(you)")
        #expect(viewer.viewerSuffix(for: nil) == nil)
        #expect(namesake.viewerSuffix(for: "sam") == nil)
        #expect(unknown.viewerSuffix(for: "sam") == nil)
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
        let finding = AuthorFeedbackPolicy.Finding(id: 1, discussionID: "t", reviewerID: 7, reviewerUsername: "alice",
            state: .ready, reason: nil, waitingForReviewers: [], waitingForHumanResolution: ["@alice", "bob"])
        let text = finding.resolutionWaitPeopleMessage(people: people)?.text ?? ""
        #expect(text.contains("Alice Example and @bob"))
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
        #expect(legacyText.statusPeopleMessage == nil && legacyText.requirementPeopleMessage == nil
            && legacyText.pendingDraftsPeopleMessage == nil)
    }

    @Test func replyRecipientsCarryDisplayNamesAndSkipTheViewerAndSystemNotes() throws {
        let discussion = try JSONDecoder().decode(GitLabMergeRequestDiscussion.self, from: Data(#"""
            {"id":"t","notes":[
              {"id":1,"author":{"id":5,"username":"ext_pragmatic_pw1","name":"Pragmatic Reviewer"},"system":false},
              {"id":2,"author":{"id":3,"username":"me","name":"Me"},"system":false},
              {"id":3,"author":{"id":5,"username":"EXT_pragmatic_pw1","name":"Pragmatic Reviewer"},"system":false},
              {"id":4,"author":{"id":6,"username":"bot","name":"Bot"},"system":true}]}
            """#.utf8))
        let recipients = discussion.replyRecipients(excluding: 3)
        #expect(recipients.map(\.displayName) == ["Pragmatic Reviewer"])
        #expect(recipients.first?.handle == "@ext_pragmatic_pw1")
    }

    @Test func pendingDraftsSummaryNamesPeopleStillWithoutAPublishedReply() throws {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "MR",
            url: URL(string: "https://gitlab.example.com/g/p/-/merge_requests/2")!)
        #expect(MRPendingDraftsSummary(item: item) == nil)
        func draft(_ id: Int, _ thread: String?) -> GitLabDraftNote {
            .init(id: id, authorID: 3, note: "Reply", discussionID: thread, position: nil)
        }
        let alice = PersonIdentity(name: "Alice Example", username: "alice")
        let bob = PersonIdentity(name: "Bob Example", username: "bob")
        item.drafts = [draft(1, "a"), draft(2, "b"), draft(3, nil), draft(4, "missing")]
        item.replyRecipients = ["a": [alice], "b": [bob, alice], "unrelated": [.init(name: "Carol", username: "carol")]]
        let summary = try #require(MRPendingDraftsSummary(item: item))
        #expect(summary.count == 4)
        #expect(summary.awaitingReply == [alice, bob])
        let message = String(localized: summary.message)
        #expect(message == "4 unpublished drafts for Alice Example and Bob Example")

        item.drafts = [draft(1, "a")]
        let reply = try #require(MRPendingDraftsSummary(item: item))
        #expect(String(localized: reply.message) == "1 unpublished draft for Alice Example")
        #expect(reply.peopleMessage?.people == [.init(name: "Alice Example", username: "alice")])

        item.drafts = [draft(1, nil)]
        let general = try #require(MRPendingDraftsSummary(item: item))
        #expect(general.awaitingReply.isEmpty)
        #expect(String(localized: general.message) == String(localized: .Board.boardPendingDraftsSingle))
    }

    @Test func pendingDraftsSummaryCapsTheNamedPeople() throws {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "MR",
            url: URL(string: "https://gitlab.example.com/g/p/-/merge_requests/2")!)
        item.drafts = [.init(id: 1, authorID: 3, note: "Reply", discussionID: "t", position: nil)]
        item.replyRecipients = ["t": ["a", "b", "c", "d", "e"].map { (id: String) in PersonIdentity(name: "Person \(id)", username: id) }]
        let message = String(localized: try #require(MRPendingDraftsSummary(item: item)).message)
        #expect(message.contains("Person a, Person b and 3 others"))
        #expect(!message.contains("Person c"))
    }
}
