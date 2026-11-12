import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct ReReviewCoordinatorTests {
    @Test(arguments: [false, true])
    func personalNoContactPreferenceExcludesAutomaticAndConfirmedReviewRequests(_ automatic: Bool) async throws {
        let f = try Fixture()
        defer { f.close() }
        f.settings.automation.autoVerifyReReview = automatic
        f.settings.reviewParticipationPreferences.exclude(.init(host: f.context.host, entityID: 8, label: "@reviewer"), username: "me")
        let coordinator = f.coordinator()
        await coordinator.refresh(for: try f.request(), feedback: try f.feedback(), draftCount: 0, context: f.context, user: f.user)
        _ = await coordinator.confirm(f.context, user: f.user, head: "head", fingerprint: try f.fingerprint())
        #expect(f.gitlab.text("requested").isEmpty)
        #expect(f.settings.reReviewReceipts.values.allSatisfy { $0.requested != true && !$0.unconfirmed })
    }

    @Test(arguments: [false, true])
    func aSourceBoundOptOutIsNotReinvitedAfterAnAuthorAcknowledgement(_ automatic: Bool) async throws {
        let f = try Fixture()
        defer { f.close() }
        f.settings.automation.autoVerifyReReview = automatic
        f.gitlab.write("discussions", Fixture.discussionsJSON.replacingOccurrences(of: "Please fix", with: "Do not invite me to reviews"))
        let assessment = ReReviewAssessment(notes: [.init(noteID: 40, state: .informational, reason: "The participant declined reviews.",
            informationalAcknowledgementSafe: false, informationalPurpose: .other,
            reviewerOptOut: .init(sourceQuote: "Do not invite me to reviews"))])
        let coordinator = f.coordinator(verify: { _, _, _ in
            #expect(automatic)
            return assessment
        }, sharedAssessment: automatic ? nil : assessment)
        await coordinator.refresh(for: try f.request(), feedback: try f.feedback(), draftCount: 0, context: f.context, user: f.user)
        let deadline = ContinuousClock.now + .seconds(3)
        while coordinator.isVerifying, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        await coordinator.refresh(for: try f.request(), feedback: try f.feedback(), draftCount: 0, context: f.context, user: f.user)
        _ = await coordinator.confirm(f.context, user: f.user, head: "head", fingerprint: try f.fingerprint())
        #expect(f.gitlab.text("requested").isEmpty)
        #expect(f.settings.reReviewReceipts.values.allSatisfy { $0.requested != true && !$0.unconfirmed })
    }

    @Test func confirmedReviewIsDeduplicatedAcrossCoordinatorReplacement() async throws {
        // given
        let fixture = try Fixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator()
        let request = try fixture.request()
        let feedback = try fixture.feedback()
        let fingerprint = try fixture.fingerprint()
        await coordinator.refresh(for: request, feedback: feedback, draftCount: 0,
            context: fixture.context, user: fixture.user)
        #expect(coordinator.status(for: fixture.context, authorID: fixture.user.id).state == .manual)

        // when
        let result = await coordinator.confirm(fixture.context, user: fixture.user, head: "head", fingerprint: fingerprint)
        let replacement = fixture.coordinator()
        await replacement.refresh(for: request, feedback: feedback, draftCount: 0,
            context: fixture.context, user: fixture.user)
        let repeated = await replacement.confirm(fixture.context, user: fixture.user, head: "head", fingerprint: fingerprint)

        // then
        #expect(result == .confirmed && repeated == .ignored)
        #expect(fixture.gitlab.text("requested") == "review\n")
        #expect(replacement.status(for: fixture.context, authorID: fixture.user.id).requested)
        let receipt = try #require(fixture.settings.reReviewReceipts.values.first)
        #expect(receipt.covers(noteID: 40, headSHA: "head") && !receipt.unconfirmed)
    }

    @Test(arguments: ["head", "title", "discussion", "account-revision"])
    func confirmationCannotUseEvidenceFromAnEarlierContext(_ changed: String) async throws {
        // given
        let fixture = try Fixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator()
        await coordinator.refresh(for: try fixture.request(), feedback: try fixture.feedback(), draftCount: 0,
            context: fixture.context, user: fixture.user)
        let fingerprint = try fixture.fingerprint()
        #expect(coordinator.status(for: fixture.context, authorID: fixture.user.id).state == .manual)
        switch changed {
        case "head": fixture.gitlab.write("request", Fixture.requestJSON.replacingOccurrences(of: "head", with: "new-head"))
        case "title": fixture.gitlab.write("request", Fixture.requestJSON.replacingOccurrences(of: "Fix", with: "Different scope"))
        case "discussion": fixture.gitlab.write("discussions", Fixture.discussionsJSON.replacingOccurrences(of: "Please fix", with: "New requirement"))
        default:
            fixture.glab.currentUsername = "other"
            fixture.glab.currentUsername = "me"
        }

        // when
        let result = await coordinator.confirm(fixture.context, user: fixture.user, head: "head", fingerprint: fingerprint)

        // then
        #expect(result == (changed == "account-revision" ? .ignored : .changed))
        #expect(fixture.gitlab.text("requested").isEmpty && fixture.settings.reReviewReceipts.isEmpty)
        if changed == "account-revision" {
            #expect(coordinator.status(for: fixture.context, authorID: fixture.user.id).state == nil)
        }
    }

    @Test func runtimeCancellationKeepsPublicationBaselineAndAllowsFreshVerificationAfterResume() async throws {
        // given
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.settings.automation.autoVerifyReReview = true
        let coordinator = fixture.coordinator(verify: { _, _, _ in
            if !fixture.gitlab.has("verified-once") {
                fixture.gitlab.write("verified-once")
                try await fixture.gitlab.waitFor("release-verifier")
            }
            return .init(notes: [.init(noteID: 40, state: .addressed, reason: "Verified correction")])
        })
        defer { coordinator.reset() }
        let request = try fixture.request()
        fixture.gitlab.write("discussions", Fixture.unansweredJSON)
        await coordinator.refresh(for: request, feedback: try fixture.feedback(), draftCount: 1,
            context: fixture.context, user: fixture.user)
        fixture.gitlab.write("discussions", Fixture.discussionsJSON)
        await coordinator.refresh(for: request, feedback: try fixture.feedback(), draftCount: 0,
            context: fixture.context, user: fixture.user)
        try await fixture.gitlab.waitFor("verified-once")
        #expect(coordinator.isVerifying)
        let baseline = fixture.settings.reReviewDraftBaselines[fixture.context.target]

        // when
        var paused = fixture.settings.automation.scope
        paused[fixture.context.target] = .paused
        coordinator.cancelRuntimePreparation(outsideScope: paused)
        fixture.gitlab.write("release-verifier")

        // then
        #expect(!coordinator.isVerifying)
        #expect(fixture.settings.reReviewDraftBaselines[fixture.context.target] == baseline)
        #expect(baseline == 0 && fixture.gitlab.text("requested").isEmpty)
        coordinator.cancelRuntimePreparation(outsideScope: fixture.settings.automation.scope)
        await coordinator.refresh(for: request, feedback: try fixture.feedback(), draftCount: 0,
            context: fixture.context, user: fixture.user)
        try await fixture.gitlab.waitFor("requested")
        #expect(fixture.gitlab.text("requested") == "review\n")
    }

    @Test func anAccountRoundTripDiscardsAndDrainsAnOldVerifierCompletion() async throws {
        // given
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.settings.automation.autoVerifyReReview = true
        let coordinator = fixture.coordinator(verify: { _, _, _ in
            fixture.gitlab.write("verifier-entered")
            try await fixture.gitlab.waitFor("release-verifier")
            return .init(notes: [.init(noteID: 40, state: .addressed, reason: "Verified correction")])
        })
        defer { coordinator.reset() }
        var observations = 0
        coordinator.onChange = { _, _ in observations += 1 }
        await coordinator.refresh(for: try fixture.request(), feedback: try fixture.feedback(), draftCount: 0,
            context: fixture.context, user: fixture.user)
        try await fixture.gitlab.waitFor("verifier-entered")
        #expect(coordinator.isVerifying && observations > 0)
        let beforeSwitch = observations

        // when
        fixture.glab.currentUsername = "other"
        fixture.glab.currentUsername = "me"
        fixture.gitlab.write("release-verifier")
        let deadline = ContinuousClock.now + .seconds(5)
        while coordinator.isVerifying, ContinuousClock.now < deadline { await Task.yield() }

        // then
        #expect(!coordinator.isVerifying && observations == beforeSwitch)
        #expect(coordinator.status(for: fixture.context, authorID: fixture.user.id).state == nil)
        #expect(fixture.gitlab.text("requested").isEmpty && fixture.settings.reReviewReceipts.isEmpty)
    }

    @MainActor private final class Fixture {
        let gitlab: InMemoryGitLab
        let glab: GlabService
        let settings: SettingsManager
        let defaults: UserDefaults
        let suite: String
        let context: ReReviewCoordinator.Context
        let user: GitLabAuthenticatedUser

        static let requestJSON = #"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Fix","web_url":"https://gitlab.example.org/g/p/-/merge_requests/2","state":"opened","draft":false,"sha":"head","source_project_id":1,"source_branch":"fix","target_project_id":1,"target_branch":"main","labels":[]}"#
        static let unansweredJSON = #"[{"id":"thread","notes":[{"id":40,"author":{"id":8,"username":"reviewer"},"body":"Please fix","system":false,"resolvable":true,"resolved":false}]}]"#
        static let discussionsJSON = #"[{"id":"thread","notes":[{"id":40,"author":{"id":8,"username":"reviewer"},"body":"Please fix","system":false,"resolvable":true,"resolved":false},{"id":41,"author":{"id":3,"username":"me"},"body":"Fixed and verified","system":false}]}]"#

        init() throws {
            let suite = "ReReviewCoordinatorTests.\(UUID())"
            self.suite = suite
            let gitlab = InMemoryGitLab()
            self.gitlab = gitlab
            let defaults = try #require(UserDefaults(suiteName: suite))
            self.defaults = defaults
            let settings = SettingsManager(defaults: defaults)
            self.settings = settings
            settings.automation.packageDecision = .enabled
            settings.automation.autoReReviewEnabled = true
            settings.automation.autoVerifyReReview = false
            let glab = gitlab.service(host: "gitlab.example.org", username: "me")
            self.glab = glab
            context = .init(host: "gitlab.example.org", username: "me", revision: glab.accountRevision, projectID: 1, iid: 2)
            user = try JSONDecoder().decode(GitLabAuthenticatedUser.self, from: Data(#"{"id":3,"username":"me"}"#.utf8))
            gitlab.write("request", Self.requestJSON)
            gitlab.write("discussions", Self.discussionsJSON)
            let boundary = gitlab
            gitlab.handler = { call in
                switch call.endpoint {
                case "/user": return InMemoryGitLab.output(#"{"id":3,"username":"me"}"#)
                case "/projects/1/merge_requests/2": return try boundary.response("request")
                case let endpoint where endpoint.contains("/discussions?"): return try boundary.response("discussions")
                case let endpoint where endpoint.contains("/reviewers?"):
                    return InMemoryGitLab.output(#"[{"user":{"id":8,"username":"reviewer"},"state":"unapproved"}]"#)
                case let endpoint where endpoint.contains("/draft_notes?"): return InMemoryGitLab.output("[]")
                case "/projects/1/merge_requests/2/approvals": return InMemoryGitLab.output(#"{"approved_by":[]}"#)
                case "/projects/1/merge_requests/2/raw_diffs": return InMemoryGitLab.output("diff")
                case "/users/8": return InMemoryGitLab.output(#"{"id":8,"username":"reviewer","bot":false,"state":"active"}"#)
                case "graphql":
                    boundary.append("requested", "review\n")
                    return InMemoryGitLab.output(#"{"data":{"mergeRequestReviewerRereview":{"mergeRequest":{"iid":"2"},"errors":[]}}}"#)
                default: return try boundary.unexpected(call)
                }
            }
        }

        func coordinator(verify: @escaping ReReviewCoordinator.Verify = { _, _, _ in
            Issue.record("Manual verification unexpectedly started an assistant")
            throw CancellationError()
        }, sharedAssessment: ReReviewAssessment? = nil) -> ReReviewCoordinator {
            .init(settings: settings, glab: glab, canAutomate: { _ in true }, verify: verify,
                authorFeedbackAssessment: { _, _ in sharedAssessment })
        }

        func request() throws -> GitLabMergeRequest {
            try JSONDecoder().decode(GitLabMergeRequest.self, from: gitlab.data("request"))
        }

        func feedback() throws -> ReReviewFeedback {
            .init(discussions: try discussions(), authorID: user.id)
        }

        func discussions() throws -> [GitLabMergeRequestDiscussion] {
            try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: gitlab.data("discussions"))
        }

        func fingerprint() throws -> String {
            let threads = try discussions()
            return try #require(ReviewVerdict.fingerprint(threads))
        }

        func close() {
            gitlab.close()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
