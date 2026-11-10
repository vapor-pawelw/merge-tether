import Foundation
import Testing
import MergeTetherRemote
@testable import GitLabTodos

@MainActor
struct MRDependencyLoaderTests {
    @Test func retainedCatalogRetargetingHidesOldLinksBeforeTheNextDependencyRead() async throws {
        let h = try MonitorHarness()
        defer { h.close() }
        try await h.refresh()
        try await h.gitlab.waitFor("metadata")
        #expect(h.child?.dependencies?.predecessors.map(\.iid) == [1])

        let changed = try MRDependencyPresentationTests().request(2, source: "child", target: "release")
        h.settings.mrLifecycleLedger.record(changed, for: h.target)
        h.failCatalog = true
        h.gitlab.write("holdDependencies")
        try await h.refresh()
        try await h.gitlab.waitFor("dependenciesStarted")

        #expect(h.child?.mergeRequest?.targetBranch == "release")
        #expect(h.child?.dependencies == nil)
        #expect(h.monitor.currentItems.isEmpty)
        h.gitlab.remove("metadata")
        h.gitlab.write("releaseDependencies")
        try await h.gitlab.waitFor("metadata")
    }

    @Test func aSupersededDependencyReadCannotPublishItsOldBlockers() async throws {
        let h = try MonitorHarness()
        defer { h.close() }
        h.dependencyBlockers = [try MRDependencyPresentationTests().request(4, project: 77)]
        h.gitlab.write("holdDependencies")
        try await h.refresh()
        try await h.gitlab.waitFor("dependenciesStarted")
        #expect(h.child?.dependencies == nil)
        h.dependencyBlockers = []
        try await h.refresh()
        #expect(h.child?.dependencies == nil)
        h.gitlab.remove("holdDependencies")
        h.gitlab.write("releaseDependencies")
        try await h.gitlab.waitFor("metadata")
        #expect(h.dependencySnapshots.count == 1)
        #expect(h.dependencySnapshots.first?.predecessors.map(\.projectID) == [34])
        #expect(h.gitlab.requests.allSatisfy { $0.method == "GET" })
    }

    @Test func anAccountRoundTripDuringDependencyReadsCannotCommitEarlierLinks() async throws {
        let h = try MonitorHarness()
        defer { h.close() }
        h.dependencyBlockers = [try MRDependencyPresentationTests().request(4, project: 77)]
        h.gitlab.write("holdDependencies")
        try await h.refresh()
        try await h.gitlab.waitFor("dependenciesStarted")
        h.glab.currentUsername = "other"
        h.glab.currentUsername = "author7"
        h.dependencyBlockers = []
        try await h.refresh()
        #expect(h.child?.dependencies == nil)
        h.gitlab.remove("holdDependencies")
        h.gitlab.write("releaseDependencies")
        try await h.gitlab.waitFor("metadata")
        #expect(h.dependencySnapshots.count == 1)
        #expect(h.child?.dependencies?.predecessors.map(\.projectID) == [34])
    }

    @Test func completingCommentReviewRemovesAttentionWithoutDroppingCatalogDependencies() async throws {
        let h = try MonitorHarness()
        defer { h.close() }
        h.settings.beginCommentReview(for: h.target)
        try await h.refresh()
        try await h.gitlab.waitFor("metadata")
        let summary = try #require(h.child?.dependencies)
        #expect(summary.predecessors.map(\.iid) == [1])
        #expect(h.monitor.currentItems.first { $0.id.iid == 2 }?.dependencies == summary)

        h.settings.completeCommentReview(for: h.target)
        try await h.refresh()
        #expect(!h.monitor.currentItems.contains { $0.id.iid == 2 })
        #expect(h.child?.dependencies == summary)
        let board = MergeRequestBoardSnapshot(own: h.monitor.currentOpenItems, reviewed: [], todos: [],
            attention: h.monitor.currentItems, handoffs: [], host: h.host, username: "author7")
        #expect(board.own.first { $0.id.iid == 2 }?.item.dependencies == summary)
    }

