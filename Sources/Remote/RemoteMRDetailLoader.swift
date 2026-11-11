import Foundation
import MergeTetherRemote

/// Reads one displayed MR. This path never grants action authority or renews the board lease.
@MainActor enum RemoteMRDetailLoader {
    enum ReadError: Error { case changed }

    static func load(source: GitLabMergeRequest, drafts: [GitLabDraftNote], glab: GlabService) async throws -> RemoteMRDetails {
        let revision = glab.accountRevision, executable = glab.glabPath
        guard let host = glab.resolvedHost, let username = glab.currentUsername,
              source.webURL.isGitLabMergeRequest(host: host, iid: source.iid),
              let context = RemoteBoardAdapter.contextRevision(source) else { throw ReadError.changed }
        func check(_ request: GitLabMergeRequest) throws {
            try Task.checkCancellation()
            guard glab.accountRevision == revision, glab.glabPath == executable,
                  glab.resolvedHost == host, glab.currentUsername == username,
                  RemoteBoardAdapter.contextRevision(request) == context else { throw ReadError.changed }
        }
        let user = try await glab.fetchAuthenticatedUser(host: host, expectedUsername: username)
        try check(source)
        let current = try await glab.fetchMergeRequest(projectID: source.projectID, iid: source.iid, host: host)
        try check(current)
        let store = MRDiscussionStore()
        async let discussionRead: Void = store.refresh(target: .init(host: host, username: username,
            projectID: source.projectID, iid: source.iid, url: source.webURL), glab: glab)
        async let counts = try? glab.fetchMergeRequestApprovalProgress(projectID: source.projectID, iid: source.iid, host: host)
        async let rules: RemoteApprovalRuleState? = try? glab.mergeRequestAPI(
            "/projects/\(source.projectID)/merge_requests/\(source.iid)/approval_state", host: host)
        async let reviewers = try? glab.fetchMergeRequestReviewers(projectID: source.projectID, iid: source.iid, host: host)
        let (progress, ruleState, reviewerHistory, _) = await (counts, rules, reviewers, discussionRead)
        let latest = try await glab.fetchMergeRequest(projectID: source.projectID, iid: source.iid, host: host)
        try check(latest)
        guard try await glab.fetchAuthenticatedUser(host: host, expectedUsername: username) == user else { throw ReadError.changed }
        try check(latest)
        let discussions = store.hasLoaded && !store.hasError ? store.discussions : nil
        let origins = store.origins
        let details = await Task.detached(priority: .utility) {
            project(request: latest, progress: progress, rules: ruleState, reviewers: reviewerHistory,
                discussions: discussions, origins: origins, drafts: drafts, username: username)
        }.value
        try check(latest)
        return details
    }

