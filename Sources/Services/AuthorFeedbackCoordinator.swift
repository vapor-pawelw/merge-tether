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
    var pendingDraftCount = 0
    var acceptedReviewerIDs: Set<Int> = []
    var followUpNoteIDs: Set<Int> = []
    var replyNoteIDs: Set<Int> = []
    var addressedNoteIDs: Set<Int> = []
    var failureReason: String? = nil
    var isReadOnlyFailure = false

    var needsAttention: Bool {
        phase == .failed || phase == .waitingPublication || !replyNoteIDs.isEmpty || findings.contains {
            [.needsChanges, .needsVerification].contains($0.state)
        }
    }
    var waitingForReviewer: Bool { findings.contains { $0.state == .waitingAcceptance } }
}

/// Verifier work is bounded, cached by source/text/policy, and independent of GUI chats.
@MainActor @Observable
final class AuthorFeedbackCoordinator {
    private(set) var statuses: [MRAutomationScope.Target: AuthorFeedbackStatus] = [:]
    @ObservationIgnored private var tasks: [MRAutomationScope.Target: Task<Void, Never>] = [:]
    @ObservationIgnored private var pending: [MRAutomationScope.Target: Input] = [:]
    private struct AcknowledgementProgress {
        let userID: Int
        var threadRevisions: [Int: String] = [:]
        var reactions: Set<Int> = []
        var resolutions: Set<Int> = []
        var failures: [Int: String] = [:]
    }
    @ObservationIgnored private var acknowledgedReactions: [MRAutomationScope.Target: Set<String>] = [:]
    @ObservationIgnored private var acknowledgementAttempts: [MRAutomationScope.Target: AcknowledgementProgress] = [:]
    @ObservationIgnored private var cache: [MRAutomationScope.Target: (String, ReReviewAssessment)] = [:]
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
    var onNeedsWork: ((GitLabMergeRequest, Set<Int>, String) async -> Void)?

    private struct Input {
        let request: GitLabMergeRequest
        let discussions: [GitLabMergeRequestDiscussion]
        let user: GitLabAuthenticatedUser
        let target: MRAutomationScope.Target
        let configuration: AutomationSettings
        let fingerprint: String
        let drafts: Int
        let accountRevision: UInt64
        var readOnly: Bool { request.draft == true || drafts > 0 }
    }

    private struct Preparation {
        let assessment: ReReviewAssessment
        let threads: [GitLabMergeRequestDiscussion]
        let drafts: [GitLabDraftNote]
        let approvals: Set<Int>
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
        return cache[.init(host: host, username: username, projectID: request.projectID, iid: request.iid)]?.1
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
        if let status = statuses[target], status.head == head, status.fingerprint == fingerprint,
           status.semanticContextFingerprint == request.semanticContextFingerprint,
           status.phase == .failed {
            guard status.isReadOnlyFailure, let failure = failedReads[target],
                  failure.accountRevision != glab.accountRevision || failure.configuration != configuration
                    || now().timeIntervalSince(failure.date) >= ReadOnlyAssessmentRetry.cooldown else { return }
            statuses[target]?.phase = .checking
            statuses[target]?.isReadOnlyFailure = false
            statuses[target]?.failureReason = nil
        }
        let input = Input(request: request, discussions: discussions, user: user, target: target,
                          configuration: settings.automation, fingerprint: fingerprint, drafts: drafts,
                          accountRevision: glab.accountRevision)
        if statuses[target]?.head != head || statuses[target]?.fingerprint != fingerprint
            || statuses[target]?.semanticContextFingerprint != request.semanticContextFingerprint {
            statuses[target] = .init(head: head, fingerprint: fingerprint,
                semanticContextFingerprint: request.semanticContextFingerprint,
                readOnlyReconciliation: input.readOnly, phase: .checking, pendingDraftCount: drafts)
        }
        pending[target] = input
        startNext()
    }