    @Test func readsHiddenBlockersAndReusesEachProjectSnapshotWithinTheTTL() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let first = await h.loader.refresh(requests: h.requests, glab: h.glab, host: h.host, now: h.start)
        #expect(first[h.childID]?.stackPosition == "2/2")
        #expect(first[h.childID]?.predecessors.count == 1)
        #expect(first[h.childID]?.issues.contains(.hiddenDependency) == true)
        _ = await h.loader.refresh(requests: h.requests, glab: h.glab, host: h.host, now: h.start.addingTimeInterval(10))
        #expect(try h.calls("stack") == 1)
        #expect(try h.calls("project") == 1)
        #expect(try h.calls("blocks-2") == 1)
        // GitLab dependencies can change without a new source commit.
        try h.write("blocks-2.json", "[]")
        let refreshed = await h.loader.refresh(requests: h.requests, glab: h.glab, host: h.host, now: h.start.addingTimeInterval(61))
        #expect(refreshed[h.childID]?.issues.contains(.hiddenDependency) == false)
        #expect(try h.calls("blocks-2") == 2)
        #expect(refreshed[h.childID]?.predecessors.first?.sources == [.stack])
    }

    @Test(arguments: [403, 404])
    func failedReadsKeepLastKnownLinksExplicitlyUnverified(_ status: Int) async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        _ = await h.loader.refresh(requests: h.requests, glab: h.glab, host: h.host, now: h.start)
        try h.write("fail", String(status))
        let failed = await h.loader.refresh(requests: h.requests, glab: h.glab, host: h.host, now: h.start.addingTimeInterval(61))
        let summary = try #require(failed[h.childID])
        #expect(summary.stackPosition == nil)
        #expect(summary.predecessors.map(\.iid) == [1])
        #expect(summary.predecessors.first?.isCurrent == false)
        #expect(summary.issues.contains(.dependenciesUnavailable))
        #expect(summary.issues.contains(.stackUnavailable))
    }

    @Test func accountRoundTripCannotReuseEarlierDependencyEvidence() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        _ = await h.loader.refresh(requests: h.requests, glab: h.glab, host: h.host, now: h.start)
        h.glab.currentUsername = "other"
        h.glab.currentUsername = "author7"
        try h.write("fail", "403")
        let changed = await h.loader.refresh(requests: h.requests, glab: h.glab, host: h.host, now: h.start.addingTimeInterval(1))
        #expect(changed[h.childID]?.predecessors.isEmpty == true)
        #expect(changed[h.childID]?.issues.contains(.dependenciesUnavailable) == true)
        #expect(try h.calls("blocks-2") == 2)
    }

    @Test func retargetedRequestDoesNotReuseOldStackOrBlockerEvidence() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        _ = await h.loader.refresh(requests: h.requests, glab: h.glab, host: h.host, now: h.start)
        let retargeted = try MRDependencyPresentationTests().request(2, source: "child", target: "main")
        try h.write("blocks-2.json", "[]")
        let changed = await h.loader.refresh(requests: [retargeted], glab: h.glab, host: h.host, now: h.start.addingTimeInterval(1))
        #expect(changed[h.childID]?.stackPosition == nil)
        #expect(changed[h.childID]?.predecessors.isEmpty == true)
        #expect(changed[h.childID]?.issues.contains(.stackUnavailable) == true)
        #expect(try h.calls("blocks-2") == 2)
    }

    @Test func accountChangeDuringAReadDiscardsLateEvidence() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try h.write("delay", "yes")
        let task = Task { await h.loader.refresh(requests: h.requests, glab: h.glab, host: h.host, now: h.start) }
        try await h.waitUntil { FileManager.default.fileExists(atPath: h.directory.appending(path: "started").path) }
        h.glab.currentUsername = "other"
        h.glab.currentUsername = "author7"
        try h.write("release", "yes")
        #expect(await task.value.isEmpty)
        try h.write("fail", "403")
        let freshAccount = await h.loader.refresh(requests: h.requests, glab: h.glab, host: h.host, now: h.start)
        #expect(freshAccount[h.childID]?.predecessors.isEmpty == true)
    }

    @Test func catalogArrivesBeforeDependencyReadsAndRetargetingRejectsLateMetadata() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try h.write("delay", "yes")
        let monitor = MergeRequestAttentionMonitor(glab: h.glab, verdictDirectory: h.directory,
            aiAssessmentDirectory: h.directory, followUpDirectory: h.directory)
        monitor.refresh(host: h.host, username: "author7", todos: [])
        try await h.waitUntil { !monitor.isLoading }
        #expect(!monitor.hasError)
        #expect(monitor.currentOpenItems.count == 2)
        try await h.waitUntil { FileManager.default.fileExists(atPath: h.directory.appending(path: "started").path) }
        #expect(monitor.currentOpenItems.first { $0.id == h.childID }?.dependencies == nil)
        let retargeted = try MRDependencyPresentationTests().request(2, source: "child", target: "main")
        let changed = [h.requests[0], retargeted]
        try JSONEncoder().encode(changed).write(to: h.directory.appending(path: "stack.json"))
        try h.write("blocks-2.json", "[]")
        monitor.refresh(host: h.host, username: "author7", todos: [])
        try await h.waitUntil { !monitor.isLoading }
        try h.write("release", "yes")
        try await h.waitUntil { monitor.currentOpenItems.first { $0.id == h.childID }?.dependencies != nil }
        let summary = try #require(monitor.currentOpenItems.first { $0.id == h.childID }?.dependencies)
        #expect(summary.stackPosition == nil)
        #expect(summary.predecessors.isEmpty)
    }

    @Test func phoneSnapshotCarriesTheSameCanonicalDependencyLinks() throws {
        let fixture = MRDependencyPresentationTests()
        let parent = try fixture.request(1, source: "base")
        let child = try fixture.request(2, source: "child", target: "base")
        let summary = MergeRequestDependencySummary(request: child,
            stack: .init(requests: [parent, child], defaultBranch: "main"),
            dependencies: .init(requests: [parent], hasHiddenDependency: false))
        let item = MergeRequestAttentionMonitor.Item(id: .init(projectID: child.projectID, iid: child.iid),
            title: child.title, url: child.webURL, mergeRequest: child, dependencies: summary)
        let card = RemoteBoardAdapter.card(item, account: "author@gitlab.example.test")
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as? [String: Any])
        let dependency = try #require(wire["dependencies"] as? [String: Any])
        #expect(dependency["stackPosition"] as? String == "2/2")
        let links = try #require(dependency["predecessors"] as? [[String: Any]])
        #expect(links.count == 1)
        #expect(links.first?["reference"] as? String == "!1")
        #expect(links.first?["url"] as? String == parent.webURL.absoluteString)
        let oldData = Data(#"{"id":"mr:34:2","title":"Old","project":"group/repo","detail":"","drafts":[],"actions":[]}"#.utf8)
        let old = try JSONDecoder().decode(RemoteCard.self, from: oldData)
        let oldWire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        #expect(oldWire["dependencies"] == nil)
    }

    @Test func catalogDependencyMetadataSurvivesAnAttentionOverlay() throws {
        let fixture = MRDependencyPresentationTests()
        let parent = try fixture.request(1, source: "base")
        let child = try fixture.request(2, source: "child", target: "base")
        let summary = MergeRequestDependencySummary(request: child,
            stack: .init(requests: [parent, child], defaultBranch: "main"),
            dependencies: .init(requests: [parent], hasHiddenDependency: false))
        let catalog = MergeRequestAttentionMonitor.Item(id: .init(projectID: child.projectID, iid: child.iid),
            title: child.title, url: child.webURL, mergeRequest: child, dependencies: summary)
        var attention = catalog
        attention.dependencies = nil
        attention.needsMerge = true
        let board = MergeRequestBoardSnapshot(own: [catalog], reviewed: [], todos: [], attention: [attention],
            handoffs: [], host: "gitlab.example.test", username: "author7")
        #expect(board.own.first?.item.dependencies == summary)
    }

    @Test func oneCatalogPollDrainsDependencyReadsBeyondThePerWaveLimit() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let fixture = MRDependencyPresentationTests()
        let requests = try (1...15).map { try fixture.request($0, source: "feature-\($0)") }
        try JSONEncoder().encode(requests).write(to: h.directory.appending(path: "stack.json"))
        for iid in 1...15 { try h.write("blocks-\(iid).json", "[]") }
        let monitor = MergeRequestAttentionMonitor(glab: h.glab, verdictDirectory: h.directory,
            aiAssessmentDirectory: h.directory, followUpDirectory: h.directory)
        var metadataSnapshots: [[MergeRequestDependencySummary]] = []
        monitor.onRefreshed = {
            let values = monitor.currentOpenItems.compactMap(\.dependencies)
            if !values.isEmpty { metadataSnapshots.append(values) }
        }
        monitor.refresh(host: h.host, username: "author7", todos: [])
        try await h.waitUntil { !monitor.isLoading }
        #expect(monitor.currentOpenItems.count == 15)
        try await h.waitUntil {
            monitor.currentOpenItems.allSatisfy { $0.dependencies != nil
                && $0.dependencies?.issues.contains(.dependenciesUnavailable) == false }
        }
        #expect(metadataSnapshots.count == 1)
        #expect(metadataSnapshots.allSatisfy { $0.allSatisfy { !$0.issues.contains(.dependenciesUnavailable) } })
        #expect(try h.calls("stack") == 1)
        for iid in 1...15 { #expect(try h.calls("blocks-\(iid)") == 1) }
    }

    @Test(arguments: [false, true])
    func hiddenDependencyResponsesKeepMissingLinksAsLastKnown(_ includesVisible: Bool) async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let fixture = MRDependencyPresentationTests()
        let old = try fixture.request(4, project: 77)
        let visible = try fixture.request(5, project: 88)
        let oldJSON = String(data: try JSONEncoder().encode(old), encoding: .utf8)!
        let visibleJSON = String(data: try JSONEncoder().encode(visible), encoding: .utf8)!
        try h.write("blocks-2.json", "[{\"id\":1,\"blocking_merge_request\":\(oldJSON)}]")
        let initial = await h.loader.refresh(requests: h.requests, glab: h.glab, host: h.host, now: h.start)
        #expect(initial[h.childID]?.predecessors.first { $0.projectID == 77 }?.isCurrent == true)
        let readable = includesVisible ? ",{\"id\":2,\"blocking_merge_request\":\(visibleJSON)}" : ""
        try h.write("blocks-2.json", "[{\"id\":1}\(readable)]")
        let partial = await h.loader.refresh(requests: h.requests, glab: h.glab, host: h.host,
            now: h.start.addingTimeInterval(61))
        let oldLink = try #require(partial[h.childID]?.predecessors.first { $0.projectID == 77 })
        #expect(oldLink.url == old.webURL)
        #expect(!oldLink.isCurrent)
        #expect(partial[h.childID]?.issues.contains(.hiddenDependency) == true)
        if includesVisible {
            #expect(partial[h.childID]?.predecessors.first { $0.projectID == 88 }?.isCurrent == true)
        }
        // Only a complete empty response proves those earlier GitLab links are gone.
        try h.write("blocks-2.json", "[]")
        let cleared = await h.loader.refresh(requests: h.requests, glab: h.glab, host: h.host,
            now: h.start.addingTimeInterval(122))
        #expect(cleared[h.childID]?.predecessors.map(\.projectID) == [34])
        #expect(try h.calls("blocks-2") == 3)
    }

    @Test func successfulCachedEvidenceStaysKnownWhileAnotherBoundedBatchRefreshes() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let fixture = MRDependencyPresentationTests()
        let requests = try (1...13).map { try fixture.request($0, source: "feature-\($0)") }
        try JSONEncoder().encode(requests).write(to: h.directory.appending(path: "stack.json"))
        for iid in 1...13 { try h.write("blocks-\(iid).json", "[]") }
        _ = await h.loader.refresh(requests: requests, glab: h.glab, host: h.host, now: h.start)
        _ = await h.loader.refresh(requests: requests, glab: h.glab, host: h.host, now: h.start)
        let refreshed = await h.loader.refresh(requests: requests, glab: h.glab, host: h.host,
            now: h.start.addingTimeInterval(300))
        let waitingID = MergeRequestAttentionMonitor.Item.ID(projectID: 34, iid: 13)
        #expect(refreshed[waitingID]?.issues.contains(.dependenciesUnavailable) == false)
        #expect(try h.calls("blocks-13") == 1)
        _ = await h.loader.refresh(requests: requests, glab: h.glab, host: h.host,
            now: h.start.addingTimeInterval(300))
        #expect(try h.calls("blocks-13") == 2)
    }

    @MainActor final class MonitorHarness {
        let gitlab = InMemoryGitLab()
        let host = "gitlab.example.test"
        let suite = "MRDependencyMonitorTests-\(UUID())"
        let defaults: UserDefaults
        let settings: SettingsManager
        let glab: GlabService
        let directory: URL
        var monitor: MergeRequestAttentionMonitor!
        var requests: [GitLabMergeRequest]
        var dependencyBlockers: [GitLabMergeRequest]?
        var dependencySnapshots: [MergeRequestDependencySummary] = []
        var failCatalog = false
        var child: MergeRequestAttentionMonitor.Item? { monitor.currentOpenItems.first { $0.id.iid == 2 } }
        var target: MRAutomationScope.Target { .init(host: host, username: "author7", projectID: 34, iid: 2) }

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            settings = SettingsManager(defaults: defaults)
            settings.automation.disableAssistantPackage()
            directory = FileManager.default.temporaryDirectory.appending(path: suite)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fixture = MRDependencyPresentationTests()
            requests = [try fixture.request(1, source: "base"), try fixture.request(2, source: "child", target: "base")]
            glab = gitlab.service(host: host, username: "author7")
            gitlab.handler = { [weak self] call in
                guard let self else { throw CancellationError() }
                let path = call.endpoint
                guard call.method == "GET" else { return try gitlab.unexpected(call) }
                if path == "/user" { return InMemoryGitLab.output(#"{"id":7,"username":"author7"}"#) }
                if path.hasPrefix("/merge_requests?scope=created_by_me") {
                    if failCatalog { return InMemoryGitLab.output(code: 1) }
                    return try encoded(requests)
                }
                if path.hasPrefix("/merge_requests?scope=all") { return InMemoryGitLab.output("[]") }
                if path == "/projects/34" { return InMemoryGitLab.output(#"{"default_branch":"main"}"#) }
                if path.hasPrefix("/projects/34/merge_requests?state=opened") { return try encoded(requests) }
                if path.contains("/blocks?") {
                    let blockers = path.contains("/2/blocks?") ? dependencyBlockers ?? [requests[0]] : []
                    let json = try blockers.map { ["blocking_merge_request": try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))] }
                    let response = try InMemoryGitLab.json(json)
                    try await gitlab.pause(ifPresent: "holdDependencies", entered: "dependenciesStarted", until: "releaseDependencies")
                    return response
                }
                if path.contains("/draft_notes?") || path.contains("/discussions?") || path.contains("/reviewers?") {
                    return InMemoryGitLab.output("[]")
                }
                if path.hasSuffix("/approvals") {
                    return InMemoryGitLab.output(#"{"approvals_required":0,"approvals_left":0,"approved_by":[]}"#)
                }
                if path == "/projects/34/merge_requests/1" || path == "/projects/34/merge_requests/2" {
                    if failCatalog { return InMemoryGitLab.output(code: 1) }
                    return try encoded(requests[path.hasSuffix("/1") ? 0 : 1])
                }
                return try gitlab.unexpected(call)
            }
            monitor = MergeRequestAttentionMonitor(glab: glab, settings: settings, verdictDirectory: directory,
                aiAssessmentDirectory: directory, followUpDirectory: directory, canAutomate: { _ in false })
            monitor.onRefreshed = { [weak self] in
                guard let self else { return }
                if !monitor.isLoading { gitlab.write("catalog") }
                if let summary = child?.dependencies {
                    dependencySnapshots.append(summary)
                    gitlab.write("metadata")
                }
            }
        }

        func refresh() async throws {
            gitlab.remove("catalog")
            gitlab.remove("metadata")
            monitor.refresh(host: host, username: "author7", todos: [])
            try await gitlab.waitFor("catalog")
        }
        func encoded(_ value: some Encodable) throws -> ProcessRunner.Output {
            InMemoryGitLab.output(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
        }
        func close() {
            gitlab.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor final class Harness {
        let host = "gitlab.example.test"
        let start = Date(timeIntervalSince1970: 1000)
        let directory: URL
        let glab = GlabService()
        let loader = MRDependencyLoader()
        let requests: [GitLabMergeRequest]
        let childID = MergeRequestAttentionMonitor.Item.ID(projectID: 34, iid: 2)
        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "MRDependencyLoaderTests-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let fixtures = MRDependencyPresentationTests()
            let base = try fixtures.request(1, source: "base")
            let child = try fixtures.request(2, source: "child", target: "base")
            requests = [base, child]
            let encoded = try JSONEncoder().encode(requests)
            try encoded.write(to: directory.appending(path: "stack.json"))
            try Data("{\"default_branch\":\"main\"}".utf8).write(to: directory.appending(path: "project.json"))
            let parentJSON = String(data: try JSONEncoder().encode(base), encoding: .utf8)!
            try Data("[{\"id\":1,\"blocking_merge_request\":\(parentJSON)},{\"id\":2}]".utf8).write(to: directory.appending(path: "blocks-2.json"))
            try Data("[]".utf8).write(to: directory.appending(path: "blocks-1.json"))
            let executable = directory.appending(path: "glab")
            try Data("""
            #!/bin/sh
            root="${0%/*}"
            case "$*" in
              'api /user --hostname '* ) printf '%s' '{"id":7,"username":"author7"}'; exit 0 ;;
              'api /merge_requests?scope=created_by_me&'* ) cat "$root/stack.json"; exit 0 ;;
              'api /merge_requests?scope=all&state=opened&reviewer_id='* ) printf '[]'; exit 0 ;;
              'api /projects/34/merge_requests/'*'/draft_notes?'* | 'api /projects/34/merge_requests/'*'/discussions?'* ) printf '[]'; exit 0 ;;
              'api /projects/34/merge_requests?state=opened&scope=all&per_page=100 --hostname \(host) --paginate') name=stack ;;
              'api /projects/34 --hostname \(host)') name=project ;;
              'api /projects/34/merge_requests/1/blocks?per_page=100 --hostname \(host) --paginate') name=blocks-1 ;;
              'api /projects/34/merge_requests/2/blocks?per_page=100 --hostname \(host) --paginate') name=blocks-2 ;;
              'api /projects/34/merge_requests/'*'/blocks?per_page=100 --hostname \(host) --paginate')
                iid="${2#/projects/34/merge_requests/}"
                iid="${iid%%/*}"
                name="blocks-$iid" ;;
              *) printf 'Unexpected command' >&2; exit 20 ;;
            esac
            printf x >> "$root/$name.calls"
            if test -f "$root/delay"; then
              touch "$root/started"
              while test -d "$root" && test ! -f "$root/release"; do sleep 0.02; done
            fi
            if test -f "$root/fail"; then
              printf 'HTTP %s forbidden or unavailable' "$(cat "$root/fail")" >&2
              exit 1
            fi
            cat "$root/$name.json"
            """.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            glab.glabPath = executable
            glab.resolvedHost = host
            glab.currentUsername = "author7"
        }
        func write(_ path: String, _ content: String) throws {
            try Data(content.utf8).write(to: directory.appending(path: path))
        }
        func calls(_ name: String) throws -> Int {
            try Data(contentsOf: directory.appending(path: name + ".calls")).count
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(condition())
            try #require(condition())
        }
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }
}
