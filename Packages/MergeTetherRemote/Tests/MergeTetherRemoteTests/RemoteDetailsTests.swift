import Foundation
import Testing
@testable import MergeTetherRemote

@Suite struct RemoteDetailsTests {
    @Test func gitLabProfileUsesTheMergeRequestHostAndUsername() throws {
        let request = try #require(URL(string: "https://gitlab.example.test:8443/group/project/-/merge_requests/4?tab=notes#note_1"))
        let person = RemotePerson(name: "Alice Example", username: " @alice.dev-2 ",
                                  avatarURL: URL(string: "https://avatars.example.test/alice"))

        #expect(person.profileURL(on: request)?.absoluteString == "https://gitlab.example.test:8443/alice.dev-2")
    }

    @Test(arguments: [nil, "", "..", "../admin", "alice/bob", "alice%2Fbob", "alice?tab=notes", "//other.test/alice"] as [String?])
    func gitLabProfileRequiresAUsableUsername(username: String?) throws {
        let request = try #require(URL(string: "https://gitlab.example.test/group/project/-/merge_requests/4"))
        #expect(RemotePerson(name: "Alice Example", username: username).profileURL(on: request) == nil)
    }

    @Test(arguments: [nil, "file:///tmp/comment", "https://name:password@gitlab.example.test/project", "https:/project"] as [String?])
    func gitLabProfileRequiresAWebOrigin(source: String?) {
        #expect(RemotePerson(name: nil, username: "alice").profileURL(on: source.flatMap { URL(string: $0) }) == nil)
    }

    @MainActor @Test func cachedDetailResponseFinishesTheReadWithoutAuthorizingDiscussionControls() throws {
        let board = board(), card = board.cards[0], state = RemoteDetailState()
        let request = try #require(state.begin(card: card, board: board, now: date, cachedOnly: true))
        #expect(try JSONDecoder().decode(RemoteDetailRequest.self, from: JSONEncoder().encode(request)).cachedOnly == true)
        state.receive(.init(request: request, status: .current, details: .init(checkedAt: date, description: "Mac snapshot")), board: board)
        #expect(state.pending == nil)
        #expect(state.details(for: card, board: board) == nil)
        #expect(state.displayedDetails(for: card, board: board)?.description == "Mac snapshot")
    }

    @MainActor @Test func previewsKeepTheReadPendingAndPreserveCachedDiscussionsThroughFailures() throws {
        var board = board()
        let card = board.cards[0], state = RemoteDetailState()
        let request = try #require(state.begin(card: card, board: board, now: date))
        let preview = RemoteDetailResponse(request: request, status: .current,
            details: .init(checkedAt: date, description: "On the Mac"), isPreview: true)
        state.receive(try JSONDecoder().decode(RemoteDetailResponse.self, from: JSONEncoder().encode(preview)), board: board)
        #expect(state.pending == request)
        #expect(state.details(for: card, board: board) == nil)
        #expect(state.displayedDetails(for: card, board: board)?.description == "On the Mac")

        let threads = [RemoteDetailThread(id: "thread", state: .open, notes: [.init(id: "1", body: "Cached comment")])]
        state.receive(.init(request: request, status: .current, details: .init(checkedAt: date, threads: threads)), board: board)
        state.disconnect()
        board.lanes[0].cards[0].contextRevision = "updated"
        state.update(board: board)
        let updated = board.cards[0]
        let refresh = try #require(state.begin(card: updated, board: board, now: date, force: true))
        #expect(state.displayedDetails(for: updated, board: board)?.threads == threads)
        state.receive(.init(request: refresh, status: .current, details: .init(checkedAt: date, description: "New description"),
            isPreview: true), board: board)
        state.receive(.init(request: refresh, status: .unavailable), board: board)
        #expect(state.details(for: updated, board: board) == nil)
        #expect(state.displayedDetails(for: updated, board: board)?.description == "New description")
        #expect(state.displayedDetails(for: updated, board: board)?.threads == threads)

        var partial = board
        partial.partial = true
        partial.lanes = []
        state.update(board: partial)
        #expect(state.displayedDetails(for: updated, board: partial)?.threads == threads)

        for changeAccount in [true, false] {
            var other = board
            if changeAccount { other.account = "another@host" }
            else { other.hostSession = UUID() }
            state.update(board: other)
            #expect(state.displayedDetails(for: updated, board: other) == nil)
        }
        #expect(state.displayedDetails(for: updated, board: board) == nil)
    }

