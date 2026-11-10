import Foundation
import Observation

struct AuthorFeedbackStatus: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable { case checking, complete, waitingPublication, failed }
    let head: String
    let fingerprint: String
    var semanticContextFingerprint: String? = nil
    var readOnlyReconciliation = false
    var phase: Phase
    var findings: [AuthorFeedbackPolicy.Finding] = []
    var codeReviewRequests: [ReReviewAssessment.CodeReviewRequest] = []
    var pendingDraftCount = 0
    var acceptedReviewerIDs: Set<Int> = []
    var followUpNoteIDs: Set<Int> = []
    var replyNoteIDs: Set<Int> = []
    var addressedNoteIDs: Set<Int> = []
    var ignoredNoteIDs: Set<Int> = []
    var failureReason: String? = nil
    var isReadOnlyFailure = false
    /// Exact stopped attempts observed before the current remote preflight; never persisted as worker success.
    var reconciledFollowUpJobIDs: Set<UUID> = []
    var reconciledBlockedContexts: [UUID: ReReviewVerifier.Input.BlockedFollowUp] = [:]
    /// Binds checking and failed attempts even when no successful assessment was cached.
    var completedFollowUpJobID: UUID? = nil
    var feedbackDecisionRevision = ""

    static func canReconcile(_ job: AssistantAutomationRunner.Handoff, request: GitLabMergeRequest) -> Bool {
        guard job.workflow == .followUp, job.pipelineReservation == nil, !job.allowsPush,
              let state = job.operationalExecution?.state, [.failed, .interrupted, .cancelled, .blocked].contains(state),
              let selected = job.feedbackNoteIDs, !selected.isEmpty, selected.allSatisfy({ $0 > 0 }),
              job.key.work.projectID == request.projectID, job.key.work.iid == request.iid,
              request.author.username == job.key.username, request.state == "opened",
              request.webURL.isGitLabMergeRequest(host: job.key.work.host, iid: request.iid) else { return false }
        return state != .blocked || (job.expectedHeadSHA == request.sha && job.draftRepair == nil
            && job.execution?.finishedAt != nil && blockedContext(for: job) != nil)
    }

    static func blockedContext(for job: AssistantAutomationRunner.Handoff) -> ReReviewVerifier.Input.BlockedFollowUp? {
        guard job.execution?.state == .blocked, let selected = job.feedbackNoteIDs,
              !selected.isEmpty, selected.count <= 12, Set(selected).count == selected.count,
              let blocker = job.execution?.blocker, !blocker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              blocker.count <= 600, let summary = job.execution?.summary, summary.count <= 2_000 else { return nil }
        return .init(runID: job.id, selectedFeedbackIDs: selected.sorted(), blocker: blocker, summary: summary)
    }

    func reconciles(_ job: AssistantAutomationRunner.Handoff, request: GitLabMergeRequest,
                    discussionFingerprint: String?) -> Bool {
        guard Self.canReconcile(job, request: request), reconciledFollowUpJobIDs.contains(job.id),
              phase == .complete || phase == .waitingPublication,
              head == request.sha, !head.isEmpty, fingerprint == discussionFingerprint,
              semanticContextFingerprint == request.semanticContextFingerprint else { return false }
        if job.execution?.state == .blocked {
            guard let context = Self.blockedContext(for: job), reconciledBlockedContexts[job.id] == context else { return false }
        }
        let selected = Set(job.feedbackNoteIDs ?? [])
        if !selected.isDisjoint(with: ignoredNoteIDs), job.execution?.state != .blocked { return false }
        return selected.isSubset(of: addressedNoteIDs.union(ignoredNoteIDs)) && selected.isDisjoint(with: followUpNoteIDs)
    }

    var needsAttention: Bool {
        phase == .failed || phase == .waitingPublication || !replyNoteIDs.isEmpty || !codeReviewRequests.isEmpty || findings.contains {
            [.needsChanges, .needsVerification].contains($0.state)
        }
    }
    var primaryFinding: AuthorFeedbackPolicy.Finding? {
        findings.first { $0.state == .needsChanges }
            ?? findings.first { $0.state == .needsVerification }
            ?? findings.first { replyNoteIDs.contains($0.id) }
    }
    var waitingForReviewer: Bool { findings.contains { $0.state == .waitingAcceptance } }
}

/// Verifier work is bounded, cached by source/text/policy, and independent of GUI chats.
@MainActor @Observable
final class AuthorFeedbackCoordinator {
    private(set) var statuses: [MRAutomationScope.Target: AuthorFeedbackStatus] = [:]
    @ObservationIgnored private var tasks: [MRAutomationScope.Target: Task<Void, Never>] = [:]
    @ObservationIgnored private var pending: [MRAutomationScope.Target: Input] = [:]
    @ObservationIgnored private var activeInputs: [MRAutomationScope.Target: Input] = [:]
    private struct AcknowledgementProgress {
        let userID: Int
        var threadRevisions: [Int: String] = [:]
        var reactions: Set<Int> = []
        var resolutions: Set<Int> = []
        var failures: [Int: String] = [:]
    }
    @ObservationIgnored private var acknowledgedReactions: [MRAutomationScope.Target: Set<String>] = [:]
    @ObservationIgnored private var acknowledgementAttempts: [MRAutomationScope.Target: AcknowledgementProgress] = [:]
    @ObservationIgnored private var cache: [MRAutomationScope.Target: (String, ReReviewAssessment, UUID?)] = [:]
    private let settings: SettingsManager
    private let glab: GlabService
    private let canAutomate: @MainActor (AutomationAssistant) async -> Bool
    private let verify: @MainActor (ReReviewVerifier.Input, AutomationAssistant, String) async throws -> ReReviewAssessment
    private let retryWait: ReadOnlyAssessmentRetry.Wait
    private let now: ReadOnlyAssessmentRetry.Clock
    private struct FailedRead {
        let date: Date
        let accountRevision: UInt64
        let configuration: AutomationSettings
    }
    @ObservationIgnored private var failedReads: [MRAutomationScope.Target: FailedRead] = [:]
    var onRemoteChange: (() -> Void)?
    var onNeedsWork: ((GitLabMergeRequest, Set<Int>, String, AuthorFeedbackResidual?) async -> Void)?

