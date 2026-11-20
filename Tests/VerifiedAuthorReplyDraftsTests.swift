import Foundation
import Testing
@testable import MergeTether

@MainActor
struct VerifiedAuthorReplyDraftsTests {
    @Test func aVerifiedFindingGetsOneAppDraftWithExactDurableProof() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }

        #expect(await fixture.prepare() == [10])
        let draft = try #require(try fixture.remoteDrafts().first)
        let restarted = fixture.service()
        let receipt = try #require(fixture.receipt(for: draft, using: restarted))
        #expect(receipt.sourceNoteIDs == [10])
        #expect(receipt.sourceHead == Fixture.head)
        #expect(receipt.discussionID == "finding")
        #expect(!DraftPublicationRisk.hasSideEffects(draft))
        #expect(fixture.receipt(for: draft.replacingBody("Edited reply"), using: restarted) == nil)
        #expect(await fixture.prepare(using: restarted) == [10])
        #expect(fixture.draftPosts.count == 1)
        #expect(fixture.gitlab.requests.allSatisfy { $0.method == "GET" || $0.method == "POST" })
    }

    @Test func statusAndAnExistingDraftCannotAuthorizeAnotherReply() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        #expect(await fixture.prepare(acknowledgementSafe: false).isEmpty)
        fixture.gitlab.write("drafts", #"[{"id":39,"author_id":3,"discussion_id":"finding","note":"Existing draft"}]"#)
        #expect(await fixture.prepare().isEmpty)
        #expect(fixture.draftPosts.isEmpty)
    }

    @Test func changedDiscussionOrRevokedPolicyInvalidatesProof() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        #expect(await fixture.prepare() == [10])
        let draft = try #require(try fixture.remoteDrafts().first)
        var changed = fixture.discussions
        changed[0] = .init(id: "finding", notes: [.init(id: 10, author: .init(id: 7, username: "reviewer", name: nil),
            system: false, resolvable: true, resolved: false, resolvedBy: nil, body: "An edited concern")])
        #expect(fixture.replyDrafts.receipt(for: draft, request: fixture.request, discussions: changed,
            user: Fixture.user, host: Fixture.host) == nil)
        fixture.settings.automation.allowFollowUpPush = false
        #expect(fixture.receipt(for: draft, using: fixture.replyDrafts) == nil)
    }

    @Test func aChangedBranchHeadPreventsDraftCreation() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.gitlab.write("branch", "{\"commit\":{\"id\":\"\(String(repeating: "b", count: 40))\"}}")
        #expect(await fixture.prepare().isEmpty)
        #expect(fixture.draftPosts.isEmpty)
    }

    @Test func permissionRevokedAtCommandLaunchPreventsDraftCreation() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.gitlab.beforeCommand = { [fixture] command in
            if command.method == "POST" { fixture.settings.automation.allowAutomaticPublicActions = false }
        }
        _ = await fixture.prepare()
        #expect(fixture.draftPosts.isEmpty)
        #expect(try fixture.remoteDrafts().isEmpty)
    }

    @Test func anAmbiguousWriteLeavesTheDraftPrivateAndDoesNotRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.gitlab.write("lose-create-response")

        #expect(await fixture.prepare() == [10])
        let draft = try #require(try fixture.remoteDrafts().first)
        let restarted = fixture.service()
        #expect(fixture.receipt(for: draft, using: restarted) == nil)
        #expect(await fixture.prepare(using: restarted) == [10])
        #expect(fixture.draftPosts.count == 1)
    }

    @Test func disabledPublicationStillAllowsPrivatePreparationWithAuthorFollowUpPermission() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.settings.automation.publicationMode = .manual

        #expect(await fixture.prepare() == [10])
        #expect(fixture.draftPosts.count == 1)
    }

    @Test func refreshObservingTheCreatedDraftDoesNotPreventRecordingItsProof() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        #expect(await fixture.prepare(shouldProceed: { !fixture.gitlab.has("draft-created") }) == [10])
        let draft = try #require(try fixture.remoteDrafts().first)
        #expect(fixture.receipt(for: draft, using: fixture.replyDrafts) != nil)
    }

    @MainActor
    private final class Fixture {
        static let host = "gitlab.example.test"
        static let head = String(repeating: "a", count: 40)
        static let user = GitLabAuthenticatedUser(id: 3, username: "me")
        let directory: URL
        let suite = "VerifiedAuthorReplyDraftsTests.\(UUID())"
        let defaults: UserDefaults
        let settings: SettingsManager
        let glab: GlabService
        let gitlab = InMemoryGitLab()
        let request: GitLabMergeRequest
        let discussions: [GitLabMergeRequestDiscussion]
        let replyDrafts: VerifiedAuthorReplyDrafts

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defaults = try #require(UserDefaults(suiteName: suite))
            settings = SettingsManager(defaults: defaults)
            settings.automation.packageDecision = .enabled
            settings.automation.authorFeedback.isEnabled = true
            settings.automation.allowFollowUpPush = true
            settings.automation.allowAutomaticPublicActions = true
            settings.automation.publicationMode = .aiReplies
            glab = gitlab.service(host: Self.host, username: Self.user.username)
            replyDrafts = VerifiedAuthorReplyDrafts(settings: settings, glab: glab, directory: directory)
            let requestJSON = """
                {"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},
                 "title":"Example MR","web_url":"https://\(Self.host)/group/repo/-/merge_requests/2",
                 "state":"opened","draft":false,"sha":"\(Self.head)","source_project_id":1,"source_branch":"feature",
                 "target_project_id":1,"target_branch":"main","labels":[]}
                """
            let discussionsJSON = """
                [{"id":"finding","notes":[{"id":10,"author":{"id":7,"username":"reviewer"},"system":false,
                 "body":"Fix the invalid behavior","resolvable":true,"resolved":false}]}]
                """
            request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(requestJSON.utf8))
            discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(discussionsJSON.utf8))
            gitlab.write("request", requestJSON)
            gitlab.write("discussions", discussionsJSON)
            gitlab.write("user", #"{"id":3,"username":"me"}"#)
            gitlab.write("branch", "{\"commit\":{\"id\":\"\(Self.head)\"}}")
            gitlab.write("drafts", "[]")
            gitlab.handler = { [gitlab] command in
                switch (command.method, command.endpoint) {
                case ("GET", "/user"): return try gitlab.response("user")
                case ("GET", "/projects/1/merge_requests/2"): return try gitlab.response("request")
                case ("GET", "/projects/1/repository/branches/feature"): return try gitlab.response("branch")
                case ("GET", let path) where path.contains("/discussions"): return try gitlab.response("discussions")
                case ("GET", let path) where path.contains("/draft_notes"): return try gitlab.response("drafts")
                case ("POST", "/projects/1/merge_requests/2/draft_notes"):
                    let body = try #require(command.arguments.first { $0.hasPrefix("note=") })
                    #expect(command.arguments.contains("in_reply_to_discussion_id=finding"))
                    #expect(command.arguments.contains("resolve_discussion=false"))
                    let draft: [String: Any] = ["id": 30, "author_id": 3, "discussion_id": "finding",
                        "note": String(body.dropFirst("note=".count)), "resolve_discussion": false]
                    let published = try InMemoryGitLab.json([draft])
                    gitlab.write("drafts", String(decoding: published.stdout, as: UTF8.self))
                    gitlab.write("draft-created")
                    if gitlab.has("lose-create-response") { return InMemoryGitLab.output(error: "Connection lost", code: 1) }
                    return try InMemoryGitLab.json(draft)
                default: return try gitlab.unexpected(command)
                }
            }
        }

        var draftPosts: [InMemoryGitLab.Request] { gitlab.requests.filter { $0.method == "POST" } }

        func clean() {
            gitlab.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        func service() -> VerifiedAuthorReplyDrafts {
            VerifiedAuthorReplyDrafts(settings: settings, glab: glab, directory: directory)
        }

        func prepare(acknowledgementSafe: Bool = true, using service: VerifiedAuthorReplyDrafts? = nil,
                     shouldProceed: @escaping @MainActor @Sendable () -> Bool = { true }) async -> Set<Int> {
            await (service ?? replyDrafts).prepare(request: request, discussions: discussions, assessment: .init(notes: [
                .init(noteID: 10, state: .addressed, reason: "Current code covers the finding.",
                    informationalPurpose: .concreteCodeReviewFeedback, addressedReplyAcknowledgementSafe: acknowledgementSafe)
            ]), owedNoteIDs: [10], user: Self.user, host: Self.host, shouldProceed: shouldProceed)
        }

        func remoteDrafts() throws -> [GitLabDraftNote] {
            try JSONDecoder().decode([GitLabDraftNote].self, from: gitlab.data("drafts"))
        }

        func receipt(for draft: GitLabDraftNote, using service: VerifiedAuthorReplyDrafts) -> VerifiedAuthorReplyDrafts.Receipt? {
            service.receipt(for: draft, request: request, discussions: discussions, user: Self.user, host: Self.host)
        }
    }
}
