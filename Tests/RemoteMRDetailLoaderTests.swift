import Foundation
import Testing
import MergeTetherRemote
@testable import GitLabTodos

@MainActor @Suite struct RemoteMRDetailLoaderTests {
    @Test(arguments: ["approved", "reset", "commented", "own"])
    func detailApprovalsIdentifyOnlyTheViewersCurrentOrResetApproval(_ scenario: String) throws {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.utf8))
        let viewer = Todo.Author(id: 7, username: "me", name: "Signed-in reviewer", avatarURL: nil)
        let other = Todo.Author(id: 9, username: "other", name: "Other reviewer", avatarURL: nil)
        let progress = try #require(MergeRequestApprovalProgress(completed: scenario == "approved" ? 2 : 1,
            required: 2, approvedBy: scenario == "approved" ? [other, viewer] : [other]))
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: JSONSerialization.data(withJSONObject: [
            ["id": "thread", "notes": [["id": 12, "author": ["id": 7, "username": "me", "name": "Signed-in reviewer"],
                "system": scenario == "reset", "body": scenario == "reset" ? "approved this merge request" : "Please check the retry"]]]
        ]))
        let details = RemoteMRDetailLoader.project(request: request, progress: progress, rules: nil, reviewers: [],
            discussions: discussions, drafts: [], username: scenario == "own" ? "owner" : "me")
        let approvals = try #require(details.approvals)
        #expect(approvals.viewerApprovalID == (["approved", "reset"].contains(scenario) ? 7 : nil))
        if scenario == "approved" || scenario == "reset" {
            #expect(approvals.orderedPeople.first?.id == 7)
            #expect(approvals.viewerApproval?.status == (scenario == "approved" ? .approved : .previouslyApproved))
        }
        if scenario == "commented" { #expect(approvals.people.first { $0.id == 7 }?.status == .commented) }
    }

    @Test func phoneThreadsIdentifyTheirDraftRepliesWithoutMixingOtherThreads() throws {
        // given
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.utf8))
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(#"[{"id":"first","notes":[{"id":1,"body":"First concern","system":false}]},{"id":"second","notes":[{"id":2,"body":"Different concern","system":false}]}]"#.utf8))
        let drafts = [
            GitLabDraftNote(id: 11, authorID: 3, note: "First reply", discussionID: "first", position: nil),
            GitLabDraftNote(id: 12, authorID: 3, note: "Second reply", discussionID: "first", position: nil),
            GitLabDraftNote(id: 13, authorID: 3, note: "Other thread", discussionID: "second", position: nil),
            GitLabDraftNote(id: 14, authorID: 3, note: "New comment", discussionID: nil, position: nil),
            GitLabDraftNote(id: 15, authorID: 3, note: "Unavailable thread", discussionID: "missing", position: nil)
        ]

        // when
        let details = RemoteMRDetailLoader.project(request: request, progress: nil, rules: nil, reviewers: nil,
            discussions: discussions, drafts: drafts, username: "owner")
        let data = try JSONEncoder().encode(details)
        let wire = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let threads = try #require(wire["threads"] as? [[String: Any]])

        // then
        #expect(threads[0]["draftIDs"] as? [Int] == [11, 12])
        #expect(threads[1]["draftIDs"] as? [Int] == [13])
        #expect(details.threads?.first?.notes.first?.body == "First concern")
        #expect(details.threads?.first?.draftCount == 2)
    }

    @Test(arguments: ["informational", "newRequest", "partial", "draft", "otherAccount", "stale"])
    func phoneReplyStatusReflectsVerifiedCoverageRatherThanTheLastSpeaker(_ scenario: String) throws {
        let notes = [RemoteDetailNote(id: "11", username: "reviewer", body: "Fix retry", authorID: 7),
            RemoteDetailNote(id: "12", username: "owner", body: "Fixed retry; the new retry would duplicate work", authorID: 3),
            RemoteDetailNote(id: "13", username: "reviewer", body: scenario == "newRequest" ? "Fix timeout too" : "Super", authorID: 7)]
        var details = RemoteMRDetails(checkedAt: .now, threads: [.init(id: "thread", state: .general, notes: notes,
            reply: .earlier, draftCount: scenario == "draft" ? 1 : 0)])
        let assessment = ReReviewAssessment(notes: [
            .init(noteID: 11, state: .rejected, reason: "Supported rejection", publishedReplyNoteID: scenario == "partial" ? nil : 12),
            .init(noteID: 13, state: scenario == "newRequest" ? .addressed : .informational, reason: "Current concern assessed")])
        RemoteMRDetailSupplement.applyFeedback(to: &details, assessment: scenario == "stale" ? nil : assessment,
            authorID: 3, currentUsername: scenario == "otherAccount" ? "someoneElse" : "owner")
        let thread = try #require(details.threads?.first)
        #expect(thread.showsPublishedReply == (scenario == "informational"))
        #expect(thread.feedback == (scenario == "stale" ? nil : .addressed))
        #expect(thread.draftCount == (scenario == "draft" ? 1 : 0))
    }

    @Test func phoneAuthorIdentityRoundTripsSeparatelyFromTextOrigin() throws {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.utf8))
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
            from: Data(#"[{"id":"thread","notes":[{"id":1,"author":{"id":7,"username":"reviewer"},"system":false,"body":"AI-assisted human feedback"},{"id":2,"author":{"id":8,"username":"automation"},"system":false,"body":"Deterministic automation output"}]}]"#.utf8))
        let details = RemoteMRDetailLoader.project(request: request, progress: nil, rules: nil, reviewers: nil,
            discussions: discussions, origins: [1: .assessed(evidence: "AI text"), 2: .humanLikely(evidence: "Manual text")],
            drafts: [], username: "owner", authorKinds: [7: .regular, 8: .automation])
        let notes = try #require(details.threads?.first?.notes)
        #expect(notes[0].authorKind == .regular && notes[0].origin == .ai)
        #expect(notes[1].authorKind == .automation && notes[1].origin == .human)
        let encoded = try JSONEncoder().encode(notes[1])
        let decoded = try JSONDecoder().decode(RemoteDetailNote.self, from: encoded)
        #expect(decoded.authorKind == .automation && decoded.origin == .human)
        let legacy = try JSONDecoder().decode(RemoteDetailNote.self, from: Data(#"{"id":"1","body":"Earlier client","origin":"ai"}"#.utf8))
        #expect(legacy.authorKind == nil && legacy.origin == .ai)
    }

    @Test(arguments: ["unknown", "uncertain", "human", "manualHuman"])
    func botMachineDisplayPreservesTheUnderlyingTextOriginAndPublicationPermission(_ classification: String) throws {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.utf8))
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
            from: Data(#"[{"id":"thread","notes":[{"id":2,"author":{"id":8,"username":"automation"},"system":false,"body":"Pipeline completed successfully"}]}]"#.utf8))
        let origins: [Int: MRDiscussionSnapshot.Origin]
        switch classification {
        case "uncertain": origins = [2: .uncertain(evidence: "No text authorship evidence")]
        case "human": origins = [2: .humanLikely(evidence: "Conversational text assessment")]
        case "manualHuman": origins = [2: .manual(.human)]
        default: origins = [:]
        }
        let details = RemoteMRDetailLoader.project(request: request, progress: nil, rules: nil, reviewers: nil,
            discussions: discussions, origins: origins, drafts: [], username: "owner", authorKinds: [8: .automation])
        let note = try #require(details.threads?.first?.notes.first)
        let rawOrigin: RemoteDetailNote.Origin? = classification == "unknown" ? nil
            : classification == "uncertain" ? .uncertain : .human
        #expect(note.origin == rawOrigin)
        #expect(note.authorKind == .automation)
        #expect(note.displayOrigin == .ai)
        #expect(details.threads?.first?.origin == .ai)
        let roundTrip = try JSONDecoder().decode(RemoteDetailNote.self, from: JSONEncoder().encode(note))
        #expect(roundTrip.origin == rawOrigin && roundTrip.displayOrigin == note.displayOrigin)
        let draft = GitLabDraftNote(id: 11, authorID: 3, note: "Checked", discussionID: "thread", position: nil)
        let policy = AutomaticPublicationPolicy(mode: .aiReplies, restrictions: .init(allowBotReplies: false))
        #expect(!policy.allows(draft, request: request, discussions: discussions, userID: 3,
            host: "gitlab.example.test", aiNoteIDs: [], botNoteIDs: [2]))
        let comment = try #require(discussions.first?.notes.first)
        #expect(!AICommentAssessmentStore.isAI(comment, host: "gitlab.example.test", projectID: 1, iid: 2,
            in: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)))
    }

    @Test func automationStatusMirrorsTheMacPanelForOpenMRsOnly() throws {
        let suiteName = "RemoteAutomationStatus-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsManager(defaults: defaults)
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "owner", projectID: 1, iid: 2)
        let ready = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.utf8))
        let draft = try JSONDecoder().decode(GitLabMergeRequest.self,
            from: Data(raw.replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#).utf8))
        let closed = try JSONDecoder().decode(GitLabMergeRequest.self,
            from: Data(raw.replacingOccurrences(of: #""state":"opened""#, with: #""state":"closed""#).utf8))
        settings.automation.applyPreset(.manual, for: .codex)
        #expect(RemoteMRDetailSupplement.automationStatus(settings: settings, target: target, request: ready) == nil)

        settings.automation.applyPreset(.full, for: .codex)
        let source = { (label: LocalizedStringResource) in
            String(localized: .Menu.menuScopePopoverSource(String(localized: label)))
        }
        #expect(RemoteMRDetailSupplement.automationStatus(settings: settings, target: target, request: ready)
            == .init(active: true, summary: String(localized: .Menu.menuScopeActive) + " · " + source(.Menu.menuScopeSourceGlobal)))
        #expect(RemoteMRDetailSupplement.automationStatus(settings: settings, target: target, request: draft)
            == .init(active: false, summary: String(localized: .Menu.menuScopePaused) + " · " + source(.Menu.menuScopeSourceDraft)))
        settings.automation.scope.setManualChoice(.paused, for: target)
        #expect(RemoteMRDetailSupplement.automationStatus(settings: settings, target: target, request: ready)?.active == false)
        #expect(RemoteMRDetailSupplement.automationStatus(settings: settings, target: target, request: closed) == nil)
    }

    @Test func extraContextReachesThePhoneOnlyForMatchingDraftsAndNotes() throws {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.utf8))
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
            from: Data(#"[{"id":"thread","notes":[{"id":1,"author":{"id":7,"username":"reviewer"},"system":false,"body":"Concern"},{"id":2,"author":{"id":4,"username":"owner"},"system":false,"body":"Generated reply"}]}]"#.utf8))
        let current = GitLabDraftNote(id: 11, authorID: 4, note: "Generated draft", discussionID: "thread", position: nil)
        let edited = GitLabDraftNote(id: 12, authorID: 4, note: "Edited by the user", discussionID: "thread", position: nil)
        var contexts = AICommentProvenanceStore.ExtraContexts()
        contexts.drafts[11] = .init(bodySHA256: AICommentAssessmentStore.digest("Generated draft"), markdown: "Draft background",
            proposedSolution: true)
        contexts.drafts[12] = .init(bodySHA256: AICommentAssessmentStore.digest("Generated draft"), markdown: "Stale background",
            proposedSolution: true)
        contexts.notes[2] = .init(bodySHA256: AICommentAssessmentStore.digest("Generated reply"), markdown: "Published background",
            proposedSolution: true)
        let details = RemoteMRDetailLoader.project(request: request, progress: nil, rules: nil, reviewers: nil,
            discussions: discussions, origins: [2: .appGenerated], drafts: [current, edited], username: "owner",
            extraContexts: contexts)
        #expect(details.draftContexts == ["11": "Draft background"])
        #expect(details.proposedSolutionDraftIDs == [11])
        let notes = try #require(details.threads?.first?.notes)
        #expect(notes[0].extraContext == nil && notes[1].extraContext == "Published background")
        #expect(notes[0].proposedSolution == nil && notes[1].proposedSolution == true)
        let none = RemoteMRDetailLoader.project(request: request, progress: nil, rules: nil, reviewers: nil,
            discussions: discussions, drafts: [current], username: "owner")
        #expect(none.draftContexts == nil && none.proposedSolutionDraftIDs == nil)
    }

    @Test func currentFeedbackProjectionKeepsAssessmentSeparateFromRepliesAndResolution() throws {
        let note = RemoteDetailNote(id: "11", author: "Reviewer", body: "Concern", origin: .human, authorID: 7)
        let reply = RemoteDetailNote(id: "12", author: "Owner", username: "owner", body: "Done", origin: .ai, authorID: 3)
        var details = RemoteMRDetails(checkedAt: .now, threads: [.init(id: "thread", state: .resolved,
            notes: [note, reply], reply: .published, draftCount: 1)])
        RemoteMRDetailSupplement.applyFeedback(to: &details, assessment: nil, authorID: 3, currentUsername: "owner")
        #expect(details.threads?.first?.feedback == nil)
        #expect(details.threads?.first?.reply == .unknown)
        let assessment = ReReviewAssessment(notes: [.init(noteID: 11, state: .addressed, reason: "Verified current source",
            publishedReplyNoteID: 12)])
        RemoteMRDetailSupplement.applyFeedback(to: &details, assessment: assessment, authorID: 3, currentUsername: "owner")
        #expect(details.threads?.first?.feedback == .addressed)
        #expect(details.threads?.first?.reply == .published && details.threads?.first?.draftCount == 1)
        #expect(details.threads?.first?.origin == nil)
        RemoteMRDetailSupplement.applyFeedback(to: &details, assessment: nil, authorID: 3)
        #expect(details.threads?.first?.feedback == nil)
    }

    private let raw = #"{"project_id":1,"iid":2,"author":{"id":3,"username":"owner","name":"Owner"},"title":"Feature","description":"Complete MR description","labels":[],"web_url":"https://gitlab.example.test/g/p/-/merge_requests/2","state":"opened","draft":false,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_project_id":1,"target_project_id":1,"source_branch":"feature","target_branch":"main","detailed_merge_status":"mergeable","has_conflicts":false,"reviewers":[{"id":8,"username":"assigned","name":"Assigned"}]}"#

    @Test func detailsIncludeMetadataAllUniqueApproversRulesAndOrderedDiscussionsUsingOnlyReads() async throws {
        let f = InMemoryGitLab(); defer { f.close() }
        let glab = f.service(host: "gitlab.example.test", username: "me")
        let source = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.utf8))
        f.handler = { request in
            if request.endpoint == "/user" { return InMemoryGitLab.output(#"{"id":4,"username":"me"}"#) }
            if request.endpoint.hasSuffix("/approvals") {
                return InMemoryGitLab.output(#"{"approvals_required":2,"approvals_left":1,"approved_by":[{"user":{"id":5,"username":"approved","name":"Approved"}},{"user":{"id":5,"username":"approved","name":"Approved"}},{"user":{"id":6,"username":"second","name":"Second"}},{"user":{"id":7,"username":"third","name":"Third"}}]}"#)
            }
            if request.endpoint.hasSuffix("/approval_state") {
                return InMemoryGitLab.output(#"{"rules":[{"id":1,"name":"Security","approvals_required":1,"approved":false,"approved_by":[]},{"id":2,"name":"Owners","approvals_required":1,"approved":true,"approved_by":[{"username":"approved"}]}]}"#)
            }
            if request.endpoint.contains("/reviewers?") { return InMemoryGitLab.output("[]") }
            if request.endpoint.contains("/discussions?") {
                return InMemoryGitLab.output(#"[{"id":"general","notes":[{"id":10,"author":{"id":8,"username":"assigned"},"system":false,"body":"General note"}]},{"id":"resolved","notes":[{"id":11,"author":{"id":8,"username":"assigned"},"system":false,"resolvable":true,"resolved":true,"body":"Resolved concern"}]},{"id":"open","notes":[{"id":12,"author":{"id":8,"username":"assigned"},"system":false,"resolvable":true,"resolved":false,"body":"Open concern"},{"id":13,"author":{"id":4,"username":"me"},"system":false,"body":"Published reply"}]}]"#)
            }
            return InMemoryGitLab.output(self.raw)
        }
        let details = try await RemoteMRDetailLoader.load(source: source, drafts: [], glab: glab)
        #expect(details.description == "Complete MR description")
        #expect(details.branches == .init(source: "feature", target: "main"))
        #expect(details.metadata.contains { $0.value == "feature" })
        #expect(details.metadata.contains { $0.value == "main" })
        #expect(details.approvals?.progress?.received == 3)
        #expect(details.approvals?.requirementsSatisfied == false)
        #expect(details.approvals?.people.map(\.id) == [5, 6, 7, 8, 4])
        let replyAuthor = try #require(details.approvals?.people.first { $0.id == 4 })
        #expect(replyAuthor.username == "me")
        #expect(replyAuthor.status == .commented)
        #expect(details.approvals?.rules?.map(\.name) == ["Security", "Owners"])
        #expect(details.threads?.map(\.state) == [.open, .resolved, .general])
        #expect(details.threads?.first?.reply == .unknown)
        #expect(details.threads?.first?.showsPublishedReply == false)
        #expect(details.threads?.first?.notes.map(\.body) == ["Open concern", "Published reply"])
        #expect(f.requests.allSatisfy { $0.method == "GET" })
    }

    @Test func unavailableRulesAndDiscussionsRemainUnknownWithoutDiscardingMetadata() async throws {
        let f = InMemoryGitLab(); defer { f.close() }
        let glab = f.service(host: "gitlab.example.test", username: "me")
        let source = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.utf8))
        f.handler = { request in
            if request.endpoint == "/user" { return InMemoryGitLab.output(#"{"id":4,"username":"me"}"#) }
            if request.endpoint.hasSuffix("/2") { return InMemoryGitLab.output(self.raw) }
            return InMemoryGitLab.output("Forbidden", code: 1)
        }
        let details = try await RemoteMRDetailLoader.load(source: source, drafts: [], glab: glab)
        #expect(details.description == source.description)
        #expect(details.approvals?.progress == nil)
        #expect(details.approvals?.rules == nil)
        #expect(details.approvals?.requirementsSatisfied == nil)
        #expect(details.threads == nil)
        #expect(details.approvals?.historyAvailable == false)
        #expect(details.approvals?.people.first?.status == .assigned)
    }

    @Test(arguments: ["head", "target", "description", "account", "account-roundtrip"])
    func changingContextDuringTheReadRejectsTheResult(_ change: String) async throws {
        let f = InMemoryGitLab(); defer { f.close() }
        let glab = f.service(host: "gitlab.example.test", username: "me")
        let source = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.utf8))
        var reads = 0
        f.handler = { request in
            if request.endpoint == "/user" { return InMemoryGitLab.output(#"{"id":4,"username":"me"}"#) }
            if request.endpoint.hasSuffix("/2") {
                reads += 1
                if reads == 2 {
                    if change.hasPrefix("account") { glab.currentUsername = "other" }
                    if change == "account-roundtrip" { glab.currentUsername = "me" }
                    var fields = try #require(JSONSerialization.jsonObject(with: Data(self.raw.utf8)) as? [String: Any])
                    if !change.hasPrefix("account") { fields[change == "head" ? "sha" : change == "target" ? "target_branch" : "description"] = "changed" }
                    return try InMemoryGitLab.json(fields)
                }
                return InMemoryGitLab.output(self.raw)
            }
            return InMemoryGitLab.output("Unavailable", code: 1)
        }
        await #expect(throws: (any Error).self) {
            try await RemoteMRDetailLoader.load(source: source, drafts: [], glab: glab)
        }
    }

    @Test func missingRuleApprovalIsUnknownAndOriginBadgesRequireCurrentNoteEvidence() throws {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.utf8))
        let rules = try JSONDecoder().decode(RemoteApprovalRuleState.self,
            from: Data(#"{"rules":[{"id":1,"name":"Security","approvals_required":1}]}"#.utf8))
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
            from: Data(#"[{"id":"thread","notes":[{"id":10,"body":"Source","system":false},{"id":11,"body":"Reply","system":false}]}]"#.utf8))
        let details = RemoteMRDetailLoader.project(request: request, progress: nil, rules: rules,
            reviewers: nil, discussions: discussions, origins: [10: .appGenerated], drafts: [], username: "me")
        #expect(details.approvals?.requirementsSatisfied == nil)
        #expect(details.approvals?.rules?.first?.approved == nil)
        #expect(details.threads?.first?.notes.map(\.origin) == [.ai, nil])
    }
}
