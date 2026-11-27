import Foundation
import MergeTetherRemote

/// Reads one displayed MR. This path never grants action authority or renews the board lease.
@MainActor enum RemoteMRDetailLoader {
    enum ReadError: Error { case changed }

    struct Result {
        var details: RemoteMRDetails
        var history: RemoteMRGitLabHistory = .init()
        var userID: Int? = nil
    }

    static func load(source: GitLabMergeRequest, drafts: [GitLabDraftNote], glab: GlabService,
                     criteriaOverride: String? = nil) async throws -> Result {
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
        let target = MRDiscussionTarget(host: host, username: username, projectID: source.projectID,
            iid: source.iid, url: source.webURL)
        async let discussionRead: Void = store.refresh(target: target, glab: glab, criteriaOverride: criteriaOverride)
        async let resourceRead = MRGitLabActivityStore.readResources(for: target, glab: glab, timeout: 15)
        async let counts = try? glab.fetchMergeRequestApprovalProgress(projectID: source.projectID, iid: source.iid, host: host)
        async let rules: RemoteApprovalRuleState? = try? glab.mergeRequestAPI(
            "/projects/\(source.projectID)/merge_requests/\(source.iid)/approval_state", host: host)
        async let reviewers = try? glab.fetchMergeRequestReviewers(projectID: source.projectID, iid: source.iid, host: host)
        let (progress, ruleState, reviewerHistory, resources, _) = await (counts, rules, reviewers, resourceRead, discussionRead)
        let latest = try await glab.fetchMergeRequest(projectID: source.projectID, iid: source.iid, host: host)
        try check(latest)
        guard try await glab.fetchAuthenticatedUser(host: host, expectedUsername: username) == user else { throw ReadError.changed }
        try check(latest)
        if let discussionUserID = store.authenticatedUserID, discussionUserID != user.id { throw ReadError.changed }
        let discussions = store.hasLoaded && !store.hasError ? store.discussions : nil
        let history = RemoteMRGitLabHistory(resources: resources, notes: discussions.map { _ in store.activity })
        let origins = store.origins
        let authorKinds = store.authorKinds
        let extraContexts = store.extraContexts
        let details = await Task.detached(priority: .utility) {
            project(request: latest, progress: progress, rules: ruleState, reviewers: reviewerHistory,
                discussions: discussions, origins: origins, drafts: drafts, username: username, authorKinds: authorKinds,
                extraContexts: extraContexts)
        }.value
        try check(latest)
        return .init(details: details, history: history, userID: user.id)
    }

