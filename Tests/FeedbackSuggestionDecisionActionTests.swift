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

    @Test(arguments: ["ignore", "restore", "reset"])
    func feedbackDecisionRefreshesOnlyItsMergeRequestAndKeepsTheInbox(_ action: String) async throws {
        let suite = "FeedbackDecisionScopedRefresh.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: target.host, username: target.username)
        let settings = SettingsManager(defaults: defaults)
        settings.glabPath = glab.glabPath
        settings.resolvedHost = target.host
        settings.onboardingCompleted = false
        settings.automation.applyPreset(.manual, for: .codex)
        let selected = MergeRequestAttentionMonitor.Item.ID(projectID: 1, iid: 2)
        let unrelated = MergeRequestAttentionMonitor.Item.ID(projectID: 7, iid: 9)
        let source = try note()
        func mergeRequest(projectID: Int, iid: Int, title: String) -> String {
            """
            {"project_id":\(projectID),"iid":\(iid),"author":{"id":3,"username":"me","name":"Me"},"title":"\(title)",
             "web_url":"https://gitlab.example.test/group/repo\(projectID)/-/merge_requests/\(iid)","state":"opened","draft":false,
             "sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_branch":"feature","target_branch":"main","labels":[]}
            """
        }
        gitlab.write("selected", mergeRequest(projectID: 1, iid: 2, title: "Selected before decision"))
        gitlab.write("unrelated", mergeRequest(projectID: 7, iid: 9, title: "Unrelated before decision"))
        gitlab.write("todos", #"[{"id":401,"action_name":"mentioned","target_type":"MergeRequest","target_url":"https://gitlab.example.test/group/repo7/-/merge_requests/9","body":"Unread feedback","state":"pending","created_at":"2026-11-06T10:00:00Z","project":{"id":7,"name_with_namespace":"Group / Repo7","path_with_namespace":"group/repo7"},"author":{"id":9,"username":"reviewer","name":"Reviewer"},"target":{"id":9,"iid":9,"title":"Unrelated before decision","state":"opened"}}]"#)
        let encodedSource = try JSONSerialization.jsonObject(with: JSONEncoder().encode([source]))
        gitlab.handler = { request in
            if request.arguments.first == "config" { return InMemoryGitLab.output(target.host) }
            if request.arguments.first == "auth" { return InMemoryGitLab.output(error: "Logged in to \(target.host) as \(target.username)") }
            if request.arguments.contains(where: { $0.hasPrefix("/todos?") }) { return try gitlab.response("todos") }
            switch request.endpoint {
            case "/user": return InMemoryGitLab.output(#"{"id":3,"username":"me"}"#)
            case "/projects/1/merge_requests/2": return try gitlab.response("selected")
            case "/projects/7/merge_requests/9": return try gitlab.response("unrelated")
            case let path where path.hasPrefix("/projects/1/merge_requests/2/discussions"):
                return try InMemoryGitLab.json([["id": "discussion", "notes": encodedSource]])
            case let path where path.hasPrefix("/merge_requests?scope=created_by_me"):
                return InMemoryGitLab.output("[\(gitlab.text("selected")),\(gitlab.text("unrelated"))]")
            default: return InMemoryGitLab.output("[]")
            }
        }
        let monitor = TodoMonitorService(settings: settings, glab: glab,
            notifications: NotificationService(authorization: { .denied }, post: { _ in }))
        defer { monitor.stopTimer() }
        await monitor.bootstrap()
        await monitor.refreshNow()
        monitor.attention.refresh(host: target.host, username: target.username, todos: monitor.currentAccountTodos)
        try await waitForRefresh(monitor.attention)
        try #require(monitor.attention.currentOpenItems.first { $0.id == selected }?.title == "Selected before decision")
        try #require(monitor.attention.currentOpenItems.first { $0.id == unrelated }?.title == "Unrelated before decision")
        try #require(monitor.currentAccountTodos.map(\.id) == [401])

        gitlab.write("selected", mergeRequest(projectID: 1, iid: 2, title: "Selected updated"))
        gitlab.write("unrelated", mergeRequest(projectID: 7, iid: 9, title: "Unrelated updated"))
        gitlab.requests.removeAll()
        if action == "ignore" {
            try await monitor.ignoreFeedbackSuggestion(source, concernSummary: "Confirm the rollout", concernReason: "Needs confirmation", for: target)
        } else {
            let savedDecision = settings.feedbackSuggestionDecisions.ignore(source, concernSummary: "Confirm the rollout",
                concernReason: "Needs confirmation", for: target)
            let decision = try #require(savedDecision)
            if action == "restore" {
                try await monitor.restoreFeedbackSuggestion(decision.id, for: target)
            } else {
                try await monitor.resetFeedbackSuggestionDecisions(for: target)
            }
        }
        try await waitForRefresh(monitor.attention)

        let requests = gitlab.requests
        #expect(requests.filter { $0.endpoint.hasPrefix("/projects/1/merge_requests/2/draft_notes") }.count == 1)
        #expect(!requests.contains { $0.endpoint.hasPrefix("/merge_requests?") || $0.arguments.contains(where: { $0.hasPrefix("/todos?") })
            || $0.endpoint.hasPrefix("/projects/7/merge_requests/9/draft_notes") })
        #expect(requests.allSatisfy { $0.method == "GET" })
        #expect(monitor.currentAccountTodos.map(\.id) == [401])
        #expect(monitor.attention.currentOpenItems.first { $0.id == unrelated }?.title == "Unrelated before decision")
        #expect(monitor.attention.currentOpenItems.first { $0.id == selected }?.title == "Selected updated")
    }

    private func waitForRefresh(_ monitor: MergeRequestAttentionMonitor) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while monitor.isLoading && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!monitor.isLoading)
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
