import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct MRCatalogStalenessTests {
    private let host = "gitlab.example.org"

    @Test func readyMergeActionMustRemainInInboxWhenOwnViewIsReadOnly() {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 1), title: "Ready",
            url: URL(string: "https://gitlab.example.org/g/p/-/merge_requests/1")!)
        item.needsMerge = true
        #expect(item.needsAttention)
    }

    @Test func switchingAccountInvalidatesCatalogFreshnessBeforeAnotherPoll() async throws {
        let h = try harness()
        defer { h.cleanUp() }
        try await h.poll()
        #expect(h.monitor.hasCurrentOwnListing)
        h.glab.currentUsername = "another-user"
        #expect(!h.monitor.hasCurrentOwnListing)
    }

    @Test(arguments: ["fail-auth", "fail-owned", "fail-reviewing", "fail-explicit"])
    func initialCatalogWaitsForAllSourcesThenStaysSyncedAfterASoftFailure(_ failedSource: String) async throws {
        let h = try harness()
        defer { h.cleanUp() }
        let explicit = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 3)
        h.settings.automation.scope[explicit] = .active
        #expect(!h.monitor.hasSyncedCurrentCatalog)
        try h.write(failedSource, "yes")

        try await h.poll()

        #expect(h.monitor.hasError && !h.monitor.hasSyncedCurrentCatalog)
        try FileManager.default.removeItem(at: h.folder.appending(path: failedSource))
        try await h.poll()
        #expect(h.monitor.hasSyncedCurrentCatalog)
        #expect(Set(h.monitor.currentOpenItems.map(\.id.iid)) == [1, 2, 3])
        try h.write(failedSource, "yes")
        try await h.poll()
        #expect(h.monitor.hasError && h.monitor.hasSyncedCurrentCatalog)
        #expect(Set(h.monitor.currentOpenItems.map(\.id.iid)) == [1, 2, 3])
    }

    @Test(arguments: [true, false])
    func accountRoundTripCannotResurrectReadinessWithoutAnotherSync(_ switchHost: Bool) async throws {
        let h = try harness()
        defer { h.cleanUp() }
        let authored = h.authoredMonitor()
        try await h.poll()
        try await h.pollAuthored(authored)
        try #require(h.monitor.hasSyncedCurrentCatalog && authored.hasSyncedCurrentCatalog)
        if switchHost {
            h.glab.resolvedHost = "other.example.org"
            h.glab.resolvedHost = host
        } else {
            h.glab.currentUsername = "other"
            h.glab.currentUsername = "me"
        }
        #expect(!h.monitor.hasSyncedCurrentCatalog)
        #expect(!authored.hasSyncedCurrentCatalog)
        try await h.poll()
        try await h.pollAuthored(authored)
        #expect(h.monitor.hasSyncedCurrentCatalog && authored.hasSyncedCurrentCatalog)
        h.glab.currentUsername = "me"
        h.glab.resolvedHost = host
        #expect(h.monitor.hasSyncedCurrentCatalog && authored.hasSyncedCurrentCatalog)
    }

    @Test func anEmptyCatalogIsACompletedSync() async throws {
        let h = try harness()
        defer { h.cleanUp() }
        try h.write("owned.json", "[]")
        try h.write("reviewing.json", "[]")
        try await h.poll()
        #expect(h.monitor.hasSyncedCurrentCatalog && h.monitor.currentOpenItems.isEmpty)
    }

    @Test func discussionFailureStillCompletesInitialCatalogSync() async throws {
        let h = try harness()
        defer { h.cleanUp() }
        try h.write("fail-discussions", "yes")
        try await h.poll()
        #expect(h.monitor.hasError && h.monitor.hasSyncedCurrentCatalog)
    }

    @Test func accountSwitchDoesNotInheritThePreviousAccountsStickySync() async throws {
        let h = try harness()
        defer { h.cleanUp() }
        try await h.poll()
        #expect(h.monitor.hasSyncedCurrentCatalog)
        h.glab.currentUsername = "other"
        #expect(!h.monitor.hasSyncedCurrentCatalog)
        try h.write("user.json", #"{"id":8,"username":"other"}"#)
        try h.write("fail-owned", "yes")
        try await h.poll(username: "other")
        #expect(!h.monitor.hasSyncedCurrentCatalog)
        h.glab.currentUsername = "me"
        #expect(!h.monitor.hasSyncedCurrentCatalog)
    }

    @Test(arguments: [false, true])
    func anObsoleteInFlightCatalogCannotMarkAnotherAccountSynced(_ returnsToOriginal: Bool) async throws {
        let h = try harness()
        defer { h.cleanUp() }
        try h.write("pause-owned", "yes")
        h.monitor.refresh(host: host, username: "me", todos: [])
        try await h.waitForFile("owned-started")
        h.glab.currentUsername = "other"
        if returnsToOriginal { h.glab.currentUsername = "me" }
        try h.write("release-owned", "yes")
        let deadline = ContinuousClock.now + .seconds(5)
        while h.monitor.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!h.monitor.isLoading)
        #expect(!h.monitor.hasSyncedCurrentCatalog)
    }

    @Test(arguments: [false, true])
    func anAccountRefreshRequestedDuringAnOlderPollRunsWithoutAnotherUserRefresh(_ returnsToOriginal: Bool) async throws {
        let h = try harness()
        defer { h.cleanUp() }
        try h.write("pause-owned", "yes")
        h.monitor.refresh(host: host, username: "me", todos: [])
        try await h.waitForFile("owned-started")
        try await h.waitForFile("user-read")
        h.glab.currentUsername = "other"
        try h.write("user.json", #"{"id":8,"username":"other"}"#)
        h.monitor.refresh(host: host, username: "other", todos: [])
        if returnsToOriginal {
            h.glab.currentUsername = "me"
            try h.write("user.json", #"{"id":3,"username":"me"}"#)
            h.monitor.refresh(host: host, username: "me", todos: [])
        }
        try h.write("release-owned", "yes")
        let deadline = ContinuousClock.now + .seconds(5)
        while h.monitor.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!h.monitor.isLoading)
        #expect(h.monitor.hasSyncedCurrentCatalog)
    }

    @Test(arguments: [false, true])
    func anAuthoredRefreshRequestedDuringAnOlderPollRunsWithoutAnotherUserRefresh(_ returnsToOriginal: Bool) async throws {
        let h = try harness()
        defer { h.cleanUp() }
        let monitor = h.authoredMonitor()
        try h.write("pause-owned", "yes")
        monitor.setVisible(true)
        try await h.waitForFile("owned-started")
        try await h.waitForFile("user-read")
        h.glab.currentUsername = "other"
        try h.write("user.json", #"{"id":8,"username":"other"}"#)
        monitor.refreshIfNeeded()
        if returnsToOriginal {
            h.glab.currentUsername = "me"
            try h.write("user.json", #"{"id":3,"username":"me"}"#)
            monitor.refreshIfNeeded()
        }
        try h.write("release-owned", "yes")
        let deadline = ContinuousClock.now + .seconds(5)
        while monitor.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!monitor.isLoading)
        #expect(monitor.hasSyncedCurrentCatalog)
    }

    @Test(arguments: ["fail-auth", "fail-owned"])
    func authoredCatalogSyncIsStickyOnlyAfterASuccessfulCurrentListing(_ failedSource: String) async throws {
        let h = try harness()
        defer { h.cleanUp() }
        let monitor = h.authoredMonitor()
        #expect(!monitor.hasSyncedCurrentCatalog)
        try h.write(failedSource, "yes")
        try await h.pollAuthored(monitor)
        #expect(monitor.hasError && !monitor.hasSyncedCurrentCatalog)
        try FileManager.default.removeItem(at: h.folder.appending(path: failedSource))
        try await h.pollAuthored(monitor)
        #expect(monitor.hasSyncedCurrentCatalog && monitor.requests.count == 1)
        try h.write(failedSource, "yes")
        try await h.pollAuthored(monitor)
        #expect(monitor.hasError && monitor.hasSyncedCurrentCatalog && monitor.requests.count == 1)
        h.glab.currentUsername = "other"
        #expect(!monitor.hasSyncedCurrentCatalog)
        try h.write("user.json", #"{"id":8,"username":"other"}"#)
        try await h.pollAuthored(monitor)
        #expect(!monitor.hasSyncedCurrentCatalog && monitor.requests.isEmpty)
        h.glab.currentUsername = "me"
        #expect(!monitor.hasSyncedCurrentCatalog)
    }

    @Test func emptyAuthoredCatalogCompletesItsInitialSync() async throws {
        let h = try harness()
        defer { h.cleanUp() }
        try h.write("owned.json", "[]")
        let monitor = h.authoredMonitor()
        try await h.pollAuthored(monitor)
        #expect(monitor.hasSyncedCurrentCatalog && monitor.requests.isEmpty)
    }

    @Test(arguments: [false, true])
    func obsoleteInFlightAuthoredListingCannotCompleteAnotherAccountsInitialSync(_ returnsToOriginal: Bool) async throws {
        let h = try harness()
        defer { h.cleanUp() }
        let monitor = h.authoredMonitor()
        try h.write("pause-owned", "yes")
        monitor.setVisible(true)
        try await h.waitForFile("owned-started")
        h.glab.resolvedHost = "another.example.org"
        if returnsToOriginal { h.glab.resolvedHost = host }
        try h.write("release-owned", "yes")
        let deadline = ContinuousClock.now + .seconds(5)
        while monitor.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!monitor.isLoading)
        #expect(!monitor.hasSyncedCurrentCatalog)
    }

    @Test func authoredEvidenceDatePrecedesTheListingReadIncludingSummaryFallback() async throws {
        let h = try harness()
        defer { h.cleanUp() }
        let monitor = h.authoredMonitor()
        try h.write("pause-owned", "yes")
        monitor.setVisible(true)
        try await h.waitForFile("owned-started")
        let listingWasAlreadyReadingAt = Date()
        try h.write("release-owned", "yes")
        let deadline = ContinuousClock.now + .seconds(5)
        while monitor.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!monitor.isLoading && monitor.hasSyncedCurrentCatalog)
        // The harness deliberately has no detail endpoint for !1, so the listed
        // summary itself is also a possible source of pipeline evidence.
        #expect(monitor.requests.map { $0.request.iid } == [1])
        let lowerBound = try #require(monitor.catalogReadStartedAt)
        let refreshedAt = try #require(monitor.lastRefresh)
        #expect(lowerBound <= listingWasAlreadyReadingAt)
        #expect(refreshedAt >= listingWasAlreadyReadingAt)
    }

    @Test(arguments: ["authored", "missing", "recovery"], ["draft", "merged"])
    func aDetailReadStartedAfterAnotherReadyObservationWinsTheLifecycleRace(_ path: String, _ state: String) async throws {
        let h = try harness()
        defer { h.cleanUp() }
        let iid = path == "missing" ? 3 : 1
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: iid)
        let ready = request(iid, owned: path != "missing")
        let changed = state == "draft"
            ? ready.replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#)
            : request(iid, owned: path != "missing", state: "merged")
        if path == "missing" {
            h.settings.automation.scope[target] = .active
            try h.write("explicit.json", changed)
        } else {
            try h.write("detail.json", changed)
        }
        if path == "recovery" {
            try h.write("drafts.json", #"[{"id":71,"author_id":3,"note":"Pending private reply"}]"#)
        }
        try h.write("pause-owned", "yes")
        let authored = h.authoredMonitor()
        authored.onObservedMergeRequests = { requests, observedAt in
            for request in requests where request.iid == iid {
                h.settings.mrLifecycleLedger.record(request, for: target, now: observedAt)
            }
        }
        if path == "authored" { authored.setVisible(true) }
        else { h.monitor.refresh(host: host, username: "me", todos: []) }
        try await h.waitForFile("owned-started")
        // This independent list observation is later than the first list read,
        // but earlier than the detail GET that will begin after release.
        let otherReady = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(ready.utf8))
        h.settings.mrLifecycleLedger.record(otherReady, for: target, now: Date())
        try h.write("release-owned", "yes")
        let deadline = ContinuousClock.now + .seconds(5)
        while (path == "authored" ? authored.isLoading : h.monitor.isLoading), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!(path == "authored" ? authored.isLoading : h.monitor.isLoading))
        let latest = try #require(h.settings.mrLifecycleLedger.request(for: target))
        if state == "draft" { #expect(latest.draft == true) }
        else { #expect(latest.state == "merged") }
        #expect(h.settings.mrLifecycleLedger.takeTransitions(host: host, username: "me").map(\.kind.rawValue) == [state])
    }

    @Test func anOlderDetailAlreadyInFlightCannotUndoANewerDraftObservation() async throws {
        let h = try harness()
        defer { h.cleanUp() }
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 1)
        let ready = request(1, owned: true)
        try h.write("detail.json", ready)
        try h.write("pause-detail", "yes")
        let authored = h.authoredMonitor()
        authored.onObservedMergeRequests = { requests, observedAt in
            for request in requests where request.iid == 1 {
                h.settings.mrLifecycleLedger.record(request, for: target, now: observedAt)
            }
        }
        authored.setVisible(true)
        try await h.waitForFile("detail-started")
        let newerDraft = try JSONDecoder().decode(GitLabMergeRequest.self,
            from: Data(ready.replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#).utf8))
        h.settings.mrLifecycleLedger.record(newerDraft, for: target, now: Date())
        try h.write("release-detail", "yes")
        let deadline = ContinuousClock.now + .seconds(5)
        while authored.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!authored.isLoading)
        #expect(h.settings.mrLifecycleLedger.request(for: target)?.draft == true)
        #expect(h.settings.mrLifecycleLedger.takeTransitions(host: host, username: "me").map(\.kind) == [.draft])
    }

    @MainActor
    private struct Harness {
        let folder: URL
        let defaults: UserDefaults
        let suite: String
        let settings: SettingsManager
        let glab: GlabService
        let monitor: MergeRequestAttentionMonitor

        func write(_ name: String, _ text: String) throws {
            try Data(text.utf8).write(to: folder.appending(path: name))
        }

        func poll(username: String = "me") async throws {
            monitor.refresh(host: "gitlab.example.org", username: username, todos: [])
            let deadline = ContinuousClock.now + .seconds(5)
            while monitor.isLoading, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!monitor.isLoading)
        }

        func waitForFile(_ name: String) async throws {
            let file = folder.appending(path: name)
            let deadline = ContinuousClock.now + .seconds(5)
            while !FileManager.default.fileExists(atPath: file.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(FileManager.default.fileExists(atPath: file.path))
        }

        func authoredMonitor() -> AuthoredMergeRequestMonitor {
            settings.onboardingCompleted = true
            settings.notificationsEnabled = false
            return AuthoredMergeRequestMonitor(settings: settings, glab: glab,
                notifications: NotificationService(), canAutomate: { _ in false })
        }

        func pollAuthored(_ monitor: AuthoredMergeRequestMonitor) async throws {
            monitor.setVisible(true)
            let deadline = ContinuousClock.now + .seconds(5)
            while monitor.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            try #require(!monitor.isLoading)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }

        func recordChat(username: String = "me", host: String = "gitlab.example.org") {
            let key = AssistantAutomationRunner.ChatKey(assistant: .codex,
                work: .init(host: host, projectID: 1, iid: 3), username: username,
                workspace: "", access: .gitLabRead)
            settings.assistantChats[key] = "recorded-chat"
        }

        func exactFetchCount() throws -> Int {
            let calls = try String(contentsOf: folder.appending(path: "calls"), encoding: .utf8)
            return calls.split(separator: "\n").filter { $0 == "/projects/1/merge_requests/3" }.count
        }
    }

    private func request(_ iid: Int, owned: Bool, state: String = "opened", title: String = "Fix") -> String {
        """
        {"project_id":1,"iid":\(iid),"author":{"id":\(owned ? 3 : 9),"username":"\(owned ? "me" : "alice")","name":"Author"},
         "title":"\(title)","web_url":"https://gitlab.example.org/g/p/-/merge_requests/\(iid)",
         "state":"\(state)","draft":false,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
         "source_project_id":1,"source_branch":"fix","target_project_id":1,"target_branch":"main",
         "detailed_merge_status":"mergeable","has_conflicts":false,"labels":[],"blocking_discussions_resolved":true}
        """
    }

    private func harness() throws -> Harness {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "MRCatalogStalenessTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = SettingsManager(defaults: defaults)
        let glab = GlabService()
        glab.resolvedHost = host
        glab.currentUsername = "me"
        let executable = folder.appending(path: "glab")
        try Data("""
        #!/bin/sh
        set -eu
        cd "$(dirname "$0")"
        echo "$2" >> calls
        case "$2" in
            /user) [ ! -f fail-auth ] || exit 2; cat user.json; touch user-read ;;
            /merge_requests?scope=created_by_me*)
                if [ -f pause-owned ]; then
                    touch owned-started
                    while [ ! -f release-owned ]; do sleep 0.02; done
                fi
                [ ! -f fail-owned ] || exit 2; cat owned.json ;;
            /merge_requests?scope=all*) [ ! -f fail-reviewing ] || exit 2; cat reviewing.json ;;
            /projects/1/merge_requests/3) [ ! -f fail-explicit ] || exit 2; cat explicit.json ;;
            /projects/1/merge_requests/1)
                [ -f detail.json ] || exit 100
                if [ -f pause-detail ]; then
                    touch detail-started
                    while [ ! -f release-detail ]; do sleep 0.02; done
                fi
                cat detail.json ;;
            /projects/1/merge_requests/1/discussions*) [ ! -f fail-discussions ] || exit 2; cat discussions.json ;;
            /projects/1/merge_requests/1/draft_notes*)
                if [ -f drafts.json ]; then cat drafts.json; else echo '[]'; fi ;;
            */draft_notes*) echo '[]' ;;
            */discussions*) echo '[]' ;;
            *) exit 100 ;;
        esac
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        glab.glabPath = executable
        let monitor = MergeRequestAttentionMonitor(glab: glab, settings: settings, reportDirectory: folder,
            verdictDirectory: folder.appending(path: "verdicts"),
            aiAssessmentDirectory: folder.appending(path: "ai-assessments"), followUpDirectory: folder)
        let result = Harness(folder: folder, defaults: defaults, suite: suite, settings: settings, glab: glab, monitor: monitor)
        try result.write("user.json", #"{"id":3,"username":"me"}"#)
        try result.write("owned.json", "[\(request(1, owned: true))]")
        try result.write("reviewing.json", "[\(request(2, owned: false))]")
        try result.write("explicit.json", request(3, owned: false))
        try result.write("discussions.json", "[]")
        return result
    }

    @Test(arguments: [true, false])
    func oneFailedSourceRetainsItsCatalogWhileTheOtherUpdates(ownedFails: Bool) async throws {
        let h = try harness()
        defer { h.cleanUp() }
        #expect(!h.monitor.hasCurrentOwnListing)
        try await h.poll()
        #expect(h.monitor.hasCurrentOwnListing)
        #expect(Set(h.monitor.currentOpenItems.map(\.id.iid)) == [1, 2])
        let failure = ownedFails ? "fail-owned" : "fail-reviewing"
        try h.write(failure, "")
        let freshID = ownedFails ? 2 : 1
        try h.write(ownedFails ? "reviewing.json" : "owned.json",
                    "[\(request(freshID, owned: !ownedFails, title: "Fresh title"))]")
        try await h.poll()
        #expect(h.monitor.hasError)
        #expect(h.monitor.hasCurrentOwnListing == !ownedFails)
        #expect(Set(h.monitor.currentOpenItems.map(\.id.iid)) == [1, 2])
        #expect(h.monitor.currentOpenItems.first { $0.id.iid == freshID }?.title == "Fresh title")

        try FileManager.default.removeItem(at: h.folder.appending(path: failure))
        try h.write(ownedFails ? "owned.json" : "reviewing.json", "[]")
        try await h.poll()
        // An own MR missing from a recovered open listing needs an exact state
        // read. This fixture deliberately has no endpoint for MR 1, so the
        // previous clickable snapshot stays visible with that read failure.
        #expect(h.monitor.hasError == ownedFails)
        #expect(h.monitor.hasCurrentOwnListing)
        #expect(Set(h.monitor.currentOpenItems.map(\.id.iid)) == (ownedFails ? [1, 2] : [freshID]))
        #expect(h.monitor.currentOpenItems.first { $0.id.iid == freshID }?.title == "Fresh title")
        if ownedFails {
            let retained = try #require(h.monitor.currentOpenItems.first { $0.id.iid == 1 })
            #expect(retained.mergeRequest?.state == "opened")
            #expect(retained.url.absoluteString == "https://gitlab.example.org/g/p/-/merge_requests/1")
            let calls = try String(contentsOf: h.folder.appending(path: "calls"), encoding: .utf8)
            #expect(calls.split(separator: "\n").contains("/projects/1/merge_requests/1"))
            #expect(h.settings.mrLifecycleLedger.takeTransitions(host: host, username: "me").isEmpty)
        }
    }

    @Test(arguments: ["closed", "merged"])
    func explicitFetchFailureRetainsCatalogUntilAnAuthoritativeClosedState(state: String) async throws {
        let h = try harness()
        defer { h.cleanUp() }
        try h.write("owned.json", "[]")
        try h.write("reviewing.json", "[]")
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 3)
        h.settings.automation.scope[target] = .active
        try await h.poll()
        #expect(h.monitor.currentOpenItems.map(\.id.iid) == [3])
        try h.write("fail-explicit", "")
        try await h.poll()
        #expect(h.monitor.hasError)
        #expect(h.monitor.currentOpenItems.map(\.id.iid) == [3])
        #expect(!FileManager.default.fileExists(atPath: h.folder.appending(path: "mr-status.json").path))
        try FileManager.default.removeItem(at: h.folder.appending(path: "fail-explicit"))
        try h.write("explicit.json", request(3, owned: false, state: state))
        try await h.poll()
        #expect(!h.monitor.hasError)
        #expect(h.monitor.currentOpenItems.map(\.id.iid) == [3])
        #expect(h.monitor.currentOpenItems.first?.mergeRequest?.state == state)
        #expect(h.settings.automation.scope[target] == .active)
        #expect(h.settings.automation.scope.isManaged(target))
        let restartedSettings = SettingsManager(defaults: h.defaults)
        #expect(restartedSettings.mrLifecycleLedger.retainedRequests(host: host, username: "me").first?.state == state)
    }

    @Test func aMissingManagedOwnListingRequiresAFreshStateReadAndDoesNotInferClosureOnFailure() async throws {
        let h = try harness()
        defer { h.cleanUp() }
        try await h.poll()
        #expect(h.monitor.currentOpenItems.contains { $0.id.iid == 1 })
        try h.write("owned.json", "[]")
        try await h.poll()
        // The exact endpoint is deliberately unavailable in this fixture.
        #expect(h.monitor.hasError)
        #expect(h.monitor.currentOpenItems.contains { $0.id.iid == 1 && $0.mergeRequest?.state == "opened" })
        #expect(h.settings.mrLifecycleLedger.takeTransitions(host: host, username: "me").isEmpty)
    }

    @Test func accountChangeNeverRetainsAnotherUsersCatalog() async throws {
        let h = try harness()
        defer { h.cleanUp() }
        try await h.poll()
        #expect(h.monitor.currentOpenItems.count == 2)
        h.glab.currentUsername = "other"
        #expect(h.monitor.currentOpenItems.isEmpty)
        try h.write("user.json", #"{"id":8,"username":"other"}"#)
        try h.write("fail-owned", "")
        try h.write("fail-reviewing", "")
        try await h.poll(username: "other")
        #expect(h.monitor.hasError)
        #expect(!h.monitor.hasCurrentOwnListing)
        #expect(h.monitor.currentOpenItems.isEmpty)
    }

    @Test func automationHidesReviewerThreadButPreservesIndependentAuthorThread() async throws {
        let h = try harness()
        defer { h.cleanUp() }
        h.settings.automation.workflowRules[.newDiscussion].mode = .assistant
        try h.write("reviewing.json", "[]")
        let reviewerThread = #"{"id":"review","notes":[{"id":10,"author":{"id":9,"username":"alice"},"system":false,"resolvable":true,"resolved":false},{"id":11,"author":{"id":3,"username":"me"},"system":false,"resolvable":true,"resolved":false}]}"#
        let authorThread = #"{"id":"author","notes":[{"id":20,"author":{"id":3,"username":"me"},"system":false,"resolvable":true,"resolved":false}]}"#
        try h.write("discussions.json", "[\(reviewerThread),\(authorThread)]")
        try await h.poll()
        var item = try #require(h.monitor.currentOpenItems.first { $0.id.iid == 1 })
        #expect(item.needsDiscussion && item.hasOtherUnresolvedDiscussions)
        #expect(item.feedback.compactMap(\.id) == [10])
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 1)
        var visible = item.requiringUserAttention(automation: h.settings.automation, target: target)
        #expect(visible.needsDiscussion && visible.feedback.isEmpty)
        let todo = Todo(id: 1, actionName: .reviewSubmitted, targetType: .mergeRequest,
            targetURL: item.url, body: "Review", createdAt: Date(), state: "pending",
            project: .init(id: 1, nameWithNamespace: "Group / Project", pathWithNamespace: "g/p"),
            author: .init(id: 9, username: "alice", name: "Alice", avatarURL: nil),
            target: .init(id: 1, iid: 1, title: "Fix", state: "opened", draft: false, workInProgress: false))
        let inbox = InboxSnapshot(todos: [todo], attention: [item], host: host, username: "me")
        #expect(inbox.attention.first?.hasOtherUnresolvedDiscussions == true)
        #expect(inbox.attention.first?.needsDiscussion == true)

        // The author's reply in a reviewer's thread does not create another blocker.
        try h.write("discussions.json", "[\(reviewerThread)]")
        try await h.poll()
        item = try #require(h.monitor.currentOpenItems.first { $0.id.iid == 1 })
        #expect(item.needsDiscussion && !item.hasOtherUnresolvedDiscussions)
        visible = item.requiringUserAttention(automation: h.settings.automation, target: target)
        #expect(!visible.needsDiscussion && visible.feedback.isEmpty)

        // Failed discussion verification retains the aggregate blocker conservatively.
        try h.write("owned.json", "[\(request(1, owned: true).replacingOccurrences(of: "\"blocking_discussions_resolved\":true", with: "\"blocking_discussions_resolved\":false"))]")
        try h.write("fail-discussions", "")
        try await h.poll()
        item = try #require(h.monitor.currentOpenItems.first { $0.id.iid == 1 })
        #expect(h.monitor.hasError && item.needsDiscussion && item.hasOtherUnresolvedDiscussions)
    }

    @Test func managedRecordedReviewRemainsDiscoverableWithoutReviewerAssignment() async throws {
        let h = try harness()
        defer { h.cleanUp() }
        h.recordChat()
        try await h.poll()
        #expect(Set(h.monitor.currentOpenItems.map(\.id.iid)) == [1, 2, 3])
        #expect(h.monitor.currentItems.isEmpty)
        #expect(try h.exactFetchCount() == 1)

        try h.write("fail-explicit", "")
        try await h.poll()
        #expect(h.monitor.hasError)
        #expect(Set(h.monitor.currentOpenItems.map(\.id.iid)) == [1, 2, 3])

        h.settings.automation.scope.mode = .selected
        try await h.poll()
        #expect(h.monitor.hasError)
        #expect(Set(h.monitor.currentOpenItems.map(\.id.iid)) == [1, 2, 3])
        #expect(try h.exactFetchCount() == 3)
    }

    @Test func mergedRecordedReviewIsNotFetchedEveryPollAndReopeningIsRediscovered() async throws {
        let h = try harness()
        defer { h.cleanUp() }
        h.recordChat()
        try h.write("explicit.json", request(3, owned: false, state: "merged"))
        try await h.poll()
        try await h.poll()
        #expect(Set(h.monitor.currentOpenItems.map(\.id.iid)) == [1, 2])
        #expect(try h.exactFetchCount() == 1)

        try h.write("reviewing.json", "[\(request(3, owned: false))]")
        try await h.poll()
        #expect(Set(h.monitor.currentOpenItems.map(\.id.iid)) == [1, 3])
        try h.write("reviewing.json", "[]")
        try h.write("explicit.json", request(3, owned: false))
        try await h.poll()
        #expect(Set(h.monitor.currentOpenItems.map(\.id.iid)) == [1, 3])
        #expect(try h.exactFetchCount() == 2)
    }

    @Test func recordedReviewsFromOtherAccountsOrHostsDoNotEnterCatalog() async throws {
        let h = try harness()
        defer { h.cleanUp() }
        h.recordChat(username: "other")
        h.recordChat(host: "another.example.org")
        try await h.poll()
        #expect(Set(h.monitor.currentOpenItems.map(\.id.iid)) == [1, 2])
        #expect(try h.exactFetchCount() == 0)
    }
}
