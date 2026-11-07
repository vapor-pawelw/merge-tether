import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct AuthorFeedbackCoordinatorTests {
    @Test func checkingIsBoundToTheCurrentHeadDiscussionAndSemanticContext() async throws {
        try await withFixture { fixture in
            fixture.settings.automation.autoResolveAcceptedFeedback = false
            fixture.settings.automation.authorFeedback.isEnabled = true
            let coordinator = fixture.coordinator()
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(Fixture.request.utf8))
            let fingerprint = try #require(ReviewVerdict.fingerprint(fixture.discussions()))
            try fixture.start(coordinator)
            #expect(coordinator.isChecking(for: request, fingerprint: fingerprint))
            #expect(!coordinator.isChecking(for: request, fingerprint: "changed discussions"))
            for changed in [Fixture.request.replacingOccurrences(of: Fixture.sha, with: String(repeating: "b", count: 40)),
                            Fixture.request.replacingOccurrences(of: "Example MR", with: "Changed requirements")] {
                let edited = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(changed.utf8))
                #expect(!coordinator.isChecking(for: edited, fingerprint: fingerprint))
            }
            try await fixture.run(coordinator)
            #expect(!coordinator.isChecking(for: request, fingerprint: fingerprint))
        }
    }

    @Test func completedFeedbackVerificationNotifiesTheMRCompletionConsumer() async throws {
        try await withFixture { fixture in
            fixture.settings.automation.autoResolveAcceptedFeedback = false
            fixture.settings.automation.authorFeedback.isEnabled = true
            let monitor = MergeRequestAttentionMonitor(glab: fixture.glab, settings: fixture.settings,
                reportDirectory: nil, canAutomate: { _ in true }, verifyReReview: { _, _, _ in
                    .init(notes: [.init(noteID: 10, state: .addressed, reason: "Current code and existing reply verified.")])
                })
            var checked = 0
            monitor.onAuthorFeedbackChecked = { checked += 1 }
            monitor.refresh(host: Fixture.host, username: "me", todos: [])
            let coordinator = try #require(monitor.authorFeedbackCoordinator)
            try await fixture.run(coordinator)
            #expect(checked == 1)
        }
    }

    @Test func passesCurrentMergeRequestDescriptionToSemanticVerification() async throws {
        try await withFixture { fixture in
            let request = Fixture.request.replacingOccurrences(of: "\"title\":\"Example MR\"",
                with: "\"title\":\"Example MR\",\"description\":\"Documented fallback and verification steps\"")
            try fixture.write("request.json", request)
            let coordinator = fixture.coordinator()
            try await fixture.run(coordinator, requestJSON: request)
            #expect(fixture.inputs.first?.description == "Documented fallback and verification steps")
            #expect(fixture.inputs.first?.target?.host == Fixture.host)
            #expect(fixture.inputs.first?.target?.projectID == 1)
            #expect(fixture.inputs.first?.target?.iid == 2)
            #expect(fixture.inputs.first?.target?.expectedUsername == "me")
            let snapshot = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(request.utf8))
            #expect(fixture.inputs.first?.target?.url == snapshot.webURL)
            #expect(fixture.inputs.first?.semanticContextFingerprint == snapshot.semanticContextFingerprint)
        }
    }

    @Test(arguments: ["title", "description"])
    func sameHeadContextEditInvalidatesCachedSemanticAssessment(_ field: String) async throws {
        try await withFixture { fixture in
            fixture.settings.automation.autoResolveAcceptedFeedback = false
            fixture.settings.automation.authorFeedback.isEnabled = true
            let coordinator = fixture.coordinator()
            try await fixture.run(coordinator)
            #expect(fixture.inputs.count == 1)
            let edited = Fixture.request.replacingOccurrences(of: "\"title\":\"Example MR\"",
                with: field == "title" ? "\"title\":\"Updated requirements\""
                    : "\"title\":\"Example MR\",\"description\":\"Updated requirements\"")
            try fixture.write("request.json", edited)
            try await fixture.run(coordinator, requestJSON: edited)
            #expect(fixture.inputs.count == 2)
        }
    }

    @Test(arguments: ["title", "description"])
    func contextChangedDuringVerificationCannotAuthorizeAcceptedThreadResolution(_ field: String) async throws {
        try await withFixture { fixture in
            let edited = Fixture.request.replacingOccurrences(of: "\"title\":\"Example MR\"",
                with: field == "title" ? "\"title\":\"New acceptance criteria\""
                    : "\"title\":\"Example MR\",\"description\":\"New acceptance criteria\"")
            let coordinator = fixture.coordinator(duringVerification: {
                do { try fixture.write("request.json", edited) } catch { Issue.record(error) }
            })
            try await fixture.run(coordinator)
            #expect(!fixture.resolved)
            #expect(coordinator.status(projectID: 1, iid: 2)?.phase != .complete)
        }
    }

    @Test func resolvesOnlyTheVerifiedThreadAfterFreshChecks() async throws {
        try await withFixture { fixture in
            let coordinator = fixture.coordinator()
            var refreshed = false
            coordinator.onRemoteChange = { refreshed = true }
            try await fixture.run(coordinator)
            #expect(fixture.resolved)
            #expect(refreshed)
            #expect(coordinator.status(projectID: 1, iid: 2)?.phase == .complete)
            #expect(coordinator.status(projectID: 1, iid: 2)?.findings.isEmpty == true)
            #expect(coordinator.status(projectID: 1, iid: 2)?.acceptedReviewerIDs.contains(7) == true)
        }
    }

    @Test func anotherReviewersApprovalDoesNotCloseTheConcern() async throws {
        try await withFixture { fixture in
            try fixture.write("approvals.json", #"{"approved_by":[{"user":{"id":8}}]}"#)
            let coordinator = fixture.coordinator()
            try await fixture.run(coordinator)
            #expect(!fixture.resolved)
            #expect(coordinator.status(projectID: 1, iid: 2)?.findings.first?.state == .waitingAcceptance)
        }
    }

    @Test func disablingAutomaticResolutionStillVerifiesAndPreparesRemainingWork() async throws {
        try await withFixture { fixture in
            fixture.settings.automation.autoResolveAcceptedFeedback = false
            fixture.settings.automation.authorFeedback.isEnabled = true
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .blocking, reason: "Fix A remains necessary")
            ]))
            var requested: Set<Int> = []
            coordinator.onNeedsWork = { _, notes, _ in requested = notes }
            try await fixture.run(coordinator)
            #expect(fixture.verified)
            #expect(!fixture.resolved)
            #expect(requested == [10])
            #expect(coordinator.status(projectID: 1, iid: 2)?.needsAttention == true)
        }
    }

    @Test func disablingResolutionDoesNotTurnAcceptedFeedbackIntoHumanAttention() async throws {
        try await withFixture { fixture in
            fixture.settings.automation.autoResolveAcceptedFeedback = false
            fixture.settings.automation.authorFeedback.isEnabled = true
            let coordinator = fixture.coordinator()
            var requested: Set<Int> = []
            coordinator.onNeedsWork = { _, notes, _ in requested = notes }
            try await fixture.run(coordinator)
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(fixture.verified)
            #expect(!fixture.resolved)
            #expect(requested.isEmpty)
            #expect(!status.needsAttention)
            #expect(!status.findings.contains { [.needsChanges, .needsVerification].contains($0.state) })
        }
    }

    @Test func resolvedThreadStillTriggersWorkWhenTheVerifierFindsAnUnfulfilledCondition() async throws {
        try await withFixture { fixture in
            try fixture.write("discussions.json", "[\(Fixture.thread.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true"))]")
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .blocking, reason: "The concern was closed but fix A is still absent")
            ]))
            var requested: Set<Int> = []
            coordinator.onNeedsWork = { _, notes, _ in requested = notes }
            try await fixture.run(coordinator)
            #expect(fixture.verified)
            #expect(!fixture.resolved)
            #expect(requested == [10])
            #expect(coordinator.status(projectID: 1, iid: 2)?.needsAttention == true)
        }
    }

    @Test func generalOnlyInformationalReviewCompletesAssessmentWithoutRequestingChanges() async throws {
        try await withFixture { fixture in
            let summary = #"[{"id":"summary","notes":[{"id":20,"author":{"id":7,"username":"alice"},"system":false,"body":"Review complete; no changes needed.","resolvable":false}]}]"#
            try fixture.write("discussions.json", summary)
            fixture.settings.automation.authorFeedback.isEnabled = true
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 20, state: .informational, reason: "A review summary without a requested change")
            ]))
            var requested: Set<Int> = []
            coordinator.onNeedsWork = { _, notes, _ in requested = notes }
            try await fixture.run(coordinator)
            #expect(fixture.verified)
            #expect(requested.isEmpty)
            #expect(coordinator.status(projectID: 1, iid: 2)?.phase == .complete)
            #expect(coordinator.status(projectID: 1, iid: 2)?.needsAttention == false)
        }
    }

    @Test func advanceApprovalKeepsGeneralConditionsOpenAndRequestsFollowUp() async throws {
        try await withFixture { fixture in
            try fixture.write("discussions.json", "[\(Fixture.thread),\(Fixture.condition)]")
            let assessment = ReReviewAssessment(notes: [
                .init(noteID: 10, state: .addressed, reason: "Original fix verified"),
                .init(noteID: 20, state: .blocking, reason: "The requested rename is still missing")
            ])
            let coordinator = fixture.coordinator(assessment: assessment)
            var requested: Set<Int> = []
            let expectedFingerprint = ReviewVerdict.fingerprint(try fixture.discussions())
            coordinator.onNeedsWork = { _, notes, fingerprint in
                #expect(fingerprint == expectedFingerprint)
                requested = notes
            }
            try await fixture.run(coordinator)
            #expect(!fixture.resolved)
            #expect(requested == [20])
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(status.needsAttention)
            #expect(status.findings.map(\.state) == [.needsChanges, .needsChanges])
        }
    }

    @Test func editedConcernInvalidatesEarlierAcceptanceEvenWithTheSameBody() async throws {
        try await withFixture { fixture in
            let acknowledgement = """
                {"id":"accepted","notes":[{"id":30,"author":{"id":7,"username":"alice"},
                 "system":false,"body":"All the requested fixes look correct","resolvable":false,
                 "created_at":"2026-01-01T12:00:00Z"}]}
                """
            let initialJSON = "[\(Fixture.thread),\(acknowledgement)]"
            let initial = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(initialJSON.utf8))
            try fixture.write("discussions.json", initialJSON.replacingOccurrences(
                of: "\"created_at\":\"2026-01-01T10:00:00Z\"",
                with: "\"created_at\":\"2026-01-01T10:00:00Z\",\"updated_at\":\"2026-01-01T13:00:00Z\""))
            try fixture.write("approvals.json", #"{"approved_by":[]}"#)
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .addressed, reason: "Fix A verified", acceptanceNoteID: 30),
                .init(noteID: 30, state: .informational, reason: "Reviewer accepts fix A")
            ]))
            try await fixture.run(coordinator, initialDiscussions: initial)
            #expect(!fixture.resolved)
        }
    }

    @Test(arguments: ["head", "comment", "draft", "account", "approval"])
    func changedLiveEvidencePreventsResolution(_ changed: String) async throws {
        try await withFixture { fixture in
            switch changed {
            case "head": try fixture.write("request.json", Fixture.request.replacingOccurrences(of: Fixture.sha, with: String(repeating: "b", count: 40)))
            case "comment": try fixture.write("discussions.json", "[\(Fixture.thread.replacingOccurrences(of: "Fix A", with: "Also fix B"))]")
            case "draft": try fixture.write("drafts.json", #"[{"id":30,"author_id":3,"note":"Unpublished reply"}]"#)
            case "account": try fixture.write("user.json", #"{"id":99,"username":"me"}"#)
            default: try fixture.write("withdraw-approval", "yes")
            }
            let coordinator = fixture.coordinator()
            try await fixture.run(coordinator, initialDiscussions: [try JSONDecoder().decode(GitLabMergeRequestDiscussion.self, from: Data(Fixture.thread.utf8))])
            #expect(!fixture.resolved)
        }
    }

    @Test(arguments: ["setting", "scope", "package", "ignored"])
    func disabledPolicyDuringVerificationPreventsResolution(_ changed: String) async throws {
        try await withFixture { fixture in
            let coordinator = fixture.coordinator(duringVerification: {
                switch changed {
                case "setting": fixture.settings.automation.autoResolveAcceptedFeedback = false
                case "scope": fixture.settings.automation.scope.mode = .selected
                case "package": fixture.settings.automation.packageDecision = .disabled
                default: fixture.settings.ignoredMergeRequests.insert(.init(host: Fixture.host, username: "me", projectID: 1, iid: 2))
                }
            })
            // Disabling policy cancels work without publishing a completed assessment.
            try fixture.start(coordinator)
            try await fixture.waitForVerification()
            try await Task.sleep(for: .milliseconds(100))
            #expect(!fixture.resolved)
            #expect(coordinator.status(projectID: 1, iid: 2)?.phase != .complete)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try await body(fixture)
    }

    @MainActor
    private final class Fixture {
        static let host = "gitlab.example.test"
        static let sha = String(repeating: "a", count: 40)
        static let request = """
            {"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},
             "title":"Example MR","web_url":"https://\(host)/group/repo/-/merge_requests/2",
             "state":"opened","draft":false,"sha":"\(sha)","source_branch":"feature",
             "target_branch":"main","labels":[]}
            """
        static let thread = """
            {"id":"thread-a","notes":[
              {"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"Fix A",
               "resolvable":true,"resolved":false,"created_at":"2026-01-01T10:00:00Z"},
              {"id":11,"author":{"id":3,"username":"me"},"system":false,"body":"Fixed A",
               "resolvable":false,"created_at":"2026-01-01T11:00:00Z"}]}
            """
        static let condition = """
            {"id":"general-condition","notes":[{"id":20,"author":{"id":7,"username":"alice"},
             "system":false,"body":"Approved, but please also rename X","resolvable":false,
             "created_at":"2026-01-01T12:00:00Z"}]}
            """
        let directory: URL
        let defaults: UserDefaults
        let suite = "AuthorFeedbackCoordinatorTests.\(UUID())"
        let settings: SettingsManager
        let glab: GlabService
        var verified = false
        var inputs: [ReReviewVerifier.Input] = []
        var resolved: Bool { FileManager.default.fileExists(atPath: directory.appending(path: "resolved").path) }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defaults = try #require(UserDefaults(suiteName: suite))
            settings = SettingsManager(defaults: defaults)
            settings.automation.packageDecision = .enabled
            settings.automation.autoResolveAcceptedFeedback = true
            glab = GlabService()
            glab.resolvedHost = Self.host
            glab.currentUsername = "me"
            glab.glabPath = directory.appending(path: "glab")
            try write("request.json", Self.request)
            try write("user.json", #"{"id":3,"username":"me"}"#)
            try write("approvals.json", #"{"approved_by":[{"user":{"id":7,"username":"alice"}}]}"#)
            try write("discussions.json", "[\(Self.thread)]")
            try write("resolved.json", Self.thread.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true"))
            try write("drafts.json", "[]")
            try write("glab", """
                #!/bin/sh
                set -eu
                cd "$(dirname "$0")"
                test "$1" = api
                test "$3" = --hostname
                test "$4" = \(Self.host)
                case "$2" in
                  /user) cat user.json ;;
                  /projects/1/merge_requests/2) cat request.json ;;
                  */raw_diffs) printf '%s' 'diff --git a/A b/A' ;;
                  */approvals)
                    if [ -e approvals-read ] && [ -e withdraw-approval ]; then
                      printf '%s' '{"approved_by":[]}'
                    else cat approvals.json; fi
                    touch approvals-read ;;
                  */draft_notes*) cat drafts.json ;;
                  */discussions\\?*)
                    if [ -e resolved ]; then printf '['; cat resolved.json; printf ']';
                    else cat discussions.json; fi ;;
                  */discussions/thread-a)
                    test "$*" = 'api /projects/1/merge_requests/2/discussions/thread-a --hostname \(Self.host) --method PUT --field resolved=true'
                    touch resolved
                    cat resolved.json ;;
                  *) printf '%s' "Unexpected glab command: $*" >&2; exit 100 ;;
                esac
                """)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.appending(path: "glab").path)
        }

        func coordinator(assessment: ReReviewAssessment? = nil, duringVerification: (() -> Void)? = nil) -> AuthorFeedbackCoordinator {
            AuthorFeedbackCoordinator(settings: settings, glab: glab, canAutomate: { _ in true }, verify: { [self] input, _, _ in
                inputs.append(input)
                duringVerification?()
                verified = true
                return assessment ?? .init(notes: [.init(noteID: 10, state: .addressed, reason: "Current diff fixes A")])
            })
        }

        func start(_ coordinator: AuthorFeedbackCoordinator, initialDiscussions: [GitLabMergeRequestDiscussion]? = nil,
                   requestJSON: String = Fixture.request) throws {
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(requestJSON.utf8))
            coordinator.refresh(request: request, discussions: try initialDiscussions ?? discussions(), drafts: 0,
                                host: Self.host, user: .init(id: 3, username: "me"))
        }

        func run(_ coordinator: AuthorFeedbackCoordinator, initialDiscussions: [GitLabMergeRequestDiscussion]? = nil,
                 requestJSON: String = Fixture.request) async throws {
            try start(coordinator, initialDiscussions: initialDiscussions, requestJSON: requestJSON)
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if let phase = coordinator.status(projectID: 1, iid: 2)?.phase, phase == .complete || phase == .failed { return }
                if verified && coordinator.status(projectID: 1, iid: 2) == nil { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("Author feedback coordinator did not finish")
        }

        func waitForVerification() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !verified, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(verified)
        }

        func discussions() throws -> [GitLabMergeRequestDiscussion] {
            try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(contentsOf: directory.appending(path: "discussions.json")))
        }

        func write(_ name: String, _ content: String) throws { try Data(content.utf8).write(to: directory.appending(path: name)) }
        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