    nonisolated static func project(request: GitLabMergeRequest, progress: MergeRequestApprovalProgress?, rules: RemoteApprovalRuleState?,
                        reviewers: [GitLabMergeRequestReviewer]?, discussions: [GitLabMergeRequestDiscussion]?,
                        origins: [Int: MRDiscussionSnapshot.Origin] = [:], drafts: [GitLabDraftNote], username: String) -> RemoteMRDetails {
        var progress = progress
        let history = MergeRequestReviewHistory(reviewers: reviewers ?? [], discussions: discussions ?? [], authorID: request.author.id)
        progress?.reviewHistory = history
        let people = progress?.participants(reviewers: request.reviewers ?? [])
            ?? MergeRequestApprovalProgress.participants(reviewers: request.reviewers ?? [], history: history)
        let approvals = RemoteApprovalDetails(progress: progress.flatMap {
            .init(completed: min($0.completed, $0.required), required: $0.required,
                received: $0.completed, requirementsSatisfied: $0.requirementsSatisfied)
        }, people: people.map {
            .init(id: $0.id, name: $0.author.name, username: $0.author.username,
                status: .init(rawValue: String(describing: $0.status)) ?? .assigned, changedAt: $0.changedAt)
        }, rules: rules?.projected, requirementsSatisfied: rules?.requirementsSatisfied,
            historyAvailable: reviewers != nil && discussions != nil)
        let metadata: [RemoteDetailField] = [
            .init(label: String(localized: .CommandCenter.commandCenterAuthor), value: request.author.name + " (@" + request.author.username + ")"),
            .init(label: String(localized: .CommandCenter.commandCenterSource), value: request.sourceBranch),
            .init(label: String(localized: .CommandCenter.commandCenterTarget), value: request.targetBranch),
            .init(label: String(localized: .CommandCenter.commandCenterCommit), value: request.sha ?? String(localized: .CommandCenter.commandCenterStatusUnavailable)),
            .init(label: String(localized: .CommandCenter.commandCenterMergeState), value: request.detailedMergeStatus?.replacingOccurrences(of: "_", with: " ") ?? String(localized: .CommandCenter.commandCenterStatusUnavailable)),
            .init(label: String(localized: .CommandCenter.commandCenterPipeline), value: request.headPipeline?.status.replacingOccurrences(of: "_", with: " ") ?? String(localized: .CommandCenter.commandCenterNoPipeline)),
        ]
        let threads = discussions.map {
            MRDiscussionSnapshot(discussions: $0, drafts: drafts, origins: origins).threads.map { thread in
                let summary = thread.replySummary(currentUsername: username)
                return RemoteDetailThread(id: thread.id, state: .init(rawValue: String(describing: thread.state)) ?? .general,
                    location: thread.location, notes: thread.notes.enumerated().map { index, note in
                        let origin: RemoteDetailNote.Origin? = note.id.flatMap { thread.origins[$0] }.map {
                            switch $0 {
                            case .appGenerated, .verifiedAssistant, .assessed: .ai
                            case .uncertain: .uncertain
                            case .humanLikely: .human
                            }
                        }
                        var components = URLComponents(url: request.webURL, resolvingAgainstBaseURL: false)
                        components?.fragment = note.id.map { "note_\($0)" }
                        return RemoteDetailNote(id: note.id.map(String.init) ?? "unidentified/\(index)",
                            author: note.author?.name, username: note.author?.username, body: note.body ?? "",
                            location: MRDiscussionLocation(position: note.position)?.full,
                            createdAt: MergeRequestReviewHistory.date(note.createdAt), url: components?.url, origin: origin,
                            authorID: note.author?.id)
                    }, reply: .init(rawValue: String(describing: summary.publishedReply)) ?? .unavailable, draftCount: summary.draftCount)
            }
        }
        var details = RemoteMRDetails(checkedAt: .now, metadata: metadata, description: request.description, approvals: approvals, threads: threads,
            branches: .init(source: request.sourceBranch, target: request.targetBranch))
        details.discussionFingerprint = discussions.flatMap { ReviewVerdict.fingerprint($0) }
        return details
    }
}

struct RemoteApprovalRuleState: Decodable, Sendable {
    struct Rule: Decodable, Sendable {
        let id: Int?
        let name: String?
        let approvalsRequired: Int
        let approved: Bool?
        let approvedBy: [Person]?
        struct Person: Decodable, Sendable { let username: String? }
        enum CodingKeys: String, CodingKey {
            case id, name, approved
            case approvalsRequired = "approvals_required", approvedBy = "approved_by"
        }
    }
    let rules: [Rule]
    var requirementsSatisfied: Bool? {
        guard rules.allSatisfy({ $0.approvalsRequired >= 0 }) else { return nil }
        let required = rules.filter { $0.approvalsRequired > 0 }
        if required.contains(where: { $0.approved == false }) { return false }
        if required.contains(where: { $0.approved == nil }) { return nil }
        return true
    }
    var projected: [RemoteApprovalRule] {
        rules.enumerated().map { index, rule in
            .init(id: rule.id.map(String.init) ?? "rule/\(index)", name: rule.name ?? "#\(index + 1)",
                required: rule.approvalsRequired, approved: rule.approved,
                approvedBy: (rule.approvedBy ?? []).compactMap(\.username).map { "@" + $0 })
        }
    }
}
