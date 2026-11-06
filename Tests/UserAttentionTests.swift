import Foundation
import Testing
@testable import GitLabTodos

@Suite struct UserAttentionTests {
    private func snapshot(_ token: String, automatic: Bool = false, working: Bool = false) -> UserAttentionSnapshot {
        .init(candidates: [.init(id: "host/me/mr/7/11", title: "Example", subtitle: "team/repo",
            actions: [.init(reason: .drafts, token: token, automatic: automatic)], working: working)])
    }

    @Test func automaticAndActiveWorkDoNotCreateHumanAttention() {
        #expect(snapshot("draft", automatic: true).count == 0)
        #expect(snapshot("draft", working: true).count == 0)
        #expect(snapshot("draft").hasAttention)
        #expect(snapshot("draft").count == 1)
    }

    @Test func countGroupsActionsWhileSignatureTracksEditedContent() {
        let combined = UserAttentionSnapshot(candidates: [
            .init(id: "mr", title: "Example", actions: [.init(reason: .drafts, token: "draft1")]),
            .init(id: "mr", title: "Example", actions: [.init(reason: .approval, token: "head")])])
        #expect(combined.count == 1)
        #expect(combined.items[0].reasons == [.drafts, .approval])
        #expect(snapshot("old-body").items[0].signature != snapshot("edited-body").items[0].signature)
    }

    @Test func firstLoadRestartAndAccountSwitchEstablishSilentBaselines() {
        var ledger = UserAttentionNotificationLedger()
        #expect(ledger.update(snapshot("old"), account: "host/me", fresh: true, allowed: true).isEmpty)
        #expect(ledger.update(snapshot("old"), account: "host/me", fresh: true, allowed: true).isEmpty)
        #expect(ledger.update(snapshot("other"), account: "host/other", fresh: true, allowed: true).isEmpty)
        #expect(ledger.update(snapshot("old"), account: "host/me", fresh: true, allowed: true).isEmpty)
        ledger = UserAttentionNotificationLedger()
        #expect(ledger.update(snapshot("old"), account: "host/me", fresh: true, allowed: true).isEmpty)
    }

    @Test func onlyFreshNewActionSignaturesNotifyAndDisabledChangesStaySilent() {
        var ledger = UserAttentionNotificationLedger()
        _ = ledger.update(snapshot("old"), account: "host/me", fresh: true, allowed: true)
        #expect(ledger.update(snapshot("new"), account: "host/me", fresh: false, allowed: true).isEmpty)
        let delivered = ledger.update(snapshot("new"), account: "host/me", fresh: true, allowed: true)
        #expect(delivered.count == 1)
        ledger.acknowledge(delivered, account: "host/me")
        #expect(ledger.update(snapshot("new"), account: "host/me", fresh: true, allowed: true).isEmpty)
        #expect(ledger.update(snapshot("disabled"), account: "host/me", fresh: true, allowed: false).isEmpty)
        #expect(ledger.update(snapshot("disabled"), account: "host/me", fresh: true, allowed: true).isEmpty)
    }
    @Test func resolvingOneOfSeveralActionsDoesNotNotify() {
        let full = UserAttentionSnapshot(candidates: [.init(id: "mr", title: "Example", actions: [
            .init(reason: .drafts, token: "one"), .init(reason: .drafts, token: "two"), .init(reason: .approval, token: "head")])])
        let remaining = UserAttentionSnapshot(candidates: [.init(id: "mr", title: "Example", actions: [.init(reason: .approval, token: "head")])])
        var ledger = UserAttentionNotificationLedger()
        _ = ledger.update(full, account: "me", fresh: true, allowed: true)
        #expect(ledger.update(remaining, account: "me", fresh: true, allowed: true).isEmpty)
    }

    @Test func anUndeliveredActionRemainsPendingUntilSubmissionSucceeds() {
        var ledger = UserAttentionNotificationLedger()
        _ = ledger.update(snapshot("old"), account: "me", fresh: true, allowed: true)
        #expect(ledger.update(snapshot("new"), account: "me", fresh: true, allowed: true).count == 1)
        #expect(ledger.update(snapshot("new"), account: "me", fresh: true, allowed: true).count == 1)
    }

    @MainActor @Test func catalogFallbackDoesNotRestoreAutomaticallyOwnedReasons() {
        var catalog = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example",
            url: URL(string: "https://gitlab.example.test/g/p/-/merge_requests/2")!)
        catalog.hasConflict = true
        catalog.failedPipeline = true
        let automatic = catalog.presentingHumanAttention(filtered: nil, unfiltered: catalog, assistantReady: true)
        #expect(!automatic.needsAttention)
        let manual = catalog.presentingHumanAttention(filtered: nil, unfiltered: catalog, assistantReady: false)
        #expect(manual.hasConflict && manual.failedPipeline)
        var mergeDecision = catalog
        mergeDecision.needsMerge = true
        #expect(catalog.presentingHumanAttention(filtered: mergeDecision, unfiltered: catalog,
            assistantReady: false).needsMerge)
    }

    @Test func onlySuccessfullyDeliveredActionsAreAcknowledgedForTheCurrentAccount() {
        var ledger = UserAttentionNotificationLedger()
        _ = ledger.update(snapshot("baseline"), account: "me", fresh: true, allowed: true)
        let pending = ledger.update(snapshot("new"), account: "me", fresh: true, allowed: true)
        ledger.acknowledge(pending, account: "another-account")
        #expect(ledger.update(snapshot("new"), account: "me", fresh: true, allowed: true).count == 1)
        ledger.acknowledge(pending, account: "me")
        #expect(ledger.update(snapshot("new"), account: "me", fresh: true, allowed: true).isEmpty)
    }

}
