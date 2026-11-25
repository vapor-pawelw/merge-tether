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
    var failureCause: RefreshFailure.Cause? = nil
    var isReadOnlyFailure = false
    /// Exact stopped attempts observed before the current remote preflight; never persisted as worker success.
    var reconciledFollowUpJobIDs: Set<UUID> = []
    var reconciledBlockedContexts: [UUID: ReReviewVerifier.Input.BlockedFollowUp] = [:]
    /// Binds checking and failed attempts even when no successful assessment was cached.
    var completedFollowUpJobID: UUID? = nil
    var feedbackDecisionRevision = ""
    var reviewParticipationRevision = ""
    var accountKinds: [Int: AuthorFeedbackPolicy.AccountKind] = [:]

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
        return .init(runID: job.id, selectedFeedbackIDs: selected.sorted(), blocker: blocker, summary: summary,
            selectedFeedbackRevisions: job.verifiedFeedbackNotes)
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
        if let needsChanges = findings.first(where: { $0.state == .needsChanges }) { return needsChanges }
        if let needsVerification = findings.first(where: { $0.state == .needsVerification && $0.manualDecision == nil }) {
            return needsVerification
        }
        if let needsReply = findings.first(where: { replyNoteIDs.contains($0.id) }) { return needsReply }
        return findings.first { $0.manualDecision != nil }
    }
    var hasVisibleDetails: Bool {
        phase != .complete || !findings.isEmpty || !codeReviewRequests.isEmpty || !followUpNoteIDs.isEmpty
    }
    /// Repeated source concerns are presented once without hiding distinct feedback.
    var displayFindings: [AuthorFeedbackPolicy.Finding] {
        let ordered = primaryFinding.map { primary in
            [primary] + findings.filter { $0.id != primary.id }
        } ?? findings
        var seen: Set<[String]> = []
        return ordered.filter { finding in
            let sourceID = String(finding.sourceNoteID ?? finding.id)
            let summary = finding.summary?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
            let reason = finding.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let key = [sourceID, summary, reason]
            return seen.insert(key).inserted
        }
    }
    var waitingForReviewer: Bool { findings.contains { $0.state == .waitingAcceptance } }
}

/// The only automation settings that shape a verifier run; unrelated settings, presets and the global
/// switch must not invalidate an otherwise identical assessment.
private struct VerifierConfiguration: Encodable {
    let assistant: AutomationAssistant
    let model: String
    let thinking: VerificationThinking

    init(_ configuration: AutomationSettings) {
        assistant = configuration.assistant
        model = configuration.assistant == .codex
            ? configuration.codexVerificationModel.rawValue : configuration.claudeVerificationModel.rawValue
        thinking = configuration.verificationThinking
    }
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
    private struct CachedAssessment {
        let key: String
        let evidenceKey: String
        let assessment: ReReviewAssessment
        let input: Input
        let verifiedInProcess: Bool
    }
    private struct PublishedReply {
        let sourceNoteID: Int
        let publishedNoteID: Int
        let before: [GitLabMergeRequestDiscussion]
        let after: [GitLabMergeRequestDiscussion]
    }
    @ObservationIgnored private var cache: [MRAutomationScope.Target: CachedAssessment] = [:]
    @ObservationIgnored private var publishedReplies: [MRAutomationScope.Target: PublishedReply] = [:]
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
    @ObservationIgnored private var statusOwners: [MRAutomationScope.Target: Input] = [:]
    private struct StableCheck { let input: Input; let date: Date }
    /// Snapshots whose last pass reproduced the previous status without any GitLab write.
    @ObservationIgnored private var stableChecks: [MRAutomationScope.Target: StableCheck] = [:]
    /// An unchanged, settled snapshot is rechecked at most this often; any input change rechecks at once.
    static let unchangedRecheckInterval: TimeInterval = 10 * 60
    private let assessmentDirectory: URL?
    /// The latest finished pass per MR: later passes treat its unchanged notes as already assessed.
    private struct PriorPass { let assessment: ReReviewAssessment; let noteRevisions: [Int: String]; let diffDigest: String }
    @ObservationIgnored private var priorPasses: [MRAutomationScope.Target: PriorPass] = [:]
    /// Retried snapshots must run the verifier again instead of reusing a stored result.
    @ObservationIgnored private var bypassStoredAssessment: Set<MRAutomationScope.Target> = []
    /// A user reset discards earlier passes, so the next pass assesses every note from scratch.
    @ObservationIgnored private var fullReassessment: Set<MRAutomationScope.Target> = []
    var onRemoteChange: (() -> Void)?
    var onScopedChange: ((GitLabMergeRequest, MRAutomationScope.Target, UInt64, [GitLabMergeRequestDiscussion]?) -> Void)?
    var onNeedsWork: ((GitLabMergeRequest, Set<Int>, String, AuthorFeedbackResidual?) async -> Void)?
    var prepareVerifiedReplies: ((GitLabMergeRequest, [GitLabMergeRequestDiscussion], ReReviewAssessment, Set<Int>,
        GitLabAuthenticatedUser, String, @escaping @MainActor @Sendable () -> Bool) async -> Set<Int>)?

    private struct Input: Sendable {
        let id = UUID()
        let request: GitLabMergeRequest
        let discussions: [GitLabMergeRequestDiscussion]
        let user: GitLabAuthenticatedUser
        let target: MRAutomationScope.Target
        let configuration: AutomationSettings
        let fingerprint: String
        let activeFingerprint: String
        let drafts: Int
        let accountRevision: UInt64
        let completedFollowUpJobID: UUID?
        let decisionRevision: String
        let ignoredSuggestions: [IgnoredFeedbackSuggestion]
        let reviewParticipationRevision: String
        let approvalRevision: String?
        let handoffRevision: String
        let writesAllowed: Bool
        let scopedRefresh: Bool
        var readOnly: Bool { drafts > 0 }
    }

    private struct Preparation {
        let assessment: ReReviewAssessment
        let verifiedInProcess: Bool
        let threads: [GitLabMergeRequestDiscussion]
        let drafts: [GitLabDraftNote]
        let approvals: Set<Int>
        let accountKinds: [Int: AuthorFeedbackPolicy.AccountKind]
        let stoppedFollowUps: [AssistantAutomationRunner.Handoff]
        let blockedContexts: [ReReviewVerifier.Input.BlockedFollowUp]
    }

    private struct ReadOnlyFailure: Error { let cause: any Error }

    init(settings: SettingsManager, glab: GlabService,
         canAutomate: @escaping @MainActor (AutomationAssistant) async -> Bool = { await AssistantCLI.detect($0).isReady },
         verify: @escaping @MainActor (ReReviewVerifier.Input, AutomationAssistant, String) async throws -> ReReviewAssessment = {
             try await ReReviewVerifier.verifySingleAttempt($0, assistant: $1, model: $2)
         }, retryWait: @escaping ReadOnlyAssessmentRetry.Wait = ReadOnlyAssessmentRetry.wait,
         now: @escaping ReadOnlyAssessmentRetry.Clock = { Date() }, assessmentDirectory: URL? = nil) {
        self.settings = settings; self.glab = glab; self.canAutomate = canAutomate; self.verify = verify
        self.retryWait = retryWait
        self.now = now
        self.assessmentDirectory = assessmentDirectory
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
        guard state.feedbackDecisionRevision == settings.feedbackSuggestionDecisions.revision(for: target),
              state.reviewParticipationRevision == settings.reviewParticipationPreferences.revision(host: host, username: username) else { return nil }
        guard let stored = cache[target], stored.input.completedFollowUpJobID == completedFollowUpJob(for: request, target: target)?.id else { return nil }
        return stored.assessment
    }

