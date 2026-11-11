import Foundation
import Observation
import os
import Testing
@testable import GitLabTodos

@MainActor
struct InboxTodoStoreTests {
    private let host = "gitlab.example.test"
    private let todoJSON = #"[{"id":401,"action_name":"assigned","target_type":"Issue","target_url":"https://gitlab.example.test/group/repo/-/issues/42","body":"Unread issue","state":"pending","created_at":"2026-11-06T10:00:00Z","project":{"id":1,"name_with_namespace":"Group / Repo","path_with_namespace":"group/repo"},"author":{"id":9,"username":"reviewer","name":"Reviewer"},"target":{"id":42,"iid":42,"title":"Unread issue","state":"opened"}}]"#

    @Test func safeKeepsPrivateAutomationButOnlyAnExplicitManualActionAcknowledgesTheTodo() async throws {
        try await fixture { store, gitlab, settings in
            settings.automation.applyPreset(.safe, for: .codex)
            try await fetch(store)
            let todo = try #require(store.visibleTodos.first)
            #expect(settings.automaticWritesAllowed && !settings.automaticPublicWritesAllowed)
            await store.markDone(todo, automatically: true)
            #expect(store.visibleTodos.map(\.id) == [401])
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
            await store.markDone(todo, automatically: false)
            #expect(store.visibleTodos.isEmpty)
            #expect(gitlab.requests.filter { $0.method == "POST" }.count == 1)
        }
    }

    @Test func switchingToPrivateWorkWhileAnAcknowledgementWaitsRevokesItsCommandAdmission() async throws {
        try await fixture { store, gitlab, settings in
            settings.automation.applyPreset(.trusted, for: .codex)
            try await fetch(store)
            let todo = try #require(store.visibleTodos.first)
            gitlab.beforeCommand = { request in
                if request.method == "POST" {
                    gitlab.write("ack-queued")
                    try await gitlab.waitFor("release-ack")
                }
            }
            let pending = Task { await store.markDone(todo, automatically: true) }
            try await gitlab.waitFor("ack-queued")
            settings.automation.allowAutomaticPublicActions = false
            gitlab.write("release-ack")
            await pending.value
            #expect(store.visibleTodos.map(\.id) == [401])
            #expect(gitlab.requests.filter { $0.method == "POST" }.isEmpty)
        }
    }

