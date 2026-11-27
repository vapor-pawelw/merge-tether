import Foundation
import Observation

@MainActor
@Observable
final class MergeRequestAttentionMonitor {
    struct AIReplyDecision: Equatable, Sendable, Identifiable {
        let id: Int
        let authorID: Int
        let authorLabel: String
        let bodyDigest: String
        let excerpt: String

        init?(_ note: GitLabMergeRequestDiscussion.Note) {
            guard let id = note.id, id > 0, let author = note.author, author.id > 0, let body = note.body else { return nil }
            self.id = id
            authorID = author.id
            authorLabel = author.username ?? author.name ?? "#\(author.id)"
            bodyDigest = AICommentAssessmentStore.digest(body)
            excerpt = String(GlabService.redactWorkflowEvidence(body).prefix(180))
        }
    }

    enum AIReplyChoice { case reply, human }
    enum AIReplyDecisionResult: Equatable { case completed, draftStillPrivate, changed, failed, uncertain }

    /// Account-bound observations and checked workflow inputs for one merge request.
    struct Item: Identifiable, Sendable {
        typealias ID = GitLabMergeRequestID

        enum Section: Int {
            case open, unpublishedComments, draftMergeRequests
        }

        let id: ID
        var title: String
        var url: URL
        var lifecycleCompletionID: UUID?
        var requiresCommentReview = false
        var commentReviewSnapshot: CommentReviewSnapshot?
        /// The current user's unpublished drafts, shown in Ready for your OK.
        var drafts: [GitLabDraftNote] = []
        var draftCount: Int { drafts.count }
        /// Exact drafts covered by automatic publication, including the stability wait.
        var automaticDraftIDs: Set<Int> = []
        var aiReplyDecisions: [Int: [AIReplyDecision]] = [:]
        var automaticPublicationPolicy: AutomaticPublicationPolicy?
        /// Other participants of each draft reply thread, keyed by discussion ID.
        var replyRecipients: [String: [PersonIdentity]] = [:]
        var incomingReplyDiscussionIDs: Set<String>? = nil
        var awaitingRemoteVerification = false
        var draftProofRecoveryChecking = false
        var draftProofRecoveryReadFailure = false
        var draftProofRecoveryFailure: String?
        var draftProofRecoverySummary: String? = nil
        var rejectedDrafts: [DraftProofRecoveryCoordinator.RejectedDraft] = []
        /// Drafts remain accessible, but cannot be advertised as ready without current evidence.
        var requiresDiscussionRecheck = false
        var authorFeedbackStatus: AuthorFeedbackStatus?
        var aiOriginChecking = false
        /// Text actually read for this row; semantic results must match both this and its source head.
        var observedDiscussionFingerprint: String?
        var observedActiveDiscussionFingerprint: String?
        var observationSession: GitLabAccountSession?
        var discussionReadStartedAt: Date?
        var approvalObservation: ApprovalObservation = .unchecked
        var metApprovalThreshold: AutoApprovalThreshold?
        var remainingApprovalFindings: [ReviewVerdictStore.RemainingFinding] = []
        var catalogIssues: Set<CatalogIssue> = []
        var discussionObservation: DiscussionObservation = .resolved
        /// nil means the current reviewer states could not be read.
        var changeRequestReviewers: Set<String>?
        /// Current reviewer states matched to confirmed receipts on this head.
        var confirmedPendingReReviewers: Set<String> = []
        var approvalProgress: MergeRequestApprovalProgress?
        var manualMergeAvailable = false
        var pipelineHandoffPending = false
        var reReviewUnconfirmed = false
        var reReviewRequested = false
        var reReviewReadiness: ReReviewReadiness?
        var reReviewFingerprint: String?
        var reReviewFeedbackChecked = false
        var draftFromTodo = false
        var mergeRequest: GitLabMergeRequest?
        var isAuthored = false
        var feedback: [GitLabMergeRequestDiscussion.Note] = []
        /// Informational participation from complete discussions; nil means not loaded.
        var reviewingActivity: ReviewingActivity?
        var reviewingAssessment: ReviewingAssessment?
        var reviewingProgress: ReviewingProgress? {
            get { reviewingAssessment?.progress }
            set { reviewingAssessment = newValue.map { .init(progress: $0) } }
        }
        /// Canonical read-only stack/dependency metadata, separate from merge permissions.
        var dependencies: MergeRequestDependencySummary?

        /// Own replies observed in the discussions or confirmed by publication.
        var ownPublishedReplies: Set<DuplicateReplyDrafts.Reply>?
        /// Drafts that would repeat a reply already in their thread.
        var duplicateDraftIDs: Set<Int> { DuplicateReplyDrafts.ids(in: drafts, published: ownPublishedReplies ?? []) }
        var publishAllDrafts: [GitLabDraftNote] {
            let duplicates = duplicateDraftIDs
            return drafts.filter { $0.id.map(duplicates.contains) != true }
        }

        mutating func rememberPublishedReply(_ draft: GitLabDraftNote) {
            guard let thread = draft.discussionID, !thread.isEmpty else { return }
            let body = DuplicateReplyDrafts.normalized(draft.note)
            guard !body.isEmpty else { return }
            var replies = ownPublishedReplies ?? []
            replies.insert(.init(discussionID: thread, body: body))
            ownPublishedReplies = replies
        }

        var authoredRequest: GitLabMergeRequest? { isAuthored ? mergeRequest : nil }
        var canFinishCommentReview: Bool {
            requiresCommentReview && drafts.isEmpty && commentReviewSnapshot?.covers(mergeRequest) == true
        }

        func draftIDsHandledAutomatically(automation: AutomationSettings, target: MRAutomationScope.Target,
                                          assistantPreparing: Bool, publicationAutomatic: Bool = true,
                                          publicationPolicy: AutomaticPublicationPolicy? = nil) -> Set<Int> {
            let policy = publicationPolicy ?? automation.automaticPublicationPolicy
            guard automation.hasAutomaticPublicActionConsent, publicationAutomatic, assistantPreparing, policy.mode != .manual,
                  let request = mergeRequest, automaticPublicationPolicy == policy,
                  automation.scope.permits(request, host: target.host, username: target.username),
                  !isAuthored || automation.allowFollowUpPush else { return [] }
            return automaticDraftIDs
        }

        var observedEvidenceContext: EvidenceContext {
            .init(account: observationSession.map { .init(host: $0.host, username: $0.username) },
                  accountRevision: observationSession?.revision, mergeRequestID: id, head: mergeRequest?.sha,
                  target: mergeRequest?.evidenceTarget,
                  discussionContent: observedDiscussionFingerprint.map(DiscussionContentDigest.init),
                  activeDiscussionContent: observedActiveDiscussionFingerprint.map(DiscussionContentDigest.init),
                  semanticContext: mergeRequest?.semanticContextDigest)
        }

        /// A partial read cannot bind existing raw feedback to a newly observed conversation.
        mutating func invalidateChangedDiscussionSnapshot(head: String?, fingerprint: String?, semanticContextFingerprint: String? = nil) {
            let read = EvidenceContext(head: head, discussionContent: fingerprint.map(DiscussionContentDigest.init),
                                       semanticContext: semanticContextFingerprint.map(SemanticContextDigest.init))
            let observed = observedEvidenceContext
            guard read.binds(to: observed, policy: .feedbackProgress),
                  read.binds(to: observed, policy: .discussionContent) else {
                observedDiscussionFingerprint = nil
                observedActiveDiscussionFingerprint = nil
                discussionReadStartedAt = nil
                return
            }
        }

        func canOfferMerge(using status: AuthoredMergeRequestStatus) -> Bool {
            let openMergeBlockers: Set<Status.Blocker> = [.discussion, .feedback, .changesRequested, .conflict, .failedPipeline, .pipelineHandoff]
            return status.blockers.isEmpty && status.request.isReadyForMergeChecks
                && status.request.projectID == id.projectID && status.request.iid == id.iid
                && status.request.webURL == mergeRequest?.webURL && status.request.sha == mergeRequest?.sha
                && !requiresCommentReview && drafts.isEmpty && self.status.blockers.isDisjoint(with: openMergeBlockers)
                && mergeRequest?.state == .opened
                && mergeRequest?.draft == false && mergeRequest?.detailedMergeStatus == .mergeable
                && mergeRequest?.hasMergeConflict == false && mergeRequest?.blockingDiscussionsResolved != false
                && (mergeRequest?.headPipeline == nil || mergeRequest?.headPipeline?.status == .success)
        }

        var status: Status { .init(evidence: self) }
        var needsDiscussion: Bool { status.blockers.contains(.discussion) }
        var hasOtherUnresolvedDiscussions: Bool { discussionObservation == .unresolvedOther }
        var hasConflict: Bool { status.blockers.contains(.conflict) }
        var needsChanges: Bool { status.blockers.contains(.changesRequested) }
        var needsMerge: Bool { status.blockers.contains(.merge) }
        var failedPipeline: Bool { status.blockers.contains(.failedPipeline) }
        var needsPipelineHandoff: Bool { status.blockers.contains(.pipelineHandoff) }
        var canApprove: Bool { status.approval == .manual || status.approval == .waitingForReadiness }
        var autoApproveReady: Bool { status.approval == .automatic }
        var approvalWaitingForReadiness: Bool { status.approval == .waitingForReadiness }
        var canConfirmReReview: Bool { status.confirmations.contains(.reReview) }
        var needsAttention: Bool { status.needsAttention }
        var needsConfirmation: Bool { status.needsConfirmation }
        var section: Section { status.section }

        static func ordered(_ items: [Self], draftsLast: Bool = true) -> [Self] {
            items.map { ($0, $0.mergeOrder(using: $0.status, draftsLast: draftsLast)) }
                .sorted { $0.1 < $1.1 }
                .map(\.0)
        }

        func mergeOrder(using status: Status, draftsLast: Bool = true) -> (Int, Int, Int, String, Int, Int) {
            let order = mergeReadiness(using: status)
            let section = draftsLast ? status.section : status.openSection
            return (section.rawValue, order.priority, order.blockers, title, id.projectID, id.iid)
        }

        var isCloseToMerge: Bool { isCloseToMerge(using: status, feedbackRemaining: !feedback.isEmpty) }

        func isCloseToMerge(using status: Status, feedbackRemaining: Bool) -> Bool {
            guard let request = mergeRequest, request.isOpen, request.draft == false,
                  !request.hasQueuedMerge, drafts.isEmpty, !requiresCommentReview,
                  !requiresDiscussionRecheck, !feedbackRemaining,
                  approvalProgress.map({ $0.requirementsSatisfied ?? ($0.completed >= $0.required) }) != false,
                  dependencies.map({ $0.predecessors.isEmpty && $0.issues.isEmpty }) != false else { return false }
            return mergeReadiness(using: status).priority == 0
        }

        private func mergeReadiness(using attention: Status) -> (priority: Int, blockers: Int) {
            guard let mergeRequest, let mergeStatus = mergeRequest.detailedMergeStatus else { return (2, 0) }
            let status = AuthoredMergeRequestStatus(
                request: mergeRequest, approvals: nil, discussionsResolved: mergeRequest.blockingDiscussionsResolved,
                projectRequiresResolvedDiscussions: nil, autoMergeEnabled: false, dependencyReadiness: .notChecked
            )
            // The list endpoint supplies merge status but does not verify approval rules.
            var blockers = Set(status.blockers).subtracting([.unknown, .draft])
            if attention.blockers.contains(.discussion) { blockers.insert(.discussions) }
            if attention.blockers.contains(.conflict) { blockers.insert(.conflicts) }
            if attention.blockers.contains(.changesRequested) { blockers.insert(.changesRequested) }
            if !attention.blockers.isDisjoint(with: [.failedPipeline, .pipelineHandoff]) { blockers.insert(.pipeline) }
            if mergeStatus == .mergeable && blockers.isEmpty { return (0, 0) }
            return (blockers.contains(.checking) ? 2 : 1, blockers.count)
        }
    }

    enum ConfirmationState: Equatable, Sendable {
        case publishing, approving, removingApproval, deleting, finishingCommentReview, failed, changed, discussionResolved

        var isBusy: Bool {
            switch self {
            case .publishing, .approving, .removingApproval, .deleting, .finishingCommentReview: true
            case .failed, .changed, .discussionResolved: false
            }
        }

        var failureMessage: LocalizedStringResource? {
            switch self {
            case .failed: .Menu.menuConfirmFailed
            case .changed: .Menu.menuConfirmChanged
            case .discussionResolved: .CommentReview.commentReviewDiscussionResolved
            case .publishing, .approving, .removingApproval, .deleting, .finishingCommentReview: nil
            }
        }
    }

