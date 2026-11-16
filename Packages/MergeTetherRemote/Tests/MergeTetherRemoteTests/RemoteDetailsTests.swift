import Foundation
import Testing
@testable import MergeTetherRemote

@Suite struct RemoteDetailsTests {
    @Test func threadAssessmentAndBranchesAreOptionalAndRoundTripWithoutChangingReplyOrOrigin() throws {
        let legacy = try JSONDecoder().decode(RemoteDetailThread.self,
            from: Data(#"{"id":"thread","state":"resolved","notes":[],"reply":"none","draftCount":0,"truncated":false}"#.utf8))
        #expect(legacy.feedback == nil && legacy.origin == nil)
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

    @Test func extraContextIsOptionalForOlderPayloadsAndRoundTrips() throws {
        let legacyNote = try JSONDecoder().decode(RemoteDetailNote.self, from: Data(#"{"id":"1","body":"Reply","origin":"ai"}"#.utf8))
        #expect(legacyNote.extraContext == nil)
        let legacyDetails = try JSONDecoder().decode(RemoteMRDetails.self, from: Data(
            #"{"checkedAt":0,"metadata":[],"reasons":[],"policy":[],"feedback":[],"activity":[],"truncated":false}"#.utf8))
        #expect(legacyDetails.draftContexts == nil)
        var details = RemoteMRDetails(checkedAt: date, threads: [.init(id: "thread", state: .open,
            notes: [.init(id: "20", body: "Reply", origin: .ai, extraContext: "**Why** it matters")])])
        details.draftContexts = ["11": "- Background"]
        let decoded = try JSONDecoder().decode(RemoteMRDetails.self, from: JSONEncoder().encode(details))
        #expect(decoded == details)
        #expect(decoded.threads?.first?.notes.first?.extraContext == "**Why** it matters")
        #expect(decoded.draftContexts?["11"] == "- Background")

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
            notes: [.init(id: "1", body: "Short", extraContext: long)])])
        details.draftContexts = ["11": long]
        let clipped = RemoteDetailResponse(request: request, status: .current, details: details).bounded()
        #expect(clipped.details?.threads?.first?.notes.first?.extraContext?.count == 4_000)
        #expect(clipped.details?.draftContexts?["11"]?.count == 4_000)
        #expect(clipped.details?.truncated == true)

        let contexts = Dictionary(uniqueKeysWithValues: (0..<100).map { (String($0), String(repeating: "\"ą", count: 2_000)) })
        let notes = (0..<30).map { RemoteDetailNote(id: String($0), body: "Comment \($0)", extraContext: String(repeating: "\"ą", count: 2_000)) }
        var large = RemoteMRDetails(checkedAt: date, threads: [.init(id: "t", state: .open, notes: notes)])
        large.draftContexts = contexts
        let fitted = RemoteDetailResponse(request: request, status: .current, details: large).bounded()
        let encoded = try JSONEncoder().encode(RemoteMessage(type: .details, detailResponse: fitted))
        #expect(encoded.count <= RemoteCipher.maximumPayloadBytes)
        #expect(fitted.details?.threads?.first?.notes.count == 30)
        #expect(fitted.details?.draftContexts == nil)
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
