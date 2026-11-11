import Foundation
import Observation

@MainActor
@Observable
final class MergeRequestAttentionMonitor {
    struct Item: Identifiable, Sendable {
        struct ID: Hashable, Sendable {
            let projectID: Int
            let iid: Int
        }

        enum Section: Int {
            case open, unpublishedComments, draftMergeRequests
        }

        let id: ID
        var title: String
        var url: URL
        var lifecycleCompletionID: UUID?
        var draftCount = 0
        var requiresCommentReview = false
        var commentReviewSnapshot: CommentReviewSnapshot?
        /// The current user's unpublished drafts, shown in Ready for your OK.
        var drafts: [GitLabDraftNote] = []
        /// Exact drafts covered by automatic publication, including the stability wait.
        var automaticDraftIDs: Set<Int> = []
        var automaticPublicationPolicy: AutomaticPublicationPolicy?
        var replyRecipients: [String: String] = [:]
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
        /// Presentation only; the shared human-action projection leaves raw safety evidence intact.
        var humanActionRequired: Bool?
        /// The assistant has no objections to the current head and the user has nothing open,
        /// but automatic approval does not apply, so the user approves in Ready for your OK.
        var canApprove = false
        /// Deliberate automatic-approval opt-out is not a human checkpoint until
        /// every discussion permits that automatic action. Manual approval stays available.
        var approvalWaitingForReadiness = false
        /// Automatic approval applies and every discussion is resolved.
        var autoApproveReady = false
        var needsDiscussion = false
        var hasOtherUnresolvedDiscussions = false
        var hasConflict = false
        var needsChanges = false
        /// nil means the current reviewer states could not be read.
        var changeRequestReviewers: Set<String>?
        var approvalProgress: MergeRequestApprovalProgress?
        var needsMerge = false
        var failedPipeline = false
        var needsPipelineHandoff = false
        var reReviewUnconfirmed = false
        var reReviewRequested = false
        var reReviewReadiness: ReReviewReadiness?
        var reReviewFingerprint: String?
        var canConfirmReReview = false
        var draftFromTodo = false
        var mergeRequest: GitLabMergeRequest?
        var isAuthored = false
        var feedback: [GitLabMergeRequestDiscussion.Note] = []
        /// Informational participation from complete discussions; nil means not loaded.
        var reviewingActivity: ReviewingActivity?
        var reviewingProgress: ReviewingProgress?
        /// Canonical read-only stack/dependency metadata, separate from merge permissions.
        var dependencies: MergeRequestDependencySummary?

        var authoredRequest: GitLabMergeRequest? { isAuthored ? mergeRequest : nil }
        var canFinishCommentReview: Bool {
            requiresCommentReview && draftCount == 0 && drafts.isEmpty && commentReviewSnapshot?.covers(mergeRequest) == true
        }

        func draftIDsHandledAutomatically(automation: AutomationSettings, target: MRAutomationScope.Target,
                                          assistantPreparing: Bool, publicationAutomatic: Bool = true) -> Set<Int> {
            guard automation.hasAutomaticPublicActionConsent, publicationAutomatic, assistantPreparing, automation.publicationMode != .manual, let request = mergeRequest,
                  automaticPublicationPolicy == automation.automaticPublicationPolicy,
                  automation.scope.permits(request, host: target.host, username: target.username),
                  !isAuthored || automation.allowFollowUpPush else { return [] }
            return automaticDraftIDs
        }

        func presentingVerifiedAuthorFeedback() -> Self {
            var visible = self
            guard isAuthored, let status = authorFeedbackStatus,
                  status.head == mergeRequest?.sha,
                  status.semanticContextFingerprint == nil
                    || status.semanticContextFingerprint == mergeRequest?.semanticContextFingerprint else {
                visible.authorFeedbackStatus = nil
                return visible
            }
            guard status.phase == .complete else { return visible }
            guard status.fingerprint == observedDiscussionFingerprint else {
                visible.authorFeedbackStatus = nil
                return visible
            }
            let addressed = status.addressedNoteIDs.subtracting(status.replyNoteIDs).union(status.ignoredNoteIDs)
            visible.feedback.removeAll { $0.id.map(addressed.contains) == true }
            if visible.feedback.count != feedback.count && visible.feedback.isEmpty {
                visible.needsDiscussion = hasOtherUnresolvedDiscussions
            }
            if status.semanticContextFingerprint == mergeRequest?.semanticContextFingerprint,
               status.semanticContextFingerprint != nil,
               status.waitingForReviewer, status.ignoredNoteIDs.isEmpty,
               let changeRequestReviewers, !changeRequestReviewers.isEmpty,
               changeRequestReviewers.isSubset(of: Set(status.findings.filter { $0.state == .waitingAcceptance }.flatMap(\.waitingForReviewers))),
               visible.feedback.isEmpty, !status.needsAttention,
               status.followUpNoteIDs.isEmpty, status.replyNoteIDs.isEmpty,
               status.pendingDraftCount == 0, draftCount == 0, drafts.isEmpty {
                // GitLab may still block merging until acceptance; that is reviewer work.
                visible.needsChanges = false
            }
            return visible
        }

        /// A partial read cannot bind existing raw feedback to a newly observed conversation.
        mutating func invalidateChangedDiscussionSnapshot(head: String?, fingerprint: String?, semanticContextFingerprint: String? = nil) {
            guard let head, head == mergeRequest?.sha,
                  let fingerprint, fingerprint == observedDiscussionFingerprint,
                  semanticContextFingerprint == nil
                    || semanticContextFingerprint == mergeRequest?.semanticContextFingerprint else {
                observedDiscussionFingerprint = nil
                return
            }
        }

        func canOfferMerge(using status: AuthoredMergeRequestStatus) -> Bool {
            status.blockers.isEmpty && status.request.isReadyForMergeChecks
                && status.request.projectID == id.projectID && status.request.iid == id.iid
                && status.request.webURL == mergeRequest?.webURL && status.request.sha == mergeRequest?.sha
                && !requiresCommentReview && draftCount == 0 && !needsDiscussion && feedback.isEmpty && !needsChanges && !hasConflict
                && !failedPipeline && !needsPipelineHandoff && mergeRequest?.state == "opened"
                && mergeRequest?.draft == false && mergeRequest?.detailedMergeStatus == "mergeable"
                && mergeRequest?.hasMergeConflict == false && mergeRequest?.blockingDiscussionsResolved != false
                && (mergeRequest?.headPipeline == nil || mergeRequest?.headPipeline?.status == "success")
        }

        func requiringUserAttention(
            automation: AutomationSettings, target: MRAutomationScope.Target,
            failedTriggers: Set<MergeWorkflowTrigger> = [], conflictTaskFailed: Bool = false,
            pipelineOwnedAutomatically: Bool = false, feedbackOwnedAutomatically: Bool = false
        ) -> Self {
            guard automation.hasAutomaticActionConsent, let request = authoredRequest, request.state == "opened",
                  request.author.username == target.username,
                  request.projectID == target.projectID, request.iid == target.iid,
                  request.webURL.isGitLabMergeRequest(host: target.host, iid: request.iid),
                  automation.scope.permits(request, host: target.host, username: target.username) else { return self }
            func handles(_ trigger: MergeWorkflowTrigger) -> Bool {
                let rule = automation.workflowRules[trigger]
                return rule.mode == .assistant && rule.includes(request) && !failedTriggers.contains(trigger)
            }
            // Filter a presentation copy. Settings changes must reveal the original reasons immediately.
            var visible = self
            if automation.conflictTasksEnabled && !conflictTaskFailed { visible.hasConflict = false }
            if handles(.pipelineFailure) && pipelineOwnedAutomatically && !needsPipelineHandoff { visible.failedPipeline = false }
            let feedbackRule = automation.authorFeedback
            let canPrepareFeedback = feedbackRule.runner == .assistant && feedbackRule.isConfigured
                && feedbackRule.includes(project: request.webURL.gitLabProjectPath)
            let handlesFeedback = !failedTriggers.contains(.newDiscussion) && (
                (canPrepareFeedback && (feedbackRule.isEnabled || handles(.newDiscussion)))
                    || (handles(.newDiscussion) && feedbackOwnedAutomatically))
            if handlesFeedback && !feedback.isEmpty {
                visible.needsDiscussion = hasOtherUnresolvedDiscussions
                visible.feedback = []
            }
            if handles(.newDiscussion) && feedbackOwnedAutomatically { visible.needsChanges = false }
            // Draft publication, ownership handoffs, requested changes and uncertain re-review
            // receipts remain visible until their own eligibility/confirmation checks succeed.
            return visible
        }

        private var hasOpenAction: Bool {
            needsDiscussion || hasConflict || needsChanges || needsMerge || failedPipeline || needsPipelineHandoff
                || requiresDiscussionRecheck || reReviewUnconfirmed || !feedback.isEmpty || (reReviewReadiness != nil && reReviewReadiness != .checking)
                || authorFeedbackStatus?.needsAttention == true
        }

        var needsAttention: Bool { (requiresCommentReview && draftCount == 0) || (humanActionRequired ?? (needsConfirmation || hasOpenAction)) }

        /// Something the user must confirm before it reaches other people.
        var needsConfirmation: Bool { requiresCommentReview || draftCount > 0 || (canApprove && !approvalWaitingForReadiness) || canConfirmReReview }

        var section: Section {
            if mergeRequest?.detailedMergeStatus == "draft_status" || (mergeRequest?.draft ?? draftFromTodo) {
                return .draftMergeRequests
            }
            return needsConfirmation && !hasOpenAction ? .unpublishedComments : .open
        }

        static func ordered(_ items: [Self], draftsLast: Bool = true) -> [Self] {
            items.map { item in
                var order = item.mergeOrder
                if !draftsLast, item.section == .draftMergeRequests {
                    order.0 = (item.needsConfirmation && !item.hasOpenAction ? Section.unpublishedComments : .open).rawValue
                }
                return (item: item, order: order)
            }
                .sorted { $0.order < $1.order }
                .map(\.item)
        }

        private var mergeOrder: (Int, Int, Int, String, Int, Int) {
            let order = mergeReadiness
            return (section.rawValue, order.priority, order.blockers, title, id.projectID, id.iid)
        }

        private var mergeReadiness: (priority: Int, blockers: Int) {
            guard let mergeRequest, let mergeStatus = mergeRequest.detailedMergeStatus else { return (2, 0) }
            let status = AuthoredMergeRequestStatus(
                request: mergeRequest, approvals: nil, discussionsResolved: mergeRequest.blockingDiscussionsResolved,
                projectRequiresResolvedDiscussions: nil, autoMergeEnabled: false
            )
            // The list endpoint supplies merge status but does not verify approval rules.
            var blockers = Set(status.blockers).subtracting([.unknown, .draft])
            if needsDiscussion { blockers.insert(.discussions) }
            if hasConflict { blockers.insert(.conflicts) }
            if needsChanges { blockers.insert(.changesRequested) }
            if failedPipeline || needsPipelineHandoff { blockers.insert(.pipeline) }
            if mergeStatus == "mergeable" && blockers.isEmpty { return (0, 0) }
            return (blockers.contains(.checking) ? 2 : 1, blockers.count)
        }
    }

    enum ConfirmationState: Equatable, Sendable {
        case publishing, approving, deleting, finishingCommentReview, failed, changed

