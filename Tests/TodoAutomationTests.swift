import Foundation
import Testing
@testable import GitLabTodos

@Suite("To-do automation")
struct TodoAutomationTests {
    @Test("review request titles identify the MR author rather than the event actor")
    func reviewRequest() throws {
        let todo = try makeTodo(action: "review_requested", author: "anna")
        let event = try #require(TodoAutomationEvent(todo: todo, username: "me"))
        let author = try #require(todo.target.author)
        let context = TodoAutomationContext(todo: todo, event: event, author: author, iid: 1220)

        #expect(event == .reviewRequested)
        #expect(context.render("{repo} !{iid} ({author})") == "cards-api !1220 (Anna W)")
        #expect(context.render("{project} {actor} {unknown}") == "bank/cards-api Peter Reviewer {unknown}")
        #expect(context.environment(taskTitle: "test")["GITLAB_MR_AUTHOR"] == "Anna White")
    }

    @Test("only feedback from other people on my open MRs matches")
    func authorFeedback() throws {
        let review = try makeTodo(action: "review_submitted", author: "me")
        let comment = try makeTodo(action: "mentioned", author: "me", fragment: "#note_42")
        let description = try makeTodo(action: "mentioned", author: "me")
        let otherMR = try makeTodo(action: "directly_addressed", author: "anna", fragment: "#note_42")
        let selfComment = try makeTodo(action: "directly_addressed", author: "me", actor: "me", fragment: "#note_42")
        let closed = try makeTodo(action: "review_requested", author: "anna", state: "closed")
        let issue = try makeTodo(action: "review_requested", author: "anna", type: "Issue")

        #expect(TodoAutomationEvent(todo: review, username: "me") == .authorFeedback)
        #expect(TodoAutomationEvent(todo: comment, username: "me") == .authorFeedback)
        #expect(TodoAutomationEvent(todo: description, username: "me") == nil)
        let otherEvent = try #require(TodoAutomationEvent(todo: otherMR, username: "me"))
        #expect(!otherEvent.accepts(author: try #require(otherMR.target.author), username: "me"))
        #expect(TodoAutomationEvent(todo: selfComment, username: "me") == nil)
        #expect(TodoAutomationEvent(todo: closed, username: "me") == nil)
        #expect(TodoAutomationEvent(todo: issue, username: "me") == nil)
    }

    @MainActor
    @Test("existing installations opt in explicitly and completed launches survive reload")
    func settingsRoundTrip() throws {
        let name = "GitLabTodosTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(defaults: defaults)
        #expect(!settings.automation.reviewRequested.isEnabled)
        #expect(!settings.automation.authorFeedback.isEnabled)

        settings.automation.authorFeedback.isEnabled = true
        settings.automation.authorFeedback.runner = .shell
        settings.automation.authorFeedback.command = "printf '%s' \"$GITLAB_MR_URL\""
        let key = TodoAutomationReceipt(host: "gitlab.example.org", username: "me", todoID: 42)
        settings.automationReceipts.insert(key)
        settings.save()

        let reloaded = SettingsManager(defaults: defaults)
        #expect(reloaded.automation == settings.automation)
        #expect(reloaded.automationReceipts.contains(key))
        #expect(!reloaded.automationReceipts.contains(.init(host: "gitlab.example.org", username: "other", todoID: 42)))
    }

