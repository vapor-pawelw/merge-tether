import Foundation
import Testing
@testable import GitLabTodos

@Suite("Lifecycle completion receipts")
struct LifecycleCompletionReceiptTests {
    private let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 7, iid: 11)
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test(arguments: ["merged", "closed"], ["me", "reviewed-author"])
    func terminalTransitionKeepsReceiptAfterAutomaticLaneCleanupAndBannerConsumption(_ state: String, _ author: String) throws {
        var ledger = MergeRequestLifecycleLedger()
        ledger.record(try request(author: author), for: target, now: start)
        ledger.record(try request(state: state, author: author), for: target, now: start.addingTimeInterval(1), autoRemoveFinished: true)
        let banner = try #require(ledger.takeTransitions(host: target.host, username: target.username).first)
        #expect(ledger.isSuppressed(target))
        let receipt = try #require(receipts(ledger).first)
        #expect(receipts(ledger).count == 1)
        #expect(receipt.id == banner.id)
        #expect(receipt.target == target)
        #expect(receipt.kind.rawValue == state)
        #expect(receipt.title == "Exact completion title")
        #expect(receipt.url.absoluteString == "https://gitlab.example.test/team/repo/-/merge_requests/11")
        #expect(receipt.observedAt == start.addingTimeInterval(1))
        #expect(receipt.author?.username == author)
        ledger = try restart(ledger)
        ledger.record(try request(state: state, author: author), for: target, now: start.addingTimeInterval(2), autoRemoveFinished: true)
        #expect(receipts(ledger).map(\.id) == [receipt.id])
        #expect(ledger.takeTransitions(host: target.host, username: target.username).isEmpty)
    }

    @Test func suppressionDoesNotMeanSeenAndRetainedCardSeenAcknowledgesSameEvent() throws {
        var ledger = try closedLedger()
        let event = try #require(receipts(ledger).first)
        ledger.suppressFinished(target)
        #expect(ledger.isSuppressed(target))
        #expect(receipts(ledger).map(\.id) == [event.id])
        ledger.restore(target)
        ledger.acknowledgeFinished(target)
        #expect(ledger.isSuppressed(target))
        #expect(receipts(try restart(ledger)).isEmpty)
        ledger.record(try request(state: "closed"), for: target, now: start.addingTimeInterval(2))
        #expect(receipts(ledger).isEmpty)
    }

    @Test func seenIsBoundToExactAccountAndEventAndDoesNotIgnoreOrDeleteTracking() throws {
        var ledger = try closedLedger()
        let event = try #require(receipts(ledger).first)
        let acknowledgementResult1 = ledger.acknowledgeCompletion(id: event.id, host: target.host, username: "other")
        #expect(!acknowledgementResult1)
        let acknowledgementResult2 = ledger.acknowledgeCompletion(id: event.id, host: "other.example.test", username: target.username)
        #expect(!acknowledgementResult2)
        #expect(receipts(ledger).map(\.id) == [event.id])
        let acknowledgementResult3 = ledger.acknowledgeCompletion(id: event.id, host: target.host, username: target.username)
        #expect(acknowledgementResult3)
        #expect(receipts(try restart(ledger)).isEmpty)
        #expect(ledger.request(for: target)?.state == "closed")
        #expect(ledger.targets(host: target.host, username: target.username).contains(target))
        ledger.record(try request(), for: target, now: start.addingTimeInterval(2))
        #expect(!ledger.isSuppressed(target))
        #expect(ledger.retainedRequests(host: target.host, username: target.username).first?.state == "opened")
    }

    @Test func reopenedMRKeepsOriginalReceiptUntilNextTerminalEventReplacesIt() throws {
        var ledger = try closedLedger()
        let old = try #require(receipts(ledger).first)
        ledger.record(try request(title: "Reopened title"), for: target, now: start.addingTimeInterval(2))
        #expect(receipts(ledger).map(\.id) == [old.id])
        #expect(receipts(ledger).first?.title == "Exact completion title")
        ledger = try restart(ledger)
        ledger.record(try request(state: "closed", title: "Second close"), for: target, now: start.addingTimeInterval(3))
        let current = try #require(receipts(ledger).first)
        #expect(receipts(ledger).count == 1)
        #expect(current.id != old.id)
        #expect(current.title == "Second close")
        let acknowledgementResult4 = ledger.acknowledgeCompletion(id: old.id, host: target.host, username: target.username)
        #expect(!acknowledgementResult4)
        #expect(receipts(ledger).map(\.id) == [current.id])
        #expect(ledger.takeTransitions(host: target.host, username: target.username).map(\.kind) == [.closed, .closed])
    }

    @Test func seenThenReopenAndCloseCreatesFreshReceipt() throws {
        var ledger = try closedLedger()
        let old = try #require(receipts(ledger).first)
        let acknowledgementResult5 = ledger.acknowledgeCompletion(id: old.id, host: target.host, username: target.username)
        #expect(acknowledgementResult5)
        ledger = try restart(ledger)
        ledger.record(try request(), for: target, now: start.addingTimeInterval(2))
        ledger.record(try request(state: "merged"), for: target, now: start.addingTimeInterval(3))
        let current = try #require(receipts(ledger).first)
        #expect(current.id != old.id)
        #expect(current.kind == .merged)
    }

    @Test func kindFiltersHideAndRestoreStoredUnseenEventsWithoutChangingBannerQueue() throws {
        var ledger = try closedLedger()
        let event = try #require(receipts(ledger).first)
        #expect(ledger.unreadCompletions(host: target.host, username: target.username, showMerged: true, showClosed: false).isEmpty)
        ledger = try restart(ledger)
        #expect(receipts(ledger).map(\.id) == [event.id])
        #expect(ledger.unreadCompletions(host: target.host, username: "other", showMerged: true, showClosed: true).isEmpty)
        #expect(ledger.takeTransitions(host: target.host, username: target.username).map(\.id) == [event.id])
        #expect(receipts(ledger).map(\.id) == [event.id])
    }

    @Test(arguments: ["closed", "merged"])
    func cleanupOfKnownRetainedTerminalCreatesOneReceiptAtOriginalObservationTime(_ state: String) throws {
        var ledger = MergeRequestLifecycleLedger()
        ledger.record(try request(state: state), for: target, now: start)
        #expect(receipts(ledger).isEmpty)
        ledger = try restart(ledger)
        ledger.prepareFinishedRemoval(host: target.host, username: target.username)
        let event = try #require(receipts(ledger).first)
        #expect(event.observedAt == start)
        #expect(event.kind.rawValue == state)
        #expect(ledger.isSuppressed(target))
        #expect(ledger.takeTransitions(host: target.host, username: target.username).isEmpty)
        ledger = try restart(ledger)
        ledger.prepareFinishedRemoval(host: target.host, username: target.username)
        #expect(receipts(ledger).map(\.id) == [event.id])
        let acknowledgementResult6 = ledger.acknowledgeCompletion(id: event.id, host: target.host, username: target.username)
        #expect(acknowledgementResult6)
        ledger.prepareFinishedRemoval(host: target.host, username: target.username)
        #expect(receipts(ledger).isEmpty)
    }

    @Test func cleanupNeverResurrectsAlreadySuppressedLegacyTerminalRows() throws {
        var ledger = MergeRequestLifecycleLedger()
        ledger.record(try request(state: "merged"), for: target, now: start, autoRemoveFinished: true)
        ledger = try restart(ledger)
        ledger.prepareFinishedRemoval(host: target.host, username: target.username)
        #expect(ledger.isSuppressed(target))
        #expect(receipts(ledger).isEmpty)
    }

    @Test func staleAndInvalidObservationsCannotReplaceCurrentReceipt() throws {
        var ledger = try closedLedger()
        let event = try #require(receipts(ledger).first)
        ledger.record(try request(state: "merged"), for: target, now: start.addingTimeInterval(0.5))
        let otherHost = MRAutomationScope.Target(host: "other.example.test", username: target.username, projectID: 7, iid: 11)
        ledger.record(try request(state: "merged"), for: otherHost, now: start.addingTimeInterval(5))
        #expect(ledger.request(for: target)?.state == "closed")
        #expect(receipts(ledger).map(\.id) == [event.id])
        #expect(ledger.unreadCompletions(host: otherHost.host, username: otherHost.username, showMerged: true, showClosed: true).isEmpty)
    }

    @Test func draftReadyChangesRemainBannerOnly() throws {
        var ledger = MergeRequestLifecycleLedger()
        ledger.record(try request(draft: true), for: target, now: start)
        ledger.record(try request(), for: target, now: start.addingTimeInterval(1))
        #expect(ledger.takeTransitions(host: target.host, username: target.username).map(\.kind) == [.ready])
        #expect(receipts(ledger).isEmpty)
    }

    @Test func restoringSeenTerminalRowDoesNotInventAnotherHistoricalCompletion() throws {
        var ledger = try closedLedger()
        let event = try #require(receipts(ledger).first)
        let acknowledged = ledger.acknowledgeCompletion(id: event.id, host: target.host, username: target.username)
        #expect(acknowledged)
        ledger = try restart(ledger)
        ledger.restore(target)
        ledger.prepareFinishedRemoval(host: target.host, username: target.username)
        #expect(receipts(ledger).isEmpty)
    }

    @Test func legacyLedgerWithoutCompletionFieldsPreservesItsTrackedMR() throws {
        var ledger = MergeRequestLifecycleLedger()
        ledger.record(try request(state: "closed"), for: target, now: start)
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        payload.removeValue(forKey: "completions")
        var entries = try #require(payload["entries"] as? [Any])
        for index in entries.indices {
            guard var entry = entries[index] as? [String: Any], entry["request"] != nil else { continue }
            entry.removeValue(forKey: "terminalObservedAt")
            entry.removeValue(forKey: "terminalReceiptRecorded")
            entries[index] = entry
        }
        payload["entries"] = entries
        let restored = try JSONDecoder().decode(MergeRequestLifecycleLedger.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(restored.request(for: target)?.state == "closed")
        #expect(restored.retainedRequests(host: target.host, username: target.username).count == 1)
        #expect(receipts(restored).isEmpty)
    }

    private func receipts(_ ledger: MergeRequestLifecycleLedger) -> [MergeRequestLifecycleLedger.CompletionReceipt] {
        ledger.unreadCompletions(host: target.host, username: target.username, showMerged: true, showClosed: true)
    }

    private func closedLedger() throws -> MergeRequestLifecycleLedger {
        var ledger = MergeRequestLifecycleLedger()
        ledger.record(try request(), for: target, now: start)
        ledger.record(try request(state: "closed"), for: target, now: start.addingTimeInterval(1))
        return ledger
    }

    private func restart(_ ledger: MergeRequestLifecycleLedger) throws -> MergeRequestLifecycleLedger {
        try JSONDecoder().decode(MergeRequestLifecycleLedger.self, from: JSONEncoder().encode(ledger))
    }

    private func request(state: String = "opened", author: String = "me", title: String = "Exact completion title", draft: Bool = false) throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":7,"iid":11,"author":{"id":1,"username":"\#(author)","name":"Synthetic author"},"title":"\#(title)","web_url":"https://gitlab.example.test/team/repo/-/merge_requests/11","state":"\#(state)","draft":\#(draft),"sha":"synthetic-head","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
    }
}
