import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct MRDisplayMetadataTests {
    private let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)
    private var account: MRDisplayMetadataCache.Account { .init(host: target.host, username: target.username, revision: 7) }
    private var url: URL { URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")! }

    private func request(draft: Bool = false, state: String = "opened", projectID: Int = 1, iid: Int = 2) throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: Data("""
        {"project_id":\(projectID),"iid":\(iid),"author":{"id":9,"username":"author","name":"Author"},
         "title":"Example","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/\(iid)",
         "state":"\(state)","draft":\(draft),"source_branch":"feature","target_branch":"main","labels":[]}
        """.utf8))
    }

    @Test func lateMetadataAndAnAccountRoundTripCannotReplaceCurrentDisplayState() throws {
        var cache = MRDisplayMetadataCache()
        let fresh = try request(draft: true)
        let accepted = cache.record(fresh, for: target, url: url, readStartedAt: Date(timeIntervalSince1970: 20),
                                    account: account, currentAccount: account)
        try #require(accepted)
        let stale = cache.record(try request(), for: target, url: url, readStartedAt: Date(timeIntervalSince1970: 10),
                                 account: account, currentAccount: account)
        #expect(!stale)
        #expect(cache.request(for: target, url: url, account: account)?.draft == true)
        let nextSession = MRDisplayMetadataCache.Account(host: target.host, username: target.username, revision: 9)
        #expect(cache.request(for: target, url: url, account: nextSession) == nil)
        let oldSession = cache.record(try request(), for: target, url: url, readStartedAt: Date(timeIntervalSince1970: 30),
                                      account: account, currentAccount: nextSession)
        #expect(!oldSession)
        let newSession = cache.record(try request(), for: target, url: url, readStartedAt: Date(timeIntervalSince1970: 5),
                                      account: nextSession, currentAccount: nextSession)
        #expect(newSession)
        #expect(cache.requests(account: nextSession).first?.draft == false)
    }

    @Test(arguments: ["host", "username", "project", "iid", "url"])
    func metadataMustMatchItsExactReadTarget(_ mismatch: String) throws {
        var cache = MRDisplayMetadataCache()
        let readAccount = MRDisplayMetadataCache.Account(host: mismatch == "host" ? "other.example.test" : target.host,
            username: mismatch == "username" ? "other" : target.username, revision: account.revision)
        let readURL = mismatch == "url" ? URL(string: "https://gitlab.example.test/another/repo/-/merge_requests/2")! : url
        let accepted = cache.record(try request(projectID: mismatch == "project" ? 3 : 1, iid: mismatch == "iid" ? 3 : 2),
            for: target, url: readURL, readStartedAt: Date(), account: readAccount, currentAccount: readAccount)
        #expect(!accepted)
        #expect(cache.requests(account: readAccount).isEmpty)
    }

    @Test func proposalMetadataDoesNotRegisterManagementAndCannotOverrideManagedLifecycle() throws {
        let suite = "MRDisplayMetadataTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.resolvedHost = target.host
        let glab = GlabService()
        glab.resolvedHost = target.host
        glab.currentUsername = target.username
        let monitor = TodoMonitorService(settings: settings, glab: glab)
        monitor.recordBoardDisplayRequest(try request(), for: target, url: url,
            accountRevision: glab.accountRevision, readStartedAt: Date(timeIntervalSince1970: 30))
        #expect(monitor.boardDisplayRequest(for: target, url: url)?.draft == false)
        #expect(!settings.automation.scope.isManaged(target))
        #expect(settings.mrLifecycleLedger.targets(host: target.host, username: target.username).isEmpty)
        #expect(settings.assistantHandoffs.isEmpty && settings.mrActionIntents.isEmpty)
        settings.mrLifecycleLedger.record(try request(draft: true), for: target, now: Date(timeIntervalSince1970: 40))
        monitor.recordBoardDisplayRequest(try request(), for: target, url: url,
            accountRevision: glab.accountRevision, readStartedAt: Date(timeIntervalSince1970: 50))
        #expect(monitor.boardDisplayRequest(for: target, url: url)?.draft == true)
        #expect(monitor.boardDisplayRequests.first?.draft == true)
        glab.currentUsername = "another"
        glab.currentUsername = target.username
        #expect(monitor.boardDisplayRequest(for: target, url: url)?.draft == true)
    }

    @Test func knownAuthorMetadataLoadsPublishToTheSharedDisplayCache() async throws {
        let current = try request(draft: true)
        let item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: current.title,
            url: url, mergeRequest: current)
        let proposal = MergeRequestBoardSnapshot.Proposal(target: target, title: current.title, url: url,
            item: item, todos: [], intents: [])
        var cache = MRDisplayMetadataCache()
        var published = 0
        let loader = ProposalAuthorLoader(fetch: { _ in current }, currentAccount: {
            .init(host: target.host, username: target.username)
        }, accountRevision: { account.revision }, onLoaded: { request, target, url, revision, startedAt in
            published += 1
            let readAccount = MRDisplayMetadataCache.Account(host: target.host, username: target.username, revision: revision)
            _ = cache.record(request, for: target, url: url, readStartedAt: startedAt,
                             account: readAccount, currentAccount: account)
        })
        await loader.load(proposal, displayMetadata: true)
        #expect(published == 1)
        #expect(cache.request(for: target, url: url, account: account)?.draft == true)
    }

    @Test func loaderAccountRoundTripCannotPublishOrExposeAnOldSessionResponse() async throws {
        var revision: UInt64 = 1
        var published = false
        let current = try request()
        let proposal = MergeRequestBoardSnapshot.Proposal(target: target, title: current.title, url: url,
            item: nil, todos: [], intents: [])
        let loader = ProposalAuthorLoader(fetch: { _ in revision += 2; return current }, currentAccount: {
            .init(host: target.host, username: target.username)
        }, accountRevision: { revision }, onLoaded: { _, _, _, _, _ in published = true })
        await loader.load(proposal, displayMetadata: true)
        #expect(!published)
        #expect(loader.request(for: proposal) == nil)
    }
    @Test(arguments: ["ready", "closed", "merged"])
    func aFreshAttentionObservationReplacesOlderUnmanagedLoaderMetadata(_ state: String) async throws {
        try await withPollingMonitor { monitor, settings, directory in
            let current = try request(state: state == "ready" ? "opened" : state)
            try JSONEncoder().encode(current).write(to: directory.appending(path: "request.json"))
            monitor.recordBoardDisplayRequest(try request(draft: true), for: target, url: url,
                accountRevision: monitor.glab.accountRevision, readStartedAt: .distantPast)
            try #require(monitor.boardDisplayRequest(for: target, url: url)?.draft == true)
            monitor.attention.refresh(host: target.host, username: target.username, todos: [])
            try await settle(monitor.attention)
            let displayed = try #require(monitor.boardDisplayRequest(for: target, url: url))
            #expect(displayed.state == current.state && displayed.draft == false)
            #expect(!settings.automation.scope.isManaged(target))
            #expect(settings.mrLifecycleLedger.targets(host: target.host, username: target.username).isEmpty)
            #expect(settings.assistantHandoffs.isEmpty && settings.mrActionIntents.isEmpty)
        }
    }

    @Test func anOlderAttentionReadCannotOverwriteANewerLoaderRead() async throws {
        try await withPollingMonitor { monitor, _, directory in
            try JSONEncoder().encode(request()).write(to: directory.appending(path: "request.json"))
            try Data().write(to: directory.appending(path: "pause-list"))
            defer { try? Data().write(to: directory.appending(path: "release-list")) }
            monitor.attention.refresh(host: target.host, username: target.username, todos: [])
            let entered = directory.appending(path: "list-entered")
            let deadline = ContinuousClock.now + .seconds(5)
            while !FileManager.default.fileExists(atPath: entered.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(FileManager.default.fileExists(atPath: entered.path))
            monitor.recordBoardDisplayRequest(try request(draft: true), for: target, url: url,
                accountRevision: monitor.glab.accountRevision, readStartedAt: Date())
            try Data().write(to: directory.appending(path: "release-list"))
            try await settle(monitor.attention)
            #expect(monitor.boardDisplayRequest(for: target, url: url)?.draft == true)
        }
    }

    private func settle(_ attention: MergeRequestAttentionMonitor) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while attention.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!attention.isLoading && !attention.hasError)
    }

    private func withPollingMonitor(_ body: (TodoMonitorService, SettingsManager, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let suite = "MRDisplayPollingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "glab")
        try Data("""
        #!/bin/sh
        set -eu
        cd "$(dirname "$0")"
        case "$*" in
          'config get host') printf '%s' '\(target.host)'; exit 0 ;;
          'auth status') printf '%s' 'Logged in to \(target.host) as \(target.username)'; exit 0 ;;
        esac
        case "$*" in *--method*|*--raw-field*|*--field*) exit 200 ;; esac
        case "$2" in
          /user) printf '%s' '{"id":3,"username":"me"}' ;;
          /merge_requests\\?scope=created_by_me*) printf '%s' '[]' ;;
          /merge_requests\\?scope=all*)
            cp request.json listed-request.json
            if [ -f pause-list ]; then
              touch list-entered
              while [ ! -f release-list ]; do sleep 0.01; done
            fi
            printf '['; cat listed-request.json; printf ']' ;;
          /projects/1/merge_requests/2) cat request.json ;;
          */approval_state) printf '%s' '{"rules":[]}' ;;
          /projects/1) printf '%s' '{"default_branch":"main"}' ;;
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