    func cancel(outsideScope: MRAutomationScope? = nil) {
        for target in Set(tasks.keys).union(pending.keys).union(statuses.keys).union(acknowledgementAttempts.keys).union(acknowledgedReactions.keys) {
            guard outsideScope.map({ !$0.resolve(target).active }) ?? true else { continue }
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
                || statuses[target]?.semanticContextFingerprint != input.request.semanticContextFingerprint {
                statuses[target] = .init(head: input.request.sha ?? "", fingerprint: input.fingerprint,
                    semanticContextFingerprint: input.request.semanticContextFingerprint,
                    readOnlyReconciliation: input.readOnly, phase: .checking, pendingDraftCount: input.drafts)
            }
            tasks[target] = Task { [weak self] in
                guard let self else { return }
                defer { tasks.removeValue(forKey: target); startNext() }
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
                            isReadOnlyFailure: readOnly != nil)
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
            && settings.automation == input.configuration
            && settings.automation.packageDecision != .disabled
            && !settings.ignoredMergeRequests.contains(input.target)
            && settings.automation.scope.permits(input.request, host: input.target.host, username: input.user.username)
    }

    private func prepare(_ input: Input) async throws -> Preparation {
        guard isCurrent(input) else { throw CancellationError() }
        guard await canAutomate(input.configuration.assistant) else { throw ReReviewVerifier.VerificationError.unavailable }
        guard isCurrent(input) else { throw CancellationError() }
        let request = input.request
        let host = input.target.host
        let diff: Data = try await glab.mergeRequestAPI("/projects/\(request.projectID)/merge_requests/\(request.iid)/raw_diffs", host: host, decode: { $0 })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let key = (request.sha ?? "") + "|" + input.fingerprint + "|" + request.semanticContextFingerprint
            + "|" + UserAttentionSnapshot.digest(String(decoding: diff, as: UTF8.self))
            + "|" + String(decoding: try encoder.encode(input.configuration), as: UTF8.self)
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
                semanticContextFingerprint: request.semanticContextFingerprint), input.configuration.assistant, model)
            _ = try assessment.reviewers(in: input.discussions, authorID: input.user.id)
            guard isCurrent(input) else { throw CancellationError() }
            cache[input.target] = (key, assessment)
        }
        guard isCurrent(input) else { throw CancellationError() }
        let current = try await glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
        guard isCurrent(input), current.sha == request.sha,
              current.semanticContextFingerprint == request.semanticContextFingerprint,
              current.state == "opened", current.draft == request.draft, current.author.id == input.user.id,
              current.webURL == request.webURL else { throw CancellationError() }
        if input.readOnly {
            async let liveThreads = glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
            async let liveUser = glab.fetchAuthenticatedUser(host: host, expectedUsername: input.user.username)
            async let liveDrafts = glab.fetchOwnDraftNotes(projectID: request.projectID, iid: request.iid, host: host, userID: input.user.id)
            let (threads, user, drafts) = try await (liveThreads, liveUser, liveDrafts)
            guard isCurrent(input), user == input.user, drafts.count == input.drafts,
                  ReviewVerdict.fingerprint(threads) == input.fingerprint else { throw CancellationError() }
            return Preparation(assessment: assessment, threads: threads, drafts: drafts, approvals: [])
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
            let followUp = request.draft == false ? actionable.union(owedNotes).subtracting(draftedNotes) : []
            if !followUp.isEmpty { await onNeedsWork?(request, followUp, input.fingerprint) }
            guard isCurrent(input) else { throw CancellationError() }
            let completed = AuthorFeedbackStatus(head: request.sha ?? "", fingerprint: input.fingerprint,
                semanticContextFingerprint: request.semanticContextFingerprint,
                phase: drafts.isEmpty ? .complete : .waitingPublication, pendingDraftCount: drafts.count,
                followUpNoteIDs: followUp,
                replyNoteIDs: Set(repliesByThread.keys),
                addressedNoteIDs: Set(assessment.notes.filter { $0.state == .addressed || $0.state == .informational }.map(\.noteID)).subtracting(owedNotes))
            let changed = statuses[input.target] != completed
            statuses[input.target] = completed
            if changed { onRemoteChange?() }
            return
        }
        var approved = prepared.approvals
        var threads = input.discussions
        let initial = AuthorFeedbackPolicy.evaluate(discussions: threads, assessment: assessment, authorID: input.user.id,
            approvedReviewerIDs: approved, enabled: input.configuration.autoResolveAcceptedFeedback)
        var accepted: Set<Int> = []
        var changed = false
        let informationalThreads = Set(AuthorFeedbackPolicy.informationalAcknowledgements(discussions: threads,
            assessment: assessment, authorID: input.user.id).filter(\.canResolve).compactMap(\.discussionID))
        for finding in initial where finding.canResolve && !informationalThreads.contains(finding.discussionID ?? "") {
            guard isCurrent(input) else { throw CancellationError() }
            guard await canAutomate(input.configuration.assistant) else { throw ReReviewVerifier.VerificationError.unavailable }
            guard isCurrent(input), let discussionID = finding.discussionID else { throw CancellationError() }
            async let currentMR = glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
            async let currentThreads = glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
            async let currentUser = glab.fetchAuthenticatedUser(host: host, expectedUsername: input.user.username)
            async let drafts = glab.fetchOwnDraftNoteCount(projectID: request.projectID, iid: request.iid, host: host, userID: input.user.id)
            async let approvals = glab.fetchMergeRequestApproverIDs(projectID: request.projectID, iid: request.iid, host: host)
            let (live, discussions, user, count, liveApproved) = try await (currentMR, currentThreads, currentUser, drafts, approvals)
            approved = liveApproved
            guard isCurrent(input), live.sha == request.sha, live.state == "opened", live.draft == false,
                  live.semanticContextFingerprint == request.semanticContextFingerprint,
                  live.author.id == input.user.id, user == input.user, count == 0,
                  settings.automation.scope.permits(live, host: host, username: user.username),
                  live.webURL == request.webURL, ReviewVerdict.fingerprint(discussions) == input.fingerprint else { throw CancellationError() }
            threads = discussions
            let permitted = AuthorFeedbackPolicy.evaluate(discussions: discussions, assessment: assessment, authorID: user.id,
                approvedReviewerIDs: liveApproved).contains { $0.discussionID == discussionID && $0.canResolve }
            guard permitted else { continue }
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
            approvedReviewerIDs: approved, enabled: input.configuration.autoResolveAcceptedFeedback)
        accepted.formUnion(AuthorFeedbackPolicy.acceptedReviewers(discussions: threads, assessment: assessment,
            authorID: input.user.id, approvedReviewerIDs: approved))
        let allNotes: [GitLabMergeRequestDiscussion.Note] = threads.flatMap(\.notes)
        let outstandingNotes = allNotes.filter {
            $0.system == false && $0.author?.id != input.user.id
        }
        let outstanding: Set<Int> = Set(outstandingNotes.compactMap(\.id))
        var followUp = Set(assessment.notes.filter {
            outstanding.contains($0.noteID) && ($0.state == .blocking || $0.state == .uncertain)
        }.map(\.noteID))
        let repliesByThread = assessment.missingPublishedRepliesByThread(in: threads, authorID: input.user.id)
        let missingReplies = Set(findings.filter {
            $0.state == .waitingAcceptance && repliesByThread[$0.id] != nil
        }.map(\.id))
        let owedNotes = missingReplies.reduce(into: Set<Int>()) { notes, rootID in
            notes.formUnion(repliesByThread[rootID] ?? [])
        }
        followUp.formUnion(owedNotes)
        if !followUp.isEmpty, isCurrent(input) { await onNeedsWork?(request, followUp, input.fingerprint) }
        guard isCurrent(input) else { throw CancellationError() }
        // Courtesy acknowledgement is optional and must never suppress independent correction work.
        let acknowledgement = try await acknowledgeInformational(input, assessment: assessment, discussions: threads)
        threads = acknowledgement.threads
        changed = changed || acknowledgement.changed
        let acknowledgementFailures = acknowledgementAttempts[input.target]?.failures ?? [:]
        findings = AuthorFeedbackPolicy.evaluate(discussions: threads, assessment: assessment, authorID: input.user.id,
            approvedReviewerIDs: approved, enabled: input.configuration.autoResolveAcceptedFeedback).map { finding in
                guard finding.state == .ready, let reason = acknowledgementFailures[finding.id] else { return finding }
                return .init(id: finding.id, discussionID: finding.discussionID, reviewerID: finding.reviewerID,
                    reviewerUsername: finding.reviewerUsername, state: .needsVerification, reason: reason,
                    waitingForReviewers: [])
            }
        let completed = AuthorFeedbackStatus(head: request.sha ?? "", fingerprint: input.fingerprint,
            semanticContextFingerprint: request.semanticContextFingerprint, phase: .complete,
            findings: findings, acceptedReviewerIDs: accepted, followUpNoteIDs: followUp, replyNoteIDs: missingReplies,
            addressedNoteIDs: Set(assessment.notes.filter { $0.state == .addressed || $0.state == .informational }.map(\.noteID))
                .subtracting(owedNotes).subtracting(acknowledgementFailures.keys))
        let updated = statuses[input.target] != completed
        statuses[input.target] = completed
        if changed || updated { onRemoteChange?() }
    }

    private func liveInformationalDiscussions(_ input: Input) async throws -> [GitLabMergeRequestDiscussion] {
        guard isCurrent(input), !input.readOnly, input.configuration.autoResolveAcceptedFeedback else { throw CancellationError() }
        let request = input.request
        let host = input.target.host
        async let currentMR = glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
        async let currentThreads = glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
        async let currentUser = glab.fetchAuthenticatedUser(host: host, expectedUsername: input.user.username)
        async let currentDrafts = glab.fetchOwnDraftNoteCount(projectID: request.projectID, iid: request.iid, host: host, userID: input.user.id)
        let (live, discussions, user, count) = try await (currentMR, currentThreads, currentUser, currentDrafts)
        guard isCurrent(input), live.sha == request.sha, live.state == "opened", live.draft == false,
              live.semanticContextFingerprint == request.semanticContextFingerprint,
              live.author.id == input.user.id, user == input.user, count == 0, live.webURL == request.webURL,
              settings.automation.scope.permits(live, host: host, username: user.username),
              ReviewVerdict.fingerprint(discussions) == input.fingerprint else { throw CancellationError() }
        return discussions
    }

    private func acknowledgeInformational(_ input: Input, assessment: ReReviewAssessment,
                                          discussions: [GitLabMergeRequestDiscussion]) async throws
        -> (threads: [GitLabMergeRequestDiscussion], changed: Bool) {
        guard input.configuration.autoResolveAcceptedFeedback else { return (discussions, false) }
        let candidates = AuthorFeedbackPolicy.informationalAcknowledgements(discussions: discussions,
            assessment: assessment, authorID: input.user.id)
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
                        authorID: input.user.id).first { $0.discussionID == candidate.discussionID && $0.noteIDs == candidate.noteIDs }
                }
                for noteID in pendingReactions {
                    acknowledgementAttempts[input.target]?.reactions.insert(noteID)
                    do {
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
                guard liveCandidate.canResolve, let discussionID = liveCandidate.discussionID else { continue }
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