    private func fixture(_ body: (InboxTodoStore, InMemoryGitLab, SettingsManager) async throws -> Void) async throws {
        let name = "InboxTodoStoreTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        gitlab.handler = { request in
            if request.endpoint == "/user" { return InMemoryGitLab.output(#"{"id":7,"username":"alice"}"#) }
            if request.arguments.contains(where: { $0.hasPrefix("/todos?") }) { return InMemoryGitLab.output(todoJSON) }
            return InMemoryGitLab.output("{}")
        }
        let settings = SettingsManager(defaults: defaults)
        let store = InboxTodoStore(settings: settings, glab: gitlab.service(host: host, username: "alice"))
        try await body(store, gitlab, settings)
    }

    private func fetch(_ store: InboxTodoStore) async throws {
        store.beginRefresh()
        defer { store.finishRefresh() }
        let fetched = try #require(await store.fetch())
        let todos = try fetched.result.get()
        store.bindAccount(host: fetched.host, username: fetched.username, revision: fetched.revision)
        store.accept(todos)
    }

    @Test(arguments: [AutomationPackageDecision.undecided, .disabled, .enabled])
    func automaticAcknowledgementRequiresConsentWhileManualAcknowledgementRemainsAvailable(_ decision: AutomationPackageDecision) async throws {
        try await fixture { store, gitlab, settings in
            // given
            settings.automation.packageDecision = decision
            try await fetch(store)
            let todo = try #require(store.visibleTodos.first)

            // when
            await store.markDone(todo, automatically: true)

            // then
            let writes = gitlab.requests.filter { $0.method == "POST" }
            #expect(writes.count == (decision == .enabled ? 1 : 0))
            if decision != .enabled {
                #expect(store.visibleTodos.map(\.id) == [todo.id])
                await store.markDone(todo, automatically: false)
                #expect(gitlab.requests.filter { $0.method == "POST" }.count == 1)
            }
            #expect(store.visibleTodos.isEmpty)
        }
    }

    @Test(arguments: [true, false])
    func queuedAcknowledgementRechecksAutomaticConsentWithoutBlockingManualActions(_ automatically: Bool) async throws {
        try await fixture { store, gitlab, settings in
            settings.automation.packageDecision = .enabled
            try await fetch(store)
            let todo = try #require(store.visibleTodos.first)
            gitlab.beforeCommand = { request in
                if request.method == "POST" {
                    gitlab.write("acknowledgement-queued")
                    try await gitlab.waitFor("release-acknowledgement")
                }
            }
            let pending = Task { await store.markDone(todo, automatically: automatically) }
            try await gitlab.waitFor("acknowledgement-queued")
            settings.automation.packageDecision = .disabled
            gitlab.write("release-acknowledgement")
            await pending.value
            #expect(gitlab.requests.filter { $0.method == "POST" }.count == (automatically ? 0 : 1))
            #expect(store.visibleTodos.map(\.id) == (automatically ? [todo.id] : []))
        }
    }

    @Test func anAcknowledgedAutomaticWriteIsRecordedAfterConsentCloses() async throws {
        try await fixture { store, gitlab, settings in
            settings.automation.packageDecision = .enabled
            try await fetch(store)
            let todo = try #require(store.visibleTodos.first)
            let pending = TodoActionAcknowledgement(host: host, username: "alice", todo: todo.feedbackIdentity)
            settings.pendingTodoAcknowledgements.insert(pending)
            gitlab.handler = { request in
                #expect(request.method == "POST")
                settings.automation.packageDecision = .disabled
                return InMemoryGitLab.output("{}")
            }
            await store.markDone(todo, automatically: true)
            #expect(store.visibleTodos.isEmpty)
            #expect(!settings.pendingTodoAcknowledgements.contains(pending))
            #expect(settings.automation.packageDecision == .disabled)
        }
    }

    @Test func failedReadRetainsInboxAndAccountEpochPreventsReuse() async throws {
        try await fixture { store, gitlab, _ in
            try await fetch(store)
            gitlab.handler = { _ in InMemoryGitLab.output(error: "network unavailable", code: 1) }
            let failed = try #require(await store.fetch())
            if case .failure(let error) = failed.result { store.lastError = error }
            #expect(store.lastError != nil)
            #expect(store.currentAccountTodos.map(\.id) == [401])
            store.glab.currentUsername = "bob"
            store.glab.currentUsername = "alice"
            #expect(store.currentAccountTodos.isEmpty)
            #expect(store.allTodos.map(\.id) == [401])
        }
    }

    @Test func cancelledFetchDoesNotPublishAnErrorOrReplaceThePreviousInbox() async throws {
        try await fixture { store, gitlab, _ in
            try await fetch(store)
            gitlab.beforeCommand = { _ in
                gitlab.write("fetch-started")
                try await gitlab.waitFor("release-fetch")
            }
            let pending = Task { await store.fetch() }
            try await gitlab.waitFor("fetch-started")
            pending.cancel()
            gitlab.write("release-fetch")
            #expect(await pending.value == nil)
            #expect(store.lastError == nil && store.currentAccountTodos.map(\.id) == [401])
        }
    }

    @Test func undoRestoresVisibleTodoWithoutAcknowledgingIt() async throws {
        try await fixture { store, gitlab, _ in
            try await fetch(store)
            let todo = try #require(store.visibleTodos.first)
            store.markDoneWithUndo(todo)
            #expect(store.visibleTodos.isEmpty)
            #expect(store.undoableTodo?.id == todo.id)
            store.undoMarkDone()
            #expect(store.visibleTodos.map(\.id) == [401])
            #expect(store.undoableTodo == nil)
            #expect(!gitlab.requests.contains { $0.method == "POST" })
        }
    }

    @Test func acknowledgementDuringFetchCannotResurrectDoneTodo() async throws {
        try await fixture { store, gitlab, settings in
            try await fetch(store)
            let todo = try #require(store.visibleTodos.first)
            settings.lastSeenTodoIDs = [todo.id]
            gitlab.write("pause")
            gitlab.handler = { request in
                if request.arguments.contains(where: { $0.hasPrefix("/todos?") }) {
                    try await gitlab.pause(ifPresent: "pause", entered: "reading", until: "release")
                    return InMemoryGitLab.output(todoJSON)
                }
                return InMemoryGitLab.output("{}")
            }
            store.beginRefresh()
            let read = Task { await store.fetch() }
            try await gitlab.waitFor("reading")
            await store.markDone(todo, automatically: false)
            gitlab.write("release")
            let fetched = try #require(await read.value)
            let todos = try fetched.result.get()
            store.bindAccount(host: fetched.host, username: fetched.username, revision: fetched.revision)
            store.accept(todos)
            store.finishRefresh()
            #expect(store.allTodos.isEmpty)
            #expect(!settings.lastSeenTodoIDs.contains(todo.id))
        }
    }

    @Test func failedAcknowledgementRestoresOptimisticTodoAndNotifiesObservers() async throws {
        try await fixture { store, gitlab, _ in
            try await fetch(store)
            let todo = try #require(store.visibleTodos.first)
            gitlab.handler = { _ in InMemoryGitLab.output(error: "network unavailable", code: 1) }
            let changed = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking { _ = store.visibleTodos } onChange: { changed.withLock { $0 = true } }
            await store.markDone(todo, automatically: false)
            #expect(changed.withLock { $0 })
            #expect(store.visibleTodos.map(\.id) == [401])
            #expect(store.lastError != nil)
        }
    }

    @Test func monitorForwardingKeepsUndoAndInboxReadsObservable() async throws {
        try await fixture { store, gitlab, settings in
            settings.glabPath = store.glab.glabPath
            settings.resolvedHost = host
            settings.onboardingCompleted = false
            gitlab.handler = { request in
                if request.arguments.first == "config" { return InMemoryGitLab.output(host) }
                if request.arguments.first == "auth" {
                    return InMemoryGitLab.output(error: "Logged in to \(host) as alice")
                }
                if request.arguments.contains(where: { $0.hasPrefix("/todos?") }) { return InMemoryGitLab.output(todoJSON) }
                return InMemoryGitLab.output("[]")
            }
            let notifications = NotificationService(authorization: { .denied }, post: { _ in })
            let monitor = TodoMonitorService(settings: settings, glab: store.glab, notifications: notifications)
            await monitor.bootstrap()
            await monitor.refreshNow()
            defer { monitor.stopTimer() }
            let todo = try #require(monitor.currentAccountTodos.first)
            let changed = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking {
                _ = monitor.visibleTodos
                _ = monitor.undoableTodo
            } onChange: { changed.withLock { $0 = true } }
            #expect(monitor.userAttention.items.contains { $0.id.hasSuffix("/todo/401") })
            let attentionChanged = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking { _ = monitor.userAttention } onChange: {
                attentionChanged.withLock { $0 = true }
            }
            monitor.markDoneWithUndo(todo)
            #expect(changed.withLock { $0 })
            #expect(monitor.currentAccountTodos.isEmpty)
            #expect(monitor.undoableTodo?.id == todo.id)
            let deadline = ContinuousClock.now + .seconds(2)
            while !attentionChanged.withLock({ $0 }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(attentionChanged.withLock { $0 })
            #expect(!monitor.userAttention.items.contains { $0.id.hasSuffix("/todo/401") })
            monitor.undoMarkDone()
            #expect(monitor.currentAccountTodos.map(\.id) == [401])
        }
    }

}
