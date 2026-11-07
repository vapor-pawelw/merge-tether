import Foundation

@MainActor
final class MergeWorkflowMonitor {
    private struct Account: Codable, Hashable {
        let host: String
        let userID: Int
    }

    private struct Baselines: Codable, Equatable {
        var authored: [String: Snapshot] = [:]
        var reviews: [String: ReviewCheckpoint] = [:]
        var mergedReviews: Set<String>? = nil
    }

    private struct Snapshot: Codable, Equatable {
        var failedPipelineIDs: Set<Int>?
        var discussionNoteIDs: Set<Int>?
        var changesRequested: Bool?
        var blocker: BlockerCheckpoint?
        var parent: StackParent?
        var reportedParents: Set<String> = []
        var overdueAssignments: Set<String>?

        mutating func retain(_ enabled: Set<MergeWorkflowTrigger>) {
            if !enabled.contains(.pipelineFailure) { failedPipelineIDs = nil }
            if !enabled.contains(.newDiscussion) {
                discussionNoteIDs = nil
                changesRequested = nil
            }
            if !enabled.contains(.blockerChange) { blocker = nil }
            if !enabled.contains(.stackDependencyMerged) {
                parent = nil
                reportedParents = []
            }
            if !enabled.contains(.reviewWaiting) { overdueAssignments = nil }
        }
    }

    private struct ReviewCheckpoint: Codable, Equatable {
        var head: String
        var hasReviewed: Bool
        var reportedHeads: Set<String> = []
        var seenAuthorReplies: Set<Int>? = nil
        var reportedEvidenceContexts: Set<String>? = nil
        var reviewWasCovered: Bool? = nil
        var reviewCoverageEpoch: Int? = nil
        var lastObservedVerdictDigest: String? = nil
    }

    private struct BlockerCheckpoint: Codable, Equatable {
        var status: String?
        var inTrain: Bool?
        var revision = 0
    }

    private struct StackParent: Codable, Equatable {
        let projectID: Int
        let iid: Int
        let sourceBranch: String
        let targetBranch: String

        init(_ request: GitLabMergeRequest) {
            projectID = request.projectID
            iid = request.iid
            sourceBranch = request.sourceBranch
            targetBranch = request.targetBranch
        }

        var key: String { "\(projectID)!\(iid)" }
    }

    private struct Observation {
        let glab: GlabService
        let account: Account
        let request: GitLabMergeRequest

        func event(
            _ kind: MergeWorkflowTrigger, token: String, context: String,
            pipelineProjectID: Int? = nil, pipelineID: Int? = nil, jobID: Int? = nil,
            isInfrastructureFailure: Bool = false, noteIDs: [Int] = []
        ) -> MergeWorkflowEvent {
            MergeWorkflowEvent(
                kind: kind, mergeRequest: request,
                identity: "\(account.host)|\(account.userID)|\(kind.rawValue)|\(request.projectID)!\(request.iid)|\(token)",
                context: context, pipelineProjectID: pipelineProjectID, pipelineID: pipelineID, jobID: jobID,
                isInfrastructureFailure: isInfrastructureFailure, noteIDs: noteIDs
            )
        }
    }

    private static let storageKey = "automation.mergeWorkflowBaselines.v1"
    private let defaults: UserDefaults
    private let verdictDirectory: URL
    private var baselines: [Account: Baselines]
    private var isPolling = false

