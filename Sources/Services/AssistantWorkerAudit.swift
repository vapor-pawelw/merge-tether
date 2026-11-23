import Foundation

@MainActor
enum AssistantWorkerAudit {
    struct Snapshot {
        private let head: String?
        private let approved: Bool?
        private let discussions: Discussions?

        init(head: String?, approved: Bool?, discussions: [GitLabMergeRequestDiscussion]?, userID: Int) {
            self.head = head.flatMap { GlabService.isFullGitSHA($0) ? $0 : nil }
            self.approved = approved
            self.discussions = discussions.map { Discussions($0, userID: userID) }
        }

        func effects(since previous: Self, allowsPush: Bool, allowsOwnResolution: Bool) -> [AssistantJobExecution.RemoteEffect] {
            var effects: [AssistantJobExecution.RemoteEffect] = []
            if let discussions, let prior = previous.discussions {
                if !discussions.userNotes.isSubset(of: prior.publishedNotes) { effects.append(.publishedComment) }
                if discussions.resolvedByUser.contains(where: {
                    prior.unresolvedThreads.contains($0.threadID) && (!allowsOwnResolution || !$0.startedByUser)
                }) { effects.append(.resolvedDiscussion) }
            }
            if previous.approved == false, approved == true { effects.append(.approval) }
            if !allowsPush, let priorHead = previous.head, let head, priorHead != head { effects.append(.sourceHead) }
            return effects
        }

        private struct Discussions {
            struct Resolution {
                let threadID: String
                let startedByUser: Bool
            }

            var publishedNotes: Set<Int> = []
            var userNotes: Set<Int> = []
            var unresolvedThreads: Set<String> = []
            var resolvedByUser: [Resolution] = []

            init(_ discussions: [GitLabMergeRequestDiscussion], userID: Int) {
                for discussion in discussions {
                    for note in discussion.notes where note.system == false {
                        guard let id = note.id, id > 0 else { continue }
                        publishedNotes.insert(id)
                        if note.author?.id == userID { userNotes.insert(id) }
                    }
                    guard let id = discussion.id, !id.isEmpty,
                          let root = discussion.reviewRoot, root.resolvable == true else { continue }
                    if root.resolved == false { unresolvedThreads.insert(id) }
                    if root.resolved == true, root.resolvedBy?.id == userID {
                        resolvedByUser.append(.init(threadID: id, startedByUser: root.author?.id == userID))
                    }
                }
            }
        }
    }

    static func capture(for request: GitLabMergeRequest, host: String, user: GitLabAuthenticatedUser,
                        accountRevision: UInt64, glab: GlabService) async -> Snapshot? {
        func sameAccount() -> Bool {
            !Task.isCancelled && glab.accountRevision == accountRevision
                && glab.resolvedHost == host && glab.currentUsername == user.username
        }
        guard sameAccount() else { return nil }
        let project = request.projectID, iid = request.iid
        async let authenticated = try? glab.fetchAuthenticatedUser(host: host, expectedUsername: user.username)
        async let currentRequest = try? glab.fetchMergeRequest(projectID: project, iid: iid, host: host)
        async let discussions = try? glab.fetchMergeRequestDiscussions(projectID: project, iid: iid, host: host, timeout: 8)
        async let approvals = try? glab.fetchMergeRequestApprovalCounts(projectID: project, iid: iid, host: host, timeout: 8)
        let (verifiedUser, live, threads, approvalCounts) = await (authenticated, currentRequest, discussions, approvals)
        guard sameAccount(), verifiedUser == user, let live,
              live.webURL == request.webURL, live.webURL.isGitLabMergeRequest(host: host, iid: iid),
              live.sourceProjectID == request.sourceProjectID, live.sourceBranch == request.sourceBranch else { return nil }
        return .init(head: live.sha, approved: approvalCounts?.approverIDs?.contains(user.id),
                     discussions: threads, userID: user.id)
    }

    static func activeRunIndex(_ handoff: AssistantAutomationRunner.Handoff, in settings: SettingsManager) -> Int? {
        settings.assistantHandoffs.firstIndex {
            $0.id == handoff.id && $0.key == handoff.key && $0.expectedHeadSHA == handoff.expectedHeadSHA
                && $0.execution?.state == .running
        }
    }

    static func recordChanges(since baseline: Snapshot, handoff: AssistantAutomationRunner.Handoff,
                              request: GitLabMergeRequest, user: GitLabAuthenticatedUser, accountRevision: UInt64,
                              glab: GlabService, settings: SettingsManager) async {
        guard let live = await capture(for: request, host: handoff.key.work.host, user: user,
                                      accountRevision: accountRevision, glab: glab),
              let index = activeRunIndex(handoff, in: settings) else { return }
        let effects = live.effects(since: baseline, allowsPush: handoff.allowsPush || handoff.followUpPushAllowed == true,
                                   allowsOwnResolution: handoff.resolvesOwnThreads == true)
        guard !effects.isEmpty else { return }
        settings.assistantHandoffs[index].execution?.remoteEffects = effects
        settings.save()
        Log.monitor.warning("Observed GitLab changes outside the allowances of worker run \(handoff.id.uuidString, privacy: .private)")
    }
}