    nonisolated static func project(request: GitLabMergeRequest, progress: MergeRequestApprovalProgress?, rules: RemoteApprovalRuleState?,
                        reviewers: [GitLabMergeRequestReviewer]?, discussions: [GitLabMergeRequestDiscussion]?,
                        origins: [Int: MRDiscussionSnapshot.Origin] = [:], drafts: [GitLabDraftNote], username: String,
                        authorKinds: [Int: AuthorFeedbackPolicy.AccountKind] = [:],
                        extraContexts: AICommentProvenanceStore.ExtraContexts = .empty, checkedAt: Date = .now) -> RemoteMRDetails {
        var progress = progress
        let history = if reviewers == nil, discussions == nil, let saved = progress?.reviewHistory { saved }
            else { MergeRequestReviewHistory(reviewers: reviewers ?? [], discussions: discussions ?? [], authorID: request.author.id) }
        progress?.reviewHistory = history
        let approvals = RemoteApprovalDetails(progress: progress, reviewers: request.reviewers ?? [], viewerUsername: username,
            isOwnMergeRequest: GitLabAccountIdentity.normalize(request.author.username) == GitLabAccountIdentity.normalize(username),
            rules: rules?.projected, requirementsSatisfied: rules?.requirementsSatisfied,
            historyAvailable: reviewers != nil && discussions != nil, reviewHistory: history)
        let metadata: [RemoteDetailField] = [
            .init(label: String(localized: .CommandCenter.commandCenterAuthor), value: request.author.person.displayName ?? request.author.username,
                  person: request.author.remotePerson),
            .init(label: String(localized: .CommandCenter.commandCenterSource), value: request.sourceBranch),
            .init(label: String(localized: .CommandCenter.commandCenterTarget), value: request.targetBranch),
            .init(label: String(localized: .CommandCenter.commandCenterCommit), value: request.sha ?? String(localized: .CommandCenter.commandCenterStatusUnavailable)),
            .init(label: String(localized: .CommandCenter.commandCenterMergeState), value: request.detailedMergeStatus?.rawValue.replacingOccurrences(of: "_", with: " ") ?? String(localized: .CommandCenter.commandCenterStatusUnavailable)),
            .init(label: String(localized: .CommandCenter.commandCenterPipeline), value: request.headPipeline?.status.rawValue.replacingOccurrences(of: "_", with: " ") ?? String(localized: .CommandCenter.commandCenterNoPipeline)),
        ]
        let threads = discussions.map {
            MRDiscussionSnapshot(discussions: $0, drafts: drafts, origins: origins).threads.map { thread in
                let summary = thread.replySummary(currentUsername: username)
                return RemoteDetailThread(id: thread.id, state: .init(rawValue: String(describing: thread.state)) ?? .general,
                    location: thread.location, notes: thread.notes.enumerated().map { index, note in
                        let origin: RemoteDetailNote.Origin? = note.id.flatMap { thread.origins[$0] }.map {
                            switch $0 {
                            case .appGenerated, .verifiedAssistant, .botAccount, .assessed: .ai
                            case .uncertain: .uncertain
                            case .humanLikely: .human
                            case .manual(.ai): .ai
                            case .manual(.uncertain): .uncertain
                            case .manual(.human): .human
                            }
                        }
                        var components = URLComponents(url: request.webURL, resolvingAgainstBaseURL: false)
                        components?.fragment = note.id.map { "note_\($0)" }
                        let extraContext = extraContexts.forNote(note.id)
                        return RemoteDetailNote(id: note.id.map(String.init) ?? "unidentified/\(index)",
                            author: note.author?.person.displayName, username: note.author?.username, body: note.body ?? "",
                            location: MRDiscussionLocation(position: note.position)?.full,
                            createdAt: MergeRequestReviewHistory.date(note.createdAt), url: components?.url, origin: origin,
                            authorID: note.author?.id, authorKind: (note.author?.id).flatMap { id in
                                switch authorKinds[id] {
                                case .regular: .regular
                                case .automation: .automation
                                case .unknown, nil: nil
                                }
                            }, avatarURL: note.author?.avatarURL,
                            originManual: note.id.flatMap { thread.origins[$0] }?.isManual == true ? true : nil,
                            extraContext: extraContext?.markdown,
                            proposedSolution: extraContext?.proposedSolution == true ? true : nil)
                    }, reply: .init(rawValue: String(describing: summary.publishedReply)) ?? .unavailable,
                    draftCount: summary.draftCount, draftIDs: thread.drafts.compactMap(\.id))
            }
        }
        var details = RemoteMRDetails(checkedAt: checkedAt, metadata: metadata, description: request.description, approvals: approvals, threads: threads,
            branches: .init(source: request.sourceBranch, target: request.targetBranch))
        if let discussions {
            let content = MRDiscussionContent(discussions)
            details.discussionFingerprint = content.fingerprint
            details.activeDiscussionFingerprint = content.activeFingerprint
        }
        let draftContexts = Dictionary(drafts.compactMap { draft -> (Int, AICommentProvenanceStore.ExtraContexts.Entry)? in
            guard let id = draft.id, id > 0, let context = extraContexts.forDraft(draft) else { return nil }
            return (id, context)
        }, uniquingKeysWith: { first, _ in first })
        if !draftContexts.isEmpty {
            details.draftContexts = Dictionary(uniqueKeysWithValues: draftContexts.map { (String($0.key), $0.value.markdown) })
            let proposals = draftContexts.compactMap { $0.value.proposedSolution ? $0.key : nil }.sorted()
            details.proposedSolutionDraftIDs = proposals.isEmpty ? nil : proposals
        }
        return details
    }
}