    private struct Input {
        let request: GitLabMergeRequest
        let discussions: [GitLabMergeRequestDiscussion]
        let user: GitLabAuthenticatedUser
        let target: MRAutomationScope.Target
        let configuration: AutomationSettings
        let fingerprint: String
        let drafts: Int
        let accountRevision: UInt64
        let completedFollowUpJobID: UUID?
        let decisionRevision: String
        let ignoredSuggestions: [IgnoredFeedbackSuggestion]
        var readOnly: Bool { drafts > 0 }
    }

    private struct Preparation {
        let assessment: ReReviewAssessment
        let threads: [GitLabMergeRequestDiscussion]
        let drafts: [GitLabDraftNote]
        let approvals: Set<Int>
        var stoppedFollowUps: [AssistantAutomationRunner.Handoff] = []
    }

    private struct ReadOnlyFailure: Error { let cause: any Error }

    init(settings: SettingsManager, glab: GlabService,
         canAutomate: @escaping @MainActor (AutomationAssistant) async -> Bool = { await AssistantCLI.detect($0, requireCLI: true).isReady },
         verify: @escaping @MainActor (ReReviewVerifier.Input, AutomationAssistant, String) async throws -> ReReviewAssessment = {
             try await ReReviewVerifier.verify($0, assistant: $1, model: $2)
         }, retryWait: @escaping ReadOnlyAssessmentRetry.Wait = ReadOnlyAssessmentRetry.wait,
         now: @escaping ReadOnlyAssessmentRetry.Clock = { Date() }) {
        self.settings = settings; self.glab = glab; self.canAutomate = canAutomate; self.verify = verify
        self.retryWait = retryWait
        self.now = now
    }

