import Foundation

@MainActor
enum AssistantWorkerAudit {
    struct Snapshot: Codable, Equatable, Sendable {
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

        var isComplete: Bool { head != nil && approved != nil && discussions != nil }

        private struct Discussions: Codable, Equatable, Sendable {
            struct Resolution: Codable, Equatable, Sendable {
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

    struct Pending: Codable, Equatable, Sendable {
        let baseline: Snapshot
        let userID: Int
        let sourceProjectID: Int?
        let sourceBranch: String
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
        guard sameAccount(), verifiedUser == user, let live, live.projectID == project, live.iid == iid,
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

    enum Verdict: Equatable {
        case clean
        case unexpected([AssistantJobExecution.RemoteEffect])
        /// Comparable live evidence could not be read, so unattended writes cannot be shown to stay in bounds.
        case unavailable
    }

    /// Compares the live MR with the pre-launch baseline and records any effects outside the run's allowances.
    /// A missing baseline or an unreadable post-run state yields `.unavailable`.
    @discardableResult
    static func recordChanges(since baseline: Snapshot?, handoff: AssistantAutomationRunner.Handoff,
                              request: GitLabMergeRequest, user: GitLabAuthenticatedUser, accountRevision: UInt64,
                              glab: GlabService, settings: SettingsManager,
                              retryDelay: Duration = .seconds(2)) async -> Verdict {
        guard let baseline else { return .unavailable }
        var live = await capture(for: request, host: handoff.key.work.host, user: user,
                                 accountRevision: accountRevision, glab: glab)
        let first = compare(live, baseline: baseline, handoff: handoff)
        if first == .unavailable, !Task.isCancelled, glab.accountRevision == accountRevision {
            try? await Task.sleep(for: retryDelay)
            live = await capture(for: request, host: handoff.key.work.host, user: user,
                                 accountRevision: accountRevision, glab: glab)
        }
        guard !Task.isCancelled else { return .unavailable }
        let verdict = compare(live, baseline: baseline, handoff: handoff)
        if let index = activeRunIndex(handoff, in: settings) {
            switch verdict {
            case .clean: break
            case .unavailable where handoff.manual != true:
                settings.assistantHandoffs[index].execution?.pendingWorkerAudit = Pending(
                    baseline: baseline, userID: user.id, sourceProjectID: request.sourceProjectID, sourceBranch: request.sourceBranch)
                settings.save()
            case .unavailable: break
            case .unexpected(let effects):
                settings.assistantHandoffs[index].execution?.remoteEffects = effects
            }
        }
        return verdict
    }

    private static func compare(_ live: Snapshot?, baseline: Snapshot, handoff: AssistantAutomationRunner.Handoff) -> Verdict {
        guard let live else { return .unavailable }
        let effects = live.effects(since: baseline, allowsPush: AgentProcessEnvironment.pushPermitted(handoff),
                                   allowsOwnResolution: handoff.resolvesOwnThreads == true)
        if !effects.isEmpty { return .unexpected(effects) }
        return live.isComplete && baseline.isComplete ? .clean : .unavailable
    }

    static func enforce(_ verdict: Verdict, handoff: AssistantAutomationRunner.Handoff,
                        settings: SettingsManager) -> AssistantJobExecutor.ExecutionError? {
        switch verdict {
        case .clean: return nil
        case .unavailable: return handoff.manual == true ? nil : .auditUnavailable
        case .unexpected:
            settings.automation.scope[handoff.key.automationTarget] = .paused
            settings.save()
            Log.monitor.warning("Paused automation on a merge request with out-of-bounds worker effects")
            return .unexpectedRemoteEffects
        }
    }

    /// Resume comparing saved evidence on later polls, without launching a worker again.
    static func retryPending(host: String, user: GitLabAuthenticatedUser, glab: GlabService, settings: SettingsManager) async {
        let revision = glab.accountRevision
        let pending = settings.assistantHandoffs.filter {
            $0.key.work.host == host && $0.key.username == user.username
                && $0.execution?.state.isActive == false && $0.execution?.pendingWorkerAudit?.userID == user.id
        }
        guard !pending.isEmpty else { return }
        _ = await AssistantJobJournal.loadKey()
        for handoff in pending {
            let work = handoff.key.work
            guard !Task.isCancelled, glab.accountRevision == revision else { return }
            guard let audit = handoff.execution?.pendingWorkerAudit,
                  let request = try? await glab.fetchMergeRequest(projectID: work.projectID, iid: work.iid, host: host),
                  request.projectID == work.projectID, request.iid == work.iid, request.webURL == handoff.mergeRequestURL,
                  request.sourceProjectID == audit.sourceProjectID, request.sourceBranch == audit.sourceBranch else { continue }
            let live = await capture(for: request, host: host, user: user, accountRevision: revision, glab: glab)
            let verdict = compare(live, baseline: audit.baseline, handoff: handoff)
            guard verdict != .unavailable, !Task.isCancelled, glab.accountRevision == revision,
                  let index = settings.assistantHandoffs.firstIndex(where: {
                      $0.id == handoff.id && $0.key == handoff.key && $0.execution?.pendingWorkerAudit == audit
                  }) else { continue }
            if case .unexpected(let effects) = verdict {
                settings.assistantHandoffs[index].execution?.pendingWorkerAudit = nil
                settings.assistantHandoffs[index].execution?.remoteEffects = effects
                settings.assistantHandoffs[index].execution?.error = AssistantJobExecutor.ExecutionError.unexpectedRemoteEffects.rawValue
                _ = enforce(verdict, handoff: handoff, settings: settings)
            } else {
                guard AssistantJobJournal.isKeyReady || !AssistantJobJournal.hasCheckpoint(handoff.id) else { continue }
                do {
                    if let execution = try AssistantJobJournal.completeAuditedRun(handoff) {
                        settings.assistantHandoffs[index].execution = execution
                    }
                    settings.assistantHandoffs[index].execution?.pendingWorkerAudit = nil
                    settings.save()
                } catch {
                    Log.monitor.error("Could not restore the audited worker outcome: \(String(describing: error), privacy: .private)")
                }
            }
        }
    }
}
