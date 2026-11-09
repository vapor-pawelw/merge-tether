import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct FeedbackSuggestionDecisionActionTests {
    private let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)

    private func note(_ body: String = "Please confirm the rollout prerequisite.", authorID: Int = 9) throws -> GitLabMergeRequestDiscussion.Note {
        try JSONDecoder().decode(GitLabMergeRequestDiscussion.Note.self, from: JSONSerialization.data(withJSONObject: [
            "id": 10, "body": body, "system": false, "author": ["id": authorID, "username": "reviewer", "name": "Reviewer"]
        ]))
    }

    @Test func explicitIgnoreRechecksTheExactSourceAndPersistsWithoutGitLabWritesOrManagement() async throws {
        try await fixture { monitor, settings, directory in
            let source = try note()
            try await monitor.ignoreFeedbackSuggestion(source, concernSummary: "Confirm the deployment prerequisite",
                concernReason: "External confirmation is missing.", for: target)
            let decision = try #require(settings.feedbackSuggestionDecisions.entries(for: target).first)
            #expect(decision.sourceNoteID == 10 && decision.sourceBody == source.body)
            #expect(decision.concernSummary == "Confirm the deployment prerequisite")
            #expect(SettingsManager(defaults: settingsDefaults(directory)).feedbackSuggestionDecisions.entries(for: target) == [decision])
            #expect(!settings.automation.scope.isManaged(target) && settings.mrActionIntents.isEmpty && settings.assistantHandoffs.isEmpty)
            #expect(settings.mrLifecycleLedger.targets(host: target.host, username: target.username).isEmpty)
            #expect(settings.automationEvents.contains { $0.target == target && $0.origin == .manual && $0.state == .completed })
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "write-attempt").path))
        }
    }

    @Test(arguments: ["body", "author", "account", "emptyConcern"])
    func changedSourceOrAccountCannotRecordAConfirmedDecision(_ mismatch: String) async throws {
        try await fixture { monitor, settings, directory in
            if mismatch == "body" || mismatch == "author" {
                try writeDiscussions(note(mismatch == "body" ? "Different feedback" : "Please confirm the rollout prerequisite.",
                    authorID: mismatch == "author" ? 8 : 9), directory: directory)
            }
            if mismatch == "account" { monitor.glab.currentUsername = "another" }
            let expected: FeedbackSuggestionDecisionError = mismatch == "account" ? .accountChanged
                : mismatch == "emptyConcern" ? .invalidConcern : .sourceChanged
            await #expect(throws: expected) {
                try await monitor.ignoreFeedbackSuggestion(note(), concernSummary: mismatch == "emptyConcern" ? " " : "Confirm rollout",
                    concernReason: "External confirmation is missing.", for: target)
            }
            #expect(settings.feedbackSuggestionDecisions.entries(for: target).isEmpty)
            #expect(settings.automationEvents.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "write-attempt").path))
        }
    }

    @Test func restoringAndResettingOnlyThisMRPreservesHistoryAndOtherMRDecisions() async throws {
        try await fixture { monitor, settings, directory in
            let source = try note()
            let firstResult = settings.feedbackSuggestionDecisions.ignore(source, concernSummary: "First", concernReason: "First concern", for: target)
            let first = try #require(firstResult)
            let secondResult = settings.feedbackSuggestionDecisions.ignore(source, concernSummary: "Second", concernReason: "Second concern", for: target)
            let second = try #require(secondResult)
            let other = MRAutomationScope.Target(host: target.host, username: target.username, projectID: 1, iid: 3)
            let unrelatedResult = settings.feedbackSuggestionDecisions.ignore(source, concernSummary: "Other MR", concernReason: "Unrelated", for: other)
            let unrelated = try #require(unrelatedResult)
            settings.save()
            try await monitor.restoreFeedbackSuggestion(first.id, for: target)
            #expect(settings.feedbackSuggestionDecisions.entries(for: target).map(\.id) == [second.id])
            let count = settings.automationEvents.count
            #expect(count > 0)
            try await monitor.resetFeedbackSuggestionDecisions(for: target)
            #expect(settings.feedbackSuggestionDecisions.entries(for: target).isEmpty)
            #expect(settings.feedbackSuggestionDecisions.entries(for: other) == [unrelated])
            #expect(settings.automationEvents.count > count)
            #expect(SettingsManager(defaults: settingsDefaults(directory)).feedbackSuggestionDecisions.entries(for: target).isEmpty)
        }
    }

    private func settingsDefaults(_ directory: URL) -> UserDefaults {
        UserDefaults(suiteName: "FeedbackSuggestionDecisionActionTests.\(directory.lastPathComponent)")!
    }

    private func writeDiscussions(_ source: GitLabMergeRequestDiscussion.Note, directory: URL) throws {
        let discussion: [String: Any] = ["id": "discussion", "notes": try JSONSerialization.jsonObject(with: JSONEncoder().encode([source]))]
        try JSONSerialization.data(withJSONObject: [discussion]).write(to: directory.appending(path: "discussions.json"))
    }

    private func fixture(_ body: (TodoMonitorService, SettingsManager, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let defaults = settingsDefaults(directory)
        defer {
            defaults.removePersistentDomain(forName: "FeedbackSuggestionDecisionActionTests.\(directory.lastPathComponent)")
            try? FileManager.default.removeItem(at: directory)
        }
        try writeDiscussions(note(), directory: directory)
        try Data("""
        {"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"MR",
         "web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened",
         "sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_branch":"feature","target_branch":"main","labels":[]}
        """.utf8).write(to: directory.appending(path: "request.json"))
        let executable = directory.appending(path: "glab")
        try Data("""
        #!/bin/sh
        set -eu
        cd "$(dirname "$0")"
        case "$*" in *--method*|*--raw-field*|*--field*) touch write-attempt; exit 200 ;; esac
        case "$*" in
          'config get host') printf '%s' 'gitlab.example.test'; exit 0 ;;
          'auth status') printf '%s' 'Logged in to gitlab.example.test as me' >&2; exit 0 ;;
        esac
        case "$2" in
          /user) printf '%s' '{"id":3,"username":"me"}' ;;
          /projects/1/merge_requests/2) cat request.json ;;
          /projects/1/merge_requests/2/discussions*) cat discussions.json ;;
          *) printf '%s' '[]' ;;
        esac
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let settings = SettingsManager(defaults: defaults)
        settings.resolvedHost = target.host
        settings.glabPath = executable
        let glab = GlabService()
        glab.currentUsername = target.username
        let monitor = TodoMonitorService(settings: settings, glab: glab)
        try await body(monitor, settings, directory)
    }
}