struct RemoteMRGitLabHistory: Sendable {
    var resources: [MRGitLabActivity.Resource: [MRGitLabActivity]] = [:]
    var notes: [MRGitLabActivity]?
    var isPartial: Bool? = nil

    var entries: [MRGitLabActivity] { (notes ?? []) + resources.values.flatMap { $0 } }
    var hasMissingSources: Bool { resources.count != MRGitLabActivity.Resource.allCases.count || notes == nil }

    func fillingMissingSources(from previous: Self?) -> Self {
        var history = self
        history.isPartial = hasMissingSources ? true : nil
        if let previous {
            history.resources.merge(previous.resources, uniquingKeysWith: { current, _ in current })
            history.notes = history.notes ?? previous.notes
        }
        return history
    }

    func retained(publicationNoteIDs: Set<Int>) -> Self {
        // Keep bounded event candidates and the older events that determine attribution.
        let retainedCount = RemoteDetailActivity.maximumEntries + 1
        func sorted(_ events: [MRGitLabActivity]) -> [MRGitLabActivity] {
            var seen = Set<String>()
            return events.filter { seen.insert($0.id).inserted }.sorted {
                $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
            }
        }
        var history = self
        history.resources = resources.mapValues { events in
            let events = sorted(events)
            let olderMerges = events.dropFirst(retainedCount).lazy.filter {
                if case .state(.merged) = $0.kind { return true }
                return false
            }.prefix(2)
            return Array(events.prefix(retainedCount)) + Array(olderMerges)
        }
        history.notes = notes.map { events in
            let events = sorted(events)
            let relatedNotes = events.dropFirst(retainedCount).filter {
                if case .comment(let id, _) = $0.kind { return publicationNoteIDs.contains(id) }
                return false
            }
            return (Array(events.prefix(retainedCount)) + relatedNotes).map { event in
                let body = event.body.map { String($0.prefix(4_000)) }
                return MRGitLabActivity(id: event.id, createdAt: event.createdAt, person: event.person,
                    kind: event.kind, body: body, updatedAt: event.updatedAt, location: event.location, resolved: event.resolved)
            }
        }
        return history
    }
}

struct RemoteApprovalRuleState: Decodable, Sendable {
    struct Rule: Decodable, Sendable {
        let id: Int?
        let name: String?
        let approvalsRequired: Int
        let approved: Bool?
        let approvedBy: [Person]?
        struct Person: Decodable, Sendable {
            let username: String?
            var name: String? = nil
            var person: PersonIdentity { .init(name: name, username: username) }
        }
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
                approvedBy: (rule.approvedBy ?? []).compactMap { $0.person.displayName })
        }
    }
}

/// Maps the phone's displayed note identities back to the current GitLab comments.
enum RemoteCommentOriginMatcher {
    /// `nil` when any requested note is missing, duplicated or no longer has the body and author the phone saw.
    static func notes(_ requested: [RemoteCommentOriginRequest.Note],
                      in discussions: [GitLabMergeRequestDiscussion]) -> [GitLabMergeRequestDiscussion.Note]? {
        var result: [GitLabMergeRequestDiscussion.Note] = []
        for entry in requested {
            guard let noteID = Int(entry.noteID), noteID > 0, !result.contains(where: { $0.id == noteID }),
                  entry.threadID.hasPrefix("discussion/") else { return nil }
            let discussionID = String(entry.threadID.dropFirst("discussion/".count))
            let threads = discussions.filter { $0.id == discussionID }
            guard threads.count == 1 else { return nil }
            let matches = threads[0].notes.filter { $0.id == noteID && $0.system != true }
            guard matches.count == 1, let note = matches.first, let authorID = note.author?.id, authorID > 0,
                  let body = note.body,
                  (try? RemoteDigest.token([entry.threadID, entry.noteID, String(authorID), body])) == entry.identity
            else { return nil }
            result.append(note)
        }
        return result.isEmpty ? nil : result
    }
}
