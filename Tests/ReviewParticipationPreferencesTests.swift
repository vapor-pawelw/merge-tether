import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct ReviewParticipationPreferencesTests {
    @Test(arguments: ["invalidID", "emptyHost", "emptyAccount", "duplicateIdentity", "duplicateEntryID"])
    func malformedStoredAutomationAuthorsKeepAutomaticActionsOnHold(_ scenario: String) throws {
        let suite = "LocalAutomationAuthorsCorrupt.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var entry: [String: Any] = ["id": UUID().uuidString, "host": "gitlab.example.org", "username": "me",
            "reviewerID": 99, "label": "@automation-author"]
        if scenario == "invalidID" { entry["reviewerID"] = 0 }
        if scenario == "emptyHost" { entry["host"] = " " }
        if scenario == "emptyAccount" { entry["username"] = " " }
        var authors = [entry]
        if scenario == "duplicateIdentity" {
            var duplicate = entry
            duplicate["id"] = UUID().uuidString
            authors.append(duplicate)
        }
        if scenario == "duplicateEntryID" {
            var duplicate = entry
            duplicate["reviewerID"] = 100
            authors.append(duplicate)
        }
        let encoded = try JSONSerialization.data(withJSONObject: ["entries": [], "localAutomationAuthors": authors])
        defaults.set(encoded, forKey: "reviewParticipationPreferences")
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.reviewParticipationPreferences.localAutomationAuthors.isEmpty)
        #expect(!settings.automaticActionsAllowed)
        #expect(defaults.data(forKey: "reviewParticipationPreferences") == encoded)
    }

    @Test func verifiedServiceDesignationUsesStableIdentityAndCanBeRemoved() async throws {
        try await withAutomationService { monitor, gitlab, _ in
            monitor.glab.notifyFeedbackAccountKind(userID: 99, kind: .regular, host: "gitlab.example.org",
                username: "me", accountRevision: monitor.glab.accountRevision)
            var events: [FeedbackAccountKindUpdate] = []
            let token = monitor.glab.observeFeedbackAccountKinds { events.append($0) }
            defer { monitor.glab.removeFeedbackAccountObserver(token) }
            try await monitor.markAutomationAuthor(username: "@automation-author")
            let preferences = monitor.settings.reviewParticipationPreferences
            #expect(preferences.botIDs(host: "gitlab.example.org", username: "me") == [99])
            #expect(preferences.localAutomationAuthors.first?.label == "@automation-author")
            #expect(events.map(\.kind) == [.automation])
            try await monitor.markAutomationAuthor(username: "automation-author")
            #expect(monitor.settings.reviewParticipationPreferences.localAutomationAuthors.count == 1)
            monitor.synchronizeLocalAutomationAuthors()
            #expect(events.map(\.kind) == [.automation])
            let entry = try #require(preferences.localAutomationAuthors.first)
            try monitor.unmarkAutomationAuthor(entry.id)
            #expect(monitor.settings.reviewParticipationPreferences.localAutomationAuthors.isEmpty)
            #expect(events.map(\.kind) == [.automation, .regular])
            #expect(events.allSatisfy { $0.userID == 99 && $0.host == "gitlab.example.org" && $0.username == "me" })
            #expect(gitlab.requests.filter { $0.arguments.first == "api" }.allSatisfy { $0.method == "GET" })
        }
    }

    @Test(arguments: ["write", "synchronize"])
    func failedServiceSavesDoNotPublishIdentityChanges(_ failure: String) async throws {
        try await withAutomationService { monitor, _, defaults in
            var events: [FeedbackAccountKindUpdate] = []
            let token = monitor.glab.observeFeedbackAccountKinds { events.append($0) }
            defer { monitor.glab.removeFeedbackAccountObserver(token) }
            defaults.rejectedKey = failure == "write" ? "reviewParticipationPreferences" : nil
            defaults.synchronizationFails = failure == "synchronize"
            do {
                try await monitor.markAutomationAuthor(username: "automation-author")
                Issue.record("A failed save accepted an automation designation")
            } catch ReviewParticipationError.persistence {}
            #expect(events.isEmpty)
            defaults.rejectedKey = nil
            defaults.synchronizationFails = false
            try await monitor.markAutomationAuthor(username: "automation-author")
            #expect(events.map(\.kind) == [.automation])
            let entry = try #require(monitor.settings.reviewParticipationPreferences.localAutomationAuthors.first)
            defaults.rejectedKey = failure == "write" ? "reviewParticipationPreferences" : nil
            defaults.synchronizationFails = failure == "synchronize"
            do {
                try monitor.unmarkAutomationAuthor(entry.id)
                Issue.record("A failed save removed an automation designation")
            } catch ReviewParticipationError.persistence {}
            #expect(events.map(\.kind) == [.automation])
            #expect(monitor.settings.reviewParticipationPreferences.botIDs(host: "gitlab.example.org", username: "me") == [99])
        }
    }

    @Test(arguments: ["self", "wrongAccount", "missingUser", "accountChange", "accountRoundTrip", "hostChange", "persistence"])
    func serviceRejectsUnverifiedOrStaleAutomationDesignations(_ scenario: String) async throws {
        try await withAutomationService { monitor, gitlab, defaults in
            let initialHandler = gitlab.handler
            gitlab.handler = { request in
                if request.endpoint == "/user", scenario == "wrongAccount" {
                    return InMemoryGitLab.output(#"{"id":4,"username":"other"}"#)
                }
                if request.endpoint.hasPrefix("/users?username=") {
                    switch scenario {
                    case "self": return InMemoryGitLab.output(#"[{"id":3,"username":"automation-author","name":"Self"}]"#)
                    case "missingUser": return InMemoryGitLab.output("[]")
                    case "accountChange": monitor.glab.currentUsername = "other"
                    case "accountRoundTrip":
                        monitor.glab.currentUsername = "other"
                        monitor.glab.currentUsername = "me"
                    case "hostChange": monitor.glab.resolvedHost = "other.example.org"
                    default: break
                    }
                }
                return try await initialHandler?(request) ?? InMemoryGitLab.output(code: 1)
            }
            if scenario == "persistence" {
                defaults.rejectedKey = "reviewParticipationPreferences"
            }
            var rejected = false
            do { try await monitor.markAutomationAuthor(username: "automation-author") }
            catch { rejected = true }
            #expect(rejected)
            #expect(monitor.settings.reviewParticipationPreferences.localAutomationAuthors.isEmpty)
        }
    }

    private func withAutomationService(_ body: @MainActor (TodoMonitorService, InMemoryGitLab, PersistenceFaultDefaults) async throws -> Void) async throws {
        let suite = "LocalAutomationAuthorsService.\(UUID())"
        let defaults = try #require(PersistenceFaultDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = "gitlab.example.org"
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        gitlab.handler = { request in
            if request.arguments == ["config", "get", "host"] { return InMemoryGitLab.output(host) }
            if request.arguments == ["auth", "status"] { return InMemoryGitLab.output(error: "Logged in to \(host) as me") }
            if request.endpoint == "/user" { return InMemoryGitLab.output(#"{"id":3,"username":"me"}"#) }
            if request.endpoint == "/users?username=automation-author" {
                return InMemoryGitLab.output(#"[{"id":99,"username":"automation-author","name":"Automation"}]"#)
            }
            return try gitlab.unexpected(request)
        }
        let glab = gitlab.service(host: host, username: "me")
        let settings = SettingsManager(defaults: defaults)
        settings.glabPath = glab.glabPath
        settings.resolvedHost = host
        settings.onboardingCompleted = false
        settings.automation.applyPreset(.manual, for: .codex)
        settings.save()
        let monitor = TodoMonitorService(settings: settings, glab: glab,
            notifications: NotificationService(authorization: { .denied }, post: { _ in }))
        defer { monitor.stopTimer() }
        await monitor.bootstrap()
        try await body(monitor, gitlab, defaults)
    }

    @Test func legacyPreferencesKeepTheirExclusionsAndRevisionWhenNoAutomationAuthorsWereStored() throws {
        let encoded = try JSONSerialization.data(withJSONObject: ["entries": [[
            "id": UUID().uuidString, "host": "gitlab.example.org", "username": "me",
            "reviewerID": 7, "label": "@excluded"
        ]]])
        let preferences = try JSONDecoder().decode(ReviewParticipationPreferences.self, from: encoded)
        #expect(preferences.localAutomationAuthors.isEmpty)
        #expect(preferences.revision(host: "gitlab.example.org", username: "me") == "7")
    }

    @Test func localAutomationAuthorsAreSeparateScopedAndReversible() throws {
        var preferences = ReviewParticipationPreferences()
        let user = GitLabAuthenticatedUser(id: 3, username: "me")
        let identity = PublicationIdentity(host: "gitlab.example.org", entityID: 99, label: "@automation-author")
        let marked = preferences.markAutomationAuthor(identity, host: identity.host, user: user)
        #expect(marked)
        #expect(preferences.botIDs(host: identity.host, username: "me") == [99])
        #expect(preferences.isDeclaredAutomation(host: identity.host, username: "me", userID: 99))
        #expect(preferences.botIDs(host: "other.example.org", username: "me").isEmpty)
        #expect(preferences.botIDs(host: identity.host, username: "other").isEmpty)
        #expect(preferences.excludedIDs(host: identity.host, username: "me").isEmpty)
        let duplicateMarked = preferences.markAutomationAuthor(.init(host: identity.host, entityID: 99, label: "@renamed"),
            host: identity.host, user: user)
        #expect(!duplicateMarked)
        #expect(preferences.localAutomationAuthors.count == 1)
        let entry = try #require(preferences.localAutomationAuthors.first)
        let removedForOtherAccount = preferences.unmarkAutomationAuthor(entry.id, host: identity.host, username: "other")
        #expect(!removedForOtherAccount)
        let removedForOtherHost = preferences.unmarkAutomationAuthor(entry.id, host: "other.example.org", username: "me")
        #expect(!removedForOtherHost)
        let removed = preferences.unmarkAutomationAuthor(entry.id, host: identity.host, username: "me")
        #expect(removed)
        #expect(preferences.botIDs(host: identity.host, username: "me").isEmpty)
        #expect(preferences.revision(host: identity.host, username: "me").isEmpty)
    }

    @Test(arguments: ["zero", "negative", "self", "wrongHost", "emptyHost", "emptyAccount", "invalidAccountID", "emptyLabel"])
    func invalidOrOwnIdentitiesCannotBeDeclaredAutomation(_ scenario: String) {
        var preferences = ReviewParticipationPreferences()
        let host = scenario == "emptyHost" ? "" : "gitlab.example.org"
        let identity = PublicationIdentity(host: scenario == "wrongHost" ? "other.example.org" : host,
            entityID: scenario == "zero" ? 0 : scenario == "negative" ? -1 : scenario == "self" ? 3 : 99,
            label: scenario == "emptyLabel" ? " " : "@automation-author")
        let user = GitLabAuthenticatedUser(id: scenario == "invalidAccountID" ? 0 : 3,
            username: scenario == "emptyAccount" ? " " : "me")
        let marked = preferences.markAutomationAuthor(identity, host: host, user: user)
        #expect(!marked)
        #expect(preferences.localAutomationAuthors.isEmpty)
    }

    @Test func localAutomationDesignationDoesNotOverrideACommunicationExclusion() throws {
        var preferences = ReviewParticipationPreferences()
        let identity = PublicationIdentity(host: "gitlab.example.org", entityID: 99, label: "@automation-author")
        let user = GitLabAuthenticatedUser(id: 3, username: "me")
        let excluded = preferences.exclude(identity, username: "me")
        #expect(excluded)
        let marked = preferences.markAutomationAuthor(identity, host: identity.host, user: user)
        #expect(marked)
        #expect(preferences.revision(host: identity.host, username: "me") == "99|bots:99")
        let discussions = [GitLabMergeRequestDiscussion(id: "excluded", notes: [
            .init(id: 10, author: .init(id: 99, username: "automation-author", name: "Automation"), system: false,
                resolvable: true, resolved: false, resolvedBy: nil, body: "A technical finding")])]
        let draft = GitLabDraftNote(id: 12, authorID: 3, note: "Reply", discussionID: "excluded", position: nil)
        #expect(!preferences.permitsAutomaticReply(draft, discussions: discussions, requestAuthorID: 3,
            userID: 3, host: identity.host, username: "me"))
    }

    @Test(arguments: ["write", "synchronize"])
    func failedAutomationAuthorChangesNeverExposeOrPersistUncommittedAuthority(_ failure: String) throws {
        let suite = "LocalAutomationAuthorsFailure.\(UUID())"
        let defaults = try #require(PersistenceFaultDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let identity = PublicationIdentity(host: "gitlab.example.org", entityID: 99, label: "@automation-author")
        let user = GitLabAuthenticatedUser(id: 3, username: "me")
        defaults.rejectedKey = failure == "write" ? "reviewParticipationPreferences" : nil
        defaults.synchronizationFails = failure == "synchronize"
        #expect(!settings.markAutomationAuthor(identity, host: identity.host, user: user))
        #expect(settings.reviewParticipationPreferences.localAutomationAuthors.isEmpty)
        #expect(SettingsManager(defaults: defaults).reviewParticipationPreferences.localAutomationAuthors.isEmpty)
        #expect(!settings.automaticActionsAllowed)

        defaults.rejectedKey = nil
        defaults.synchronizationFails = false
        #expect(settings.markAutomationAuthor(identity, host: identity.host, user: user))
        let entry = try #require(settings.reviewParticipationPreferences.localAutomationAuthors.first)
        defaults.rejectedKey = failure == "write" ? "reviewParticipationPreferences" : nil
        defaults.synchronizationFails = failure == "synchronize"
        #expect(!settings.unmarkAutomationAuthor(entry.id, host: identity.host, username: "me"))
        #expect(settings.reviewParticipationPreferences.botIDs(host: identity.host, username: "me") == [99])
        #expect(SettingsManager(defaults: defaults).reviewParticipationPreferences.botIDs(host: identity.host, username: "me") == [99])
        #expect(!settings.automaticActionsAllowed)
    }

    @Test func savedAutomationAuthorsRoundTripWithoutChangingAutomationPermissions() throws {
        let suite = "LocalAutomationAuthorsRoundTrip.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let automation = settings.automation
        let identity = PublicationIdentity(host: "gitlab.example.org", entityID: 99, label: "@automation-author")
        let user = GitLabAuthenticatedUser(id: 3, username: "me")
        #expect(settings.markAutomationAuthor(identity, host: identity.host, user: user))
        let restored = SettingsManager(defaults: defaults)
        #expect(restored.reviewParticipationPreferences.botIDs(host: identity.host, username: "me") == [99])
        #expect(restored.automation == automation)
        let entry = try #require(restored.reviewParticipationPreferences.localAutomationAuthors.first)
        #expect(!restored.unmarkAutomationAuthor(entry.id, host: identity.host, username: "other"))
        #expect(restored.unmarkAutomationAuthor(entry.id, host: identity.host, username: "me"))
        #expect(SettingsManager(defaults: defaults).reviewParticipationPreferences.localAutomationAuthors.isEmpty)
    }

    @Test func persistedAutomationAuthorsInvalidateTheScopedRevisionWithoutChangingContactExclusions() throws {
        let suite = "LocalAutomationAuthorsRevision.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func entry(_ id: Int, _ label: String) -> [String: Any] {
            ["id": UUID().uuidString, "host": "gitlab.example.org", "username": "me",
             "reviewerID": id, "label": label]
        }
        let encoded = try JSONSerialization.data(withJSONObject: [
            "entries": [entry(7, "@excluded")],
            "localAutomationAuthors": [entry(99, "@automation-author")]
        ])
        defaults.set(encoded, forKey: "reviewParticipationPreferences")

        let restored = SettingsManager(defaults: defaults)
        let preferences = restored.reviewParticipationPreferences
        #expect(preferences.revision(host: "gitlab.example.org", username: "me") == "7|bots:99")
        #expect(preferences.excludedIDs(host: "gitlab.example.org", username: "me") == [7])
        #expect(preferences.revision(host: "gitlab.example.org", username: "other").isEmpty)
        #expect(preferences.revision(host: "other.example.org", username: "me").isEmpty)
    }

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
