import Foundation

@MainActor
enum AssistantWorkerAudit {
    struct Snapshot: Codable, Equatable, Sendable {
        let head: String?
        let observedAt: Date?
        private let approved: Bool?
        private let discussions: Discussions?

        init(head: String?, approved: Bool?, discussions: [GitLabMergeRequestDiscussion]?, userID: Int,
             observedAt: Date = .now) {
            self.head = head.flatMap { GlabService.isFullGitSHA($0) ? $0 : nil }
            self.observedAt = observedAt
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
        var blocksManualWorker: Bool? = nil
    }

    static func blocksNewWorker(_ handoff: AssistantAutomationRunner.Handoff, in settings: SettingsManager) -> Bool {
        settings.assistantHandoffs.contains {
            $0.key.automationTarget == handoff.key.automationTarget
                && $0.execution?.pendingWorkerAudit?.blocksManualWorker == true
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
        case headChanged
        case unexpected([AssistantJobExecution.RemoteEffect])
        /// Comparable live evidence could not be read, so unattended writes cannot be shown to stay in bounds.
        case unavailable
    }

    private struct Comparison {
        let verdict: Verdict
        var sourceHeadChange: AssistantJobExecution.SourceHeadChange? = nil
    }

    /// Compares the live MR with the pre-launch baseline and records any effects outside the run's allowances.
    /// A missing baseline or an unreadable post-run state yields `.unavailable`.
    @discardableResult
    static func recordChanges(since baseline: Snapshot?, handoff: AssistantAutomationRunner.Handoff,
                              request: GitLabMergeRequest, user: GitLabAuthenticatedUser, accountRevision: UInt64,
                              glab: GlabService, settings: SettingsManager,
                              retryDelay: Duration = .seconds(2), requireReconciliation: Bool = false) async -> Verdict {
        guard let baseline = baseline ?? (requireReconciliation
            ? Snapshot(head: nil, approved: nil, discussions: nil, userID: user.id) : nil) else { return .unavailable }
        func affectedRunIndex() -> Int? {
            activeRunIndex(handoff, in: settings) ?? (requireReconciliation ? settings.assistantHandoffs.firstIndex {
                $0.id == handoff.id && $0.key == handoff.key && $0.expectedHeadSHA == handoff.expectedHeadSHA
                    && $0.execution?.state == .interrupted
            } : nil)
        }
        let pending = Pending(baseline: baseline, userID: user.id, sourceProjectID: request.sourceProjectID,
            sourceBranch: request.sourceBranch, blocksManualWorker: requireReconciliation ? true : nil)
        // Persist the hold before starting live reads, which may be cancelled or fail.
        if requireReconciliation, let index = affectedRunIndex() {
            settings.assistantHandoffs[index].execution?.pendingWorkerAudit = pending
            settings.save()
        }
        var live = await capture(for: request, host: handoff.key.work.host, user: user,
                                 accountRevision: accountRevision, glab: glab)
        var comparison = await compare(live, baseline: baseline, handoff: handoff, request: request, user: user, glab: glab)
        if comparison.verdict == .unavailable, !Task.isCancelled, glab.accountRevision == accountRevision {
            try? await Task.sleep(for: retryDelay)
            live = await capture(for: request, host: handoff.key.work.host, user: user,
                                 accountRevision: accountRevision, glab: glab)
            comparison = await compare(live, baseline: baseline, handoff: handoff, request: request, user: user, glab: glab)
        }
        guard !Task.isCancelled else { return .unavailable }
        let currentAccount = glab.accountRevision == accountRevision
        let verdict = currentAccount ? comparison.verdict : .unavailable
        if let index = affectedRunIndex() {
            if currentAccount, let change = comparison.sourceHeadChange {
                settings.assistantHandoffs[index].execution?.sourceHeadChange = change
            }
            switch verdict {
            case .clean, .headChanged: break
            case .unavailable where handoff.manual != true:
                settings.assistantHandoffs[index].execution?.pendingWorkerAudit = pending
                settings.save()
            case .unavailable: break
            case .unexpected(let effects):
                settings.assistantHandoffs[index].execution?.remoteEffects = effects
            }
            let clearedHold = requireReconciliation && verdict != .unavailable
            if clearedHold {
                // Apply any policy pause before lifting the temporary hold.
                _ = enforce(verdict, handoff: handoff, settings: settings)
                settings.assistantHandoffs[index].execution?.pendingWorkerAudit = nil
            }
            if clearedHold || (currentAccount && comparison.sourceHeadChange != nil) { settings.save() }
        }
        return verdict
    }

    private static func compare(_ live: Snapshot?, baseline: Snapshot, handoff: AssistantAutomationRunner.Handoff,
                                request: GitLabMergeRequest, user: GitLabAuthenticatedUser, glab: GlabService) async -> Comparison {
        guard let live else { return .init(verdict: .unavailable) }
        var effects = live.effects(since: baseline, allowsPush: AgentProcessEnvironment.pushPermitted(handoff),
                                   allowsOwnResolution: handoff.resolvesOwnThreads == true)
        var change: AssistantJobExecution.SourceHeadChange?
        if effects.contains(.sourceHead), let previous = baseline.head, let current = live.head, let observedAt = live.observedAt {
            var evidence = AssistantJobExecution.SourceHeadChange(previousSHA: previous, currentSHA: current,
                previousObservation: baseline.observedAt, currentObservation: observedAt, accountID: user.id)
            if let projectID = request.sourceProjectID, let startedAt = baseline.observedAt {
                evidence.pushActorID = await sourcePushActor(projectID: projectID, branch: request.sourceBranch,
                    previous: previous, current: current, startedAt: startedAt, observedAt: observedAt,
                    host: handoff.key.work.host, glab: glab)
            }
            if evidence.attributedToAnotherAccount { effects.removeAll { $0 == .sourceHead } }
            change = evidence
        }
        let verdict: Verdict
        if !effects.isEmpty { verdict = .unexpected(effects) }
        else if !live.isComplete || !baseline.isComplete { verdict = .unavailable }
        else { verdict = change?.attributedToAnotherAccount == true ? .headChanged : .clean }
        return .init(verdict: verdict, sourceHeadChange: change)
    }

    private struct PushEvent: Decodable {
        struct Push: Decodable {
            let action: String?
            let refType: String?
            let ref: String?
            let commitFrom: String?
            let commitTo: String?

            enum CodingKeys: String, CodingKey {
                case action, ref
                case refType = "ref_type", commitFrom = "commit_from", commitTo = "commit_to"
            }
        }

        let projectID: Int?
        let authorID: Int?
        let createdAt: String?
        let pushData: Push?

        enum CodingKeys: String, CodingKey {
            case projectID = "project_id", authorID = "author_id", createdAt = "created_at", pushData = "push_data"
        }
    }

    private static func sourcePushActor(projectID: Int, branch: String, previous: String, current: String,
                                        startedAt: Date, observedAt: Date, host: String, glab: GlabService) async -> Int? {
        guard projectID > 0, !branch.isEmpty, startedAt <= observedAt else { return nil }
        let pageSize = 100
        let previousDay = startedAt.addingTimeInterval(-86_400)
            .formatted(.iso8601.year().month().day().dateSeparator(.dash))
        guard let events: [PushEvent] = try? await glab.mergeRequestAPI(
            "/projects/\(projectID)/events?action=pushed&sort=desc&per_page=\(pageSize)&after=\(previousDay)",
            host: host, timeout: 8) else { return nil }
        let oldest = events.last?.createdAt.flatMap(MRDiscussionTimestamp.parse)
        guard events.count < pageSize || oldest.map({ $0 < startedAt }) == true else { return nil }
        let candidates = events.filter { event in
            guard event.projectID == projectID else { return false }
            guard let date = event.createdAt, let time = MRDiscussionTimestamp.parse(date) else { return true }
            guard time >= startedAt, time <= observedAt else { return false }
            // GitLab may omit the ref for a bulk push. It could include this branch.
            return event.pushData?.ref == nil || event.pushData?.ref == branch
        }
        guard candidates.count == 1, let event = candidates.first, let rawDate = event.createdAt,
              MRDiscussionTimestamp.parse(rawDate) != nil, let actor = event.authorID, actor > 0,
              let push = event.pushData, push.action == "pushed", push.refType == "branch", push.ref == branch,
              push.commitFrom == previous, push.commitTo == current else { return nil }
        return actor
    }

    static func enforce(_ verdict: Verdict, handoff: AssistantAutomationRunner.Handoff,
                        settings: SettingsManager) -> AssistantJobExecutor.ExecutionError? {
        switch verdict {
        case .clean: return nil
        case .headChanged: return .headChanged
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
            let comparison = await compare(live, baseline: audit.baseline, handoff: handoff, request: request, user: user, glab: glab)
            let verdict = comparison.verdict
            guard verdict != .unavailable, !Task.isCancelled, glab.accountRevision == revision,
                  let index = settings.assistantHandoffs.firstIndex(where: {
                      $0.id == handoff.id && $0.key == handoff.key && $0.execution?.pendingWorkerAudit == audit
                  }) else { continue }
            if let change = comparison.sourceHeadChange {
                settings.assistantHandoffs[index].execution?.sourceHeadChange = change
            }
            if case .unexpected(let effects) = verdict {
                settings.assistantHandoffs[index].execution?.pendingWorkerAudit = nil
                settings.assistantHandoffs[index].execution?.remoteEffects = effects
                if audit.blocksManualWorker != true {
                    settings.assistantHandoffs[index].execution?.error = AssistantJobExecutor.ExecutionError.unexpectedRemoteEffects.rawValue
                }
                _ = enforce(verdict, handoff: handoff, settings: settings)
            } else if verdict == .headChanged {
                // Leave any checkpoint awaiting audit so the stale result cannot become a completion.
                settings.assistantHandoffs[index].execution?.pendingWorkerAudit = nil
                settings.assistantHandoffs[index].execution?.state = .failed
                if audit.blocksManualWorker != true {
                    settings.assistantHandoffs[index].execution?.error = AssistantJobExecutor.ExecutionError.headChanged.rawValue
                }
                settings.save()
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
