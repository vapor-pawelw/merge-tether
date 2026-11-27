import Foundation
import Testing
@testable import MergeTether

struct AutomaticPublicationPolicyTests {
    @Test func aCoAssigneesPublishedReplySuppressesOnlyTheDuplicate() throws {
        let request = try request(assignees: #"[{"id":7,"username":"alice","name":"Alice"},{"id":4,"username":"bob","name":"Bob"}]"#)
        let discussions = [GitLabMergeRequestDiscussion(id: "thread", notes: [
            note(10, author: 3), note(11, author: 4, body: "Already  addressed")
        ])]
        let policy = AutomaticPublicationPolicy(mode: .all, restrictions: .init())
        #expect(try !policy.allows(draft(body: "Already addressed", authorID: 7), request: request,
            discussions: discussions, userID: 7, host: host, aiNoteIDs: []))
        #expect(try policy.allows(draft(body: "I also covered the empty case", authorID: 7), request: request,
            discussions: discussions, userID: 7, host: host, aiNoteIDs: []))
    }

    @Test func publishAllIgnoresDormantFiltersForAGenuineAuthorReply() throws {
        let request = try request()
        let reply = try draft(authorID: request.author.id)
        let incoming = GitLabMergeRequestDiscussion(id: "thread", notes: [note(10, author: 3)])
        let restrictions = AutomaticPublicationRestrictions(sourceCommentAuthors: [identity(999)], requireAI: true)
        let all = AutomaticPublicationPolicy(mode: .all, restrictions: restrictions)
        let filtered = AutomaticPublicationPolicy(mode: .filtered, restrictions: restrictions)

        #expect(all.allows(reply, request: request, discussions: [incoming], userID: request.author.id, host: host, aiNoteIDs: []))
        #expect(!filtered.allows(reply, request: request, discussions: [incoming], userID: request.author.id, host: host, aiNoteIDs: []))
    }

    @Test(arguments: [AutomationPublicationMode.all, .filtered, .aiReplies])
    func authorStatusNotesStayPrivateWhileIncomingFeedbackRepliesRemainEligible(_ mode: AutomationPublicationMode) throws {
        let request = try request()
        let policy = AutomaticPublicationPolicy(mode: mode, restrictions: .init(requireAI: true))
        let status = try draft(reply: false, authorID: request.author.id)
        let reply = try draft(authorID: request.author.id)
        let incoming = GitLabMergeRequestDiscussion(id: "thread", notes: [note(10, author: 3)])

        #expect(!policy.couldAllow(status, request: request, userID: request.author.id, host: host))
        #expect(!policy.allows(status, request: request, discussions: [], userID: request.author.id, host: host, aiNoteIDs: []))
        #expect(policy.allows(reply, request: request, discussions: [incoming], userID: request.author.id, host: host, aiNoteIDs: [10]))
        #expect(!policy.allows(reply, request: request,
            discussions: [.init(id: "thread", notes: [note(10, author: request.author.id)])],
            userID: request.author.id, host: host, aiNoteIDs: [10]))
        #expect(DraftPublicationSelection(selectingAll: [status]).selectedDrafts(from: [status]) == [status])
    }

    let host = "gitlab.example.test"
    func identity(_ id: Int, host: String = "gitlab.example.test", label: String = "Label") -> PublicationIdentity {
        .init(host: host, entityID: id, label: label)
    }
    func request(assignees: String = "[]") throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":7,"username":"alice","name":"Alice"},"assignees":\#(assignees),"title":"MR","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"abc","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
    }
    func draft(reply: Bool = true, body: String = "Addressed", authorID: Int = 3) throws -> GitLabDraftNote {
        let json: [String: Any] = ["id": 9, "author_id": authorID, "note": body,
                                   "discussion_id": reply ? "thread" as Any : NSNull()]
        return try JSONDecoder().decode(GitLabDraftNote.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func note(_ id: Int?, author: Int?, body: String = "Feedback") -> GitLabMergeRequestDiscussion.Note {
        .init(id: id, author: author.map { .init(id: $0, username: "user\($0)", name: nil) },
              system: false, resolvable: true, resolved: false, resolvedBy: nil, body: body)
    }
    func allows(_ policy: AutomaticPublicationPolicy, reply: Bool = true,
                notes: [GitLabMergeRequestDiscussion.Note]? = nil, ai: Set<Int> = [], bots: Set<Int> = [],
                body: String = "Addressed", authorID: Int = 3) throws -> Bool {
        // These fixtures exercise publication filters with the separate thread permission granted.
        var optedIn = policy
        optedIn.allowsOtherReviewThreadReplies = true
        return optedIn.allows(try draft(reply: reply, body: body, authorID: authorID), request: try request(),
                              discussions: notes.map { [.init(id: "thread", notes: $0)] },
                              userID: 3, host: host, aiNoteIDs: ai, botNoteIDs: bots)
    }

    @Test(arguments: [AutomationPublicationMode.aiReplies, .filtered])
    func verifiedBotsCanQualifyIndependentlyOfAIWhenExplicitlyEnabled(_ mode: AutomationPublicationMode) throws {
        var restrictions = AutomaticPublicationRestrictions()
        restrictions.allowBotReplies = true
        restrictions.requireAI = true
        let policy = AutomaticPublicationPolicy(mode: mode, restrictions: restrictions)
        let notes = [note(40, author: 8), note(41, author: 9)]
        #expect(try allows(policy, notes: notes, ai: [40], bots: [41]))
        #expect(try !allows(policy, notes: notes, bots: [40]))
        #expect(try !allows(policy, notes: notes, ai: [40]))
        #expect(try !allows(policy, notes: notes))
        restrictions.allowBotReplies = false
        #expect(try !allows(.init(mode: mode, restrictions: restrictions), notes: notes, ai: [40], bots: [41]))
    }

    @Test func botOnlyConditionRequiresVerifiedBotSourcesAndNeverGeneralComments() throws {
        var restrictions = AutomaticPublicationRestrictions()
        restrictions.allowBotReplies = true
        let policy = AutomaticPublicationPolicy(mode: .filtered, restrictions: restrictions)
        #expect(try allows(policy, notes: [note(40, author: 8)], bots: [40]))
        #expect(try !allows(policy, notes: [note(40, author: 8)], ai: [40]))
        #expect(try !allows(policy, notes: [note(40, author: 8), note(41, author: 9)], bots: [40]))
        #expect(try !allows(policy, reply: false, bots: [40]))
        #expect(try !allows(policy, bots: [40]))
        #expect(try !allows(.init(mode: .manual, restrictions: restrictions), notes: [note(40, author: 8)], bots: [40]))
    }

    @Test func botPermissionCannotBypassIdentityFiltersDraftOwnershipOrQuickActions() throws {
        var restrictions = AutomaticPublicationRestrictions()
        restrictions.allowBotReplies = true
        restrictions.repositories = [identity(1)]
        restrictions.mergeRequestAuthors = [identity(7)]
        restrictions.sourceCommentAuthors = [identity(8)]
        let notes = [note(40, author: 8)]
        #expect(try allows(.init(mode: .aiReplies, restrictions: restrictions), notes: notes, bots: [40]))
        #expect(try !allows(.init(mode: .aiReplies, restrictions: restrictions), notes: notes, bots: [40], authorID: 99))
        #expect(try !allows(.init(mode: .aiReplies, restrictions: restrictions), notes: notes, bots: [40], body: "/merge"))
        restrictions.sourceCommentAuthors = [identity(9)]
        #expect(try !allows(.init(mode: .aiReplies, restrictions: restrictions), notes: notes, bots: [40]))
        restrictions.sourceCommentAuthors = [identity(8)]
        restrictions.repositories = [identity(1, host: "other.example")]
        #expect(try !allows(.init(mode: .aiReplies, restrictions: restrictions), notes: notes, bots: [40]))
        restrictions.repositories = [identity(1)]
        restrictions.mergeRequestAuthors = [identity(9)]
        #expect(try !allows(.init(mode: .aiReplies, restrictions: restrictions), notes: notes, bots: [40]))
    }

    @Test(arguments: [AutomationPublicationMode.all, .aiReplies])
    func resolvedDiscussionDoesNotReceiveAnAutomaticDraftReply(_ mode: AutomationPublicationMode) throws {
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data("""
            [{"id":"thread","notes":[{"id":40,"author":{"id":8},"body":"Earlier finding",
              "system":false,"resolvable":true,"resolved":true}]}]
            """.utf8))
        let policy = AutomaticPublicationPolicy(mode: mode, restrictions: .init(), allowsOtherReviewThreadReplies: true)
        #expect(try !policy.allows(draft(), request: request(), discussions: discussions, userID: 3, host: host, aiNoteIDs: [40]))
    }

    @Test(arguments: [AutomationPreset.manual, .safe, .trusted, .full])
    func onlyMaxAutomaticallyPublishesRepliesInOtherReviewersThreadsByDefault(_ preset: AutomationPreset) throws {
        var settings = AutomationSettings()
        settings.applyPreset(preset, for: .codex)
        let policy = settings.automaticPublicationPolicy
        let request = try request()
        let reply = try draft()
        let foreignThread = GitLabMergeRequestDiscussion(id: "thread", notes: [note(40, author: 8), note(41, author: 3), note(42, author: 8)])
        let ownThread = GitLabMergeRequestDiscussion(id: "thread", notes: [note(40, author: 3), note(42, author: 8)])

        #expect(policy.allows(reply, request: request, discussions: [foreignThread], userID: 3, host: host, aiNoteIDs: [42]) == (preset == .full))
        #expect(policy.allows(reply, request: request, discussions: [ownThread], userID: 3, host: host, aiNoteIDs: [42]) == (preset == .trusted || preset == .full))
    }

    @Test(arguments: [AutomationPublicationMode.all, .filtered, .aiReplies, .manual])
    func foreignThreadPermissionIsIndependentOfPublicationModeAndFilters(_ mode: AutomationPublicationMode) throws {
        var settings = AutomationSettings()
        settings.applyPreset(.trusted, for: .codex)
        settings.publicationMode = mode
        settings.publicationRestrictions = .init(requireAI: true)
        let mr = try request()
        let reply = try draft()
        let foreignThread = GitLabMergeRequestDiscussion(id: "thread", notes: [note(40, author: 8)])
        #expect(!settings.automaticPublicationPolicy.allows(reply, request: mr, discussions: [foreignThread], userID: 3, host: host, aiNoteIDs: [40]))

        settings.publishOtherReviewThreadReplies = true
        let optedIn = settings.automaticPublicationPolicy
        #expect(settings.canConfigureOtherReviewThreadPublication == (mode != .manual))
        #expect(optedIn.allows(reply, request: mr, discussions: [foreignThread], userID: 3, host: host, aiNoteIDs: [40]) == (mode != .manual))
        #expect(optedIn.allows(reply, request: mr, discussions: [foreignThread], userID: 3, host: host, aiNoteIDs: []) == (mode == .all))

        settings.allowAutomaticPublicActions = false
        #expect(!settings.canConfigureOtherReviewThreadPublication)
        settings.allowAutomaticPublicActions = true
        settings.publicationRestrictions = .init()
        #expect(settings.canConfigureOtherReviewThreadPublication == (mode == .all || mode == .aiReplies))
    }

    @Test func unrestrictedAllModePreservesGeneralDraftsButManualNeverPublishes() throws {
        #expect(try allows(.init(mode: .all, restrictions: .init()), reply: false))
        #expect(try !allows(.init(mode: .manual, restrictions: .init()), reply: false))
    }

    @Test func repositoryMRAuthorSourceAuthorAndAIConditionsAllHaveToMatch() throws {
        var restrictions = AutomaticPublicationRestrictions()
        restrictions.repositories = [identity(1)]
        restrictions.mergeRequestAuthors = [identity(7)]
        restrictions.sourceCommentAuthors = [identity(8)]
        restrictions.requireAI = true
        let notes = [note(40, author: 8)]
        #expect(try allows(.init(mode: .filtered, restrictions: restrictions), notes: notes, ai: [40]))
        #expect(try !allows(.init(mode: .filtered, restrictions: restrictions), notes: notes))
        restrictions.mergeRequestAuthors = [identity(99)]
        #expect(try !allows(.init(mode: .filtered, restrictions: restrictions), notes: notes, ai: [40]))
        restrictions.mergeRequestAuthors = [identity(7)]
        restrictions.repositories = [identity(99)]
        #expect(try !allows(.init(mode: .filtered, restrictions: restrictions), notes: notes, ai: [40]))
    }

    @Test func sameNumericIdentityOnAnotherHostCannotGrantPublication() throws {
        let restrictions = AutomaticPublicationRestrictions(mergeRequestAuthors: [identity(7, host: "other.example")])
        #expect(try !allows(.init(mode: .filtered, restrictions: restrictions), reply: false))
    }

    @Test func labelsNeverGrantIdentityPermissionsAndRenamesDoNotRevokeStableIDs() throws {
        let correct = AutomaticPublicationRestrictions(mergeRequestAuthors: [identity(7, label: "Old name")])
        #expect(try allows(.init(mode: .filtered, restrictions: correct), reply: false))
        let impostor = AutomaticPublicationRestrictions(mergeRequestAuthors: [identity(99, label: "alice")])
        #expect(try !allows(.init(mode: .filtered, restrictions: impostor), reply: false))
    }

    @Test func allExternalAuthorsInTheLatestIncomingExchangeMustQualify() throws {
        let restrictions = AutomaticPublicationRestrictions(sourceCommentAuthors: [identity(8)])
        let policy = AutomaticPublicationPolicy(mode: .filtered, restrictions: restrictions)
        #expect(try !allows(policy, notes: [note(40, author: 8), note(41, author: 9)]))
        #expect(try allows(policy, notes: [note(40, author: 9), note(41, author: 3), note(42, author: 8)]))
        #expect(try allows(policy, notes: [note(40, author: 8), note(41, author: 3)]))
    }

    @Test(arguments: [1, 2])
    func aiFeedbackRemainsTheSourceAfterOurPublishedClarifications(ownReplies: Int) throws {
        let notes = [note(40, author: 8)] + (1...ownReplies).map { note(40 + $0, author: 3) }
        let sources = AutomaticPublicationPolicy.sourceNotes(for: try draft(),
            discussions: [.init(id: "thread", notes: notes)], userID: 3)
        #expect(sources?.compactMap(\.id) == [40])
        #expect(try allows(.init(mode: .aiReplies, restrictions: .init()), notes: notes, ai: [40]))
    }

    @Test(arguments: [8, 9])
    func everyLatestIncomingCommentMustQualifyEvenAfterOurReplies(unclassifiedAuthor: Int) throws {
        let notes = [note(40, author: 8), note(41, author: 3),
                     note(42, author: unclassifiedAuthor), note(43, author: 8),
                     note(44, author: 3), note(45, author: 3)]
        let policy = AutomaticPublicationPolicy(mode: .aiReplies, restrictions: .init())
        let sources = AutomaticPublicationPolicy.sourceNotes(for: try draft(),
            discussions: [.init(id: "thread", notes: notes)], userID: 3)
        #expect(sources?.compactMap(\.id) == [42, 43])
        #expect(try !allows(policy, notes: notes, ai: [40, 43]))
        #expect(try allows(policy, notes: notes, ai: [42, 43]))
    }

    @Test func anEarlierNonqualifyingExchangeDoesNotTaintTheCurrentAIReply() throws {
        let notes = [note(38, author: 9), note(39, author: 3), note(40, author: 8),
                     note(41, author: 3), note(42, author: 3)]
        let sources = AutomaticPublicationPolicy.sourceNotes(for: try draft(),
            discussions: [.init(id: "thread", notes: notes)], userID: 3)
        #expect(sources?.compactMap(\.id) == [40])
        #expect(try allows(.init(mode: .aiReplies, restrictions: .init()), notes: notes, ai: [40]))
        #expect(try allows(.init(mode: .filtered, restrictions: .init(sourceCommentAuthors: [identity(8)])), notes: notes))
    }

    @Test func theLatestIncomingExchangeUsesNoteIDsRatherThanResponseOrder() throws {
        let notes = [note(45, author: 3), note(43, author: 8), note(38, author: 9),
                     note(41, author: 3), note(42, author: 8), note(39, author: 3), note(44, author: 3)]
        let sources = AutomaticPublicationPolicy.sourceNotes(for: try draft(),
            discussions: [.init(id: "thread", notes: notes)], userID: 3)
        #expect(Set(sources?.compactMap(\.id) ?? []) == [42, 43])
        let policy = AutomaticPublicationPolicy(mode: .aiReplies, restrictions: .init())
        #expect(try allows(policy, notes: notes, ai: [42, 43]))
        #expect(try !allows(policy, notes: notes, ai: [43]))
    }

    @Test func sourceAuthorFiltersCoverTheWholeIncomingExchangeAfterOurReplies() throws {
        let notes = [note(40, author: 8), note(41, author: 9), note(42, author: 3), note(43, author: 3)]
        let onlyOne = AutomaticPublicationRestrictions(sourceCommentAuthors: [identity(8)])
        let both = AutomaticPublicationRestrictions(sourceCommentAuthors: [identity(8), identity(9)])
        #expect(try !allows(.init(mode: .filtered, restrictions: onlyOne), notes: notes))
        #expect(try allows(.init(mode: .filtered, restrictions: both), notes: notes))
    }

    @Test func aThreadWithoutExternalCommentsCannotQualifyAsAnAIReply() throws {
        let notes = [note(40, author: 3), note(41, author: 3)]
        let sources = AutomaticPublicationPolicy.sourceNotes(for: try draft(),
            discussions: [.init(id: "thread", notes: notes)], userID: 3)
        #expect(sources?.isEmpty == true)
        #expect(try !allows(.init(mode: .aiReplies, restrictions: .init()), notes: notes))
    }

    @Test func rootDraftsCannotMatchSourceOrAIRestrictions() throws {
        #expect(try !allows(.init(mode: .filtered, restrictions: .init(sourceCommentAuthors: [identity(8)])), reply: false))
        #expect(try !allows(.init(mode: .filtered, restrictions: .init(requireAI: true)), reply: false))
        #expect(try !allows(.init(mode: .aiReplies, restrictions: .init()), reply: false))
    }

    @Test func unknownSourcesAndIncompleteIdentityFailClosed() throws {
        let policy = AutomaticPublicationPolicy(mode: .filtered, restrictions: .init(sourceCommentAuthors: [identity(8)]))
        #expect(try !allows(policy))
        #expect(try !allows(policy, notes: [note(40, author: 8), note(nil, author: nil)]))
    }

    @Test func aiOnlyAndExplicitAIRestrictionHaveIdenticalSourceRequirements() throws {
        let mode = AutomaticPublicationPolicy(mode: .aiReplies, restrictions: .init())
        let explicit = AutomaticPublicationPolicy(mode: .filtered, restrictions: .init(requireAI: true))
        let notes = [note(40, author: 8), note(41, author: 9)]
        for policy in [mode, explicit] {
            #expect(try !allows(policy, notes: notes, ai: [40]))
            #expect(try allows(policy, notes: notes, ai: [40, 41]))
        }
    }

    @Test func filtersNeverBypassDraftOwnershipOrQuickActionChecks() throws {
        let policy = AutomaticPublicationPolicy(mode: .all, restrictions: .init())
        #expect(try !allows(policy, reply: false, body: "/merge"))
        #expect(try !allows(policy, reply: false, authorID: 99))
    }

    @Test func allModeIgnoresEveryOptionalFilterButRetainsOwnershipAndQuickActionChecks() throws {
        let restrictions = AutomaticPublicationRestrictions(repositories: [identity(99)], mergeRequestAuthors: [identity(99)],
                                                            sourceCommentAuthors: [identity(99)], requireAI: true)
        let policy = AutomaticPublicationPolicy(mode: .all, restrictions: restrictions)
        #expect(try allows(policy, reply: false))
        #expect(try allows(policy, notes: [note(40, author: 8)]))
        #expect(!policy.requiresAI)
        #expect(try !allows(policy, reply: false, body: "/merge"))
        #expect(try !allows(policy, reply: false, authorID: 99))
    }

    @Test func filteredModeWithoutAnyConditionFailsClosed() throws {
        #expect(try !allows(.init(mode: .filtered, restrictions: .init()), reply: false))
        #expect(try !allows(.init(mode: .filtered, restrictions: .init()), notes: [note(40, author: 8)]))
    }

    @Test(arguments: [AutomationPublicationMode.all, .filtered, .aiReplies, .manual], [false, true])
    func onlyActivePublicationModesRequestAIAnalysis(_ mode: AutomationPublicationMode, _ retainedAI: Bool) throws {
        var settings = AutomationSettings()
        settings.publicationMode = mode
        settings.publicationRestrictions.requireAI = retainedAI
        let expected = mode == .aiReplies || (mode == .filtered && retainedAI)
        #expect(settings.needsAIAssessment == expected)
        let restored = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.needsAIAssessment == expected)
        #expect(restored.publicationRestrictions.requireAI == retainedAI && restored.publicationMode == mode)
        if mode == .manual {
            #expect(try !allows(restored.automaticPublicationPolicy, notes: [note(40, author: 8)], ai: [40]))
        }
    }

    @Test(arguments: [AutomationPackageDecision.undecided, .disabled, .enabled], [false, true])
    func explicitModeChoicesRetainDormantConditionsAndConsentAcrossReload(_ consent: AutomationPackageDecision, _ ai: Bool) throws {
        // Given custom restrictions and unrelated delivery settings.
        var settings = AutomationSettings()
        settings.packageDecision = consent
        settings.publicationRestrictions = .init(repositories: [identity(1)], mergeRequestAuthors: [identity(7)],
            sourceCommentAuthors: [identity(8)], requireAI: ai)
        settings.allowFollowUpPush = false
        settings.allowConflictPush = true
        settings.authorFeedback.promptTemplate = "Custom feedback instructions"
        let restrictions = settings.publicationRestrictions

        // When the selector visits every explicit mode, including manual with retained filters.
        for mode in [AutomationPublicationMode.all, .manual, .aiReplies, .filtered, .all] {
            settings.publicationMode = mode
            let restored = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings))

            // Then mode and future-relevant conditions survive without granting other permissions.
            #expect(restored.publicationMode == mode && restored.publicationRestrictions == restrictions)
            #expect(restored.packageDecision == consent && !restored.allowFollowUpPush && restored.allowConflictPush)
            #expect(restored.authorFeedback.promptTemplate == settings.authorFeedback.promptTemplate)
            #expect(try allows(restored.automaticPublicationPolicy, notes: [note(40, author: 8)], ai: [40]) == (mode != .manual))
            #expect(try allows(restored.automaticPublicationPolicy, reply: false) == (mode == .all))
        }
    }

    @Test func explicitFilteredModeRemainsFailClosedWhenItsLastConditionIsRemoved() throws {
        var settings = AutomationSettings()
        settings.publicationRestrictions.repositories = [identity(1)]
        settings.publicationMode = .filtered
        #expect(try allows(settings.automaticPublicationPolicy, reply: false))
        settings.publicationRestrictions.repositories = []
        let restored = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.publicationMode == .filtered)
        #expect(try !allows(restored.automaticPublicationPolicy, reply: false))
        #expect(try !allows(restored.automaticPublicationPolicy, notes: [note(40, author: 8)], ai: [40]))
    }

    @Test func editingDormantFiltersCannotChangeAnExplicitManualDecision() throws {
        var settings = AutomationSettings()
        settings.publicationMode = .manual
        settings.publicationRestrictions = .init(repositories: [identity(1)], requireAI: true)
        let restored = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.publicationMode == .manual)
        #expect(try !allows(restored.automaticPublicationPolicy, notes: [note(40, author: 8)], ai: [40]))
    }

    @Test func presetDefaultsSelectAllForFullAIForCheckpointsAndManualForManual() {
        for preset in AutomationPreset.allCases + [.manual] {
            var settings = AutomationSettings()
            settings.applyPreset(preset, for: .codex)
            #expect(settings.publishesAllComments == (preset == .full))
            #expect(settings.automaticAIReplies == (preset == .full || preset == .trusted))
            #expect(settings.publicationMode == preset.defaultPublicationMode)
            #expect(settings.publicationRestrictions == .defaults(for: preset))
        }
        #expect(AutomaticPublicationRestrictions.defaults(for: .full) == .init(requireAI: true, allowBotReplies: true))
        #expect(AutomaticPublicationRestrictions.defaults(for: .checkpoints) == .init(requireAI: true))
        #expect(AutomaticPublicationRestrictions.defaults(for: .manual) == .init())
        #expect(AutomaticPublicationRestrictions.defaults(for: nil) == .init())
    }

    @Test func disablingAllRestoresDormantAIChoiceAndIdentityConditions() throws {
        var settings = AutomationSettings()
        settings.applyPreset(.full, for: .codex)
        settings.publicationRestrictions.repositories = [identity(1)]
        settings.setPublishAllComments(false)
        #expect(settings.publicationMode == .aiReplies && settings.automaticAIReplies)
        #expect(try !allows(settings.automaticPublicationPolicy, reply: false))
        #expect(try allows(settings.automaticPublicationPolicy, notes: [note(40, author: 8)], ai: [40]))
        settings.setAutomaticAIReplies(false)
        #expect(settings.publicationMode == .filtered && settings.publicationRestrictions.allowBotReplies)
        #expect(try !allows(settings.automaticPublicationPolicy, reply: false))
        #expect(try allows(settings.automaticPublicationPolicy, notes: [note(40, author: 8)], bots: [40]))
        settings.setPublishAllComments(true)
        #expect(settings.publishesAllComments && !settings.automaticAIReplies)
        settings.setPublishAllComments(false)
        #expect(settings.publicationMode == .filtered && !settings.automaticAIReplies)
    }

    @Test(arguments: [false, true])
    func togglingAllPreservesEffectiveAIReplyChoiceWithoutStoredAICondition(legacy: Bool) throws {
        var settings: AutomationSettings
        if legacy {
            settings = try JSONDecoder().decode(AutomationSettings.self, from: Data(
                #"{"publishDraftsWithoutConfirmation":false,"publishAIRepliesWithoutConfirmation":true}"#.utf8))
        } else {
            settings = AutomationSettings()
            settings.publicationMode = .aiReplies
        }
        #expect(settings.automaticAIReplies && !settings.publicationRestrictions.requireAI)
        settings.setPublishAllComments(true)
        #expect(settings.publishesAllComments && settings.automaticAIReplies)
        settings.setPublishAllComments(false)
        #expect(settings.publicationMode == .aiReplies && settings.automaticAIReplies)
    }

    @Test func changingAIOrRemovingTheLastIdentityConditionCannotGrantPublishAll() {
        var settings = AutomationSettings()
        settings.applyPreset(.manual, for: .codex)
        settings.setAutomaticAIReplies(true)
        #expect(settings.publicationMode == .aiReplies && settings.needsAIAssessment)
        settings.setAutomaticAIReplies(false)
        #expect(settings.publicationMode == .manual && !settings.needsAIAssessment)
        settings.publicationRestrictions.repositories = [identity(1)]
        settings.publicationFiltersChanged()
        #expect(settings.publicationMode == .filtered)
        settings.publicationRestrictions.repositories = []
        settings.publicationFiltersChanged()
        #expect(settings.publicationMode == .manual && !settings.publishesAllComments)
    }

    @Test func legacySettingsPreserveAllFilteredAIAndExplicitManualMeanings() throws {
        let restrictions = AutomaticPublicationRestrictions(repositories: [identity(1)])
        for mode in [AutomationPublicationMode.all, .filtered, .aiReplies, .manual] {
            let values: [String: Any] = [
                "publishDraftsWithoutConfirmation": mode == .all || mode == .filtered,
                "publishAIRepliesWithoutConfirmation": mode != .manual,
                "publicationRestrictions": try JSONSerialization.jsonObject(with: JSONEncoder().encode(mode == .all ? AutomaticPublicationRestrictions() : restrictions))
            ]
            let loaded = try JSONDecoder().decode(AutomationSettings.self, from: JSONSerialization.data(withJSONObject: values))
            #expect(loaded.publicationMode == mode)
            #expect(loaded.baselinePreset == nil)
            #expect(try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(loaded)) == loaded)
        }
    }

    @Test func disablingLegacyAIOnlyConditionNeverEnablesUnconditionalPublication() throws {
        var settings = try JSONDecoder().decode(AutomationSettings.self, from: Data(
            #"{"publishDraftsWithoutConfirmation":true,"publishAIRepliesWithoutConfirmation":true,"publicationRestrictions":{"repositories":[],"mergeRequestAuthors":[],"sourceCommentAuthors":[],"requireAI":true}}"#.utf8))
        #expect(settings.publicationMode == .filtered && settings.automaticAIReplies)
        settings.setAutomaticAIReplies(false)
        #expect(settings.publicationMode == .manual && !settings.publishesAllComments)
        #expect(try !allows(settings.automaticPublicationPolicy, reply: false))
    }

    @Test func removingLegacyLastFilterOrResettingConditionsNeverEnablesPublishAll() throws {
        let json = #"{"publishDraftsWithoutConfirmation":true,"publicationRestrictions":{"repositories":[{"host":"gitlab.example.test","entityID":1,"label":"Repo"}],"mergeRequestAuthors":[],"sourceCommentAuthors":[],"requireAI":false}}"#
        var settings = try JSONDecoder().decode(AutomationSettings.self, from: Data(json.utf8))
        var reset = settings
        settings.publicationRestrictions.repositories = []
        settings.publicationFiltersChanged()
        #expect(settings.publicationMode == .manual && !settings.publishesAllComments)
        reset.resetPublicationRestrictions()
        #expect(reset.publicationMode == .manual && !reset.publishesAllComments)
    }

    @Test func resettingLegacyAllConditionsPreservesUnconditionalPublication() throws {
        var settings = try JSONDecoder().decode(AutomationSettings.self, from: Data(
            #"{"baselinePreset":"full","publishDraftsWithoutConfirmation":true,"publishAIRepliesWithoutConfirmation":false}"#.utf8))
        #expect(settings.publishesAllComments && !settings.automaticAIReplies)
        settings.resetPublicationRestrictions()
        #expect(settings.publicationMode == .all && settings.publishesAllComments)
        #expect(settings.automaticAIReplies && settings.publicationRestrictions == .defaults(for: .full))
        #expect(try allows(settings.automaticPublicationPolicy, reply: false))
    }

    @Test func savedExplicitAllIgnoresRetainedFiltersAfterReload() throws {
        var settings = AutomationSettings()
        settings.publicationRestrictions = .init(repositories: [identity(99)], requireAI: true)
        settings.publicationMode = .all
        let loaded = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings))
        #expect(loaded == settings && loaded.publicationMode == .all)
        #expect(try allows(loaded.automaticPublicationPolicy, reply: false))
    }

    @Test func automaticDraftHintUsesCanonicalModeRatherThanCompatibilityFlags() throws {
        var settings = AutomationSettings()
        settings.packageDecision = .enabled
        settings.publicationMode = .filtered
        #expect(try !settings.publishesAutomatically(any: [draft(reply: false)]))
        settings.publicationRestrictions.repositories = [identity(1)]
        #expect(try settings.publishesAutomatically(any: [draft(reply: false)]))
        settings.setAutomaticAIReplies(true)
        #expect(try !settings.publishesAutomatically(any: [draft(reply: false)]))
        #expect(try settings.publishesAutomatically(any: [draft()]))
        settings.publicationMode = .all
        #expect(!settings.needsAIAssessment)
        #expect(try settings.publishesAutomatically(any: [draft(reply: false)]))
    }

    @Test func directLegacyBooleanChangesStillUpdateCanonicalMode() {
        var settings = AutomationSettings()
        settings.publicationMode = .all
        settings.publishDraftsWithoutConfirmation = false
        settings.publishAIRepliesWithoutConfirmation = false
        #expect(settings.publicationMode == .manual)
        settings.publicationRestrictions.repositories = [identity(1)]
        settings.publishDraftsWithoutConfirmation = true
        #expect(settings.publicationMode == .filtered)
    }

    @Test func resettingPublicationOptionsPreservesOtherPermissionsScopeAndCustomInstructions() {
        var settings = AutomationSettings()
        settings.applyPreset(.full, for: .claude)
        settings.setAutomaticAIReplies(false)
        settings.setPublishAllComments(false)
        settings.publicationRestrictions.repositories = [identity(1)]
        settings.publicationFiltersChanged()
        settings.autoApproveEnabled = false
        settings.allowFollowUpPush = false
        settings.scope.mode = .selected
        settings.authorFeedback.promptTemplate = "Custom instructions"
        var expected = settings
        expected.setPublishAllComments(true)
        settings.resetPublication(to: .full)
        #expect(settings == expected && !settings.automaticAIReplies)
        expected.publicationRestrictions = .defaults(for: .full)
        settings.resetPublicationRestrictions()
        #expect(settings == expected && settings.publishesAllComments && settings.automaticAIReplies)
        settings.resetPublication(to: .checkpoints)
        #expect(settings.publicationMode == .aiReplies && !settings.autoApproveEnabled && !settings.allowFollowUpPush)
        #expect(settings.scope.mode == .selected && settings.authorFeedback.promptTemplate == "Custom instructions")
    }

    @Test(arguments: [AutomationPreset.full, .checkpoints, .manual])
    func resettingConditionsRestoresBaselineWithoutChangingGlobalAll(preset: AutomationPreset) {
        var settings = AutomationSettings()
        settings.applyPreset(preset, for: .codex)
        settings.publicationRestrictions = .init(repositories: [identity(1)], requireAI: preset == .manual)
        settings.resetPublicationRestrictions()
        #expect(settings.publicationRestrictions == .defaults(for: preset))
        #expect(settings.publishesAllComments == (preset == .full))
        #expect(settings.automaticAIReplies == (preset != .manual))
    }

    @Test func legacyConditionResetUsesUnrestrictedDefaultsAndKeepsNoInventedBaseline() {
        var settings = AutomationSettings()
        settings.publicationMode = .filtered
        settings.publicationRestrictions = .init(repositories: [identity(1)])
        settings.resetPublicationRestrictions()
        #expect(settings.publicationRestrictions == .init())
        #expect(settings.publicationMode == .manual && settings.baselinePreset == nil)
    }
}