        var isBusy: Bool {
            switch self {
            case .publishing, .approving, .deleting, .finishingCommentReview: true
            case .failed, .changed: false
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
    private let reportDirectory: URL?
    private let verdictDirectory: URL
    private let aiAssessmentDirectory: URL
    private let followUpDirectory: URL
    private let provenanceDirectory: URL
    private var verifiedRemoteFiles: [String: [FollowUpVerification.FileEvidence]] = [:]
    private var isRefreshingDrafts = false
    @ObservationIgnored private let pendingDraftPolling = PendingDraftPolling()
    private let reReviewCoordinator: ReReviewCoordinator?
    private let canAutomate: @MainActor (AutomationAssistant) async -> Bool
    private let approvalReadClock: ReadOnlyAssessmentRetry.Clock
    private let approvalReadWait: ReadOnlyAssessmentRetry.Wait
    /// Called after MergeTether approved a merge request on its own.
    var onRefreshed: (() -> Void)?
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
    let aiOriginCoordinator: AICommentOriginCoordinator
    let draftProofRecoveryCoordinator: DraftProofRecoveryCoordinator?
    private var feedbackNeedsRefresh = false
    var onAuthorFeedbackNeedsWork: ((GitLabMergeRequest, Set<Int>, String, AuthorFeedbackResidual?) async -> Void)?
    var onAuthorFeedbackChecked: (() -> Void)?

    private struct Account: Equatable {
        let host: String
        let username: String
    }

    init(
        glab: GlabService, settings: SettingsManager? = nil, reportDirectory: URL? = nil,
        verdictDirectory: URL = ReviewVerdictStore.directory,
        aiAssessmentDirectory: URL = AICommentAssessmentStore.directory,
        followUpDirectory: URL = FollowUpVerificationStore.directory,
        provenanceDirectory: URL = AICommentProvenanceStore.directory,
        canAutomate: @escaping @MainActor (AutomationAssistant) async -> Bool = {
            await AssistantCLI.detect($0, requireCLI: true).isReady
        },
        approvalReadClock: @escaping ReadOnlyAssessmentRetry.Clock = { Date() },
        approvalReadWait: @escaping ReadOnlyAssessmentRetry.Wait = ReadOnlyAssessmentRetry.wait,
        verifyReReview: @escaping @MainActor (ReReviewVerifier.Input, AutomationAssistant, String) async throws -> ReReviewAssessment = {
            try await ReReviewVerifier.verify($0, assistant: $1, model: $2)
        },
        verifyDraftProofRecovery: @escaping DraftProofRecoveryCoordinator.Verify = {
            try await DraftProofRecoveryVerifier.verify($0, assistant: $1, model: $2)
        },
        assessAIOrigin: @escaping AICommentOriginCoordinator.Assess = {
            try await AICommentOriginAssessor.verify(target: $0, notes: $1, assistant: $2, model: $3, thinking: $4)
        }
    ) {
        self.glab = glab
        self.settings = settings
        self.reportDirectory = reportDirectory
        self.verdictDirectory = verdictDirectory
        self.aiAssessmentDirectory = aiAssessmentDirectory
        self.followUpDirectory = followUpDirectory
        self.provenanceDirectory = provenanceDirectory
        self.canAutomate = canAutomate
        self.approvalReadClock = approvalReadClock
        self.approvalReadWait = approvalReadWait
        self.aiOriginCoordinator = AICommentOriginCoordinator(directory: aiAssessmentDirectory, assess: assessAIOrigin,
            fetchCurrent: { target in
                guard let iid = target.iid, glab.resolvedHost == target.host,
                      glab.currentUsername == target.username else { throw CancellationError() }
                _ = try await glab.fetchAuthenticatedUser(host: target.host, expectedUsername: target.username)
                let request = try await glab.fetchMergeRequest(projectID: target.projectID, iid: iid, host: target.host)
                guard request.state == "opened", request.webURL.isGitLabMergeRequest(host: target.host, iid: iid),
                      settings?.automation.scope.permits(request, host: target.host, username: target.username) == true
                else { throw CancellationError() }
                return try await glab.fetchMergeRequestDiscussions(projectID: target.projectID, iid: iid, host: target.host).flatMap(\.notes)
            }, isCurrent: { target, assistant, model, thinking in
                guard let settings, glab.resolvedHost == target.host, glab.currentUsername == target.username,
                      settings.automation.hasAutomaticActionConsent,
                      settings.automation.assistant == assistant, settings.automation.publicationMode != .manual,
                      settings.automation.automaticPublicationPolicy.requiresAI,
                      settings.automation.scope.resolve(target).active else { return false }
                let configured = assistant == .codex ? settings.automation.codexVerificationModel.rawValue
                    : settings.automation.claudeVerificationModel.rawValue
                return model == configured && settings.automation.verificationThinking == thinking
            })
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
        self.authorFeedbackCoordinator = settings.map { AuthorFeedbackCoordinator(settings: $0, glab: glab,
            canAutomate: canAutomate, verify: verifyReReview) }
        let feedbackCoordinator = self.authorFeedbackCoordinator
        self.reReviewCoordinator = settings.map { ReReviewCoordinator(settings: $0, glab: glab,
            canAutomate: canAutomate, verify: verifyReReview,
            authorFeedbackStatus: { request in
                feedbackCoordinator?.status(projectID: request.projectID, iid: request.iid)
            }, authorFeedbackAssessment: { request, fingerprint in
                feedbackCoordinator?.assessment(for: request, fingerprint: fingerprint)
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
        authorFeedbackCoordinator?.onRemoteChange = { [weak self] in
            guard let self, let account, isCurrent(account) else { return }
            onAuthorFeedbackChecked?()
            if isLoading { feedbackNeedsRefresh = true }
            else { refresh(host: account.host, username: account.username, todos: []) }
        }
        draftProofRecoveryCoordinator?.onChange = { [weak self] in
            guard let self, let account, isCurrent(account) else { return }
            if isLoading { feedbackNeedsRefresh = true }
            else { refresh(host: account.host, username: account.username, todos: []) }
        }
        aiOriginCoordinator.onChange = { [weak self] in
            guard let self, let account, isCurrent(account) else { return }
            if isLoading { feedbackNeedsRefresh = true }
            else { refresh(host: account.host, username: account.username, todos: []) }
        }
    }

    private func permitsAssistantAutomation(for account: Account) async -> Bool {
        guard let settings, isCurrent(account), !Task.isCancelled else { return false }
        let configuration = settings.automation
        let generation = accountGeneration
        return await canAutomate(configuration.assistant) && !Task.isCancelled
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
        return items.map(presentAuthorFeedback)
    }

    var currentOpenItems: [Item] {
        guard let account, isCurrent(account) else { return [] }
        return openItems.map(presentAuthorFeedback)
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
        let evidence = attentionRecords.mapValues { presentAuthorFeedback($0.evidence) }
        let candidates = attentionCandidateIDs.compactMap { evidence[$0] }
        return .init(host: account.host, username: account.username, revision: glab.accountRevision,
            evidence: Array(evidence.values),
            attention: Item.ordered(candidates.filter(\.needsAttention)), catalog: openItems.map(presentAuthorFeedback))
    }

    private func presentAuthorFeedback(_ original: Item) -> Item {
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
        return item.presentingVerifiedAuthorFeedback()
    }

    func retryDraftProofRecovery(_ id: Item.ID) {
        guard let account, isCurrent(account) else { return }
        draftProofRecoveryCoordinator?.retry(work: .init(host: account.host, projectID: id.projectID, iid: id.iid), username: account.username)
        refresh(host: account.host, username: account.username, todos: [])
    }

    func retryAuthorFeedback(_ id: Item.ID) {
        authorFeedbackCoordinator?.invalidate(projectID: id.projectID, iid: id.iid)
        guard let account, isCurrent(account) else { return }
        refresh(host: account.host, username: account.username, todos: [])
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
        if self.account != account {
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
            reReviewCoordinator?.reset()
            if let reportDirectory { CodexDesktopRelay.clearMergeRequestStatus(in: reportDirectory) }
        }
        refreshGeneration += 1
        isLoading = true
        Task {
            defer {
                isLoading = false; onRefreshed?()
                let pending = pendingRefresh
                pendingRefresh = nil
                if let pending, pending.revision == glab.accountRevision, isCurrent(pending.account) {
                    feedbackNeedsRefresh = false
                    refresh(host: pending.account.host, username: pending.account.username, todos: pending.todos)
                } else if feedbackNeedsRefresh, isCurrent(account) {
                    feedbackNeedsRefresh = false
                    refresh(host: account.host, username: account.username, todos: [])
                }
                signalAutomaticActionIdle()
            }
            do {
                try await poll(account, todos: todos, revision: revision)
            } catch {
                if isCurrent(account), revision == glab.accountRevision {
                    hasError = true
                    for id in attentionRecords.keys { attentionRecords[id]?.evidence.reviewingProgress = nil }
                    clearApprovalProgress()
                }
            }
        }
    }

    private func isCurrent(_ account: Account) -> Bool {
        glab.resolvedHost == account.host && glab.currentUsername == account.username
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
        defer {
            isLoading = false
            onRefreshed?()
            let pending = pendingRefresh
            pendingRefresh = nil
            if let pending, pending.revision == glab.accountRevision, isCurrent(pending.account) {
                feedbackNeedsRefresh = false
                refresh(host: pending.account.host, username: pending.account.username, todos: pending.todos)
            } else if feedbackNeedsRefresh, isCurrent(account) {
                feedbackNeedsRefresh = false
                refresh(host: account.host, username: account.username, todos: [])
            }
            signalAutomaticActionIdle()
        }
        do {
            let todos = latestTodoSnapshot.flatMap {
                $0.account == account && $0.revision == key.revision ? $0.todos : nil
            } ?? []
            try await poll(account, todos: todos, revision: key.revision, automaticResume: (id, key.action))
        } catch {
            if isCurrent(account), glab.accountRevision == key.revision {
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

    private func poll(_ account: Account, todos: [Todo], revision: UInt64,
                      automaticResume: (id: Item.ID, action: MRAutomaticAction)? = nil) async throws {
        let host = account.host
        let user = try await glab.fetchAuthenticatedUser(host: host, expectedUsername: account.username)
        self.user = user
        let agentWorks = assistantWorks(username: user.username)
        let verdictDirectory = verdictDirectory
        let observedAt = Date()
        async let authored = try? glab.fetchAuthoredMergeRequests(host: host)
        async let reviewing = try? glab.fetchReviewAssignedMergeRequests(userID: user.id, host: host)
        let (owned, assigned) = await (authored, reviewing)
        guard isCurrent(account) else { return }
        let listed = (owned ?? []) + (assigned ?? [])
        func target(for request: GitLabMergeRequest) -> MRAutomationScope.Target {
            .init(host: host, username: user.username, projectID: request.projectID, iid: request.iid)
        }
        func isIgnored(_ target: MRAutomationScope.Target) -> Bool {
            settings?.ignoredMergeRequests.contains(target) == true
        }
        func hasManagedIntent(_ target: MRAutomationScope.Target) -> Bool {
            settings?.mrActionIntents.contains { $0.target == target && $0.grantsManagement } == true
        }
        func isTracked(_ request: GitLabMergeRequest) -> Bool {
            let target = target(for: request)
            return request.author.id == user.id || settings?.automation.scope.isManaged(target) == true
                || hasManagedIntent(target) || settings?.mrLifecycleLedger.request(for: target) != nil
                || agentWorks.contains(.init(host: host, projectID: request.projectID, iid: request.iid))
        }
        func remember(_ request: GitLabMergeRequest, readStartedAt: Date) {
            let target = target(for: request)
            guard !isIgnored(target) else { return }
            onDisplayMetadataObserved?(request, target, revision, readStartedAt)
            guard isTracked(request) else { return }
            settings?.mrLifecycleLedger.record(request, for: target, now: readStartedAt,
                autoRemoveFinished: true)
            onAutomationEligibilityObserved?()
        }
        func retireCommentReview(_ request: GitLabMergeRequest) {
            guard request.state == "merged" || request.state == "closed" else { return }
            let reviewTarget = target(for: request)
            // A newer reopening must win over an older in-flight terminal read.
            guard settings?.mrLifecycleLedger.request(for: reviewTarget)?.state != "opened" else { return }
            settings?.completeCommentReview(for: reviewTarget)
        }
        guard revision == glab.accountRevision else { return }
        for pending in settings?.pendingCommentReviews ?? [] where pending.host == host && pending.username == user.username {
            if isIgnored(pending) || settings?.mrLifecycleLedger.request(for: pending)?.state == "merged" {
                settings?.completeCommentReview(for: pending)
            }
        }
        for request in listed where request.webURL.isGitLabMergeRequest(host: host, iid: request.iid) {
            remember(request, readStartedAt: observedAt)
            if request.state == "opened" {
                terminalCatalogRequests.remove(.init(projectID: request.projectID, iid: request.iid))
            }
        }
        let listedIDs = Set(listed.filter {
            $0.webURL.isGitLabMergeRequest(host: host, iid: $0.iid)
                && ["opened", "closed", "merged"].contains($0.state)
        }.map { Item.ID(projectID: $0.projectID, iid: $0.iid) })
        var previousCatalog = Dictionary(uniqueKeysWithValues: openItems.map { ($0.id, $0) })
        for request in settings?.mrLifecycleLedger.retainedRequests(host: host, username: user.username) ?? [] {
            let id = Item.ID(projectID: request.projectID, iid: request.iid)
            if previousCatalog[id] == nil {
                previousCatalog[id] = Item(id: id, title: request.title, url: request.webURL,
                    mergeRequest: request, isAuthored: request.author.id == user.id)
            }
        }
        // Known tracked rows survive a successful open list until an exact read
        // confirms their state. Absence, pagination and failures are not closure.
        var retainedCatalog = previousCatalog.filter { _, item in
            let tracked = item.mergeRequest.map { settings?.mrLifecycleLedger.request(for: target(for: $0)) != nil } == true
            return tracked || (item.mergeRequest?.author.id == user.id ? owned == nil : assigned == nil)
        }.mapValues { item in
            var item = item
            item.approvalProgress = nil
            return item
        }
        for request in listed where request.state == "closed" || request.state == "merged" {
            retireCommentReview(request)
            retainedCatalog.removeValue(forKey: .init(projectID: request.projectID, iid: request.iid))
        }
        let pendingReviewTargets = (settings?.pendingCommentReviews ?? []).filter { $0.host == host && $0.username == user.username }
        let scopeTargets = Set(settings?.automation.scope.individualTargets(host: host, username: user.username) ?? []).union(pendingReviewTargets)
        let recordedTargets = Set(agentWorks.filter { $0.host == host }.map {
            MRAutomationScope.Target(host: host, username: user.username, projectID: $0.projectID, iid: $0.iid)
        })
        let intentTargets = Set((settings?.mrActionIntents ?? []).filter {
            $0.target.host == host && $0.target.username == user.username && $0.grantsManagement
        }.map(\.target))
        let trackedTargets = settings?.mrLifecycleLedger.targets(host: host, username: user.username) ?? []
        let lookupTargets = scopeTargets.union(recordedTargets).union(intentTargets).union(trackedTargets)
        var explicit: [GitLabMergeRequest] = []
        var recordedReviews: [GitLabMergeRequest] = []
        var explicitFetchFailed = false
        for target in lookupTargets.sorted(by: { ($0.projectID, $0.iid ?? 0) < ($1.projectID, $1.iid ?? 0) }) {
            guard let iid = target.iid, !isIgnored(target) else { continue }
            let id = Item.ID(projectID: target.projectID, iid: iid)
            guard !listedIDs.contains(id) else { continue }
            // Merged MRs cannot reopen. Closed rows, including Seen tombstones,
            // continue exact checks because they may reopen without assignment.
            if settings?.mrLifecycleLedger.request(for: target)?.state == "merged"
                || terminalCatalogRequests.contains(id) { continue }
            let requestReadStartedAt = Date()
            guard let request = try? await glab.fetchMergeRequest(projectID: target.projectID, iid: iid, host: host) else {
                explicitFetchFailed = true
                if var previous = previousCatalog[id] {
                    previous.approvalProgress = nil
                    retainedCatalog[id] = previous
                }
                continue
            }
            guard isCurrent(account), revision == glab.accountRevision else { return }
            guard request.projectID == target.projectID, request.iid == iid,
                  request.webURL.isGitLabMergeRequest(host: host, iid: iid),
                  ["opened", "closed", "merged"].contains(request.state) else {
                explicitFetchFailed = true
                continue
            }
            if request.state == "merged" || request.state == "closed" {
                let alreadyTracked = settings?.mrLifecycleLedger.request(for: target) != nil
                    || settings?.automation.scope.isManaged(target) == true || hasManagedIntent(target)
                if alreadyTracked { remember(request, readStartedAt: requestReadStartedAt) }
                else { onDisplayMetadataObserved?(request, target, revision, requestReadStartedAt) }
                retireCommentReview(request)
                if request.state == "merged" { terminalCatalogRequests.insert(id) }
                retainedCatalog.removeValue(forKey: id)
            } else {
                terminalCatalogRequests.remove(id)
                remember(request, readStartedAt: requestReadStartedAt)
                if scopeTargets.contains(target) || request.author.id == user.id { explicit.append(request) }
                else { recordedReviews.append(request) }
            }
        }
        guard isCurrent(account), revision == glab.accountRevision else { return }
        // A newer Authored read may have completed while this poll was awaiting
        // GitLab. Its observed state must win over the older list snapshot.
        let currentListed = (listed + explicit).map { request in
            settings?.mrLifecycleLedger.request(for: target(for: request)) ?? request
        }

        let todoItems: [Item] = todos.compactMap { todo in
            guard todo.targetType == .mergeRequest, let iid = todo.target.iid,
                  todo.targetURL.isGitLabMergeRequest(host: host, iid: iid) else { return nil }
            var url = URLComponents(url: todo.targetURL, resolvingAgainstBaseURL: false)
            url?.fragment = nil
            return Item(id: .init(projectID: todo.project.id, iid: iid),
                        title: todo.displayTitle, url: url?.url ?? todo.targetURL, draftFromTodo: todo.isDraft)
        }
        var candidates: [Item.ID: Item] = [:]
        for item in items where item.draftCount > 0 || item.requiresCommentReview || owned == nil {
            candidates[item.id] = item
        }
        for item in recentTodos where candidates[item.id] == nil {
            candidates[item.id] = item
        }
        for item in todoItems {
            if candidates[item.id] == nil { candidates[item.id] = item }
            candidates[item.id]?.draftFromTodo = item.draftFromTodo
        }
        recentTodos = todoItems

        for mr in currentListed {
            guard mr.state == "opened", mr.webURL.isGitLabMergeRequest(host: host, iid: mr.iid) else { continue }
            let id = Item.ID(projectID: mr.projectID, iid: mr.iid)
            var item = Item(
                id: id, title: mr.title, url: mr.webURL, draftCount: candidates[id]?.draftCount ?? 0,
                draftFromTodo: candidates[id]?.draftFromTodo ?? false, mergeRequest: mr, isAuthored: mr.author.id == user.id
            )
            item.drafts = candidates[id]?.drafts ?? []
            item.requiresCommentReview = commentReviewPending(id, account: account)
            if item.isAuthored {
                item.needsDiscussion = mr.blockingDiscussionsResolved == false
                    || mr.detailedMergeStatus == "discussions_not_resolved"
                item.hasConflict = mr.hasMergeConflict
                item.needsChanges = mr.detailedMergeStatus == "requested_changes"
                item.failedPipeline = mr.headPipeline?.status == "failed"
                    || mr.detailedMergeStatus == "ci_must_pass"
            }
            candidates[id] = item
        }
        if owned != nil {
            let ownedIDs = Set((owned ?? []).map { Item.ID(projectID: $0.projectID, iid: $0.iid) })
            for id in Array(candidates.keys) where !ownedIDs.contains(id) {
                candidates[id]?.needsDiscussion = false
                candidates[id]?.hasConflict = false
                candidates[id]?.needsChanges = false
                candidates[id]?.failedPipeline = false
                candidates[id]?.isAuthored = false
                candidates[id]?.feedback = []
            }
        }

        for id in Array(candidates.keys) {
            let target = MRAutomationScope.Target(host: host, username: user.username, projectID: id.projectID, iid: id.iid)
            if let current = settings?.mrLifecycleLedger.request(for: target) {
                if current.state != "opened" { candidates.removeValue(forKey: id) }
                else { candidates[id]?.mergeRequest = current }
            }
        }
        var results: [Item] = []
        var authoredUnansweredFeedback: [Item.ID: Bool] = [:]
        var reReviewCandidates: [(GitLabMergeRequest, ReReviewFeedback, Int)] = []
        var failed = owned == nil || assigned == nil
        let ordered = candidates.values.sorted { ($0.id.projectID, $0.id.iid) < ($1.id.projectID, $1.id.iid) }
        // Limit simultaneous glab processes while still checking the entire list.
        for start in stride(from: 0, to: ordered.count, by: 4) {
            guard isCurrent(account) else { return }
            let batch = ordered[start..<min(start + 4, ordered.count)]
            let reviewRevisions = Dictionary(uniqueKeysWithValues: batch.map {
                ($0.id, settings?.commentReviewRevision(for: commentReviewTarget($0.id, account: account)) ?? 0)
            })
            await withTaskGroup(of: (Item, Bool, ReReviewFeedback?, [GitLabMergeRequestDiscussion]?, Set<Int>, GitLabMergeRequest?, Date?).self) { group in
                for item in batch {
                    let approvedHead = approvedHeads[item.id]
                    let failedHead = failedApprovalHeads[item.id]
                    let autoApproves = item.mergeRequest.map {
                        autoApproveApplies(to: $0, host: host, username: account.username)
                    } ?? false
                    let approvalOptedOut = settings?.actionIsAutomatic(.approval,
                        for: .init(host: host, username: account.username, projectID: item.id.projectID, iid: item.id.iid)) == false
                    let followUpReceipts = contextReceipts(projectID: item.id.projectID, iid: item.id.iid,
                        host: host, username: user.username)
                    let authenticatedVerdict = ReviewVerdictStore.authenticatedVerdict(host: host,
                        projectID: item.id.projectID, iid: item.id.iid, user: user, settings: settings, in: verdictDirectory)
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
                        let draftCount = drafts?.count
                        if let drafts { updated.drafts = drafts }
                        if let drafts, !drafts.isEmpty {
                            ReviewVerdictStore.rememberDrafts(drafts, host: host, projectID: item.id.projectID,
                                                              iid: item.id.iid, in: verdictDirectory)
                        }
                        updated.canApprove = false
                        updated.approvalWaitingForReadiness = false
                        updated.autoApproveReady = false
                        if drafts?.isEmpty == true, !item.isAuthored,
                           let request = item.mergeRequest, request.author.id != user.id, request.draft != nil,
                           let head = request.sha, head != approvedHead,
                           ReviewVerdictStore.verdict(
                               host: host, projectID: request.projectID, iid: request.iid, user: user, in: verdictDirectory
                           )?.headSHA == head {
                            let check = await Self.approvalCheck(request, user: user, host: host, glab: glab)
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
                                    head: head, discussions: discussions, user: user, in: verdictDirectory)
                            } else { automaticContext = false }
                            // After GitLab refused an automatic approval, offer the button instead of retrying.
                            let automatic = autoApproves && head != failedHead && automaticContext
                                && authenticatedVerdict == ReviewVerdictStore.verdict(host: host, projectID: request.projectID,
                                    iid: request.iid, user: user, in: verdictDirectory)
                            updated.canApprove = currentVerdict && check.ownReady && !automatic
                            updated.approvalWaitingForReadiness = updated.canApprove && approvalOptedOut && !check.allResolved
                            updated.autoApproveReady = automaticContext && check.ownReady && check.allResolved && automatic
                        }
                        let hasDrafts = !(drafts ?? item.drafts).isEmpty
                        let discussions = if item.mergeRequest != nil || item.authoredRequest != nil || hasDrafts {
                            try? await glab.fetchMergeRequestDiscussions(
                                projectID: item.id.projectID, iid: item.id.iid, host: host
                            )
                        } else { nil as [GitLabMergeRequestDiscussion]? }
                        updated.observedDiscussionFingerprint = discussions.flatMap { ReviewVerdict.fingerprint($0) }
                        let reviewers = try? await glab.fetchMergeRequestReviewers(projectID: item.id.projectID, iid: item.id.iid, host: host)
                        if let discussions, let request = item.mergeRequest {
                            updated.approvalProgress?.reviewHistory = MergeRequestReviewHistory(
                                reviewers: reviewers ?? [], discussions: discussions, authorID: request.author.id)
                        }
                        updated.commentReviewSnapshot = CommentReviewSnapshot(request: item.mergeRequest, discussions: discussions)
                        updated.changeRequestReviewers = nil
                        if item.isAuthored, item.needsChanges, let reviewers {
                            let requests = reviewers.filter { $0.state == "requested_changes" }
                            if !requests.isEmpty, requests.allSatisfy({ $0.user.id > 0 && $0.user.username?.isEmpty == false }) {
                                updated.changeRequestReviewers = Set(requests.compactMap(\.user.username))
                            }
                        }
                        if !item.isAuthored, let request = item.mergeRequest {
                            updated.reviewingActivity = discussions.map {
                                ReviewingActivity(discussions: $0, reviewerID: user.id, authorID: request.author.id)
                            }
                            updated.reviewingProgress = Self.reviewingProgress(for: item, request: request,
                                discussions: discussions, host: host, user: user, verdictDirectory: verdictDirectory)
                        }
                        if hasDrafts {
                            let requestReadStartedAt = Date()
                            let live = try? await glab.fetchMergeRequest(projectID: item.id.projectID, iid: item.id.iid, host: host)
                            recoveryRequest = live
                            if live != nil { recoveryReadStartedAt = requestReadStartedAt }
                            updated.reviewingProgress = Self.reviewingProgress(for: item, request: live,
                                discussions: discussions, host: host, user: user, verdictDirectory: verdictDirectory)
                            updated.requiresDiscussionRecheck = !Self.draftContextIsCurrent(
                                request: live, drafts: drafts, discussions: discussions, host: host, user: user,
                                verdictDirectory: verdictDirectory, followUpReceipts: followUpReceipts
                            )
                            contextDraftIDs = Set((drafts ?? []).filter { draft in
                                Self.draftContextIsCurrent(request: live, drafts: [draft], discussions: discussions,
                                    host: host, user: user, verdictDirectory: verdictDirectory, followUpReceipts: followUpReceipts)
                            }.compactMap(\.id))
                        } else {
                            updated.requiresDiscussionRecheck = false
                        }
                        if item.isAuthored {
                            // Without discussion evidence, the list endpoint's aggregate
                            // blocker cannot safely be attributed to automated feedback.
                            updated.hasOtherUnresolvedDiscussions = item.needsDiscussion
                        }
                        if let draftCount { updated.draftCount = draftCount }
                        updated.replyRecipients = [:]
                        if let discussions {
                            for discussion in discussions {
                                if let id = discussion.id, let recipients = discussion.replyRecipients(excluding: user.id) {
                                    updated.replyRecipients[id] = recipients
                                }
                            }
                            if item.isAuthored {
                                updated.feedback = GitLabMergeRequestDiscussion.unresolvedFeedback(in: discussions, excluding: user.id)
                                let feedbackIDs = Set(updated.feedback.compactMap(\.id))
                                let unresolved = discussions.filter { discussion in
                                    discussion.notes.contains { $0.system != true && $0.resolvable == true && $0.resolved == false }
                                }
                                let uncertain = discussions.contains { discussion in
                                    discussion.notes.contains { $0.system != true && $0.resolvable == true && $0.resolved == nil }
                                }
                                updated.hasOtherUnresolvedDiscussions = unresolved.contains { discussion in
                                    !discussion.notes.contains { $0.id.map(feedbackIDs.contains) == true }
                                } || ((uncertain || unresolved.isEmpty) && item.needsDiscussion)
                                updated.needsDiscussion = !unresolved.isEmpty || item.needsDiscussion
                            }
                        }
                        let feedback = discussions.map { ReReviewFeedback(discussions: $0, authorID: user.id) }
                        return (updated, draftCount != nil && (!(item.isAuthored || hasDrafts) || discussions != nil), feedback, discussions, contextDraftIDs, recoveryRequest, recoveryReadStartedAt)
                    }
                }
                for await (var item, success, feedback, discussions, contextDraftIDs, recoveryRequest, recoveryReadStartedAt) in group {
                    guard isCurrent(account), revision == glab.accountRevision else { return }
                    settings?.observeCommentReview(item.drafts.filter { publishedDrafts[item.id]?.contains($0) != true },
                        for: commentReviewTarget(item.id, account: account), revision: reviewRevisions[item.id] ?? 0)
                    item.requiresCommentReview = commentReviewPending(item.id, account: account)
                    if item.requiresCommentReview {
                        item.canApprove = false; item.autoApproveReady = false; item.canConfirmReReview = false
                    }
                    if let recoveryRequest, let recoveryReadStartedAt {
                        remember(recoveryRequest, readStartedAt: recoveryReadStartedAt)
                    }
                    let lifecycleTarget = MRAutomationScope.Target(host: host, username: user.username,
                        projectID: item.id.projectID, iid: item.id.iid)
                    if let latest = settings?.mrLifecycleLedger.request(for: lifecycleTarget) {
                        guard latest.state == "opened", latest.sha == item.mergeRequest?.sha,
                              latest.semanticContextFingerprint == item.mergeRequest?.semanticContextFingerprint else { continue }
                        item.mergeRequest = latest
                    }
                    let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: item.id.projectID, iid: item.id.iid)
                    if success, let request = item.mergeRequest, let discussions {
                        await scheduleAIOriginChecks(request: request, drafts: item.drafts, discussions: discussions,
                            account: account, user: user)
                    }
                    if item.isAuthored, agentWorks.contains(work), let settings {
                        let run = FollowUpVerificationStore.latestRun(for: work, username: user.username, settings: settings)
                        if let run { FollowUpVerificationStore.register(run, settings: settings, in: followUpDirectory) }
                        let receipts = publicationReceipts(projectID: item.id.projectID, iid: item.id.iid,
                            host: host, username: user.username)
                        let candidates = item.drafts.filter { draft in
                            guard let request = item.mergeRequest,
                                  settings.automation.scope.permits(request, host: host, username: user.username) else { return false }
                            return settings.automation.automaticPublicationPolicy.couldAllow(
                                draft, request: request, userID: user.id, host: host)
                        }
                        let verificationCandidates = item.mergeRequest.map { request in
                            DraftReplyRepair.preparationAllowed(request, configuration: settings.automation) ? item.drafts : candidates
                        } ?? candidates
                        if automaticResume == nil || (automaticResume?.action == .commentPublication && automaticResume?.id == item.id),
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
                    item.automaticPublicationPolicy = nil
                    if success, let settings, let request = item.mergeRequest,
                       agentWorks.contains(work), settings.automation.scope.permits(request, host: host, username: user.username),
                       item.isAuthored || (!item.awaitingRemoteVerification && !item.requiresDiscussionRecheck) {
                        let policy = settings.automation.automaticPublicationPolicy
                        if policy.mode != .manual {
                            let aiIDs = await aiNoteIDs(in: discussions ?? [], policy: policy, host: host,
                                                       projectID: item.id.projectID, iid: item.id.iid)
                            item.automaticPublicationPolicy = policy
                            item.automaticDraftIDs = Set(item.drafts.filter {
                                (!item.isAuthored || (settings.automation.allowFollowUpPush && $0.id.map(contextDraftIDs.contains) == true))
                                    && policy.allows($0, request: request, discussions: discussions, userID: user.id,
                                        host: host, aiNoteIDs: aiIDs)
                            }.compactMap(\.id))
                        }
                    }
                    if automaticResume == nil, success, let request = item.authoredRequest, let discussions {
                        authorFeedbackCoordinator?.refresh(request: request, discussions: discussions,
                            drafts: item.draftCount, host: host, user: user)
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
        guard isCurrent(account), revision == glab.accountRevision else { return }
        hasError = failed || explicitFetchFailed
        hasOwnListing = owned != nil
        let openIDs = Set(currentListed.filter { $0.state == "opened" }.map {
            Item.ID(projectID: $0.projectID, iid: $0.iid)
        })
        for item in results where openIDs.contains(item.id) && item.mergeRequest?.state == "opened" {
            retainedCatalog[item.id] = item
        }
        for request in recordedReviews {
            let id = Item.ID(projectID: request.projectID, iid: request.iid)
            var item = Item(id: id, title: request.title, url: request.webURL, mergeRequest: request)
            item.approvalProgress = try? await glab.fetchMergeRequestApprovalProgress(projectID: request.projectID, iid: request.iid, host: host)
            async let reviewStates = try? glab.fetchMergeRequestReviewers(projectID: request.projectID, iid: request.iid, host: host)
            async let reviewThreads = try? glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
            let (states, threads) = await (reviewStates, reviewThreads)
            if let threads {
                item.approvalProgress?.reviewHistory = MergeRequestReviewHistory(
                    reviewers: states ?? [], discussions: threads, authorID: request.author.id)
            }
            guard isCurrent(account), revision == glab.accountRevision else { return }
            retainedCatalog[id] = item
        }
        if let settings {
            settings.mrLifecycleLedger.prepareFinishedRemoval(host: host, username: user.username)
            for target in settings.mrLifecycleLedger.targets(host: host, username: user.username) {
                let id = Item.ID(projectID: target.projectID, iid: target.iid ?? 0)
                if settings.mrLifecycleLedger.isSuppressed(target) || settings.ignoredMergeRequests.contains(target) {
                    retainedCatalog.removeValue(forKey: id)
                }
            }
            for request in settings.mrLifecycleLedger.retainedRequests(host: host, username: user.username)
                where !settings.ignoredMergeRequests.contains(target(for: request)) {
                let id = Item.ID(projectID: request.projectID, iid: request.iid)
                if request.state == "opened", var item = retainedCatalog[id] {
                    if !MRAttentionRecord.sameContext(item.mergeRequest, request) {
                        item.approvalProgress = nil
                        item.reviewingActivity = nil
                    }
                    item.mergeRequest = request
                    retainedCatalog[id] = item
                } else {
                    retainedCatalog[id] = Item(id: id, title: request.title, url: request.webURL,
                        mergeRequest: request, isAuthored: request.author.id == user.id)
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
                results[index].draftCount = results[index].drafts.count
                if results[index].drafts.isEmpty { results[index].requiresDiscussionRecheck = false }
            }
            results[index].requiresCommentReview = commentReviewPending(id, account: account)
            if results[index].requiresCommentReview {
                results[index].canApprove = false
                results[index].autoApproveReady = false
                results[index].canConfirmReReview = false
            }
            if results[index].isAuthored {
                applyReReviewPresentation(&results[index], unanswered: authoredUnansweredFeedback[id] ?? true)
            }
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
            guard isCurrent(account), revision == glab.accountRevision else { return }
            await requestReReviewsIfReady(for: request, feedback: feedback, draftCount: draftCount,
                                          account: account, user: user)
        }
        if owned != nil, assigned != nil, !explicitFetchFailed { syncedCatalogRevision = revision }
        if automaticResume == nil || automaticResume?.action == .commentPublication {
            await publishSettledDrafts(agentWorks: agentWorks, account: account, only: automaticResume?.id)
        }
        for item in results where item.autoApproveReady
            && (automaticResume == nil || (automaticResume?.action == .approval && automaticResume?.id == item.id)) {
            guard let request = item.mergeRequest, let head = request.sha else { continue }
            if await performApproval(of: item.id, head: head, requireAllResolved: true) {
            }
        }
        scheduleDependencyRefresh(account: account, revision: revision)
    }

    /// The inbox is published before optional dependency reads. A cancelled predecessor
    /// drains before its replacement so slow subprocesses cannot multiply concurrency.
    private func scheduleDependencyRefresh(account: Account, revision: UInt64) {
        let previous = dependencyTask
        previous?.cancel()
        let requests = (openItems + items).compactMap(\.mergeRequest).filter { $0.state == "opened" }
        let contexts = Dictionary(requests.map { (Item.ID(projectID: $0.projectID, iid: $0.iid),
            MergeRequestDependencySummary.Context($0)) }, uniquingKeysWith: { first, _ in first })
        let projectCount = Set(requests.map(\.projectID)).count
        let waves = max(1, max((projectCount + 2) / 3, (contexts.count + 11) / 12))
        let generation = refreshGeneration
        dependencyTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, isCurrent(account), revision == glab.accountRevision,
                  generation == refreshGeneration else { return }
            // Drain this finite catalog in bounded waves instead of waiting for another timer poll.
            // Keep the base catalog visible and publish metadata once all initial sources were attempted.
            var summaries: [Item.ID: MergeRequestDependencySummary] = [:]
            for _ in 0..<waves {
                guard !Task.isCancelled, isCurrent(account), revision == glab.accountRevision,
                      generation == refreshGeneration else { return }
                summaries = await dependencyLoader.refresh(requests: requests, glab: glab, host: account.host)
                guard !Task.isCancelled, isCurrent(account), revision == glab.accountRevision,
                      generation == refreshGeneration else { return }
                await Task.yield()
            }
            guard !Task.isCancelled, isCurrent(account), revision == glab.accountRevision,
                  generation == refreshGeneration else { return }
            dependencyPresentation.acceptDependencies(summaries, requestedContexts: contexts,
                currentRequests: (openItems + items).compactMap(\.mergeRequest),
                account: .init(host: account.host, username: account.username, revision: revision))
            onRefreshed?()
        }
    }

    // MARK: - Ready for your OK

    private nonisolated static func reviewingProgress(
        for item: Item, request: GitLabMergeRequest?, discussions: [GitLabMergeRequestDiscussion]?,
        host: String, user: GitLabAuthenticatedUser, verdictDirectory: URL
    ) -> ReviewingProgress? {
        guard !item.isAuthored, let request, let displayed = item.mergeRequest,
              request.projectID == item.id.projectID, request.iid == item.id.iid,
              request.webURL == item.url, request.webURL == displayed.webURL,
              request.webURL.isGitLabMergeRequest(host: host, iid: request.iid),
              request.state == "opened", request.author.id != user.id,
              let head = request.sha, !head.isEmpty, head == displayed.sha,
              request.semanticContextFingerprint == displayed.semanticContextFingerprint,
              let discussions, ReviewVerdict.fingerprint(discussions) != nil else { return nil }
        let verdict = ReviewVerdictStore.verdict(host: host, projectID: request.projectID,
            iid: request.iid, user: user, in: verdictDirectory)
        guard verdict?.covers(head: head, discussions: discussions, reviewerID: user.id,
            publishedDrafts: ReviewVerdictStore.seenDrafts(host: host, projectID: request.projectID,
                iid: request.iid, in: verdictDirectory)) == true else { return .needsReview }
        let ownOpen = discussions.flatMap(\.notes).contains {
            $0.system != true && $0.author?.id == user.id && $0.resolvable == true && $0.resolved != true
        }
        return verdict?.verdict == .noObjections && !ownOpen && !allResolved(discussions)
            ? .waitingForOtherDiscussions : .current
    }

    private nonisolated static func draftContextIsCurrent(
        request: GitLabMergeRequest?, drafts: [GitLabDraftNote]?, discussions: [GitLabMergeRequestDiscussion]?,
        host: String, user: GitLabAuthenticatedUser, verdictDirectory: URL, followUpReceipts: [FollowUpVerification]
    ) -> Bool {
        guard let request, request.state == "opened", let head = request.sha,
              let drafts, !drafts.isEmpty, let discussions else { return false }
        if request.author.id == user.id {
            return drafts.allSatisfy { draft in
                followUpReceipt(for: draft, request: request, discussions: discussions, host: host, user: user,
                    verdictDirectory: verdictDirectory, receipts: followUpReceipts) != nil
            }
        }
        guard let verdict = ReviewVerdictStore.verdict(host: host, projectID: request.projectID, iid: request.iid, user: user, in: verdictDirectory),
              verdict.version == 1, verdict.headSHA == head, let fingerprint = verdict.discussionFingerprint else { return false }
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
    }

    private func captureGeneratedPublication(_ drafts: [GitLabDraftNote], id: Item.ID, account: Account,
        user: GitLabAuthenticatedUser, before: [GitLabMergeRequestDiscussion]? = nil) async -> PublicationEvidence? {
        let context = AICommentProvenanceStore.Context(host: account.host, username: account.username, userID: user.id,
            projectID: id.projectID, iid: id.iid)
        let generation = accountGeneration, revision = glab.accountRevision
        func current() -> Bool {
            !Task.isCancelled && generation == accountGeneration && revision == glab.accountRevision && isCurrent(account)
        }
        guard current() else { return nil }
        let work = AssistantAutomationRunner.MergeRequestWork(host: account.host, projectID: id.projectID, iid: id.iid)
        let request = openItems.first(where: { $0.id == id })?.mergeRequest
        let proofInput = request?.author.id == user.id ? settings.map {
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
                guard request?.sha == verdict.headSHA,
                      let reviewedDrafts = ReviewVerdictStore.authenticatedReviewDrafts(for: verdict, settings: settings) else { return nil as ReviewVerdictStore.Publication? }
                return ReviewVerdictStore.capturePublication(drafts, verdict: verdict,
                    before: discussions, reviewedDrafts: reviewedDrafts, user: user, in: verdictDirectory)
            }
            guard publication != nil || review != nil else { return nil }
            return .init(origin: publication, review: review, request: request)
        } catch { return nil }
    }

    private func recordGeneratedPublication(_ publication: PublicationEvidence?, id: Item.ID,
        account: Account, user: GitLabAuthenticatedUser) async {
        guard let publication else { return }
        let generation = accountGeneration, revision = glab.accountRevision
        func current() -> Bool {
            !Task.isCancelled && generation == accountGeneration && revision == glab.accountRevision && isCurrent(account)
        }
        guard current() else { return }
        do {
            let authenticated = try await glab.fetchAuthenticatedUser(host: account.host, expectedUsername: account.username)
            let discussions = try await glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
            guard authenticated == user, current() else { return }
            if let review = publication.review {
                let request = try await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
                guard current(), MRAttentionRecord.sameContext(publication.request, request),
                      ReviewVerdictStore.authenticatedVerdict(host: account.host, projectID: id.projectID,
                        iid: id.iid, user: user, settings: settings, in: verdictDirectory) == review.verdict else { return }
                try ReviewVerdictStore.recordPublication(review, after: discussions, user: user, in: verdictDirectory)
            }
            let directory = provenanceDirectory
            try await Task.detached(priority: .utility) {
                if let origin = publication.origin {
                    try AICommentProvenanceStore.recordPublished(origin, after: discussions, in: directory)
                }
            }.value
            guard current() else { return }
        } catch {
            Log.monitor.error("Could not record published comment origins: \(String(describing: error), privacy: .private)")
        }
    }

    private func assistantWorks(username: String) -> Set<AssistantAutomationRunner.MergeRequestWork> {
        guard let settings else { return [] }
        let handoffs = settings.assistantHandoffs.filter { $0.key.username == username }.map(\.key.work)
        let chats = settings.assistantChats.keys.filter { $0.username == username }.map(\.work)
        return Set(handoffs).union(chats)
    }

    func autoApproveApplies(to request: GitLabMergeRequest, host: String, username: String) -> Bool {
        guard let settings else { return false }
        let target = MRAutomationScope.Target(host: host, username: username, projectID: request.projectID, iid: request.iid)
        return settings.permitsAutomaticAction(.approval, for: request, target: target)
    }

    private func permitsAutomaticPublication(of request: GitLabMergeRequest, account: Account) -> Bool {
        let target = MRAutomationScope.Target(host: account.host, username: account.username,
            projectID: request.projectID, iid: request.iid)
        return settings?.permitsAutomaticAction(.commentPublication, for: request, target: target) == true
    }

    private struct ApprovalCheck {
        var discussions: [GitLabMergeRequestDiscussion]? = nil
        /// The user is a reviewer, has not approved yet and has no unresolved thread of their own.
        var ownReady = false
        /// Every resolvable discussion on the MR is resolved, including other reviewers'.
        var allResolved = false
    }

    private nonisolated static func approvalCheck(
        _ request: GitLabMergeRequest, user: GitLabAuthenticatedUser, host: String, glab: GlabService
    ) async -> ApprovalCheck {
        async let reviewers = try? glab.fetchMergeRequestReviewers(projectID: request.projectID, iid: request.iid, host: host)
        async let discussions = try? glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
        guard let reviewers = await reviewers, let discussions = await discussions,
              let me = reviewers.first(where: { $0.user.id == user.id }), me.state != "approved" else { return ApprovalCheck() }
        let ownOpen = discussions.contains { discussion in
            guard let first = discussion.notes.first else { return false }
            return first.author?.id == user.id && first.resolvable == true && first.resolved == false
        }
        return ApprovalCheck(discussions: discussions, ownReady: !ownOpen, allResolved: allResolved(discussions))
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

    /// With "Publish comments without confirmation" on, publishes assistant drafts once they are
    /// unchanged across two polls, so a draft the assistant is still writing is never sent.
    private func publishSettledDrafts(
        agentWorks: Set<AssistantAutomationRunner.MergeRequestWork>, account: Account, only id: Item.ID? = nil
    ) async {
        let earlier = previousDrafts
        previousDrafts = Dictionary(uniqueKeysWithValues: items.filter { !$0.drafts.isEmpty }.map { ($0.id, $0.drafts) })
        guard let settings, settings.automation.publishDraftsWithoutConfirmation || settings.automation.publishAIRepliesWithoutConfirmation else { return }
        for item in items where !item.drafts.isEmpty && earlier[item.id] == item.drafts && (id == nil || id == item.id) {
            let work = AssistantAutomationRunner.MergeRequestWork(host: account.host, projectID: item.id.projectID, iid: item.id.iid)
            guard agentWorks.contains(work), !hasActiveWorker(for: item.id, account: account), let request = item.mergeRequest,
                  permitsAutomaticPublication(of: request, account: account)
            else { continue }
            let checkedDraftIDs = item.automaticDraftIDs
            guard item.automaticPublicationPolicy == settings.automation.automaticPublicationPolicy,
                  !checkedDraftIDs.isEmpty else { continue }
            if settings.automation.publishDraftsWithoutConfirmation {
                await publishDrafts(of: item.id, automatic: true, checkedDraftIDs: checkedDraftIDs)
            } else {
                await publishAIReplies(of: item, account: account, checkedDraftIDs: checkedDraftIDs)
            }
        }
    }

    /// Cheap filters and reads do not disable the manual action or pretend a publication started.
    private func publishAIReplies(of item: Item, account: Account, checkedDraftIDs: Set<Int>) async {
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
        guard let configuration = settings?.automation, let request = item.mergeRequest else { return }
        let policy = configuration.automaticPublicationPolicy
        let aiIDs = await aiNoteIDs(in: discussions, policy: policy, host: account.host,
                                   projectID: id.projectID, iid: id.iid)
        func qualifies(_ draft: GitLabDraftNote, in threads: [GitLabMergeRequestDiscussion]) -> Bool {
            policy.allows(draft, request: request, discussions: threads, userID: user.id,
                          host: account.host, aiNoteIDs: aiIDs)
        }
        let eligible = candidates.filter { qualifies($0, in: discussions) }
        guard !eligible.isEmpty, isCurrent(account), !isConfirming(id) else { return }
        let generation = accountGeneration, revision = glab.accountRevision
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
                guard isCurrent(account), let settings, settings.automation.publishAIRepliesWithoutConfirmation,
                      let request = item.mergeRequest,
                      permitsAutomaticPublication(of: request, account: account)
                else { break }
                let liveDiscussions = try await glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
                let origin = await captureGeneratedPublication([draft], id: id, account: account, user: user, before: liveDiscussions)
                let latest = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
                guard latest.contains(draft), let draftID = draft.id, qualifies(draft, in: liveDiscussions),
                      isCurrent(account), settings.automation.publishAIRepliesWithoutConfirmation,
                      permitsAutomaticPublication(of: request, account: account) else { continue }
                guard let admitted = await automaticPublicationAdmission(draft, id: id, account: account,
                    request: request, aiRepliesOnly: true, generation: generation, revision: revision) else { continue }
                attemptedPublish = true
                try await glab.publishDraftNote(projectID: id.projectID, iid: id.iid, draftID: draftID,
                    host: account.host, shouldProceed: admitted)
                attemptedPublish = false
                guard isCurrent(account) else { return }
                published = true
                publishedDrafts[id, default: []].append(draft)
                publishedNow.append(draft)
                self.settings?.recordAutomaticCommentPublication([draft], for: commentReviewTarget(id, account: account))
                updateItem(id) {
                    $0.drafts.removeAll { $0 == draft }
                    $0.draftCount = $0.drafts.count
                }
                await recordGeneratedPublication(origin, id: id, account: account, user: user)
            }
            publicationChecked = true
        } catch {
            if attemptedPublish, isCurrent(account) { confirmationStates[id] = .failed }
            Log.monitor.error("Could not publish AI reply: \(String(describing: error), privacy: .private)")
        }
        if published, isCurrent(account) {
            previousDrafts[id] = nil
            if publicationChecked, publishedNow.count == item.drafts.count {
                await completeCommentReviewAfterPublication(id, snapshot: item.commentReviewSnapshot, published: publishedNow, account: account, user: user, automatic: true)
            }
            await refreshReReviewAfterPublication(id, account: account, user: user)
        }
    }

    private func commentReviewTarget(_ id: Item.ID, account: Account) -> MRAutomationScope.Target {
        .init(host: account.host, username: account.username, projectID: id.projectID, iid: id.iid)
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
            generation == self.accountGeneration && revision == self.glab.accountRevision && self.isCurrent(account)
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
            guard request.state == "opened", request.projectID == id.projectID, request.iid == id.iid,
                  request.webURL == displayed.url else { confirmationStates[id] = .changed; return }
            let drafts = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
            guard current() else { return }
            settings?.beginCommentReview(for: commentReviewTarget(id, account: account))
            updateItem(id) { $0.drafts = drafts; $0.draftCount = drafts.count }
            let matching = drafts.filter { $0.id == draftID }
            guard !matching.isEmpty else { return } // Already handled in GitLab; retain the human checkpoint.
            guard matching == [expected] else { confirmationStates[id] = .changed; return }
            try Task.checkCancellation()
            try await glab.deleteDraftNote(projectID: id.projectID, iid: id.iid, draftID: draftID, host: account.host) { !Task.isCancelled && current() }
            guard current() else { return }
            // A poll started before DELETE may still carry this exact snapshot.
            publishedDrafts[id, default: []].append(expected)
            previousDrafts[id] = nil
            updateItem(id) { $0.drafts.removeAll { $0 == expected }; $0.draftCount = $0.drafts.count }
            let remaining = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
            guard current() else { return }
            updateItem(id) { $0.drafts = remaining; $0.draftCount = remaining.count }
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
        let generation = accountGeneration, revision = glab.accountRevision
        func current() -> Bool { generation == accountGeneration && revision == glab.accountRevision && isCurrent(account) }
        confirmationStates[id] = .finishingCommentReview
        defer {
            if current(), confirmationStates[id] == .finishingCommentReview { confirmationStates[id] = nil }
            signalAutomaticActionIdle()
        }
        do {
            async let authenticated = glab.fetchAuthenticatedUser(host: account.host, expectedUsername: account.username)
            async let request = glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
            async let discussions = glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
            let (liveUser, live, threads) = try await (authenticated, request, discussions)
            guard current() else { return false }
            guard liveUser == user else { throw GlabError.notAuthenticated }
            // Read drafts last so an edit in GitLab during the other checks is observed.
            let drafts = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
            guard current() else { return false }
            updateItem(id) { $0.drafts = drafts; $0.draftCount = drafts.count }
            guard drafts.isEmpty, live.projectID == id.projectID, live.iid == id.iid, live.webURL == displayed.url,
                  snapshot.matches(live, discussions: threads, userID: user.id) else {
                confirmationStates[id] = .changed
                return false
            }
            settings?.completeCommentReview(for: commentReviewTarget(id, account: account))
            updateItem(id) { $0.requiresCommentReview = false }
            confirmationStates[id] = nil
            await refreshReReviewAfterPublication(id, account: account, user: user)
            onCommentReviewFinished?(id)
            return true
        } catch {
            if current() { confirmationStates[id] = .failed }
            Log.monitor.error("Could not finish comment review: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    /// Only an actual, successful publication can complete the human checkpoint implicitly.
    private func completeCommentReviewAfterPublication(_ id: Item.ID, snapshot: CommentReviewSnapshot?,
                                                       published: [GitLabDraftNote], account: Account,
                                                       user: GitLabAuthenticatedUser, automatic: Bool = false) async {
        guard let snapshot, !published.isEmpty, isCurrent(account),
              confirmationStates[id] != .failed, confirmationStates[id] != .changed else { return }
        let generation = accountGeneration, revision = glab.accountRevision
        func current() -> Bool { generation == accountGeneration && revision == glab.accountRevision && isCurrent(account) }
        do {
            async let authenticated = glab.fetchAuthenticatedUser(host: account.host, expectedUsername: account.username)
            async let request = glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
            async let discussions = glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
            let (liveUser, live, threads) = try await (authenticated, request, discussions)
            guard liveUser == user, current() else { return }
            let drafts = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
            guard current() else { return }
            let contextMatches = live.projectID == id.projectID && live.iid == id.iid
                && live.webURL.isGitLabMergeRequest(host: account.host, iid: id.iid)
                && snapshot.matches(live, discussions: threads, publishedDrafts: published, userID: user.id)
            let wasPending = commentReviewPending(id, account: account)
            let automaticallyComplete = !automatic || settings?.canAutomaticallyFinishCommentReview(for: commentReviewTarget(id, account: account)) == true
            if drafts.isEmpty && contextMatches && automaticallyComplete {
                settings?.completeCommentReview(for: commentReviewTarget(id, account: account))
            } else {
                settings?.beginCommentReview(for: commentReviewTarget(id, account: account))
                if !contextMatches { confirmationStates[id] = .changed }
            }
            updateItem(id) {
                $0.drafts = drafts; $0.draftCount = drafts.count
                $0.commentReviewSnapshot = CommentReviewSnapshot(request: live, discussions: threads)
            }
            if drafts.isEmpty, contextMatches, automaticallyComplete, wasPending { onCommentReviewFinished?(id) }
        } catch {
            if current() { confirmationStates[id] = .failed }
        }
    }

    /// Explicit consent binds the reviewed IDs and bodies, independently of automation policy.
    func publishDrafts(_ selected: [GitLabDraftNote], for target: MRDiscussionTarget) async {
        let id = Item.ID(projectID: target.projectID, iid: target.iid)
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
        let currentContext: @MainActor @Sendable () -> Bool = {
            generation == self.accountGeneration && revision == self.glab.accountRevision && self.isCurrent(account)
        }
        let ready: @MainActor @Sendable () -> Bool = {
            currentContext() && !self.hasActiveWorker(for: id, account: account)
                && MRAttentionRecord.sameContext(reviewedRequest, self.openItems.first(where: { $0.id == id })?.mergeRequest)
        }
        func display(_ drafts: [GitLabDraftNote]) {
            let visible = drafts.filter { publishedDrafts[id]?.contains($0) != true }
            updateItem(id) { $0.drafts = visible; $0.draftCount = visible.count }
        }
        confirmationStates[id] = .publishing
        defer {
            // Release this run's local lock even if its account revision changed.
            if generation == accountGeneration, confirmationStates[id] == .publishing { confirmationStates[id] = nil }
            signalAutomaticActionIdle()
        }
        var remaining = selected
        var publicDrafts: [GitLabDraftNote] = []
        if let previous = manualPublicationProgress[id], previous.accountRevision == revision,
           previous.snapshot == snapshot, MRAttentionRecord.sameContext(previous.request, reviewedRequest) {
            publicDrafts = previous.publicDrafts
        }
        func rememberPublicDraft(_ draft: GitLabDraftNote) {
            if !publicDrafts.contains(draft) { publicDrafts.append(draft) }
            manualPublicationProgress[id] = .init(request: reviewedRequest, snapshot: snapshot,
                accountRevision: revision, publicDrafts: publicDrafts)
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
                      let checkedFingerprint = ReviewVerdict.fingerprint(discussions) else {
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
                          let observed = self.openItems.first(where: { $0.id == id })?.observedDiscussionFingerprint else { return false }
                    return observed == snapshot.discussionFingerprint || observed == checkedFingerprint
                }
                // A changed later selection must stop the first write too. Unselected changes are unrelated.
                guard admitted(), remaining.allSatisfy({ expected in current.filter { $0.id == expected.id } == [expected] }),
                      let draftID = draft.id else {
                    confirmationStates[id] = .changed
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
                await recordGeneratedPublication(origin, id: id, account: account, user: user)
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
                    let matches = discussions.flatMap { thread in thread.notes.filter { note in
                        note.system != true && note.author?.id == user.id && note.author?.username == account.username
                            && note.id.map { $0 > 0 && !uncertainBeforeIDs.contains($0) } == true
                            && note.body == uncertainDraft.note
                            && (uncertainDraft.discussionID == nil || uncertainDraft.discussionID == thread.id)
                            && (uncertainDraft.position == nil || uncertainDraft.position == note.position)
                    } }
                    if matches.count == 1 { rememberPublicDraft(uncertainDraft) }
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
            if publishedNow.count == item.drafts.count {
                await completeCommentReviewAfterPublication(id, snapshot: snapshot, published: publicDrafts, account: account, user: user)
            }
            // A partial publication keeps the reviewed preview for continuation. A live
            // context mismatch above already invalidated stale feedback; re-review needs no drafts.
            if openItems.first(where: { $0.id == id })?.drafts.isEmpty == true {
                await refreshReReviewAfterPublication(id, account: account, user: user)
            }
        }
    }

    func publishDrafts(of id: Item.ID, automatic: Bool = false, checkedDraftIDs: Set<Int> = []) async {
        guard let account, isCurrent(account), let user,
              let displayed = items.first(where: { $0.id == id }), !displayed.drafts.isEmpty,
              !isConfirming(id) else { return }
        if !automatic {
            await publishDrafts(displayed.drafts, for: .init(host: account.host, username: account.username,
                projectID: id.projectID, iid: id.iid, url: displayed.url))
            return
        }
        guard !checkedDraftIDs.isEmpty, !hasActiveWorker(for: id, account: account) else { return }
        let expected = displayed.drafts
        let generation = accountGeneration, revision = glab.accountRevision
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
                updateItem(id) { $0.drafts = current; $0.draftCount = current.count }
                confirmationStates[id] = nil
                return
            }
            guard let settings, settings.automation.publishDraftsWithoutConfirmation,
                  let request = openItems.first(where: { $0.id == id })?.mergeRequest,
                  permitsAutomaticPublication(of: request, account: account) else {
                confirmationStates[id] = nil
                return
            }
            // Live evidence may narrow this frozen preview, never add an ID.
            for draft in current where draft.id.map(checkedDraftIDs.contains) == true {
                let origin = await captureGeneratedPublication([draft], id: id, account: account, user: user)
                let latest = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
                guard latest.contains(draft), let draftID = draft.id, isCurrent(account),
                      settings.automation.publishDraftsWithoutConfirmation,
                      let request = openItems.first(where: { $0.id == id })?.mergeRequest,
                      permitsAutomaticPublication(of: request, account: account),
                      AICommentAssessmentStore.safeForAutomaticPublication(draft),
                      let admitted = await automaticPublicationAdmission(draft, id: id, account: account,
                        request: request, aiRepliesOnly: false, generation: generation, revision: revision) else { continue }
                attemptedPublish = true
                try await glab.publishDraftNote(projectID: id.projectID, iid: id.iid, draftID: draftID,
                    host: account.host, shouldProceed: admitted)
                attemptedPublish = false
                guard isCurrent(account) else { return }
                publishedDrafts[id, default: []].append(draft)
                publishedNow.append(draft)
                settings.recordAutomaticCommentPublication([draft], for: commentReviewTarget(id, account: account))
                updateItem(id) { $0.drafts.removeAll { $0 == draft }; $0.draftCount = $0.drafts.count }
                await recordGeneratedPublication(origin, id: id, account: account, user: user)
            }
            let remaining = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
            guard isCurrent(account) else { return }
            updateItem(id) { $0.drafts = remaining; $0.draftCount = remaining.count }
            guard !publishedNow.isEmpty else { return }
            publicationChecked = true
            confirmationStates[id] = nil
        } catch {
            if isCurrent(account) { confirmationStates[id] = attemptedPublish ? .failed : nil }
            Log.monitor.error("Could not publish drafts: \(String(describing: error), privacy: .private)")
        }
        // A later read or PUT can fail after an earlier draft was successfully published.
        if !publishedNow.isEmpty, isCurrent(account) {
            previousDrafts[id] = nil
            if publicationChecked, publishedNow.count == expected.count {
                await completeCommentReviewAfterPublication(id, snapshot: displayed.commentReviewSnapshot, published: publishedNow, account: account, user: user, automatic: true)
            }
            await refreshReReviewAfterPublication(id, account: account, user: user)
        }
    }

    /// Bind every mutable authorization input after the live proof checks, then recheck
    /// the same envelope when the transport is ready to launch the individual PUT.
    private func automaticPublicationAdmission(_ draft: GitLabDraftNote, id: Item.ID, account: Account,
        request: GitLabMergeRequest, aiRepliesOnly: Bool, generation: Int, revision: UInt64) async -> (@MainActor @Sendable () -> Bool)? {
        guard let settings, let user else { return nil }
        let configuration = settings.automation
        guard await permitsAssistantAutomation(for: account),
              await permitsAutomaticPublication(draft, id: id, account: account),
              isCurrent(account), settings.automation == configuration,
              aiRepliesOnly ? settings.automation.publishAIRepliesWithoutConfirmation : settings.automation.publishDraftsWithoutConfirmation,
              permitsAutomaticPublication(of: request, account: account),
              !hasActiveWorker(for: id, account: account) else { return nil }
        let proofVerdict = ReviewVerdictStore.verdict(host: account.host, projectID: id.projectID, iid: id.iid, user: user, in: verdictDirectory)
        let proofReceipts = publicationReceipts(projectID: id.projectID, iid: id.iid, host: account.host, username: account.username)
        let reviewRevision = settings.commentReviewRevision(for: commentReviewTarget(id, account: account))
        let admitted: @MainActor @Sendable () -> Bool = {
            !Task.isCancelled && generation == self.accountGeneration && revision == self.glab.accountRevision
                && self.isCurrent(account) && settings.automaticPublicWritesAllowed
                && settings.automation == configuration
                && (aiRepliesOnly ? settings.automation.publishAIRepliesWithoutConfirmation : settings.automation.publishDraftsWithoutConfirmation)
                && self.openItems.first(where: { $0.id == id })?.mergeRequest?.sha == request.sha
                && self.openItems.first(where: { $0.id == id })?.mergeRequest?.semanticContextFingerprint == request.semanticContextFingerprint
                && ReviewVerdictStore.verdict(host: account.host, projectID: id.projectID, iid: id.iid, user: user, in: self.verdictDirectory) == proofVerdict
                && self.publicationReceipts(projectID: id.projectID, iid: id.iid, host: account.host, username: account.username) == proofReceipts
                && settings.commentReviewRevision(for: self.commentReviewTarget(id, account: account)) == reviewRevision
                && self.permitsAutomaticPublication(of: request, account: account)
                && !self.hasActiveWorker(for: id, account: account)
        }
        return admitted() ? admitted : nil
    }

    /// Identity verification and content-bound records supply facts; the pure policy
    /// decides the same way for the board preview and the final live publication gate.
    private func aiNoteIDs(in discussions: [GitLabMergeRequestDiscussion], policy: AutomaticPublicationPolicy,
                           host: String, projectID: Int, iid: Int) async -> Set<Int> {
        guard policy.requiresAI else { return [] }
        let notes = discussions.flatMap(\.notes).filter { $0.system != true }
        let candidates = Set(notes.compactMap { note -> Int? in
            guard note.author?.username?.lowercased() == "gitlabduo", let id = note.author?.id, id > 0 else { return nil }
            return id
        })
        var verifiedIdentities: Set<Int> = []
        for id in candidates where (try? await glab.isGitLabDuo(userID: id, host: host)) == true {
            verifiedIdentities.insert(id)
        }
        return Set(notes.compactMap { note in
            guard let id = note.id, id > 0 else { return nil }
            return verifiedIdentities.contains(note.author?.id ?? 0)
                || AICommentAssessmentStore.isAI(note, host: host, projectID: projectID, iid: iid, in: aiAssessmentDirectory) ? id : nil
        })
    }

    /// Preparation is independent of remote-fix proof. Publication only consumes its records.
    private func scheduleAIOriginChecks(request: GitLabMergeRequest, drafts: [GitLabDraftNote],
                                        discussions: [GitLabMergeRequestDiscussion], account: Account,
                                        user: GitLabAuthenticatedUser) async {
        guard let settings, isCurrent(account), !Task.isCancelled else { return }
        let configuration = settings.automation
        let policy = configuration.automaticPublicationPolicy
        guard configuration.hasAutomaticActionConsent, policy.mode != .manual, policy.requiresAI,
              configuration.scope.permits(request, host: account.host, username: account.username) else { return }
        var sources: [Int: GitLabMergeRequestDiscussion.Note] = [:]
        for draft in drafts where policy.couldAllow(draft, request: request, userID: user.id, host: account.host) {
            guard let notes = AutomaticPublicationPolicy.sourceNotes(for: draft, discussions: discussions, userID: user.id),
                  notes.allSatisfy({ note in
                      policy.restrictions.sourceCommentAuthors.isEmpty || policy.restrictions.sourceCommentAuthors.contains {
                          $0.host == account.host && $0.entityID == note.author?.id
                      }
                  }) else { continue }
            for note in notes { if let id = note.id { sources[id] = note } }
        }
        guard !sources.isEmpty else { return }
        let knownAI = await aiNoteIDs(in: discussions, policy: policy, host: account.host,
            projectID: request.projectID, iid: request.iid)
        let unknown = sources.filter { !knownAI.contains($0.key) }.sorted { $0.key < $1.key }.map(\.value)
        guard !unknown.isEmpty, await permitsAssistantAutomation(for: account), isCurrent(account),
              settings.automation == configuration, !Task.isCancelled else { return }
        let model = configuration.assistant == .codex ? configuration.codexVerificationModel.rawValue
            : configuration.claudeVerificationModel.rawValue
        aiOriginCoordinator.schedule(target: .init(host: account.host, username: account.username,
            projectID: request.projectID, iid: request.iid), notes: unknown, assistant: configuration.assistant, model: model, thinking: configuration.verificationThinking)
    }

    /// Every automatic publication needs current discussion evidence. Author replies
    /// additionally need this run's exact draft and remote source content.
    private func permitsAutomaticPublication(_ draft: GitLabDraftNote, id: Item.ID, account: Account) async -> Bool {
        guard let user, !hasActiveWorker(for: id, account: account),
              openItems.first(where: { $0.id == id })?.mergeRequest != nil else { return false }
        var permitted = false
        defer {
            if !permitted, isCurrent(account), let draftID = draft.id {
                // A newer live read may reject a formerly eligible preview.
                // Keep that exact draft visible as a private human checkpoint.
                updateItem(id) { $0.automaticDraftIDs.remove(draftID) }
            }
        }
        let live = try? await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
        let discussions = try? await glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
        guard isCurrent(account), Self.draftContextIsCurrent(request: live, drafts: [draft], discussions: discussions,
            host: account.host, user: user, verdictDirectory: verdictDirectory,
            followUpReceipts: publicationReceipts(projectID: id.projectID, iid: id.iid, host: account.host, username: user.username)) else {
            updateItem(id) { $0.requiresDiscussionRecheck = true }
            return false
        }
        guard let live, let discussions, let settings else { return false }
        let policy = settings.automation.automaticPublicationPolicy
        let aiIDs = await aiNoteIDs(in: discussions, policy: policy, host: account.host,
                                   projectID: id.projectID, iid: id.iid)
        guard isCurrent(account), settings.automation.automaticPublicationPolicy == policy,
              permitsAutomaticPublication(of: live, account: account),
              policy.allows(draft, request: live, discussions: discussions, userID: user.id,
                            host: account.host, aiNoteIDs: aiIDs) else { return false }
        if live.author.id != user.id {
            // The discussion reads above can outlive the caller's draft snapshot.
            // Recheck the exact body so a concurrent edit cannot smuggle quick actions.
            guard let latest = try? await glab.fetchOwnDraftNotes(
                projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id
            ), latest.contains(draft), AICommentAssessmentStore.safeForAutomaticPublication(draft),
                  isCurrent(account), permitsAutomaticPublication(of: live, account: account) else { return false }
            permitted = true
            return true
        }
        func blocked() -> Bool {
            updateItem(id) { $0.awaitingRemoteVerification = true }
            return false
        }
        guard settings.automation.allowFollowUpPush else { return blocked() }
        guard let receipt = Self.followUpReceipt(for: draft, request: live, discussions: discussions,
            host: account.host, user: user, verdictDirectory: verdictDirectory,
            receipts: publicationReceipts(projectID: id.projectID, iid: id.iid, host: account.host, username: user.username)) else { return blocked() }
        do {
            let live = try await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
            guard receipt.covers(draft, request: live, host: account.host, user: user, runID: receipt.runID) else { return blocked() }
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
            guard currentUser == user, currentSource == receipt.headSHA, freshDrafts.contains(draft),
                  Self.draftContextIsCurrent(request: currentMR, drafts: [draft], discussions: freshDiscussions,
                    host: account.host, user: currentUser, verdictDirectory: verdictDirectory,
                    followUpReceipts: [receipt]),
                  receipt.covers(draft, request: currentMR, host: account.host, user: currentUser, runID: receipt.runID),
                  isCurrent(account), settings.automation.allowFollowUpPush,
                  publicationReceipts(projectID: id.projectID, iid: id.iid, host: account.host, username: user.username).contains(receipt),
                  permitsAutomaticPublication(of: currentMR, account: account) else { return blocked() }
            let freshAIIDs = await aiNoteIDs(in: freshDiscussions, policy: policy, host: account.host,
                                            projectID: id.projectID, iid: id.iid)
            // Identity verification can await GitLab after the proof snapshot's draft
            // read. Re-read the exact body last so a concurrent edit cannot execute
            // a quick action or publish an unsealed author-follow-up response.
            let finalDrafts = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid,
                                                               host: account.host, userID: currentUser.id)
            guard finalDrafts.contains(draft), AutomaticPublicationPolicy.safeForAutomaticPublication(draft),
                  isCurrent(account), settings.automation.automaticPublicationPolicy == policy,
                  settings.automation.allowFollowUpPush,
                  publicationReceipts(projectID: id.projectID, iid: id.iid, host: account.host, username: user.username).contains(receipt),
                  permitsAutomaticPublication(of: currentMR, account: account) else { return false }
            guard isCurrent(account), settings.automation.automaticPublicationPolicy == policy,
                  policy.allows(draft, request: currentMR, discussions: freshDiscussions, userID: currentUser.id,
                                host: account.host, aiNoteIDs: freshAIIDs) else { return false }
            permitted = true
            return true
        } catch {
            Log.monitor.error("Author follow-up is awaiting remote verification: \(String(describing: error), privacy: .private)")
            return blocked()
        }
    }

    func approve(_ id: Item.ID) async {
        guard let item = (items + openItems).first(where: { $0.id == id }), item.canApprove,
              let head = item.mergeRequest?.sha else { return }
        _ = await performApproval(of: id, head: head, requireAllResolved: false)
    }

    enum RemotePublicationResult { case completed, changed, uncertain, partial }

    func publishRemoteDrafts(of id: Item.ID, head: String, expectedDrafts: [GitLabDraftNote]) async -> RemotePublicationResult {
        guard let account, isCurrent(account), let user, let executable = glab.glabPath, !isConfirming(id),
              !expectedDrafts.isEmpty, expectedDrafts.allSatisfy(AICommentAssessmentStore.safeForAutomaticPublication),
              expectedDrafts.allSatisfy({ $0.id != nil && $0.authorID == user.id }),
              Set(expectedDrafts.compactMap(\.id)).count == expectedDrafts.count,
              let displayed = items.first(where: { $0.id == id }), displayed.drafts == expectedDrafts else { return .changed }
        let generation = accountGeneration, revision = glab.accountRevision
        let currentContext: @MainActor @Sendable () -> Bool = {
            generation == self.accountGeneration && revision == self.glab.accountRevision
                && executable == self.glab.glabPath && self.isCurrent(account)
        }
        confirmationStates[id] = .publishing
        defer {
            if generation == accountGeneration, confirmationStates[id] == .publishing { confirmationStates[id] = nil }
            signalAutomaticActionIdle()
        }
        var remaining = expectedDrafts
        var attemptedWrite = false
        var publishedAny = false
        do {
            for draft in expectedDrafts {
                try Task.checkCancellation()
                async let live = glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
                async let authenticated = glab.fetchAuthenticatedUser(host: account.host, expectedUsername: account.username)
                let (request, liveUser) = try await (live, authenticated)
                guard currentContext() else { return publishedAny ? .partial : .changed }
                guard liveUser == user else { throw GlabError.notAuthenticated }
                let origin = await captureGeneratedPublication([draft], id: id, account: account, user: user)
                // Read the exact bodies last, after identity checks that can suspend.
                let drafts = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
                guard currentContext(), request.state == "opened", request.sha == head,
                      request.projectID == id.projectID, request.iid == id.iid, request.webURL == displayed.url,
                      drafts == remaining, let draftID = draft.id else {
                    if currentContext() { confirmationStates[id] = .changed }
                    return publishedAny ? .partial : .changed
                }
                try Task.checkCancellation()
                attemptedWrite = true
                try await glab.publishDraftNote(projectID: id.projectID, iid: id.iid, draftID: draftID, host: account.host) { !Task.isCancelled && currentContext() }
                attemptedWrite = false
                guard currentContext() else { return .uncertain }
                publishedAny = true
                remaining.removeAll { $0 == draft }
                publishedDrafts[id, default: []].append(draft)
                updateItem(id) { $0.drafts = remaining; $0.draftCount = remaining.count }
                await recordGeneratedPublication(origin, id: id, account: account, user: user)
            }
            previousDrafts[id] = nil
            confirmationStates[id] = nil
            await completeCommentReviewAfterPublication(id, snapshot: displayed.commentReviewSnapshot, published: expectedDrafts, account: account, user: user)
            guard currentContext() else { return .uncertain }
            await refreshReReviewAfterPublication(id, account: account, user: user)
            return currentContext() ? .completed : .uncertain
        } catch {
            if currentContext() { confirmationStates[id] = .failed }
            return attemptedWrite ? .uncertain : (publishedAny ? .partial : .changed)
        }
    }

    func approveRemotely(_ id: Item.ID, expectedHead: String) async -> Bool {
        guard let item = (currentItems + currentOpenItems).first(where: { $0.id == id }), item.canApprove,
              item.mergeRequest?.sha == expectedHead else { return false }
        return await performApproval(of: id, head: expectedHead, requireAllResolved: false)
    }

    /// Re-checks the live MR, approves at `head` and reports whether GitLab confirmed it.
    private func performApproval(of id: Item.ID, head: String, requireAllResolved: Bool) async -> Bool {
        guard let account, isCurrent(account), let user, !isConfirming(id) else { return false }
        let generation = accountGeneration
        let revision = glab.accountRevision
        let displayed = (openItems + items).first { $0.id == id }?.mergeRequest
        let readContext = ApprovalReadContext(revision: revision, head: head,
            discussionFingerprint: ReviewVerdictStore.verdict(host: account.host, projectID: id.projectID,
                iid: id.iid, user: user, in: verdictDirectory)?.discussionFingerprint,
            semanticContext: displayed?.semanticContextFingerprint, configuration: settings?.automation)
        if requireAllResolved, let failure = approvalReadFailures[id], failure.context == readContext,
           approvalReadClock() < failure.retryAfter { return false }
        var submitted = false
        var checkedFingerprint: String?
        var checkedSemanticContext: String?
        typealias Evidence = (request: GitLabMergeRequest, drafts: [GitLabDraftNote],
                              discussions: [GitLabMergeRequestDiscussion], user: GitLabAuthenticatedUser, approvers: Set<Int>)
        let currentAccount: @MainActor @Sendable () -> Bool = {
            generation == self.accountGeneration && revision == self.glab.accountRevision && self.isCurrent(account)
        }
        @MainActor func readEvidence() async throws -> Evidence {
            let current = try await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
            let drafts = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
            let discussions = try await glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
            let currentUser = try await glab.fetchAuthenticatedUser(host: account.host, expectedUsername: account.username)
            let approved = try await glab.fetchMergeRequestApproverIDs(projectID: id.projectID, iid: id.iid, host: account.host)
            return (current, drafts, discussions, currentUser, approved)
        }
        let permits: @MainActor @Sendable (Evidence) -> Bool = { evidence in
            let current = evidence.request
            let verdict = ReviewVerdictStore.verdict(host: account.host, projectID: id.projectID, iid: id.iid, user: user, in: self.verdictDirectory)
            let covered: Bool
            if requireAllResolved, let verdict {
                covered = ReviewVerdictStore.automaticallyApproves(verdict, head: head,
                    discussions: evidence.discussions, user: user, in: self.verdictDirectory)
            } else {
                covered = verdict?.approves(head: head, discussions: evidence.discussions, reviewerID: user.id,
                    publishedDrafts: ReviewVerdictStore.seenDrafts(host: account.host, projectID: id.projectID,
                        iid: id.iid, in: self.verdictDirectory)) == true
            }
            return currentAccount() && !self.commentReviewPending(id, account: account)
                && (!requireAllResolved || (verdict != nil && verdict == ReviewVerdictStore.authenticatedVerdict(
                    host: account.host, projectID: id.projectID, iid: id.iid, user: user,
                    settings: self.settings, in: self.verdictDirectory)))
                && evidence.user == user && current.state == "opened" && current.draft != nil
                && current.sha == head && current.author.id != user.id && evidence.drafts.isEmpty
                && covered
                && (!requireAllResolved || (Self.allResolved(evidence.discussions)
                    && self.autoApproveApplies(to: current, host: account.host, username: account.username)))
        }
        @MainActor func confirmed() -> Bool {
            approvedHeads[id] = head
            failedApprovalHeads[id] = nil
            approvalReadFailures.removeValue(forKey: id)
            updateItem(id) { $0.canApprove = false }
            confirmationStates[id] = nil
            return true
        }
        confirmationStates[id] = .approving
        defer {
            if generation == accountGeneration, confirmationStates[id] == .approving { confirmationStates[id] = nil }
            signalAutomaticActionIdle()
        }
        do {
            let evidence = try await ReadOnlyAssessmentRetry.run(isCurrent: currentAccount, wait: approvalReadWait, operation: readEvidence)
            approvalReadFailures.removeValue(forKey: id)
            guard permits(evidence) else {
                guard currentAccount() else { return false }
                updateItem(id) { $0.canApprove = false }
                confirmationStates[id] = requireAllResolved ? nil : .changed
                return false
            }
            checkedFingerprint = ReviewVerdict.fingerprint(evidence.discussions)
            checkedSemanticContext = evidence.request.semanticContextFingerprint
            // The previous POST may already have succeeded despite a lost response.
            if evidence.approvers.contains(user.id) { return confirmed() }
            if requireAllResolved {
                guard await permitsAssistantAutomation(for: account),
                      currentAccount(), autoApproveApplies(to: evidence.request, host: account.host, username: account.username) else {
                    if currentAccount() {
                        confirmationStates[id] = nil
                        updateItem(id) { $0.canApprove = true; $0.autoApproveReady = false }
                    }
                    return false
                }
            }
            try await glab.approveMergeRequest(projectID: id.projectID, iid: id.iid, headSHA: head,
                host: account.host, userID: user.id, willSubmit: { submitted = true },
                shouldProceed: { permits(evidence) })
            guard currentAccount() else { return false }
            return confirmed()
        } catch {
            guard currentAccount() else { return false }
            if submitted,
               let evidence = try? await ReadOnlyAssessmentRetry.run(isCurrent: currentAccount, wait: approvalReadWait, operation: readEvidence),
               permits(evidence), evidence.approvers.contains(user.id),
               evidence.request.semanticContextFingerprint == checkedSemanticContext,
               ReviewVerdict.fingerprint(evidence.discussions) == checkedFingerprint { return confirmed() }
            guard currentAccount() else { return false }
            // Pure GET failures cannot establish that GitLab rejected a write.
            // An attempted, unconfirmed POST keeps the existing deliberate retry fence.
            if requireAllResolved && !submitted {
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
        confirmationStates[id]?.isBusy == true
    }

    private func updateItem(_ id: Item.ID, introducesAttention: Bool = true,
                            skipUnchangedPendingDraftEvidence: Bool = false, _ change: (inout Item) -> Void) {
        guard attentionRecordsRevision == glab.accountRevision, var record = attentionRecords[id] else { return }
        var item = record.evidence
        change(&item)
        if let account {
            item.requiresCommentReview = commentReviewPending(id, account: account)
            if item.requiresCommentReview { item.canApprove = false; item.autoApproveReady = false; item.canConfirmReReview = false }
        }
        if item.drafts.isEmpty { item.awaitingRemoteVerification = false; item.requiresDiscussionRecheck = false }
        else if item.isAuthored, let settings, let account, let user, let request = item.mergeRequest {
            let work = AssistantAutomationRunner.MergeRequestWork(host: account.host, projectID: id.projectID, iid: id.iid)
            if assistantWorks(username: user.username).contains(work) {
                let receipts = publicationReceipts(projectID: id.projectID, iid: id.iid,
                    host: account.host, username: user.username)
                // Conditions that definitely exclude these drafts do not require
                // automatic remote proof; they remain ordinary manual checkpoints.
                let candidates = item.drafts.filter {
                    settings.automation.scope.permits(request, host: account.host, username: account.username)
                        && settings.automation.automaticPublicationPolicy.couldAllow(
                            $0, request: request, userID: user.id, host: account.host)
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
            guard !Task.isCancelled, generation == refreshGeneration, revision == glab.accountRevision else { return }
            let read = await glab.fetchPendingDraftRead(projectID: item.id.projectID, iid: item.id.iid,
                host: account.host, userID: user.id)
            guard !Task.isCancelled, generation == refreshGeneration, revision == glab.accountRevision,
                  isCurrent(account), !isLoading, !isConfirming(item.id),
                  let latest = items.first(where: { $0.id == item.id }), latest.drafts == item.drafts,
                  MRAttentionRecord.sameContext(latest.mergeRequest, item.mergeRequest),
                  (settings?.commentReviewRevision(for: target) ?? 0) == reviewRevision else { continue }
            guard var current = read.drafts else {
                updateItem(item.id, skipUnchangedPendingDraftEvidence: true) {
                    $0.requiresDiscussionRecheck = !$0.drafts.isEmpty
                    $0.canApprove = false
                    $0.canConfirmReReview = false
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
                    host: account.host, username: user.username))
            let approvalCurrent = contextMatches && (request.flatMap { request in
                discussions.map { discussions in
                    ReviewVerdictStore.verdict(host: account.host, projectID: item.id.projectID, iid: item.id.iid, user: user, in: verdictDirectory)?
                        .approves(head: request.sha ?? "", discussions: discussions, reviewerID: user.id,
                            publishedDrafts: ReviewVerdictStore.seenDrafts(host: account.host, projectID: item.id.projectID,
                                iid: item.id.iid, in: verdictDirectory)) == true && request.state == "opened"
                }
            } ?? false)
            updateItem(item.id, skipUnchangedPendingDraftEvidence: true) {
                $0.drafts = current; $0.draftCount = current.count
                $0.commentReviewSnapshot = CommentReviewSnapshot(request: request, discussions: discussions)
                $0.reviewingProgress = contextMatches ? Self.reviewingProgress(for: item, request: request,
                    discussions: discussions, host: account.host, user: user, verdictDirectory: verdictDirectory) : nil
                if !$0.isAuthored, let request {
                    $0.reviewingActivity = discussions.map {
                        ReviewingActivity(discussions: $0, reviewerID: user.id, authorID: request.author.id)
                    }
                }
                $0.invalidateChangedDiscussionSnapshot(head: request?.sha,
                    fingerprint: discussions.flatMap { ReviewVerdict.fingerprint($0) },
                    semanticContextFingerprint: request?.semanticContextFingerprint)
                $0.requiresDiscussionRecheck = !current.isEmpty && !contextCurrent
                if !approvalCurrent { $0.canApprove = false }
                if !contextMatches || request == nil || discussions == nil || request?.sha != item.mergeRequest?.sha
                    || request?.semanticContextFingerprint != item.mergeRequest?.semanticContextFingerprint
                    || ReviewVerdict.fingerprint(discussions ?? []) != item.reReviewFingerprint {
                    $0.canConfirmReReview = false
                }
            }
            if current != item.drafts {
                confirmationStates[item.id] = nil
                previousDrafts[item.id] = nil
                await refreshReReviewAfterPublication(item.id, account: account, user: user)
            }
        }
    }

    private func refreshReReviewAfterPublication(_ id: Item.ID, account: Account, user: GitLabAuthenticatedUser) async {
        let revision = glab.accountRevision
        guard openItems.first(where: { $0.id == id })?.isAuthored == true,
              let request = try? await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host),
              request.author.id == user.id,
              let drafts = try? await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id),
              let discussions = try? await glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host),
              isCurrent(account), glab.accountRevision == revision else { return }
        updateItem(id) {
            $0.invalidateChangedDiscussionSnapshot(head: request.sha, fingerprint: ReviewVerdict.fingerprint(discussions),
                semanticContextFingerprint: request.semanticContextFingerprint)
        }
        await requestReReviewsIfReady(for: request, feedback: ReReviewFeedback(discussions: discussions, authorID: user.id),
                                      draftCount: drafts.count, account: account, user: user)
    }

    private func reReviewContext(_ id: Item.ID, account: Account) -> ReReviewCoordinator.Context {
        .init(host: account.host, username: account.username, revision: glab.accountRevision,
            projectID: id.projectID, iid: id.iid)
    }

    private func applyReReviewPresentation(_ item: inout Item, unanswered: Bool) {
        guard let account else { return }
        item.requiresCommentReview = commentReviewPending(item.id, account: account)
        if item.requiresCommentReview { item.canApprove = false; item.autoApproveReady = false }
        let status = reReviewCoordinator?.status(for: reReviewContext(item.id, account: account), authorID: user?.id)
        item.reReviewReadiness = status?.state
        item.reReviewFingerprint = status?.fingerprint
        item.canConfirmReReview = status?.state?.canConfirm == true && !unanswered && item.draftCount == 0 && !item.requiresCommentReview
        item.reReviewRequested = status?.requested ?? false
        item.reReviewUnconfirmed = status?.unconfirmed ?? false
    }

    private func updateReReviewPresentation(_ id: Item.ID, unanswered: Bool = false) {
        // A background presentation update cannot admit a retained-only catalog row.
        updateItem(id, introducesAttention: false) { applyReReviewPresentation(&$0, unanswered: unanswered) }
    }

    func retryReReview(_ id: Item.ID) async {
        guard let account, let user, isCurrent(account) else { return }
        await reReviewCoordinator?.retry(reReviewContext(id, account: account), user: user)
    }

    func cancelRuntimePreparation(outsideScope scope: MRAutomationScope) {
        reReviewCoordinator?.cancelRuntimePreparation(outsideScope: scope)
    }

    func automationConfigurationChanged(outsideScope scope: MRAutomationScope? = nil) {
        authorFeedbackCoordinator?.cancel(outsideScope: scope)
        draftProofRecoveryCoordinator?.cancel(outsideScope: scope)
        aiOriginCoordinator.cancel(outsideScope: scope)
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

extension MergeRequestAttentionMonitor.Item {
    /// A row missing from the filtered list has no manual reasons; its catalog
    /// fallback must not restore work already owned by automation.
    func presentingHumanAttention(filtered: Self?, unfiltered: Self?, assistantReady: Bool) -> Self {
        if assistantReady {
            return filtered ?? Self(id: id, title: title, url: url, mergeRequest: mergeRequest, isAuthored: isAuthored)
        }
        var manual = unfiltered ?? self
        manual.needsMerge = manual.needsMerge || filtered?.needsMerge == true
        return manual
    }
}
