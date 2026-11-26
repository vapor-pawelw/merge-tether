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
        var reportedPipelineFailures: [String: Set<String>]?
        var discussionNoteIDs: Set<Int>?
        var changesRequested: Bool?
        var blocker: BlockerCheckpoint?
        var parent: StackParent?
        var reportedParents: Set<String> = []
        var overdueAssignments: Set<String>?

        mutating func retain(_ enabled: Set<MergeWorkflowTrigger>) {
            if !enabled.contains(.pipelineFailure) {
                failedPipelineIDs = nil
                reportedPipelineFailures = nil
            }
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
        var reportedHeadVerdicts: [String: String]? = nil
        var seenAuthorReplies: Set<Int>? = nil
        var reportedEvidenceContexts: Set<String>? = nil
        var reviewWasCovered: Bool? = nil
        var reviewCoverageEpoch: Int? = nil
        var lastObservedVerdictDigest: String? = nil
        /// The head, MR diff content and discussion text your last covering verdict assessed.
        /// Later passes review only what changed since, so unrelated edits never reopen the whole MR.
        var reviewedHead: String? = nil
        // Legacy reviewedDiffDigest values were saved without confirming the head after the diff read.
        var reviewedDiff: ReviewDiffSnapshot? = nil
        var reviewedNoteRevisions: [Int: String]? = nil
    }

    private struct BlockerCheckpoint: Codable, Equatable {
        var status: GitLabDetailedMergeStatus?
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
            isInfrastructureFailure: Bool = false, noteIDs: [Int] = [], failedPipelineJobIDs: [Int]? = nil,
            reviewUpdateReasons: [ReviewLaunchReason]? = nil
        ) -> MergeWorkflowEvent {
            MergeWorkflowEvent(
                kind: kind, mergeRequest: request,
                identity: "\(account.host)|\(account.userID)|\(kind.rawValue)|\(request.projectID)!\(request.iid)|\(token)",
                context: context, pipelineProjectID: pipelineProjectID, pipelineID: pipelineID, jobID: jobID,
                isInfrastructureFailure: isInfrastructureFailure, noteIDs: noteIDs, failedPipelineJobIDs: failedPipelineJobIDs,
                reviewUpdateReasons: reviewUpdateReasons
            )
        }
    }

    private static let storageKey = "automation.mergeWorkflowBaselines.v1"
    private let persistenceStore: DurableSettingsStore
    private let verdictDirectory: URL
    private var baselines: [Account: Baselines]
    private var isPolling = false

    init(defaults: UserDefaults = .standard, verdictDirectory: URL = ReviewVerdictStore.directory,
         persistenceStore: DurableSettingsStore? = nil) {
        let store = persistenceStore ?? DurableSettingsStore(defaults: defaults)
        self.persistenceStore = store
        self.verdictDirectory = verdictDirectory
        baselines = store.load(Self.storageKey, fallback: [:])
    }

    func poll(
        glab: GlabService, host: String, user: GitLabAuthenticatedUser,
        authored: [GitLabMergeRequest], enabled: Set<MergeWorkflowTrigger>,
        reviewSLA: TimeInterval, now: Date = Date(),
        trackedReviews: Set<AssistantAutomationRunner.MergeRequestWork> = [],
        automationScope: MRAutomationScope = .init(),
        reviewHistory: [AssistantAutomationRunner.Handoff] = [],
        isCurrent: @MainActor () -> Bool = { true },
        deliver: @MainActor (MergeWorkflowEvent) -> Void
    ) async {
        guard !isPolling, !Task.isCancelled, isCurrent() else { return }
        guard persistenceStore.failures[Self.storageKey] == nil else {
            persistenceStore.preserveCorruptValues()
            persistenceStore.recordFailure(Self.storageKey)
            return
        }
        let accountRevision = glab.accountRevision
        isPolling = true
        defer { isPolling = false }

        let account = Account(host: GitLabAccountIdentity.normalize(host), userID: user.id)
        let owned = authored.filter {
            $0.state == .opened && glab.owns($0, userID: user.id) && $0.webURL.isGitLabMergeRequest(host: host, iid: $0.iid)
        }
        let eligibleOwned = owned.filter { automationScope.permits($0, host: host, username: user.username) }
        let prior = baselines[account] ?? Baselines()
        var next = prior
        let ownedKeys = Set(owned.map(Self.key))
        next.authored = next.authored.filter { ownedKeys.contains($0.key) }

        var events: [MergeWorkflowEvent] = []
        var activeTrains: [Int: Set<Int>] = [:]
        if enabled.contains(.blockerChange) {
            for project in Set(eligibleOwned.map(\.projectID)) {
                activeTrains[project] = try? await glab.fetchActiveMergeTrainIIDs(projectID: project, host: host)
            }
        }
        var defaultBranches: [Int: String] = [:]
        if enabled.contains(.stackDependencyMerged) {
            for project in Set(eligibleOwned.compactMap(\.targetProjectID)) {
                defaultBranches[project] = try? await glab.fetchProjectDefaultBranch(projectID: project, host: host)
            }
        }

        // Paused MRs retain their existing checkpoints without consuming new events.
        for request in eligibleOwned {
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
            events.append(contentsOf: await reviewUpdates(glab: glab, account: account, baselines: &next, tracked: trackedReviews, ownedKeys: ownedKeys,
                automationScope: automationScope, username: user.username, reviewHistory: reviewHistory))
        } else {
            next.reviews.removeAll()
        }

        guard !Task.isCancelled, glab.accountRevision == accountRevision, isCurrent() else { return }
        if prior != next {
            var proposed = baselines
            proposed[account] = next
            guard persistenceStore.save(proposed, forKey: Self.storageKey) else { return }
            guard persistenceStore.synchronize() else {
                persistenceStore.recordFailure(Self.storageKey)
                return
            }
            baselines = proposed
        }
        for event in events { deliver(event) }
    }

    private func pipelineFailure(_ observation: Observation, snapshot: inout Snapshot) async -> MergeWorkflowEvent? {
        let request = observation.request
        // The authored list omits head_pipeline. Only the detail response
        // can distinguish an MR without a pipeline from unavailable data.
        guard request.canMerge != nil || request.headPipeline != nil else { return nil }
        guard let pipeline = request.headPipeline, pipeline.status == .failed else {
            if snapshot.failedPipelineIDs == nil { snapshot.failedPipelineIDs = [] }
            return nil
        }
        guard let id = pipeline.id, id > 0, let projectID = pipeline.projectID, projectID > 0 else { return nil }
        guard let jobs = try? await observation.glab.fetchPipelineFailedJobs(
            projectID: projectID, pipelineID: id, host: observation.account.host
        ) else { return nil }

        let blockingIDs = GitLabPipelineJob.blockingFailureIDs(jobs)
        let pipelineKey = "\(projectID)/\(id)"
        let signature = UserAttentionSnapshot.digest(blockingIDs.map(String.init).joined(separator: ","))
        var reported = snapshot.reportedPipelineFailures ?? [:]
        let isFirstObservation = reported[pipelineKey] == nil
        guard !blockingIDs.isEmpty || isFirstObservation,
              reported[pipelineKey, default: []].insert(signature).inserted else { return nil }
        snapshot.reportedPipelineFailures = reported
        // Old checkpoints knew only that the pipeline had already been reported.
        if isFirstObservation, snapshot.failedPipelineIDs?.contains(id) == true { return nil }
        let failed = jobs.filter { $0.status == .failed && $0.id > 0 }
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
            .pipelineFailure, token: blockingIDs.isEmpty ? String(id) : "\(id)-\(projectID)-jobs-\(signature)",
            context: "Latest MR pipeline \(id) in project \(projectID) failed. Failed job IDs: \(ids.isEmpty ? "unavailable" : ids).",
            pipelineProjectID: projectID, pipelineID: id, jobID: onlyFailure?.id, isInfrastructureFailure: infrastructure,
            failedPipelineJobIDs: blockingIDs.isEmpty ? nil : blockingIDs
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
        let requestedChanges = request.detailedMergeStatus == .requestedChanges
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

    private static let stableMergeStatuses: Set<GitLabDetailedMergeStatus> = [
        .blockedStatus, .ciMustPass, .commitsStatus, .conflict, .discussionsNotResolved,
        .draftStatus, .externalStatusChecks, .jiraAssociationMissing, .mergeable,
        .mergeRequestBlocked, .mergeTime, .needRebase, .notApproved, .requestedChanges,
        .securityPolicyViolations, .statusChecksMustPass, .titleRegex, .lockedPaths, .lockedLfsFiles
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
            changes.append("Merge status changed from \(old.rawValue) to \(status.rawValue).")
        }
        let leftMergeTrain = previous.inTrain == true && inTrain == false
        if leftMergeTrain {
            changes.append("The still-open MR left the active merge train.")
        }
        if !changes.isEmpty { current.revision += 1 }
        snapshot.blocker = current
        guard !changes.isEmpty else { return nil }
        var event = observation.event(.blockerChange, token: String(current.revision), context: changes.joined(separator: " "))
        event.leftMergeTrain = leftMergeTrain ? true : nil
        return event
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
            guard !parent.isOpen else { return nil }
            snapshot.parent = nil
            guard parent.state == .merged, Self.matchesStackRelationship(parent, child: child, tracked: tracked),
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
        parent.isOpen && key(parent) != key(child)
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
        guard seconds.isFinite, seconds > 0,
              let reviewers = try? await observation.glab.fetchMergeRequestReviewers(
                projectID: request.projectID, iid: request.iid, host: observation.account.host
              ) else { return nil }
        let overdue = reviewers.compactMap { reviewer -> (key: String, userID: Int)? in
            guard reviewer.state == .unreviewed, reviewer.user.id > 0,
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
        tracked: Set<AssistantAutomationRunner.MergeRequestWork>, ownedKeys: Set<String>,
        automationScope: MRAutomationScope, username: String, reviewHistory: [AssistantAutomationRunner.Handoff]
    ) async -> [MergeWorkflowEvent] {
        let assigned = try? await glab.fetchReviewAssignedMergeRequests(userID: account.userID, host: account.host)
        var candidates = assigned ?? []
        var known = Set(candidates.map(Self.key))
        var retained = Set(tracked.filter { GitLabAccountIdentity.normalize($0.host) == account.host })
        var merged = baselines.mergedReviews ?? []
        var failedDetailReads: Set<String> = []
        for (key, checkpoint) in baselines.reviews where checkpoint.hasReviewed {
            let parts = key.split(separator: "!")
            if parts.count == 2, let projectID = Int(parts[0]), let iid = Int(parts[1]) {
                retained.insert(.init(host: account.host, projectID: projectID, iid: iid))
            }
        }
        for work in retained {
            let key = "\(work.projectID)!\(work.iid)"
            guard !known.contains(key), !ownedKeys.contains(key), !merged.contains(key) else { continue }
            guard let request = try? await glab.fetchMergeRequest(projectID: work.projectID, iid: work.iid, host: account.host) else {
                failedDetailReads.insert(key)
                continue
            }
            if request.state == .merged { merged.insert(key); continue }
            candidates.append(request)
            known.insert(key)
        }
        for request in candidates where request.isOpen { merged.remove(Self.key(request)) }
        baselines.mergedReviews = merged.isEmpty ? nil : merged
        let otherRequests = candidates.filter {
            !glab.owns($0, userID: account.userID)
                && $0.webURL.isGitLabMergeRequest(host: account.host, iid: $0.iid)
        }
        let nonterminalKeys = Set(otherRequests.lazy.filter { $0.state != .merged && $0.state != .closed }.map(Self.key))
        baselines.reviews = baselines.reviews.filter { key, _ in
            guard !ownedKeys.contains(key), !merged.contains(key) else { return false }
            return nonterminalKeys.contains(key) || failedDetailReads.contains(key)
                || (assigned == nil && !known.contains(key))
        }
        var events: [MergeWorkflowEvent] = []
        for request in otherRequests where request.isOpen {
            guard !Task.isCancelled else { return [] }
            guard automationScope.permits(request, host: account.host, username: username),
                  let head = request.sha, !head.isEmpty else { continue }
            let reviewers = try? await glab.fetchMergeRequestReviewers(projectID: request.projectID, iid: request.iid, host: account.host)
            let reviewer = reviewers?.first(where: { $0.user.id == account.userID })
            let key = Self.key(request)
            let reviewed = reviewer.map { [.reviewed, .approved, .requestedChanges].contains($0.state) } ?? false
            let discussions = try? await glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: account.host)
            let replies = discussions.map { threads in
                Set(GitLabMergeRequestDiscussion.activeForReview(threads).flatMap { thread -> [Int] in
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
            let candidate = ReviewVerdictStore.verdict(host: account.host, projectID: request.projectID,
                iid: request.iid, user: .init(id: account.userID, username: username), in: verdictDirectory)
            let verdictRun = candidate.flatMap { verdict in
                reviewHistory.first {
                    $0.id == verdict.runID && $0.key.work.host == account.host && $0.key.username == username
                        && $0.key.work.projectID == request.projectID && $0.key.work.iid == request.iid
                }
            }
            let diagnosedHead = verdictRun.flatMap { run in
                AssistantAutomationRunner.isForeignPipelineDiagnosis(for: run, history: reviewHistory) ? candidate?.headSHA : nil
            }
            let verdict = diagnosedHead == nil ? candidate : nil
            if let diagnosedHead, previous.reviewedHead == diagnosedHead {
                previous.reviewedHead = nil
                previous.reviewedDiff = nil
                previous.reviewedNoteRevisions = nil
                previous.lastObservedVerdictDigest = nil
            }
            let savedVerdictDigest: String? = {
                guard let verdict, verdict.version == 1 else { return nil }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                return (try? encoder.encode(verdict)).map { UserAttentionSnapshot.digest(String(decoding: $0, as: UTF8.self)) }
            }()
            let verdictDigest = verdict?.headSHA == head ? savedVerdictDigest : nil
            let changedVerdict = verdictDigest.map {
                previous.lastObservedVerdictDigest != nil && previous.lastObservedVerdictDigest != $0
            } ?? false
            let changedTarget = await changedReviewTarget(request, run: verdictRun, verdict: verdict, host: account.host, glab: glab)
            let covered = changedTarget == nil
                ? reviewCoverage(request, discussions: discussions, account: account, verdict: verdict)
                : false
            if changedVerdict || (covered == true && previous.reviewWasCovered != true) {
                previous.reviewCoverageEpoch = (previous.reviewCoverageEpoch ?? 0) + 1
            }
            if let verdictDigest { previous.lastObservedVerdictDigest = verdictDigest }
            if let covered {
                previous.reviewWasCovered = covered
            }
            if covered == true, let discussions {
                let revisions = MergeRequestDiffDigest.noteRevisions(GitLabMergeRequestDiscussion.activeForReview(discussions),
                        excludingAuthor: account.userID)
                // A failed read leaves no digest, so a later head change is never mistaken for a rebase.
                if previous.reviewedDiff?.headSHA != head {
                    previous.reviewedDiff = try? await glab.fetchReviewDiffSnapshot(for: request, host: account.host)
                }
                previous.reviewedHead = head
                previous.reviewedNoteRevisions = revisions
            }
            // A no-findings review may finish and lose its current head between two polls.
            // Its authenticated completion can establish earlier coverage without borrowing the live diff or notes.
            var recoveredReview = false
            if !previous.hasReviewed, !hasReviewEvidence, previous.reviewedHead == nil,
               let verdict, verdict.version == 1, verdict.headSHA != head,
               let verdictRun, verdictRun.execution?.state == .succeeded,
               AssistantJobJournal.reviewVerdict(for: verdictRun) == verdict {
                previous.reviewedHead = verdict.headSHA
                previous.reviewedDiff = nil
                previous.reviewedNoteRevisions = nil
                recoveredReview = true
            }
            let externallySuperseded = covered != true && reviewHistory.contains { job in
                guard job.key.work.host == account.host, job.key.username == username,
                      job.key.work.projectID == request.projectID, job.key.work.iid == request.iid,
                      job.manual != true, job.execution?.state == .failed, job.execution?.cancellationOrigin != .user,
                      job.execution?.remoteEffects?.isEmpty != false, job.execution?.pendingWorkerAudit == nil,
                      let change = job.execution?.sourceHeadChange, change.accountID == account.userID,
                      change.attributedToAnotherAccount, change.previousSHA == job.expectedHeadSHA, change.currentSHA == head
                else { return false }
                return AssistantAutomationRunner.recordsReviewVerdict(for: job, history: reviewHistory)
            }
            let supersededInstructions = "Another GitLab account pushed during the previous review. Review the current diff and discussions at the new head."
            let epoch = previous.reviewCoverageEpoch ?? 0
            let changedActiveNotes = if let reviewedNotes = previous.reviewedNoteRevisions, let discussions {
                MergeRequestDiffDigest.changedNotes(from: reviewedNotes,
                    to: MergeRequestDiffDigest.noteRevisions(GitLabMergeRequestDiscussion.activeForReview(discussions),
                        excludingAuthor: account.userID))
            } else { [Int]() }
            let staleEvidence = if let changedTarget {
                "target-" + UserAttentionSnapshot.digest("\(changedTarget.targetProjectID)|\(changedTarget.targetBranch)|\(changedTarget.baseSHA)")
            } else if externallySuperseded {
                "external-push-" + head
            } else {
                await staleReviewContext(request, discussions: discussions, glab: glab,
                    account: account, verdict: verdict, changedActiveNotes: changedActiveNotes)
            }
            let staleContext = staleEvidence.map { epoch == 0 ? $0 : $0 + "-coverage-\(epoch)" }
            let targetReviewInstructions = "The MR target or diff base changed. Review the entire current diff and discussions, including files previously reviewed, and record a fresh verdict."
            let metadataNeedsReview = staleContext != nil
                && verdict?.requiresFreshReview(forSemanticContext: request.semanticContextFingerprint) == true
            let staleReason: ReviewLaunchReason = if changedTarget != nil {
                .targetChanged
            } else if externallySuperseded {
                .pushedDuringReview
            } else if metadataNeedsReview {
                verdict?.semanticContextFingerprint == nil ? .metadataCoverageMissing : .metadataChanged
            } else {
                verdict?.discussionFingerprint == nil ? .discussionCoverageMissing : .discussionsChanged
            }
            let hasReviewed = previous.hasReviewed || hasReviewEvidence || previous.reviewedHead != nil || staleContext != nil
            if firstObservation && !recoveredReview {
                previous.hasReviewed = hasReviewed
                previous.reportedEvidenceContexts = staleContext.map { Set([$0]) }
                baselines.reviews[key] = previous
                if let staleContext {
                    let observation = Observation(glab: glab, account: account, request: request)
                    events.append(observation.event(.reviewUpdate, token: head + "-context-" + staleContext,
                        context: changedTarget != nil ? targetReviewInstructions
                            : externallySuperseded ? supersededInstructions
                            : metadataNeedsReview ? IncrementalReviewScope.metadataReviewInstructions
                            : "Your recorded review does not cover the current discussion content at this head. Recheck current discussions and record a fresh review verdict.",
                        reviewUpdateReasons: [staleReason]))
                }
                continue
            }
            let newReplies = replies.flatMap { current in previous.seenAuthorReplies.map { current.subtracting($0) } } ?? []
            if let replies { previous.seenAuthorReplies = (previous.seenAuthorReplies ?? []).union(replies) }
            let movedToUncoveredHead = hasReviewed && previous.head != head && covered != true
            let firstHeadReport = recoveredReview || (movedToUncoveredHead && !previous.reportedHeads.contains(head))
            // A prior report at this SHA used older review evidence. A fresh event needs its own admission ID.
            let returnToken: String? = if movedToUncoveredHead, !firstHeadReport, verdict?.headSHA != head,
                let savedVerdictDigest, previous.reportedHeadVerdicts?[head] != savedVerdictDigest {
                head + "-return-" + savedVerdictDigest
            } else { nil }
            let changedHead = firstHeadReport || returnToken != nil
            if changedHead {
                previous.reportedHeads.insert(head)
                if let savedVerdictDigest {
                    previous.reportedHeadVerdicts = previous.reportedHeadVerdicts ?? [:]
                    previous.reportedHeadVerdicts?[head] = savedVerdictDigest
                }
            }
            let staleUnreported = staleContext.map { !(previous.reportedEvidenceContexts ?? []).contains($0) } == true
            if hasReviewed && (changedHead || !newReplies.isEmpty || staleUnreported) {
                let observation = Observation(glab: glab, account: account, request: request)
                let ids = newReplies.sorted()
                let token: String
                if staleUnreported, !changedHead, ids.isEmpty {
                    token = "\(head)-context-\(staleContext ?? "")"
                } else if ids.isEmpty {
                    token = returnToken ?? head
                } else {
                    let replyIDs = ids.map { String($0) }.joined(separator: ",")
                    token = "\(returnToken ?? head)-replies-\(replyIDs)"
                }
                var scope = IncrementalReviewScope(currentHead: head)
                let observedReviewHead = previous.head == diagnosedHead ? nil : previous.head
                let reviewedBaseline = previous.reviewedHead == head ? observedReviewHead : previous.reviewedHead ?? observedReviewHead
                if changedHead, !externallySuperseded, let reviewed = reviewedBaseline {
                    scope.reviewedHead = reviewed
                    if let reviewedDiff = previous.reviewedDiff, reviewedDiff.headSHA == reviewed,
                       let currentDiff = try? await glab.fetchReviewDiffSnapshot(for: request, host: account.host) {
                        scope.diffUnchanged = currentDiff.digest == reviewedDiff.digest
                    }
                }
                scope.changedNoteIDs = changedActiveNotes
                var parts: [String] = []
                var reasons: [ReviewLaunchReason] = []
                if changedHead {
                    reasons.append(externallySuperseded ? .pushedDuringReview : .headChanged)
                    parts.append(scope.reviewedHead == nil
                        ? "The MR head changed. Review the current diff and discussions at this head."
                        : "The MR head changed after your recorded review.")
                }
                if !ids.isEmpty {
                    reasons.append(.authorReplied)
                    parts.append("The author replied after your review comments. Recheck reply note IDs: "
                        + ids.map(String.init).joined(separator: ", ") + ".")
                }
                if changedTarget != nil {
                    parts.append(targetReviewInstructions)
                } else if externallySuperseded {
                    parts.append(supersededInstructions)
                } else if metadataNeedsReview {
                    parts.append(IncrementalReviewScope.metadataReviewInstructions)
                } else if staleUnreported {
                    parts.append("Your recorded review does not cover the current discussion content. Record a fresh verdict after checking what changed.")
                }
                let scoped = metadataNeedsReview || changedTarget != nil ? "" : scope.instructions
                if !scoped.isEmpty { parts.append(scoped) }
                let onlyOwnOrRemoved = staleUnreported && changedTarget == nil && !metadataNeedsReview && !changedHead && ids.isEmpty && scope.changedNoteIDs.isEmpty
                    && previous.reviewedNoteRevisions != nil
                if onlyOwnOrRemoved {
                    parts.append("No other participant's note was added or edited since your review. Do not review again; confirm your verdict for the current discussions.")
                }
                let discussionChangeIsAuthorReply = staleReason == .discussionsChanged && !newReplies.isEmpty
                    && changedActiveNotes.allSatisfy { newReplies.contains($0) }
                if staleUnreported, !discussionChangeIsAuthorReply, !reasons.contains(staleReason) {
                    reasons.append(staleReason)
                }
                let context = parts.joined(separator: " ")
                events.append(observation.event(.reviewUpdate, token: token, context: context, noteIDs: ids,
                    reviewUpdateReasons: reasons))
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

    private func changedReviewTarget(_ request: GitLabMergeRequest, run: AssistantAutomationRunner.Handoff?,
                                     verdict: ReviewVerdict?, host: String, glab: GlabService) async -> ReviewTargetBinding? {
        guard let run, let head = request.sha, verdict?.headSHA == head,
              AssistantJobJournal.reviewVerdict(for: run) == verdict,
              let reviewed = AssistantJobJournal.targetForReviewUpdates(for: run) else { return nil }
        let live: GitLabMergeRequest?
        if ReviewTargetBinding(request) != nil { live = request }
        else { live = try? await glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host) }
        guard let live, live.isOpen, live.webURL == request.webURL,
              let current = ReviewTargetBinding(live), current.headSHA == head, current != reviewed else { return nil }
        return current
    }

    private func reviewCoverage(_ request: GitLabMergeRequest, discussions: [GitLabMergeRequestDiscussion]?,
                                account: Account, verdict: ReviewVerdict?) -> Bool? {
        guard let head = request.sha, let discussions, ReviewVerdict.fingerprint(discussions) != nil else { return nil }
        guard verdict?.requiresFreshReview(forSemanticContext: request.semanticContextFingerprint) != true else { return false }
        return verdict?.covers(head: head, discussions: discussions, reviewerID: account.userID,
                publishedDrafts: ReviewVerdictStore.seenDrafts(host: account.host, projectID: request.projectID,
                    iid: request.iid, in: verdictDirectory)) == true
    }

    private func staleReviewContext(_ request: GitLabMergeRequest,
                                   discussions: [GitLabMergeRequestDiscussion]?, glab: GlabService,
                                   account: Account, verdict: ReviewVerdict?, changedActiveNotes: [Int]) async -> String? {
        guard let head = request.sha, let discussions, let fingerprint = ReviewVerdict.fingerprint(discussions),
              let verdict, verdict.version == 1, verdict.headSHA == head,
              reviewCoverage(request, discussions: discussions, account: account, verdict: verdict) == false else { return nil }
        let metadataNeedsReview = verdict.requiresFreshReview(forSemanticContext: request.semanticContextFingerprint)
        let hasOwnOpenDiscussion = GitLabMergeRequestDiscussion.activeForReview(discussions).contains {
            $0.reviewRoot.map { $0.author?.id == account.userID && $0.resolvable == true } == true
        }
        guard metadataNeedsReview || !changedActiveNotes.isEmpty || !hasOwnOpenDiscussion,
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