    func isChecking(for request: GitLabMergeRequest, fingerprint: String) -> Bool {
        guard let status = status(projectID: request.projectID, iid: request.iid) else { return false }
        return status.phase == .checking && status.head == request.sha && status.fingerprint == fingerprint
            && status.semanticContextFingerprint == request.semanticContextFingerprint
    }

    func assessmentInFlight(for request: GitLabMergeRequest, fingerprint: String, activeFingerprint: String) -> Bool {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return false }
        let target = MRAutomationScope.Target(host: host, username: username, projectID: request.projectID, iid: request.iid)
        guard let input = statusOwners[target], statuses[target]?.phase == .checking,
              input.request.sha == request.sha, input.request.draftProofRecoveryContextFingerprint == request.draftProofRecoveryContextFingerprint,
              input.fingerprint == fingerprint, input.activeFingerprint == activeFingerprint,
              liveContextMatches(input) else { return false }
        return pending[target]?.id == input.id || (activeInputs[target]?.id == input.id && tasks[target]?.isCancelled == false)
    }

    /// Carry the previous assessment across publication only when the application
    /// observes the exact checked reply and every other discussion stays identical.
    func recordVerifiedPublication(draft: GitLabDraftNote, sourceNoteID: Int, request: GitLabMergeRequest,
                                   user: GitLabAuthenticatedUser, host: String, before: [GitLabMergeRequestDiscussion],
                                   after: [GitLabMergeRequestDiscussion]) -> Int? {
        let target = MRAutomationScope.Target(host: host, username: user.username, projectID: request.projectID, iid: request.iid)
        guard let discussionID = draft.discussionID, let body = draft.note,
              let prior = cache[target], prior.verifiedInProcess, prior.input.user == user, liveContextMatches(prior.input),
              prior.input.request.sha == request.sha,
              prior.input.request.draftProofRecoveryContextFingerprint == request.draftProofRecoveryContextFingerprint,
              Self.samePublicationDiscussions(prior.input.discussions, before),
              before.contains(where: { $0.id == discussionID && $0.notes.contains { $0.id == sourceNoteID } }),
              prior.assessment.notes.contains(where: {
                  $0.noteID == sourceNoteID && $0.publishedReplyNoteID == nil && [.addressed, .rejected].contains($0.state)
              }),
              prior.assessment.missingPublishedReplyNoteIDs(in: before, authorID: user.id,
                  excludedReplyAuthorIDs: excludedReplyAuthors(prior.input)).contains(sourceNoteID) else { return nil }
        let oldIDs = Set(before.flatMap(\.notes).compactMap(\.id))
        let matches = after.filter { $0.id == discussionID }.flatMap(\.notes).compactMap { note -> Int? in
            guard let id = note.id, id > sourceNoteID, !oldIDs.contains(id), note.author?.id == user.id,
                  note.system == false, let publishedBody = note.body, publishedBody.utf8.elementsEqual(body.utf8) else { return nil }
            return id
        }
        guard matches.count == 1, let id = matches.first,
              Self.samePublicationDiscussions(before, after.map {
                  .init(id: $0.id, notes: $0.notes.filter { $0.id != id })
              }) else { return nil }
        publishedReplies[target] = .init(sourceNoteID: sourceNoteID, publishedNoteID: id, before: before, after: after)
        return id
    }

    private static func samePublicationDiscussions(_ first: [GitLabMergeRequestDiscussion],
                                                   _ second: [GitLabMergeRequestDiscussion]) -> Bool {
        guard let fingerprint = ManualDiscussionResolution.fingerprint(first),
              fingerprint == ManualDiscussionResolution.fingerprint(second),
              sameDiscussionResolution(first, second) else { return false }
        return first.flatMap(\.notes).elementsEqual(second.flatMap(\.notes)) {
            $0.body == $1.body && $0.author?.id == $1.author?.id && $0.system == $1.system
                && $0.resolvedBy?.id == $1.resolvedBy?.id
        }
    }

    static func permitsBackgroundCheck(for request: GitLabMergeRequest, configuration: AutomationSettings,
                                       host: String, username: String, mergeOptedIn: Bool = false) -> Bool {
        let workflow = configuration.workflowRules[.newDiscussion]
        let followsFeedback = configuration.authorFeedback.isEnabled
            || (workflow.mode == .assistant && workflow.includes(request))
        let checksForMerge = configuration.autoMergeEnabled || (mergeOptedIn && configuration.hasAutomaticPublicActionConsent)
        return (configuration.autoResolveAcceptedFeedback || checksForMerge || followsFeedback)
            && configuration.hasAutomaticActionConsent
            && configuration.scope.permits(request, host: host, username: username)
    }

    /// `approvalRevision` identifies the observed approvals; without it an unchanged snapshot is always rechecked.
    func refresh(request: GitLabMergeRequest, discussions: [GitLabMergeRequestDiscussion], drafts: Int,
                 host: String, user: GitLabAuthenticatedUser, approvalRevision: String? = nil, scopedRefresh: Bool = false) {
        let target = MRAutomationScope.Target(host: host, username: user.username, projectID: request.projectID, iid: request.iid)
        let configuration = settings.automation
        guard request.author.id == user.id, request.state == "opened", request.draft != nil,
              Self.permitsBackgroundCheck(for: request, configuration: configuration, host: host, username: user.username,
                  mergeOptedIn: settings.autoMergePreference(for: target) == .on),
              let fingerprint = ReviewVerdict.fingerprint(discussions), let head = request.sha else { return }
        let activeDiscussions = GitLabMergeRequestDiscussion.activeForReview(discussions)
        guard let activeFingerprint = ReviewVerdict.fingerprint(activeDiscussions) else { return }
        let hasFeedback = activeDiscussions.contains { $0.notes.contains { $0.system == false && $0.author?.id != user.id } }
        guard hasFeedback else {
            pending.removeValue(forKey: target)
            tasks[target]?.cancel()
            removeStatus(for: target)
            return
        }
        let completedJobID = completedFollowUpJob(for: request, target: target)?.id
        let decisionRevision = settings.feedbackSuggestionDecisions.revision(for: target)
        let participationRevision = settings.reviewParticipationPreferences.revision(host: host, username: user.username)
        if let status = statuses[target], status.head == head, status.fingerprint == fingerprint,
           status.semanticContextFingerprint == request.semanticContextFingerprint,
           status.feedbackDecisionRevision == decisionRevision,
           status.reviewParticipationRevision == participationRevision,
           status.phase == .failed, status.completedFollowUpJobID == completedJobID {
            guard status.isReadOnlyFailure, let failure = failedReads[target],
                  failure.accountRevision != glab.accountRevision || failure.configuration != configuration
                    || now().timeIntervalSince(failure.date) >= ReadOnlyAssessmentRetry.cooldown else { return }
            statuses[target]?.phase = .checking
            statuses[target]?.isReadOnlyFailure = false
            statuses[target]?.failureReason = nil
            statuses[target]?.failureCause = nil
        }
        let input = Input(request: request, discussions: discussions, user: user, target: target,
                          configuration: settings.automation, fingerprint: fingerprint, activeFingerprint: activeFingerprint, drafts: drafts,
                          accountRevision: glab.accountRevision,
                          completedFollowUpJobID: completedJobID, decisionRevision: decisionRevision,
                          ignoredSuggestions: settings.feedbackSuggestionDecisions.applicable(in: activeDiscussions, for: target),
                          reviewParticipationRevision: participationRevision, approvalRevision: approvalRevision,
                          handoffRevision: handoffRevision(target), writesAllowed: settings.automaticWritesAllowed,
                          scopedRefresh: scopedRefresh)
        if isSettled(input) { return }
        // An unchanged periodic refresh must not take ownership from the active task.
        if !sameSnapshot(statusOwners[target], input) {
            statuses[target] = checkingStatus(input)
            statusOwners[target] = input
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
            removeStatus(for: target); cache.removeValue(forKey: target); publishedReplies.removeValue(forKey: target)
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
        publishedReplies.removeValue(forKey: target)
        bypassStoredAssessment.insert(target)
        acknowledgementAttempts.removeValue(forKey: target)
        acknowledgedReactions.removeValue(forKey: target)
        removeStatus(for: target)
        failedReads.removeValue(forKey: target)
    }

    /// Emergency reset: forget every earlier pass and verify all feedback against the current MR from scratch.
    func resetAssessment(projectID: Int, iid: Int) {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return }
        let target = MRAutomationScope.Target(host: host, username: username, projectID: projectID, iid: iid)
        invalidate(projectID: projectID, iid: iid)
        priorPasses.removeValue(forKey: target)
        if let assessmentDirectory { AuthorFeedbackAssessmentStore.remove(target, in: assessmentDirectory) }
        fullReassessment.insert(target)
    }

    private func priorPass(for target: MRAutomationScope.Target) -> PriorPass? {
        guard !fullReassessment.contains(target) else { return nil }
        if let prior = priorPasses[target] { return prior }
        guard let assessmentDirectory, let record = AuthorFeedbackAssessmentStore.latest(target, in: assessmentDirectory),
              let revisions = record.noteRevisions, let digest = record.diffDigest else { return nil }
        return .init(assessment: record.assessment, noteRevisions: revisions, diffDigest: digest)
    }

    /// Earlier notes whose text is unchanged count as assessed; the verifier may cite them but not reopen them.
    private static func priorInput(_ prior: PriorPass?, revisions: [Int: String], diffDigest: String) -> ReReviewVerifier.Input.PriorAssessment? {
        guard let prior else { return nil }
        let unchanged = Set(revisions.filter { prior.noteRevisions[$0.key] == $0.value }.keys)
        let notes = prior.assessment.notes.filter { unchanged.contains($0.noteID) }
            .map { ReReviewVerifier.Input.PriorAssessment.Note(noteID: $0.noteID, state: $0.state, reason: $0.reason) }
        guard !notes.isEmpty else { return nil }
        return .init(notes: notes, codeReviewRequests: prior.assessment.reviewRequests.filter { unchanged.contains($0.sourceNoteID) },
            codeChangedSincePrior: prior.diffDigest != diffDigest)
    }

    /// Already assessed notes gain no new code-review requests; only earlier ones may be repeated.
    private static func constrained(_ assessment: ReReviewAssessment, prior: ReReviewVerifier.Input.PriorAssessment?) -> ReReviewAssessment {
        guard let prior, let requests = assessment.codeReviewRequests else { return assessment }
        let assessed = Set(prior.notes.map(\.noteID))
        let earlier = Set(prior.codeReviewRequests.map { "\($0.sourceNoteID)/\($0.kind.rawValue)" })
        var result = assessment
        result.codeReviewRequests = requests.filter {
            !assessed.contains($0.sourceNoteID) || earlier.contains("\($0.sourceNoteID)/\($0.kind.rawValue)")
        }
        return result
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
            guard statuses[target] != nil, liveContextMatches(input) else {
                discardOwnedCheckingStatus(input)
                continue
            }
            if !sameSnapshot(statusOwners[target], input) {
                statuses[target] = checkingStatus(input)
            }
            statusOwners[target] = input
            activeInputs[target] = input
            tasks[target] = Task { [weak self] in
                guard let self else { return }
                defer { tasks.removeValue(forKey: target); activeInputs.removeValue(forKey: target); startNext() }
                do { try await process(input) }
                catch is CancellationError {
                    discardOwnedCheckingStatus(input)
                }
                catch {
                    if !Task.isCancelled, isCurrent(input) {
                        let readOnly = error as? ReadOnlyFailure
                        if readOnly != nil {
                            failedReads[target] = .init(date: now(), accountRevision: input.accountRevision, configuration: input.configuration)
                        } else { failedReads.removeValue(forKey: target) }
                        var failed = checkingStatus(input)
                        failed.phase = .failed
                        failed.failureReason = String(GlabService.redactWorkflowEvidence(String(describing: readOnly?.cause ?? error)).prefix(600))
                        failed.isReadOnlyFailure = readOnly != nil
                        failed.failureCause = RefreshFailure.Cause(readOnly?.cause ?? error)
                        statuses[target] = failed
                        // Refreshes queued during backoff cannot restart an exhausted snapshot's budget.
                        pending.removeValue(forKey: target)
                        Log.monitor.error("Author feedback verification failed: \(String(describing: error), privacy: .private)")
                        notifyChange(input)
                    } else { discardOwnedCheckingStatus(input) }
                }
            }
        }
    }

    private func isCurrent(_ input: Input) -> Bool {
        !Task.isCancelled && statusOwners[input.target]?.id == input.id && liveContextMatches(input)
            && statuses[input.target]?.head == input.request.sha
            && statuses[input.target]?.fingerprint == input.fingerprint
            && statuses[input.target]?.semanticContextFingerprint == input.request.semanticContextFingerprint
            && statuses[input.target]?.completedFollowUpJobID == input.completedFollowUpJobID
            && statuses[input.target]?.feedbackDecisionRevision == input.decisionRevision
            && statuses[input.target]?.reviewParticipationRevision == input.reviewParticipationRevision
    }

    private func liveContextMatches(_ input: Input) -> Bool {
        glab.resolvedHost == input.target.host && glab.currentUsername == input.user.username
            && glab.accountRevision == input.accountRevision
            && settings.feedbackSuggestionDecisions.revision(for: input.target) == input.decisionRevision
            && settings.reviewParticipationPreferences.revision(host: input.target.host, username: input.user.username) == input.reviewParticipationRevision
            && settings.automation == input.configuration
            && completedFollowUpJob(for: input.request, target: input.target)?.id == input.completedFollowUpJobID
            && settings.automation.hasAutomaticActionConsent
            && !settings.ignoredMergeRequests.contains(input.target)
            && settings.automation.scope.permits(input.request, host: input.target.host, username: input.user.username)
    }

    private func sameSnapshot(_ previous: Input?, _ input: Input) -> Bool {
        guard let previous else { return false }
        return previous.target == input.target && previous.user == input.user
            && previous.accountRevision == input.accountRevision && previous.configuration == input.configuration
            && previous.request.sha == input.request.sha
            && previous.request.draftProofRecoveryContextFingerprint == input.request.draftProofRecoveryContextFingerprint
            && previous.fingerprint == input.fingerprint && previous.activeFingerprint == input.activeFingerprint
            && previous.drafts == input.drafts
            && previous.completedFollowUpJobID == input.completedFollowUpJobID
            && previous.decisionRevision == input.decisionRevision
            && previous.reviewParticipationRevision == input.reviewParticipationRevision
    }

    /// A settled snapshot repeats no GitLab reads, verifier run or launch admission until an input
    /// changes (head, text, thread state, drafts, approvals, jobs, settings, decisions) or the recheck interval passes.
    private func isSettled(_ input: Input) -> Bool {
        guard let stable = stableChecks[input.target], tasks[input.target] == nil, pending[input.target] == nil,
              statusOwners[input.target]?.id == stable.input.id,
              let phase = statuses[input.target]?.phase, phase == .complete || phase == .waitingPublication,
              input.approvalRevision != nil, stable.input.approvalRevision == input.approvalRevision,
              stable.input.handoffRevision == input.handoffRevision, stable.input.writesAllowed == input.writesAllowed,
              stable.input.request.semanticContextFingerprint == input.request.semanticContextFingerprint,
              stable.input.request.draft == input.request.draft,
              sameSnapshot(stable.input, input),
              Self.sameDiscussionResolution(stable.input.discussions, input.discussions) else { return false }
        let elapsed = now().timeIntervalSince(stable.date)
        return elapsed >= 0 && elapsed < Self.unchangedRecheckInterval
    }

    // Resolution changes within active threads can also change reply and acceptance readiness.
    private static func sameDiscussionResolution(_ previous: [GitLabMergeRequestDiscussion],
                                                 _ current: [GitLabMergeRequestDiscussion]) -> Bool {
        previous.elementsEqual(current) { before, after in
            before.id == after.id && before.notes.elementsEqual(after.notes) { earlier, latest in
                earlier.id == latest.id && earlier.resolvable == latest.resolvable && earlier.resolved == latest.resolved
            }
        }
    }

    private func recordSettlement(_ input: Input, settled: Bool) {
        if settled, input.approvalRevision != nil { stableChecks[input.target] = .init(input: input, date: now()) }
        else { stableChecks.removeValue(forKey: input.target) }
    }

    private func handoffRevision(_ target: MRAutomationScope.Target) -> String {
        let rows = settings.assistantHandoffs.filter {
            $0.key.work.host == target.host && $0.key.username == target.username
                && $0.key.work.projectID == target.projectID && $0.key.work.iid == target.iid
        }.map {
            "\($0.id.uuidString):\(String(describing: $0.execution?.state)):\(String(describing: $0.operationalExecution?.state))"
                + ":\($0.execution?.finishedAt?.timeIntervalSince1970 ?? 0)"
        }.sorted()
        return UserAttentionSnapshot.digest(rows.joined(separator: "\n"))
    }

    private func checkingStatus(_ input: Input) -> AuthorFeedbackStatus {
        .init(head: input.request.sha ?? "", fingerprint: input.fingerprint,
            semanticContextFingerprint: input.request.semanticContextFingerprint,
            readOnlyReconciliation: input.readOnly, phase: .checking, pendingDraftCount: input.drafts,
            completedFollowUpJobID: input.completedFollowUpJobID, feedbackDecisionRevision: input.decisionRevision,
            reviewParticipationRevision: input.reviewParticipationRevision)
    }

    private func discardOwnedCheckingStatus(_ input: Input) {
        guard statusOwners[input.target]?.id == input.id, statuses[input.target]?.phase == .checking else { return }
        removeStatus(for: input.target)
        notifyChange(input)
    }

    private func notifyChange(_ input: Input, updatedDiscussions: [GitLabMergeRequestDiscussion]? = nil) {
        if input.scopedRefresh { onScopedChange?(input.request, input.target, input.accountRevision, updatedDiscussions) }
        else { onRemoteChange?() }
    }

    private func removeStatus(for target: MRAutomationScope.Target) {
        statuses.removeValue(forKey: target)
        statusOwners.removeValue(forKey: target)
        stableChecks.removeValue(forKey: target)
    }

    /// A successful worker can leave work outstanding. Its prior semantic verdict then
    /// predates the worker and cannot establish that the worker omitted remaining author work.
    private func completedFollowUpJob(for request: GitLabMergeRequest, target: MRAutomationScope.Target) -> AssistantAutomationRunner.Handoff? {
        let decision = settings.feedbackSuggestionDecisions.revision(for: target)
        return settings.assistantHandoffs.filter {
            $0.key.work.host == target.host && $0.key.work.projectID == target.projectID
                && $0.key.work.iid == target.iid && $0.key.username == target.username
                && $0.workflow == .followUp && $0.draftRepair == nil
                && $0.feedbackDecisionRevision == (decision.isEmpty ? nil : decision)
                && $0.execution?.state == .succeeded
                && $0.execution?.finishedAt != nil && !($0.feedbackNoteIDs ?? []).isEmpty
        }.max {
            let first = $0.execution?.finishedAt ?? $0.createdAt
            let second = $1.execution?.finishedAt ?? $1.createdAt
            return first == second ? $0.id.uuidString < $1.id.uuidString : first < second
        }
    }

    private func residual(_ input: Input, assessment: ReReviewAssessment, notes: Set<Int>,
                          stoppedFollowUps: [AssistantAutomationRunner.Handoff]) -> AuthorFeedbackResidual? {
        let runID = input.completedFollowUpJobID
        guard runID == nil || cache[input.target]?.input.completedFollowUpJobID == runID else { return nil }
        let requests = assessment.reviewRequests.filter { notes.contains($0.sourceNoteID) }
        let requestedIDs = Set(requests.map(\.sourceNoteID))
        let owed = assessment.missingPublishedReplyNoteIDs(in: input.discussions, authorID: input.user.id,
            excludedReplyAuthorIDs: excludedReplyAuthors(input))
        let outstanding = assessment.notes.filter {
            notes.contains($0.noteID) && ($0.state == .blocking || $0.state == .uncertain
                || owed.contains($0.noteID) || requestedIDs.contains($0.noteID))
                && !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !outstanding.isEmpty else { return nil }
        return .init(assessedRunID: runID, notes: outstanding,
            semanticContextFingerprint: input.request.semanticContextFingerprint, codeReviewRequests: requests,
            assessedStoppedRunIDs: Set(stoppedFollowUps.filter { $0.execution?.state != .blocked }.map(\.id)))
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
        let activeDiscussions = GitLabMergeRequestDiscussion.activeForReview(input.discussions)
        let activeNoteIDs = Set(activeDiscussions.flatMap(\.notes).compactMap(\.id))
        guard input.configuration.selectedAssistant != nil, await canAutomate(input.configuration.assistant) else { throw ReReviewVerifier.VerificationError.unavailable }
        guard isCurrent(input) else { throw CancellationError() }
        let request = input.request
        let host = input.target.host
        let diff: Data = try await glab.mergeRequestAPI("/projects/\(request.projectID)/merge_requests/\(request.iid)/raw_diffs", host: host, decode: { $0 })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let completedFollowUp = completedFollowUpJob(for: request, target: input.target).flatMap { job -> ReReviewVerifier.Input.CompletedFollowUp? in
            guard job.id == input.completedFollowUpJobID, let ids = job.feedbackNoteIDs,
                  Set(ids).isSubset(of: activeNoteIDs), let summary = job.execution?.summary, !summary.isEmpty else { return nil }
            return .init(runID: job.id, selectedFeedbackIDs: ids,
                summary: String(GlabService.redactWorkflowEvidence(summary).prefix(2_000)))
        }
        let stoppedRevision = stoppedFollowUps.map {
            "\($0.id.uuidString):\(String(describing: $0.execution?.state)):\($0.execution?.finishedAt?.timeIntervalSince1970 ?? 0)"
        }.sorted().joined(separator: "\n")
        let diffText = String(decoding: diff, as: UTF8.self)
        let diffDigest = MergeRequestDiffDigest.normalized(diffText)
        let stoppedContexts = stoppedFollowUps.compactMap { AuthorFeedbackStatus.blockedContext(for: $0) }
        var verificationInput = ReReviewVerifier.Input(authorID: input.user.id, headSHA: request.sha ?? "", title: request.title,
            description: request.description, diff: diffText, discussions: input.discussions,
            target: .init(host: host, projectID: request.projectID, iid: request.iid,
                url: request.webURL, expectedUsername: input.user.username),
            semanticContextFingerprint: request.semanticContextFingerprint,
            thinking: input.configuration.verificationThinking, blockedFollowUps: stoppedContexts,
            ignoredSuggestions: input.ignoredSuggestions, completedFollowUp: completedFollowUp,
            excludedReplyAuthorIDs: excludedReplyAuthors(input).sorted(), usagePurpose: .authorFeedback,
            usageCorrelationID: input.id).activeEvidence
        let blockedContexts = verificationInput.blockedFollowUps
        let blockedHead = blockedContexts.isEmpty ? "" : verificationInput.headSHA
        let replyFingerprint = ReviewVerdict.fingerprint(verificationInput.resolvedOverviewReplyEvidence ?? []) ?? ""
        let contextKey = request.semanticContextFingerprint + "|" + diffDigest
        let policyKey = (input.completedFollowUpJobID?.uuidString ?? "")
            + "|" + String(decoding: try encoder.encode(VerifierConfiguration(input.configuration)), as: UTF8.self)
            + "|" + blockedHead + "|" + UserAttentionSnapshot.digest(String(decoding: try encoder.encode(blockedContexts), as: UTF8.self))
            + "|" + input.decisionRevision
            + "|" + input.reviewParticipationRevision
            + "|" + String(decoding: try encoder.encode(completedFollowUp), as: UTF8.self)
            + (stoppedRevision.isEmpty ? "" : "|stopped:" + UserAttentionSnapshot.digest(stoppedRevision))
        // Content-bound rather than commit-bound: a rebase that keeps the MR's changes reuses the assessment.
        let key = ReReviewVerifier.policyVersion + "|" + input.activeFingerprint + "|" + contextKey + "|" + replyFingerprint + "|" + policyKey
        let evidenceKey = contextKey + "|" + policyKey
        let assessment: ReReviewAssessment
        let verifiedInProcess: Bool
        let keyDigest = UserAttentionSnapshot.digest(key)
        let revisions = MergeRequestDiffDigest.noteRevisions(activeDiscussions)
        let bypass = bypassStoredAssessment.contains(input.target) || fullReassessment.contains(input.target)
        if !bypass, let stored = cache[input.target], stored.key == key {
            assessment = stored.assessment
            verifiedInProcess = stored.verifiedInProcess && stored.input.request.sha == request.sha
                && stored.input.request.draftProofRecoveryContextFingerprint == request.draftProofRecoveryContextFingerprint
                && Self.samePublicationDiscussions(stored.input.discussions, input.discussions)
        }
        else if !bypass, let assessmentDirectory,
                let record = AuthorFeedbackAssessmentStore.load(input.target, keyDigest: keyDigest, in: assessmentDirectory),
                record.completedFollowUpJobID == input.completedFollowUpJobID,
                (try? record.assessment.reviewers(in: input.discussions, authorID: input.user.id, ignoredSuggestions: input.ignoredSuggestions,
                    excludedReplyAuthorIDs: excludedReplyAuthors(input))) != nil {
            assessment = record.assessment
            verifiedInProcess = false
            cache[input.target] = .init(key: key, evidenceKey: evidenceKey, assessment: assessment, input: input, verifiedInProcess: false)
        } else {
            if !bypass, let updated = assessmentAfterPublication(input, evidenceKey: evidenceKey) {
                assessment = updated
            } else {
                let model = input.configuration.assistant == .codex
                    ? input.configuration.codexVerificationModel.rawValue : input.configuration.claudeVerificationModel.rawValue
                let prior = Self.priorInput(priorPass(for: input.target), revisions: revisions, diffDigest: diffDigest)
                verificationInput.priorAssessment = prior
                assessment = Self.constrained(try await verify(verificationInput,
                    input.configuration.assistant, model), prior: prior)
            }
            _ = try assessment.reviewers(in: input.discussions, authorID: input.user.id, ignoredSuggestions: input.ignoredSuggestions,
                excludedReplyAuthorIDs: excludedReplyAuthors(input))
            guard isCurrent(input) else { throw CancellationError() }
            verifiedInProcess = true
            cache[input.target] = .init(key: key, evidenceKey: evidenceKey, assessment: assessment, input: input, verifiedInProcess: true)
            publishedReplies.removeValue(forKey: input.target)
            priorPasses[input.target] = .init(assessment: assessment, noteRevisions: revisions, diffDigest: diffDigest)
            bypassStoredAssessment.remove(input.target)
            fullReassessment.remove(input.target)
            if let assessmentDirectory {
                do {
                    try AuthorFeedbackAssessmentStore.save(.init(version: AuthorFeedbackAssessmentStore.version, target: input.target,
                        keyDigest: keyDigest, completedFollowUpJobID: input.completedFollowUpJobID, assessment: assessment,
                        noteRevisions: revisions, diffDigest: diffDigest), in: assessmentDirectory)
                } catch {
                    Log.monitor.error("Could not persist author feedback assessment: \(String(describing: error), privacy: .private)")
                }
            }
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
                  ReviewVerdict.fingerprint(threads) == input.fingerprint,
                  ReviewVerdict.fingerprint(GitLabMergeRequestDiscussion.activeForReview(threads)) == input.activeFingerprint
            else { throw CancellationError() }
            let approvals = input.readOnly ? [] : try await glab.fetchMergeRequestApproverIDs(
                projectID: request.projectID, iid: request.iid, host: host)
            guard isCurrent(input) else { throw CancellationError() }
            let accountKinds = try await participantAccountKinds(in: threads, input: input)
            return Preparation(assessment: assessment,
                verifiedInProcess: verifiedInProcess && Self.samePublicationDiscussions(input.discussions, threads),
                threads: threads, drafts: drafts, approvals: approvals, accountKinds: accountKinds,
                stoppedFollowUps: stoppedFollowUps, blockedContexts: blockedContexts)
        }
        let approvals = try await glab.fetchMergeRequestApproverIDs(projectID: request.projectID, iid: request.iid, host: host)
        guard isCurrent(input) else { throw CancellationError() }
        let accountKinds = try await participantAccountKinds(in: input.discussions, input: input)
        return Preparation(assessment: assessment, verifiedInProcess: verifiedInProcess, threads: input.discussions,
            drafts: [], approvals: approvals, accountKinds: accountKinds,
            stoppedFollowUps: [], blockedContexts: [])
    }

    private func assessmentAfterPublication(_ input: Input, evidenceKey: String) -> ReReviewAssessment? {
        guard let reply = publishedReplies[input.target], let stored = cache[input.target], stored.verifiedInProcess,
              stored.evidenceKey == evidenceKey, stored.input.accountRevision == input.accountRevision,
              stored.input.request.sha == input.request.sha,
              stored.input.request.draftProofRecoveryContextFingerprint == input.request.draftProofRecoveryContextFingerprint,
              Self.samePublicationDiscussions(stored.input.discussions, reply.before),
              Self.samePublicationDiscussions(input.discussions, reply.after) else { return nil }
        let assessment = ReReviewAssessment(notes: stored.assessment.notes.map { note in
            var note = note
            if note.noteID == reply.sourceNoteID { note.publishedReplyNoteID = reply.publishedNoteID }
            return note
        }, completedBlockedRunIDs: stored.assessment.completedBlockedRunIDs, codeReviewRequests: stored.assessment.codeReviewRequests)
        guard (try? assessment.reviewers(in: input.discussions, authorID: input.user.id,
            ignoredSuggestions: input.ignoredSuggestions, excludedReplyAuthorIDs: excludedReplyAuthors(input))) != nil else { return nil }
        return assessment
    }

    private func participantAccountKinds(in discussions: [GitLabMergeRequestDiscussion], input: Input) async throws
        -> [Int: AuthorFeedbackPolicy.AccountKind] {
        guard isCurrent(input) else { throw CancellationError() }
        let relevant = discussions.filter {
            $0.notes.first?.system == false && $0.notes.first?.resolvable == true && $0.notes.first?.resolved == false
                && $0.notes.first?.author?.id != input.user.id
        }
        let ids = Set(relevant.flatMap(\.notes).compactMap { note -> Int? in
            guard note.system == false, let id = note.author?.id, id > 0, id != input.user.id else { return nil }
            return id
        })
        var kinds = Dictionary(uniqueKeysWithValues: ids.map { ($0, AuthorFeedbackPolicy.AccountKind.unknown) })
        let bounded = Array(ids.sorted().prefix(64))
        for offset in stride(from: 0, to: bounded.count, by: 4) {
            let batch = Array(bounded[offset..<min(offset + 4, bounded.count)])
            async let first = participantAccountKind(batch.first, input: input)
            async let second = participantAccountKind(batch.dropFirst().first, input: input)
            async let third = participantAccountKind(batch.dropFirst(2).first, input: input)
            async let fourth = participantAccountKind(batch.dropFirst(3).first, input: input)
            let values = await (first, second, third, fourth)
            guard isCurrent(input) else { throw CancellationError() }
            for (id, kind) in [values.0, values.1, values.2, values.3].compactMap({ $0 }) { kinds[id] = kind }
        }
        guard isCurrent(input) else { throw CancellationError() }
        let declared = settings.reviewParticipationPreferences.botIDs(host: input.target.host, username: input.user.username)
            .intersection(ids).subtracting(excludedReplyAuthors(input))
        for id in declared { kinds[id] = .automation }
        return kinds
    }

    private func participantAccountKind(_ id: Int?, input: Input) async -> (Int, AuthorFeedbackPolicy.AccountKind)? {
        guard let id, isCurrent(input) else { return nil }
        let kind = (try? await glab.feedbackAccountKind(userID: id, host: input.target.host)) ?? .unknown
        guard isCurrent(input) else { return nil }
        return (id, kind)
    }

    private func prepareReplyOnlyFeedback(_ input: Input, preparation: Preparation, owedNotes: Set<Int>) async -> Set<Int> {
        let replyOnly = owedNotes.subtracting(preparation.assessment.automaticWorkNoteIDs)
        guard preparation.verifiedInProcess, !replyOnly.isEmpty, settings.automaticWritesAllowed,
              isCurrent(input), let prepareVerifiedReplies else { return [] }
        return await prepareVerifiedReplies(input.request, preparation.threads, preparation.assessment,
            replyOnly, input.user, input.target.host) { [weak self] in
                self?.isCurrent(input) == true
            }
    }

    private func process(_ input: Input) async throws {
        let prepared: Preparation
        do {
            prepared = try await ReadOnlyAssessmentRetry.run(isCurrent: { self.isCurrent(input) }, wait: retryWait, onRetry: {
                self.statuses[input.target]?.phase = .checking
                self.statuses[input.target]?.readOnlyReconciliation = input.readOnly
                self.statuses[input.target]?.failureReason = nil
                self.statuses[input.target]?.failureCause = nil
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
            let repliesByThread = assessment.missingPublishedRepliesByThread(in: threads, authorID: input.user.id, excludedReplyAuthorIDs: excludedReplyAuthors(input))
            let owedNotes = Set(repliesByThread.values.flatMap { $0 })
            let draftedThreads = Set(drafts.compactMap(\.discussionID))
            let draftedNotes = Set(threads.filter { $0.id.map(draftedThreads.contains) == true }.flatMap(\.notes).compactMap(\.id))
            let actionable = assessment.automaticWorkNoteIDs
            let drafted = await prepareReplyOnlyFeedback(input, preparation: prepared, owedNotes: owedNotes.subtracting(draftedNotes))
            guard isCurrent(input) else { throw CancellationError() }
            let followUp = settings.automation.scope.permits(request, host: host, username: input.user.username)
                ? actionable.union(owedNotes).subtracting(draftedNotes).subtracting(drafted) : []
            if settings.automaticWritesAllowed, !followUp.isEmpty { await onNeedsWork?(request, followUp, input.fingerprint,
                residual(input, assessment: assessment, notes: followUp, stoppedFollowUps: prepared.stoppedFollowUps)) }
            guard isCurrent(input) else { throw CancellationError() }
            let addressedNoteIDs = Self.addressedNoteIDs(in: assessment).subtracting(owedNotes)
            var completed = AuthorFeedbackStatus(head: request.sha ?? "", fingerprint: input.fingerprint,
                semanticContextFingerprint: request.semanticContextFingerprint,
                phase: drafts.isEmpty ? .complete : .waitingPublication, pendingDraftCount: drafts.count,
                followUpNoteIDs: followUp,
                replyNoteIDs: Set(repliesByThread.keys),
                addressedNoteIDs: addressedNoteIDs,
                completedFollowUpJobID: input.completedFollowUpJobID)
            completed.feedbackDecisionRevision = input.decisionRevision
            completed.reviewParticipationRevision = input.reviewParticipationRevision
            completed.accountKinds = prepared.accountKinds
            completed.findings = AuthorFeedbackPolicy.evaluate(discussions: threads, assessment: assessment, authorID: input.user.id,
                approvedReviewerIDs: prepared.approvals, enabled: false, pendingDraftCount: drafts.count,
                ignoredSuggestions: input.ignoredSuggestions, excludedReplyAuthorIDs: excludedReplyAuthors(input),
                accountKinds: prepared.accountKinds)
            completed.codeReviewRequests = assessment.reviewRequests
            completed.ignoredNoteIDs = Set(assessment.notes.filter { $0.state == .ignoredByUser }.map(\.noteID))
            bindStoppedFollowUpEvidence(to: &completed, prepared: prepared, input: input, discussions: threads, authorID: input.user.id)
            let changed = statuses[input.target] != completed
            statuses[input.target] = completed
            recordSettlement(input, settled: !changed)
            if changed { notifyChange(input) }
            return
        }
        var approved = prepared.approvals
        var threads = prepared.threads
        var accountKinds = prepared.accountKinds
        let initial = AuthorFeedbackPolicy.evaluate(discussions: threads, assessment: assessment, authorID: input.user.id,
            approvedReviewerIDs: approved, enabled: input.configuration.autoResolveAcceptedFeedback, ignoredSuggestions: input.ignoredSuggestions,
            excludedReplyAuthorIDs: excludedReplyAuthors(input), accountKinds: accountKinds)
        var accepted: Set<Int> = []
        var changed = false
        let informationalThreads = Set(AuthorFeedbackPolicy.informationalAcknowledgements(discussions: threads,
            assessment: assessment, authorID: input.user.id, ignoredSuggestions: input.ignoredSuggestions, excludedReplyAuthorIDs: excludedReplyAuthors(input)).filter(\.canResolve).compactMap(\.discussionID))
        for finding in initial where finding.canResolve && !informationalThreads.contains(finding.discussionID ?? "") {
            guard settings.automaticPublicWritesAllowed else { break }
            guard isCurrent(input) else { throw CancellationError() }
            guard input.configuration.selectedAssistant != nil, await canAutomate(input.configuration.assistant) else { throw ReReviewVerifier.VerificationError.unavailable }
            guard settings.automaticPublicWritesAllowed else { break }
            guard isCurrent(input), let discussionID = finding.discussionID else { throw CancellationError() }
            async let currentMR = glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
            async let currentThreads = glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
            async let currentUser = glab.fetchAuthenticatedUser(host: host, expectedUsername: input.user.username)
            async let drafts = glab.fetchOwnDraftNoteCount(projectID: request.projectID, iid: request.iid, host: host, userID: input.user.id)
            async let approvals = glab.fetchMergeRequestApproverIDs(projectID: request.projectID, iid: request.iid, host: host)
            let (live, discussions, user, count, liveApproved) = try await (currentMR, currentThreads, currentUser, drafts, approvals)
            approved = liveApproved
            guard settings.automaticPublicWritesAllowed else { break }
            guard isCurrent(input), live.sha == request.sha, live.state == "opened",
                  live.semanticContextFingerprint == request.semanticContextFingerprint,
                  live.author.id == input.user.id, user == input.user, count == 0,
                  settings.automation.scope.permits(live, host: host, username: user.username),
                  live.webURL == request.webURL, ReviewVerdict.fingerprint(discussions) == input.fingerprint else { throw CancellationError() }
            threads = discussions
            let involved = discussions.filter { $0.id == discussionID }
            let freshKinds = try await participantAccountKinds(in: involved, input: input)
            accountKinds.merge(freshKinds, uniquingKeysWith: { _, fresh in fresh })
            guard settings.automaticPublicWritesAllowed, isCurrent(input) else { throw CancellationError() }
            let permitted = AuthorFeedbackPolicy.evaluate(discussions: discussions, assessment: assessment, authorID: user.id,
                approvedReviewerIDs: liveApproved, ignoredSuggestions: input.ignoredSuggestions,
                excludedReplyAuthorIDs: excludedReplyAuthors(input), accountKinds: accountKinds).contains { $0.discussionID == discussionID && $0.canResolve }
            guard permitted, !settings.pendingCommentReviews.contains(input.target) else { continue }
            try await glab.resolveAcceptedDiscussion(projectID: request.projectID, iid: request.iid, discussionID: discussionID, host: host) {
                self.settings.automaticPublicWritesAllowed && self.isCurrent(input) && !input.readOnly
                    && input.configuration.autoResolveAcceptedFeedback
                    && !self.settings.pendingCommentReviews.contains(input.target)
            }
            changed = true
            if accountKinds[finding.reviewerID] != .automation { accepted.insert(finding.reviewerID) }
            threads = try await glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
            let confirmed = try await glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
            guard isCurrent(input), confirmed.sha == request.sha,
                  confirmed.semanticContextFingerprint == request.semanticContextFingerprint,
                  settings.automation.scope.permits(confirmed, host: host, username: input.user.username),
                  ReviewVerdict.fingerprint(threads) == input.fingerprint else { throw CancellationError() }
        }
        guard isCurrent(input) else { throw CancellationError() }
        var findings = AuthorFeedbackPolicy.evaluate(discussions: threads, assessment: assessment, authorID: input.user.id,
            approvedReviewerIDs: approved, enabled: input.configuration.autoResolveAcceptedFeedback, ignoredSuggestions: input.ignoredSuggestions,
            excludedReplyAuthorIDs: excludedReplyAuthors(input), accountKinds: accountKinds)
        accepted.formUnion(AuthorFeedbackPolicy.acceptedReviewers(discussions: threads, assessment: assessment,
            authorID: input.user.id, approvedReviewerIDs: approved, ignoredSuggestions: input.ignoredSuggestions,
            excludedReplyAuthorIDs: excludedReplyAuthors(input), accountKinds: accountKinds))
        let outstandingNotes = GitLabMergeRequestDiscussion.activeForReview(threads).flatMap(\.notes).filter {
            $0.system == false && $0.author?.id != input.user.id
        }
        let outstanding: Set<Int> = Set(outstandingNotes.compactMap(\.id))
        var followUp = assessment.automaticWorkNoteIDs.intersection(outstanding)
        let repliesByThread = assessment.missingPublishedRepliesByThread(in: threads, authorID: input.user.id, excludedReplyAuthorIDs: excludedReplyAuthors(input))
        // An owed published reply remains work even when approval or a disabled
        // resolution policy changes the finding's presentation state.
        let missingReplies = Set(repliesByThread.keys)
        let owedNotes = missingReplies.reduce(into: Set<Int>()) { notes, rootID in
            notes.formUnion(repliesByThread[rootID] ?? [])
        }
        followUp.formUnion(owedNotes)
        let drafted = await prepareReplyOnlyFeedback(input, preparation: prepared, owedNotes: owedNotes)
        guard isCurrent(input) else { throw CancellationError() }
        followUp.subtract(drafted)
        if settings.automaticWritesAllowed, !followUp.isEmpty, isCurrent(input) { await onNeedsWork?(request, followUp, input.fingerprint,
            residual(input, assessment: assessment, notes: followUp, stoppedFollowUps: prepared.stoppedFollowUps)) }
        guard isCurrent(input) else { throw CancellationError() }
        // Courtesy acknowledgement is optional and must never suppress independent correction work.
        let acknowledgement = try await acknowledgeInformational(input, assessment: assessment, discussions: threads)
        guard isCurrent(input) else { throw CancellationError() }
        threads = acknowledgement.threads
        changed = changed || acknowledgement.changed
        let acknowledgementFailures = acknowledgementAttempts[input.target]?.failures ?? [:]
        findings = AuthorFeedbackPolicy.evaluate(discussions: threads, assessment: assessment, authorID: input.user.id,
            approvedReviewerIDs: approved, enabled: input.configuration.autoResolveAcceptedFeedback, ignoredSuggestions: input.ignoredSuggestions,
            excludedReplyAuthorIDs: excludedReplyAuthors(input), accountKinds: accountKinds).map { finding in
                guard finding.state == .ready, let reason = acknowledgementFailures[finding.id] else { return finding }
                return .init(id: finding.id, discussionID: finding.discussionID, reviewerID: finding.reviewerID,
                    reviewerUsername: finding.reviewerUsername, state: .needsVerification, reason: reason,
                    waitingForReviewers: [])
            }
        accepted.subtract(accountKinds.compactMap { $0.value == .automation ? $0.key : nil })
        accepted.subtract(settings.reviewParticipationPreferences.botIDs(host: host, username: input.user.username))
        let addressedNoteIDs = Self.addressedNoteIDs(in: assessment).subtracting(owedNotes).subtracting(acknowledgementFailures.keys)
        var completed = AuthorFeedbackStatus(head: request.sha ?? "", fingerprint: input.fingerprint,
            semanticContextFingerprint: request.semanticContextFingerprint, phase: drafted.isEmpty ? .complete : .waitingPublication,
            findings: findings, codeReviewRequests: assessment.reviewRequests,
            acceptedReviewerIDs: accepted, followUpNoteIDs: followUp, replyNoteIDs: missingReplies,
            addressedNoteIDs: addressedNoteIDs,
            completedFollowUpJobID: input.completedFollowUpJobID)
        completed.feedbackDecisionRevision = input.decisionRevision
        completed.reviewParticipationRevision = input.reviewParticipationRevision
        completed.accountKinds = accountKinds
        completed.ignoredNoteIDs = Set(assessment.notes.filter { $0.state == .ignoredByUser }.map(\.noteID))
        bindStoppedFollowUpEvidence(to: &completed, prepared: prepared, input: input, discussions: threads, authorID: input.user.id)
        let updated = statuses[input.target] != completed
        statuses[input.target] = completed
        recordSettlement(input, settled: !changed && !updated)
        if changed || updated { notifyChange(input, updatedDiscussions: changed ? threads : nil) }
    }

    private static func addressedNoteIDs(in assessment: ReReviewAssessment) -> Set<Int> {
        let addressedNotes = assessment.notes.filter { note in
            switch note.state {
            case .addressed, .rejected, .informational: true
            default: false
            }
        }
        return Set(addressedNotes.map(\.noteID))
    }

    private func excludedReplyAuthors(_ input: Input) -> Set<Int> {
        settings.reviewParticipationPreferences.excludedIDs(host: input.target.host, username: input.user.username)
    }

    private func bindStoppedFollowUpEvidence(to status: inout AuthorFeedbackStatus, prepared: Preparation, input: Input,
                                            discussions: [GitLabMergeRequestDiscussion], authorID: Int) {
        let missingReplies = prepared.assessment.missingPublishedReplyNoteIDs(in: discussions, authorID: authorID,
            excludedReplyAuthorIDs: excludedReplyAuthors(input))
        let verifiedActive = status.addressedNoteIDs.union(status.ignoredNoteIDs)
        for candidate in prepared.stoppedFollowUps {
            guard let current = settings.assistantHandoffs.first(where: { $0.id == candidate.id }),
                  current.key == candidate.key, current.workflow == candidate.workflow,
                  current.execution?.state == candidate.execution?.state,
                  current.feedbackNoteIDs == candidate.feedbackNoteIDs,
                  current.pipelineReservation == nil, candidate.pipelineReservation == nil,
                  current.allowsPush == candidate.allowsPush,
                  current.expectedHeadSHA == candidate.expectedHeadSHA else { continue }
            let selected = Set(candidate.feedbackNoteIDs ?? [])
            guard selected.isDisjoint(with: status.followUpNoteIDs), selected.isDisjoint(with: missingReplies) else { continue }
            if candidate.execution?.state == .blocked {
                guard prepared.assessment.completedBlockedRunIDs?.contains(candidate.id) == true,
                      let context = AuthorFeedbackStatus.blockedContext(for: candidate),
                      AuthorFeedbackStatus.blockedContext(for: current) == context,
                      prepared.blockedContexts.contains(context) else { continue }
                let resolved = context.resolvedFeedbackIDs(in: discussions, authorID: authorID)
                let active = selected.subtracting(resolved)
                let addressed = Set(prepared.assessment.notes.filter { $0.state == .addressed || $0.state == .rejected || $0.state == .ignoredByUser }.map(\.noteID))
                    .union(prepared.assessment.pureReviewerOptOutNoteIDs(in: discussions, authorID: authorID))
                guard active.isSubset(of: verifiedActive), active.isSubset(of: addressed) else { continue }
                status.reconciledBlockedContexts[candidate.id] = context
                status.addressedNoteIDs.formUnion(resolved)
            } else {
                guard selected.isSubset(of: verifiedActive), selected.isDisjoint(with: status.ignoredNoteIDs) else { continue }
            }
            status.reconciledFollowUpJobIDs.insert(candidate.id)
        }
    }

    private func liveInformationalDiscussions(_ input: Input) async throws -> [GitLabMergeRequestDiscussion] {
        guard settings.automaticPublicWritesAllowed, isCurrent(input), !input.readOnly,
              input.configuration.autoResolveAcceptedFeedback else { throw CancellationError() }
        let request = input.request
        let host = input.target.host
        async let currentMR = glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
        async let currentThreads = glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
        async let currentUser = glab.fetchAuthenticatedUser(host: host, expectedUsername: input.user.username)
        async let currentDrafts = glab.fetchOwnDraftNoteCount(projectID: request.projectID, iid: request.iid, host: host, userID: input.user.id)
        let (live, discussions, user, count) = try await (currentMR, currentThreads, currentUser, currentDrafts)
        guard settings.automaticPublicWritesAllowed, isCurrent(input), live.sha == request.sha, live.state == "opened",
              live.semanticContextFingerprint == request.semanticContextFingerprint,
              live.author.id == input.user.id, user == input.user, count == 0, live.webURL == request.webURL,
              settings.automation.scope.permits(live, host: host, username: user.username),
              ReviewVerdict.fingerprint(discussions) == input.fingerprint else { throw CancellationError() }
        return discussions
    }

    private func acknowledgeInformational(_ input: Input, assessment: ReReviewAssessment,
                                          discussions: [GitLabMergeRequestDiscussion]) async throws
        -> (threads: [GitLabMergeRequestDiscussion], changed: Bool) {
        guard settings.automaticPublicWritesAllowed, input.configuration.autoResolveAcceptedFeedback else { return (discussions, false) }
        let candidates = AuthorFeedbackPolicy.informationalAcknowledgements(discussions: discussions,
            assessment: assessment, authorID: input.user.id, ignoredSuggestions: input.ignoredSuggestions, excludedReplyAuthorIDs: excludedReplyAuthors(input))
        if acknowledgementAttempts[input.target]?.userID != input.user.id {
            acknowledgementAttempts[input.target] = .init(userID: input.user.id)
            acknowledgedReactions.removeValue(forKey: input.target)
        }
        for discussion in discussions where discussion.isResolvedForReview {
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
                guard input.configuration.selectedAssistant != nil, await canAutomate(input.configuration.assistant) else { throw ReReviewVerifier.VerificationError.unavailable }
                func currentCandidate(_ current: [GitLabMergeRequestDiscussion]) -> AuthorFeedbackPolicy.InformationalAcknowledgement? {
                    AuthorFeedbackPolicy.informationalAcknowledgements(discussions: current, assessment: assessment,
                        authorID: input.user.id, ignoredSuggestions: input.ignoredSuggestions, excludedReplyAuthorIDs: excludedReplyAuthors(input)).first { $0.discussionID == candidate.discussionID && $0.noteIDs == candidate.noteIDs }
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
                        guard isCurrent(input) else { throw CancellationError() }
                        let effectiveKind: AuthorFeedbackPolicy.AccountKind = settings.reviewParticipationPreferences.isDeclaredAutomation(
                            host: input.target.host, username: input.user.username, userID: reviewerID) ? .automation : kind
                        guard AuthorFeedbackPolicy.permitsInformationalReaction(verdict, accountKind: effectiveKind) else { continue }
                        let exists = try await glab.hasOwnThumbsUp(projectID: input.request.projectID, iid: input.request.iid,
                            noteID: noteID, host: input.target.host, userID: input.user.id)
                        if !exists {
                            threads = try await liveInformationalDiscussions(input)
                            guard currentCandidate(threads) != nil else { throw CancellationError() }
                            try await glab.addOwnThumbsUp(projectID: input.request.projectID, iid: input.request.iid,
                                noteID: noteID, host: input.target.host, userID: input.user.id) {
                                self.settings.automaticPublicWritesAllowed && self.isCurrent(input) && !input.readOnly
                                    && input.configuration.autoResolveAcceptedFeedback
                                    && self.acknowledgementAttempts[input.target]?.threadRevisions[rootID] == threadRevision
                            }
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
                    if threads.contains(where: { $0.id == candidate.discussionID && $0.isResolvedForReview }) {
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
                        discussionID: discussionID, host: input.target.host) {
                        self.settings.automaticPublicWritesAllowed && self.isCurrent(input) && !input.readOnly
                            && input.configuration.autoResolveAcceptedFeedback
                            && self.acknowledgementAttempts[input.target]?.threadRevisions[rootID] == threadRevision
                            && !self.settings.pendingCommentReviews.contains(input.target)
                    }
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
                if threads.contains(where: { $0.id == discussionID && $0.isResolvedForReview }) {
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
    func resolveAcceptedDiscussion(projectID: Int, iid: Int, discussionID: String, host: String, shouldProceed: @escaping @MainActor @Sendable () -> Bool) async throws -> GitLabMergeRequestDiscussion {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard !discussionID.isEmpty, let encoded = discussionID.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw GlabError.decoding("Missing discussion identity")
        }
        let result: GitLabMergeRequestDiscussion = try await mergeRequestWriteAPI(
            "/projects/\(projectID)/merge_requests/\(iid)/discussions/\(encoded)", host: host,
            arguments: ["--method", "PUT", "--field", "resolved=true"], shouldProceed: shouldProceed)
        guard result.id == discussionID, !result.notes.isEmpty,
              result.notes.allSatisfy({ $0.resolvable != true || $0.resolved == true }) else {
            throw GlabError.decoding("GitLab did not confirm discussion resolution")
        }
        return result
    }
}