    init(defaults: UserDefaults = .standard, verdictDirectory: URL = ReviewVerdictStore.directory) {
        self.defaults = defaults
        self.verdictDirectory = verdictDirectory
        baselines = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([Account: Baselines].self, from: $0) } ?? [:]
    }

    func poll(
        glab: GlabService, host: String, user: GitLabAuthenticatedUser,
        authored: [GitLabMergeRequest], enabled: Set<MergeWorkflowTrigger>,
        reviewSLA: TimeInterval, now: Date = Date(),
        trackedReviews: Set<AssistantAutomationRunner.MergeRequestWork> = [],
        deliver: @MainActor (MergeWorkflowEvent) -> Void
    ) async {
        guard !isPolling, !Task.isCancelled else { return }
        let accountRevision = glab.accountRevision
        isPolling = true
        defer { isPolling = false }

        let account = Account(host: host.lowercased(), userID: user.id)
        let owned = authored.filter {
            $0.state == "opened" && $0.author.id == user.id && $0.webURL.isGitLabMergeRequest(host: host, iid: $0.iid)
        }
        let prior = baselines[account] ?? Baselines()
        var next = prior
        let ownedKeys = Set(owned.map(Self.key))
        next.authored = next.authored.filter { ownedKeys.contains($0.key) }

        var events: [MergeWorkflowEvent] = []
        var activeTrains: [Int: Set<Int>] = [:]
        if enabled.contains(.blockerChange) {
            for project in Set(owned.map(\.projectID)) {
                activeTrains[project] = try? await glab.fetchActiveMergeTrainIIDs(projectID: project, host: host)
            }
        }
        var defaultBranches: [Int: String] = [:]
        if enabled.contains(.stackDependencyMerged) {
            for project in Set(owned.compactMap(\.targetProjectID)) {
                defaultBranches[project] = try? await glab.fetchProjectDefaultBranch(projectID: project, host: host)
            }
        }

        for request in owned {
            guard !Task.isCancelled else { return }
            let key = Self.key(request)
            var snapshot = next.authored[key] ?? Snapshot()
            snapshot.retain(enabled)
            let observation = Observation(glab: glab, account: account, request: request)
            if enabled.contains(.pipelineFailure),
               let event = await pipelineFailure(observation, snapshot: &snapshot) { events.append(event) }
            if enabled.contains(.newDiscussion),
               let event = await newDiscussion(observation, snapshot: &snapshot) { events.append(event) }
            if enabled.contains(.blockerChange),
               let event = blockerChange(observation, inTrain: activeTrains[request.projectID]?.contains(request.iid),
                                         snapshot: &snapshot) { events.append(event) }
            if enabled.contains(.stackDependencyMerged),
               let event = await stackDependencyMerged(
                   observation, owned: owned, defaultBranch: request.targetProjectID.flatMap { defaultBranches[$0] },
                   snapshot: &snapshot
               ) { events.append(event) }
            if enabled.contains(.reviewWaiting),
               let event = await reviewWaiting(observation, seconds: reviewSLA, now: now,
                                               snapshot: &snapshot) { events.append(event) }
            next.authored[key] = snapshot
        }

        if enabled.contains(.reviewUpdate) {
            events.append(contentsOf: await reviewUpdates(glab: glab, account: account, baselines: &next, tracked: trackedReviews, ownedKeys: ownedKeys))
        } else {
            next.reviews.removeAll()
        }

        guard !Task.isCancelled, glab.accountRevision == accountRevision else { return }
        if prior != next {
            baselines[account] = next
            if let encoded = try? JSONEncoder().encode(baselines) {
                defaults.set(encoded, forKey: Self.storageKey)
            }
        }
        for event in events { deliver(event) }
    }

    private func pipelineFailure(_ observation: Observation, snapshot: inout Snapshot) async -> MergeWorkflowEvent? {
        let request = observation.request
        // The authored list omits head_pipeline. Only the detail response
        // can distinguish an MR without a pipeline from unavailable data.
        guard request.canMerge != nil || request.headPipeline != nil else { return nil }
        guard let pipeline = request.headPipeline, pipeline.status == "failed" else {
            if snapshot.failedPipelineIDs == nil { snapshot.failedPipelineIDs = [] }
            return nil
        }
        guard let id = pipeline.id, id > 0, let projectID = pipeline.projectID, projectID > 0 else { return nil }
        let seen = snapshot.failedPipelineIDs ?? []
        guard !seen.contains(id),
              let jobs = try? await observation.glab.fetchPipelineFailedJobs(
                projectID: projectID, pipelineID: id, host: observation.account.host
              ) else { return nil }

        snapshot.failedPipelineIDs = seen.union([id])
        let failed = jobs.filter { $0.status == "failed" && $0.id > 0 }
        let hardFailures = failed.filter { $0.allowFailure != true }
        let onlyFailure = hardFailures.count == 1 ? hardFailures.first : nil
        let infrastructure = onlyFailure?.allowFailure == false
            && onlyFailure?.failureReason == "runner_system_failure"
        let visibleReasons: Set<String> = [
            "runner_system_failure", "script_failure", "job_execution_timeout", "stuck_or_timeout_failure",
            "api_failure", "scheduler_failure", "data_integrity_failure", "unknown_failure"
        ]
        let ids = failed.sorted { $0.id < $1.id }.prefix(12).map { job in
            let reason = job.failureReason.flatMap { visibleReasons.contains($0) ? $0 : nil }
            return reason.map { "\(job.id) (\($0))" } ?? String(job.id)
        }.joined(separator: ", ")
        return observation.event(
            .pipelineFailure, token: String(id),
            context: "Latest MR pipeline \(id) in project \(projectID) failed. Failed job IDs: \(ids.isEmpty ? "unavailable" : ids).",
            pipelineProjectID: projectID, pipelineID: id, jobID: onlyFailure?.id, isInfrastructureFailure: infrastructure
        )
    }

    private func newDiscussion(_ observation: Observation, snapshot: inout Snapshot) async -> MergeWorkflowEvent? {
        let request = observation.request
        guard let discussions = try? await observation.glab.fetchMergeRequestDiscussions(
            projectID: request.projectID, iid: request.iid, host: observation.account.host
        ) else { return nil }
        let ids = Set(GitLabMergeRequestDiscussion.unresolvedFeedback(in: discussions, excluding: observation.account.userID)
            .compactMap(\.id))
        let previous = snapshot.discussionNoteIDs
        snapshot.discussionNoteIDs = (previous ?? []).union(ids)
        let requestedChanges = request.detailedMergeStatus == "requested_changes"
        let requestedNow = requestedChanges && snapshot.changesRequested == false
        if let status = request.detailedMergeStatus, Self.stableMergeStatuses.contains(status) {
            snapshot.changesRequested = requestedChanges
        }
        guard let previous else { return nil }
        let new = ids.subtracting(previous).sorted()
        guard !new.isEmpty || requestedNow else { return nil }
        let list = new.map(String.init).joined(separator: ", ")
        let context = new.isEmpty
            ? "A reviewer requested changes to this MR."
            : "New unresolved review notes. GitLab note IDs: \(list)."
        return observation.event(
            .newDiscussion, token: new.isEmpty ? "changes-\(request.sha ?? "")" : list, context: context, noteIDs: new
        )
    }

    private static let stableMergeStatuses: Set<String> = [
        "blocked_status", "ci_must_pass", "commits_status", "conflict", "discussions_not_resolved",
        "draft_status", "external_status_checks", "jira_association_missing", "mergeable",
        "merge_request_blocked", "merge_time", "need_rebase", "not_approved", "requested_changes",
        "security_policy_violations", "status_checks_must_pass", "title_regex", "locked_paths", "locked_lfs_files"
    ]

    private func blockerChange(
        _ observation: Observation, inTrain: Bool?, snapshot: inout Snapshot
    ) -> MergeWorkflowEvent? {
        let status = observation.request.detailedMergeStatus.flatMap {
            Self.stableMergeStatuses.contains($0) ? $0 : nil
        }
        let previous = snapshot.blocker ?? BlockerCheckpoint()
        var current = previous
        current.status = status ?? previous.status
        current.inTrain = inTrain ?? previous.inTrain

        var changes: [String] = []
        if let old = previous.status, let status, old != status {
            changes.append("Merge status changed from \(old) to \(status).")
        }
        if previous.inTrain == true, inTrain == false {
            changes.append("The still-open MR left the active merge train.")
        }
        if !changes.isEmpty { current.revision += 1 }
        snapshot.blocker = current
        guard !changes.isEmpty else { return nil }
        return observation.event(.blockerChange, token: String(current.revision), context: changes.joined(separator: " "))
    }

    private func stackDependencyMerged(
        _ observation: Observation, owned: [GitLabMergeRequest], defaultBranch: String?, snapshot: inout Snapshot
    ) async -> MergeWorkflowEvent? {
        let child = observation.request
        if let tracked = snapshot.parent {
            if child.targetBranch != tracked.sourceBranch && child.targetBranch != tracked.targetBranch {
                snapshot.parent = nil
                return nil
            }
            if owned.contains(where: { Self.key($0) == tracked.key }) { return nil }
            guard let parent = try? await observation.glab.fetchMergeRequest(
                projectID: tracked.projectID, iid: tracked.iid, host: observation.account.host
            ) else { return nil }
            guard parent.state != "opened" else { return nil }
            snapshot.parent = nil
            guard parent.state == "merged", Self.matchesStackRelationship(parent, child: child, tracked: tracked),
                  snapshot.reportedParents.insert(tracked.key).inserted else { return nil }
            return observation.event(
                .stackDependencyMerged, token: tracked.key,
                context: "Previously tracked stack parent project \(tracked.projectID), MR !\(tracked.iid), is merged."
            )
        }

        // A release MR whose source is the default branch is unrelated to
        // normal changes targeting that branch unless GitLab links them.
        let mayInferStack = defaultBranch != nil && child.targetBranch != defaultBranch
        let localMatches = mayInferStack ? owned.filter { Self.isOpenStackParent($0, of: child) } : []
        if localMatches.count == 1, let parent = localMatches.first {
            snapshot.parent = StackParent(parent)
        } else if localMatches.isEmpty, let dependencies = try? await observation.glab.fetchMergeRequestDependencies(
            projectID: child.projectID, iid: child.iid, host: observation.account.host
        ) {
            let matches = dependencies.filter { Self.isOpenStackParent($0, of: child) }
            if matches.count == 1, let parent = matches.first { snapshot.parent = StackParent(parent) }
        }
        return nil
    }

    private static func isOpenStackParent(_ parent: GitLabMergeRequest, of child: GitLabMergeRequest) -> Bool {
        parent.state == "opened" && key(parent) != key(child)
            && parent.sourceProjectID == child.targetProjectID && parent.targetProjectID == child.targetProjectID
            && child.targetProjectID != nil && parent.sourceBranch == child.targetBranch
            && parent.sourceBranch != parent.targetBranch
    }

    private static func matchesStackRelationship(
        _ parent: GitLabMergeRequest, child: GitLabMergeRequest, tracked: StackParent
    ) -> Bool {
        child.targetProjectID != nil && parent.sourceProjectID == child.targetProjectID
            && parent.targetProjectID == child.targetProjectID
            && parent.sourceBranch == tracked.sourceBranch && parent.targetBranch == tracked.targetBranch
    }

    private func reviewWaiting(
        _ observation: Observation, seconds: TimeInterval, now: Date, snapshot: inout Snapshot
    ) async -> MergeWorkflowEvent? {
        let request = observation.request
        guard request.draft == false, seconds.isFinite, seconds > 0,
              let reviewers = try? await observation.glab.fetchMergeRequestReviewers(
                projectID: request.projectID, iid: request.iid, host: observation.account.host
              ) else { return nil }
        let overdue = reviewers.compactMap { reviewer -> (key: String, userID: Int)? in
            guard reviewer.state == "unreviewed", reviewer.user.id > 0,
                  reviewer.user.id != observation.account.userID,
                  let raw = reviewer.createdAt, let since = Self.parseDate(raw),
                  now.timeIntervalSince(since) >= seconds else { return nil }
            return ("\(reviewer.user.id)@\(since.timeIntervalSince1970)", reviewer.user.id)
        }
        let prior = snapshot.overdueAssignments
        snapshot.overdueAssignments = (prior ?? []).union(overdue.map(\.key))
        guard let prior else { return nil }
        let new = overdue.filter { !prior.contains($0.key) }
        guard !new.isEmpty else { return nil }
        let userIDs = Set(new.map(\.userID)).sorted().map(String.init).joined(separator: ", ")
        return observation.event(
            .reviewWaiting, token: new.map(\.key).sorted().joined(separator: ","),
            context: "Review wait exceeded the configured threshold. Pending GitLab reviewer IDs: \(userIDs)."
        )
    }

    private func reviewUpdates(
        glab: GlabService, account: Account, baselines: inout Baselines,
        tracked: Set<AssistantAutomationRunner.MergeRequestWork>, ownedKeys: Set<String>
    ) async -> [MergeWorkflowEvent] {
        let assigned = try? await glab.fetchReviewAssignedMergeRequests(userID: account.userID, host: account.host)
        guard assigned != nil || !tracked.isEmpty else { return [] }
        var candidates = assigned ?? []
        var known = Set(candidates.map(Self.key))
        var retained = Set(tracked.filter { $0.host.lowercased() == account.host })
        var merged = baselines.mergedReviews ?? []
        for (key, checkpoint) in baselines.reviews where checkpoint.hasReviewed {
            let parts = key.split(separator: "!")
            if parts.count == 2, let projectID = Int(parts[0]), let iid = Int(parts[1]) {
                retained.insert(.init(host: account.host, projectID: projectID, iid: iid))
            }
        }
        for work in retained {
            let key = "\(work.projectID)!\(work.iid)"
            guard !known.contains(key), !ownedKeys.contains(key), !merged.contains(key),
                  let request = try? await glab.fetchMergeRequest(projectID: work.projectID, iid: work.iid, host: account.host)
            else { continue }
            if request.state == "merged" { merged.insert(key); continue }
            candidates.append(request)
            known.insert(key)
        }
        for request in candidates where request.state == "opened" { merged.remove(Self.key(request)) }
        baselines.mergedReviews = merged.isEmpty ? nil : merged
        let others = candidates.filter {
            $0.state == "opened" && $0.author.id != account.userID
                && $0.webURL.isGitLabMergeRequest(host: account.host, iid: $0.iid)
        }
        let keys = Set(others.map(Self.key))
        baselines.reviews = baselines.reviews.filter { keys.contains($0.key) }
        var events: [MergeWorkflowEvent] = []
        for request in others {
            guard !Task.isCancelled else { return [] }
            guard let head = request.sha, !head.isEmpty, request.draft == false else { continue }
            let reviewers = try? await glab.fetchMergeRequestReviewers(projectID: request.projectID, iid: request.iid, host: account.host)
            let reviewer = reviewers?.first(where: { $0.user.id == account.userID })
            let key = Self.key(request)
            let reviewed = reviewer.map { ["reviewed", "approved", "requested_changes"].contains($0.state) } ?? false
            let discussions = try? await glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: account.host)
            let replies = discussions.map { threads in
                Set(threads.flatMap { thread -> [Int] in
                    let firstMine = thread.notes.filter { $0.system != true && $0.author?.id == account.userID }.compactMap(\.id).min()
                    guard let firstMine else { return [] }
                    return thread.notes.filter { $0.system != true && $0.author?.id == request.author.id && ($0.id ?? 0) > firstMine }.compactMap(\.id)
                })
            }
            let hasReviewEvidence = reviewed || discussions?.contains(where: { $0.notes.contains { $0.system != true && $0.author?.id == account.userID } }) == true
            guard reviewer != nil || hasReviewEvidence else { continue }
            let firstObservation = baselines.reviews[key] == nil
            var previous = baselines.reviews[key] ?? ReviewCheckpoint(head: head, hasReviewed: hasReviewEvidence,
                reportedHeads: [head], seenAuthorReplies: replies)
            let verdict = ReviewVerdictStore.verdict(host: account.host, projectID: request.projectID,
                iid: request.iid, in: verdictDirectory)
            let verdictDigest: String? = {
                guard let verdict, verdict.version == 1, verdict.headSHA == head else { return nil }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                return (try? encoder.encode(verdict)).map { UserAttentionSnapshot.digest(String(decoding: $0, as: UTF8.self)) }
            }()
            let changedVerdict = verdictDigest.map {
                previous.lastObservedVerdictDigest != nil && previous.lastObservedVerdictDigest != $0
            } ?? false
            let covered = reviewCoverage(request, discussions: discussions, account: account, verdict: verdict)
            if changedVerdict || (covered == true && previous.reviewWasCovered != true) {
                previous.reviewCoverageEpoch = (previous.reviewCoverageEpoch ?? 0) + 1
            }
            if let verdictDigest { previous.lastObservedVerdictDigest = verdictDigest }
            if let covered {
                previous.reviewWasCovered = covered
            }
            let epoch = previous.reviewCoverageEpoch ?? 0
            let staleContext = await staleReviewContext(request, discussions: discussions, glab: glab,
                account: account, verdict: verdict)
                .map { epoch == 0 ? $0 : $0 + "-coverage-\(epoch)" }
            if firstObservation {
                previous.hasReviewed = hasReviewEvidence || staleContext != nil
                previous.reportedEvidenceContexts = staleContext.map { Set([$0]) }
                baselines.reviews[key] = previous
                if let staleContext {
                    let observation = Observation(glab: glab, account: account, request: request)
                    events.append(observation.event(.reviewUpdate, token: head + "-context-" + staleContext,
                        context: "Your recorded review does not cover the current discussion content at this head. Recheck current discussions and record a fresh review verdict."))
                }
                continue
            }
            let newReplies = replies.flatMap { current in previous.seenAuthorReplies.map { current.subtracting($0) } } ?? []
            if let replies { previous.seenAuthorReplies = (previous.seenAuthorReplies ?? []).union(replies) }
            let hasReviewed = previous.hasReviewed || hasReviewEvidence || staleContext != nil
            let changedHead = hasReviewed && previous.head != head && previous.reportedHeads.insert(head).inserted
            let staleUnreported = staleContext.map { !(previous.reportedEvidenceContexts ?? []).contains($0) } == true
            if hasReviewed && (changedHead || !newReplies.isEmpty || staleUnreported) {
                let observation = Observation(glab: glab, account: account, request: request)
                let ids = newReplies.sorted()
                let token = staleUnreported && !changedHead && ids.isEmpty
                    ? head + "-context-" + (staleContext ?? "")
                    : head + (ids.isEmpty ? "" : "-replies-" + ids.map(String.init).joined(separator: ","))
                let context = (changedHead ? "The MR head changed after your recorded review. " : "")
                    + (ids.isEmpty ? "" : "The author replied after your review comments. Recheck reply note IDs: " + ids.map(String.init).joined(separator: ", ") + ".")
                    + (staleUnreported ? " Your recorded review does not cover the current discussion content. Recheck all current discussions and record a fresh verdict." : "")
                events.append(observation.event(.reviewUpdate, token: token, context: context, noteIDs: ids))
                if let staleContext {
                    previous.reportedEvidenceContexts = (previous.reportedEvidenceContexts ?? []).union([staleContext])
                }
            }
            previous.head = head
            previous.hasReviewed = hasReviewed
            baselines.reviews[key] = previous
        }
        return events
    }

    private func reviewCoverage(_ request: GitLabMergeRequest, discussions: [GitLabMergeRequestDiscussion]?,
                                account: Account, verdict: ReviewVerdict?) -> Bool? {
        guard let head = request.sha, let discussions, ReviewVerdict.fingerprint(discussions) != nil else { return nil }
        return verdict?.covers(head: head, discussions: discussions, reviewerID: account.userID,
                publishedDrafts: ReviewVerdictStore.seenDrafts(host: account.host, projectID: request.projectID,
                    iid: request.iid, in: verdictDirectory)) == true
    }

    private func staleReviewContext(_ request: GitLabMergeRequest,
                                   discussions: [GitLabMergeRequestDiscussion]?, glab: GlabService,
                                   account: Account, verdict: ReviewVerdict?) async -> String? {
        guard let head = request.sha, let discussions, let fingerprint = ReviewVerdict.fingerprint(discussions),
              let verdict, verdict.version == 1, verdict.headSHA == head,
              !verdict.covers(head: head, discussions: discussions, reviewerID: account.userID,
                  publishedDrafts: ReviewVerdictStore.seenDrafts(host: account.host, projectID: request.projectID,
                      iid: request.iid, in: verdictDirectory)),
              !discussions.flatMap(\.notes).contains(where: {
                  $0.system != true && $0.author?.id == account.userID && $0.resolvable == true && $0.resolved != true
              }),
              !AssistantAutomationRunner.isWorking(on: .init(host: account.host, projectID: request.projectID, iid: request.iid)),
              let draftCount = try? await glab.fetchOwnDraftNoteCount(projectID: request.projectID, iid: request.iid,
                  host: account.host, userID: account.userID), draftCount == 0 else { return nil }
        guard !Task.isCancelled,
              !AssistantAutomationRunner.isWorking(on: .init(host: account.host, projectID: request.projectID, iid: request.iid))
        else { return nil }
        return UserAttentionSnapshot.digest([head, request.semanticContextFingerprint, fingerprint,
            String(verdict.version), verdict.verdict.rawValue, verdict.discussionFingerprint ?? "legacy"].joined(separator: "|"))
    }

    private static func key(_ request: GitLabMergeRequest) -> String {
        "\(request.projectID)!\(request.iid)"
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
