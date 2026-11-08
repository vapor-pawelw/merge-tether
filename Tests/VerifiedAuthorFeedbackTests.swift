import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct VerifiedAuthorFeedbackTests {
    @Test func verifiedGeneralConditionIsIncludedAndAutomaticDispatchDoesNotRepeat() async throws {
        try await withFixture { fixture in
            try await fixture.prepare()
            let handoff = try #require(fixture.settings.assistantHandoffs.first)
            #expect(handoff.feedbackNoteIDs == [20])
            #expect(handoff.expectedHeadSHA == Fixture.sha)
            #expect(handoff.workflow == .followUp)
            #expect(handoff.taskPrompt?.contains("Focus on GitLab note IDs: 20.") == true)
            #expect(handoff.taskPrompt?.contains("conditions attached to an advance approval") == true)
            #expect(handoff.taskPrompt?.contains("Decide whether each request is justified") == true)
            #expect(handoff.taskPrompt?.contains("Correlate summaries with their underlying findings and substantive author replies across all discussions") == true)
            #expect(handoff.taskPrompt?.contains("If the same request is already substantively answered elsewhere, do not create a duplicate reply or code change") == true)
            #expect(handoff.taskPrompt?.contains("A summary's distinct unanswered request still requires work or an evidence-based answer") == true)
            #expect(handoff.followUpPushAllowed == false)
            try await fixture.waitForJob()
            try await fixture.prepare()
            #expect(fixture.settings.assistantHandoffs.count == 1)
        }
    }

    @Test func clearingJobHistoryAndReloadingSettingsDoesNotReplayAttemptedFeedback() async throws {
        try await withFixture { fixture in
            try await fixture.prepare()
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 1)

            fixture.settings.assistantHandoffs.removeAll()
            fixture.settings.save()
            let reloaded = SettingsManager(defaults: fixture.defaults)
            #expect(reloaded.assistantHandoffs.isEmpty)

            try await fixture.prepare(using: reloaded)
            try await fixture.waitForJob()
            #expect(reloaded.assistantHandoffs.isEmpty)

            try await fixture.prepare(manual: true, using: reloaded)
            try await fixture.waitForJob()
            #expect(reloaded.assistantHandoffs.count == 1)
            #expect(reloaded.assistantHandoffs.first?.manual == true)
            #expect(reloaded.assistantHandoffs.first?.feedbackNoteIDs == [20])
        }
    }

    @Test func boundedBatchesDoNotLoseTheThirteenthConditionAndAllowManualRetry() async throws {
        try await withFixture { fixture in
            let noteIDs = Array(100...112)
            let notes = noteIDs.map { id in
                """
                    {"id":\(id),"author":{"id":7,"username":"alice"},"system":false,
                     "body":"Approved, but also address condition \(id)","resolvable":false}
                    """
            }.joined(separator: ",")
            let snapshot = "[{\"id\":\"general-conditions\",\"notes\":[\(notes)]}]"
            try fixture.write("discussions.json", snapshot)

            try await fixture.prepare(noteIDs: noteIDs, snapshot: snapshot)
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 1)
            #expect(fixture.settings.assistantHandoffs.first?.feedbackNoteIDs == Array(100...111))

            try await fixture.prepare(noteIDs: noteIDs, snapshot: snapshot)
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 2)
            #expect(fixture.settings.assistantHandoffs.contains { $0.feedbackNoteIDs == [112] })

            try await fixture.prepare(noteIDs: noteIDs, snapshot: snapshot)
            #expect(fixture.settings.assistantHandoffs.count == 2)

            try await fixture.prepare(noteIDs: noteIDs, snapshot: snapshot, manual: true)
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 3)
            #expect(fixture.settings.assistantHandoffs.filter { $0.manual == true }.map(\.feedbackNoteIDs) == [Array(100...111)])
        }
    }

    @Test func unchangedReviewerConcernDoesNotReplayAfterOurReplyOrNewHeadButNewFeedbackCanRun() async throws {
        try await withFixture { fixture in
            try await fixture.prepare()
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 1)

            let reply = """
                ,{"id":21,"author":{"id":3,"username":"me"},"system":false,
                  "body":"I have addressed the request","resolvable":false}
                """
            let withReply = Fixture.discussions.replacingOccurrences(of: "]}]", with: "\(reply)]}]")
            try fixture.write("discussions.json", withReply)
            try await fixture.prepare(snapshot: withReply)
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 1)

            let newHead = String(repeating: "b", count: 40)
            try fixture.write("request.json", Fixture.request.replacingOccurrences(of: Fixture.sha, with: newHead))
            try await fixture.prepare(snapshot: withReply, expectedHeadSHA: newHead)
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 1)

            let editedConcern = withReply.replacingOccurrences(of: "rename X", with: "rename Y")
            try fixture.write("discussions.json", editedConcern)
            try await fixture.prepare(snapshot: editedConcern, expectedHeadSHA: newHead)
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 2)

            let newConcern = """
                ,{"id":22,"author":{"id":7,"username":"alice"},"system":false,
                  "body":"One additional correction","resolvable":false}
                """
            let withNewConcern = editedConcern.replacingOccurrences(of: "]}]", with: "\(newConcern)]}]")
            try fixture.write("discussions.json", withNewConcern)
            try await fixture.prepare(noteIDs: [20, 22], snapshot: withNewConcern, expectedHeadSHA: newHead)
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 3)
            #expect(fixture.settings.assistantHandoffs.contains { $0.feedbackNoteIDs == [22] })

            try await fixture.prepare(snapshot: withNewConcern, manual: true, expectedHeadSHA: newHead)
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 4)
            #expect(fixture.settings.assistantHandoffs.filter { $0.manual == true }.map(\.feedbackNoteIDs) == [[20]])
        }
    }

    @Test(arguments: ["head", "comment"])
    func changedEvidenceDuringStackLookupPreventsDispatch(_ changed: String) async throws {
        try await withFixture { fixture in
            if changed == "head" {
                try fixture.write("changed-request.json", Fixture.request.replacingOccurrences(of: Fixture.sha, with: String(repeating: "b", count: 40)))
            } else {
                try fixture.write("changed-discussions.json", Fixture.discussions.replacingOccurrences(of: "rename X", with: "rename Y"))
            }
            try await fixture.prepare()
            #expect(FileManager.default.fileExists(atPath: fixture.directory.appending(path: "stack-read").path))
            #expect(fixture.settings.assistantHandoffs.isEmpty)
            #expect(!fixture.executed)
        }
    }

    @Test(arguments: ["head", "comment"])
    func alreadyStaleVerifierSnapshotDoesNotPrepareAJob(_ changed: String) async throws {
        try await withFixture { fixture in
            if changed == "head" {
                try fixture.write("request.json", Fixture.request.replacingOccurrences(of: Fixture.sha, with: String(repeating: "b", count: 40)))
            } else {
                try fixture.write("discussions.json", Fixture.discussions.replacingOccurrences(of: "rename X", with: "rename Y"))
            }
            try await fixture.prepare()
            #expect(fixture.settings.assistantHandoffs.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appending(path: "stack-read").path))
            #expect(!fixture.executed)
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
        static let discussions = """
            [{"id":"general-condition","notes":[{"id":20,"author":{"id":7,"username":"alice"},
             "system":false,"body":"Approved, but please also rename X","resolvable":false,
             "created_at":"2026-01-01T12:00:00Z"}]}]
            """
        let directory: URL
        let defaults: UserDefaults
        let suite = "VerifiedAuthorFeedbackTests.\(UUID())"
        let settings: SettingsManager
        let glab: GlabService
        let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.test", projectID: 1, iid: 2)
        var executed = false
        lazy var coordinator = AssistantJobCoordinator(execute: { [self] _, _ in
            executed = true
            return .init(result: .init(status: .blocked, summary: "Synthetic job"), output: "")
        })
        lazy var service = TodoAutomationService(canAutomate: { _ in true }, jobCoordinator: coordinator)

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defaults = try #require(UserDefaults(suiteName: suite))
            settings = SettingsManager(defaults: defaults)
            settings.automation.assistant = .codex
            settings.automation.authorFeedback.runner = .assistant
            settings.automation.authorFeedback.isEnabled = true
            settings.automation.allowFollowUpPush = false
            glab = GlabService()
            glab.glabPath = directory.appending(path: "glab")
            glab.resolvedHost = Self.host
            glab.currentUsername = "me"
            try write("request.json", Self.request)
            try write("discussions.json", Self.discussions)
            try write("glab", """
                #!/bin/sh
                set -eu
                cd "$(dirname "$0")"
                test "$1" = api
                test "$3" = --hostname
                test "$4" = \(Self.host)
                case "$2" in
                  /projects/1/merge_requests/2) cat request.json ;;
                  */discussions\\?*) cat discussions.json ;;
                  /projects/1/merge_requests\\?*)
                    touch stack-read
                    if [ -e changed-request.json ]; then cp changed-request.json request.json; fi
                    if [ -e changed-discussions.json ]; then cp changed-discussions.json discussions.json; fi
                    printf '%s' '[]' ;;
                  /projects/1) printf '%s' '{"default_branch":"main"}' ;;
                  *) printf '%s' "Unexpected glab command: $*" >&2; exit 100 ;;
                esac
                """)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.appending(path: "glab").path)
        }

        func prepare(noteIDs: [Int] = [20], snapshot: String? = nil, manual: Bool = false, expectedHeadSHA: String? = nil,
                     using settingsOverride: SettingsManager? = nil) async throws {
            let discussion = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data((snapshot ?? Self.discussions).utf8))
            try await service.prepareFeedback(work: work, noteIDs: noteIDs, username: "me", settings: settingsOverride ?? settings,
                glab: glab, manual: manual, verifiedFingerprint: ReviewVerdict.fingerprint(discussion),
                expectedHeadSHA: expectedHeadSHA ?? Self.sha, shouldProceed: { true })
        }

        func waitForJob() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while coordinator.isWorking(on: work), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!coordinator.isWorking(on: work))
        }

        func write(_ name: String, _ content: String) throws { try Data(content.utf8).write(to: directory.appending(path: name)) }
        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