    func status(projectID: Int, iid: Int) -> AuthorFeedbackStatus? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return nil }
        return statuses[.init(host: host, username: username, projectID: projectID, iid: iid)]
    }

    func assessment(for request: GitLabMergeRequest, fingerprint: String) -> ReReviewAssessment? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername,
              let state = status(projectID: request.projectID, iid: request.iid),
              state.phase == .complete || state.phase == .waitingPublication,
              state.head == request.sha, state.fingerprint == fingerprint,
              state.semanticContextFingerprint == request.semanticContextFingerprint else { return nil }
        let target = MRAutomationScope.Target(host: host, username: username, projectID: request.projectID, iid: request.iid)
        guard state.feedbackDecisionRevision == settings.feedbackSuggestionDecisions.revision(for: target) else { return nil }
        guard let stored = cache[target], stored.2 == completedFollowUpJob(for: request, target: target)?.id else { return nil }
        return stored.1
    }

    func isChecking(for request: GitLabMergeRequest, fingerprint: String) -> Bool {
        guard let status = status(projectID: request.projectID, iid: request.iid) else { return false }
        return status.phase == .checking && status.head == request.sha && status.fingerprint == fingerprint
            && status.semanticContextFingerprint == request.semanticContextFingerprint
    }

    func refresh(request: GitLabMergeRequest, discussions: [GitLabMergeRequestDiscussion], drafts: Int,
                 host: String, user: GitLabAuthenticatedUser) {
        let target = MRAutomationScope.Target(host: host, username: user.username, projectID: request.projectID, iid: request.iid)
        let configuration = settings.automation
        let workflow = configuration.workflowRules[.newDiscussion]
        let followsFeedback = configuration.authorFeedback.isEnabled
            || (workflow.mode == .assistant && workflow.includes(request))
        guard request.author.id == user.id, request.state == "opened", request.draft != nil,
              configuration.autoResolveAcceptedFeedback || configuration.autoMergeEnabled || followsFeedback,
              settings.automation.packageDecision != .disabled,
              settings.automation.packageDecision == .enabled || settings.automation.usesAssistant
                || settings.automation.autoReReviewEnabled || settings.automation.autoMergeEnabled,
              settings.automation.scope.permits(request, host: host, username: user.username),
              let fingerprint = ReviewVerdict.fingerprint(discussions), let head = request.sha else { return }
        let hasFeedback = discussions.contains { $0.notes.contains { $0.system == false && $0.author?.id != user.id } }
        guard hasFeedback else { statuses.removeValue(forKey: target); return }
        let completedJobID = completedFollowUpJob(for: request, target: target)?.id
        let decisionRevision = settings.feedbackSuggestionDecisions.revision(for: target)
        if let status = statuses[target], status.head == head, status.fingerprint == fingerprint,
           status.semanticContextFingerprint == request.semanticContextFingerprint,
           status.feedbackDecisionRevision == decisionRevision,
           status.phase == .failed, status.completedFollowUpJobID == completedJobID {
            guard status.isReadOnlyFailure, let failure = failedReads[target],
                  failure.accountRevision != glab.accountRevision || failure.configuration != configuration
                    || now().timeIntervalSince(failure.date) >= ReadOnlyAssessmentRetry.cooldown else { return }
            statuses[target]?.phase = .checking
            statuses[target]?.isReadOnlyFailure = false
            statuses[target]?.failureReason = nil
        }
        let input = Input(request: request, discussions: discussions, user: user, target: target,
                          configuration: settings.automation, fingerprint: fingerprint, drafts: drafts,
                          accountRevision: glab.accountRevision,
                          completedFollowUpJobID: completedJobID, decisionRevision: decisionRevision,
                          ignoredSuggestions: settings.feedbackSuggestionDecisions.applicable(in: discussions, for: target))
        if statuses[target]?.head != head || statuses[target]?.fingerprint != fingerprint
            || statuses[target]?.semanticContextFingerprint != request.semanticContextFingerprint
            || statuses[target]?.feedbackDecisionRevision != decisionRevision
            || statuses[target]?.completedFollowUpJobID != completedJobID {
            statuses[target] = .init(head: head, fingerprint: fingerprint,
                semanticContextFingerprint: request.semanticContextFingerprint,
                readOnlyReconciliation: input.readOnly, phase: .checking, pendingDraftCount: drafts,
                completedFollowUpJobID: input.completedFollowUpJobID, feedbackDecisionRevision: decisionRevision)
        }
        pending[target] = input
        startNext()
    }

    func cancel(outsideScope: MRAutomationScope? = nil) {
        for target in Set(tasks.keys).union(pending.keys).union(statuses.keys).union(acknowledgementAttempts.keys).union(acknowledgedReactions.keys) {
            let permitted: Bool
            if let scope = outsideScope {
                if let request = pending[target]?.request ?? activeInputs[target]?.request {
                    permitted = scope.permits(request, host: target.host, username: target.username)
                } else { permitted = scope.resolve(target).active }
            } else { permitted = false }
            guard !permitted else { continue }
            pending.removeValue(forKey: target); tasks[target]?.cancel()
            statuses.removeValue(forKey: target); cache.removeValue(forKey: target)
            failedReads.removeValue(forKey: target)
            acknowledgementAttempts.removeValue(forKey: target)
            acknowledgedReactions.removeValue(forKey: target)
        }
    }

    func invalidate(projectID: Int, iid: Int) {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return }
        let target = MRAutomationScope.Target(host: host, username: username, projectID: projectID, iid: iid)
        pending.removeValue(forKey: target)
        tasks[target]?.cancel()
        cache.removeValue(forKey: target)
        acknowledgementAttempts.removeValue(forKey: target)
        acknowledgedReactions.removeValue(forKey: target)
        statuses.removeValue(forKey: target)
        failedReads.removeValue(forKey: target)
    }

    /// Dependency recovery reopens only evidence gathering, never a failed action.
    func retryReadOnlyFailures() {
        for (target, failure) in failedReads where target.host == glab.resolvedHost && target.username == glab.currentUsername {
            failedReads[target] = .init(date: .distantPast, accountRevision: failure.accountRevision,
                configuration: failure.configuration)
        }
    }

    private func startNext() {
        while tasks.count < 2, let (target, input) = pending.first(where: { tasks[$0.key] == nil }) {
            pending.removeValue(forKey: target)
            if statuses[target]?.head != input.request.sha || statuses[target]?.fingerprint != input.fingerprint
                || statuses[target]?.semanticContextFingerprint != input.request.semanticContextFingerprint
                || statuses[target]?.feedbackDecisionRevision != input.decisionRevision
                || statuses[target]?.completedFollowUpJobID != input.completedFollowUpJobID {
                statuses[target] = .init(head: input.request.sha ?? "", fingerprint: input.fingerprint,
                    semanticContextFingerprint: input.request.semanticContextFingerprint,
                    readOnlyReconciliation: input.readOnly, phase: .checking, pendingDraftCount: input.drafts,
                    completedFollowUpJobID: input.completedFollowUpJobID, feedbackDecisionRevision: input.decisionRevision)
            }
            activeInputs[target] = input
            tasks[target] = Task { [weak self] in
                guard let self else { return }
                defer { tasks.removeValue(forKey: target); activeInputs.removeValue(forKey: target); startNext() }
                do { try await process(input) }
                catch is CancellationError {
                    if !Task.isCancelled, isCurrent(input) {
                        statuses.removeValue(forKey: target)
                        onRemoteChange?()
                    }
                }
                catch {
                    if !Task.isCancelled, isCurrent(input) {
                        let readOnly = error as? ReadOnlyFailure
                        if readOnly != nil {
                            failedReads[target] = .init(date: now(), accountRevision: input.accountRevision, configuration: input.configuration)
                        } else { failedReads.removeValue(forKey: target) }
                        statuses[target] = .init(head: input.request.sha ?? "", fingerprint: input.fingerprint,
                            semanticContextFingerprint: input.request.semanticContextFingerprint, phase: .failed,
                            failureReason: String(GlabService.redactWorkflowEvidence(String(describing: readOnly?.cause ?? error)).prefix(600)),
                            isReadOnlyFailure: readOnly != nil, completedFollowUpJobID: input.completedFollowUpJobID,
                            feedbackDecisionRevision: input.decisionRevision)
                        // Refreshes queued during backoff cannot restart an exhausted snapshot's budget.
                        pending.removeValue(forKey: target)
                        Log.monitor.error("Author feedback verification failed: \(String(describing: error), privacy: .private)")
                    }
                }
            }
        }
    }

    private func isCurrent(_ input: Input) -> Bool {
        !Task.isCancelled && glab.resolvedHost == input.target.host && glab.currentUsername == input.user.username
            && glab.accountRevision == input.accountRevision
            && statuses[input.target]?.head == input.request.sha
            && statuses[input.target]?.fingerprint == input.fingerprint
            && statuses[input.target]?.semanticContextFingerprint == input.request.semanticContextFingerprint
            && statuses[input.target]?.completedFollowUpJobID == input.completedFollowUpJobID
            && statuses[input.target]?.feedbackDecisionRevision == input.decisionRevision
            && settings.feedbackSuggestionDecisions.revision(for: input.target) == input.decisionRevision
            && settings.automation == input.configuration
            && completedFollowUpJob(for: input.request, target: input.target)?.id == input.completedFollowUpJobID
            && settings.automation.packageDecision != .disabled
            && !settings.ignoredMergeRequests.contains(input.target)
            && settings.automation.scope.permits(input.request, host: input.target.host, username: input.user.username)
    }

    /// A successful worker can leave work outstanding. Its prior semantic verdict then
    /// predates the worker and cannot establish that the worker omitted remaining author work.
    private func completedFollowUpJob(for request: GitLabMergeRequest, target: MRAutomationScope.Target) -> AssistantAutomationRunner.Handoff? {
        settings.assistantHandoffs.filter {
            $0.key.work.host == target.host && $0.key.work.projectID == target.projectID
                && $0.key.work.iid == target.iid && $0.key.username == target.username
                && $0.workflow == .followUp && $0.draftRepair == nil
                && $0.execution?.state == .succeeded
                && $0.execution?.finishedAt != nil && !($0.feedbackNoteIDs ?? []).isEmpty
        }.max {
            let first = $0.execution?.finishedAt ?? $0.createdAt
            let second = $1.execution?.finishedAt ?? $1.createdAt
            return first == second ? $0.id.uuidString < $1.id.uuidString : first < second
        }
    }

    private func residual(_ input: Input, assessment: ReReviewAssessment, notes: Set<Int>) -> AuthorFeedbackResidual? {
        let runID = input.completedFollowUpJobID
        guard runID == nil || cache[input.target]?.2 == runID else { return nil }
        let requests = assessment.reviewRequests.filter { notes.contains($0.sourceNoteID) }
        let requestedIDs = Set(requests.map(\.sourceNoteID))
        let blocking = assessment.notes.filter {
            notes.contains($0.noteID) && ($0.state == .blocking || requestedIDs.contains($0.noteID))
                && !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !blocking.isEmpty, runID != nil || !requests.isEmpty else { return nil }
        return .init(assessedRunID: runID, notes: blocking,
            semanticContextFingerprint: input.request.semanticContextFingerprint, codeReviewRequests: requests)
    }

    func reviewContext(for request: GitLabMergeRequest, fingerprint: String) -> AuthorFeedbackResidual? {
        guard let assessment = assessment(for: request, fingerprint: fingerprint),
              let status = status(projectID: request.projectID, iid: request.iid),
              !assessment.reviewRequests.isEmpty else { return nil }
        let selected = Set(assessment.reviewRequests.map(\.sourceNoteID))
        return .init(assessedRunID: status.completedFollowUpJobID,
            notes: assessment.notes.filter { selected.contains($0.noteID) },
            semanticContextFingerprint: request.semanticContextFingerprint, codeReviewRequests: assessment.reviewRequests)
    }

    private func latestBlockedFollowUp(_ input: Input) -> AssistantAutomationRunner.Handoff? {
        let latest = settings.assistantHandoffs.filter {
            !$0.isObsoleteReminder && $0.key.work.host == input.target.host && $0.key.username == input.target.username
                && $0.key.work.projectID == input.target.projectID && $0.key.work.iid == input.target.iid
        }.max {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
        guard let latest, latest.execution?.state == .blocked,
              AuthorFeedbackStatus.canReconcile(latest, request: input.request) else { return nil }
        return latest
    }

    private func prepare(_ input: Input) async throws -> Preparation {
        guard isCurrent(input) else { throw CancellationError() }
        // Capture attempt identity before reading remote postconditions. A later run
        // cannot inherit proof produced for an earlier stopped attempt.
        var stoppedFollowUps = settings.assistantHandoffs.filter {
            $0.key.work.host == input.target.host && $0.key.username == input.target.username
                && $0.execution?.state != .blocked
                && AuthorFeedbackStatus.canReconcile($0, request: input.request)
        }
        if let blocked = latestBlockedFollowUp(input) { stoppedFollowUps.append(blocked) }
        let blockedContexts = stoppedFollowUps.compactMap { AuthorFeedbackStatus.blockedContext(for: $0) }
        guard await canAutomate(input.configuration.assistant) else { throw ReReviewVerifier.VerificationError.unavailable }
        guard isCurrent(input) else { throw CancellationError() }
        let request = input.request
        let host = input.target.host
        let diff: Data = try await glab.mergeRequestAPI("/projects/\(request.projectID)/merge_requests/\(request.iid)/raw_diffs", host: host, decode: { $0 })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let completedFollowUp = completedFollowUpJob(for: request, target: input.target).flatMap { job -> ReReviewVerifier.Input.CompletedFollowUp? in
            guard job.id == input.completedFollowUpJobID, let ids = job.feedbackNoteIDs,
                  let summary = job.execution?.summary, !summary.isEmpty else { return nil }
            return .init(runID: job.id, selectedFeedbackIDs: ids,
                summary: String(GlabService.redactWorkflowEvidence(summary).prefix(2_000)))
        }
        let key = ReReviewVerifier.policyVersion + "|" + (request.sha ?? "") + "|" + input.fingerprint + "|" + request.semanticContextFingerprint
            + "|" + UserAttentionSnapshot.digest(String(decoding: diff, as: UTF8.self))
            + "|" + (input.completedFollowUpJobID?.uuidString ?? "")
            + "|" + String(decoding: try encoder.encode(input.configuration), as: UTF8.self)
            + "|" + UserAttentionSnapshot.digest(String(decoding: try encoder.encode(blockedContexts), as: UTF8.self))
            + "|" + input.decisionRevision
            + "|" + String(decoding: try encoder.encode(completedFollowUp), as: UTF8.self)
        let assessment: ReReviewAssessment
        if let stored = cache[input.target], stored.0 == key { assessment = stored.1 }
        else {
            let model = input.configuration.assistant == .codex
                ? input.configuration.codexVerificationModel.rawValue : input.configuration.claudeVerificationModel.rawValue
            assessment = try await verify(.init(authorID: input.user.id, headSHA: request.sha ?? "", title: request.title,
                description: request.description,
                diff: String(decoding: diff, as: UTF8.self), discussions: input.discussions,
                target: .init(host: host, projectID: request.projectID, iid: request.iid,
                    url: request.webURL, expectedUsername: input.user.username),
                semanticContextFingerprint: request.semanticContextFingerprint,
                thinking: input.configuration.verificationThinking, blockedFollowUps: blockedContexts,
                ignoredSuggestions: input.ignoredSuggestions, completedFollowUp: completedFollowUp), input.configuration.assistant, model)
            _ = try assessment.reviewers(in: input.discussions, authorID: input.user.id, ignoredSuggestions: input.ignoredSuggestions)
            guard isCurrent(input) else { throw CancellationError() }
            cache[input.target] = (key, assessment, input.completedFollowUpJobID)
        }
        guard isCurrent(input) else { throw CancellationError() }
        let current = try await glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
        guard isCurrent(input), current.sha == request.sha,
              current.semanticContextFingerprint == request.semanticContextFingerprint,
              current.state == "opened", current.draft == request.draft, current.author.id == input.user.id,
              current.webURL == request.webURL else { throw CancellationError() }
        if input.readOnly || !stoppedFollowUps.isEmpty || !input.ignoredSuggestions.isEmpty {
            async let liveThreads = glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
            async let liveUser = glab.fetchAuthenticatedUser(host: host, expectedUsername: input.user.username)
            async let liveDrafts = glab.fetchOwnDraftNotes(projectID: request.projectID, iid: request.iid, host: host, userID: input.user.id)
            let (threads, user, drafts) = try await (liveThreads, liveUser, liveDrafts)
            guard isCurrent(input), user == input.user, drafts.count == input.drafts,
                  ReviewVerdict.fingerprint(threads) == input.fingerprint else { throw CancellationError() }
            let approvals = input.readOnly ? [] : try await glab.fetchMergeRequestApproverIDs(
                projectID: request.projectID, iid: request.iid, host: host)
            guard isCurrent(input) else { throw CancellationError() }
            return Preparation(assessment: assessment, threads: threads, drafts: drafts, approvals: approvals,
                stoppedFollowUps: stoppedFollowUps)
        }
        let approvals = try await glab.fetchMergeRequestApproverIDs(projectID: request.projectID, iid: request.iid, host: host)
        guard isCurrent(input) else { throw CancellationError() }
        return Preparation(assessment: assessment, threads: input.discussions, drafts: [], approvals: approvals)
    }

    private func process(_ input: Input) async throws {
        let prepared: Preparation
        do {
            prepared = try await ReadOnlyAssessmentRetry.run(isCurrent: { self.isCurrent(input) }, wait: retryWait, onRetry: {
                self.statuses[input.target]?.phase = .checking
                self.statuses[input.target]?.readOnlyReconciliation = input.readOnly
                self.statuses[input.target]?.failureReason = nil
                self.statuses[input.target]?.isReadOnlyFailure = false
            }) { try await self.prepare(input) }
        } catch is CancellationError { throw CancellationError() }
        catch { throw ReadOnlyFailure(cause: error) }
        failedReads.removeValue(forKey: input.target)
        // No executable follow-up, reaction or resolution is inside the retry boundary.
        let request = input.request
        let host = input.target.host
        let assessment = prepared.assessment
        if input.readOnly {
            let threads = prepared.threads
            let drafts = prepared.drafts
            let repliesByThread = assessment.missingPublishedRepliesByThread(in: threads, authorID: input.user.id)
            let owedNotes = Set(repliesByThread.values.flatMap { $0 })
            let draftedThreads = Set(drafts.compactMap(\.discussionID))
            let draftedNotes = Set(threads.filter { $0.id.map(draftedThreads.contains) == true }.flatMap(\.notes).compactMap(\.id))
            let actionable = Set(assessment.notes.filter { $0.state == .blocking || $0.state == .uncertain }.map(\.noteID))
                .union(assessment.reviewRequests.map(\.sourceNoteID))
            let followUp = settings.automation.scope.permits(request, host: host, username: input.user.username)
                ? actionable.union(owedNotes).subtracting(draftedNotes) : []
            if settings.automaticActionsAllowed, !followUp.isEmpty { await onNeedsWork?(request, followUp, input.fingerprint,
                residual(input, assessment: assessment, notes: followUp)) }
            guard isCurrent(input) else { throw CancellationError() }
            var completed = AuthorFeedbackStatus(head: request.sha ?? "", fingerprint: input.fingerprint,
                semanticContextFingerprint: request.semanticContextFingerprint,
                phase: drafts.isEmpty ? .complete : .waitingPublication, pendingDraftCount: drafts.count,
                followUpNoteIDs: followUp,
                replyNoteIDs: Set(repliesByThread.keys),
                addressedNoteIDs: Set(assessment.notes.filter { $0.state == .addressed || $0.state == .informational }.map(\.noteID)).subtracting(owedNotes),
                completedFollowUpJobID: input.completedFollowUpJobID)
            completed.feedbackDecisionRevision = input.decisionRevision
            completed.codeReviewRequests = assessment.reviewRequests
            completed.ignoredNoteIDs = Set(assessment.notes.filter { $0.state == .ignoredByUser }.map(\.noteID))
            bindStoppedFollowUpEvidence(to: &completed, prepared: prepared, discussions: threads, authorID: input.user.id)
            let changed = statuses[input.target] != completed
            statuses[input.target] = completed
            if changed { onRemoteChange?() }
            return
        }
        var approved = prepared.approvals
        var threads = prepared.threads
        let initial = AuthorFeedbackPolicy.evaluate(discussions: threads, assessment: assessment, authorID: input.user.id,
            approvedReviewerIDs: approved, enabled: input.configuration.autoResolveAcceptedFeedback, ignoredSuggestions: input.ignoredSuggestions)
        var accepted: Set<Int> = []
        var changed = false
        let informationalThreads = Set(AuthorFeedbackPolicy.informationalAcknowledgements(discussions: threads,
            assessment: assessment, authorID: input.user.id, ignoredSuggestions: input.ignoredSuggestions).filter(\.canResolve).compactMap(\.discussionID))
        for finding in initial where finding.canResolve && !informationalThreads.contains(finding.discussionID ?? "") {
            guard settings.automaticActionsAllowed else { break }
            guard isCurrent(input) else { throw CancellationError() }
            guard await canAutomate(input.configuration.assistant) else { throw ReReviewVerifier.VerificationError.unavailable }
            guard settings.automaticActionsAllowed else { break }
            guard isCurrent(input), let discussionID = finding.discussionID else { throw CancellationError() }
            async let currentMR = glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
            async let currentThreads = glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
            async let currentUser = glab.fetchAuthenticatedUser(host: host, expectedUsername: input.user.username)
            async let drafts = glab.fetchOwnDraftNoteCount(projectID: request.projectID, iid: request.iid, host: host, userID: input.user.id)
            async let approvals = glab.fetchMergeRequestApproverIDs(projectID: request.projectID, iid: request.iid, host: host)
            let (live, discussions, user, count, liveApproved) = try await (currentMR, currentThreads, currentUser, drafts, approvals)
            approved = liveApproved
            guard settings.automaticActionsAllowed else { break }
            guard isCurrent(input), live.sha == request.sha, live.state == "opened",
                  live.semanticContextFingerprint == request.semanticContextFingerprint,
                  live.author.id == input.user.id, user == input.user, count == 0,
                  settings.automation.scope.permits(live, host: host, username: user.username),
                  live.webURL == request.webURL, ReviewVerdict.fingerprint(discussions) == input.fingerprint else { throw CancellationError() }
            threads = discussions
            let permitted = AuthorFeedbackPolicy.evaluate(discussions: discussions, assessment: assessment, authorID: user.id,
                approvedReviewerIDs: liveApproved, ignoredSuggestions: input.ignoredSuggestions).contains { $0.discussionID == discussionID && $0.canResolve }
            guard permitted, !settings.pendingCommentReviews.contains(input.target) else { continue }
            try await glab.resolveAcceptedDiscussion(projectID: request.projectID, iid: request.iid, discussionID: discussionID, host: host)
            changed = true
            accepted.insert(finding.reviewerID)
            threads = try await glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
            let confirmed = try await glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
            guard isCurrent(input), confirmed.sha == request.sha,
                  confirmed.semanticContextFingerprint == request.semanticContextFingerprint,
                  settings.automation.scope.permits(confirmed, host: host, username: input.user.username),
                  ReviewVerdict.fingerprint(threads) == input.fingerprint else { throw CancellationError() }
        }
        guard isCurrent(input) else { throw CancellationError() }
        var findings = AuthorFeedbackPolicy.evaluate(discussions: threads, assessment: assessment, authorID: input.user.id,
            approvedReviewerIDs: approved, enabled: input.configuration.autoResolveAcceptedFeedback, ignoredSuggestions: input.ignoredSuggestions)
        accepted.formUnion(AuthorFeedbackPolicy.acceptedReviewers(discussions: threads, assessment: assessment,
            authorID: input.user.id, approvedReviewerIDs: approved, ignoredSuggestions: input.ignoredSuggestions))
        let allNotes: [GitLabMergeRequestDiscussion.Note] = threads.flatMap(\.notes)
        let outstandingNotes = allNotes.filter {
            $0.system == false && $0.author?.id != input.user.id
        }
        let outstanding: Set<Int> = Set(outstandingNotes.compactMap(\.id))
        var followUp = Set(assessment.notes.filter {
            outstanding.contains($0.noteID) && ($0.state == .blocking || $0.state == .uncertain)
        }.map(\.noteID))
        followUp.formUnion(assessment.reviewRequests.map(\.sourceNoteID))
        let repliesByThread = assessment.missingPublishedRepliesByThread(in: threads, authorID: input.user.id)
        // An owed published reply remains work even when approval or a disabled
        // resolution policy changes the finding's presentation state.
        let missingReplies = Set(repliesByThread.keys)
        let owedNotes = missingReplies.reduce(into: Set<Int>()) { notes, rootID in
            notes.formUnion(repliesByThread[rootID] ?? [])
        }
        followUp.formUnion(owedNotes)
        if settings.automaticActionsAllowed, !followUp.isEmpty, isCurrent(input) { await onNeedsWork?(request, followUp, input.fingerprint,
            residual(input, assessment: assessment, notes: followUp)) }
        guard isCurrent(input) else { throw CancellationError() }
        // Courtesy acknowledgement is optional and must never suppress independent correction work.
        let acknowledgement = try await acknowledgeInformational(input, assessment: assessment, discussions: threads)
        threads = acknowledgement.threads
        changed = changed || acknowledgement.changed
        let acknowledgementFailures = acknowledgementAttempts[input.target]?.failures ?? [:]
        findings = AuthorFeedbackPolicy.evaluate(discussions: threads, assessment: assessment, authorID: input.user.id,
            approvedReviewerIDs: approved, enabled: input.configuration.autoResolveAcceptedFeedback, ignoredSuggestions: input.ignoredSuggestions).map { finding in
                guard finding.state == .ready, let reason = acknowledgementFailures[finding.id] else { return finding }
                return .init(id: finding.id, discussionID: finding.discussionID, reviewerID: finding.reviewerID,
                    reviewerUsername: finding.reviewerUsername, state: .needsVerification, reason: reason,
                    waitingForReviewers: [])
            }
        var completed = AuthorFeedbackStatus(head: request.sha ?? "", fingerprint: input.fingerprint,
            semanticContextFingerprint: request.semanticContextFingerprint, phase: .complete,
            findings: findings, codeReviewRequests: assessment.reviewRequests,
            acceptedReviewerIDs: accepted, followUpNoteIDs: followUp, replyNoteIDs: missingReplies,
            addressedNoteIDs: Set(assessment.notes.filter { $0.state == .addressed || $0.state == .informational }.map(\.noteID))
                .subtracting(owedNotes).subtracting(acknowledgementFailures.keys),
            completedFollowUpJobID: input.completedFollowUpJobID)
        completed.feedbackDecisionRevision = input.decisionRevision
        completed.ignoredNoteIDs = Set(assessment.notes.filter { $0.state == .ignoredByUser }.map(\.noteID))
        bindStoppedFollowUpEvidence(to: &completed, prepared: prepared, discussions: threads, authorID: input.user.id)
        let updated = statuses[input.target] != completed
        statuses[input.target] = completed
        if changed || updated { onRemoteChange?() }
    }

    private func bindStoppedFollowUpEvidence(to status: inout AuthorFeedbackStatus, prepared: Preparation,
                                            discussions: [GitLabMergeRequestDiscussion], authorID: Int) {
        let missingReplies = prepared.assessment.missingPublishedReplyNoteIDs(in: discussions, authorID: authorID)
        for candidate in prepared.stoppedFollowUps {
            guard let current = settings.assistantHandoffs.first(where: { $0.id == candidate.id }),
                  current.key == candidate.key, current.workflow == candidate.workflow,
                  current.execution?.state == candidate.execution?.state,
                  current.feedbackNoteIDs == candidate.feedbackNoteIDs,
                  current.pipelineReservation == nil, candidate.pipelineReservation == nil,
                  current.allowsPush == candidate.allowsPush,
                  current.expectedHeadSHA == candidate.expectedHeadSHA else { continue }
            let selected = Set(candidate.feedbackNoteIDs ?? [])
            guard selected.isSubset(of: status.addressedNoteIDs.union(status.ignoredNoteIDs)), selected.isDisjoint(with: status.followUpNoteIDs),
                  selected.isDisjoint(with: missingReplies) else { continue }
            if !selected.isDisjoint(with: status.ignoredNoteIDs), candidate.execution?.state != .blocked { continue }
            if candidate.execution?.state == .blocked {
                let addressed = Set(prepared.assessment.notes.filter { $0.state == .addressed || $0.state == .ignoredByUser }.map(\.noteID))
                guard prepared.assessment.completedBlockedRunIDs?.contains(candidate.id) == true,
                      let context = AuthorFeedbackStatus.blockedContext(for: candidate),
                      AuthorFeedbackStatus.blockedContext(for: current) == context,
                      selected.isSubset(of: addressed) else { continue }
                status.reconciledBlockedContexts[candidate.id] = context
            }
            status.reconciledFollowUpJobIDs.insert(candidate.id)
        }
    }

    private func liveInformationalDiscussions(_ input: Input) async throws -> [GitLabMergeRequestDiscussion] {
        guard settings.automaticActionsAllowed, isCurrent(input), !input.readOnly,
              input.configuration.autoResolveAcceptedFeedback else { throw CancellationError() }
        let request = input.request
        let host = input.target.host
        async let currentMR = glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
        async let currentThreads = glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
        async let currentUser = glab.fetchAuthenticatedUser(host: host, expectedUsername: input.user.username)
        async let currentDrafts = glab.fetchOwnDraftNoteCount(projectID: request.projectID, iid: request.iid, host: host, userID: input.user.id)
        let (live, discussions, user, count) = try await (currentMR, currentThreads, currentUser, currentDrafts)
        guard settings.automaticActionsAllowed, isCurrent(input), live.sha == request.sha, live.state == "opened",
              live.semanticContextFingerprint == request.semanticContextFingerprint,
              live.author.id == input.user.id, user == input.user, count == 0, live.webURL == request.webURL,
              settings.automation.scope.permits(live, host: host, username: user.username),
              ReviewVerdict.fingerprint(discussions) == input.fingerprint else { throw CancellationError() }
        return discussions
    }

    private func acknowledgeInformational(_ input: Input, assessment: ReReviewAssessment,
                                          discussions: [GitLabMergeRequestDiscussion]) async throws
        -> (threads: [GitLabMergeRequestDiscussion], changed: Bool) {
        guard settings.automaticActionsAllowed, input.configuration.autoResolveAcceptedFeedback else { return (discussions, false) }
        let candidates = AuthorFeedbackPolicy.informationalAcknowledgements(discussions: discussions,
            assessment: assessment, authorID: input.user.id, ignoredSuggestions: input.ignoredSuggestions)
        if acknowledgementAttempts[input.target]?.userID != input.user.id {
            acknowledgementAttempts[input.target] = .init(userID: input.user.id)
            acknowledgedReactions.removeValue(forKey: input.target)
        }
        for discussion in discussions where discussion.notes.first?.resolved == true {
            if let rootID = discussion.notes.first?.id { acknowledgementAttempts[input.target]?.failures.removeValue(forKey: rootID) }
        }
        var threads = discussions
        var changed = false
        var freshCandidates = 0
        var accountKinds: [Int: AuthorFeedbackPolicy.AccountKind] = [:]
        let verdicts = Dictionary(uniqueKeysWithValues: assessment.notes.map { ($0.noteID, $0) })
        for candidate in candidates {
            guard let rootID = candidate.noteIDs.first,
                  let thread = discussions.first(where: { $0.id == candidate.discussionID && $0.notes.contains(where: { $0.id == rootID }) }),
                  let fingerprint = ReviewVerdict.fingerprint([thread]) else { continue }
            let threadRevision = AICommentAssessmentStore.digest("\(candidate.discussionID ?? "")|\(fingerprint)")
            if acknowledgementAttempts[input.target]?.threadRevisions[rootID] != threadRevision {
                acknowledgementAttempts[input.target]?.threadRevisions[rootID] = threadRevision
                acknowledgementAttempts[input.target]?.reactions.subtract(candidate.noteIDs)
                acknowledgementAttempts[input.target]?.resolutions.remove(rootID)
                acknowledgementAttempts[input.target]?.failures.removeValue(forKey: rootID)
            }
            let reactionKeys = Dictionary(uniqueKeysWithValues: candidate.noteIDs.map {
                ($0, AICommentAssessmentStore.digest("\(candidate.discussionID ?? "")|\($0)|\(fingerprint)"))
            })
            let pendingReactions = candidate.noteIDs.filter { noteID in
                acknowledgementAttempts[input.target]?.reactions.contains(noteID) != true
                    && reactionKeys[noteID].map { acknowledgedReactions[input.target]?.contains($0) != true } == true
            }
            let pendingResolution = candidate.canResolve && acknowledgementAttempts[input.target]?.resolutions.contains(rootID) != true
            guard !pendingReactions.isEmpty || pendingResolution else { continue }
            // Cached and fenced history consumes no budget, so later notes progress on the next pass.
            guard freshCandidates < 4 else { break }
            freshCandidates += 1
            do {
                guard isCurrent(input) else { throw CancellationError() }
                guard await canAutomate(input.configuration.assistant) else { throw ReReviewVerifier.VerificationError.unavailable }
                func currentCandidate(_ current: [GitLabMergeRequestDiscussion]) -> AuthorFeedbackPolicy.InformationalAcknowledgement? {
                    AuthorFeedbackPolicy.informationalAcknowledgements(discussions: current, assessment: assessment,
                        authorID: input.user.id, ignoredSuggestions: input.ignoredSuggestions).first { $0.discussionID == candidate.discussionID && $0.noteIDs == candidate.noteIDs }
                }
                for noteID in pendingReactions {
                    acknowledgementAttempts[input.target]?.reactions.insert(noteID)
                    do {
                        guard let reviewerID = thread.notes.first(where: { $0.id == noteID })?.author?.id,
                              let verdict = verdicts[noteID] else { continue }
                        let kind: AuthorFeedbackPolicy.AccountKind
                        if let cached = accountKinds[reviewerID] { kind = cached }
                        else {
                            kind = try await glab.feedbackAccountKind(userID: reviewerID, host: input.target.host)
                            accountKinds[reviewerID] = kind
                        }
                        guard AuthorFeedbackPolicy.permitsInformationalReaction(verdict, accountKind: kind) else { continue }
                        let exists = try await glab.hasOwnThumbsUp(projectID: input.request.projectID, iid: input.request.iid,
                            noteID: noteID, host: input.target.host, userID: input.user.id)
                        if !exists {
                            threads = try await liveInformationalDiscussions(input)
                            guard currentCandidate(threads) != nil else { throw CancellationError() }
                            try await glab.addOwnThumbsUp(projectID: input.request.projectID, iid: input.request.iid,
                                noteID: noteID, host: input.target.host, userID: input.user.id)
                            changed = true
                        }
                        if let key = reactionKeys[noteID] { acknowledgedReactions[input.target, default: []].insert(key) }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        Log.monitor.error("Informational feedback reaction failed for note \(noteID): \(String(describing: error), privacy: .private)")
                    }
                }
                guard pendingResolution else { continue }
                threads = try await liveInformationalDiscussions(input)
                guard let liveCandidate = currentCandidate(threads) else {
                    if threads.contains(where: { $0.id == candidate.discussionID && $0.notes.first?.resolved == true }) {
                        acknowledgementAttempts[input.target]?.failures.removeValue(forKey: rootID)
                        continue
                    }
                    throw CancellationError()
                }
                guard liveCandidate.canResolve, let discussionID = liveCandidate.discussionID,
                      !settings.pendingCommentReviews.contains(input.target) else { continue }
                acknowledgementAttempts[input.target]?.resolutions.insert(rootID)
                // A fresh read reconciles lost responses before a fenced failure reaches the UI.
                acknowledgementAttempts[input.target]?.failures[rootID] = String(describing:
                    GlabError.decoding("GitLab did not confirm discussion resolution"))
                do {
                    let resolved = try await glab.resolveAcceptedDiscussion(projectID: input.request.projectID, iid: input.request.iid,
                        discussionID: discussionID, host: input.target.host)
                    acknowledgementAttempts[input.target]?.failures.removeValue(forKey: rootID)
                    if let index = threads.firstIndex(where: { $0.id == discussionID }) { threads[index] = resolved }
                    guard ReviewVerdict.fingerprint(threads) == input.fingerprint else { throw CancellationError() }
                    changed = true
                } catch is CancellationError { throw CancellationError() }
                catch {
                    acknowledgementAttempts[input.target]?.failures[rootID] = String(
                        GlabService.redactWorkflowEvidence(String(describing: error)).prefix(600))
                    Log.monitor.error("Informational feedback resolution failed for note \(rootID): \(String(describing: error), privacy: .private)")
                }
                threads = try await liveInformationalDiscussions(input)
                if threads.contains(where: { $0.id == discussionID && $0.notes.first?.resolved == true }) {
                    acknowledgementAttempts[input.target]?.failures.removeValue(forKey: rootID)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                Log.monitor.error("Informational feedback verification failed for note \(rootID): \(String(describing: error), privacy: .private)")
            }
        }
        return (threads, changed)
    }

}

extension GlabService {
    func fetchMergeRequestApproverIDs(projectID: Int, iid: Int, host: String) async throws -> Set<Int> {
        struct Approvals: Decodable {
            struct Entry: Decodable { let user: GitLabWorkflowUser }
            let approvedBy: [Entry]
            enum CodingKeys: String, CodingKey { case approvedBy = "approved_by" }
        }
        let approvals: Approvals = try await mergeRequestAPI("/projects/\(projectID)/merge_requests/\(iid)/approvals", host: host)
        return Set(approvals.approvedBy.map(\.user.id).filter { $0 > 0 })
    }

    @discardableResult
    func resolveAcceptedDiscussion(projectID: Int, iid: Int, discussionID: String, host: String) async throws -> GitLabMergeRequestDiscussion {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard !discussionID.isEmpty, let encoded = discussionID.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw GlabError.decoding("Missing discussion identity")
        }
        let result: GitLabMergeRequestDiscussion = try await mergeRequestAPI(
            "/projects/\(projectID)/merge_requests/\(iid)/discussions/\(encoded)", host: host,
            arguments: ["--method", "PUT", "--field", "resolved=true"])
        guard result.id == discussionID, !result.notes.isEmpty,
              result.notes.allSatisfy({ $0.resolvable != true || $0.resolved == true }) else {
            throw GlabError.decoding("GitLab did not confirm discussion resolution")
        }
        return result
    }
}
