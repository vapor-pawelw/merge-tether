import Foundation
import Testing
@testable import GitLabTodos

struct AutomaticPublicationPolicyTests {
    let host = "gitlab.example.test"
    func identity(_ id: Int, host: String = "gitlab.example.test", label: String = "Label") -> PublicationIdentity {
        .init(host: host, entityID: id, label: label)
    }
    func request() throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":7,"username":"alice","name":"Alice"},"title":"MR","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"abc","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
    }
    func draft(reply: Bool = true, body: String = "Addressed", authorID: Int = 3) throws -> GitLabDraftNote {
        let json: [String: Any] = ["id": 9, "author_id": authorID, "note": body,
                                   "discussion_id": reply ? "thread" as Any : NSNull()]
        return try JSONDecoder().decode(GitLabDraftNote.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func note(_ id: Int?, author: Int?) -> GitLabMergeRequestDiscussion.Note {
        .init(id: id, author: author.map { .init(id: $0, username: "user\($0)", name: nil) },
              system: false, resolvable: true, resolved: false, resolvedBy: nil, body: "Feedback")
    }
    func allows(_ policy: AutomaticPublicationPolicy, reply: Bool = true,
                notes: [GitLabMergeRequestDiscussion.Note]? = nil, ai: Set<Int> = [],
                body: String = "Addressed", authorID: Int = 3) throws -> Bool {
        policy.allows(try draft(reply: reply, body: body, authorID: authorID), request: try request(),
                      discussions: notes.map { [.init(id: "thread", notes: $0)] }, userID: 3, host: host, aiNoteIDs: ai)
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
        #expect(try allows(.init(mode: .all, restrictions: restrictions), notes: notes, ai: [40]))
        #expect(try !allows(.init(mode: .all, restrictions: restrictions), notes: notes))
        restrictions.mergeRequestAuthors = [identity(99)]
        #expect(try !allows(.init(mode: .all, restrictions: restrictions), notes: notes, ai: [40]))
        restrictions.mergeRequestAuthors = [identity(7)]
        restrictions.repositories = [identity(99)]
        #expect(try !allows(.init(mode: .all, restrictions: restrictions), notes: notes, ai: [40]))
    }

    @Test func sameNumericIdentityOnAnotherHostCannotGrantPublication() throws {
        let restrictions = AutomaticPublicationRestrictions(mergeRequestAuthors: [identity(7, host: "other.example")])
        #expect(try !allows(.init(mode: .all, restrictions: restrictions), reply: false))
    }

    @Test func labelsNeverGrantIdentityPermissionsAndRenamesDoNotRevokeStableIDs() throws {
        let correct = AutomaticPublicationRestrictions(mergeRequestAuthors: [identity(7, label: "Old name")])
        #expect(try allows(.init(mode: .all, restrictions: correct), reply: false))
        let impostor = AutomaticPublicationRestrictions(mergeRequestAuthors: [identity(99, label: "alice")])
        #expect(try !allows(.init(mode: .all, restrictions: impostor), reply: false))
    }

    @Test func allExternalAuthorsSinceOurLastReplyMustQualify() throws {
        let restrictions = AutomaticPublicationRestrictions(sourceCommentAuthors: [identity(8)])
        let policy = AutomaticPublicationPolicy(mode: .all, restrictions: restrictions)
        #expect(try !allows(policy, notes: [note(40, author: 8), note(41, author: 9)]))
        #expect(try allows(policy, notes: [note(40, author: 9), note(41, author: 3), note(42, author: 8)]))
        #expect(try !allows(policy, notes: [note(40, author: 8), note(41, author: 3)]))
    }

    @Test func rootDraftsCannotMatchSourceOrAIRestrictions() throws {
        #expect(try !allows(.init(mode: .all, restrictions: .init(sourceCommentAuthors: [identity(8)])), reply: false))
        #expect(try !allows(.init(mode: .all, restrictions: .init(requireAI: true)), reply: false))
        #expect(try !allows(.init(mode: .aiReplies, restrictions: .init()), reply: false))
    }

    @Test func unknownSourcesAndIncompleteIdentityFailClosed() throws {
        let policy = AutomaticPublicationPolicy(mode: .all, restrictions: .init(sourceCommentAuthors: [identity(8)]))
        #expect(try !allows(policy))
        #expect(try !allows(policy, notes: [note(40, author: 8), note(nil, author: nil)]))
    }

    @Test func aiOnlyAndExplicitAIRestrictionHaveIdenticalSourceRequirements() throws {
        let mode = AutomaticPublicationPolicy(mode: .aiReplies, restrictions: .init())
        let explicit = AutomaticPublicationPolicy(mode: .all, restrictions: .init(requireAI: true))
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

    @Test func legacySettingsPreservePolicyAndHaveNoInventedBaseline() throws {
        let loaded = try JSONDecoder().decode(AutomationSettings.self, from: Data(#"{"publishDraftsWithoutConfirmation":false,"publishAIRepliesWithoutConfirmation":true}"#.utf8))
        #expect(loaded.baselinePreset == nil)
        #expect(loaded.publicationMode == .aiReplies && loaded.publicationRestrictions == .init())
    }

    @Test func choosingPresetRecordsResetBaselineAndClearsAdvancedRestrictions() throws {
        var settings = AutomationSettings()
        settings.publicationRestrictions.requireAI = true
        settings.applyPreset(.checkpoints, for: .codex)
        #expect(settings.baselinePreset == .checkpoints && settings.publicationRestrictions == .init())
        let loaded = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings))
        #expect(loaded.baselinePreset == .checkpoints)
    }

    @Test func resettingOneOptionDoesNotApplyTheWholePresetOrEraseOtherCustomization() {
        var settings = AutomationSettings()
        settings.applyPreset(.full, for: .codex)
        settings.publicationMode = .manual
        settings.autoApproveEnabled = false
        settings.allowFollowUpPush = false
        settings.publicationRestrictions.requireAI = true
        settings.scope.mode = .selected
        settings.resetCheckpoint(.approval, to: .full)
        #expect(settings.autoApproveEnabled)
        #expect(!settings.allowFollowUpPush && settings.publicationMode == .manual)
        #expect(settings.scope.mode == .selected && settings.publicationRestrictions.requireAI)
        settings.resetPublication(to: .full)
        #expect(settings.publicationMode == .all && !settings.allowFollowUpPush)
        #expect(settings.publicationRestrictions.requireAI)
        settings.resetPublicationRestrictions()
        #expect(settings.publicationRestrictions == .init() && settings.scope.mode == .selected)
    }
}
