import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct ReviewParticipationPreferencesTests {
    @Test(arguments: ["write", "synchronize"])
    func failedPreferencePersistenceKeepsTheNegativeDecisionAndSafetyHold(_ failure: String) throws {
        let suite = "ReviewParticipationPreferencesFailure.\(UUID())"
        let defaults = try #require(PersistenceFaultDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let automation = settings.automation
        settings.reviewParticipationPreferences.exclude(.init(host: "gitlab.example.org", entityID: 7, label: "@reviewer"), username: "me")
        defaults.rejectedKey = failure == "write" ? "reviewParticipationPreferences" : nil
        defaults.synchronizationFails = failure == "synchronize"
        #expect(!settings.saveReviewParticipationPreferences())
        #expect(settings.reviewParticipationPreferences.excludedIDs(host: "gitlab.example.org", username: "me") == [7])
        #expect(!settings.automaticActionsAllowed)
        #expect(settings.automation == automation)
        defaults.rejectedKey = nil
        defaults.synchronizationFails = false
        #expect(settings.saveReviewParticipationPreferences())
        let entry = try #require(settings.reviewParticipationPreferences.entries.first)
        defaults.rejectedKey = failure == "write" ? "reviewParticipationPreferences" : nil
        defaults.synchronizationFails = failure == "synchronize"
        #expect(!settings.removeReviewParticipationExclusion(entry.id))
        #expect(settings.reviewParticipationPreferences.excludedIDs(host: "gitlab.example.org", username: "me") == [7])
        #expect(!settings.automaticActionsAllowed)
    }

    @Test func anUnrelatedDurableHoldDoesNotMisreportASuccessfulPreferenceWrite() throws {
        let suite = "ReviewParticipationPreferencesUnrelatedHold.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.recordPersistenceFailure("unrelatedJournal")
        settings.reviewParticipationPreferences.exclude(.init(host: "gitlab.example.org", entityID: 7, label: "@reviewer"), username: "me")
        #expect(settings.saveReviewParticipationPreferences())
        #expect(!settings.automaticActionsAllowed)
    }

    @Test func exclusionsPersistByAccountHostAndStableIdentityAndCanBeReversed() throws {
        let suite = "ReviewParticipationPreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let excluded = settings.reviewParticipationPreferences.exclude(
            .init(host: "gitlab.example.org", entityID: 7, label: "@reviewer"), username: "me")
        #expect(excluded)
        settings.save()
        let restored = SettingsManager(defaults: defaults)
        #expect(restored.reviewParticipationPreferences.excludedIDs(host: "gitlab.example.org", username: "me") == [7])
        #expect(restored.reviewParticipationPreferences.excludedIDs(host: "other.example.org", username: "me").isEmpty)
        #expect(restored.reviewParticipationPreferences.excludedIDs(host: "gitlab.example.org", username: "other").isEmpty)
        let entry = try #require(restored.reviewParticipationPreferences.entries.first)
        let removed = restored.reviewParticipationPreferences.remove(entry.id)
        #expect(removed)
        restored.save()
        #expect(SettingsManager(defaults: defaults).reviewParticipationPreferences.entries.isEmpty)
    }

    @Test func noReplyPreferenceBlocksThreadAndSelectedGeneralRepliesWithoutBlockingOtherParticipants() {
        var preferences = ReviewParticipationPreferences()
        preferences.exclude(.init(host: "gitlab.example.org", entityID: 7, label: "@reviewer"), username: "me")
        let discussions = [GitLabMergeRequestDiscussion(id: "excluded", notes: [
            .init(id: 10, author: .init(id: 7, username: "reviewer", name: "Reviewer"), system: false,
                resolvable: false, resolved: false, resolvedBy: nil, body: "Do not invite me to reviews")]),
            .init(id: "other", notes: [.init(id: 20, author: .init(id: 8, username: "other", name: "Other"),
                system: false, resolvable: false, resolved: false, resolvedBy: nil, body: "Fix overflow")])]
        func allowed(_ discussion: String?, selected: [Int] = []) -> Bool {
            preferences.permitsAutomaticReply(.init(id: 12, authorID: 3, note: "Response", discussionID: discussion, position: nil),
                discussions: discussions, requestAuthorID: 3, userID: 3, host: "gitlab.example.org", username: "me",
                selectedFeedbackNoteIDs: selected)
        }
        #expect(!allowed("excluded"))
        #expect(!allowed(nil, selected: [10]))
        #expect(!allowed(nil))
        #expect(allowed("other"))
        #expect(allowed(nil, selected: [20]))
    }
}
