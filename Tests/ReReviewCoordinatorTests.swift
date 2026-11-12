import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct ReReviewCoordinatorTests {
    @Test(arguments: [false, true])
    func localAutomationDesignationSuppressesHumanReReviewUntilRemoved(_ automatic: Bool) async throws {
        let f = try Fixture()
        defer { f.close() }
        f.settings.automation.autoVerifyReReview = automatic
        try f.declareAutomationAuthor()
        let assessment = ReReviewAssessment(notes: [.init(noteID: 40, state: .addressed,
            reason: "The technical correction and substantive author reply are verified.")])
        let coordinator = f.coordinator(sharedAssessment: assessment)
        let request = try f.request()
        let feedback = try f.feedback()
        let fingerprint = try f.fingerprint()

        await coordinator.refresh(for: request, feedback: feedback, draftCount: 0, context: f.context, user: f.user)
        _ = await coordinator.confirm(f.context, user: f.user, head: "head", fingerprint: fingerprint)

        #expect(f.gitlab.text("requested").isEmpty)
        #expect(f.settings.reReviewReceipts.isEmpty)
        #expect(!f.gitlab.requests.contains { $0.endpoint == "/users/8" })
        #expect(coordinator.status(for: f.context, authorID: f.user.id).state?.canConfirm != true)
        f.settings.reviewParticipationPreferences = .init()
        await coordinator.refresh(for: request, feedback: feedback, draftCount: 0, context: f.context, user: f.user)
        if !automatic {
            let result = await coordinator.confirm(f.context, user: f.user, head: "head", fingerprint: fingerprint)
            #expect(result == .confirmed)
        }
        #expect(f.gitlab.text("requested") == "review\n")
        #expect(coordinator.status(for: f.context, authorID: f.user.id).requested)
    }

    @Test(arguments: ["host", "account"])
    func localAutomationDesignationDoesNotSuppressAnotherScope(_ other: String) async throws {
        let f = try Fixture()
        defer { f.close() }
        f.settings.automation.autoVerifyReReview = true
        try f.declareAutomationAuthor(host: other == "host" ? "other.example.test" : f.context.host,
            username: other == "account" ? "other" : "me")
        let assessment = ReReviewAssessment(notes: [.init(noteID: 40, state: .addressed,
            reason: "The technical correction and substantive author reply are verified.")])
        let coordinator = f.coordinator(sharedAssessment: assessment)
        await coordinator.refresh(for: try f.request(), feedback: try f.feedback(), draftCount: 0, context: f.context, user: f.user)
        #expect(f.gitlab.text("requested") == "review\n")
    }

    @Test(arguments: [false, true])
    func localAutomationDesignationDuringIdentityReadStopsReReview(_ automatic: Bool) async throws {
        let f = try Fixture()
        defer { f.close() }
        f.settings.automation.autoVerifyReReview = automatic
        let assessment = ReReviewAssessment(notes: [.init(noteID: 40, state: .addressed,
            reason: "The technical correction and substantive author reply are verified.")])
        let coordinator = f.coordinator(sharedAssessment: assessment)
        let request = try f.request()
        let feedback = try f.feedback()
        let fingerprint = try f.fingerprint()
        if !automatic {
            await coordinator.refresh(for: request, feedback: feedback, draftCount: 0, context: f.context, user: f.user)
        }
        var changed = false
        f.gitlab.beforeCommand = { call in
            guard !changed, call.endpoint == "/users/8" else { return }
            try f.declareAutomationAuthor()
            changed = true
        }
        if automatic {
            await coordinator.refresh(for: request, feedback: feedback, draftCount: 0, context: f.context, user: f.user)
        } else {
            _ = await coordinator.confirm(f.context, user: f.user, head: "head", fingerprint: fingerprint)
        }
        #expect(changed)
        #expect(f.gitlab.text("requested").isEmpty)
        #expect(f.settings.reReviewReceipts.isEmpty)
    }

    @Test(arguments: [false, true])
    func anAbsentCommenterIsNotAReReviewRecipientEvenWhenTheirTechnicalFeedbackIsAddressed(_ automatic: Bool) async throws {
        let f = try Fixture()
        defer { f.close() }
        f.settings.automation.autoVerifyReReview = automatic
        f.gitlab.write("reviewers", "[]")
        let assessment = ReReviewAssessment(notes: [.init(noteID: 40, state: .addressed,
            reason: "The technical correction and substantive author reply are verified.")])
        let coordinator = f.coordinator(sharedAssessment: assessment)
        let request = try f.request()
        let feedback = try f.feedback()
        let fingerprint = try f.fingerprint()
        #expect(f.settings.reviewParticipationPreferences.entries.isEmpty)

        await coordinator.refresh(for: request, feedback: feedback, draftCount: 0, context: f.context, user: f.user)
        let beforeConfirmation = coordinator.status(for: f.context, authorID: f.user.id)
        #expect(beforeConfirmation.state?.canConfirm != true)
        let result = await coordinator.confirm(f.context, user: f.user, head: "head", fingerprint: fingerprint)

        #expect(result == .ignored)
        #expect(f.gitlab.text("requested").isEmpty)
        #expect(f.gitlab.requests.allSatisfy { $0.endpoint != "graphql" })
        #expect(f.settings.reReviewReceipts.isEmpty)
        #expect(!coordinator.status(for: f.context, authorID: f.user.id).requested)
    }

    @Test(arguments: [false, true])
    func addingACommenterToTheCurrentReviewerListRestoresOrdinaryReReviewEligibility(_ automatic: Bool) async throws {
        let f = try Fixture()
        defer { f.close() }
        f.settings.automation.autoVerifyReReview = automatic
        f.gitlab.write("reviewers", "[]")
        let assessment = ReReviewAssessment(notes: [.init(noteID: 40, state: .addressed,
            reason: "The technical correction and substantive author reply are verified.")])
        let coordinator = f.coordinator(sharedAssessment: assessment)
        let request = try f.request()
        let feedback = try f.feedback()
        let fingerprint = try f.fingerprint()
        await coordinator.refresh(for: request, feedback: feedback, draftCount: 0, context: f.context, user: f.user)
        #expect(f.gitlab.text("requested").isEmpty)

        f.gitlab.write("reviewers", Fixture.assignedReviewersJSON)
        await coordinator.refresh(for: request, feedback: feedback, draftCount: 0, context: f.context, user: f.user)
        if !automatic {
            #expect(coordinator.status(for: f.context, authorID: f.user.id).state == .manual)
            let result = await coordinator.confirm(f.context, user: f.user, head: "head", fingerprint: fingerprint)
            #expect(result == .confirmed)
        }

        #expect(f.gitlab.text("requested") == "review\n")
        #expect(f.gitlab.requests.filter { $0.endpoint == "graphql" }.allSatisfy {
            $0.arguments.contains { $0.contains("mergeRequestReviewerRereview") }
                && !$0.arguments.contains { $0.contains("mergeRequestSetReviewers") }
        })
        #expect(coordinator.status(for: f.context, authorID: f.user.id).requested)
    }

    @Test(arguments: [false, true], ["unapproved", "unreviewed", "review_started"])
    func aReviewerRemovedDuringAsynchronousPreparationIsHeldByTheFinalLiveMembershipCheck(_ automatic: Bool, state: String) async throws {
        let f = try Fixture()
        defer { f.close() }
        f.settings.automation.autoVerifyReReview = automatic
        f.gitlab.write("reviewers", Fixture.assignedReviewersJSON.replacingOccurrences(of: "unapproved", with: state))
        let assessment = ReReviewAssessment(notes: [.init(noteID: 40, state: .addressed,
            reason: "The technical correction and substantive author reply are verified.")])
        let coordinator = f.coordinator(sharedAssessment: assessment)
        let request = try f.request()
        let feedback = try f.feedback()
        let fingerprint = try f.fingerprint()
        if !automatic {
            await coordinator.refresh(for: request, feedback: feedback, draftCount: 0, context: f.context, user: f.user)
            #expect(coordinator.status(for: f.context, authorID: f.user.id).state == .manual)
        }
        var removed = false
        f.gitlab.beforeCommand = { call in
            if !removed && call.endpoint == "/user" {
                f.gitlab.write("reviewers", "[]")
                removed = true
            }
        }
        if automatic {
            await coordinator.refresh(for: request, feedback: feedback, draftCount: 0, context: f.context, user: f.user)
        } else {
            _ = await coordinator.confirm(f.context, user: f.user, head: "head", fingerprint: fingerprint)
        }

        #expect(removed)
        #expect(f.gitlab.text("requested").isEmpty)
        #expect(f.gitlab.requests.allSatisfy { $0.endpoint != "graphql" })
        #expect(f.settings.reReviewReceipts.isEmpty)
        #expect(!coordinator.status(for: f.context, authorID: f.user.id).requested)
    }

    @Test(arguments: ["unreviewed", "review_started"])
    func removalDuringFinalParallelReadsCannotProduceAnAlreadyRequestedReceipt(_ state: String) async throws {
        let f = try Fixture()
        defer { f.close() }
        f.settings.automation.autoVerifyReReview = true
        let assessment = ReReviewAssessment(notes: [.init(noteID: 40, state: .addressed, reason: "Verified technical correction and reply.")])
        let coordinator = f.coordinator(sharedAssessment: assessment)
        var userReads = 0
        var draftReads = 0
        var removed = false
        f.gitlab.beforeCommand = { call in
            if call.endpoint == "/user" {
                userReads += 1
                if userReads == 2 {
                    f.gitlab.write("reviewers", Fixture.assignedReviewersJSON.replacingOccurrences(of: "unapproved", with: state))
                }
            }
            if call.endpoint.contains("/draft_notes?") {
                draftReads += 1
                if draftReads == 2 {
                    // Let concurrently launched metadata reads observe the earlier assignment.
                    for _ in 0..<8 { await Task.yield() }
                    f.gitlab.write("reviewers", "[]")
                    removed = true
                }
            }
        }
        let request = try f.request()
        let feedback = try f.feedback()
        await coordinator.refresh(for: request, feedback: feedback, draftCount: 0, context: f.context, user: f.user)
        #expect(removed)
        #expect(f.gitlab.text("requested").isEmpty)
        #expect(f.settings.reReviewReceipts.isEmpty)
        let status = coordinator.status(for: f.context, authorID: f.user.id)
        #expect(!status.requested && !status.unconfirmed)
    }

    @Test(arguments: ["initial", "final"], ["disabled", "paused", "pendingReview"])
    func receiptShortcutsRecheckAdmissionAfterTheFreshReviewerRead(_ phase: String, change: String) async throws {
        let f = try Fixture()
        defer { f.close() }
        f.settings.automation.autoVerifyReReview = true
        let assessment = ReReviewAssessment(notes: [.init(noteID: 40, state: .addressed, reason: "Verified technical correction and reply.")])
        let coordinator = f.coordinator(sharedAssessment: assessment)
        var reviewerReads = 0
        var changed = false
        f.gitlab.beforeCommand = { call in
            guard call.endpoint.contains("/reviewers?") else { return }
            reviewerReads += 1
            guard reviewerReads == (phase == "initial" ? 2 : 3) else { return }
            f.gitlab.write("reviewers", Fixture.assignedReviewersJSON.replacingOccurrences(of: "unapproved", with: "unreviewed"))
            switch change {
            case "disabled": f.settings.automation.autoReReviewEnabled = false
            case "paused":
                var scope = f.settings.automation.scope
                scope[f.context.target] = .paused
                f.settings.automation.scope = scope
            default: f.settings.pendingCommentReviews.insert(f.context.target)
            }
            changed = true
        }
        let request = try f.request()
        let feedback = try f.feedback()
        await coordinator.refresh(for: request, feedback: feedback, draftCount: 0, context: f.context, user: f.user)
        #expect(changed)
        #expect(f.settings.reReviewReceipts.isEmpty)
        #expect(f.gitlab.text("requested").isEmpty)
    }

    @Test(arguments: [false, true])
    func receiptDisplayUsesCurrentMembershipWithoutDeletingItsJournal(_ unconfirmed: Bool) async throws {
        let f = try Fixture()
        defer { f.close() }
        let key = ReReviewReceipt.Key(host: f.context.host, authorID: f.user.id, projectID: 1, iid: 2, reviewerID: 8)
        f.settings.reReviewReceipts[key] = .init(noteID: 40, unconfirmed: unconfirmed,
            requested: unconfirmed ? nil : true, headSHA: "head")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let saved = try encoder.encode(f.settings.reReviewReceipts)
        f.gitlab.write("reviewers", "[]")
        let assessment = ReReviewAssessment(notes: [.init(noteID: 40, state: .addressed, reason: "Verified technical correction and reply.")])
        let coordinator = f.coordinator(sharedAssessment: assessment)
        let request = try f.request()
        let feedback = try f.feedback()
        await coordinator.refresh(for: request, feedback: feedback, draftCount: 0, context: f.context, user: f.user)
        let absent = coordinator.status(for: f.context, authorID: f.user.id)
        #expect(!absent.requested && !absent.unconfirmed)
        let afterRemoval = try encoder.encode(f.settings.reReviewReceipts)
        #expect(afterRemoval == saved)

        f.gitlab.write("reviewers", Fixture.assignedReviewersJSON)
        await coordinator.refresh(for: request, feedback: feedback, draftCount: 0, context: f.context, user: f.user)
        let present = coordinator.status(for: f.context, authorID: f.user.id)
        #expect(present.requested == !unconfirmed && present.unconfirmed == unconfirmed)
        let afterReaddition = try encoder.encode(f.settings.reReviewReceipts)
        #expect(afterReaddition == saved && f.gitlab.text("requested").isEmpty)
        coordinator.reset()
        let reset = coordinator.status(for: f.context, authorID: f.user.id)
        #expect(!reset.requested && !reset.unconfirmed)
        let afterReset = try encoder.encode(f.settings.reReviewReceipts)
        #expect(afterReset == saved)
    }

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
        static let assignedReviewersJSON = #"[{"user":{"id":8,"username":"reviewer"},"state":"unapproved"}]"#
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
            gitlab.write("reviewers", Self.assignedReviewersJSON)
            let boundary = gitlab
            gitlab.handler = { call in
                switch call.endpoint {
                case "/user": return InMemoryGitLab.output(#"{"id":3,"username":"me"}"#)
                case "/projects/1/merge_requests/2": return try boundary.response("request")
                case let endpoint where endpoint.contains("/discussions?"): return try boundary.response("discussions")
                case let endpoint where endpoint.contains("/reviewers?"):
                    return try boundary.response("reviewers")
                case let endpoint where endpoint.contains("/draft_notes?"): return InMemoryGitLab.output("[]")
                case "/projects/1/merge_requests/2/approvals": return InMemoryGitLab.output(#"{"approved_by":[]}"#)
                case "/projects/1/merge_requests/2/raw_diffs": return InMemoryGitLab.output("diff")
                case "/users/8": return InMemoryGitLab.output(#"{"id":8,"username":"reviewer","bot":false,"state":"active"}"#)
                case "graphql":
                    let append = call.arguments.contains { $0.contains("mergeRequestSetReviewers") }
                    boundary.append("requested", append ? "append\n" : "review\n")
                    let mutation = append ? "mergeRequestSetReviewers" : "mergeRequestReviewerRereview"
                    return InMemoryGitLab.output("{\"data\":{\"\(mutation)\":{\"mergeRequest\":{\"iid\":\"2\"},\"errors\":[]}}}")
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

        func declareAutomationAuthor(host: String? = nil, username: String = "me") throws {
            let entry: [String: Any] = [
                "id": UUID().uuidString, "host": host ?? context.host, "username": username,
                "reviewerID": 8, "label": "@reviewer"
            ]
            let data = try JSONSerialization.data(withJSONObject: ["entries": [], "localAutomationAuthors": [entry]])
            settings.reviewParticipationPreferences = try JSONDecoder().decode(ReviewParticipationPreferences.self, from: data)
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