    @Test(arguments: [RemoteApprovalPerson.Status.approved, .previouslyApproved, .commented, .assigned])
    func onlyApprovalEvidenceMarksTheViewerAndPlacesThemFirst(_ status: RemoteApprovalPerson.Status) throws {
        let other = RemoteApprovalPerson(id: 8, name: "Other", username: "other", status: .approved)
        let viewer = RemoteApprovalPerson(id: 7, name: "Viewer", username: "me", status: status)
        let details = RemoteApprovalDetails(progress: nil, people: [other, viewer], viewerApprovalID: 7)
        let hasApproval = status == .approved || status == .previouslyApproved
        #expect(details.viewerApproval == (hasApproval ? viewer : nil))
        #expect(details.orderedPeople.first == (hasApproval ? viewer : other))
        #expect(try JSONDecoder().decode(RemoteApprovalDetails.self, from: JSONEncoder().encode(details)) == details)
    }

    @Test func presentationIndependentReadsRemainBoundToContentAndDecodeLegacyRequests() throws {
        let original = board(), card = original.cards[0]
        let legacy = try RemoteDetailRequest(card: card, board: original)
        #expect(legacy.contentDigest == nil)
        #expect(try JSONDecoder().decode(RemoteDetailRequest.self, from: JSONEncoder().encode(legacy)) == legacy)
        let current = try RemoteDetailRequest(card: card, board: original, presentationIndependent: true)
        #expect(current.contentDigest != nil)
        #expect(try JSONDecoder().decode(RemoteDetailRequest.self, from: JSONEncoder().encode(current)) == current)
        for change in ["head", "text", "draft", "action", "account", "session"] {
            var changed = original
            switch change {
            case "head": changed.lanes[0].cards[0].head = "new-head"
            case "text": changed.lanes[0].cards[0].contextRevision = "edited-description"
            case "draft": changed.lanes[0].cards[0].drafts = [.init(id: 11, body: "New reply")]
            case "action": changed.lanes[0].cards[0].actions = [.init(id: "approve", kind: .approve, token: "new")]
            case "account": changed.account = "other"
            default: changed.hostSession = UUID()
            }
            #expect(!current.matches(changed))
        }
    }

    @Test func olderPhonesCanStillOpenDetailsAfterPeopleMessagesAreAdded() throws {
        var board = board()
        board.lanes[0].cards[0].presentation = .init(repository: "p", status: "Open review thread from Alice")
        let request = try RemoteDetailRequest(card: board.cards[0], board: board)
        let message = RemotePeopleMessage(prefix: "Open review thread from",
                                          people: [.init(name: "Alice", username: "alice")], remainingCount: 0)
        board.lanes[0].cards[0].presentation?.statusPeopleMessage = message
        let card = board.cards[0]
        #expect(request.matches(board))
        #expect(try JSONDecoder().decode(RemoteCard.self, from: JSONEncoder().encode(card)) == card)
        board.lanes[0].cards[0].head = "changed"
        #expect(!request.matches(board))
    }

    @MainActor @Test func presentationUpdatesDoNotInterruptAnOpenDetailsRead() throws {
        var board = board()
        let state = RemoteDetailState()
        let request = try #require(state.begin(card: board.cards[0], board: board, now: date))
        board.lanes[0].cards[0].presentation = .init(repository: "p", status: "Checking feedback", working: true)
        board.lanes[0].cards[0].detail = "Updated explanation"
        board.lanes[0].cards[0].needsAttention = true
        state.update(board: board)
        #expect(state.pending == request)
        #expect(state.failure == nil)
        state.receive(.init(request: request, status: .current, details: .init(checkedAt: date)), board: board)
        #expect(state.details(for: board.cards[0], board: board)?.checkedAt == date)
    }

    @Test func threadDraftLinksSurviveTransportAndBoundedExcerpts() throws {
        // given
        let payload = Data(#"{"id":"discussion/first","state":"resolved","notes":[{"id":"1","body":"Concern"}],"reply":"none","draftCount":2,"draftIDs":[11,12],"truncated":false}"#.utf8)
        var thread = try JSONDecoder().decode(RemoteDetailThread.self, from: payload)
        thread.notes[0].body = String(repeating: "Comment ", count: 1_000)
        let board = board()
        let request = try RemoteDetailRequest(card: board.cards[0], board: board)

        // when
        let details = RemoteMRDetails(checkedAt: date, threads: [thread])
        let response = RemoteDetailResponse(request: request, status: .current, details: details).bounded()
        let bounded = try #require(response.details?.threads?.first)
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(bounded)) as? [String: Any])