    @Test("the fallback keeps Duo comments without a TODO and yields to matching GitLab TODOs")
    func fallbackCoverage() throws {
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data("""
        [{"notes":[
          {"id":42,"author":{"id":7,"username":"GitLabDuo"},"system":false,"resolvable":true,"resolved":false},
          {"id":43,"author":{"id":8,"username":"another-reviewer"},"system":false,"resolvable":true,"resolved":false},
          {"id":44,"author":{"id":9,"username":"me"},"system":false,"resolvable":true,"resolved":false},
          {"id":45,"author":{"id":7,"username":"GitLabDuo"},"system":false,"resolvable":true,"resolved":true}
        ]}]
        """.utf8))
        let comment = try makeTodo(action: "mentioned", author: "me", fragment: "#note_42")
        let open = GitLabMergeRequestDiscussion.unresolvedFeedback(in: discussions, excluding: 9)
        func remaining(_ todos: [Todo]) -> [Int] {
            TodoAutomationEvent.feedbackWithoutTodo(
                open, todos: todos, host: "gitlab.example.org", projectID: comment.project.id, iid: 1220, username: "me"
            ).compactMap(\.id)
        }
        #expect(remaining([]) == [42, 43])
        #expect(remaining([comment]) == [43])
    }

    @MainActor
    @Test("Codex follow-up permissions and remote-proof order are explicit without requiring an MR skill", arguments: [true, false])
    func codexFollowUpUsesLocalGitLabRead(pushAllowed: Bool) async throws {
        let todo = try makeTodo(action: "mentioned", author: "me", fragment: "#note_42")
        let suite = "GitLabTodosTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsManager(defaults: defaults)
        let automation = TodoAutomationService()
        settings.automation.allowFollowUpPush = pushAllowed

        let acknowledge = try await automation.prepareToAcknowledge(
            todo, event: .authorFeedback, host: "gitlab.example.org", username: "me",
            settings: settings, glab: GlabService(), manual: true, isPending: { true }
        )
        #expect(acknowledge)
        let handoff = try #require(settings.assistantHandoffs.first)
        #expect(handoff.title == "[MT] cards-api !1220 (Own)")
        #expect(handoff.key.access == .gitLabRead)
        #expect(handoff.openedAt == nil)
        #expect(handoff.feedbackTodos == nil)
        #expect(SettingsManager(defaults: defaults).pendingTodoAcknowledgements == [
            .init(host: "gitlab.example.org", username: "me", todo: todo.feedbackIdentity)
        ])
        settings.automation.codexRelayEnabled = true
        CodexDesktopRelay.synchronize(settings: settings, host: "gitlab.example.org", username: "me", directory: directory)
        let jobURL = directory.appending(path: "jobs/\(handoff.id.uuidString.lowercased()).json")
        struct Job: Decodable { let prompt: String; let repository: String? }
        let job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: jobURL))
        #expect(job.repository == "cards-api")
        let prompt = job.prompt
        #expect(prompt.contains("`read_merge_request` tool"))
        #expect(handoff.followUpPushAllowed == pushAllowed)
        if pushAllowed {
            #expect(prompt.contains("without a separate push prompt"))
            #expect(prompt.contains("Mandatory author follow-up order, even without installed MR skills"))
            #expect(prompt.contains("author_follow_up_status"))
            #expect(prompt.contains("verify_author_follow_up"))
            #expect(prompt.contains("For human or uncertain feedback, leave drafts private"))
            #expect(prompt.contains("record_author_follow_up_drafts"))
            #expect(prompt.contains("headSHA"))
            #expect(prompt.contains("runID `\(handoff.id.uuidString.lowercased())`"))
            #expect(prompt.contains("private `draft_notes` endpoint"))
            #expect(prompt.contains("Never substitute a published note or a chat-only draft"))
        } else {
            #expect(prompt.contains("Automatic author-follow-up push is OFF"))
            #expect(prompt.contains("do not push, save author-follow-up response drafts, or publish anything"))
            #expect(!prompt.contains("verify_author_follow_up"))
            #expect(!prompt.contains("save replies as GitLab drafts"))
        }
        #expect(prompt.hasPrefix("\(todo.targetURL.absoluteString)\n\n"))
        #expect(prompt.contains("Start your final update with a clickable Markdown link"))
        #expect(prompt.contains("git worktree add --detach"))
        if pushAllowed { #expect(prompt.contains("Get my explicit approval before publishing")) }
        #expect(!prompt.contains("<gitlab-evidence>"))
        #expect(prompt.contains("load and follow the applicable installed MR skills"))
        #expect(prompt.contains("Use the fallback below only where no applicable skill or explicit workflow covers the step."))
        #expect(prompt.contains("only the indicated feedback"))
        #expect(prompt.contains("Summarize what you did or found"))
    }

    @MainActor
    @Test("a repeat review on the same MR runs once for its new to-do ID")
    func shellReceipt() async throws {
        let todo = try makeTodo(action: "review_requested", author: "anna")
        let repeatRequest = try makeTodo(action: "review_requested", author: "anna", id: 43)
        let name = "GitLabTodosTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(defaults: defaults)
        let glab = GlabService()
        let automation = TodoAutomationService()

        settings.automation.reviewRequested.isEnabled = true
        settings.automation.reviewRequested.markDoneOnSuccess = true
        settings.automation.reviewRequested.runner = .shell
        settings.automation.reviewRequested.projects = "bank/cards-api"
        settings.automation.reviewRequested.command = """
            [ "$GITLAB_TASK_TITLE" = "cards-api !1220 (Anna W)" ] &&
            [ "$GITLAB_PROJECT_PATH" = "bank/cards-api" ] &&
            [ "$GITLAB_TODO_EVENT" = "review_requested" ]
            """

        func run(_ todo: Todo) async throws -> Bool {
            let event = try #require(TodoAutomationEvent(todo: todo, username: "me"))
            return try await automation.prepareToAcknowledge(
                todo, event: event, host: "gitlab.example.org", username: "me",
                settings: settings, glab: glab, isPending: { true }
            )
        }

        #expect(try await run(todo))
        settings.automation.reviewRequested.command = "exit 17"
        #expect(try await run(todo))

        settings.automation.reviewRequested.command = #"[ "$GITLAB_TODO_ID" = "43" ]"#
        #expect(try await run(repeatRequest))
        #expect(Set(settings.automationReceipts.map(\.todoID)) == [42, 43])

        automation.prune(fetchedIDs: [43], host: "gitlab.example.org", username: "me", settings: settings)
        #expect(Set(settings.automationReceipts.map(\.todoID)) == [43])
        settings.automation.reviewRequested.command = "exit 17"
        #expect(try await run(repeatRequest))
        await #expect(throws: (any Error).self) { try await run(todo) }
        #expect(try await !run(todo))
    }

    @MainActor
    @Test("polling retries a failed GitLab acknowledgement without repeating the script")
    func acknowledgesAfterShellSuccess() async throws {
        let todo = try makeTodo(action: "review_requested", author: "anna")
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([todo]).write(to: folder.appending(path: "inbox.json"))
        let glab = folder.appending(path: "glab")
        try Data("""
            #!/bin/sh
            set -eu
            cd "$(dirname "$0")"
            case "$*" in
                'config get host') echo gitlab.example.org ;;
                'auth status') echo 'Logged in to gitlab.example.org as me' >&2 ;;
                'api --paginate /todos?per_page=100&state=pending --hostname gitlab.example.org')
                    if [ -e acknowledged ]; then echo '[]'; else cat inbox.json; fi ;;
                'api --method POST /todos/42/mark_as_done --hostname gitlab.example.org')
                    if [ ! -e attempted ]; then
                        touch attempted
                        exit 1
                    fi
                    touch acknowledged ;;
                *) exit 100 ;;
            esac
            """.utf8).write(to: glab)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: glab.path)

        let name = "GitLabTodosTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(defaults: defaults)
        settings.glabPath = glab
        settings.onboardingCompleted = true
        settings.notificationsEnabled = false
        settings.automation.reviewRequested.isEnabled = true
        settings.automation.reviewRequested.markDoneOnSuccess = true
        settings.automation.reviewRequested.runner = .shell
        settings.automation.reviewRequested.projects = "bank/cards-api"
        let actionLog = folder.appending(path: "action.log")
        settings.automation.reviewRequested.command = "echo run >> '\(actionLog.path)'"

        let monitor = TodoMonitorService(settings: settings)
        defer { monitor.stopTimer() }
        let clock = ContinuousClock()
        let firstDeadline = clock.now + .seconds(5)
        while monitor.lastError == nil, clock.now < firstDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(monitor.lastError != nil)
        #expect(monitor.visibleTodos.map(\.id) == [42])

        await monitor.refreshNow()
        let secondDeadline = clock.now + .seconds(5)
        while !monitor.allTodos.isEmpty, clock.now < secondDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(monitor.visibleTodos.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "acknowledged").path))
        #expect(try String(contentsOf: actionLog, encoding: .utf8) == "run\n")
    }

    @MainActor
    @Test("a click bypasses automatic scope and prevents a later duplicate")
    func manualDispatch() async throws {
        let todo = try makeTodo(action: "review_requested", author: "anna")
        let event = try #require(TodoAutomationEvent(todo: todo, username: "me"))
        let name = "GitLabTodosTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(defaults: defaults)
        let service = TodoAutomationService()
        let glab = GlabService()
        settings.automation.reviewRequested.runner = .shell
        settings.automation.reviewRequested.projects = "bank/cards-api"
        settings.automation.reviewRequested.command = "exit 0"
        settings.automation.scope.mode = .selected
        settings.automation.reviewRequested.isEnabled = true
        let automatic = try await service.prepareToAcknowledge(
            todo, event: event, host: "gitlab.example.org", username: "me", settings: settings,
            glab: glab, isPending: { true }
        )
        #expect(!automatic)
        #expect(settings.automationReceipts.isEmpty)
        let acknowledge = try await service.prepareToAcknowledge(
            todo, event: event, host: "gitlab.example.org", username: "me", settings: settings,
            glab: glab, manual: true, isPending: { true }
        )
        #expect(acknowledge)
        #expect(settings.automationReceipts.count == 1)

        settings.automation.reviewRequested.command = "exit 41"
        _ = try await service.prepareToAcknowledge(
            todo, event: event, host: "gitlab.example.org", username: "me", settings: settings,
            glab: glab, isPending: { true }
        )
        #expect(settings.automationReceipts.count == 1)
    }

    @MainActor
    @Test("click and automatic polling share a reservation before awaiting MR details")
    func sharedReservation() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }

        let todo = try makeTodo(action: "review_requested", author: "anna", hasTargetAuthor: false)
        let event = try #require(TodoAutomationEvent(todo: todo, username: "me"))
        let executable = folder.appending(path: "glab")
        try Data("""
            #!/bin/sh
            set -eu
            cd "$(dirname "$0")"
            touch lookup-started
            for i in 1 2 3 4 5 6 7 8 9 10; do
                [ ! -f release-lookup ] || break
                sleep 0.1
            done
            printf '%s\\n' '{"author":{"id":3,"username":"anna","name":"Anna White"}}'
            """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let name = "GitLabTodosTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(defaults: defaults)
        let glab = GlabService()
        glab.glabPath = executable
        let service = TodoAutomationService()
        settings.automation.reviewRequested.runner = .shell
        settings.automation.reviewRequested.projects = "bank/cards-api"
        settings.automation.reviewRequested.command = "mkdir '\(folder.path)/launched-once'"
        settings.automation.reviewRequested.isEnabled = true
        let automatic = Task {
            try await service.prepareToAcknowledge(
                todo, event: event, host: "gitlab.example.org", username: "me",
                settings: settings, glab: glab, isPending: { true }
            )
        }
        let lookupDeadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < lookupDeadline {
            if FileManager.default.fileExists(atPath: folder.appending(path: "lookup-started").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "lookup-started").path))
        _ = try await service.prepareToAcknowledge(
            todo, event: event, host: "gitlab.example.org", username: "me",
            settings: settings, glab: glab, manual: true, isPending: { true }
        )
        try Data().write(to: folder.appending(path: "release-lookup"))
        _ = try await automatic.value
        #expect(settings.automationReceipts.count == 1)
    }

    private func makeTodo(
        action: String,
        author: String,
        actor: String = "peter",
        fragment: String = "",
        state: String = "opened",
        type: String = "MergeRequest",
        id: Int = 42,
        hasTargetAuthor: Bool = true
    ) throws -> Todo {
        let targetAuthor = hasTargetAuthor ? #", "author": {"id": 3, "username": "\#(author)", "name": "Anna White"}"# : ""
        let json = """
        [{
          "id": \(id), "action_name": "\(action)", "target_type": "\(type)",
          "target_url": "https://gitlab.example.org/bank/cards-api/-/merge_requests/1220\(fragment)",
          "body": "Title", "created_at": "2026-11-04T10:00:00Z", "state": "pending",
          "project": {"id": 1, "name_with_namespace": "Bank / Cards API", "path_with_namespace": "bank/cards-api"},
          "author": {"id": 2, "username": "\(actor)", "name": "Peter Reviewer"},
          "target": {"iid": 1220, "state": "\(state)"\(targetAuthor)}
        }]
        """
        return try #require(GlabService.decodeTodos(Data(json.utf8)).first)
    }
}
