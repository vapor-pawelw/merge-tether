import Foundation
import Testing
@testable import MergeTether

struct ManualMergeRequestReviewTests {
    private let target = ManualReviewTarget(host: "gitlab.example.org", username: "reviewer", projectID: 7, iid: 12,
        url: URL(string: "https://gitlab.example.org/group/app/-/merge_requests/12")!)

    private func request(state: String = "opened", author: String = "author", projectID: Int = 7,
                         iid: Int = 12, url: String = "https://gitlab.example.org/group/app/-/merge_requests/12",
                         sha: String? = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", draft: Bool? = nil) throws -> GitLabMergeRequest {
        var object: [String: Any] = ["project_id": projectID, "iid": iid, "title": "Improve logging",
            "author": ["id": 2, "username": author, "name": "Author"], "state": state, "web_url": url,
            "source_branch": "fix", "target_branch": "main", "labels": []]
        if let sha { object["sha"] = sha }
        if let draft { object["draft"] = draft }
        return try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @MainActor @Test func reviewDisclosureFollowsTheEffectivePublicationScopeAndFilters() throws {
        let suite = "ReviewPublication.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.full, for: .codex)
        settings.setAutomationGloballyEnabled(true)
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: target.host, username: target.username)
        settings.resolvedHost = target.host
        settings.glabPath = glab.glabPath
        let monitor = TodoMonitorService(settings: settings, glab: glab)
        defer { monitor.stopTimer() }
        let request = try request(draft: false)
        let item = MergeRequestAttentionMonitor.Item(id: .init(projectID: target.projectID, iid: target.iid),
            title: request.title, url: request.webURL, mergeRequest: request)
        let scope = try #require(monitor.scopeTarget(projectID: target.projectID, iid: target.iid, url: target.url))
        #expect(monitor.manualReviewConsent(for: item).publicationMode == .all)

        settings.automation.scope[scope.repository] = .paused
        #expect(monitor.manualReviewConsent(for: item).publicationMode == .manual)
        settings.automation.scope[scope] = .active
        #expect(monitor.manualReviewConsent(for: item).publicationMode == .all)

        settings.automation.publicationMode = .filtered
        settings.automation.publicationRestrictions.repositories = [.init(host: target.host, entityID: 999, label: "Other")]
        #expect(monitor.manualReviewConsent(for: item).publicationMode == .manual)
        settings.automation.publicationRestrictions.repositories = [.init(host: target.host, entityID: target.projectID, label: "App")]
        #expect(monitor.manualReviewConsent(for: item).publicationMode == .filtered)
    }

    @Test func acceptsFreshOpenedReviewTargetWithoutAutomationScope() throws {
        #expect(target.accepts(try request()))
        #expect(target.matchesAccount(host: "gitlab.example.org", username: "reviewer"))
    }

    @Test func rejectsClosedMergedOwnAndMissingHeadRequests() throws {
        #expect(!target.accepts(try request(state: "closed")))
        #expect(!target.accepts(try request(state: "merged")))
        #expect(!target.accepts(try request(author: "reviewer")))
        #expect(!target.accepts(try request(sha: nil)))
        #expect(!target.accepts(try request(sha: "")))
    }

    @Test func rejectsDifferentProjectNumberHostAndURL() throws {
        #expect(!target.accepts(try request(projectID: 8)))
        #expect(!target.accepts(try request(iid: 13)))
        #expect(!target.accepts(try request(url: "https://other.example.org/group/app/-/merge_requests/12")))
        #expect(!target.accepts(try request(url: "https://gitlab.example.org/other/app/-/merge_requests/12")))
        #expect(!target.accepts(try request(url: "https://gitlab.example.org:8443/group/app/-/merge_requests/12")))
    }

    @Test func accountSwitchInvalidatesCapturedTarget() {
        #expect(!target.matchesAccount(host: "other.example.org", username: "reviewer"))
        #expect(!target.matchesAccount(host: "gitlab.example.org", username: "other"))
        #expect(!target.matchesAccount(host: nil, username: nil))
    }
}