        // then
        #expect(wire["draftIDs"] as? [Int] == [11, 12])
        #expect(bounded.draftCount == 2 && bounded.truncated)
        #expect(bounded.notes.first?.body.count == 4_000)
    }

    @Test(arguments: [
        (RemoteDetailThread.Reply.published, 0, true), (.published, 1, false), (.published, 2, false),
        (.earlier, 0, false), (.earlier, 1, false), (.none, 0, false),
        (.unknown, 0, false), (.unavailable, 0, false)
    ])
    func onlyACurrentPublishedReplyWithoutDraftsGetsAPublishedIndicator(
        reply: RemoteDetailThread.Reply, draftCount: Int, visible: Bool) throws {
        let thread = RemoteDetailThread(id: "thread", state: .open, notes: [], reply: reply, draftCount: draftCount)
        #expect(thread.showsPublishedReply == visible)
        let decoded = try JSONDecoder().decode(RemoteDetailThread.self, from: JSONEncoder().encode(thread))
        #expect(decoded.reply == reply && decoded.draftCount == draftCount)
        #expect(decoded.showsPublishedReply == visible)
    }

    @Test func threadAssessmentAndBranchesAreOptionalAndRoundTripWithoutChangingReplyOrOrigin() throws {
        let legacy = try JSONDecoder().decode(RemoteDetailThread.self,
            from: Data(#"{"id":"thread","state":"resolved","notes":[],"reply":"none","draftCount":0,"truncated":false}"#.utf8))
        #expect(legacy.feedback == nil && legacy.origin == nil && legacy.draftIDs == nil)
        let note = RemoteDetailNote(id: "11", author: "Reviewer", body: "Concern", origin: .ai, authorID: 7)
        let thread = RemoteDetailThread(id: "thread", state: .open, notes: [note], reply: .published,
            draftCount: 1, feedback: .addressed)
        #expect(thread.origin == .ai)
        let details = RemoteMRDetails(checkedAt: date, threads: [thread], branches: .init(source: "feature/very-long-name", target: "release/current"))
        let decoded = try JSONDecoder().decode(RemoteMRDetails.self, from: JSONEncoder().encode(details))
        #expect(decoded == details)
        #expect(decoded.threads?.first?.reply == .published && decoded.threads?.first?.draftCount == 1)
        #expect(decoded.threads?.first?.notes.first?.authorID == 7)
        #expect(decoded.branches?.source == "feature/very-long-name" && decoded.branches?.target == "release/current")
        let oldDetails = RemoteMRDetails(checkedAt: date)
        #expect(try JSONDecoder().decode(RemoteMRDetails.self, from: JSONEncoder().encode(oldDetails)).branches == nil)
    }

    @Test func savedRulesAreOptionalAndStayASubsetOfPolicyWhenBounded() throws {
        // Older hosts send no rules; the phone then shows every policy line together, as before.
        let legacy = try JSONDecoder().decode(RemoteMRDetails.self,
            from: JSONEncoder().encode(RemoteMRDetails(checkedAt: date, policy: ["Merge waits for you"])))
        #expect(legacy.rules == nil)
        var details = RemoteMRDetails(checkedAt: date, description: String(repeating: "ą", count: 100_000),
            policy: ["Automatic work paused: sign in to the coding agent", "Merge waits for you"])
        details.rules = ["Merge waits for you"]
        #expect(try JSONDecoder().decode(RemoteMRDetails.self, from: JSONEncoder().encode(details)) == details)
        let board = board()
        let request = try RemoteDetailRequest(card: board.cards[0], board: board)
        let bounded = try #require(RemoteDetailResponse(request: request, status: .current, details: details).bounded().details)
        #expect(bounded.rules?.allSatisfy(bounded.policy.contains) == true)
    }

    @Test func automationStatusIsOptionalRoundTripsAndIsClippedWhenBounded() throws {
        let legacy = try JSONDecoder().decode(RemoteMRDetails.self, from: Data(
            #"{"checkedAt":0,"metadata":[],"reasons":[],"policy":[],"feedback":[],"activity":[],"truncated":false}"#.utf8))
        #expect(legacy.automation == nil)
        var details = RemoteMRDetails(checkedAt: date)
        details.automation = .init(active: false, summary: "Automation paused · Decided by: Draft default")
        #expect(try JSONDecoder().decode(RemoteMRDetails.self, from: JSONEncoder().encode(details)) == details)

        details.automation = .init(active: true, summary: String(repeating: "a", count: 2_000))
        let board = board()
        let request = try RemoteDetailRequest(card: board.cards[0], board: board)
        let bounded = try #require(RemoteDetailResponse(request: request, status: .current, details: details).bounded().details)
        #expect(bounded.automation?.active == true && bounded.automation?.summary.count == 512 && bounded.truncated)
    }

    @Test func extraContextIsOptionalForOlderPayloadsAndRoundTrips() throws {
        let legacyNote = try JSONDecoder().decode(RemoteDetailNote.self, from: Data(#"{"id":"1","body":"Reply","origin":"ai"}"#.utf8))
        #expect(legacyNote.extraContext == nil && legacyNote.proposedSolution == nil)
        let legacyDetails = try JSONDecoder().decode(RemoteMRDetails.self, from: Data(
            #"{"checkedAt":0,"metadata":[],"reasons":[],"policy":[],"feedback":[],"activity":[],"truncated":false}"#.utf8))
        #expect(legacyDetails.draftContexts == nil && legacyDetails.proposedSolutionDraftIDs == nil)
        var details = RemoteMRDetails(checkedAt: date, threads: [.init(id: "thread", state: .open,
            notes: [.init(id: "20", body: "Reply", origin: .ai, extraContext: "**Why** it matters", proposedSolution: true)])])
        details.draftContexts = ["11": "- Background"]
        details.proposedSolutionDraftIDs = [11]
        let decoded = try JSONDecoder().decode(RemoteMRDetails.self, from: JSONEncoder().encode(details))
        #expect(decoded == details)
        #expect(decoded.threads?.first?.notes.first?.extraContext == "**Why** it matters")
        #expect(decoded.draftContexts?["11"] == "- Background")
        #expect(decoded.threads?.first?.notes.first?.proposedSolution == true)
        #expect(decoded.proposedSolutionDraftIDs == [11])

        // An older phone's decoder sees only the fields it knows; the extra keys are ignored.
        struct OlderNote: Decodable { let id: String; let body: String }
        let older = try JSONDecoder().decode(OlderNote.self, from: JSONEncoder().encode(decoded.threads![0].notes[0]))
        #expect(older.id == "20" && older.body == "Reply")
    }

    @Test func boundedDetailsClipExtraContextAndDropItBeforeComments() throws {
        let board = board(), card = board.cards[0]
        let request = try RemoteDetailRequest(card: card, board: board)
        let long = String(repeating: "ą", count: 5_000)
        var details = RemoteMRDetails(checkedAt: date, threads: [.init(id: "t", state: .open,
            notes: [.init(id: "1", body: "Short", extraContext: long, proposedSolution: true)])])
        details.draftContexts = ["11": long]
        details.proposedSolutionDraftIDs = [11, 12]
        let clipped = RemoteDetailResponse(request: request, status: .current, details: details).bounded()
        #expect(clipped.details?.threads?.first?.notes.first?.extraContext?.count == 4_000)
        #expect(clipped.details?.draftContexts?["11"]?.count == 4_000)
        #expect(clipped.details?.proposedSolutionDraftIDs == [11])
        #expect(clipped.details?.threads?.first?.notes.first?.proposedSolution == true)
        #expect(clipped.details?.truncated == true)

        let contexts = Dictionary(uniqueKeysWithValues: (0..<100).map { (String($0), String(repeating: "\"ą", count: 2_000)) })
        let notes = (0..<30).map { RemoteDetailNote(id: String($0), body: "Comment \($0)", extraContext: String(repeating: "\"ą", count: 2_000)) }
        var large = RemoteMRDetails(checkedAt: date, threads: [.init(id: "t", state: .open, notes: notes)])
        large.draftContexts = contexts
        large.proposedSolutionDraftIDs = [11]
        let fitted = RemoteDetailResponse(request: request, status: .current, details: large).bounded()
        let encoded = try JSONEncoder().encode(RemoteMessage(type: .details, detailResponse: fitted))
        #expect(encoded.count <= RemoteCipher.maximumPayloadBytes)
        #expect(fitted.details?.threads?.first?.notes.count == 30)
        #expect(fitted.details?.draftContexts == nil && fitted.details?.proposedSolutionDraftIDs == nil)
    }

    @Test func olderPhonesWithoutAuthorIdentityFieldsCanStillOpenDetails() throws {
        var card = RemoteCard(id: "mr:1:2", title: "MR", project: "g/p", url: nil)
        card.presentation = .init(author: "Alice Example", repository: "p",
            authorUsername: "alice", authorAvatarURL: URL(string: "https://gitlab.example.test/a.png"))
        let board = RemoteBoard(hostSession: UUID(), account: "me@host", lanes: [.init(id: .own, cards: [card])])
        #expect(try RemoteDetailRequest(card: card, board: board).matches(board))

        // An older phone decodes the card without the new fields before hashing it.
        var legacy = card
        legacy.presentation?.authorUsername = nil
        legacy.presentation?.authorAvatarURL = nil
        #expect(try RemoteDetailRequest(card: legacy, board: board).matches(board))

        var changed = legacy
        changed.presentation?.author = "Someone Else"
        #expect(try !RemoteDetailRequest(card: changed, board: board).matches(board))
    }

    @Test func olderPhonesWithoutDraftRecipientFieldsCanStillOpenDetails() throws {
        var card = RemoteCard(id: "mr:1:2", title: "MR", project: "g/p", url: nil,
            drafts: [.init(id: 11, body: "Reply", context: "thread",
                           replyRecipients: [.init(name: "Alice Example", username: "alice")])])
        card.presentation = .init(author: "Alice Example", repository: "p", authorUsername: "alice",
            pendingDrafts: "1 unpublished draft · no reply published yet to Alice Example")
        let board = RemoteBoard(hostSession: UUID(), account: "me@host", lanes: [.init(id: .own, cards: [card])])
        let wire = try JSONDecoder().decode(RemoteCard.self, from: JSONEncoder().encode(card))
        #expect(wire.drafts.first?.replyRecipients?.first?.name == "Alice Example")
        #expect(wire.presentation?.pendingDrafts == card.presentation?.pendingDrafts)

        var legacy = card
        legacy.presentation?.pendingDrafts = nil
        legacy.drafts[0].replyRecipients = nil
        #expect(try RemoteDetailRequest(card: legacy, board: board).matches(board))
        legacy.presentation?.authorUsername = nil
        #expect(try RemoteDetailRequest(card: legacy, board: board).matches(board))
        legacy.drafts[0].body = "Edited"
        #expect(try !RemoteDetailRequest(card: legacy, board: board).matches(board))
    }

    @Test func peopleAreOptionalAndClippedWithTheirFields() throws {
        let legacyField = try JSONDecoder().decode(RemoteDetailField.self, from: Data(#"{"label":"Author","value":"Alice"}"#.utf8))
        #expect(legacyField.person == nil)
        let legacyPerson = try JSONDecoder().decode(RemoteApprovalPerson.self,
            from: Data(#"{"id":1,"name":"Alice","username":"alice","status":"approved"}"#.utf8))
        #expect(legacyPerson.avatarURL == nil)
        let person = RemotePerson(name: "Alice", username: "alice", avatarURL: URL(string: "https://gitlab.example.test/a.png"))
        let field = RemoteDetailField(label: "Alice", value: "Waiting", person: person)
        #expect(try JSONDecoder().decode(RemoteDetailField.self, from: JSONEncoder().encode(field)) == field)
    }

    @Test func threadOriginDoesNotTurnMissingOrMixedEvidenceIntoAIOrHuman() {
        func thread(_ origins: [RemoteDetailNote.Origin?]) -> RemoteDetailThread {
            .init(id: "thread", state: .general, notes: origins.enumerated().map {
                RemoteDetailNote(id: String($0.offset), body: "Note", origin: $0.element)
            })
        }
        #expect(thread([.ai, .ai]).origin == .ai)
        #expect(thread([.ai, .uncertain]).origin == .uncertain)
        #expect(thread([.human, .human]).origin == .human)
        #expect(thread([.ai, .human]).origin == nil)
        #expect(thread([.ai, nil]).origin == nil)
        #expect(thread([nil]).origin == nil)
        #expect(thread([]).origin == nil)
        var truncated = thread([.ai])
        truncated.truncated = true
        #expect(truncated.origin == nil)
    }

    private let date = Date(timeIntervalSince1970: 100)
    private func board() -> RemoteBoard {
        .init(hostSession: UUID(), account: "me@host", lanes: [.init(id: .own, cards: [
            .init(id: "mr:1:2", title: "Feature", project: "g/p", url: nil, head: "a", contextRevision: "source-target-text")
        ])])
    }

    @MainActor @Test func detailsAreReadOnlyAndCanLoadWithoutAnyWriteAction() throws {
        let board = board(), state = RemoteDetailState()
        let request = try #require(state.begin(card: board.cards[0], board: board, now: date))
        let response = RemoteDetailResponse(request: request, status: .current,
            details: .init(checkedAt: date, metadata: [.init(label: "Source", value: "feature")]))
        state.receive(response, board: board)
        #expect(state.details(for: board.cards[0], board: board)?.metadata.first?.value == "feature")
        #expect(board.cards[0].actions.isEmpty)
        #expect(state.pending == nil)
    }

    @MainActor @Test(arguments: ["account", "session", "head", "target", "card"])
    func lateDetailsCannotCrossTheirDisplayedContext(_ change: String) throws {
        var board = board()
        let state = RemoteDetailState(), original = board.cards[0]
        let request = try #require(state.begin(card: original, board: board, now: date))
        switch change {
        case "account": board.account = "other@host"
        case "session": board.hostSession = UUID()
        case "head": board.lanes[0].cards[0].head = "b"
        case "target": board.lanes[0].cards[0].contextRevision = "changed-target"
        case "card": board.lanes[0].cards[0].id = "mr:1:3"
        default: break
        }
        state.receive(.init(request: request, status: .current, details: .init(checkedAt: date)), board: board)
        #expect(state.details(for: board.cards[0], board: board) == nil)
    }

    @MainActor @Test func replacingTheRequestRejectsTheEarlierReplyAndDisconnectKeepsOnlyMatchingCachedData() throws {
        let board = board(), state = RemoteDetailState(), card = board.cards[0]
        let first = try #require(state.begin(card: card, board: board, now: date))
        let current = try #require(state.begin(card: card, board: board, now: date, force: true))
        state.receive(.init(request: first, status: .current, details: .init(checkedAt: date)), board: board)
        #expect(state.details(for: card, board: board) == nil)
        state.receive(.init(request: current, status: .current, details: .init(checkedAt: date)), board: board)
        state.disconnect()
        #expect(state.details(for: card, board: board) != nil)
        var changed = board; changed.account = "other@host"
        state.update(board: changed)
        #expect(state.details(for: card, board: changed) == nil)
    }

    @MainActor @Test func timeoutAndPartialReadNeverGrantCommandReadiness() throws {
        let board = board(), state = RemoteDetailState()
        let request = try #require(state.begin(card: board.cards[0], board: board, now: date))
        #expect(state.isLoading(now: date))
        #expect(!state.isLoading(now: date.addingTimeInterval(46)))
        state.receive(.init(request: request, status: .unavailable), board: board)
        #expect(state.failure == .unavailable)
        #expect(state.details(for: board.cards[0], board: board) == nil)
        let phone = RemotePhoneState()
        let challenge = phone.challenge(now: date)
        var partial = board; partial.partial = true
        phone.receive(.init(type: .snapshot, challenge: challenge, board: partial), now: date)
        #expect(!phone.canAct(now: date))
    }

    @Test func aLargeEscapedDetailResponseFitsTheEncryptedPayloadAndDeclaresItsExcerpt() throws {
        let board = board(), card = board.cards[0]
        let request = try RemoteDetailRequest(card: card, board: board)
        let note = RemoteDetailNote(id: "1", author: "Person", username: "person", body: String(repeating: "\"\\\ną", count: 40_000))
        let threads = (0..<80).map { RemoteDetailThread(id: String($0), state: .open, notes: [note]) }
        let response = RemoteDetailResponse(request: request, status: .current,
            details: .init(checkedAt: date, description: String(repeating: "ą", count: 100_000), threads: threads)).bounded()
        let encoded = try JSONEncoder().encode(RemoteMessage(type: .details, detailResponse: response))
        #expect(encoded.count <= RemoteCipher.maximumPayloadBytes)
        #expect(response.details?.truncated == true)
        #expect(response.status == .current)
    }
}