    private var attentionRecords: [Item.ID: MRAttentionRecord] = [:]
    private var attentionRecordsRevision: UInt64?
    private var attentionCandidateIDs: Set<Item.ID> = []
    private var catalogIDs: Set<Item.ID> = []
    var items: [Item] {
        guard attentionRecordsRevision == glab.accountRevision else { return [] }
        return Item.ordered(attentionCandidateIDs.compactMap { attentionRecords[$0]?.evidence }.filter(\.needsAttention))
    }
    private(set) var confirmationStates: [Item.ID: ConfirmationState] = [:]
    private var user: GitLabAuthenticatedUser?
    /// Drafts seen on the previous poll, so automatic publishing waits until they stop changing.
    private var previousDrafts: [Item.ID: [GitLabDraftNote]] = [:]
    /// Drafts already published; a poll that started earlier may still report them.
    private var publishedDrafts: [Item.ID: [GitLabDraftNote]] = [:]
    /// Continuations may exclude only publications tied to this exact reviewed context and account session.
    private struct ManualPublicationProgress {
        let request: GitLabMergeRequest
        let snapshot: CommentReviewSnapshot
        let accountRevision: UInt64
        var publicDrafts: [GitLabDraftNote]
    }
    private var manualPublicationProgress: [Item.ID: ManualPublicationProgress] = [:]
    /// Heads approved here, until GitLab's reviewer state catches up.
    private var approvedHeads: [Item.ID: String] = [:]
    /// Commits GitLab refused to auto-approve; retried only after a new commit or a manual approval.
    private var failedApprovalHeads: [Item.ID: String] = [:]
    private struct ApprovalReadContext: Equatable {
        let revision: UInt64
        let head: String
        let discussionFingerprint: String?
        let semanticContext: String?
        let configuration: AutomationSettings?
    }
    @ObservationIgnored private var approvalReadFailures: [Item.ID: (context: ApprovalReadContext, retryAfter: Date)] = [:]
    private var openItems: [Item] {
        guard attentionRecordsRevision == glab.accountRevision else { return [] }
        return Item.ordered(catalogIDs.compactMap { attentionRecords[$0]?.catalogItem })
    }
    @ObservationIgnored private let dependencyLoader = MRDependencyLoader()
    @ObservationIgnored private var dependencyTask: Task<Void, Never>?
    private var dependencyPresentation = MRDependencyPresentationCache()
    /// Historical chats remain recorded after their MR closes. Recheck them only
    /// after an open listing makes them current again, or after an account change.
    private var terminalCatalogRequests: Set<Item.ID> = []
    @ObservationIgnored private var runCleanupAttempts: [MRAutomationScope.Target: (date: Date, open: Bool)] = [:]
    @ObservationIgnored private var runCleanupInProgress: Set<MRAutomationScope.Target> = []
    @ObservationIgnored private var latestOpenForRunCleanup: [MRAutomationScope.Target: Date] = [:]
    private(set) var isLoading = false
    private struct AutomaticResumeKey: Hashable {
        let target: MRAutomationScope.Target
        let action: MRAutomaticAction
        let revision: UInt64
    }
    @ObservationIgnored private var automaticResumeTasks: [AutomaticResumeKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var automaticActionIdleWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var hasError = false
    /// Initial catalog readiness is sticky within this account session. Later
    /// metadata or transport failures retain the last authoritative catalog.
    private var syncedCatalogRevision: UInt64?
    var hasSyncedCurrentCatalog: Bool { syncedCatalogRevision == glab.accountRevision && account.map(isCurrent) == true }
    private var hasOwnListing = false
    var hasCurrentOwnListing: Bool { hasOwnListing && account.map(isCurrent) == true }
    private let glab: GlabService
    private let settings: SettingsManager?
    private var commentOriginRevision: UInt64 = 0

    func invalidateCommentOriginPublication() {
        commentOriginRevision &+= 1
    }
    @ObservationIgnored private(set) lazy var draftRegeneration = DraftRegenerationCoordinator(
        glab: glab, settings: settings, provenanceDirectory: provenanceDirectory,
        candidates: { [weak self] in
            guard let self else { return [] }
            return openItems.compactMap { item in
                guard !item.drafts.isEmpty, let request = item.mergeRequest else { return nil }
                return .init(request: request, drafts: item.drafts)
            }
        }, isBusy: { [weak self] id in
            guard let self, let account, isCurrent(account) else { return true }
            return confirmationStates[id]?.isBusy == true || hasActiveWorker(for: id, account: account)
        }, onUpdate: { [weak self] id, previous, replacement in
            self?.didRegenerateDraft(previous, replacement: replacement, in: id)
        }
    )
    private let verdictDirectory: URL
    let aiAssessmentDirectory: URL
    private let followUpDirectory: URL
    private let provenanceDirectory: URL
    private let authorFeedbackAssessmentDirectory: URL?
    private let runStorage: InstallationStorage
    private var verifiedRemoteFiles: [String: [FollowUpVerification.FileEvidence]] = [:]
    private var isRefreshingDrafts = false
    @ObservationIgnored private let pendingDraftPolling = PendingDraftPolling()
    private var workerAuditRetry: Task<Void, Never>?
    private let reReviewCoordinator: ReReviewCoordinator?
    private let canAutomate: @MainActor (AutomationAssistant) async -> Bool
    private let approvalReadClock: ReadOnlyAssessmentRetry.Clock
    private let approvalReadWait: ReadOnlyAssessmentRetry.Wait
    /// Called after MergeTether approved a merge request on its own.
    var onRefreshed: (() -> Void)?
    var onReviewAssignmentsObserved: ((ReviewAssignmentLedger, String, String) -> Void)?
    var onIssueCatalogRefreshed: (([GitLabMergeRequest]) -> Void)?
    var onCommentReviewFinished: ((Item.ID) -> Void)?
    var onDisplayMetadataObserved: ((GitLabMergeRequest, MRAutomationScope.Target, UInt64, Date) -> Void)?
    var onAutomationEligibilityObserved: (() -> Void)?
    private var pendingRefresh: (account: Account, todos: [Todo], revision: UInt64)?
    private var account: Account?
    private var accountGeneration = 0
    private var refreshGeneration = 0
    private var recentTodos: [Item] = []
    private var latestTodoSnapshot: (account: Account, revision: UInt64, todos: [Todo])?
    let authorFeedbackCoordinator: AuthorFeedbackCoordinator?
    private let actionPromptGate: AutomaticActionPromptGate
    private let verifiedReplyDrafts: VerifiedAuthorReplyDrafts?
    let aiOriginCoordinator: AICommentOriginCoordinator
    let displayAIOriginCoordinator: AICommentDisplayCoordinator?
    let draftProofRecoveryCoordinator: DraftProofRecoveryCoordinator?
    private var feedbackNeedsRefresh = false
    var onAuthorFeedbackNeedsWork: ((GitLabMergeRequest, Set<Int>, String, AuthorFeedbackResidual?) async -> Void)?
    var onAuthorFeedbackChecked: (() -> Void)?
    var onScopedAuthorFeedbackChecked: ((MRAutomationScope.Target, UInt64) -> Void)?

    private typealias Account = GitLabAccountIdentity
    @MainActor private final class OriginReadContexts {
        var values: [MRAutomationScope.Target: (request: GitLabMergeRequest, revision: UInt64)] = [:]
    }

    init(
        glab: GlabService, settings: SettingsManager? = nil,
        verdictDirectory: URL = ReviewVerdictStore.directory,
        aiAssessmentDirectory: URL = AICommentAssessmentStore.directory,
        followUpDirectory: URL = FollowUpVerificationStore.directory,
        provenanceDirectory: URL = AICommentProvenanceStore.directory,
        authorFeedbackAssessmentDirectory: URL? = nil,
        runStorage: InstallationStorage = .current,
        canAutomate: @escaping @MainActor (AutomationAssistant) async -> Bool = {
            await AssistantCLI.detect($0).isReady
        },
        approvalReadClock: @escaping ReadOnlyAssessmentRetry.Clock = { Date() },
        approvalReadWait: @escaping ReadOnlyAssessmentRetry.Wait = ReadOnlyAssessmentRetry.wait,
        verifyActionPrompt: @escaping AutomaticActionPromptVerifier.Verify = AutomaticActionPromptVerifier.verify,
        verifyReReview: ReReviewCoordinator.Verify? = nil,
        verifyAuthorFeedback: ReReviewCoordinator.Verify? = nil,
        verificationExecutableResolver: ReReviewVerifier.ExecutableResolver? = nil,
        verifyDraftProofRecovery: @escaping DraftProofRecoveryCoordinator.Verify = {
            try await DraftProofRecoveryVerifier.verify($0, assistant: $1, model: $2)
        },
        assessAIOrigin: @escaping AICommentOriginCoordinator.Assess = {
            try await AICommentOriginAssessor.verify(target: $0, notes: $1, assistant: $2, model: $3, thinking: $4, criteriaOverride: $5)
        }
    ) {
        self.glab = glab
        if let settings { glab.ownershipSettings = settings }
        self.settings = settings
        self.verdictDirectory = verdictDirectory
        self.aiAssessmentDirectory = aiAssessmentDirectory
        self.followUpDirectory = followUpDirectory
        self.provenanceDirectory = provenanceDirectory
        self.authorFeedbackAssessmentDirectory = authorFeedbackAssessmentDirectory
        self.runStorage = runStorage
        self.canAutomate = canAutomate
        self.actionPromptGate = AutomaticActionPromptGate(verify: verifyActionPrompt)
        self.approvalReadClock = approvalReadClock
        self.approvalReadWait = approvalReadWait
        let originReadContexts = OriginReadContexts()
        let publicationOrigins = AICommentOriginCoordinator(directory: aiAssessmentDirectory, assess: assessAIOrigin,
            fetchCurrent: { target in
                let revision = glab.accountRevision
                guard let iid = target.iid, glab.resolvedHost == target.host,
                      glab.currentUsername == target.username else { throw CancellationError() }
                _ = try await glab.fetchAuthenticatedUser(host: target.host, expectedUsername: target.username,
                                                          expectedUserID: target.userID)
                let request = try await glab.fetchMergeRequest(projectID: target.projectID, iid: iid, host: target.host)
                guard request.isOpen, request.webURL.isGitLabMergeRequest(host: target.host, iid: iid),
                      settings?.automation.scope.permits(request, host: target.host, username: target.username) == true
                else { throw CancellationError() }
                let notes = try await glab.fetchMergeRequestDiscussions(projectID: target.projectID, iid: iid, host: target.host).flatMap(\.notes)
                if glab.accountRevision == revision, glab.resolvedHost == target.host, glab.currentUsername == target.username {
                    originReadContexts.values[target] = (request, revision)
                }
                return notes
            }, isCurrent: { target, assistant, model, thinking in
                let projected = target.forAccount(.init(host: target.host, username: target.username))
                guard let settings, glab.resolvedHost == target.host, glab.currentUsername == target.username,
                      glab.authenticatedUserID == target.userID,
                      settings.automation.hasAutomaticActionConsent,
                      settings.automation.selectedAssistant == assistant, settings.publicationPolicy(for: projected).requiresAI,
                      settings.automation.scope.resolve(projected).active else { return false }
                let configured = assistant == .codex ? settings.automation.codexVerificationModel.rawValue
                    : settings.automation.claudeVerificationModel.rawValue
                return model == configured && settings.automation.verificationThinking == thinking
            }, criteriaOverride: { settings?.automation.aiCommentCriteriaOverride },
            legacyUsernames: { settings?.unambiguousLegacyUsernames(for: $0) ?? [$0.username] })
        self.aiOriginCoordinator = publicationOrigins
        self.displayAIOriginCoordinator = settings.map { settings in
            AICommentDisplayCoordinator(glab: glab, settings: settings, assessmentDirectory: aiAssessmentDirectory,
                canAutomate: canAutomate, publicationIsChecking: { work in
                    publicationOrigins.isChecking(work: work) || settings.assistantHandoffs.contains {
                        $0.key.work == work && $0.key.username == glab.currentUsername && $0.execution?.state.isActive == true
                    }
                }, assess: assessAIOrigin)
        }
        self.draftProofRecoveryCoordinator = settings.map { settings in
            DraftProofRecoveryCoordinator(settings: settings, directory: followUpDirectory, verdictDirectory: verdictDirectory, canAutomate: canAutomate,
                fetch: { snapshot in
                    let work = snapshot.work
                    guard glab.resolvedHost == work.host, glab.currentUsername == snapshot.user.username else { throw CancellationError() }
                    async let user = glab.fetchAuthenticatedUser(host: work.host, expectedUsername: snapshot.user.username)
                    async let request = glab.fetchMergeRequest(projectID: work.projectID, iid: work.iid, host: work.host)
                    async let discussions = glab.fetchMergeRequestDiscussions(projectID: work.projectID, iid: work.iid, host: work.host)
                    async let drafts = glab.fetchOwnDraftNotes(projectID: work.projectID, iid: work.iid, host: work.host, userID: snapshot.user.id)
                    let (liveUser, liveRequest, liveDiscussions, liveDrafts) = try await (user, request, discussions, drafts)
                    guard let sourceProjectID = liveRequest.sourceProjectID else { throw CancellationError() }
                    let branchHead = try await glab.fetchBranchHeadSHA(projectID: sourceProjectID, branch: liveRequest.sourceBranch, host: work.host)
                    return .init(request: liveRequest, discussions: liveDiscussions, drafts: liveDrafts,
                        user: liveUser, host: work.host, branchHead: branchHead)
                }, hashFile: { snapshot, file in
                    guard let sourceProjectID = snapshot.request.sourceProjectID, let head = snapshot.request.sha else { throw CancellationError() }
                    return try await glab.fetchFileSHA256(projectID: sourceProjectID, path: file.path, ref: head, host: snapshot.host)
                }, verify: verifyDraftProofRecovery, accountIsCurrent: {
                    glab.resolvedHost == $0.host && glab.currentUsername == $0.user.username
                })
        }
        let reviewVerifier: ReReviewCoordinator.Verify = verifyReReview ?? {
            try await ReReviewVerifier.verify($0, assistant: $1, model: $2, executableResolver: verificationExecutableResolver)
        }
        let feedbackVerifier: ReReviewCoordinator.Verify = verifyAuthorFeedback ?? verifyReReview ?? {
            try await ReReviewVerifier.verifySingleAttempt($0, assistant: $1, model: $2, executableResolver: verificationExecutableResolver)
        }
        self.authorFeedbackCoordinator = settings.map { AuthorFeedbackCoordinator(settings: $0, glab: glab,
            canAutomate: canAutomate, verify: feedbackVerifier, assessmentDirectory: authorFeedbackAssessmentDirectory) }
        self.verifiedReplyDrafts = settings.map { VerifiedAuthorReplyDrafts(settings: $0, glab: glab, directory: followUpDirectory) }
        let feedbackCoordinator = self.authorFeedbackCoordinator
        self.reReviewCoordinator = settings.map { ReReviewCoordinator(settings: $0, glab: glab,
            canAutomate: canAutomate, verify: reviewVerifier,
            authorFeedbackStatus: { request in
                feedbackCoordinator?.status(projectID: request.projectID, iid: request.iid)
            }, authorFeedbackAssessment: { request, fingerprint in
                feedbackCoordinator?.assessment(for: request, fingerprint: fingerprint)
            }, authorFeedbackAssessmentInFlight: { request, fingerprint, activeFingerprint in
                feedbackCoordinator?.assessmentInFlight(for: request, fingerprint: fingerprint, activeFingerprint: activeFingerprint) == true
            }) }
        reReviewCoordinator?.onChange = { [weak self] context, unanswered in
            guard let self, let account, isCurrent(account), account.host == context.host,
                  account.username == context.username, glab.accountRevision == context.revision else { return }
            updateReReviewPresentation(.init(projectID: context.projectID, iid: context.iid), unanswered: unanswered)
        }
        reReviewCoordinator?.onRefreshRequested = { [weak self] context, user in
            guard let self, let account, isCurrent(account), account.host == context.host,
                  account.username == context.username, glab.accountRevision == context.revision else { return }
            await refreshReReviewAfterPublication(.init(projectID: context.projectID, iid: context.iid), account: account, user: user)
        }
        draftProofRecoveryCoordinator?.onNeedsRepair = { snapshot, origin, assessment in
            guard let settings else { return nil }
            return try await DraftReplyRepair.launch(snapshot: snapshot, origin: origin, assessment: assessment,
                settings: settings, glab: glab, directory: followUpDirectory)
        }
        authorFeedbackCoordinator?.onNeedsWork = { [weak self] request, notes, fingerprint, residual in
            await self?.onAuthorFeedbackNeedsWork?(request, notes, fingerprint, residual)
        }
        authorFeedbackCoordinator?.prepareVerifiedReplies = { [weak self] request, discussions, assessment, notes, user, host, proceed in
            guard let self, let account, isCurrent(account), account.host == host, account.username == user.username,
                  let verifiedReplyDrafts else { return [] }
            let id = request.mergeRequestID
            return await verifiedReplyDrafts.prepare(request: request, discussions: discussions, assessment: assessment,
                owedNoteIDs: notes, user: user, host: host) { [weak self] in
                    guard let self else { return false }
                    return proceed() && isCurrent(account) && !hasActiveWorker(for: id, account: account) && !isConfirming(id)
                }
        }
        authorFeedbackCoordinator?.onRemoteChange = { [weak self] in
            guard let self else { return }
            onAuthorFeedbackChecked?()
            requestFeedbackRefresh()
        }
        authorFeedbackCoordinator?.onScopedChange = { [weak self] request, target, revision, discussions in
            guard let self, let account, isCurrent(account), account.host == target.host,
                  account.username == target.username, glab.accountRevision == revision,
                  let user else { return }
            if let discussions {
                let id = request.mergeRequestID
                updateItem(id, introducesAttention: false) { item in
                    guard MRAttentionRecord.sameContext(item.mergeRequest, request),
                          item.observedEvidenceContext.discussionContent == ReviewVerdict.discussionContentDigest(discussions) else { return }
                    Self.applyDiscussionFeedback(to: &item, discussions: discussions, userID: user.id)
                    applyReReviewPresentation(&item, unanswered: ReReviewFeedback(
                        discussions: discussions, authorID: user.id).hasUnansweredFeedback)
                }
            }
            onScopedAuthorFeedbackChecked?(target, revision)
            onRefreshed?()
        }
        draftProofRecoveryCoordinator?.onChange = { [weak self] in
            self?.requestFeedbackRefresh()
        }
        aiOriginCoordinator.onPersisted = { [weak self] target, notes, assessment in
            guard let context = originReadContexts.values.removeValue(forKey: target) else { return }
            let projected = target.forAccount(.init(host: target.host, username: target.username))
            self?.displayAIOriginCoordinator?.notifyPersistedOrigins(target: projected, request: context.request,
                accountRevision: context.revision, notes: notes, assessment: assessment)
        }
        aiOriginCoordinator.onChange = { [weak self] in
            guard let self, let account, isCurrent(account) else { return }
            displayAIOriginCoordinator?.resume()
            requestFeedbackRefresh()
        }
    }

    private func permitsAssistantAutomation(for account: Account) async -> Bool {
        guard let settings, isCurrent(account), !Task.isCancelled else { return false }
        let configuration = settings.automation
        guard let assistant = configuration.selectedAssistant else { return false }
        let generation = accountGeneration
        return await canAutomate(assistant) && !Task.isCancelled
            && generation == accountGeneration && isCurrent(account) && settings.automation == configuration
    }

    var isVerifyingReReview: Bool { reReviewCoordinator?.isVerifying == true }
    var isAssessingAIOrigins: Bool {
        guard let account, isCurrent(account) else { return false }
        return (items + openItems).contains {
            aiOriginCoordinator.isChecking(work: .init(host: account.host, projectID: $0.id.projectID, iid: $0.id.iid))
        }
    }

    var currentItems: [Item] {
        guard let account, isCurrent(account) else { return [] }
        return items.map(enrichObservation)
    }

    var currentOpenItems: [Item] {
        guard let account, isCurrent(account) else { return [] }
        return openItems.map(enrichObservation)
    }

    /// One account/revision-bound value read for the display projector; no additional owner or epoch.
    struct PresentationSnapshot {
        let host: String
        let username: String
        let revision: UInt64
        let evidence: [Item]
        let attention: [Item]
        let catalog: [Item]
    }

    var presentationSnapshot: PresentationSnapshot? {
        guard let account, isCurrent(account), attentionRecordsRevision == glab.accountRevision else { return nil }
        let evidence = attentionRecords.mapValues { enrichObservation($0.evidence) }
        let candidates = attentionCandidateIDs.compactMap { evidence[$0]?.presentingVerifiedAuthorFeedback() }
        return .init(host: account.host, username: account.username, revision: glab.accountRevision,
            evidence: Array(evidence.values),
            attention: ItemPresentation.ordered(candidates.filter(\.needsAttention)).map(\.evidence),
            catalog: openItems.map(enrichObservation))
    }

    private func enrichObservation(_ original: Item) -> Item {
        var item = original
        item.dependencies = item.mergeRequest.flatMap { request in
            guard let account, isCurrent(account) else { return nil }
            return dependencyPresentation.summary(for: request,
                account: .init(host: account.host, username: account.username, revision: glab.accountRevision))
        }
        let status = authorFeedbackCoordinator?.status(projectID: item.id.projectID, iid: item.id.iid)
        item.authorFeedbackStatus = status
        if let account, isCurrent(account) {
            let work = AssistantAutomationRunner.MergeRequestWork(host: account.host, projectID: item.id.projectID, iid: item.id.iid)
            item.aiOriginChecking = aiOriginCoordinator.isChecking(work: work)
            let recoveryCurrent = item.draftCount > 0 && item.authoredRequest.map { request in
                guard let settings, let fingerprint = item.observedDiscussionFingerprint else { return false }
                return draftProofRecoveryCoordinator?.presentationIsCurrent(request: request, host: account.host,
                    fingerprint: fingerprint, configuration: settings.automation) == true
            } == true
            item.draftProofRecoveryChecking = recoveryCurrent && draftProofRecoveryCoordinator?.isChecking(work: work) == true
            item.draftProofRecoveryReadFailure = recoveryCurrent && draftProofRecoveryCoordinator?.isReadOnlyFailure(work: work) == true
            item.draftProofRecoveryFailure = recoveryCurrent ? draftProofRecoveryCoordinator?.failure(work: work) : nil
            item.draftProofRecoverySummary = recoveryCurrent ? draftProofRecoveryCoordinator?.summary(work: work) : nil
            item.rejectedDrafts = recoveryCurrent
                ? draftProofRecoveryCoordinator?.rejectedDrafts(work: work, drafts: item.drafts) ?? [] : []
            if item.draftProofRecoveryChecking, let request = item.authoredRequest,
               let fingerprint = item.observedDiscussionFingerprint {
                item.authorFeedbackStatus = .init(head: request.sha ?? "", fingerprint: fingerprint,
                    semanticContextFingerprint: request.semanticContextFingerprint,
                    readOnlyReconciliation: status?.phase == .checking && status?.readOnlyReconciliation == true, phase: .checking,
                    pendingDraftCount: item.draftCount)
            }
        }
        return item
    }

    func retryDraftProofRecovery(_ id: Item.ID) {
        guard let account, isCurrent(account) else { return }
        draftProofRecoveryCoordinator?.retry(work: .init(host: account.host, projectID: id.projectID, iid: id.iid), username: account.username)
        refresh(host: account.host, username: account.username, todos: [])
    }

    /// Identifies observed approvals so unchanged author feedback is not reassessed on every refresh.
    nonisolated static func approvalRevision(_ progress: MergeRequestApprovalProgress) -> String {
        "\(progress.completed)/\(progress.required):" + Set(progress.approvedBy.map(\.id)).sorted().map(String.init).joined(separator: ",")
    }

    /// Emergency reset: forget earlier feedback passes and verify every comment against the current MR from scratch.
    func resetAuthorFeedbackAssessment(_ id: Item.ID) {
        authorFeedbackCoordinator?.resetAssessment(projectID: id.projectID, iid: id.iid)
        guard let account, isCurrent(account) else { return }
        refresh(host: account.host, username: account.username, todos: [])
    }

    func retryAuthorFeedback(_ id: Item.ID) {
        authorFeedbackCoordinator?.invalidate(projectID: id.projectID, iid: id.iid)
        guard let account, isCurrent(account) else { return }
        refresh(host: account.host, username: account.username, todos: [])
    }

    func refreshFeedbackDecision(_ id: Item.ID, target: MRAutomationScope.Target, revision: UInt64) async {
        let account = Account(host: target.host, username: target.username)
        while isLoading || isRefreshingDrafts || isConfirming(id) {
            await withCheckedContinuation { automaticActionIdleWaiters.append($0) }
        }
        guard !Task.isCancelled, isCurrent(account), self.account == account,
              glab.accountRevision == revision, attentionRecordsRevision == revision else { return }
        let todos = latestTodoSnapshot.flatMap {
            $0.account == account && $0.revision == revision ? $0.todos : nil
        } ?? []
        authorFeedbackCoordinator?.invalidate(projectID: id.projectID, iid: id.iid)
        isLoading = true
        defer { finishRefresh(account, revision: revision) }
        do {
            try await poll(account, todos: todos, revision: revision, feedbackDecision: id)
        } catch {
            Log.monitor.error("Could not refresh feedback decision: \(String(describing: error), privacy: .private)")
        }
    }

    func refresh(host: String, username: String, todos: [Todo]) {
        let account = Account(host: host, username: username)
        guard isCurrent(account) else { return }
        let revision = glab.accountRevision
        latestTodoSnapshot = (account, revision, todos)
        if isLoading {
            pendingRefresh = (account, todos, revision)
            return
        }
        if self.account != account { resetAccountState(for: account) }
        refreshGeneration += 1
        isLoading = true
        Task {
            defer { finishRefresh(account, revision: revision) }
            do {
                try await poll(account, todos: todos, revision: revision)
            } catch {
                if isCurrent(account, revision: revision) {
                    hasError = true
                    for id in attentionRecords.keys { attentionRecords[id]?.evidence.reviewingProgress = nil }
                    clearApprovalProgress()
                }
            }
        }
    }

    private func resetAccountState(for account: Account) {
        draftRegeneration.cancelAndClear()
        dependencyTask?.cancel()
        dependencyPresentation = .init()
        authorFeedbackCoordinator?.cancel()
        draftProofRecoveryCoordinator?.cancel()
        aiOriginCoordinator.cancel()
        accountGeneration += 1
        attentionRecords = [:]
        attentionRecordsRevision = nil
        attentionCandidateIDs = []
        catalogIDs = []
        terminalCatalogRequests = []
        runCleanupAttempts = [:]
        latestOpenForRunCleanup = [:]
        recentTodos = []
        hasError = false
        hasOwnListing = false
        syncedCatalogRevision = nil
        confirmationStates = [:]
        previousDrafts = [:]
        publishedDrafts = [:]
        manualPublicationProgress = [:]
        approvedHeads = [:]
        failedApprovalHeads = [:]
        approvalReadFailures = [:]
        verifiedRemoteFiles = [:]
        user = nil
        self.account = account
        displayAIOriginCoordinator?.cancel()
        reReviewCoordinator?.reset()
    }

    private func isCurrent(_ account: Account) -> Bool {
        EvidenceContext(account: account).binds(to: glab.evidenceAccountContext, policy: .accountIdentity)
    }

    private func isCurrent(_ account: Account, revision: UInt64) -> Bool {
        EvidenceContext(account: account, accountRevision: revision)
            .binds(to: glab.evidenceAccountContext, policy: .accountSession)
    }

    private func requestFeedbackRefresh() {
        guard let account, isCurrent(account), let snapshot = latestTodoSnapshot,
              snapshot.account == account, snapshot.revision == glab.accountRevision else { return }
        if isLoading { feedbackNeedsRefresh = true }
        else { refresh(host: account.host, username: account.username, todos: snapshot.todos) }
    }

    private func finishRefresh(_ account: Account, revision: UInt64) {
        isLoading = false
        onRefreshed?()
        let pending = pendingRefresh
        pendingRefresh = nil
        let needsRefresh = feedbackNeedsRefresh
        feedbackNeedsRefresh = false
        if let pending, pending.revision == glab.accountRevision, isCurrent(pending.account) {
            refresh(host: pending.account.host, username: pending.account.username, todos: pending.todos)
        } else if needsRefresh, isCurrent(account), let snapshot = latestTodoSnapshot,
                  snapshot.account == account, snapshot.revision == revision, revision == glab.accountRevision {
            refresh(host: account.host, username: account.username, todos: snapshot.todos)
        }
        signalAutomaticActionIdle()
    }

    private func clearApprovalProgress() {
        for id in attentionRecords.keys { attentionRecords[id]?.clearApprovalProgress() }
    }

    /// A policy restoration reads current evidence and enters the automatic executor only.
    /// It deliberately does not reset verdicts, delivery proof or failed coding attempts.
    func resumeAutomaticAction(_ action: MRAutomaticAction, for target: MRAutomationScope.Target) async {
        let account = Account(host: target.host, username: target.username)
        guard action != .merge, target.iid != nil, isCurrent(account), self.account == account,
              settings?.actionIsAutomatic(action, for: target) == true else { return }
        let key = AutomaticResumeKey(target: target, action: action, revision: glab.accountRevision)
        if let task = automaticResumeTasks[key] { await task.value; return }
        let task = Task { await self.performAutomaticResume(key, account: account) }
        automaticResumeTasks[key] = task
        await task.value
    }

    private func performAutomaticResume(_ key: AutomaticResumeKey, account: Account) async {
        defer { automaticResumeTasks[key] = nil }
        let id = Item.ID(projectID: key.target.projectID, iid: key.target.iid ?? 0)
        while isLoading || isRefreshingDrafts || isConfirming(id) {
            await withCheckedContinuation { automaticActionIdleWaiters.append($0) }
        }
        guard isCurrent(account), self.account == account, glab.accountRevision == key.revision,
              settings?.actionIsAutomatic(key.action, for: key.target) == true else { return }
        refreshGeneration += 1
        isLoading = true
        defer { finishRefresh(account, revision: key.revision) }
        do {
            let todos = latestTodoSnapshot.flatMap {
                $0.account == account && $0.revision == key.revision ? $0.todos : nil
            } ?? []
            try await poll(account, todos: todos, revision: key.revision, automaticResume: (id, key.action))
        } catch {
            if isCurrent(account, revision: key.revision) {
                hasError = true
                clearApprovalProgress()
            }
        }
    }

    private func signalAutomaticActionIdle() {
        let waiting = automaticActionIdleWaiters
        automaticActionIdleWaiters = []
        for continuation in waiting { continuation.resume() }
    }

    /// Called only with the response to a single-MR read. Listing omissions and
    /// persisted terminal metadata cannot authorize cleanup.
    @discardableResult
    func retireConfirmedLifecycle(_ request: GitLabMergeRequest, host: String, user: GitLabAuthenticatedUser,
                                  revision: UInt64, readStartedAt: Date) async -> Bool {
        let account = user.account(on: host)
        let target = MRAutomationScope.Target.mergeRequest(host: host, username: user.username,
            projectID: request.projectID, iid: request.iid)
        guard let settings, MergeRequestFinishedState(request) != nil,
              isCurrent(account, revision: revision), !Task.isCancelled,
              settings.mrLifecycleLedger.accepts(request, for: target, observedAt: readStartedAt),
              (try? await glab.fetchAuthenticatedUser(host: host, expectedUsername: user.username)) == user,
              isCurrent(account, revision: revision), !Task.isCancelled,
              settings.mrLifecycleLedger.accepts(request, for: target, observedAt: readStartedAt) else { return false }

        let terminalSince = settings.mrLifecycleLedger.terminalObservedAt(for: target, state: request.state) ?? readStartedAt
        settings.retireMRProgress(for: target, state: request.state, terminalSince: terminalSince, now: readStartedAt, user: user)
        await reclaimConfirmedRuns(request, target: target, user: user, revision: revision, readStartedAt: readStartedAt)
        guard isCurrent(account, revision: revision), !Task.isCancelled,
              settings.mrLifecycleLedger.accepts(request, for: target, observedAt: readStartedAt) else { return false }
        if request.state == .merged && !isConfirming(request.mergeRequestID)
            && !settings.assistantHandoffs.contains(where: {
                $0.key.work == .init(host: host, projectID: request.projectID, iid: request.iid)
                    && settings.handoffMatchesAccount($0, host: host, username: user.username) && $0.execution?.state.isActive == true
            }) {
            let origins = AICommentProvenanceStore.Context(host: host, username: user.username, userID: user.id,
                projectID: request.projectID, iid: request.iid, legacyUsernames: settings.knownUsernames(for: account))
            let provenance = provenanceDirectory
            let assessments = authorFeedbackAssessmentDirectory
            let assessmentTargets = [target.forAccount(account)] + settings.unambiguousLegacyUsernames(for: account).map {
                target.forAccount(.init(host: host, username: $0))
            }
            await Task.detached(priority: .utility) {
                AICommentProvenanceStore.removeMergeRequest(origins, in: provenance)
                if let assessments {
                    for target in assessmentTargets { AuthorFeedbackAssessmentStore.remove(target, in: assessments) }
                }
            }.value
        }
        return true
    }

    private func reclaimConfirmedRuns(_ request: GitLabMergeRequest, target: MRAutomationScope.Target,
                                      user: GitLabAuthenticatedUser, revision: UInt64, readStartedAt: Date) async {
        let account = user.account(on: target.host)
        guard let settings, settings.automaticActionsAllowed, request.sha.map(GlabService.isFullGitSHA) == true,
              isCurrent(account, revision: revision), !Task.isCancelled,
              settings.mrLifecycleLedger.accepts(request, for: target, observedAt: readStartedAt),
              latestOpenForRunCleanup[target].map({ $0 <= readStartedAt }) != false,
              runCleanupIsDue(for: target, at: readStartedAt, open: request.isOpen), !isConfirming(request.mergeRequestID) else { return }
        let scoped = settings.assistantHandoffs.filter { $0.key.automationTarget == target }
        guard !hasPendingRunWork(for: target, jobs: scoped, settings: settings) else { return }
        let candidates = scoped.compactMap { job -> AssistantRunReclamation.Candidate? in
            guard ownsRun(job, user: user, host: target.host),
                  let candidate = AssistantRunReclamation.candidate(job, storage: runStorage, finishedBy: readStartedAt),
                  !request.isOpen || candidate.hasExpired(at: readStartedAt) else { return nil }
            return candidate
        }
        guard !candidates.isEmpty, runCleanupInProgress.insert(target).inserted else { return }
        defer { runCleanupInProgress.remove(target) }
        let inspection = Task.detached(priority: .utility) {
            candidates.filter { !Task.isCancelled && AssistantRunReclamation.hasFilesToInspect($0,
                isListedOpen: request.isOpen, at: readStartedAt) }
        }
        let inspected = await withTaskCancellationHandler { await inspection.value } onCancel: { inspection.cancel() }
        guard !inspected.isEmpty, isCurrent(account, revision: revision), !Task.isCancelled else { return }
        if request.isOpen {
            guard (try? await glab.fetchAuthenticatedUser(host: target.host, expectedUsername: user.username)) == user,
                  isCurrent(account, revision: revision), !Task.isCancelled else { return }
        }
        runCleanupAttempts[target] = (readStartedAt, request.isOpen)
        await AssistantRunReclamation.reclaimObservedRuns(inspected, request: request, readStartedAt: readStartedAt) { [weak self] candidate in
            guard let self, !Task.isCancelled, isCurrent(account, revision: revision), settings.automaticActionsAllowed,
                  !isConfirming(request.mergeRequestID), Date().timeIntervalSince(readStartedAt) <= 300,
                  latestOpenForRunCleanup[target].map({ $0 <= readStartedAt }) != false,
                  settings.mrLifecycleLedger.accepts(request, for: target, observedAt: readStartedAt) else { return false }
            let jobs = settings.assistantHandoffs.filter { $0.key.automationTarget == target }
            guard !hasPendingRunWork(for: target, jobs: jobs, settings: settings) else { return false }
            let owners = settings.assistantHandoffs.filter { $0.id == candidate.id || $0.execution?.workingDirectory == candidate.path }
            guard let owner = owners.first, owners.count == 1, owner.key.automationTarget == target,
                  ownsRun(owner, user: user, host: target.host) else { return false }
            return AssistantRunReclamation.candidate(owner, storage: runStorage, finishedBy: readStartedAt) == candidate
        }
    }

    private func ownsRun(_ job: AssistantAutomationRunner.Handoff, user: GitLabAuthenticatedUser, host: String) -> Bool {
        job.accountUserID.map { $0 == user.id }
            ?? (settings?.handoffMatchesAccount(job, host: host, username: user.username) == true)
    }

    private func workspaceCleanupTargets(host: String, user: GitLabAuthenticatedUser, listed: [GitLabMergeRequest],
                                         observedAt: Date) async -> Set<MRAutomationScope.Target> {
        guard let settings, settings.automaticActionsAllowed else { return [] }
        let observations = Dictionary(listed.filter { [.opened, .closed, .merged].contains($0.state) }
            .map { ($0.mergeRequestID, $0.isOpen) }, uniquingKeysWith: { first, _ in first })
        let pending = settings.assistantHandoffs.compactMap { job -> (MRAutomationScope.Target, AssistantRunReclamation.Candidate)? in
            let target = job.key.automationTarget
            guard target.host == host, target.username == user.username, ownsRun(job, user: user, host: host),
                  runCleanupIsDue(for: target, at: observedAt, open: target.mergeRequestID.flatMap { observations[$0] }),
                  let candidate = AssistantRunReclamation.candidate(job, storage: runStorage, finishedBy: observedAt) else { return nil }
            return (target, candidate)
        }
        guard !pending.isEmpty else { return [] }
        let inspection = Task.detached(priority: .utility) {
            var targets: Set<MRAutomationScope.Target> = []
            for (target, candidate) in pending {
                guard !Task.isCancelled else { break }
                if !targets.contains(target), AssistantRunReclamation.hasFilesToInspect(candidate,
                    isListedOpen: target.mergeRequestID.flatMap { observations[$0] } == true, at: observedAt) {
                    targets.insert(target)
                }
            }
            return targets
        }
        return await withTaskCancellationHandler { await inspection.value } onCancel: { inspection.cancel() }
    }

    private func hasPendingRunWork(for target: MRAutomationScope.Target, jobs: [AssistantAutomationRunner.Handoff],
                                   settings: SettingsManager) -> Bool {
        if jobs.contains(where: { $0.execution?.state.isActive == true || $0.execution?.pendingWorkerAudit != nil }) { return true }
        let ids = Set(jobs.map(\.id))
        if settings.mrActionIntents.contains(where: {
            $0.target == target && [.pending, .verifying, .running].contains($0.state)
                && ($0.jobID.map(ids.contains) == true || $0.reviewRecoveryJobID.map(ids.contains) == true)
        }) { return true }
        let executions = WorkflowExecutionProjection.JobIndex(jobs)
        return settings.workflowActivity.contains { entry in
            guard [.awaitingPipelineHandoff, .queued, .running, .waitingForAssistant].contains(entry.state) else { return false }
            if entry.preparedReviewJobID.map(ids.contains) == true { return true }
            // Persisted admissions keep their original state even after their linked run finishes.
            return entry.assistantJobID.map(ids.contains) == true && !executions.hasTerminalExecution(entry)
        }
    }

    private func runCleanupIsDue(for target: MRAutomationScope.Target, at now: Date, open: Bool? = nil) -> Bool {
        guard !runCleanupInProgress.contains(target) else { return false }
        guard let attempt = runCleanupAttempts[target], open == nil || open == attempt.open else { return true }
        return now.timeIntervalSince(attempt.date) >= 3_600
    }

    private func recordOpenRunCleanupObservation(_ target: MRAutomationScope.Target, at observedAt: Date) {
        if latestOpenForRunCleanup[target].map({ $0 < observedAt }) ?? true { latestOpenForRunCleanup[target] = observedAt }
        if let attempt = runCleanupAttempts[target], !attempt.open, attempt.date < observedAt { runCleanupAttempts[target] = nil }
    }

    private func poll(_ account: Account, todos: [Todo], revision: UInt64,
                      automaticResume: (id: Item.ID, action: MRAutomaticAction)? = nil,
                      feedbackDecision: Item.ID? = nil) async throws {
        let host = account.host
        let user = try await glab.fetchAuthenticatedUser(host: host, expectedUsername: account.username)
        guard isCurrent(account, revision: revision) else { return }
        if let previousUser = self.user, previousUser.id != user.id { resetAccountState(for: account) }
        if let settings, feedbackDecision == nil, workerAuditRetry == nil,
           settings.assistantHandoffs.contains(where: { $0.execution?.pendingWorkerAudit != nil }) {
            workerAuditRetry = Task { [weak self, glab] in
                defer { self?.workerAuditRetry = nil }
                await AssistantWorkerAudit.retryPending(host: host, user: user, glab: glab, settings: settings)
            }
        }
        self.user = user
        let agentWorks = assistantWorks(username: user.username)
        let verdictDirectory = verdictDirectory
        let observedAt = Date()
        // Capture legacy visibility before the network read so this refresh can route new review requests independently.
        let legacyLedger: MergeRequestLifecycleLedger?
        var legacyTracked: Set<MRAutomationScope.Target> = []
        var legacyOpenRequests: [GitLabMergeRequest] = []
        if feedbackDecision == nil, let settings,
           settings.reviewAssignments.needsBaseline(host: host, username: user.username) {
            let ledger = settings.mrLifecycleLedger
            let scope = settings.automation.scope
            legacyLedger = ledger
            legacyOpenRequests = ledger.retainedRequests(host: host, username: user.username) + openItems.compactMap(\.mergeRequest)
            legacyTracked = ledger.targets(host: host, username: user.username)
            legacyTracked.formUnion(scope.individualTargets(host: host, username: user.username).filter(scope.isManaged))
            legacyTracked.formUnion(settings.mrActionIntents.lazy.filter(\.grantsManagement).map(\.target))
            legacyTracked.formUnion(agentWorks.filter { $0.host == host }.map {
                .mergeRequest(host: host, username: user.username, projectID: $0.projectID, iid: $0.iid)
            })
        } else {
            legacyLedger = nil
        }
        let owned: [GitLabMergeRequest]?
        let assigned: [GitLabMergeRequest]?
        let listed: [GitLabMergeRequest]
        if let id = feedbackDecision {
            let request = try await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: host)
            guard request.projectID == id.projectID, request.iid == id.iid,
                  request.webURL.isGitLabMergeRequest(host: host, iid: id.iid),
                  [.opened, .closed, .merged].contains(request.state) else { return }
            owned = nil
            assigned = nil
            listed = [request]
        } else {
            async let authored = try? glab.fetchOwnedMergeRequests(userID: user.id, host: host)
            async let reviewing = try? glab.fetchReviewAssignedMergeRequests(userID: user.id, host: host)
            (owned, assigned) = await (authored, reviewing)
            listed = (owned ?? []) + (assigned ?? [])
        }
        guard isCurrent(account, revision: revision) else { return }
        func target(for request: GitLabMergeRequest) -> MRAutomationScope.Target {
            .mergeRequest(host: host, username: user.username, projectID: request.projectID, iid: request.iid)
        }
        func isIgnored(_ target: MRAutomationScope.Target) -> Bool {
            settings?.ignoredMergeRequests.contains(target) == true
        }
        func hasManagedIntent(_ target: MRAutomationScope.Target) -> Bool {
            settings?.mrActionIntents.contains { $0.target == target && $0.grantsManagement } == true
        }
        func isTracked(_ request: GitLabMergeRequest) -> Bool {
            let target = target(for: request)
            return glab.owns(request, userID: user.id) || settings?.automation.scope.isManaged(target) == true
                || hasManagedIntent(target) || settings?.mrLifecycleLedger.request(for: target) != nil
                || agentWorks.contains(.init(host: host, projectID: request.projectID, iid: request.iid))
        }
        if let assigned, let settings {
            let requests = assigned.filter { request in
                !glab.owns(request, userID: user.id) && request.reviewers?.contains { $0.id == user.id } != false
            }
            var previouslyVisible: Set<MRAutomationScope.Target> = []
            if let legacyLedger {
                previouslyVisible = Set((requests + legacyOpenRequests).compactMap { request in
                    let key = target(for: request)
                    guard request.isOpen, !glab.owns(request, userID: user.id), !isIgnored(key),
                          request.webURL.isGitLabMergeRequest(host: host, iid: request.iid),
                          legacyLedger.request(for: key).map({ $0.state == .opened }) != false,
                          legacyTracked.contains(key) else { return nil }
                    return key
                })
            }
            var ledger = settings.reviewAssignments
            ledger.observe(requests, host: host, username: user.username, at: observedAt, previouslyVisible: previouslyVisible)
            if let onReviewAssignmentsObserved {
                onReviewAssignmentsObserved(ledger, host, user.username)
            } else {
                settings.reviewAssignments = ledger
                settings.save()
            }
        }
        func isFiltered(_ target: MRAutomationScope.Target) -> Bool {
            settings?.intakeFilterHolds(target) == true
        }
        func remember(_ request: GitLabMergeRequest, readStartedAt: Date) {
            let target = target(for: request)
            if request.isOpen { recordOpenRunCleanupObservation(target, at: readStartedAt) }
            guard !isIgnored(target), !isFiltered(target) else { return }
            onDisplayMetadataObserved?(request, target, revision, readStartedAt)
            guard isTracked(request) else { return }
            settings?.mrLifecycleLedger.record(request, for: target, now: readStartedAt,
                autoRemoveFinished: true)
            onAutomationEligibilityObserved?()
        }
        for pending in settings?.pendingCommentReviews ?? [] where pending.host == host && pending.username == user.username
            && (feedbackDecision == nil || (pending.projectID == feedbackDecision?.projectID && pending.iid == feedbackDecision?.iid)) {
            if isIgnored(pending) {
                settings?.completeCommentReview(for: pending)
            }
        }
        for request in listed where request.webURL.isGitLabMergeRequest(host: host, iid: request.iid) {
            if feedbackDecision != nil, settings != nil, MergeRequestFinishedState(request) != nil {
                guard await retireConfirmedLifecycle(request, host: host, user: user, revision: revision, readStartedAt: observedAt),
                      isCurrent(account, revision: revision) else { return }
            }
            remember(request, readStartedAt: observedAt)
            if request.isOpen {
                terminalCatalogRequests.remove(.init(projectID: request.projectID, iid: request.iid))
            }
        }
        let listedIDs = Set(listed.filter {
            $0.webURL.isGitLabMergeRequest(host: host, iid: $0.iid)
                && [.opened, .closed, .merged].contains($0.state)
        }.map { $0.mergeRequestID })
        var previousCatalog = Dictionary(uniqueKeysWithValues: openItems
            .filter { feedbackDecision == nil || $0.id == feedbackDecision }.map { ($0.id, $0) })
        let retainedRequests = feedbackDecision == nil
            ? (settings?.mrLifecycleLedger.retainedRequests(host: host, username: user.username) ?? []) : []
        for request in retainedRequests {
            let id = request.mergeRequestID
            if previousCatalog[id] == nil {
                previousCatalog[id] = Item(id: id, title: request.title, url: request.webURL,
                    mergeRequest: request, isAuthored: glab.owns(request, userID: user.id))
            }
        }
        // Known tracked rows survive a successful open list until an exact read
        // confirms their state. Absence, pagination and failures are not closure.
        var retainedCatalog = previousCatalog.filter { _, item in
            let tracked = item.mergeRequest.map { settings?.mrLifecycleLedger.request(for: target(for: $0)) != nil } == true
            return tracked || (item.mergeRequest.map { glab.owns($0, userID: user.id) } == true ? owned == nil : assigned == nil)
        }.mapValues { item in
            var item = item
            item.approvalProgress = nil
            return item
        }
        for request in listed where request.state == .closed || request.state == .merged {
            retainedCatalog.removeValue(forKey: .init(projectID: request.projectID, iid: request.iid))
        }
        let pendingReviewTargets = (settings?.pendingCommentReviews ?? []).filter { $0.host == host && $0.username == user.username }
        let scopeTargets = Set(settings?.automation.scope.individualTargets(host: host, username: user.username) ?? []).union(pendingReviewTargets)
        let transientTargets = (settings?.newReviewTargets ?? []).filter { $0.host == host && $0.username == user.username }
        let recordedTargets = Set(agentWorks.filter { $0.host == host }.map {
            MRAutomationScope.Target.mergeRequest(host: host, username: user.username, projectID: $0.projectID, iid: $0.iid)
        })
        let intentTargets = Set((settings?.mrActionIntents ?? []).filter {
            $0.target.host == host && $0.target.username == user.username && $0.grantsManagement
        }.map(\.target))
        let trackedTargets = settings?.mrLifecycleLedger.targets(host: host, username: user.username) ?? []
        let hiddenTargets = settings?.ignoredMergeRequests.filter {
            $0.account.matches(user.account(on: host))
        } ?? []
        let listedAssignments = Set((assigned ?? []).filter { request in
            request.isOpen && request.reviewers?.contains(where: { $0.id == user.id }) == true
                && request.webURL.isGitLabMergeRequest(host: host, iid: request.iid)
        }.map(\.mergeRequestID))
        let historyCleanupTargets = settings?.retainedHistoryCandidates(host: host, username: user.username) ?? []
        let trackedLookupTargets = feedbackDecision == nil
            ? scopeTargets.union(recordedTargets).union(intentTargets).union(trackedTargets).union(hiddenTargets).union(transientTargets) : []
        let approvalTargets = feedbackDecision == nil ? (settings?.approvalBaselineTargets(host: host, user: user) ?? []) : []
        let workspaceCleanupTargets = feedbackDecision == nil
            ? await self.workspaceCleanupTargets(host: host, user: user, listed: listed, observedAt: observedAt) : []
        guard isCurrent(account, revision: revision), !Task.isCancelled else { return }
        let lookupTargets = feedbackDecision == nil
            ? trackedLookupTargets.union(approvalTargets).union(workspaceCleanupTargets) : []
        var explicit: [GitLabMergeRequest] = []
        var recordedReviews: [GitLabMergeRequest] = []
        var removedHiddenAssignments: Set<MRAutomationScope.Target> = []
        var explicitFetchFailed = false
        for target in lookupTargets.sorted(by: { ($0.projectID, $0.iid ?? 0) < ($1.projectID, $1.iid ?? 0) }) {
            let hidden = isIgnored(target)
            let cleanupOnly = !trackedLookupTargets.contains(target)
            let needsWorkspaceRead = workspaceCleanupTargets.contains(target)
            guard let iid = target.iid else { continue }
            let hide = settings?.hiddenReviewDetails[target]
            let id = Item.ID(projectID: target.projectID, iid: iid)
            let supplementaryRead = cleanupOnly || listedIDs.contains(id)
            if hidden {
                // The assignment listing only contains open MRs. An omitted row
                // cannot distinguish closure, unassignment and a partial listing.
                if !needsWorkspaceRead, listedAssignments.contains(id), hide?.request?.isOpen == true,
                   hide?.request?.reviewers?.contains(where: { $0.id == user.id }) == true { continue }
            } else if listedIDs.contains(id), !needsWorkspaceRead {
                continue
            }
            // Merged MRs cannot reopen. Closed rows, including Seen tombstones,
            // continue exact checks because they may reopen without assignment.
            if !hidden, !needsWorkspaceRead, terminalCatalogRequests.contains(id)
                || (settings?.mrLifecycleLedger.request(for: target)?.state == .merged
                    && !transientTargets.contains(target) && !historyCleanupTargets.contains(target)
                    && !approvalTargets.contains(target)) { continue }
            let requestReadStartedAt = Date()
            guard let request = try? await glab.fetchMergeRequest(projectID: target.projectID, iid: iid, host: host) else {
                if hidden || supplementaryRead { continue }
                explicitFetchFailed = true
                if var previous = previousCatalog[id] {
                    previous.approvalProgress = nil
                    retainedCatalog[id] = previous
                }
                continue
            }
            guard isCurrent(account, revision: revision) else { return }
            guard request.projectID == target.projectID, request.iid == iid,
                  request.webURL.isGitLabMergeRequest(host: host, iid: iid),
                  [.opened, .closed, .merged].contains(request.state) else {
                if !hidden && !supplementaryRead { explicitFetchFailed = true }
                continue
            }
            if needsWorkspaceRead, request.isOpen {
                recordOpenRunCleanupObservation(target, at: requestReadStartedAt)
                await reclaimConfirmedRuns(request, target: target, user: user, revision: revision, readStartedAt: requestReadStartedAt)
                guard isCurrent(account, revision: revision), !Task.isCancelled else { return }
            }
            if hidden {
                guard !Task.isCancelled else { return }
                if request.isOpen { recordOpenRunCleanupObservation(target, at: requestReadStartedAt) }
                if settings?.reconcileHiddenReview(target, request: request, reviewerID: user.id, hideID: hide?.hideID) == true {
                    removedHiddenAssignments.insert(target)
                }
                if needsWorkspaceRead || request.state != .merged || !terminalCatalogRequests.contains(id),
                   await retireConfirmedLifecycle(request, host: host, user: user, revision: revision, readStartedAt: requestReadStartedAt),
                   request.state == .merged {
                    terminalCatalogRequests.insert(id)
                }
                guard isCurrent(account, revision: revision) else { return }
                continue
            }
            if request.state == .merged || request.state == .closed {
                let alreadyTracked = settings?.mrLifecycleLedger.request(for: target) != nil
                    || settings?.automation.scope.isManaged(target) == true || hasManagedIntent(target)
                if settings != nil {
                    let confirmed = await retireConfirmedLifecycle(request, host: host, user: user, revision: revision,
                        readStartedAt: requestReadStartedAt)
                    guard isCurrent(account, revision: revision) else { return }
                    guard confirmed else {
                        if !supplementaryRead { explicitFetchFailed = true }
                        continue
                    }
                }
                if alreadyTracked { remember(request, readStartedAt: requestReadStartedAt) }
                else if !cleanupOnly { onDisplayMetadataObserved?(request, target, revision, requestReadStartedAt) }
                if request.state == .merged { terminalCatalogRequests.insert(id) }
                retainedCatalog.removeValue(forKey: id)
            } else {
                terminalCatalogRequests.remove(id)
                // A cleanup read may observe an MR outside the board's tracked scope.
                guard !cleanupOnly else { continue }
                remember(request, readStartedAt: requestReadStartedAt)
                if scopeTargets.contains(target) || glab.owns(request, userID: user.id) { explicit.append(request) }
                else { recordedReviews.append(request) }
            }
        }
        guard isCurrent(account, revision: revision) else { return }
        // A newer Authored read may have completed while this poll was awaiting
        // GitLab. Its observed state must win over the older list snapshot.
        let currentListed = (listed + explicit).filter { !isFiltered(target(for: $0)) }.map { request in
            settings?.mrLifecycleLedger.request(for: target(for: request)) ?? request
        }

        let todoItems: [Item] = todos.compactMap { todo in
            guard let id = todo.mergeRequestID,
                  todo.targetURL.isGitLabMergeRequest(host: host, iid: id.iid) else { return nil }
            var url = URLComponents(url: todo.targetURL, resolvingAgainstBaseURL: false)
            url?.fragment = nil
            return Item(id: id,
                        title: todo.displayTitle, url: url?.url ?? todo.targetURL, draftFromTodo: todo.isDraft)
        }
        var candidates: [Item.ID: Item] = [:]
        for item in items where (feedbackDecision == nil || item.id == feedbackDecision)
            && (item.draftCount > 0 || item.requiresCommentReview || owned == nil) {
            candidates[item.id] = item
        }
        for item in recentTodos where (feedbackDecision == nil || item.id == feedbackDecision) && candidates[item.id] == nil {
            candidates[item.id] = item
        }
        for item in todoItems where feedbackDecision == nil || item.id == feedbackDecision {
            if candidates[item.id] == nil { candidates[item.id] = item }
            candidates[item.id]?.draftFromTodo = item.draftFromTodo
        }
        if feedbackDecision == nil { recentTodos = todoItems }

        for mr in currentListed {
            guard mr.isOpen, mr.webURL.isGitLabMergeRequest(host: host, iid: mr.iid) else { continue }
            let id = mr.mergeRequestID
            if feedbackDecision != nil {
                guard !isIgnored(target(for: mr)),
                      previousCatalog[id] != nil || candidates[id] != nil || isTracked(mr) else { continue }
            }
            var item = Item(
                id: id, title: mr.title, url: mr.webURL, drafts: candidates[id]?.drafts ?? [],
                draftFromTodo: candidates[id]?.draftFromTodo ?? false, mergeRequest: mr, isAuthored: glab.owns(mr, userID: user.id)
            )
            item.requiresCommentReview = commentReviewPending(id, account: account)
            if item.isAuthored {
                item.catalogIssues = CatalogIssue.observed(in: mr)
                if Self.reportsDiscussionBlock(mr) {
                    item.discussionObservation = .unresolvedOther
                }
            }
            candidates[id] = item
        }
        if owned != nil {
            let ownedIDs = Set((owned ?? []).map { $0.mergeRequestID })
            for id in Array(candidates.keys) where !ownedIDs.contains(id) {
                candidates[id]?.catalogIssues = []
                candidates[id]?.discussionObservation = .resolved
                candidates[id]?.isAuthored = false
                candidates[id]?.feedback = []
            }
        }

        for id in Array(candidates.keys) {
            let target = MRAutomationScope.Target.mergeRequest(host: host, username: user.username, projectID: id.projectID, iid: id.iid)
            if isFiltered(target) || removedHiddenAssignments.contains(target) {
                candidates.removeValue(forKey: id)
                continue
            }
            if let current = settings?.mrLifecycleLedger.request(for: target) {
                if current.state != .opened { candidates.removeValue(forKey: id) }
                else { candidates[id]?.mergeRequest = current }
            }
        }
        var results: [Item] = []
        var authoredUnansweredFeedback: [Item.ID: Bool] = [:]
        var reReviewCandidates: [(GitLabMergeRequest, ReReviewFeedback, Int)] = []
        var failed = feedbackDecision == nil && (owned == nil || assigned == nil)
        let ordered = candidates.values.sorted { ($0.id.projectID, $0.id.iid) < ($1.id.projectID, $1.id.iid) }
        // Limit simultaneous glab processes while still checking the entire list.
        for start in stride(from: 0, to: ordered.count, by: 4) {
            guard isCurrent(account) else { return }
            let batch = ordered[start..<min(start + 4, ordered.count)]
            let treatAssignedMergeRequestsAsOwn = settings?.treatAssignedMergeRequestsAsOwn == true
            let reviewRevisions = Dictionary(uniqueKeysWithValues: batch.map {
                ($0.id, settings?.commentReviewRevision(for: commentReviewTarget($0.id, account: account)) ?? 0)
            })
            await withTaskGroup(of: (Item, Bool, ReReviewFeedback?, [GitLabMergeRequestDiscussion]?, Set<Int>,
                                     GitLabMergeRequest?, Date?, ApprovalBaselineRead?).self) { group in
                for item in batch {
                    let approvedHead = approvedHeads[item.id]
                    let failedHead = failedApprovalHeads[item.id]
                    let autoApproves = item.mergeRequest.map {
                        autoApproveApplies(to: $0, host: host, username: account.username)
                    } ?? false
                    let target = commentReviewTarget(item.id, account: account)
                    let approvalThreshold = settings?.automation.autoApprovalThreshold ?? .noMajorIssues
                    let approvalBaseline = settings?.approvalBaseline(for: target, user: user)
                    let approvalOptedOut = settings.map {
                        $0.automation.scope[target] != .paused && $0.actionPreference(.approval, for: target) == .off
                    } == true
                    let followUpReceipts = contextReceipts(projectID: item.id.projectID, iid: item.id.iid,
                        host: host, username: user.username)
                    let authenticatedVerdict = ReviewVerdictStore.authenticatedVerdict(host: host,
                        projectID: item.id.projectID, iid: item.id.iid, user: user, settings: settings, in: verdictDirectory)
                    let reviewedTarget = authenticatedVerdict.flatMap {
                        ReviewVerdictStore.authenticatedTarget(for: $0, settings: settings)
                    }
                    group.addTask { [glab] in
                        var updated = item
                        var contextDraftIDs: Set<Int> = []
                        var recoveryRequest: GitLabMergeRequest?
                        var recoveryReadStartedAt: Date?
                        updated.reviewingProgress = nil
                        updated.approvalProgress = if item.mergeRequest != nil {
                            try? await glab.fetchMergeRequestApprovalProgress(projectID: item.id.projectID, iid: item.id.iid, host: host)
                        } else { nil }
                        let drafts = try? await glab.fetchOwnDraftNotes(
                            projectID: item.id.projectID, iid: item.id.iid, host: host, userID: user.id
                        )
                        if let drafts { updated.drafts = drafts }
                        if let drafts, !drafts.isEmpty {
                            ReviewVerdictStore.rememberDrafts(drafts, host: host, projectID: item.id.projectID,
                                                              iid: item.id.iid, in: verdictDirectory)
                        }
                        updated.approvalObservation = .unchecked
                        updated.metApprovalThreshold = nil
                        updated.remainingApprovalFindings = []
                        if drafts?.isEmpty == true, !item.isAuthored,
                           let request = item.mergeRequest,
                           !request.isOwned(by: user.id, includingAssignee: treatAssignedMergeRequestsAsOwn), request.draft != nil,
                           let head = request.sha, head != approvedHead,
                           ReviewVerdictStore.verdict(
                               host: host, projectID: request.projectID, iid: request.iid, user: user, in: verdictDirectory
                           )?.headSHA == head {
                            let check = await Self.approvalCheck(request, user: user, host: host,
                                glab: glab, verdict: authenticatedVerdict,
                                automaticGate: autoApproves && authenticatedVerdict != nil ? (head, reviewedTarget) : nil)
                            let currentVerdict = check.discussions.map {
                                ReviewVerdictStore.verdict(host: host, projectID: request.projectID, iid: request.iid, user: user, in: verdictDirectory)?
                                    .approves(head: head, discussions: $0, reviewerID: user.id,
                                              publishedDrafts: ReviewVerdictStore.seenDrafts(
                                                  host: host, projectID: request.projectID, iid: request.iid, in: verdictDirectory
                                              )) == true
                            } ?? false
                            let automaticContext: Bool
                            if let authenticatedVerdict, let discussions = check.discussions {
                                automaticContext = await ReviewVerdictStore.automaticallyApproves(authenticatedVerdict,
                                    head: head, discussions: discussions, user: user, threshold: approvalThreshold,
                                    semanticContextFingerprint: request.semanticContextFingerprint,
                                    legacyDuoThreadsVerified: check.discussionsReady, in: verdictDirectory)
                            } else { automaticContext = false }
                            // After GitLab refused an automatic approval, offer the button instead of retrying.
                            let automatic = autoApproves && head != failedHead && automaticContext && check.automaticGatePassed
                                && authenticatedVerdict == ReviewVerdictStore.verdict(host: host, projectID: request.projectID,
                                    iid: request.iid, user: user, in: verdictDirectory)
                            let classifiedReviewAllowsApproval = authenticatedVerdict?.verdict == .classifiedFindings && automaticContext
                            updated.approvalObservation = .checked(
                                manualVerdictPermitsApproval: (currentVerdict && check.ownReady) || classifiedReviewAllowsApproval,
                                automaticGatePassed: automatic,
                                awaitsDiscussionReadiness: (approvalOptedOut || autoApproves) && !automaticContext && !check.discussionsReady)
                            if classifiedReviewAllowsApproval, let verdict = authenticatedVerdict, let discussions = check.discussions {
                                updated.metApprovalThreshold = approvalThreshold
                                updated.remainingApprovalFindings = await ReviewVerdictStore.remainingFindings(verdict,
                                    discussions: discussions, in: verdictDirectory)
                            }
                        }
                        let hasDrafts = !(drafts ?? item.drafts).isEmpty
                        let discussionReadStartedAt = Date()
                        let discussions = if item.mergeRequest != nil || item.authoredRequest != nil || hasDrafts {
                            try? await glab.fetchMergeRequestDiscussions(
                                projectID: item.id.projectID, iid: item.id.iid, host: host
                            )
                        } else { nil as [GitLabMergeRequestDiscussion]? }
                        // The list endpoint can report a discussion blocker after the last thread is resolved.
                        let rechecksDiscussionBlock = feedbackDecision == nil && item.isAuthored
                            && item.mergeRequest.map(Self.reportsDiscussionBlock) == true
                            && discussions.map(GitLabMergeRequestDiscussion.allConfirmedResolved) == true
                        if hasDrafts || rechecksDiscussionBlock {
                            let requestReadStartedAt = Date()
                            let live = try? await glab.fetchMergeRequest(projectID: item.id.projectID, iid: item.id.iid, host: host)
                            if let live, rechecksDiscussionBlock, live.blockingDiscussionsResolved == true,
                               !Self.reportsDiscussionBlock(live), MRAttentionRecord.sameContext(item.mergeRequest, live) {
                                updated.mergeRequest = live
                                updated.catalogIssues = CatalogIssue.observed(in: live)
                                recoveryRequest = live
                            } else if hasDrafts {
                                recoveryRequest = live
                            }
                            if recoveryRequest != nil { recoveryReadStartedAt = requestReadStartedAt }
                        }
                        updated.observationSession = .init(host: account.host, username: account.username, revision: revision)
                        updated.discussionReadStartedAt = discussions.map { _ in discussionReadStartedAt }
                        updated.observedDiscussionFingerprint = discussions.flatMap { ReviewVerdict.fingerprint($0) }
                        updated.observedActiveDiscussionFingerprint = discussions.flatMap {
                            ReviewVerdict.fingerprint(GitLabMergeRequestDiscussion.activeForReview($0))
                        }
                        updated.ownPublishedReplies = discussions.map { DuplicateReplyDrafts.publishedReplies(in: $0, userID: user.id) }
                        let reviewers = try? await glab.fetchMergeRequestReviewers(projectID: item.id.projectID, iid: item.id.iid, host: host)
                        let reviewHistory = discussions.flatMap { discussions in
                            item.mergeRequest.map { MergeRequestReviewHistory(
                                reviewers: reviewers ?? [], discussions: discussions, authorID: $0.author.id) }
                        }
                        if let reviewHistory { updated.approvalProgress?.reviewHistory = reviewHistory }
                        updated.commentReviewSnapshot = CommentReviewSnapshot(request: item.mergeRequest, discussions: discussions)
                        updated.changeRequestReviewers = nil
                        updated.confirmedPendingReReviewers = []
                        if updated.isAuthored, updated.needsChanges, let reviewers {
                            let requests = reviewers.filter { $0.state == .requestedChanges }
                            if requests.allSatisfy({ $0.user.id > 0 && $0.user.username?.isEmpty == false }) {
                                updated.changeRequestReviewers = Set(requests.compactMap(\.user.username))
                            }
                            if requests.isEmpty, let reviewHistory, let request = updated.mergeRequest {
                                updated.confirmedPendingReReviewers = await self.reReviewCoordinator?.confirmedPendingReviewers(
                                    for: request, reviewers: reviewers, history: reviewHistory,
                                    context: .init(host: host, username: account.username, revision: revision,
                                        projectID: item.id.projectID, iid: item.id.iid), authorID: user.id) ?? []
                            }
                        }
                        if !item.isAuthored, let request = item.mergeRequest {
                            updated.reviewingActivity = discussions.map {
                                ReviewingActivity(discussions: $0, reviewerID: user.id, authorID: request.author.id)
                            }
                        }
                        if hasDrafts {
                            updated.requiresDiscussionRecheck = !Self.draftContextIsCurrent(
                                request: recoveryRequest, drafts: drafts, discussions: discussions, host: host, user: user,
                                verdictDirectory: verdictDirectory, followUpReceipts: followUpReceipts,
                                treatAssignedMergeRequestsAsOwn: treatAssignedMergeRequestsAsOwn
                            )
                            contextDraftIDs = Set((drafts ?? []).filter { draft in
                                Self.draftContextIsCurrent(request: recoveryRequest, drafts: [draft], discussions: discussions,
                                    host: host, user: user, verdictDirectory: verdictDirectory, followUpReceipts: followUpReceipts,
                                    treatAssignedMergeRequestsAsOwn: treatAssignedMergeRequestsAsOwn)
                            }.compactMap(\.id))
                        } else {
                            updated.requiresDiscussionRecheck = false
                        }
                        var approvalRead: ApprovalBaselineRead?
                        if !item.isAuthored, let displayed = item.mergeRequest {
                            let ownApproval = updated.approvalProgress?.currentApproverIDs?.contains(user.id) == true
                            let readStartedAt = recoveryReadStartedAt ?? Date()
                            let request: GitLabMergeRequest? = if hasDrafts { recoveryRequest } else if ownApproval {
                                try? await glab.fetchMergeRequest(projectID: item.id.projectID, iid: item.id.iid, host: host)
                            } else { displayed }
                            if ownApproval, let request,
                               !request.isOwned(by: user.id, includingAssignee: treatAssignedMergeRequestsAsOwn),
                               MRAttentionRecord.sameContext(displayed, request), let discussions,
                               let baseline = await Self.observedApprovalBaseline(for: request, previous: approvalBaseline,
                                   approvedAt: updated.approvalProgress?.approvalDates[user.id],
                                   discussions: discussions, host: host, glab: glab) {
                                approvalRead = .init(request: request, startedAt: readStartedAt, previous: approvalBaseline, baseline: baseline)
                            }
                            updated.reviewingAssessment = Self.reviewingAssessment(for: updated,
                                request: request ?? (ownApproval && !hasDrafts ? displayed : nil),
                                discussions: discussions, host: host, user: user, verdictDirectory: verdictDirectory,
                                approvedHead: approvedHead, approvalBaseline: approvalRead?.baseline,
                                previousApprovalBaseline: approvalBaseline,
                                treatAssignedMergeRequestsAsOwn: treatAssignedMergeRequestsAsOwn)
                        }
                        updated.replyRecipients = [:]
                        updated.incomingReplyDiscussionIDs = AutomaticPublicationPolicy.incomingDiscussionIDs(in: discussions, userID: user.id)
                        if let discussions {
                            for discussion in discussions {
                                if let id = discussion.id, case let recipients = discussion.replyRecipients(excluding: user.id), !recipients.isEmpty {
                                    updated.replyRecipients[id] = recipients
                                }
                            }
                        }
                        let feedback = discussions.map { ReReviewFeedback(discussions: $0, authorID: user.id) }
                        return (updated, drafts != nil && (!(item.isAuthored || hasDrafts) || discussions != nil),
                            feedback, discussions, contextDraftIDs, recoveryRequest, recoveryReadStartedAt, approvalRead)
                    }
                }
                for await (var item, success, feedback, discussions, workerDraftIDs, recoveryRequest, recoveryReadStartedAt, approvalRead) in group {
                    guard isCurrent(account, revision: revision) else { return }
                    settings?.observeCommentReview(item.drafts.filter { publishedDrafts[item.id]?.contains($0) != true },
                        for: commentReviewTarget(item.id, account: account), revision: reviewRevisions[item.id] ?? 0)
                    item.requiresCommentReview = commentReviewPending(item.id, account: account)
                    if item.requiresCommentReview {
                        item.approvalObservation = .unchecked; item.reReviewFeedbackChecked = false
                    }
                    if let recoveryRequest, let recoveryReadStartedAt {
                        remember(recoveryRequest, readStartedAt: recoveryReadStartedAt)
                    }
                    let lifecycleTarget = MRAutomationScope.Target.mergeRequest(host: host, username: user.username,
                        projectID: item.id.projectID, iid: item.id.iid)
                    if let latest = settings?.mrLifecycleLedger.request(for: lifecycleTarget) {
                        guard latest.isOpen, latest.evidenceContext().binds(
                            to: item.observedEvidenceContext, policy: .requestText) else { continue }
                        item.mergeRequest = latest
                    }
                    if item.isAuthored, let discussions {
                        Self.applyDiscussionFeedback(to: &item, discussions: discussions, userID: user.id)
                    }
                    if !item.isAuthored, let approvers = item.approvalProgress?.currentApproverIDs, let settings {
                        if !approvers.contains(user.id) {
                            settings.setApprovalBaseline(nil, for: lifecycleTarget, user: user)
                        } else if let approvalRead {
                            if settings.approvalBaseline(for: lifecycleTarget, user: user) == approvalRead.previous,
                               settings.mrLifecycleLedger.accepts(approvalRead.request, for: lifecycleTarget, observedAt: approvalRead.startedAt) {
                                settings.setApprovalBaseline(approvalRead.baseline, for: lifecycleTarget, user: user)
                            } else if item.reviewingProgress == .current {
                                item.reviewingProgress = .needsReview
                            }
                        }
                    }
                    let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: item.id.projectID, iid: item.id.iid)
                    let verifiedReplyIDs = Set(item.drafts.compactMap { draft -> Int? in
                        guard item.isAuthored, let request = recoveryRequest, let discussions,
                              verifiedReplyDrafts?.receipt(for: draft, request: request, discussions: discussions, user: user, host: host) != nil else { return nil }
                        return draft.id
                    })
                    let contextDraftIDs = workerDraftIDs.union(verifiedReplyIDs)
                    if !verifiedReplyIDs.isEmpty, contextDraftIDs.count == item.drafts.count {
                        item.requiresDiscussionRecheck = false
                    }
                    if feedbackDecision == nil, success, let request = item.mergeRequest, let discussions {
                        await scheduleAIOriginChecks(request: request, drafts: item.drafts, discussions: discussions,
                            account: account, user: user)
                    }
                    if item.isAuthored, agentWorks.contains(work), let settings {
                        let run = FollowUpVerificationStore.latestRun(for: work, username: user.username, settings: settings)
                        if let run { FollowUpVerificationStore.register(run, settings: settings, in: followUpDirectory) }
                        let receipts = publicationReceipts(projectID: item.id.projectID, iid: item.id.iid,
                            host: host, username: user.username)
                        let candidates = item.drafts.filter { draft in
                            guard draft.id.map(verifiedReplyIDs.contains) != true else { return false }
                            guard let request = item.mergeRequest,
                                  settings.automation.scope.permits(request, host: host, username: user.username) else { return false }
                            return settings.publicationPolicy(for: lifecycleTarget).couldAllow(
                                draft, request: request, userID: user.id, host: host)
                                && AutomaticPublicationPolicy.sourceNotes(for: draft, discussions: discussions,
                                    userID: user.id)?.isEmpty == false
                        }
                        let verificationCandidates = item.mergeRequest.map { request in
                            DraftReplyRepair.preparationAllowed(request, configuration: settings.automation)
                                ? item.drafts.filter {
                                    $0.id.map(verifiedReplyIDs.contains) != true
                                        && AutomaticPublicationPolicy.sourceNotes(for: $0, discussions: discussions, userID: user.id)?.isEmpty == false
                                }
                                : candidates
                        } ?? candidates
                        if feedbackDecision == nil,
                           automaticResume == nil || (automaticResume?.action == .commentPublication && automaticResume?.id == item.id),
                           success, let request = item.mergeRequest, let discussions, let head = request.sha,
                           !verificationCandidates.isEmpty, settings.automation.allowFollowUpPush,
                           verificationCandidates.contains(where: { draft in
                               Self.followUpReceipt(for: draft, request: request, discussions: discussions,
                                   host: host, user: user, verdictDirectory: verdictDirectory, receipts: receipts) == nil
                           }) {
                            let unverified = verificationCandidates.filter { draft in
                                Self.followUpReceipt(for: draft, request: request, discussions: discussions,
                                    host: host, user: user, verdictDirectory: verdictDirectory, receipts: receipts) == nil
                            }
                            let observedRequest = recoveryRequest ?? request
                            for origin in FollowUpVerificationStore.recoveryOrigins(work: work, username: user.username,
                                settings: settings, in: followUpDirectory) {
                                let scopedIDs = unverified.filter { draft in
                                    origin.owns(draft, request: observedRequest, host: host, user: user)
                                        && AutomaticPublicationPolicy.safeForAutomaticPublication(draft)
                                }.compactMap(\.id)
                                guard !scopedIDs.isEmpty else { continue }
                                draftProofRecoveryCoordinator?.schedule(snapshot: .init(request: observedRequest, discussions: discussions,
                                    drafts: item.drafts, user: user, host: host, branchHead: observedRequest.sha ?? head), origin: origin,
                                    draftIDs: scopedIDs, configuration: settings.automation)
                            }
                        }
                        item.awaitingRemoteVerification = !candidates.isEmpty && (!settings.automation.allowFollowUpPush
                            || candidates.contains { draft in
                                guard let request = item.mergeRequest else { return true }
                                return !receipts.contains { $0.covers(draft, request: request, host: host, user: user, runID: $0.runID) }
                            })
                    }
                    item.automaticDraftIDs = []
                    item.aiReplyDecisions = [:]
                    item.automaticPublicationPolicy = nil
                    if success, let settings, let request = item.mergeRequest,
                       (agentWorks.contains(work) || !verifiedReplyIDs.isEmpty),
                       settings.automation.scope.permits(request, host: host, username: user.username),
                       item.isAuthored || (!item.awaitingRemoteVerification && !item.requiresDiscussionRecheck) {
                        let policy = settings.publicationPolicy(for: lifecycleTarget)
                        if policy.mode != .manual {
                            let evidence = await publicationNoteEvidence(in: discussions ?? [], for: item.drafts, policy: policy, host: host,
                                                       projectID: item.id.projectID, iid: item.id.iid, user: user)
                            item.automaticPublicationPolicy = policy
                            let duplicates = item.duplicateDraftIDs
                            let reviewDrafts = policy.requiresAI && !item.isAuthored
                                ? authenticatedPublicationDrafts(id: item.id, account: account, user: user) : []
                            let candidates = item.drafts.filter {
                                $0.id.map(duplicates.contains) != true
                                    && !settings.holdsRegeneratedDraft($0, for: lifecycleTarget)
                                    && (!item.isAuthored || (settings.automation.allowFollowUpPush && $0.id.map(contextDraftIDs.contains) == true))
                            }
                            for draft in candidates {
                                guard let draftID = draft.id else { continue }
                                let sources = AutomaticPublicationPolicy.sourceNotes(for: draft, discussions: discussions, userID: user.id) ?? []
                                let hasPreparedDraft = item.isAuthored || reviewDrafts.contains(draft)
                                let usesTrust = sources.contains { $0.id.map(evidence.trusted.contains) == true }
                                if policy.allows(draft, request: request, discussions: discussions, userID: user.id,
                                    host: host, aiNoteIDs: evidence.ai, botNoteIDs: evidence.bots) {
                                    if hasPreparedDraft || !usesTrust { item.automaticDraftIDs.insert(draftID) }
                                } else if policy.requiresAI, hasPreparedDraft, permitsAutomaticPublication(of: request, account: account),
                                          policy.allows(draft, request: request, discussions: discussions, userID: user.id,
                                            host: host, aiNoteIDs: Set(sources.compactMap(\.id))) {
                                    let decisions = sources.compactMap(AIReplyDecision.init).filter { evidence.lanes[$0.id] == .unconfirmed }
                                    if !decisions.isEmpty { item.aiReplyDecisions[draftID] = decisions }
                                }
                            }
                        }
                    }
                    if automaticResume == nil, success, let request = item.authoredRequest, let discussions {
                        authorFeedbackCoordinator?.refresh(request: request, discussions: discussions,
                            drafts: item.draftCount, host: host, user: user,
                            approvalRevision: item.approvalProgress.map(Self.approvalRevision),
                            scopedRefresh: feedbackDecision != nil)
                    }
                    if automaticResume == nil, success, let feedback, let request = item.authoredRequest {
                        reReviewCandidates.append((request, feedback, item.draftCount))
                    }
                    if item.isAuthored {
                        authoredUnansweredFeedback[item.id] = feedback?.hasUnansweredFeedback != false
                        applyReReviewPresentation(&item, unanswered: feedback?.hasUnansweredFeedback != false)
                    }
                    results.append(item)
                    failed = failed || !success
                }
            }
        }
        guard isCurrent(account, revision: revision) else { return }
        if feedbackDecision == nil {
            hasError = failed || explicitFetchFailed
            hasOwnListing = owned != nil
        }
        let openIDs = Set(currentListed.filter { $0.state == .opened }.map {
            $0.mergeRequestID
        })
        for item in results where openIDs.contains(item.id) && item.mergeRequest?.state == .opened {
            retainedCatalog[item.id] = item
        }
        for request in recordedReviews {
            let id = request.mergeRequestID
            var item = Item(id: id, title: request.title, url: request.webURL, mergeRequest: request)
            item.approvalProgress = try? await glab.fetchMergeRequestApprovalProgress(projectID: request.projectID, iid: request.iid, host: host)
            async let reviewStates = try? glab.fetchMergeRequestReviewers(projectID: request.projectID, iid: request.iid, host: host)
            async let reviewThreads = try? glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
            let (states, threads) = await (reviewStates, reviewThreads)
            if let threads {
                item.approvalProgress?.reviewHistory = MergeRequestReviewHistory(
                    reviewers: states ?? [], discussions: threads, authorID: request.author.id)
            }
            guard isCurrent(account, revision: revision) else { return }
            if item.approvalProgress?.currentApproverIDs?.contains(user.id) == false {
                settings?.setApprovalBaseline(nil, for: target(for: request), user: user)
            }
            retainedCatalog[id] = item
        }
        if let settings, feedbackDecision == nil {
            settings.mrLifecycleLedger.prepareFinishedRemoval(host: host, username: user.username)
            for target in settings.mrLifecycleLedger.targets(host: host, username: user.username) {
                let id = Item.ID(projectID: target.projectID, iid: target.iid ?? 0)
                if settings.mrLifecycleLedger.isSuppressed(target) || settings.ignoredMergeRequests.contains(target) {
                    retainedCatalog.removeValue(forKey: id)
                }
            }
            for request in settings.mrLifecycleLedger.retainedRequests(host: host, username: user.username)
                where !settings.ignoredMergeRequests.contains(target(for: request)) {
                let id = request.mergeRequestID
                if request.isOpen, var item = retainedCatalog[id] {
                    if !MRAttentionRecord.sameContext(item.mergeRequest, request) {
                        item.approvalProgress = nil
                        item.reviewingActivity = nil
                    }
                    item.mergeRequest = request
                    retainedCatalog[id] = item
                } else {
                    retainedCatalog[id] = Item(id: id, title: request.title, url: request.webURL,
                        mergeRequest: request, isAuthored: glab.owns(request, userID: user.id))
                }
            }
            settings.save()
        }
        // Retention belongs only to the read-only catalog. Stale rows do not become
        // new publication, approval or re-review action candidates.
        // Verifiers can finish while another row or retained review is being read.
        // Commit their current state, rather than the earlier per-row snapshot.
        for index in results.indices {
            let id = results[index].id
            if let published = publishedDrafts[id] {
                // Use the latest action tombstones after all catalog reads have drained.
                results[index].drafts.removeAll { published.contains($0) }
                if results[index].drafts.isEmpty { results[index].requiresDiscussionRecheck = false }
            }
            results[index].requiresCommentReview = commentReviewPending(id, account: account)
            if results[index].requiresCommentReview {
                results[index].approvalObservation = .unchecked
                results[index].reReviewFeedbackChecked = false
            }
            if results[index].isAuthored {
                applyReReviewPresentation(&results[index], unanswered: authoredUnansweredFeedback[id] ?? true)
            }
        }
        if let id = feedbackDecision {
            if let item = results.first {
                let catalog = previousCatalog[id] != nil || item.mergeRequest.map(isTracked) == true
                attentionRecords[id] = MRAttentionRecord(evidence: item, catalog: catalog ? item : nil)
                attentionCandidateIDs.insert(id)
                if catalog { catalogIDs.insert(id) }
            } else if let request = currentListed.first, !request.isOpen || isIgnored(target(for: request)) {
                attentionRecords.removeValue(forKey: id)
                attentionCandidateIDs.remove(id)
                catalogIDs.remove(id)
            }
            settings?.save()
            return
        }
        var records = retainedCatalog.mapValues { MRAttentionRecord(evidence: $0, catalog: $0) }
        for item in results {
            records[item.id] = MRAttentionRecord(evidence: item, catalog: retainedCatalog[item.id])
        }
        attentionRecords = records
        attentionRecordsRevision = revision
        attentionCandidateIDs = Set(results.map(\.id))
        catalogIDs = Set(retainedCatalog.keys)
        dependencyPresentation.reconcileCatalog(requests: (openItems + items).compactMap(\.mergeRequest),
            account: .init(host: account.host, username: account.username, revision: revision))
        // A fast verifier needs its row to exist before it can apply its result
        // and continue the re-review workflow.
        for (request, feedback, draftCount) in reReviewCandidates {
            guard isCurrent(account, revision: revision) else { return }
            await requestReReviewsIfReady(for: request, feedback: feedback, draftCount: draftCount,
                                          account: account, user: user)
        }
        if owned != nil, assigned != nil, !explicitFetchFailed {
            syncedCatalogRevision = revision
            if feedbackDecision == nil, automaticResume == nil {
                onIssueCatalogRefreshed?(openItems.compactMap(\.mergeRequest))
            }
        }
        if automaticResume == nil || automaticResume?.action == .commentPublication {
            for item in results where item.drafts.isEmpty && item.requiresCommentReview
                && (automaticResume == nil || automaticResume?.id == item.id) {
                await resumeAutomaticCommentReview(for: item.id, account: account, user: user)
            }
            await publishSettledDrafts(agentWorks: agentWorks, account: account, only: automaticResume?.id)
        }
        for item in results where item.autoApproveReady
            && (automaticResume == nil || (automaticResume?.action == .approval && automaticResume?.id == item.id)) {
            guard let request = item.mergeRequest, let head = request.sha else { continue }
            _ = await performApproval(of: item.id, head: head, automatic: true)
        }
        scheduleDependencyRefresh(account: account, revision: revision)
    }

    private nonisolated static func applyDiscussionFeedback(
        to item: inout Item, discussions: [GitLabMergeRequestDiscussion], userID: Int
    ) {
        item.observedActiveDiscussionFingerprint = ReviewVerdict.fingerprint(
            GitLabMergeRequestDiscussion.activeForReview(discussions))
        let aggregateBlocker = item.mergeRequest.map(Self.reportsDiscussionBlock) ?? item.needsDiscussion
        item.feedback = GitLabMergeRequestDiscussion.unresolvedFeedback(in: discussions, excluding: userID)
        let feedbackIDs = Set(item.feedback.compactMap(\.id))
        let unresolved = discussions.filter { discussion in
            discussion.notes.contains { $0.system != true && $0.resolvable == true && $0.resolved == false }
        }
        let uncertain = discussions.contains { discussion in
            discussion.notes.contains { $0.system != true && $0.resolvable == true && $0.resolved == nil }
        }
        let includesOther = unresolved.contains { discussion in
            !discussion.notes.contains { $0.id.map(feedbackIDs.contains) == true }
        } || ((uncertain || unresolved.isEmpty) && aggregateBlocker)
        item.discussionObservation = .init(unresolved: !unresolved.isEmpty || aggregateBlocker, includesOther: includesOther)
    }

    private nonisolated static func reportsDiscussionBlock(_ request: GitLabMergeRequest) -> Bool {
        request.blockingDiscussionsResolved == false || request.detailedMergeStatus == .discussionsNotResolved
    }

    /// The inbox is published before optional dependency reads. A cancelled predecessor
    /// drains before its replacement so slow subprocesses cannot multiply concurrency.
    private func scheduleDependencyRefresh(account: Account, revision: UInt64) {
        let previous = dependencyTask
        previous?.cancel()
        let requests = (openItems + items).compactMap(\.mergeRequest).filter { $0.state == .opened }
        let contexts = Dictionary(requests.map { ($0.mergeRequestID,
            MergeRequestDependencySummary.Context($0)) }, uniquingKeysWith: { first, _ in first })
        let projectCount = Set(requests.map(\.projectID)).count
        let waves = max(1, max((projectCount + 2) / 3, (contexts.count + 11) / 12))
        let generation = refreshGeneration
        dependencyTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, isCurrent(account, revision: revision),
                  generation == refreshGeneration else { return }
            // Drain this finite catalog in bounded waves instead of waiting for another timer poll.
            // Keep the base catalog visible and publish metadata once all initial sources were attempted.
            var summaries: [Item.ID: MergeRequestDependencySummary] = [:]
            for _ in 0..<waves {
                guard !Task.isCancelled, isCurrent(account, revision: revision),
                      generation == refreshGeneration else { return }
                summaries = await dependencyLoader.refresh(requests: requests, glab: glab, host: account.host)
                guard !Task.isCancelled, isCurrent(account, revision: revision),
                      generation == refreshGeneration else { return }
                await Task.yield()
            }
            guard !Task.isCancelled, isCurrent(account, revision: revision),
                  generation == refreshGeneration else { return }
            dependencyPresentation.acceptDependencies(summaries, requestedContexts: contexts,
                currentRequests: (openItems + items).compactMap(\.mergeRequest),
                account: .init(host: account.host, username: account.username, revision: revision))
            onRefreshed?()
        }
    }

    // MARK: - Ready for your OK

    private struct ApprovalBaselineRead: Sendable {
        let request: GitLabMergeRequest
        let startedAt: Date
        let previous: ReviewApprovalBaseline?
        let baseline: ReviewApprovalBaseline
    }

    private static func observedApprovalBaseline(for request: GitLabMergeRequest, previous: ReviewApprovalBaseline?,
                                                 approvedAt: Date?, discussions: [GitLabMergeRequestDiscussion],
                                                 host: String, glab: GlabService) async -> ReviewApprovalBaseline? {
        let metadataChangedAt = latestReviewMetadataChange(in: discussions)
        if let previous, previous.covers(request), metadataChangedAt <= previous.approvedAt {
            guard let approvedAt else { return previous }
            guard approvedAt >= previous.approvedAt else { return nil }
            return ReviewApprovalBaseline(request: request, approvedAt: approvedAt)
        }

        // A Git commit may have been created long before it was pushed to this MR.
        // Bootstrap older installations from the server's matching diff version instead.
        guard let approvedAt, previous.map({ approvedAt > $0.approvedAt }) != false,
              let versionAt = try? await glab.fetchCurrentDiffVersionDate(for: request, host: host) else { return nil }
        let changedAt = max(versionAt, metadataChangedAt)
        guard approvedAt >= changedAt else { return nil }
        if let previous, !previous.reviewedTarget.evidenceContext.binds(to: request.evidenceContext(), policy: .approvalTarget),
           changedAt <= previous.approvedAt { return nil }
        return ReviewApprovalBaseline(request: request, approvedAt: approvedAt)
    }

    private nonisolated static func latestReviewMetadataChange(in discussions: [GitLabMergeRequestDiscussion]) -> Date {
        // A retarget between branches at the same commit can leave all three diff SHAs unchanged.
        discussions.lazy.flatMap(\.notes).compactMap { note in
            guard note.system == true, let raw = note.body else { return nil }
            // GitLab returns system notes as Markdown; tolerate an HTML paragraph wrapper as well.
            let body = raw.hasPrefix("<p>") ? String(raw.dropFirst(3)) : raw
            let retargeted = body.hasPrefix("changed target branch from ")
                || (body.hasPrefix("deleted the `") && body.contains("This merge request now targets"))
            let editedText = body == "changed the description" || body.hasPrefix("changed title from ")
            guard retargeted || editedText else { return nil }
            return MergeRequestReviewHistory.date(note.createdAt)
        }.max() ?? .distantPast
    }

    private nonisolated static func reviewingAssessment(
        for item: Item, request: GitLabMergeRequest?, discussions: [GitLabMergeRequestDiscussion]?,
        host: String, user: GitLabAuthenticatedUser, verdictDirectory: URL, approvedHead: String?,
        approvalBaseline: ReviewApprovalBaseline?, previousApprovalBaseline: ReviewApprovalBaseline? = nil,
        treatAssignedMergeRequestsAsOwn: Bool
    ) -> ReviewingAssessment? {
        guard !item.isAuthored, let request, let displayed = item.mergeRequest,
              request.projectID == item.id.projectID, request.iid == item.id.iid,
              request.webURL == item.url, request.webURL == displayed.webURL,
              request.webURL.isGitLabMergeRequest(host: host, iid: request.iid),
              request.isOpen, !request.isOwned(by: user.id, includingAssignee: treatAssignedMergeRequestsAsOwn),
              let head = request.sha, !head.isEmpty,
              displayed.evidenceContext().binds(to: request.evidenceContext(), policy: .requestText),
              let discussions, ReviewVerdict.fingerprint(discussions) != nil else { return nil }
        if item.approvalProgress?.currentApproverIDs?.contains(user.id) == true {
            if MRAttentionRecord.sameContext(displayed, request), let approvalBaseline, approvalBaseline.covers(request),
               latestReviewMetadataChange(in: discussions) <= approvalBaseline.approvedAt {
                return .init(progress: .current)
            }
            var reasons: [ReviewLaunchReason] = []
            if let baseline = previousApprovalBaseline ?? approvalBaseline {
                let target = baseline.reviewedTarget
                if target.headSHA != head { reasons.append(.headChanged) }
                if let current = ReviewTargetBinding(request),
                   target.targetProjectID != current.targetProjectID || target.targetBranch != current.targetBranch
                       || target.baseSHA != current.baseSHA {
                    reasons.append(.targetChanged)
                }
                if baseline.semanticContext != request.semanticContextDigest { reasons.append(.metadataChanged) }
            }
            return .init(progress: .needsReview, reasons: reasons.isEmpty ? [.noVerifiedReview] : reasons)
        }
        guard let verdict = ReviewVerdictStore.verdict(host: host, projectID: request.projectID, iid: request.iid,
            user: user, in: verdictDirectory), verdict.version == 1 else {
            return .init(progress: .needsReview, reasons: [.noVerifiedReview])
        }
        let publishedDrafts = ReviewVerdictStore.seenDrafts(host: host, projectID: request.projectID,
            iid: request.iid, in: verdictDirectory)
        var reasons: [ReviewLaunchReason] = []
        if verdict.headSHA != head { reasons.append(.headChanged) }
        if verdict.requiresFreshReview(forSemanticContext: request.semanticContextFingerprint) {
            reasons.append(verdict.semanticContextFingerprint == nil ? .metadataCoverageMissing : .metadataChanged)
        }
        if !verdict.covers(head: verdict.headSHA, discussions: discussions, reviewerID: user.id, publishedDrafts: publishedDrafts) {
            reasons.append(verdict.discussionFingerprint == nil ? .discussionCoverageMissing : .discussionsChanged)
        }
        if !reasons.isEmpty { return .init(progress: .needsReview, reasons: reasons) }
        let ownOpen = discussions.flatMap(\.notes).contains {
            $0.system != true && $0.author?.id == user.id && $0.resolvable == true && $0.resolved != true
        }
        let alreadyApproved = head == approvedHead || item.approvalProgress?.approvedBy.contains { $0.id == user.id } == true
        return .init(progress: verdict.verdict == .noObjections && !alreadyApproved && !ownOpen && !allResolved(discussions)
            ? .waitingForOtherDiscussions : .current)
    }

    private nonisolated static func draftContextIsCurrent(
        request: GitLabMergeRequest?, drafts: [GitLabDraftNote]?, discussions: [GitLabMergeRequestDiscussion]?,
        host: String, user: GitLabAuthenticatedUser, verdictDirectory: URL, followUpReceipts: [FollowUpVerification],
        treatAssignedMergeRequestsAsOwn: Bool
    ) -> Bool {
        guard let request, request.isOpen, let head = request.sha,
              let drafts, !drafts.isEmpty, let discussions else { return false }
        if request.isOwned(by: user.id, includingAssignee: treatAssignedMergeRequestsAsOwn) {
            return drafts.allSatisfy { draft in
                followUpReceipt(for: draft, request: request, discussions: discussions, host: host, user: user,
                    verdictDirectory: verdictDirectory, receipts: followUpReceipts) != nil
            }
        }
        guard let verdict = ReviewVerdictStore.verdict(host: host, projectID: request.projectID, iid: request.iid, user: user, in: verdictDirectory),
              verdict.version == 1, verdict.evidenceContext.binds(to: .init(head: head), policy: .head),
              let fingerprint = verdict.discussionFingerprint else { return false }
        // The same content check applies to reviews with findings, not just approval verdicts.
        return ReviewVerdict(version: 1, host: host, projectID: request.projectID, iid: request.iid,
            headSHA: head, verdict: .noObjections, discussionFingerprint: fingerprint)
            .approves(head: head, discussions: discussions, reviewerID: user.id,
                publishedDrafts: ReviewVerdictStore.seenDrafts(host: host, projectID: request.projectID,
                    iid: request.iid, in: verdictDirectory))
    }

    private nonisolated static func followUpReceipt(
        for draft: GitLabDraftNote, request: GitLabMergeRequest, discussions: [GitLabMergeRequestDiscussion],
        host: String, user: GitLabAuthenticatedUser, verdictDirectory: URL, receipts: [FollowUpVerification]
    ) -> FollowUpVerification? {
        receipts.first { receipt in
            guard receipt.covers(draft, request: request, host: host, user: user, runID: receipt.runID),
                  let fingerprint = receipt.discussionFingerprint else { return false }
            return ReviewVerdict(version: 1, host: host, projectID: request.projectID, iid: request.iid,
                headSHA: receipt.headSHA, verdict: .noObjections, discussionFingerprint: fingerprint)
                .approves(head: request.sha ?? "", discussions: discussions, reviewerID: user.id,
                    publishedDrafts: ReviewVerdictStore.seenDrafts(host: host, projectID: request.projectID,
                        iid: request.iid, in: verdictDirectory))
        }
    }

    private func publicationReceipts(projectID: Int, iid: Int, host: String, username: String) -> [FollowUpVerification] {
        guard let settings else { return [] }
        return FollowUpVerificationStore.publicationReceipts(work: .init(host: host, projectID: projectID, iid: iid),
            username: username, settings: settings, in: followUpDirectory)
    }

    private func contextReceipts(projectID: Int, iid: Int, host: String, username: String) -> [FollowUpVerification] {
        guard let settings else { return [] }
        return FollowUpVerificationStore.claimReceipts(work: .init(host: host, projectID: projectID, iid: iid),
            username: username, settings: settings, in: followUpDirectory)
    }

    private struct PublicationEvidence: Sendable {
        let origin: AICommentProvenanceStore.Publication?
        let review: ReviewVerdictStore.Publication?
        let request: GitLabMergeRequest?
        let authorReply: VerifiedReplyPublication?
    }

    private struct VerifiedReplyPublication: Sendable {
        let draft: GitLabDraftNote
        let discussions: [GitLabMergeRequestDiscussion]
        let sourceNoteID: Int
        let appReceipt: VerifiedAuthorReplyDrafts.Receipt?
    }

    private func captureGeneratedPublication(_ drafts: [GitLabDraftNote], id: Item.ID, account: Account,
        user: GitLabAuthenticatedUser, before: [GitLabMergeRequestDiscussion]? = nil,
        automatic: Bool = false) async -> PublicationEvidence? {
        let context = AICommentProvenanceStore.Context(host: account.host, username: account.username, userID: user.id,
            projectID: id.projectID, iid: id.iid, legacyUsernames: settings?.knownUsernames(for: user.account(on: account.host)) ?? [])
        let generation = accountGeneration, revision = glab.accountRevision
        func current() -> Bool {
            !Task.isCancelled && generation == accountGeneration && isCurrent(account, revision: revision)
        }
        guard current() else { return nil }
        let work = AssistantAutomationRunner.MergeRequestWork(host: account.host, projectID: id.projectID, iid: id.iid)
        let request = openItems.first(where: { $0.id == id })?.mergeRequest
        let proofInput = request.map { glab.owns($0, userID: user.id) } == true ? settings.map {
            FollowUpVerificationStore.receiptReadInput(work: work, username: account.username, settings: $0, in: followUpDirectory)
        } : nil
        let directory = provenanceDirectory, proofDirectory = followUpDirectory
        let prepared = await Task.detached(priority: .utility) {
            let proofs = proofInput.map {
                FollowUpVerificationStore.contextReceipts(work: work, username: context.username, input: $0, in: proofDirectory)
            } ?? []
            return AICommentProvenanceStore.preparePublication(drafts, context: context, request: request, proofs: proofs, in: directory)
        }.value
        guard current() else { return nil }
        do {
            let authenticated = try await glab.fetchAuthenticatedUser(host: account.host, expectedUsername: account.username)
            let discussions: [GitLabMergeRequestDiscussion]
            if let before { discussions = before }
            else { discussions = try await glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host) }
            guard authenticated == user, current() else { return nil }
            let publication = await Task.detached(priority: .utility) {
                prepared.flatMap { AICommentProvenanceStore.capturePublication($0, before: discussions) }
            }.value
            guard current() else { return nil }
            let verdict = ReviewVerdictStore.authenticatedVerdict(host: account.host, projectID: id.projectID,
                iid: id.iid, user: user, settings: settings, in: verdictDirectory)
            let review = verdict.flatMap { verdict in
                guard verdict.evidenceContext.binds(to: .init(head: request?.sha), policy: .head),
                      let reviewedDrafts = ReviewVerdictStore.authenticatedReviewDrafts(for: verdict, settings: settings) else { return nil as ReviewVerdictStore.Publication? }
                return ReviewVerdictStore.capturePublication(drafts, verdict: verdict,
                    before: discussions, reviewedDrafts: reviewedDrafts, user: user, in: verdictDirectory)
            }
            let reply = automatic && drafts.count == 1 ? request.flatMap {
                verifiedReplyPublication(drafts[0], request: $0, discussions: discussions, user: user, work: work)
            } : nil
            guard publication != nil || review != nil || reply != nil else { return nil }
            return .init(origin: publication, review: review, request: request, authorReply: reply)
        } catch { return nil }
    }

    private func verifiedReplyPublication(_ draft: GitLabDraftNote, request: GitLabMergeRequest,
                                          discussions: [GitLabMergeRequestDiscussion], user: GitLabAuthenticatedUser,
                                          work: AssistantAutomationRunner.MergeRequestWork) -> VerifiedReplyPublication? {
        guard glab.owns(request, userID: user.id), let draftID = draft.id else { return nil }
        if let receipt = verifiedReplyDrafts?.receipt(for: draft, request: request, discussions: discussions, user: user, host: work.host),
           let sourceID = receipt.sourceNoteIDs.first {
            return .init(draft: draft, discussions: discussions, sourceNoteID: sourceID, appReceipt: receipt)
        }
        guard let settings, let proof = Self.followUpReceipt(for: draft, request: request, discussions: discussions,
            host: work.host, user: user, verdictDirectory: verdictDirectory,
            receipts: publicationReceipts(projectID: work.projectID, iid: work.iid, host: work.host, username: user.username)),
              let sourceID = FollowUpVerificationStore.coveredFeedbackNoteID(for: proof, draftID: draftID,
                work: work, username: user.username, settings: settings, in: followUpDirectory),
              AutomaticPublicationPolicy.sourceNotes(for: draft, discussions: discussions, userID: user.id)?.map(\.id) == [sourceID]
        else { return nil }
        return .init(draft: draft, discussions: discussions, sourceNoteID: sourceID, appReceipt: nil)
    }

    private func recordPublication(_ publication: PublicationEvidence?, draft: GitLabDraftNote, id: Item.ID,
        account: Account, user: GitLabAuthenticatedUser, origin: MRAutomationEvent.Origin,
        basedOnAuthorTrust: Bool = false) async {
        let generation = accountGeneration, revision = glab.accountRevision
        let eventID = UUID()
        settings?.recordAutomationEvent(target: commentReviewTarget(id, account: account),
            action: .publication, origin: origin, state: .completed, publicationBasedOnAuthorTrust: basedOnAuthorTrust ? true : nil,
            publication: .init(draft), id: eventID)
        var noteID: Int?
        func current() -> Bool {
            !Task.isCancelled && generation == accountGeneration && isCurrent(account, revision: revision)
        }
        defer {
            if let noteID, current() { settings?.linkAutomationPublication(eventID, noteID: noteID) }
        }
        guard let publication, current() else { return }
        do {
            let authenticated = try await glab.fetchAuthenticatedUser(host: account.host, expectedUsername: account.username)
            let discussions = try await glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
            guard authenticated == user, current() else { return }
            if let reply = publication.authorReply, let priorRequest = publication.request,
               let live = try? await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host),
               current(),
               priorRequest.draftRecoveryEvidence.binds(to: live.draftRecoveryEvidence, policy: .draftRecovery) {
                noteID = authorFeedbackCoordinator?.recordVerifiedPublication(draft: reply.draft, sourceNoteID: reply.sourceNoteID,
                    request: live, user: user, host: account.host, before: reply.discussions, after: discussions)
            }
            if let review = publication.review {
                let request = try await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
                guard current(), MRAttentionRecord.sameContext(publication.request, request),
                      ReviewVerdictStore.authenticatedVerdict(host: account.host, projectID: id.projectID,
                        iid: id.iid, user: user, settings: settings, in: verdictDirectory) == review.verdict else { return }
                try ReviewVerdictStore.recordPublication(review, after: discussions, user: user, in: verdictDirectory)
            }
            let directory = provenanceDirectory
            let matched = try await Task.detached(priority: .utility) {
                guard let origin = publication.origin else { return Set<Int>() }
                return try AICommentProvenanceStore.recordPublished(origin, after: discussions, in: directory)
            }.value
            if current(), matched.count == 1 { noteID = matched.first }
        } catch {
            Log.monitor.error("Could not record published comment origins: \(String(describing: error), privacy: .private)")
        }
    }

    private func assistantWorks(username: String) -> Set<AssistantAutomationRunner.MergeRequestWork> {
        guard let settings else { return [] }
        return Set(settings.assistantHandoffs.lazy.filter { $0.key.username == username }.map(\.key.work))
    }

    func autoApproveApplies(to request: GitLabMergeRequest, host: String, username: String) -> Bool {
        guard let settings else { return false }
        let target = MRAutomationScope.Target.mergeRequest(host: host, username: username, projectID: request.projectID, iid: request.iid)
        return settings.permitsAutomaticAction(.approval, for: request, target: target)
    }

    private func permitsAutomaticPublication(of request: GitLabMergeRequest, account: Account) -> Bool {
        let target = MRAutomationScope.Target.mergeRequest(host: account.host, username: account.username,
            projectID: request.projectID, iid: request.iid)
        return settings?.permitsAutomaticAction(.commentPublication, for: request, target: target) == true
    }

    private struct ApprovalCheck {
        var discussions: [GitLabMergeRequestDiscussion]? = nil
        /// The user is a reviewer, has not approved yet and has no unresolved thread of their own.
        var ownReady = false
        var discussionsReady = false
        /// The deterministic automatic-approval gate passed on a fresh single-MR read.
        var automaticGatePassed = false
    }

    private nonisolated static func approvalCheck(
        _ request: GitLabMergeRequest, user: GitLabAuthenticatedUser, host: String, glab: GlabService,
        verdict: ReviewVerdict?, automaticGate: (head: String, reviewed: ReviewTargetBinding?)? = nil
    ) async -> ApprovalCheck {
        async let reviewers = try? glab.fetchMergeRequestReviewers(projectID: request.projectID, iid: request.iid, host: host)
        async let discussions = try? glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
        // List reads may omit diff refs, so check the target on a single-MR read.
        async let gatePassed = automaticApprovalGatePasses(request, gate: automaticGate, host: host, glab: glab)
        guard let reviewers = await reviewers, let discussions = await discussions,
              let me = reviewers.first(where: { $0.user.id == user.id }), me.state != .approved else { return ApprovalCheck() }
        let ownOpen = discussions.contains { discussion in
            guard let first = discussion.notes.first else { return false }
            return first.author?.id == user.id && first.resolvable == true && first.resolved == false
        }
        let ready = try? await approvalDiscussionsReady(discussions, verdict: verdict, user: user, host: host, glab: glab)
        return ApprovalCheck(discussions: discussions, ownReady: !ownOpen, discussionsReady: ready == true,
            automaticGatePassed: await gatePassed)
    }

    private nonisolated static func automaticApprovalGatePasses(
        _ request: GitLabMergeRequest, gate: (head: String, reviewed: ReviewTargetBinding?)?, host: String, glab: GlabService
    ) async -> Bool {
        guard let gate, gate.reviewed != nil,
              let live = try? await glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
        else { return false }
        return AutomaticApprovalGate.permits(live, head: gate.head, reviewed: gate.reviewed)
    }

    private nonisolated static func approvalDiscussionsReady(
        _ discussions: [GitLabMergeRequestDiscussion], verdict: ReviewVerdict?,
        user: GitLabAuthenticatedUser, host: String, glab: GlabService
    ) async throws -> Bool {
        var duoAuthors: Set<Int> = []
        for discussion in GitLabMergeRequestDiscussion.activeForReview(discussions)
            where discussion.notes.contains(where: { $0.resolvable == true && $0.resolved != true }) {
            guard let author = verdict?.duoAuthorID(for: discussion, reviewerID: user.id) else { return false }
            duoAuthors.insert(author)
        }
        for author in duoAuthors.sorted() {
            guard try await glab.isGitLabDuo(userID: author, host: host) else { return false }
        }
        return true
    }

    private nonisolated static func allResolved(_ discussions: [GitLabMergeRequestDiscussion]) -> Bool {
        discussions.allSatisfy { $0.notes.allSatisfy { $0.resolvable != true || $0.resolved == true } }
    }

    private func hasActiveWorker(for id: Item.ID, account: Account) -> Bool {
        let work = AssistantAutomationRunner.MergeRequestWork(host: account.host, projectID: id.projectID, iid: id.iid)
        return settings?.assistantHandoffs.contains {
            $0.key.work == work && $0.key.username == account.username && $0.execution?.state.isActive == true
        } == true
    }

    private func didRegenerateDraft(_ previous: GitLabDraftNote, replacement: GitLabDraftNote, in id: Item.ID) {
        previousDrafts[id] = nil
        updateItem(id) {
            if let index = $0.drafts.firstIndex(of: previous) { $0.drafts[index] = replacement }
            if let draftID = replacement.id { $0.automaticDraftIDs.remove(draftID) }
        }
    }

    /// With "Publish comments without confirmation" on, publishes assistant drafts once they are
    /// unchanged across two polls, so a draft the assistant is still writing is never sent.
    private func publishSettledDrafts(
        agentWorks: Set<AssistantAutomationRunner.MergeRequestWork>, account: Account, only id: Item.ID? = nil
    ) async {
        let earlier = previousDrafts
        previousDrafts = Dictionary(uniqueKeysWithValues: items.filter { !$0.drafts.isEmpty }.map { ($0.id, $0.drafts) })
        guard let settings else { return }
        for item in items where !item.drafts.isEmpty && earlier[item.id] == item.drafts && (id == nil || id == item.id) {
            let work = AssistantAutomationRunner.MergeRequestWork(host: account.host, projectID: item.id.projectID, iid: item.id.iid)
            guard (agentWorks.contains(work) || item.isAuthored), !hasActiveWorker(for: item.id, account: account), let request = item.mergeRequest,
                  permitsAutomaticPublication(of: request, account: account)
            else { continue }
            let checkedDraftIDs: Set<Int> = Set(item.drafts.compactMap { draft in
                guard let id = draft.id, item.automaticDraftIDs.contains(id),
                      !draftRegeneration.isHeldForAutomaticPublication(draft, in: item.id) else { return nil }
                return id
            })
            let policy = settings.publicationPolicy(for: commentReviewTarget(item.id, account: account))
            guard item.automaticPublicationPolicy == policy,
                  !checkedDraftIDs.isEmpty else { continue }
            await publishDrafts(of: item.id, automatic: true, checkedDraftIDs: checkedDraftIDs)
        }
    }

    /// Cheap filters and reads do not disable the manual action or pretend a publication started.
    private func publishAIReplies(of item: Item, account: Account, checkedDraftIDs: Set<Int>,
                                  publicationOrigin: MRAutomationEvent.Origin) async {
        guard let user, !isConfirming(item.id), !hasActiveWorker(for: item.id, account: account) else { return }
        let id = item.id
        let candidates = item.drafts.filter {
            $0.id.map(checkedDraftIDs.contains) == true && $0.discussionID != nil
                && AICommentAssessmentStore.safeForAutomaticPublication($0)
        }
        guard !candidates.isEmpty else { return }
        let discussions: [GitLabMergeRequestDiscussion]
        do {
            discussions = try await glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
        } catch {
            Log.monitor.error("Could not check AI reply eligibility: \(String(describing: error), privacy: .private)")
            return
        }
        guard let settings, let request = item.mergeRequest else { return }
        let reviewTarget = commentReviewTarget(id, account: account)
        let policy = settings.publicationPolicy(for: reviewTarget)
        guard policy.mode == .aiReplies else { return }
        let evidence = await publicationNoteEvidence(in: discussions, for: candidates, policy: policy, host: account.host,
                                   projectID: id.projectID, iid: id.iid, user: user)
        func qualifies(_ draft: GitLabDraftNote, in threads: [GitLabMergeRequestDiscussion]) -> Bool {
            policy.allows(draft, request: request, discussions: threads, userID: user.id,
                          host: account.host, aiNoteIDs: evidence.ai, botNoteIDs: evidence.bots)
        }
        let eligible = candidates.filter { qualifies($0, in: discussions) }
        guard !eligible.isEmpty, isCurrent(account), !isConfirming(id) else { return }
        let generation = accountGeneration, revision = glab.accountRevision
        let reviewRevision = settings.commentReviewRevision(for: reviewTarget)
        let completion = SettingsManager.CommentReviewProgress.AutomaticPublication(
            request: item.mergeRequest, snapshot: item.commentReviewSnapshot, userID: user.id)
        confirmationStates[id] = .publishing
        defer {
            if generation == accountGeneration, confirmationStates[id] == .publishing { confirmationStates[id] = nil }
            signalAutomaticActionIdle()
        }
        var published = false
        var publishedNow: [GitLabDraftNote] = []
        var attemptedPublish = false
        var publicationChecked = false
        do {
            for draft in eligible {
                guard isCurrent(account), settings.publicationPolicy(for: reviewTarget) == policy,
                      permitsAutomaticPublication(of: request, account: account)
                else { break }
                let liveDiscussions = try await glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
                let origin = await captureGeneratedPublication([draft], id: id, account: account, user: user,
                    before: liveDiscussions, automatic: true)
                let latest = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
                guard latest.contains(draft), let draftID = draft.id, qualifies(draft, in: liveDiscussions),
                      isCurrent(account), settings.publicationPolicy(for: reviewTarget) == policy,
                      permitsAutomaticPublication(of: request, account: account) else { continue }
                guard let admitted = await automaticPublicationAdmission(draft, id: id, account: account,
                    request: request, policy: policy, generation: generation, revision: revision, authorReply: origin?.authorReply,
                    requiresPreparedDraft: publicationOrigin == .manual) else { continue }
                attemptedPublish = true
                try await glab.publishDraftNote(projectID: id.projectID, iid: id.iid, draftID: draftID,
                    host: account.host, shouldProceed: admitted.shouldProceed)
                attemptedPublish = false
                guard generation == accountGeneration, isCurrent(account, revision: revision) else { return }
                published = true
                publishedDrafts[id, default: []].append(draft)
                publishedNow.append(draft)
                self.settings?.recordAutomaticCommentPublication([draft], for: reviewTarget, revision: reviewRevision, evidence: completion)
                updateItem(id) {
                    $0.drafts.removeAll { $0 == draft }

                }
                await recordPublication(origin, draft: draft, id: id, account: account, user: user, origin: publicationOrigin,
                    basedOnAuthorTrust: publicationOrigin == .automatic && admitted.basis == .authorTrust)
            }
            publicationChecked = true
        } catch {
            if attemptedPublish, isCurrent(account) { confirmationStates[id] = .failed }
            Log.monitor.error("Could not publish AI reply: \(String(describing: error), privacy: .private)")
        }
        if published, isCurrent(account) {
            previousDrafts[id] = nil
            let finished = if publicationChecked, publishedNow.count == item.drafts.count {
                await completeAutomaticCommentReview(id, account: account, user: user, reviewRevision: reviewRevision)
            } else { false }
            await refreshReReviewAfterPublication(id, account: account, user: user, finishedCommentReview: finished)
        }
    }

    private func commentReviewTarget(_ id: Item.ID, account: Account) -> MRAutomationScope.Target {
        .mergeRequest(host: account.host, username: account.username, projectID: id.projectID, iid: id.iid)
    }

    private func commentReviewPending(_ id: Item.ID, account: Account) -> Bool {
        settings?.pendingCommentReviews.contains(commentReviewTarget(id, account: account)) == true
    }

    func deleteDraft(_ expected: GitLabDraftNote, from id: Item.ID) async {
        guard let account, isCurrent(account), let user, let draftID = expected.id, draftID > 0,
              expected.authorID == user.id, !isConfirming(id),
              let displayed = (items + openItems).first(where: { $0.id == id }),
              displayed.drafts.contains(expected) else { return }
        let generation = accountGeneration, revision = glab.accountRevision
        let current: @MainActor @Sendable () -> Bool = {
            generation == self.accountGeneration && self.isCurrent(account, revision: revision)
        }
        confirmationStates[id] = .deleting
        defer {
            if current(), confirmationStates[id] == .deleting { confirmationStates[id] = nil }
            signalAutomaticActionIdle()
        }
        do {
            let request = try await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
            let authenticated = try await glab.fetchAuthenticatedUser(host: account.host, expectedUsername: account.username)
            guard current() else { return }
            guard authenticated == user else { throw GlabError.notAuthenticated }
            guard request.isOpen, request.projectID == id.projectID, request.iid == id.iid,
                  request.webURL == displayed.url else { confirmationStates[id] = .changed; return }
            let drafts = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
            guard current() else { return }
            settings?.beginCommentReview(for: commentReviewTarget(id, account: account))
            updateItem(id) { $0.drafts = drafts }
            let matching = drafts.filter { $0.id == draftID }
            guard !matching.isEmpty else { return } // Already handled in GitLab; retain the human checkpoint.
            guard matching == [expected] else { confirmationStates[id] = .changed; return }
            try Task.checkCancellation()
            try await glab.deleteDraftNote(projectID: id.projectID, iid: id.iid, draftID: draftID, host: account.host) { !Task.isCancelled && current() }
            guard current() else { return }
            // A poll started before DELETE may still carry this exact snapshot.
            publishedDrafts[id, default: []].append(expected)
            previousDrafts[id] = nil
            updateItem(id) { $0.drafts.removeAll { $0 == expected } }
            let remaining = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
            guard current() else { return }
            updateItem(id) { $0.drafts = remaining }
        } catch {
            if current() { confirmationStates[id] = .failed }
            Log.monitor.error("Could not delete draft: \(String(describing: error), privacy: .private)")
        }
    }

    @discardableResult
    func finishCommentReview(_ displayed: Item) async -> Bool {
        let id = displayed.id
        guard let account, isCurrent(account), let user, !isConfirming(id),
              commentReviewPending(id, account: account), displayed.canFinishCommentReview,
              let snapshot = displayed.commentReviewSnapshot else { return false }
        let generation = accountGeneration
        let reviewRevision = settings?.commentReviewRevision(for: commentReviewTarget(id, account: account)) ?? 0
        confirmationStates[id] = .finishingCommentReview
        defer {
            if generation == accountGeneration, confirmationStates[id] == .finishingCommentReview { confirmationStates[id] = nil }
            signalAutomaticActionIdle()
        }
        let finished = await reconcileCommentReview(id, account: account, user: user,
            proof: .explicit(snapshot, displayed.url), reviewRevision: reviewRevision)
        if finished { await refreshReReviewAfterPublication(id, account: account, user: user, finishedCommentReview: true) }
        return finished
    }

    private func resumeAutomaticCommentReview(for id: Item.ID, account: Account, user: GitLabAuthenticatedUser) async {
        guard !isConfirming(id), let settings,
              settings.automaticCommentReviewCompletion(for: commentReviewTarget(id, account: account))?.userID == user.id,
              !hasActiveWorker(for: id, account: account) else { return }
        let generation = accountGeneration
        let reviewRevision = settings.commentReviewRevision(for: commentReviewTarget(id, account: account))
        confirmationStates[id] = .finishingCommentReview
        defer {
            if generation == accountGeneration, confirmationStates[id] == .finishingCommentReview { confirmationStates[id] = nil }
            signalAutomaticActionIdle()
        }
        if await completeAutomaticCommentReview(id, account: account, user: user, reviewRevision: reviewRevision) {
            await refreshReReviewAfterPublication(id, account: account, user: user, finishedCommentReview: true)
        }
    }

    private func completeAutomaticCommentReview(_ id: Item.ID, account: Account, user: GitLabAuthenticatedUser,
                                                reviewRevision: UInt64) async -> Bool {
        guard let receipt = settings?.automaticCommentReviewCompletion(for: commentReviewTarget(id, account: account)),
              receipt.userID == user.id else { return false }
        return await reconcileCommentReview(id, account: account, user: user,
            proof: .automaticPublication(receipt), reviewRevision: reviewRevision)
    }

    /// Only an actual, successful publication can complete the human checkpoint implicitly.
    private func completeCommentReviewAfterPublication(_ id: Item.ID, snapshot: CommentReviewSnapshot?,
                                                       published: [GitLabDraftNote], account: Account,
                                                       user: GitLabAuthenticatedUser, reviewRevision: UInt64) async -> Bool {
        guard let snapshot, !published.isEmpty,
              confirmationStates[id] != .failed, confirmationStates[id] != .changed else { return false }
        return await reconcileCommentReview(id, account: account, user: user,
            proof: .manualPublication(snapshot, published), reviewRevision: reviewRevision)
    }

    private func reconcileCommentReview(_ id: Item.ID, account: Account, user: GitLabAuthenticatedUser,
                                        proof: CommentReviewCoordinator.Proof, reviewRevision: UInt64) async -> Bool {
        guard let settings else { return false }
        let target = commentReviewTarget(id, account: account)
        let generation = accountGeneration, revision = glab.accountRevision
        func current() -> Bool {
            guard !Task.isCancelled, generation == accountGeneration,
                  EvidenceContext.sameAccountRevision(revision, glab.accountRevision),
                  isCurrent(account), self.user == user, !hasActiveWorker(for: id, account: account),
                  settings.commentReviewRevision(for: target) == reviewRevision else { return false }
            if case .automaticPublication(let receipt) = proof {
                return settings.automaticCommentReviewCompletion(for: target) == receipt
            }
            return true
        }
        do {
            let coordinator = CommentReviewCoordinator(glab: glab)
            guard var observed = try await coordinator.read(target, user: user, requireUser: proof.isExplicit, isCurrent: current),
                  current() else { return false }
            func decision(for evidence: CommentReviewCoordinator.Observation) -> CommentReviewCoordinator.Decision {
                CommentReviewCoordinator.decide(proof, observed: evidence, target: target, userID: user.id,
                    latestRequest: settings.mrLifecycleLedger.request(for: target) ?? attentionRecords[id]?.evidence.mergeRequest)
            }
            var outcome = decision(for: observed)
            if outcome == .completed {
                // Catch a note or new source commit that arrived during the initial draft read.
                guard let latest = try await coordinator.read(target, user: user, requireUser: proof.isExplicit, isCurrent: current),
                      current() else { return false }
                observed = latest
                outcome = decision(for: latest)
            }
            guard outcome != .stale else { return false }
            let wasPending = commentReviewPending(id, account: account)
            switch proof {
            case .explicit: break
            case .automaticPublication:
                settings.observeCommentReview(observed.drafts, for: target, revision: reviewRevision)
                if outcome == .changed { settings.invalidateAutomaticCommentReviewCompletion(for: target) }
            case .manualPublication:
                if outcome != .completed { settings.beginCommentReview(for: target) }
            }
            if outcome == .completed { settings.completeCommentReview(for: target) }
            if outcome == .changed { confirmationStates[id] = .changed }
            updateItem(id) {
                $0.drafts = observed.drafts
                if !proof.isExplicit { $0.commentReviewSnapshot = observed.snapshot }
            }
            return outcome == .completed && wasPending
        } catch {
            if current() { confirmationStates[id] = .failed }
            Log.monitor.error("Could not check comment review completion: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    /// Explicit consent binds the reviewed IDs and bodies, independently of automation policy.
    private static func containsReplyToResolvedDiscussion(_ drafts: [GitLabDraftNote],
                                                         in discussions: [GitLabMergeRequestDiscussion]) -> Bool {
        let resolvedIDs = Set(discussions.filter(\.isResolvedForReview).compactMap(\.id))
        return drafts.contains { $0.discussionID.map(resolvedIDs.contains) == true }
    }

    func publishDrafts(_ selected: [GitLabDraftNote], for target: MRDiscussionTarget) async {
        let id = target.mergeRequestID
        guard let account, isCurrent(account), let user, user.id > 0,
              account.host == target.host, account.username == target.username,
              target.projectID > 0, target.iid > 0,
              target.url.isGitLabMergeRequest(host: target.host, iid: target.iid),
              let item = items.first(where: { $0.id == id }) ?? openItems.first(where: { $0.id == id }),
              item.url == target.url, !isConfirming(id) else { return }
        guard !hasActiveWorker(for: id, account: account), let reviewedRequest = item.mergeRequest,
              let snapshot = item.commentReviewSnapshot,
              !selected.isEmpty, selected.allSatisfy({
                  ($0.id ?? 0) > 0 && $0.authorID == user.id && !($0.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }), Set(selected.compactMap(\.id)).count == selected.count,
              selected.allSatisfy({ draft in item.drafts.filter { $0.id == draft.id } == [draft] }) else {
            confirmationStates[id] = .changed
            return
        }
        let generation = accountGeneration, revision = glab.accountRevision
        let reviewRevision = settings?.commentReviewRevision(for: commentReviewTarget(id, account: account)) ?? 0
        let currentContext: @MainActor @Sendable () -> Bool = {
            generation == self.accountGeneration && self.isCurrent(account, revision: revision)
        }
        let ready: @MainActor @Sendable () -> Bool = {
            currentContext() && !self.hasActiveWorker(for: id, account: account)
                && MRAttentionRecord.sameContext(reviewedRequest, self.openItems.first(where: { $0.id == id })?.mergeRequest)
        }
        func display(_ drafts: [GitLabDraftNote]) {
            let visible = drafts.filter { publishedDrafts[id]?.contains($0) != true }
            updateItem(id) { $0.drafts = visible }
        }
        confirmationStates[id] = .publishing
        defer {
            // Release this run's local lock even if its account revision changed.
            if generation == accountGeneration, confirmationStates[id] == .publishing { confirmationStates[id] = nil }
            signalAutomaticActionIdle()
        }
        var remaining = selected
        var publicDrafts: [GitLabDraftNote] = []
        if let previous = manualPublicationProgress[id], EvidenceContext.sameAccountRevision(previous.accountRevision, revision),
           previous.snapshot.evidenceContext.binds(to: snapshot.evidenceContext, policy: .feedbackPresentation),
           MRAttentionRecord.sameContext(previous.request, reviewedRequest) {
            publicDrafts = previous.publicDrafts
        }
        func rememberPublicDraft(_ draft: GitLabDraftNote) {
            if !publicDrafts.contains(draft) { publicDrafts.append(draft) }
            manualPublicationProgress[id] = .init(request: reviewedRequest, snapshot: snapshot,
                accountRevision: revision, publicDrafts: publicDrafts)
            updateItem(id) { $0.rememberPublishedReply(draft) }
        }
        var publishedNow: [GitLabDraftNote] = []
        var attemptedWrite = false
        var uncertainDraft: GitLabDraftNote?
        var uncertainBeforeIDs: Set<Int> = []
        do {
            for draft in selected {
                try Task.checkCancellation()
                guard currentContext() else { return }
                guard ready() else { confirmationStates[id] = .changed; break }
                // Origin labels are optional; the mandatory live checks below authorize publication.
                let origin = await captureGeneratedPublication([draft], id: id, account: account, user: user)
                guard currentContext() else { return }
                guard ready() else { confirmationStates[id] = .changed; break }
                async let liveUser = glab.fetchAuthenticatedUser(host: account.host, expectedUsername: account.username)
                async let liveMR = glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
                async let liveDiscussions = glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
                let (authenticated, request, discussions) = try await (liveUser, liveMR, liveDiscussions)
                guard currentContext() else { return }
                guard authenticated == user else { throw GlabError.notAuthenticated }
                guard ready(), MRAttentionRecord.sameContext(reviewedRequest, request),
                      request.projectID == target.projectID, request.iid == target.iid, request.webURL == target.url,
                      snapshot.matches(request, discussions: discussions, publishedDrafts: publicDrafts, userID: user.id),
                      let checkedDigest = ReviewVerdict.discussionContentDigest(discussions) else {
                    updateItem(id) {
                        $0.invalidateChangedDiscussionSnapshot(head: request.sha, fingerprint: ReviewVerdict.fingerprint(discussions),
                            semanticContextFingerprint: request.semanticContextFingerprint)
                    }
                    confirmationStates[id] = .changed
                    break
                }
                // Read drafts last. New IDs never broaden the explicit selection.
                let current = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid,
                    host: account.host, userID: user.id)
                guard currentContext() else { return }
                display(current)
                let admitted: @MainActor @Sendable () -> Bool = {
                    guard !Task.isCancelled, ready(),
                          let fingerprint = self.openItems.first(where: { $0.id == id })?.observedDiscussionFingerprint else { return false }
                    let observed = EvidenceContext(discussionContent: .init(fingerprint))
                    return snapshot.evidenceContext.binds(to: observed, policy: .discussionContent)
                        || EvidenceContext(discussionContent: checkedDigest).binds(to: observed, policy: .discussionContent)
                }
                // A changed later selection must stop the first write too. Unselected changes are unrelated.
                guard admitted(), remaining.allSatisfy({ expected in current.filter { $0.id == expected.id } == [expected] }),
                      let draftID = draft.id else {
                    confirmationStates[id] = .changed
                    break
                }
                guard !Self.containsReplyToResolvedDiscussion(remaining, in: discussions) else {
                    confirmationStates[id] = .discussionResolved
                    break
                }
                try Task.checkCancellation()
                attemptedWrite = true
                uncertainDraft = draft
                uncertainBeforeIDs = Set(discussions.flatMap(\.notes).compactMap(\.id))
                try await glab.publishDraftNote(projectID: id.projectID, iid: id.iid, draftID: draftID,
                    host: account.host, shouldProceed: admitted)
                attemptedWrite = false
                uncertainDraft = nil
                guard currentContext() else { return }
                publishedNow.append(draft)
                rememberPublicDraft(draft)
                remaining.removeAll { $0.id == draftID }
                publishedDrafts[id, default: []].append(draft)
                display(current)
                rememberManuallyConfirmedAIReply(draft, discussions: discussions, id: id, account: account, user: user)
                await recordPublication(origin, draft: draft, id: id, account: account, user: user, origin: .manual)
            }
        } catch {
            if currentContext() {
                confirmationStates[id] = !ready() || (error is CancellationError && !Task.isCancelled) ? .changed : .failed
            }
            Log.monitor.error("Could not publish selected drafts: \(String(describing: error), privacy: .private)")
        }
        guard currentContext(), !publishedNow.isEmpty || attemptedWrite else { return }
        var authenticatedForRefresh = false
        do {
            let authenticated = try await glab.fetchAuthenticatedUser(host: account.host, expectedUsername: account.username)
            guard currentContext() else { return }
            guard authenticated == user else { throw GlabError.notAuthenticated }
            authenticatedForRefresh = true
            // A missing draft alone is only a tombstone. An ambiguous PUT needs a unique
            // newly observed own public note, with unchanged surrounding context, for continuation.
            let uncertainRequest: GitLabMergeRequest?
            let uncertainDiscussions: [GitLabMergeRequestDiscussion]?
            if uncertainDraft != nil {
                uncertainRequest = try? await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
                uncertainDiscussions = try? await glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
            } else {
                uncertainRequest = nil
                uncertainDiscussions = nil
            }
            let current = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid,
                host: account.host, userID: user.id)
            guard currentContext() else { return }
            if let uncertainDraft, !current.contains(where: { $0.id == uncertainDraft.id }) {
                publishedDrafts[id, default: []].append(uncertainDraft)
                if let request = uncertainRequest, let discussions = uncertainDiscussions,
                   MRAttentionRecord.sameContext(reviewedRequest, request),
                   snapshot.matches(request, discussions: discussions, publishedDrafts: publicDrafts + [uncertainDraft], userID: user.id) {
                    let matchingThreads = discussions.filter { thread in
                        guard let discussionID = uncertainDraft.discussionID else { return true }
                        return discussionID == thread.id
                    }
                    let notes = matchingThreads.flatMap(\.notes)
                    let written = EvidenceContext(commentText: uncertainDraft.note)
                    let matches = notes.filter { note in
                        guard note.system != true, note.author?.id == user.id, note.author?.username == account.username,
                              let id = note.id, id > 0, !uncertainBeforeIDs.contains(id),
                              written.binds(to: .init(commentText: note.body), policy: .commentText) else { return false }
                        guard let position = uncertainDraft.position else { return true }
                        return position == note.position
                    }
                    if matches.count == 1 {
                        rememberPublicDraft(uncertainDraft)
                        settings?.recordAutomationEvent(target: commentReviewTarget(id, account: account),
                            action: .publication, origin: .manual, state: .completed, publishedNoteID: matches.first?.id,
                            publication: .init(uncertainDraft))
                    }
                }
            }
            display(current)
        } catch {
            if currentContext(), confirmationStates[id] == .publishing { confirmationStates[id] = .failed }
            Log.monitor.error("Could not refresh selected draft publication: \(String(describing: error), privacy: .private)")
        }
        guard currentContext() else { return }
        previousDrafts[id] = nil
        if !publishedNow.isEmpty, authenticatedForRefresh {
            let finished = if publishedNow.count == item.drafts.count {
                await completeCommentReviewAfterPublication(id, snapshot: snapshot, published: publicDrafts,
                    account: account, user: user, reviewRevision: reviewRevision)
            } else { false }
            // A partial publication keeps the reviewed preview for continuation. A live
            // context mismatch above already invalidated stale feedback; re-review needs no drafts.
            if finished || openItems.first(where: { $0.id == id })?.drafts.isEmpty == true {
                await refreshReReviewAfterPublication(id, account: account, user: user, finishedCommentReview: finished)
            }
        }
    }

    func publishDrafts(of id: Item.ID, automatic: Bool = false, checkedDraftIDs: Set<Int> = [],
                       boardSnapshot: Item? = nil, explicitAIReply: GitLabDraftNote? = nil) async {
        guard let account, isCurrent(account), let user,
              let displayed = items.first(where: { $0.id == id }), !displayed.drafts.isEmpty,
              !isConfirming(id) else { return }
        if !automatic {
            if let boardSnapshot,
               boardSnapshot.url != displayed.url || boardSnapshot.drafts != displayed.drafts
                   || displayed.drafts.contains(where: DraftPublicationRisk.hasSideEffects) {
                confirmationStates[id] = .changed
                return
            }
            // "Publish all" never repeats a reply already in its thread; the user can still pick one explicitly.
            let publishable = displayed.publishAllDrafts
            guard !publishable.isEmpty else { return }
            await publishDrafts(publishable, for: .init(host: account.host, username: account.username,
                projectID: id.projectID, iid: id.iid, url: displayed.url))
            return
        }
        guard !checkedDraftIDs.isEmpty, !hasActiveWorker(for: id, account: account),
              explicitAIReply.map(displayed.drafts.contains) ?? true else { return }
        let publicationOrigin: MRAutomationEvent.Origin = explicitAIReply == nil ? .automatic : .manual
        if settings?.publicationPolicy(for: commentReviewTarget(id, account: account)).mode == .aiReplies {
            await publishAIReplies(of: displayed, account: account, checkedDraftIDs: checkedDraftIDs, publicationOrigin: publicationOrigin)
            return
        }
        let expected = displayed.drafts
        let generation = accountGeneration, revision = glab.accountRevision
        let reviewTarget = commentReviewTarget(id, account: account)
        let reviewRevision = settings?.commentReviewRevision(for: reviewTarget) ?? 0
        let completion = SettingsManager.CommentReviewProgress.AutomaticPublication(
            request: displayed.mergeRequest, snapshot: displayed.commentReviewSnapshot, userID: user.id)
        confirmationStates[id] = .publishing
        defer {
            if generation == accountGeneration, confirmationStates[id] == .publishing { confirmationStates[id] = nil }
            signalAutomaticActionIdle()
        }
        var publishedNow: [GitLabDraftNote] = []
        var attemptedPublish = false
        var publicationChecked = false
        do {
            let current = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
            guard isCurrent(account) else { return }
            guard current == expected else {
                updateItem(id) { $0.drafts = current }
                confirmationStates[id] = nil
                return
            }
            guard let settings,
                  let request = openItems.first(where: { $0.id == id })?.mergeRequest,
                  permitsAutomaticPublication(of: request, account: account) else {
                confirmationStates[id] = nil
                return
            }
            let policy = settings.publicationPolicy(for: reviewTarget)
            guard policy.mode == .all || policy.mode == .filtered else { return }
            // Live evidence may narrow this frozen preview, never add an ID.
            for draft in current where draft.id.map(checkedDraftIDs.contains) == true {
                let origin = await captureGeneratedPublication([draft], id: id, account: account, user: user, automatic: true)
                let latest = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
                guard latest.contains(draft), let draftID = draft.id, isCurrent(account),
                      settings.publicationPolicy(for: reviewTarget) == policy,
                      let request = openItems.first(where: { $0.id == id })?.mergeRequest,
                      permitsAutomaticPublication(of: request, account: account),
                      AICommentAssessmentStore.safeForAutomaticPublication(draft),
                      let admitted = await automaticPublicationAdmission(draft, id: id, account: account,
                        request: request, policy: policy, generation: generation, revision: revision,
                        authorReply: origin?.authorReply,
                        requiresPreparedDraft: publicationOrigin == .manual) else { continue }
                attemptedPublish = true
                try await glab.publishDraftNote(projectID: id.projectID, iid: id.iid, draftID: draftID,
                    host: account.host, shouldProceed: admitted.shouldProceed)
                attemptedPublish = false
                guard generation == accountGeneration, isCurrent(account, revision: revision) else { return }
                publishedDrafts[id, default: []].append(draft)
                publishedNow.append(draft)
                settings.recordAutomaticCommentPublication([draft], for: reviewTarget, revision: reviewRevision, evidence: completion)
                updateItem(id) { $0.drafts.removeAll { $0 == draft } }
                await recordPublication(origin, draft: draft, id: id, account: account, user: user, origin: publicationOrigin,
                    basedOnAuthorTrust: publicationOrigin == .automatic && admitted.basis == .authorTrust)
            }
            let remaining = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
            guard isCurrent(account) else { return }
            updateItem(id) { $0.drafts = remaining }
            guard !publishedNow.isEmpty else { return }
            publicationChecked = true
        } catch {
            if isCurrent(account) { confirmationStates[id] = attemptedPublish ? .failed : nil }
            Log.monitor.error("Could not publish drafts: \(String(describing: error), privacy: .private)")
        }
        // A later read or PUT can fail after an earlier draft was successfully published.
        if !publishedNow.isEmpty, isCurrent(account) {
            previousDrafts[id] = nil
            let finished = if publicationChecked, publishedNow.count == expected.count {
                await completeAutomaticCommentReview(id, account: account, user: user, reviewRevision: reviewRevision)
            } else { false }
            await refreshReReviewAfterPublication(id, account: account, user: user, finishedCommentReview: finished)
        }
    }

    /// Bind every mutable authorization input after the live proof checks, then recheck
    /// the same envelope when the transport is ready to launch the individual PUT.
    private enum PublicationBasis { case standard, authorTrust }

    private struct AutomaticPublicationAdmission {
        let basis: PublicationBasis
        let shouldProceed: @MainActor @Sendable () -> Bool
    }

    private func automaticPublicationAdmission(_ draft: GitLabDraftNote, id: Item.ID, account: Account,
        request: GitLabMergeRequest, policy: AutomaticPublicationPolicy,
        generation: Int, revision: UInt64, authorReply: VerifiedReplyPublication?,
        requiresPreparedDraft: Bool) async -> AutomaticPublicationAdmission? {
        guard let settings, let user, !draftRegeneration.isHeldForAutomaticPublication(draft, in: id) else { return nil }
        let configuration = settings.automation
        let target = commentReviewTarget(id, account: account)
        let participation = settings.reviewParticipationPreferences
        let originRevision = commentOriginRevision
        guard await permitsAssistantAutomation(for: account),
              let basis = await automaticPublicationBasis(draft, id: id, account: account,
                appReceipt: authorReply?.appReceipt, requiresPreparedDraft: requiresPreparedDraft),
              isCurrent(account), settings.automation == configuration,
              settings.publicationPolicy(for: target) == policy,
              permitsAutomaticPublication(of: request, account: account),
              !hasActiveWorker(for: id, account: account) else { return nil }
        let proofVerdict = ReviewVerdictStore.verdict(host: account.host, projectID: id.projectID, iid: id.iid, user: user, in: verdictDirectory)
        let proofReceipts = publicationReceipts(projectID: id.projectID, iid: id.iid, host: account.host, username: account.username)
        let reviewRevision = settings.commentReviewRevision(for: commentReviewTarget(id, account: account))
        let bindsReviewDraft = !glab.owns(request, userID: user.id) && (requiresPreparedDraft || basis == .authorTrust)
        let admitted: @MainActor @Sendable () -> Bool = {
            !Task.isCancelled && generation == self.accountGeneration
                && EvidenceContext.sameAccountRevision(revision, self.glab.accountRevision)
                && self.isCurrent(account) && settings.automaticPublicWritesAllowed
                && settings.automation == configuration
                && settings.publicationPolicy(for: target) == policy
                && self.openItems.first(where: { $0.id == id })?.observedEvidenceContext
                    .binds(to: request.evidenceContext(), policy: .requestText) == true
                && ReviewVerdictStore.verdict(host: account.host, projectID: id.projectID, iid: id.iid, user: user, in: self.verdictDirectory) == proofVerdict
                && self.publicationReceipts(projectID: id.projectID, iid: id.iid, host: account.host, username: account.username) == proofReceipts
                && self.appReplyAdmissionIsCurrent(authorReply, request: request, user: user, host: account.host)
                && settings.commentReviewRevision(for: self.commentReviewTarget(id, account: account)) == reviewRevision
                && settings.reviewParticipationPreferences == participation
                && self.commentOriginRevision == originRevision
                && (!bindsReviewDraft || self.authenticatedPublicationDrafts(id: id, account: account, user: user).contains(draft))
                && self.permitsAutomaticPublication(of: request, account: account)
                && !self.draftRegeneration.isHeldForAutomaticPublication(draft, in: id)
                && !self.hasActiveWorker(for: id, account: account)
        }
        return admitted() ? .init(basis: basis, shouldProceed: admitted) : nil
    }

    private func appReplyAdmissionIsCurrent(_ publication: VerifiedReplyPublication?, request: GitLabMergeRequest,
                                            user: GitLabAuthenticatedUser, host: String) -> Bool {
        guard let publication, let expected = publication.appReceipt else { return true }
        return verifiedReplyDrafts?.receipt(for: publication.draft, request: request, discussions: publication.discussions,
            user: user, host: host) == expected
    }

    func decideAIReply(_ choice: AIReplyChoice, source: AIReplyDecision, draft: GitLabDraftNote,
                       displayed: Item, originCenter: CommentOriginOverrideCenter) async -> AIReplyDecisionResult {
        let id = displayed.id
        guard let account, let user, let settings, isCurrent(account),
              let draftID = draft.id, let displayedRequest = displayed.mergeRequest,
              let displayedFingerprint = displayed.observedDiscussionFingerprint,
              displayed.drafts.contains(draft), displayed.aiReplyDecisions[draftID]?.contains(source) == true else { return .changed }
        let revision = glab.accountRevision
        let originRevision = commentOriginRevision
        let target = commentReviewTarget(id, account: account)
        let policy = settings.publicationPolicy(for: target)
        let preferences = settings.reviewParticipationPreferences
        func current() -> Bool {
            !Task.isCancelled && isCurrent(account, revision: revision)
                && !isConfirming(id) && !hasActiveWorker(for: id, account: account)
                && commentOriginRevision == originRevision && settings.reviewParticipationPreferences == preferences
                && settings.publicationPolicy(for: target) == policy
                && items.contains { item in
                    item.id == id && item.drafts.contains(draft) && item.aiReplyDecisions[draftID]?.contains(source) == true
                        && item.observedEvidenceContext.binds(to: displayed.observedEvidenceContext, policy: .accountSession)
                        && item.observedEvidenceContext.binds(to: displayed.observedEvidenceContext, policy: .verifiedFeedback)
                }
        }
        guard current(), policy.requiresAI else { return .changed }
        do {
            async let signedIn = glab.fetchAuthenticatedUser(host: account.host, expectedUsername: account.username)
            async let live = glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
            async let threads = glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
            let (liveUser, request, discussions) = try await (signedIn, live, threads)
            guard current(), liveUser == user, request.isOpen, MRAttentionRecord.sameContext(displayedRequest, request),
                  ReviewVerdict.fingerprint(discussions) == displayedFingerprint,
                  let notes = AutomaticPublicationPolicy.sourceNotes(for: draft, discussions: discussions, userID: user.id),
                  let note = notes.first(where: { AIReplyDecision($0) == source }) else { return .changed }
            let evidence = await publicationNoteEvidence(in: discussions, for: [draft], policy: policy, host: account.host,
                projectID: id.projectID, iid: id.iid, user: user)
            let drafts = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
            guard current(), drafts.filter({ $0.id == draftID }) == [draft],
                  evidence.lanes[source.id] == .unconfirmed else { return .changed }
            let classification: AICommentOriginOverride.Classification = choice == .reply ? .ai : .human
            try originCenter.applyImmediately(classification, to: [note], in: discussions, target: target,
                userID: user.id, legacyUsernames: settings.unambiguousLegacyUsernames(for: user.account(on: account.host))) { selected in
                settings.recordAIReplyTrust(classification, notes: selected, host: account.host, user: user)
            }
            invalidateCommentOriginPublication()
            updateItem(id) { item in
                for key in Array(item.aiReplyDecisions.keys) {
                    item.aiReplyDecisions[key]?.removeAll { $0.id == source.id }
                }
            }
            guard choice == .reply else { return .completed }
            await publishDrafts(of: id, automatic: true, checkedDraftIDs: [draftID], explicitAIReply: draft)
            guard isCurrent(account, revision: revision) else { return .uncertain }
            if publishedDrafts[id]?.contains(draft) == true { return .completed }
            return confirmationStates[id] == .failed ? .uncertain : .draftStillPrivate
        } catch is CancellationError {
            return .changed
        } catch {
            return .failed
        }
    }

    /// How many current drafts automation would newly publish if `becomingAI` counted as AI comments.
    /// Zero when this MR is not published automatically under the current settings.
    func automaticPublicationGain(for id: Item.ID, discussions: [GitLabMergeRequestDiscussion],
                                  becomingAI: Set<Int>) async -> Int {
        guard !becomingAI.isEmpty, let settings, let account, isCurrent(account), let user,
              settings.automaticPublicWritesAllowed,
              let item = items.first(where: { $0.id == id }), !item.drafts.isEmpty, let request = item.mergeRequest,
              permitsAutomaticPublication(of: request, account: account) else { return 0 }
        let policy = settings.publicationPolicy(for: commentReviewTarget(id, account: account))
        guard policy.mode != .manual, policy.requiresAI else { return 0 }
        let current = await publicationNoteEvidence(in: discussions, for: item.drafts, policy: policy, host: account.host,
            projectID: id.projectID, iid: id.iid, user: user)
        let widened = current.ai.union(becomingAI)
        return item.drafts.filter { draft in
            !policy.allows(draft, request: request, discussions: discussions, userID: user.id, host: account.host, aiNoteIDs: current.ai, botNoteIDs: current.bots)
                && policy.allows(draft, request: request, discussions: discussions, userID: user.id, host: account.host, aiNoteIDs: widened, botNoteIDs: current.bots)
        }.count
    }

    private struct PublicationNoteEvidence {
        var lanes: [Int: AIReplyTrustLane] = [:]
        var bots: Set<Int> = []

        var ai: Set<Int> { Set(lanes.filter { $0.value.permitsAutomaticReply }.keys) }
        var trusted: Set<Int> { Set(lanes.filter { $0.value == .trustedAuthor }.keys) }
    }

    /// Identity verification and content-bound records supply facts for both the preview and the live gate.
    private func publicationNoteEvidence(in discussions: [GitLabMergeRequestDiscussion], for drafts: [GitLabDraftNote],
                                         policy: AutomaticPublicationPolicy, host: String, projectID: Int, iid: Int,
                                         user: GitLabAuthenticatedUser) async -> PublicationNoteEvidence {
        guard policy.requiresAI || policy.allowsBotReplies else { return .init() }
        let notes = drafts.filter { policy.threadOriginPreference(for: $0) == .default }
            .flatMap { AutomaticPublicationPolicy.sourceNotes(for: $0, discussions: discussions, userID: user.id) ?? [] }
        let authors = Dictionary(grouping: notes.compactMap(\.author), by: \.id)
        var verifiedAutomation: Set<Int> = []
        for (id, identities) in authors.sorted(by: { $0.key < $1.key }) where id > 0 {
            let duo = identities.contains { $0.username?.lowercased() == "gitlabduo" }
            if duo, (try? await glab.isGitLabDuo(userID: id, host: host)) == true {
                verifiedAutomation.insert(id)
            } else if (try? await glab.feedbackAccountKind(userID: id, host: host)) == .automation {
                verifiedAutomation.insert(id)
            }
        }
        let preferences = settings?.reviewParticipationPreferences
        let automation = verifiedAutomation.union(preferences?.botIDs(host: host, username: user.username) ?? [])
        let legacyUsernames = settings?.unambiguousLegacyUsernames(for: user.account(on: host)) ?? [user.username]
        let now = Date()
        var evidence = PublicationNoteEvidence()
        for note in notes {
            guard let id = note.id, id > 0, let authorID = note.author?.id, authorID > 0 else { continue }
            let automatedAuthor = automation.contains(authorID)
            let override = AICommentOriginOverrideStore.override(for: note, host: host, projectID: projectID, iid: iid,
                username: user.username, userID: user.id, legacyUsernames: legacyUsernames, in: aiAssessmentDirectory)
            let verdict: AICommentOriginOverride.Classification? = override.map {
                $0.isActive(at: now) ? $0.classification : .uncertain
            }
            if automatedAuthor, !policy.requiresAI || verdict == nil || verdict == .ai { evidence.bots.insert(id) }
            guard policy.requiresAI else { continue }
            let definite = automatedAuthor || AICommentOriginAssessor.declaredAttribution(for: note) != nil
            let styleSaysAI = verdict == nil && !definite && hasCurrentStyleAssessment(note, policy: policy,
                host: host, projectID: projectID, iid: iid, userID: user.id, legacyUsernames: legacyUsernames)
            evidence.lanes[id] = .init(override: verdict, definite: definite, styleSaysAI: styleSaysAI,
                trustsAuthor: preferences?.aiReplyTrust(host: host, accountID: user.id, authorID: authorID)?.trustsStyleAssessment == true)
        }
        return evidence
    }

    private func hasCurrentStyleAssessment(_ note: GitLabMergeRequestDiscussion.Note, policy: AutomaticPublicationPolicy,
                                            host: String, projectID: Int, iid: Int, userID: Int, legacyUsernames: Set<String>) -> Bool {
        let directory = AICommentAssessmentStore.scopedDirectory(aiAssessmentDirectory, criteriaOverride: policy.aiCommentCriteriaOverride)
        guard let record = AICommentAssessmentStore.assessment(for: note, host: host, projectID: projectID, iid: iid,
            userID: userID, legacyUsernames: legacyUsernames, in: directory),
              record.criteriaVersion == AICommentOriginAssessor.criteriaVersion else { return false }
        return record.authorID == note.author?.id
    }

    private func rememberManuallyConfirmedAIReply(_ draft: GitLabDraftNote, discussions: [GitLabMergeRequestDiscussion],
                                                   id: Item.ID, account: Account, user: GitLabAuthenticatedUser) {
        guard let settings, let notes = AutomaticPublicationPolicy.sourceNotes(for: draft, discussions: discussions, userID: user.id)
        else { return }
        let policy = settings.publicationPolicy(for: commentReviewTarget(id, account: account))
        let legacyUsernames = settings.unambiguousLegacyUsernames(for: user.account(on: account.host))
        let confirmed = notes.filter { note in
            AICommentOriginOverrideStore.override(for: note, host: account.host, projectID: id.projectID, iid: id.iid,
                username: account.username, userID: user.id, legacyUsernames: legacyUsernames, in: aiAssessmentDirectory) == nil
                && AICommentOriginAssessor.declaredAttribution(for: note) == nil
                && hasCurrentStyleAssessment(note, policy: policy, host: account.host, projectID: id.projectID,
                    iid: id.iid, userID: user.id, legacyUsernames: legacyUsernames)
        }
        if !confirmed.isEmpty {
            settings.recordAIReplyTrust(.ai, notes: confirmed, host: account.host, user: user)
        }
    }

    /// Preparation is independent of remote-fix proof. Publication only consumes its records.
    private func scheduleAIOriginChecks(request: GitLabMergeRequest, drafts: [GitLabDraftNote],
                                        discussions: [GitLabMergeRequestDiscussion], account: Account,
                                        user: GitLabAuthenticatedUser) async {
        guard let settings, isCurrent(account), !Task.isCancelled else { return }
        let configuration = settings.automation
        let target = commentReviewTarget(.init(projectID: request.projectID, iid: request.iid), account: account)
        let policy = settings.publicationPolicy(for: target)
        let work = AssistantAutomationRunner.MergeRequestWork(host: target.host, projectID: request.projectID, iid: request.iid)
        guard !hasActiveWorker(for: .init(projectID: request.projectID, iid: request.iid), account: account),
              displayAIOriginCoordinator?.isChecking(work: work) != true,
              configuration.hasAutomaticActionConsent, policy.mode != .manual, policy.requiresAI,
              configuration.scope.permits(request, host: account.host, username: account.username) else { return }
        var sources: [Int: GitLabMergeRequestDiscussion.Note] = [:]
        for draft in drafts where policy.threadOriginPreference(for: draft) == .default
            && policy.couldAllow(draft, request: request, userID: user.id, host: account.host) {
            guard let notes = AutomaticPublicationPolicy.sourceNotes(for: draft, discussions: discussions, userID: user.id),
                  notes.allSatisfy({ note in
                      policy.restrictions.sourceCommentAuthors.isEmpty || policy.restrictions.sourceCommentAuthors.contains {
                          $0.host == account.host && $0.entityID == note.author?.id
                      }
                  }) else { continue }
            for note in notes { if let id = note.id { sources[id] = note } }
        }
        guard !sources.isEmpty else { return }
        let known = await publicationNoteEvidence(in: discussions, for: drafts, policy: policy, host: account.host,
            projectID: request.projectID, iid: request.iid, user: user)
        let unknown = sources.filter { known.lanes[$0.key] == .humanOrUncertain && !known.bots.contains($0.key) }.sorted { $0.key < $1.key }.map(\.value)
        guard !unknown.isEmpty, await permitsAssistantAutomation(for: account), isCurrent(account),
              settings.automation == configuration, settings.publicationPolicy(for: target) == policy, !Task.isCancelled,
              !hasActiveWorker(for: .init(projectID: request.projectID, iid: request.iid), account: account),
              displayAIOriginCoordinator?.isChecking(work: work) != true else { return }
        let model = configuration.assistant == .codex ? configuration.codexVerificationModel.rawValue
            : configuration.claudeVerificationModel.rawValue
        aiOriginCoordinator.schedule(target: target.forAccount(user.account(on: account.host)), notes: unknown,
            assistant: configuration.assistant, model: model, thinking: configuration.verificationThinking)
    }

    private func permitsParticipantReply(_ draft: GitLabDraftNote, request: GitLabMergeRequest,
                                        discussions: [GitLabMergeRequestDiscussion], account: Account) -> Bool {
        guard let settings, let user else { return false }
        let authorID = settings.owns(request, userID: user.id) ? user.id : request.author.id
        let semanticOptOuts = ReviewVerdict.fingerprint(discussions).flatMap {
            authorFeedbackCoordinator?.assessment(for: request, fingerprint: $0)
        }?.reviewerOptOutIDs(in: discussions, authorID: authorID) ?? []
        let receipts = publicationReceipts(projectID: request.projectID, iid: request.iid, host: account.host, username: account.username)
        let runs = Set(receipts.filter { proof in proof.drafts.contains { $0.id == draft.id } }.map(\.runID))
        let selected = settings.assistantHandoffs.filter { runs.contains($0.id) }.flatMap { $0.feedbackNoteIDs ?? [] }
        return settings.reviewParticipationPreferences.permitsAutomaticReply(draft, discussions: discussions,
            requestAuthorID: authorID, userID: user.id, host: account.host, username: account.username,
            selectedFeedbackNoteIDs: selected, semanticOptOutIDs: semanticOptOuts)
    }

    private func authenticatedPublicationDrafts(id: Item.ID, account: Account, user: GitLabAuthenticatedUser) -> [GitLabDraftNote] {
        guard let verdict = ReviewVerdictStore.authenticatedVerdict(host: account.host, projectID: id.projectID,
            iid: id.iid, user: user, settings: settings, in: verdictDirectory) else { return [] }
        return ReviewVerdictStore.authenticatedReviewDrafts(for: verdict, settings: settings) ?? []
    }

    /// Every automatic publication needs current discussion evidence. Author replies
    /// additionally need this run's exact draft and remote source content.
    private func automaticPublicationBasis(_ draft: GitLabDraftNote, id: Item.ID, account: Account,
                                             appReceipt: VerifiedAuthorReplyDrafts.Receipt?,
                                             requiresPreparedDraft: Bool) async -> PublicationBasis? {
        guard let user, !hasActiveWorker(for: id, account: account),
              let displayed = openItems.first(where: { $0.id == id })?.mergeRequest else { return nil }
        var basis: PublicationBasis?
        defer {
            if basis == nil, isCurrent(account), let draftID = draft.id {
                // A newer live read may reject a formerly eligible preview.
                // Keep that exact draft visible as a private human checkpoint.
                updateItem(id) { $0.automaticDraftIDs.remove(draftID) }
            }
        }
        guard let live = try? await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host),
              glab.owns(live, userID: user.id) == glab.owns(displayed, userID: user.id) else { return nil }
        let discussions = try? await glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
        if let appReceipt, let discussions, isCurrent(account),
           verifiedReplyDrafts?.receipt(for: draft, request: live, discussions: discussions, user: user, host: account.host) == appReceipt {
            basis = await verifiedAppReplyPublicationBasis(appReceipt, request: live, id: id, account: account, user: user)
            return basis
        }
        guard isCurrent(account), Self.draftContextIsCurrent(request: live, drafts: [draft], discussions: discussions,
            host: account.host, user: user, verdictDirectory: verdictDirectory,
            followUpReceipts: publicationReceipts(projectID: id.projectID, iid: id.iid, host: account.host, username: user.username),
            treatAssignedMergeRequestsAsOwn: settings?.treatAssignedMergeRequestsAsOwn == true) else {
            updateItem(id) { $0.requiresDiscussionRecheck = true }
            return nil
        }
        guard let discussions, let settings else { return nil }
        guard permitsParticipantReply(draft, request: live, discussions: discussions, account: account) else { return nil }
        let target = commentReviewTarget(id, account: account)
        let policy = settings.publicationPolicy(for: target)
        let evidence = await publicationNoteEvidence(in: discussions, for: [draft], policy: policy, host: account.host,
                                   projectID: id.projectID, iid: id.iid, user: user)
        guard isCurrent(account), settings.publicationPolicy(for: target) == policy,
              permitsAutomaticPublication(of: live, account: account),
              policy.allows(draft, request: live, discussions: discussions, userID: user.id,
                            host: account.host, aiNoteIDs: evidence.ai, botNoteIDs: evidence.bots) else { return nil }
        if !glab.owns(live, userID: user.id) {
            guard live.author.id != user.id else { return nil }
            if requiresPreparedDraft || !evidence.trusted.isEmpty {
                guard authenticatedPublicationDrafts(id: id, account: account, user: user).contains(draft) else { return nil }
            }
            // The discussion reads above can outlive the caller's draft snapshot.
            // Recheck the exact body so a concurrent edit cannot smuggle quick actions.
            guard let latest = try? await glab.fetchOwnDraftNotes(
                projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id
            ), latest.contains(draft), AICommentAssessmentStore.safeForAutomaticPublication(draft),
                  isCurrent(account), settings.publicationPolicy(for: target) == policy,
                  permitsAutomaticPublication(of: live, account: account) else { return nil }
            guard permitsParticipantReply(draft, request: live, discussions: discussions, account: account) else { return nil }
            basis = evidence.trusted.isEmpty ? .standard : .authorTrust
            return basis
        }
        func blocked() -> PublicationBasis? {
            updateItem(id) { $0.awaitingRemoteVerification = true }
            return nil
        }
        guard settings.automation.allowFollowUpPush else { return blocked() }
        guard let receipt = Self.followUpReceipt(for: draft, request: live, discussions: discussions,
            host: account.host, user: user, verdictDirectory: verdictDirectory,
            receipts: publicationReceipts(projectID: id.projectID, iid: id.iid, host: account.host, username: user.username)) else { return blocked() }
        do {
            let live = try await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
            guard settings.owns(live, userID: user.id), receipt.covers(draft, request: live, host: account.host, user: user, runID: receipt.runID) else { return blocked() }
            let cacheKey = "\(receipt.verificationID):\(receipt.headSHA):\(receipt.sourceProjectID)"
            if verifiedRemoteFiles[cacheKey] != receipt.files {
                for file in receipt.files {
                    guard try await glab.fetchFileSHA256(projectID: receipt.sourceProjectID, path: file.path,
                                                        ref: receipt.headSHA, host: account.host) == file.sha256 else { return blocked() }
                }
                verifiedRemoteFiles[cacheKey] = receipt.files
            }
            async let freshUser = glab.fetchAuthenticatedUser(host: account.host, expectedUsername: account.username)
            async let freshMR = glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
            async let sourceHead = glab.fetchBranchHeadSHA(projectID: receipt.sourceProjectID, branch: receipt.sourceBranch, host: account.host)
            async let currentDrafts = glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
            async let currentDiscussions = glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
            let (currentUser, currentMR, currentSource, freshDrafts, freshDiscussions) = try await (freshUser, freshMR, sourceHead, currentDrafts, currentDiscussions)
            guard currentUser == user, receipt.evidenceContext.binds(to: .init(head: currentSource), policy: .head),
                  freshDrafts.contains(draft),
                  permitsParticipantReply(draft, request: currentMR, discussions: freshDiscussions, account: account),
                  Self.draftContextIsCurrent(request: currentMR, drafts: [draft], discussions: freshDiscussions,
                    host: account.host, user: currentUser, verdictDirectory: verdictDirectory,
                    followUpReceipts: [receipt], treatAssignedMergeRequestsAsOwn: settings.treatAssignedMergeRequestsAsOwn),
                  settings.owns(currentMR, userID: currentUser.id),
                  receipt.covers(draft, request: currentMR, host: account.host, user: currentUser, runID: receipt.runID),
                  isCurrent(account), settings.automation.allowFollowUpPush,
                  publicationReceipts(projectID: id.projectID, iid: id.iid, host: account.host, username: user.username).contains(receipt),
                  permitsAutomaticPublication(of: currentMR, account: account) else { return blocked() }
            let freshEvidence = await publicationNoteEvidence(in: freshDiscussions, for: [draft], policy: policy, host: account.host,
                                            projectID: id.projectID, iid: id.iid, user: user)
            if settings.treatAssignedMergeRequestsAsOwn {
                let final = try await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
                guard final.isOpen, settings.owns(final, userID: currentUser.id),
                      MRAttentionRecord.sameContext(currentMR, final) else { return blocked() }
            }
            // Identity verification can await GitLab after the proof snapshot's draft
            // read. Re-read the exact body last so a concurrent edit cannot execute
            // a quick action or publish an unsealed author-follow-up response.
            async let latestDrafts = glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid,
                                                               host: account.host, userID: currentUser.id)
            async let latestDiscussions = glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
            let (finalDrafts, finalDiscussions) = try await (latestDrafts, latestDiscussions)
            guard finalDrafts.contains(draft), AutomaticPublicationPolicy.safeForAutomaticPublication(draft),
                  let assessedFingerprint = ReviewVerdict.fingerprint(freshDiscussions),
                  ReviewVerdict.fingerprint(finalDiscussions) == assessedFingerprint,
                  permitsParticipantReply(draft, request: currentMR, discussions: finalDiscussions, account: account),
                  isCurrent(account), settings.publicationPolicy(for: target) == policy,
                  settings.automation.allowFollowUpPush,
                  publicationReceipts(projectID: id.projectID, iid: id.iid, host: account.host, username: user.username).contains(receipt),
                  permitsAutomaticPublication(of: currentMR, account: account) else { return nil }
            guard isCurrent(account), settings.publicationPolicy(for: target) == policy,
                  policy.allows(draft, request: currentMR, discussions: finalDiscussions, userID: currentUser.id,
                                host: account.host, aiNoteIDs: freshEvidence.ai, botNoteIDs: freshEvidence.bots) else { return nil }
            basis = freshEvidence.trusted.isEmpty ? .standard : .authorTrust
            return basis
        } catch {
            Log.monitor.error("Author follow-up is awaiting remote verification: \(String(describing: error), privacy: .private)")
            return blocked()
        }
    }

    private func verifiedAppReplyPublicationBasis(_ receipt: VerifiedAuthorReplyDrafts.Receipt, request: GitLabMergeRequest,
                                         id: Item.ID, account: Account, user: GitLabAuthenticatedUser) async -> PublicationBasis? {
        guard let settings, let project = request.sourceProjectID else { return nil }
        let target = commentReviewTarget(id, account: account)
        let policy = settings.publicationPolicy(for: target)
        let host = account.host
        let revision = glab.accountRevision
        let draft = receipt.draft
        do {
            async let currentUser = glab.fetchAuthenticatedUser(host: host, expectedUsername: account.username)
            async let currentMR = glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: host)
            async let currentSource = glab.fetchBranchHeadSHA(projectID: project, branch: request.sourceBranch, host: host)
            async let currentDiscussions = glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: host)
            let (liveUser, live, head, discussions) = try await (currentUser, currentMR, currentSource, currentDiscussions)
            guard isCurrent(account, revision: revision), liveUser == user, EvidenceContext.sameHead(receipt.sourceHead, head),
                  verifiedReplyDrafts?.receipt(for: draft, request: live, discussions: discussions, user: user, host: host) == receipt
            else { return nil }
            let evidence = await publicationNoteEvidence(in: discussions, for: [draft], policy: policy, host: host,
                projectID: id.projectID, iid: id.iid, user: user)
            if settings.treatAssignedMergeRequestsAsOwn {
                let final = try await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: host)
                guard final.isOpen, settings.owns(final, userID: user.id),
                      MRAttentionRecord.sameContext(live, final) else { return nil }
            }
            async let latestDrafts = glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: host, userID: user.id)
            async let latestDiscussions = glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: host)
            let (drafts, finalDiscussions) = try await (latestDrafts, latestDiscussions)
            guard isCurrent(account) && EvidenceContext.sameAccountRevision(revision, glab.accountRevision)
                && settings.publicationPolicy(for: target) == policy
                && permitsAutomaticPublication(of: live, account: account) && !hasActiveWorker(for: id, account: account)
                && drafts.filter({ $0.id == draft.id || $0.discussionID == receipt.discussionID }) == [draft]
                && verifiedReplyDrafts?.receipt(for: draft, request: live, discussions: finalDiscussions, user: user, host: host) == receipt
                && policy.allows(draft, request: live, discussions: finalDiscussions, userID: user.id,
                    host: host, aiNoteIDs: evidence.ai, botNoteIDs: evidence.bots) else { return nil }
            return evidence.trusted.isEmpty ? .standard : .authorTrust
        } catch { return nil }
    }

    func approve(_ id: Item.ID) async {
        guard let item = (items + openItems).first(where: { $0.id == id }), item.canApprove,
              let head = item.mergeRequest?.sha else { return }
        _ = await performApproval(of: id, head: head, automatic: false)
    }

    enum PersonalApprovalResult: Equatable { case completed, changed, failed, uncertain }

    func personalApprovalAction(for row: MergeRequestBoardSnapshot.Row) -> PersonalMRApproval? {
        guard let account, isCurrent(account), let user, attentionRecordsRevision == glab.accountRevision,
              let request = row.displayRequest, request.isOpen,
              !glab.owns(request, userID: user.id), !row.isOwnMergeRequest(viewer: account.username),
              request.sha.map(GlabService.isFullGitSHA) == true,
              request.webURL.isGitLabMergeRequest(host: account.host, iid: request.iid),
              let progress = row.displayItem.approvalProgress, let approverIDs = progress.currentApproverIDs else { return nil }
        if approverIDs.contains(user.id) { return .remove }
        return progress.userCanApprove == false ? nil : .approve
    }

    func changePersonalApproval(_ action: PersonalMRApproval, for displayed: GitLabMergeRequest,
                                accountRevision: UInt64) async -> PersonalApprovalResult {
        let id = Item.ID(projectID: displayed.projectID, iid: displayed.iid)
        guard let settings, let account, isCurrent(account), let user, displayed.author.id != user.id,
              !glab.owns(displayed, userID: user.id),
              let head = displayed.sha, GlabService.isFullGitSHA(head), displayed.state == .opened,
              displayed.webURL.isGitLabMergeRequest(host: account.host, iid: id.iid),
              EvidenceContext.sameAccountRevision(accountRevision, glab.accountRevision),
              EvidenceContext.sameAccountRevision(attentionRecordsRevision, accountRevision),
              !isConfirming(id) else { return .changed }
        let generation = accountGeneration
        let target = commentReviewTarget(id, account: account)
        let isCurrentSession: @MainActor @Sendable () -> Bool = {
            generation == self.accountGeneration && EvidenceContext.sameAccountRevision(accountRevision, self.glab.accountRevision)
                && self.isCurrent(account) && !Task.isCancelled
        }
        let busy: ConfirmationState = action == .approve ? .approving : .removingApproval
        confirmationStates[id] = busy
        var submitted = false
        var needsRefresh = false
        let previousPreference = settings.independentApprovalPreferences[target]
        var savedRemovalPreference = false
        defer {
            if generation == accountGeneration, EvidenceContext.sameAccountRevision(accountRevision, glab.accountRevision) {
                if confirmationStates[id] == busy { confirmationStates[id] = nil }
                if needsRefresh { requestFeedbackRefresh() }
            }
            signalAutomaticActionIdle()
        }

        func confirm(_ progress: MergeRequestApprovalProgress?) {
            approvedHeads[id] = action == .approve ? head : nil
            failedApprovalHeads[id] = nil
            approvalReadFailures.removeValue(forKey: id)
            applyApprovalProgress(progress, to: displayed)
            updateItem(id, introducesAttention: false) {
                $0.approvalObservation = .unchecked
                if $0.reviewingProgress == .waitingForOtherDiscussions, action == .approve { $0.reviewingProgress = .current }
            }
            settings.recordAutomationEvent(target: target, action: action == .approve ? .approve : .removeApproval,
                origin: .manual, state: .completed, approvedHeadSHA: head)
        }

        do {
            let liveUser = try await glab.fetchAuthenticatedUser(host: account.host, expectedUsername: account.username)
            let counts = try await glab.fetchMergeRequestApprovalCounts(projectID: id.projectID, iid: id.iid, host: account.host)
            let current = try await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
            guard isCurrentSession(), liveUser == user, current.state == .opened,
                  MRAttentionRecord.sameContext(current, displayed),
                  let approvers = counts.approverIDs, approvers.contains(user.id) == (action == .remove),
                  action == .remove || counts.userCanApprove != false else {
                needsRefresh = true
                return .changed
            }
            if action == .remove {
                // Persist before the write so an interrupted or uncertain response cannot re-enable approval.
                settings.independentApprovalPreferences[target] = .off
                guard settings.save() else {
                    settings.independentApprovalPreferences[target] = previousPreference
                    return .failed
                }
                savedRemovalPreference = true
            }
            let canSubmit: @MainActor @Sendable () -> Bool = {
                isCurrentSession() && (action == .approve || settings.independentApprovalPreferences[target] == .off)
            }
            let progress: MergeRequestApprovalProgress?
            switch action {
            case .approve:
                progress = try await glab.approveMergeRequest(projectID: id.projectID, iid: id.iid, headSHA: head,
                    host: account.host, userID: user.id, willSubmit: { submitted = true }, shouldProceed: canSubmit)
            case .remove:
                progress = try await glab.removeMergeRequestApproval(from: displayed, host: account.host, userID: user.id,
                    willSubmit: { submitted = true }, shouldProceed: canSubmit)
            }
            guard isCurrentSession() else { return .uncertain }
            confirm(progress)
            needsRefresh = isLoading || progress == nil
            return .completed
        } catch {
            guard isCurrentSession() else { return submitted ? .uncertain : .changed }
            needsRefresh = true
            let rejected: Bool
            if case .nonZeroExit(_, let diagnostic) = error as? GlabError {
                rejected = [400, 403, 404, 409, 422].contains { GlabError.hasHTTPStatus($0, in: diagnostic) }
            } else {
                rejected = (error as? GlabError) == .notAuthenticated
            }
            if savedRemovalPreference, !submitted || rejected, settings.independentApprovalPreferences[target] == .off {
                settings.independentApprovalPreferences[target] = previousPreference
                settings.save()
            }
            if rejected { return .failed }
            if !submitted, error is CancellationError { return .changed }
            if submitted,
               let counts = try? await glab.fetchMergeRequestApprovalCounts(projectID: id.projectID, iid: id.iid, host: account.host),
               let current = try? await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host),
               isCurrentSession(), current.state == .opened, MRAttentionRecord.sameContext(current, displayed),
               let approvers = counts.approverIDs, approvers.contains(user.id) == (action == .approve) {
                confirm(counts.progress(projectID: id.projectID, iid: id.iid))
                return .completed
            }
            Log.monitor.error("Could not change personal approval: \(String(describing: error), privacy: .private)")
            return submitted ? .uncertain : .failed
        }
    }

    enum RemotePublicationResult { case completed, changed, uncertain, partial }

    func publishRemoteDrafts(of id: Item.ID, head: String, expectedDrafts: [GitLabDraftNote]) async -> RemotePublicationResult {
        guard let account, isCurrent(account), let user, let executable = glab.glabPath, !isConfirming(id),
              !expectedDrafts.isEmpty, expectedDrafts.allSatisfy(AICommentAssessmentStore.safeForAutomaticPublication),
              expectedDrafts.allSatisfy({ $0.id != nil && $0.authorID == user.id }),
              Set(expectedDrafts.compactMap(\.id)).count == expectedDrafts.count,
              let displayed = items.first(where: { $0.id == id }), displayed.drafts == expectedDrafts,
              let snapshot = displayed.commentReviewSnapshot,
              snapshot.evidenceContext.binds(to: .init(head: head), policy: .head) else { return .changed }
        let publishable = displayed.publishAllDrafts
        guard !publishable.isEmpty else { return .changed }
        let generation = accountGeneration, revision = glab.accountRevision
        let reviewRevision = settings?.commentReviewRevision(for: commentReviewTarget(id, account: account)) ?? 0
        let currentContext: @MainActor @Sendable () -> Bool = {
            generation == self.accountGeneration && EvidenceContext.sameAccountRevision(revision, self.glab.accountRevision)
                && executable == self.glab.glabPath && self.isCurrent(account)
        }
        confirmationStates[id] = .publishing
        defer {
            if generation == accountGeneration, confirmationStates[id] == .publishing { confirmationStates[id] = nil }
            signalAutomaticActionIdle()
        }
        var remaining = expectedDrafts
        var published: [GitLabDraftNote] = []
        var attemptedWrite = false
        do {
            for draft in publishable {
                try Task.checkCancellation()
                async let live = glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
                async let authenticated = glab.fetchAuthenticatedUser(host: account.host, expectedUsername: account.username)
                async let threads = try? glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
                let (request, liveUser, initialDiscussions) = try await (live, authenticated, threads)
                guard currentContext() else { return published.isEmpty ? .changed : .partial }
                guard liveUser == user else { throw GlabError.notAuthenticated }
                let discussions: [GitLabMergeRequestDiscussion]
                let origin: PublicationEvidence?
                if let initialDiscussions {
                    discussions = initialDiscussions
                    origin = await captureGeneratedPublication([draft], id: id, account: account, user: user, before: discussions)
                } else {
                    // Retry duplicate validation once. A failed capture leaves origin evidence unknown.
                    try Task.checkCancellation()
                    discussions = try await glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
                    origin = nil
                }
                let replies = DuplicateReplyDrafts.publishedReplies(in: discussions, userID: user.id)
                // Read the exact bodies last, after identity checks that can suspend.
                let drafts = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
                guard currentContext(), request.isOpen, EvidenceContext.sameHead(head, request.sha),
                      request.projectID == id.projectID, request.iid == id.iid, request.webURL == displayed.url,
                      snapshot.matches(request, discussions: discussions, publishedDrafts: published, userID: user.id),
                      drafts == remaining, let draftID = draft.id,
                      !DuplicateReplyDrafts.ids(in: drafts, published: replies).contains(draftID) else {
                    if currentContext() { confirmationStates[id] = .changed }
                    return published.isEmpty ? .changed : .partial
                }
                guard !Self.containsReplyToResolvedDiscussion([draft], in: discussions) else {
                    confirmationStates[id] = .discussionResolved
                    return published.isEmpty ? .changed : .partial
                }
                try Task.checkCancellation()
                attemptedWrite = true
                try await glab.publishDraftNote(projectID: id.projectID, iid: id.iid, draftID: draftID, host: account.host) { !Task.isCancelled && currentContext() }
                attemptedWrite = false
                guard currentContext() else { return .uncertain }
                published.append(draft)
                remaining.removeAll { $0 == draft }
                publishedDrafts[id, default: []].append(draft)
                updateItem(id) {
                    $0.drafts = remaining
                    $0.rememberPublishedReply(draft)
                }
                rememberManuallyConfirmedAIReply(draft, discussions: discussions, id: id, account: account, user: user)
                await recordPublication(origin, draft: draft, id: id, account: account, user: user, origin: .manual)
            }
            previousDrafts[id] = nil
            if remaining.isEmpty {
                let finished = await completeCommentReviewAfterPublication(id, snapshot: snapshot,
                    published: published, account: account, user: user, reviewRevision: reviewRevision)
                guard currentContext() else { return .uncertain }
                await refreshReReviewAfterPublication(id, account: account, user: user, finishedCommentReview: finished)
            }
            return currentContext() ? .completed : .uncertain
        } catch {
            if currentContext() { confirmationStates[id] = .failed }
            return attemptedWrite ? .uncertain : (published.isEmpty ? .changed : .partial)
        }
    }

    func approveRemotely(_ id: Item.ID, expectedHead: String) async -> Bool {
        guard let item = (currentItems + currentOpenItems).first(where: { $0.id == id }), item.canApprove,
              EvidenceContext.sameHead(expectedHead, item.mergeRequest?.sha) else { return false }
        return await performApproval(of: id, head: expectedHead, automatic: false)
    }

    private func applyApprovalProgress(_ progress: MergeRequestApprovalProgress?, to request: GitLabMergeRequest) {
        let id = request.mergeRequestID
        guard attentionRecordsRevision == glab.accountRevision, var record = attentionRecords[id] else { return }
        var refreshed = progress
        if MRAttentionRecord.sameContext(record.catalog?.request, request) {
            if let history = record.catalog?.approvalProgress?.reviewHistory { refreshed?.reviewHistory = history }
            record.catalog?.approvalProgress = refreshed
        }
        if MRAttentionRecord.sameContext(record.evidence.mergeRequest, request) {
            if let history = record.evidence.approvalProgress?.reviewHistory { refreshed?.reviewHistory = history }
            record.evidence.approvalProgress = refreshed
        }
        attentionRecords[id] = record
    }

    /// Re-checks the live MR, approves at `head` and reports whether GitLab confirmed it.
    private func performApproval(of id: Item.ID, head: String, automatic: Bool) async -> Bool {
        guard let account, isCurrent(account), let user, !isConfirming(id) else { return false }
        let generation = accountGeneration
        let revision = glab.accountRevision
        let target = commentReviewTarget(id, account: account)
        let displayed = (openItems + items).first { $0.id == id }?.mergeRequest
        let readContext = ApprovalReadContext(revision: revision, head: head,
            discussionFingerprint: ReviewVerdictStore.verdict(host: account.host, projectID: id.projectID,
                iid: id.iid, user: user, in: verdictDirectory)?.discussionFingerprint,
            semanticContext: displayed?.semanticContextFingerprint, configuration: settings?.automation)
        if automatic, let failure = approvalReadFailures[id], failure.context == readContext,
           approvalReadClock() < failure.retryAfter { return false }
        var submitted = false
        var approvalWithOpenFindingsRunID: UUID?
        var checkedContext = EvidenceContext()
        typealias Evidence = (request: GitLabMergeRequest, drafts: [GitLabDraftNote],
                              discussions: [GitLabMergeRequestDiscussion], user: GitLabAuthenticatedUser,
                              approvers: Set<Int>, approvalProgress: MergeRequestApprovalProgress?,
                              discussionsReady: Bool, checkedVerdict: ReviewVerdict?)
        let currentAccount: @MainActor @Sendable () -> Bool = {
            generation == self.accountGeneration && self.isCurrent(account, revision: revision)
        }
        @MainActor func readEvidence() async throws -> Evidence {
            let current = try await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
            let drafts = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
            let discussions = try await glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
            let currentUser = try await glab.fetchAuthenticatedUser(host: account.host, expectedUsername: account.username)
            let counts = try await glab.fetchMergeRequestApprovalCounts(projectID: id.projectID, iid: id.iid, host: account.host)
            guard let approvers = counts.approverIDs else { throw GlabError.decoding("GitLab did not provide merge request approvers") }
            let checkedVerdict = ReviewVerdictStore.authenticatedVerdict(host: account.host,
                projectID: id.projectID, iid: id.iid, user: user, settings: settings, in: verdictDirectory)
            let ready = automatic && checkedVerdict?.verdict == .noObjections ? try await Self.approvalDiscussionsReady(discussions, verdict: checkedVerdict,
                user: user, host: account.host, glab: glab) : true
            return (current, drafts, discussions, currentUser, approvers, counts.progress(projectID: id.projectID, iid: id.iid),
                ready, checkedVerdict)
        }
        let permits: @MainActor @Sendable (Evidence) -> Bool = { evidence in
            let current = evidence.request
            let verdict = ReviewVerdictStore.verdict(host: account.host, projectID: id.projectID, iid: id.iid, user: user, in: self.verdictDirectory)
            let covered: Bool
            let requiresAuthenticatedVerdict = automatic || verdict?.verdict == .classifiedFindings
            if requiresAuthenticatedVerdict, let verdict {
                covered = ReviewVerdictStore.automaticallyApproves(verdict, head: head,
                    discussions: evidence.discussions, user: user,
                    threshold: self.settings?.automation.autoApprovalThreshold ?? .noMajorIssues,
                    semanticContextFingerprint: current.semanticContextFingerprint,
                    legacyDuoThreadsVerified: evidence.discussionsReady, in: self.verdictDirectory)
            } else {
                covered = verdict?.approves(head: head, discussions: evidence.discussions, reviewerID: user.id,
                    publishedDrafts: ReviewVerdictStore.seenDrafts(host: account.host, projectID: id.projectID,
                        iid: id.iid, in: self.verdictDirectory)) == true
            }
            return currentAccount() && !self.commentReviewPending(id, account: account)
                && (!requiresAuthenticatedVerdict || (verdict != nil && verdict == evidence.checkedVerdict
                    && verdict == ReviewVerdictStore.authenticatedVerdict(
                    host: account.host, projectID: id.projectID, iid: id.iid, user: user,
                    settings: self.settings, in: self.verdictDirectory)))
                && evidence.user == user && current.state == .opened && current.draft != nil
                && EvidenceContext.sameHead(head, current.sha) && current.author.id != user.id
                && !self.glab.owns(current, userID: user.id) && evidence.drafts.isEmpty
                && covered
                && (!automatic || self.autoApproveApplies(to: current, host: account.host, username: account.username))
                // App-owned, model-independent proof re-checked against this fresh read, including the final one.
                && (!automatic || AutomaticApprovalGate.permits(current, head: head,
                    reviewed: evidence.checkedVerdict.flatMap { ReviewVerdictStore.authenticatedTarget(for: $0, settings: self.settings) }))
        }
        @MainActor func confirmed(_ progress: MergeRequestApprovalProgress?, for request: GitLabMergeRequest) -> Bool {
            if submitted {
                settings?.recordAutomationEvent(target: commentReviewTarget(id, account: account),
                    action: approvalWithOpenFindingsRunID == nil ? .approve : .approval,
                    origin: automatic ? .automatic : .manual, state: .completed,
                    jobID: approvalWithOpenFindingsRunID, approvedHeadSHA: approvalWithOpenFindingsRunID == nil ? nil : head)
            }
            approvedHeads[id] = head
            failedApprovalHeads[id] = nil
            approvalReadFailures.removeValue(forKey: id)
            applyApprovalProgress(progress, to: request)
            updateItem(id) {
                guard MRAttentionRecord.sameContext($0.mergeRequest, request) else { return }
                $0.approvalObservation = .unchecked
                if $0.reviewingProgress == .waitingForOtherDiscussions { $0.reviewingProgress = .current }
            }
            confirmationStates[id] = nil
            return true
        }
        confirmationStates[id] = .approving
        defer {
            if generation == accountGeneration, confirmationStates[id] == .approving { confirmationStates[id] = nil }
            signalAutomaticActionIdle()
        }
        do {
            var evidence = try await ReadOnlyAssessmentRetry.run(isCurrent: currentAccount, wait: approvalReadWait, operation: readEvidence)
            approvalReadFailures.removeValue(forKey: id)
            guard permits(evidence) else {
                guard currentAccount() else { return false }
                updateItem(id) { $0.approvalObservation = .unchecked }
                confirmationStates[id] = automatic ? nil : .changed
                return false
            }
            // The previous POST may already have succeeded despite a lost response.
            if evidence.approvers.contains(user.id) { return confirmed(evidence.approvalProgress, for: evidence.request) }
            if automatic {
                guard await permitsAssistantAutomation(for: account),
                      currentAccount(), autoApproveApplies(to: evidence.request, host: account.host, username: account.username) else {
                    if currentAccount() {
                        confirmationStates[id] = nil
                        updateItem(id) { $0.approvalObservation = .manualFallback }
                    }
                    return false
                }
            }
            @MainActor func currentPromptPolicy() -> AutomaticActionPromptGate.Policy? {
                guard automatic, let settings else { return nil }
                return .init(.approval, target: target, settings: settings)
            }
            let promptPolicy = currentPromptPolicy()
            var promptCandidate: AutomaticActionPromptGate.Candidate?
            if let promptPolicy, let settings {
                guard permits(evidence),
                      let candidate = AutomaticActionPromptGate.Candidate(action: .approval, target: target,
                          userID: user.id, accountRevision: revision, policy: promptPolicy, request: evidence.request,
                          discussions: evidence.discussions) else { return false }
                let assessedEvidence = evidence
                guard await actionPromptGate.allows(candidate, request: evidence.request, discussions: evidence.discussions,
                    settings: settings, accountIsCurrent: currentAccount,
                    isEligible: { permits(assessedEvidence) && currentPromptPolicy() == promptPolicy }) else {
                    if currentAccount() { updateItem(id) { $0.approvalObservation = .manualFallback } }
                    return false
                }
                promptCandidate = candidate
            }
            let checkedPromptCandidate = promptCandidate
            if checkedPromptCandidate != nil || (automatic && evidence.checkedVerdict?.verdict == .classifiedFindings) {
                evidence = try await ReadOnlyAssessmentRetry.run(isCurrent: currentAccount, wait: approvalReadWait, operation: readEvidence)
                guard permits(evidence), currentPromptPolicy() == promptPolicy,
                      checkedPromptCandidate?.matches(evidence.request) != false,
                      checkedPromptCandidate?.matches(evidence.discussions) != false else { return false }
                if evidence.approvers.contains(user.id) { return confirmed(evidence.approvalProgress, for: evidence.request) }
            }
            let checkedEvidence = evidence
            checkedContext = .init(discussionContent: ReviewVerdict.discussionContentDigest(checkedEvidence.discussions),
                                   semanticContext: checkedEvidence.request.semanticContextDigest)
            var progress = try await glab.approveMergeRequest(projectID: id.projectID, iid: id.iid, headSHA: head,
                host: account.host, userID: user.id, willSubmit: {
                    submitted = true
                    if automatic, let verdict = checkedEvidence.checkedVerdict, verdict.verdict == .classifiedFindings,
                       !ReviewVerdictStore.automaticallyApproves(verdict, head: head,
                            discussions: checkedEvidence.discussions, user: user, threshold: .noIssues,
                            semanticContextFingerprint: checkedEvidence.request.semanticContextFingerprint, in: self.verdictDirectory) {
                        approvalWithOpenFindingsRunID = verdict.runID
                    }
                }, shouldProceed: { permits(checkedEvidence) && currentPromptPolicy() == promptPolicy })
            guard currentAccount() else { return false }
            if progress == nil,
               let observed = try? await glab.fetchMergeRequestApprovalProgress(projectID: id.projectID, iid: id.iid, host: account.host),
               observed.currentApproverIDs?.contains(user.id) == true,
               let current = try? await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host),
               MRAttentionRecord.sameContext(current, checkedEvidence.request) {
                progress = observed
            }
            guard currentAccount() else { return false }
            return confirmed(progress, for: checkedEvidence.request)
        } catch {
            guard currentAccount() else { return false }
            if submitted,
               let evidence = try? await ReadOnlyAssessmentRetry.run(isCurrent: currentAccount, wait: approvalReadWait, operation: readEvidence),
               permits(evidence), evidence.approvers.contains(user.id),
               checkedContext.binds(to: .init(discussionContent: ReviewVerdict.discussionContentDigest(evidence.discussions),
                                              semanticContext: evidence.request.semanticContextDigest),
                                    policy: .feedbackPresentation) {
                return confirmed(evidence.approvalProgress, for: evidence.request)
            }
            guard currentAccount() else { return false }
            // Pure GET failures cannot establish that GitLab rejected a write.
            // An attempted, unconfirmed POST keeps the existing deliberate retry fence.
            if automatic && !submitted {
                approvalReadFailures[id] = (readContext, approvalReadClock().addingTimeInterval(ReadOnlyAssessmentRetry.cooldown))
                confirmationStates[id] = nil
            } else {
                confirmationStates[id] = .failed
                if submitted { failedApprovalHeads[id] = head }
            }
            Log.monitor.error("Could not approve merge request: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    private func isConfirming(_ id: Item.ID) -> Bool {
        confirmationStates[id]?.isBusy == true || draftRegeneration.isSaving(id)
    }

    private func updateItem(_ id: Item.ID, introducesAttention: Bool = true,
                            skipUnchangedPendingDraftEvidence: Bool = false, _ change: (inout Item) -> Void) {
        guard attentionRecordsRevision == glab.accountRevision, var record = attentionRecords[id] else { return }
        var item = record.evidence
        change(&item)
        if !item.aiReplyDecisions.isEmpty {
            item.aiReplyDecisions = item.aiReplyDecisions.filter { draftID, _ in
                let before = record.evidence.drafts.first { $0.id == draftID }
                return before != nil && item.drafts.contains { $0.id == draftID && $0 == before }
            }
        }
        if let account {
            item.requiresCommentReview = commentReviewPending(id, account: account)
            if item.requiresCommentReview { item.approvalObservation = .unchecked; item.reReviewFeedbackChecked = false }
        }
        if item.drafts.isEmpty { item.awaitingRemoteVerification = false; item.requiresDiscussionRecheck = false }
        else if item.isAuthored, let settings, let account, let user, let request = item.mergeRequest {
            let work = AssistantAutomationRunner.MergeRequestWork(host: account.host, projectID: id.projectID, iid: id.iid)
            if assistantWorks(username: user.username).contains(work) {
                let receipts = publicationReceipts(projectID: id.projectID, iid: id.iid,
                    host: account.host, username: user.username)
                // Conditions that definitely exclude these drafts do not require
                // automatic remote proof; they remain ordinary manual checkpoints.
                let candidates = item.drafts.filter { draft in
                    let mayHaveSource = item.incomingReplyDiscussionIDs.map { ids in
                        draft.discussionID.map(ids.contains) == true
                    } ?? true
                    return mayHaveSource && settings.automation.scope.permits(request, host: account.host, username: account.username)
                        && settings.publicationPolicy(for: commentReviewTarget(id, account: account)).couldAllow(
                            draft, request: request, userID: user.id, host: account.host)
                }
                item.awaitingRemoteVerification = !candidates.isEmpty && (
                    item.awaitingRemoteVerification || !settings.automation.allowFollowUpPush
                        || candidates.contains { draft in
                            return !receipts.contains { $0.covers(draft, request: request, host: account.host, user: user, runID: $0.runID) }
                        })
            }
        }
        if !skipUnchangedPendingDraftEvidence || !item.hasSamePendingDraftEvidence(as: record.evidence) {
            record.replaceEvidence(item)
            attentionRecords[id] = record
        }
        if introducesAttention, item.needsAttention, !attentionCandidateIDs.contains(id) { attentionCandidateIDs.insert(id) }
    }

    func observePendingDrafts() async {
        await pendingDraftPolling.observe { [weak self] in await self?.refreshPendingDrafts() }
    }

    /// Recheck visible confirmations against live discussions, including unchanged drafts.
    func refreshPendingDrafts() async {
        guard !Task.isCancelled, !isLoading, !isRefreshingDrafts, let account, isCurrent(account), let user else { return }
        let generation = refreshGeneration
        let revision = glab.accountRevision
        isRefreshingDrafts = true
        defer { isRefreshingDrafts = false; signalAutomaticActionIdle() }
        for item in items where item.needsConfirmation && !isConfirming(item.id) {
            let target = commentReviewTarget(item.id, account: account)
            let reviewRevision = settings?.commentReviewRevision(for: target) ?? 0
            guard !Task.isCancelled, generation == refreshGeneration,
                  EvidenceContext.sameAccountRevision(revision, glab.accountRevision) else { return }
            let read = await glab.fetchPendingDraftRead(projectID: item.id.projectID, iid: item.id.iid,
                host: account.host, userID: user.id)
            guard !Task.isCancelled, generation == refreshGeneration,
                  EvidenceContext.sameAccountRevision(revision, glab.accountRevision),
                  isCurrent(account), !isLoading, !isConfirming(item.id),
                  let latest = items.first(where: { $0.id == item.id }), latest.drafts == item.drafts,
                  MRAttentionRecord.sameContext(latest.mergeRequest, item.mergeRequest),
                  (settings?.commentReviewRevision(for: target) ?? 0) == reviewRevision else { continue }
            guard var current = read.drafts else {
                updateItem(item.id, skipUnchangedPendingDraftEvidence: true) {
                    $0.requiresDiscussionRecheck = !$0.drafts.isEmpty
                    $0.approvalObservation = .unchecked
                    $0.reReviewFeedbackChecked = false
                    $0.reviewingProgress = nil
                }
                continue
            }
            current.removeAll { publishedDrafts[item.id]?.contains($0) == true }
            settings?.observeCommentReview(current, for: target, revision: reviewRevision)
            let request = read.request
            let discussions = read.discussions
            let contextMatches = MRAttentionRecord.sameContext(request, item.mergeRequest)
            let contextCurrent = contextMatches && Self.draftContextIsCurrent(request: request, drafts: current, discussions: discussions,
                host: account.host, user: user, verdictDirectory: verdictDirectory,
                followUpReceipts: contextReceipts(projectID: item.id.projectID, iid: item.id.iid,
                    host: account.host, username: user.username),
                treatAssignedMergeRequestsAsOwn: settings?.treatAssignedMergeRequestsAsOwn == true)
            let approvalCurrent = contextMatches && (request.flatMap { request in
                discussions.map { discussions in
                    if let verdict = ReviewVerdictStore.authenticatedVerdict(host: account.host, projectID: item.id.projectID,
                        iid: item.id.iid, user: user, settings: settings, in: verdictDirectory), verdict.verdict == .classifiedFindings {
                        return request.isOpen && ReviewVerdictStore.automaticallyApproves(verdict, head: request.sha ?? "",
                            discussions: discussions, user: user, threshold: settings?.automation.autoApprovalThreshold ?? .noMajorIssues,
                            semanticContextFingerprint: request.semanticContextFingerprint, in: verdictDirectory)
                    }
                    return ReviewVerdictStore.verdict(host: account.host, projectID: item.id.projectID, iid: item.id.iid, user: user, in: verdictDirectory)?
                        .approves(head: request.sha ?? "", discussions: discussions, reviewerID: user.id,
                            publishedDrafts: ReviewVerdictStore.seenDrafts(host: account.host, projectID: item.id.projectID,
                                iid: item.id.iid, in: verdictDirectory)) == true && request.isOpen
                }
            } ?? false)
            updateItem(item.id, skipUnchangedPendingDraftEvidence: true) {
                $0.drafts = current
                $0.commentReviewSnapshot = CommentReviewSnapshot(request: request, discussions: discussions)
                $0.incomingReplyDiscussionIDs = contextMatches
                    ? AutomaticPublicationPolicy.incomingDiscussionIDs(in: discussions, userID: user.id) : nil
                if contextMatches, let discussions {
                    $0.ownPublishedReplies = DuplicateReplyDrafts.publishedReplies(in: discussions, userID: user.id)
                }
                $0.reviewingAssessment = contextMatches ? Self.reviewingAssessment(for: item, request: request,
                    discussions: discussions, host: account.host, user: user, verdictDirectory: verdictDirectory,
                    approvedHead: approvedHeads[item.id], approvalBaseline: settings?.approvalBaseline(for: target, user: user),
                    treatAssignedMergeRequestsAsOwn: settings?.treatAssignedMergeRequestsAsOwn == true) : nil
                if !$0.isAuthored, let request {
                    $0.reviewingActivity = discussions.map {
                        ReviewingActivity(discussions: $0, reviewerID: user.id, authorID: request.author.id)
                    }
                }
                $0.invalidateChangedDiscussionSnapshot(head: request?.sha,
                    fingerprint: discussions.flatMap { ReviewVerdict.fingerprint($0) },
                    semanticContextFingerprint: request?.semanticContextFingerprint)
                $0.requiresDiscussionRecheck = !current.isEmpty && !contextCurrent
                if !approvalCurrent { $0.approvalObservation = .unchecked }
                let reReviewMatches: Bool
                if contextMatches, let request, let discussions {
                    let recorded = item.mergeRequest?.evidenceContext(
                        discussionContent: item.reReviewFingerprint.map(DiscussionContentDigest.init)) ?? .init()
                    let live = request.evidenceContext(discussionContent: ReviewVerdict.discussionContentDigest(discussions))
                    reReviewMatches = recorded.binds(to: live, policy: .feedbackPresentation)
                } else {
                    reReviewMatches = false
                }
                if !reReviewMatches {
                    $0.reReviewFeedbackChecked = false
                }
            }
            if current != item.drafts {
                confirmationStates[item.id] = nil
                previousDrafts[item.id] = nil
                await refreshReReviewAfterPublication(item.id, account: account, user: user)
            }
        }
    }

    private func refreshReReviewAfterPublication(_ id: Item.ID, account: Account, user: GitLabAuthenticatedUser,
                                                 finishedCommentReview: Bool = false) async {
        let generation = accountGeneration, revision = glab.accountRevision
        func current() -> Bool {
            !Task.isCancelled && generation == accountGeneration && EvidenceContext.sameAccountRevision(revision, glab.accountRevision)
                && isCurrent(account) && self.user == user
        }
        defer { if finishedCommentReview, current() { onCommentReviewFinished?(id) } }
        let coordinator = CommentReviewCoordinator(glab: glab)
        guard openItems.first(where: { $0.id == id })?.isAuthored == true,
              let observed = try? await coordinator.read(commentReviewTarget(id, account: account), user: user, isCurrent: current),
              glab.owns(observed.request, userID: user.id), current() else { return }
        let request = observed.request, discussions = observed.discussions
        updateItem(id) {
            $0.invalidateChangedDiscussionSnapshot(head: request.sha, fingerprint: ReviewVerdict.fingerprint(discussions),
                semanticContextFingerprint: request.semanticContextFingerprint)
        }
        authorFeedbackCoordinator?.refresh(request: request, discussions: discussions, drafts: observed.drafts.count,
            host: account.host, user: user)
        await requestReReviewsIfReady(for: request, feedback: ReReviewFeedback(discussions: discussions, authorID: user.id),
                                      draftCount: observed.drafts.count, account: account, user: user, discussions: discussions)
    }

    private func reReviewContext(_ id: Item.ID, account: Account) -> ReReviewCoordinator.Context {
        .init(host: account.host, username: account.username, revision: glab.accountRevision,
            projectID: id.projectID, iid: id.iid)
    }

    func discussionAssessment(for request: GitLabMergeRequest, fingerprint: String,
                              activeFingerprint: String?) -> ReReviewAssessment? {
        if let assessment = authorFeedbackCoordinator?.assessment(for: request, fingerprint: fingerprint) {
            return assessment
        }
        guard let activeFingerprint, let account, isCurrent(account) else { return nil }
        let id = request.mergeRequestID
        return reReviewCoordinator?.discussionAssessment(for: request, fingerprint: fingerprint,
            activeFingerprint: activeFingerprint, context: reReviewContext(id, account: account))
    }

    private func applyReReviewPresentation(_ item: inout Item, unanswered: Bool) {
        guard let account else { return }
        item.requiresCommentReview = commentReviewPending(item.id, account: account)
        if item.requiresCommentReview { item.approvalObservation = .unchecked }
        let status = reReviewCoordinator?.currentStatus(for: reReviewContext(item.id, account: account),
            request: item.mergeRequest, fingerprint: item.observedDiscussionFingerprint,
            activeFingerprint: item.observedActiveDiscussionFingerprint, authorID: user?.id)
        item.reReviewReadiness = status?.state
        item.reReviewFingerprint = status?.fingerprint
        item.reReviewFeedbackChecked = status != nil && !unanswered && item.drafts.isEmpty && !item.requiresCommentReview
        item.reReviewRequested = status?.requested ?? false
        item.reReviewUnconfirmed = status?.unconfirmed ?? false
    }

    private func updateReReviewPresentation(_ id: Item.ID, unanswered: Bool = false) {
        // A background presentation update cannot admit a retained-only catalog row.
        updateItem(id, introducesAttention: false) { applyReReviewPresentation(&$0, unanswered: unanswered) }
    }

    func retryReReview(_ id: Item.ID) async {
        guard let account, let user, isCurrent(account) else { return }
        let context = reReviewContext(id, account: account)
        if reReviewCoordinator?.hasSharedFeedbackConcern(context) == true {
            retryAuthorFeedback(id)
        } else {
            await reReviewCoordinator?.retry(context, user: user)
        }
    }

    func cancelRuntimePreparation(outsideScope scope: MRAutomationScope) {
        reReviewCoordinator?.cancelRuntimePreparation(outsideScope: scope)
    }

    func automationConfigurationChanged(outsideScope scope: MRAutomationScope? = nil) {
        authorFeedbackCoordinator?.cancel(outsideScope: scope)
        draftProofRecoveryCoordinator?.cancel(outsideScope: scope)
        aiOriginCoordinator.cancel(outsideScope: scope)
        displayAIOriginCoordinator?.cancel(outsideScope: scope)
        feedbackNeedsRefresh = false
        reReviewCoordinator?.cancel(outsideScope: scope)
    }

    func retryFailedReReviews() async {
        guard let user else { return }
        await reReviewCoordinator?.retryFailed(user: user)
    }

    func confirmReReview(_ id: Item.ID, head: String, fingerprint: String) async {
        guard let account, let user, isCurrent(account), let reReviewCoordinator else { return }
        let context = reReviewContext(id, account: account)
        let result = await reReviewCoordinator.confirm(context, user: user, head: head, fingerprint: fingerprint)
        guard isCurrent(account), glab.accountRevision == context.revision else { return }
        switch result {
        case .changed:
            confirmationStates[id] = .changed
            refresh(host: account.host, username: account.username, todos: [])
        case .unansweredFeedback: confirmationStates[id] = .changed
        case .failed: confirmationStates[id] = .failed
        case .ignored, .confirmed: break
        }
    }

    private func requestReReviewsIfReady(
        for request: GitLabMergeRequest, feedback: ReReviewFeedback, draftCount: Int,
        account: Account, user: GitLabAuthenticatedUser, discussions: [GitLabMergeRequestDiscussion]? = nil
    ) async {
        await reReviewCoordinator?.refresh(for: request, feedback: feedback, draftCount: draftCount,
            context: reReviewContext(.init(projectID: request.projectID, iid: request.iid), account: account),
            user: user, discussions: discussions)
    }
}
