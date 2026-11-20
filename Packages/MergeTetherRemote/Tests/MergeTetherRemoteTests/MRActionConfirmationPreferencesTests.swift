import Foundation
import Testing
@testable import MergeTetherRemote

struct MRActionConfirmationPreferencesTests {
    @Test func remembersOnlyTheAcceptedActionWhenRequested() throws {
        let name = "MRActionConfirmationPreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = MRActionConfirmationPreferences(defaults: defaults)

        #expect(preferences.requiresConfirmation(for: "verifyFeedback"))
        preferences.accept("verifyFeedback", remember: false)
        #expect(preferences.requiresConfirmation(for: "verifyFeedback"))

        preferences.accept("verifyFeedback", remember: true)
        let reopened = MRActionConfirmationPreferences(defaults: try #require(UserDefaults(suiteName: name)))
        #expect(!reopened.requiresConfirmation(for: "verifyFeedback"))
        #expect(reopened.requiresConfirmation(for: "verifyReReview"))
        #expect(reopened.requiresConfirmation(for: "verifyFeedback.retry"))
    }

    @Test func confirmationIdentityKeepsDifferentActionsAndReviewModesSeparate() throws {
        let first = RemoteAction(id: "job:first", kind: .retryJob, token: "first", confirmationID: "retryRun.pipeline")
        let second = RemoteAction(id: "job:second", kind: .retryJob, token: "second", confirmationID: "retryRun.pipeline")
        let review = RemoteAction(id: "job:review", kind: .retryJob, token: "review", confirmationID: "retryRun.review.manual")
        let automaticReview = RemoteAction(id: "runReview", kind: .runReview, token: "review", confirmationID: "runReview.all")
        let manualReview = RemoteAction(id: "runReview", kind: .runReview, token: "review", confirmationID: "runReview.manual")

        #expect(first.suppressibleConfirmationID == second.suppressibleConfirmationID)
        #expect(first.suppressibleConfirmationID != review.suppressibleConfirmationID)
        #expect(automaticReview.suppressibleConfirmationID != manualReview.suppressibleConfirmationID)
        #expect(RemoteAction(id: "approve", kind: .approve, token: "approve").suppressibleConfirmationID == nil)

        let legacy = try JSONDecoder().decode(RemoteAction.self, from: Data("""
            {"id":"verifyDrafts","kind":"verify","token":"legacy"}
            """.utf8))
        #expect(legacy.suppressibleConfirmationID == "verify.verifyDrafts")
    }
}
