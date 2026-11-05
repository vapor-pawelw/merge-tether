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
        let title: String
        let url: URL
        var draftCount = 0
        /// The current user's unpublished drafts, shown in Ready for your OK.
        var drafts: [GitLabDraftNote] = []
        var replyRecipients: [String: String] = [:]
        var awaitingRemoteVerification = false
        /// The assistant has no objections to the current head and the user has nothing open,
        /// but automatic approval does not apply, so the user approves in Ready for your OK.
        var canApprove = false
        /// Automatic approval applies and every discussion is resolved.
        var autoApproveReady = false
        var needsDiscussion = false
        var hasOtherUnresolvedDiscussions = false
        var hasConflict = false
        var needsChanges = false
        var needsMerge = false
        var failedPipeline = false
        var needsPipelineHandoff = false
        var reReviewUnconfirmed = false
        var reReviewRequested = false
        var draftFromTodo = false
        var mergeRequest: GitLabMergeRequest?
        var isAuthored = false
        var feedback: [GitLabMergeRequestDiscussion.Note] = []

        var authoredRequest: GitLabMergeRequest? { isAuthored ? mergeRequest : nil }

        func canOfferMerge(using status: AuthoredMergeRequestStatus) -> Bool {
            status.blockers.isEmpty && status.request.isReadyForMergeChecks
                && status.request.projectID == id.projectID && status.request.iid == id.iid
                && status.request.webURL == mergeRequest?.webURL && status.request.sha == mergeRequest?.sha
                && draftCount == 0 && !needsDiscussion && feedback.isEmpty && !needsChanges && !hasConflict
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
            guard let request = authoredRequest, request.state == "opened", request.draft == false,
                  request.author.username == target.username,
                  request.projectID == target.projectID, request.iid == target.iid,
                  request.webURL.isGitLabMergeRequest(host: target.host, iid: request.iid),
                  automation.scope.resolve(target).active else { return self }
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
                || reReviewUnconfirmed || !feedback.isEmpty
        }

        var needsAttention: Bool { needsConfirmation || hasOpenAction }

        /// Something the user must confirm before it reaches other people.
        var needsConfirmation: Bool { draftCount > 0 || canApprove }

        var section: Section {
            if mergeRequest?.detailedMergeStatus == "draft_status" || (mergeRequest?.draft ?? draftFromTodo) {
                return .draftMergeRequests
            }
            return needsConfirmation && !hasOpenAction ? .unpublishedComments : .open
        }

        static func ordered(_ items: [Self]) -> [Self] {
            items.map { (item: $0, order: $0.mergeOrder) }
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
        case publishing, approving, failed, changed
    }

    private(set) var items: [Item] = []
    private(set) var confirmationStates: [Item.ID: ConfirmationState] = [:]
    private var user: GitLabAuthenticatedUser?
    /// Drafts seen on the previous poll, so automatic publishing waits until they stop changing.
    private var previousDrafts: [Item.ID: [GitLabDraftNote]] = [:]
    /// Drafts already published; a poll that started earlier may still report them.
    private var publishedDrafts: [Item.ID: [GitLabDraftNote]] = [:]
    /// Heads approved here, until GitLab's reviewer state catches up.
    private var approvedHeads: [Item.ID: String] = [:]
    /// Commits GitLab refused to auto-approve; retried only after a new commit or a manual approval.
    private var failedApprovalHeads: [Item.ID: String] = [:]
    private var openItems: [Item] = []
    /// Historical chats remain recorded after their MR closes. Recheck them only
    /// after an open listing makes them current again, or after an account change.
    private var terminalCatalogRequests: Set<Item.ID> = []
    private(set) var isLoading = false
    private(set) var hasError = false
    private(set) var hasCurrentOwnListing = false
    private let glab: GlabService
    private let settings: SettingsManager?
    private let reportDirectory: URL?
    private let verdictDirectory: URL
    private let aiAssessmentDirectory: URL
    private let followUpDirectory: URL
    private var verifiedRemoteFiles: [String: [FollowUpVerification.FileEvidence]] = [:]
    private var isRefreshingDrafts = false
    private var reReviewsInProgress: Set<MRAutomationScope.Target> = []
    /// Called after MergeTether approved a merge request on its own.
    var onAutoApproved: ((GitLabMergeRequest) -> Void)?
    var onRefreshed: (() -> Void)?
    private var account: Account?
    private var accountGeneration = 0
    private var recentTodos: [Item] = []

    private struct Account: Equatable {
        let host: String
        let username: String
    }

    init(
        glab: GlabService, settings: SettingsManager? = nil, reportDirectory: URL? = nil,
        verdictDirectory: URL = ReviewVerdictStore.directory,
        aiAssessmentDirectory: URL = AICommentAssessmentStore.directory,
        followUpDirectory: URL = FollowUpVerificationStore.directory
    ) {
        self.glab = glab
        self.settings = settings
        self.reportDirectory = reportDirectory
        self.verdictDirectory = verdictDirectory
        self.aiAssessmentDirectory = aiAssessmentDirectory
        self.followUpDirectory = followUpDirectory
    }

    var currentItems: [Item] {
        guard let account, isCurrent(account) else { return [] }
        return items
    }

    var currentOpenItems: [Item] {
        guard let account, isCurrent(account) else { return [] }
        return openItems
    }

    func refresh(host: String, username: String, todos: [Todo]) {
        let account = Account(host: host, username: username)
        guard !isLoading, isCurrent(account) else { return }
        if self.account != account {
            accountGeneration += 1
            items = []
            openItems = []
            terminalCatalogRequests = []
            recentTodos = []
            hasError = false
            hasCurrentOwnListing = false
            confirmationStates = [:]
            previousDrafts = [:]
            publishedDrafts = [:]
            approvedHeads = [:]
            failedApprovalHeads = [:]
            verifiedRemoteFiles = [:]
            user = nil
            self.account = account
            if let reportDirectory { CodexDesktopRelay.clearMergeRequestStatus(in: reportDirectory) }
        }
        isLoading = true
        Task {
            defer { isLoading = false; onRefreshed?() }
            do {
                try await poll(account, todos: todos)
            } catch {
                if isCurrent(account) { hasError = true }
            }
        }
    }

    private func isCurrent(_ account: Account) -> Bool {
        glab.resolvedHost == account.host && glab.currentUsername == account.username
    }

    private func poll(_ account: Account, todos: [Todo]) async throws {
        let host = account.host
        let user = try await glab.fetchAuthenticatedUser(host: host, expectedUsername: account.username)
        self.user = user
        let agentWorks = assistantWorks(username: user.username)
        let verdictDirectory = verdictDirectory
        async let authored = try? glab.fetchAuthoredMergeRequests(host: host)
        async let reviewing = try? glab.fetchReviewAssignedMergeRequests(userID: user.id, host: host)
        let (owned, assigned) = await (authored, reviewing)
        guard isCurrent(account) else { return }
        let listed = (owned ?? []) + (assigned ?? [])
        let listedIDs = Set(listed.map { Item.ID(projectID: $0.projectID, iid: $0.iid) })
        for request in listed where request.state == "opened" {
            terminalCatalogRequests.remove(.init(projectID: request.projectID, iid: request.iid))
        }
        let previousCatalog = Dictionary(uniqueKeysWithValues: openItems.map { ($0.id, $0) })
        // Catalog rows have independent sources. A failed source must not make its
        // last good rows disappear merely because the other source succeeded.
        var retainedCatalog = previousCatalog.filter { _, item in
            item.mergeRequest?.author.id == user.id ? owned == nil : assigned == nil
        }
        for request in listed where request.state == "closed" || request.state == "merged" {
            retainedCatalog.removeValue(forKey: .init(projectID: request.projectID, iid: request.iid))
        }
        var explicit: [GitLabMergeRequest] = []
        var explicitFetchFailed = false
        var lookedUpIDs = listedIDs
        var removedMergedOverride = false
        for target in settings?.automation.scope.individualOverrides(host: host, username: user.username) ?? [] {
            guard let iid = target.iid, !listedIDs.contains(.init(projectID: target.projectID, iid: iid)) else { continue }
            let id = Item.ID(projectID: target.projectID, iid: iid)
            lookedUpIDs.insert(id)
            guard let request = try? await glab.fetchMergeRequest(projectID: target.projectID, iid: iid, host: host) else {
                explicitFetchFailed = true
                if let previous = previousCatalog[id] { retainedCatalog[id] = previous }
                continue
            }
            guard isCurrent(account) else { return }
            if request.state == "merged" {
                retainedCatalog.removeValue(forKey: id)
                settings?.automation.scope[target] = .inherit
                settings?.reReviewDraftBaselines.removeValue(forKey: target)
                removedMergedOverride = true
            } else if request.state == "closed" {
                retainedCatalog.removeValue(forKey: id)
            } else if request.state == "opened" {
                terminalCatalogRequests.remove(id)
                explicit.append(request)
            }
        }
        guard isCurrent(account) else { return }
        if removedMergedOverride { settings?.save() }

        // A completed review may no longer be assigned to this user. Its recorded
        // chat still identifies a managed MR, without turning catalog discovery
        // into another automation trigger or draft-publication candidate.
        var recordedReviews: [GitLabMergeRequest] = []
        for work in agentWorks.sorted(by: { ($0.projectID, $0.iid) < ($1.projectID, $1.iid) }) {
            let id = Item.ID(projectID: work.projectID, iid: work.iid)
            let target = MRAutomationScope.Target(host: host, username: user.username,
                                                  projectID: work.projectID, iid: work.iid)
            guard work.host == host, !lookedUpIDs.contains(id), !terminalCatalogRequests.contains(id),
                  settings?.automation.scope.resolve(target).active == true else { continue }
            guard let request = try? await glab.fetchMergeRequest(projectID: work.projectID, iid: work.iid, host: host) else {
                explicitFetchFailed = true
                if let previous = previousCatalog[id] { retainedCatalog[id] = previous }
                continue
            }
            guard isCurrent(account) else { return }
            if request.state == "merged" || request.state == "closed" {
                terminalCatalogRequests.insert(id)
                retainedCatalog.removeValue(forKey: id)
            } else if request.state == "opened", request.author.id != user.id,
                      request.webURL.isGitLabMergeRequest(host: host, iid: work.iid) {
                recordedReviews.append(request)
            }
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
        for item in items where item.draftCount > 0 || owned == nil {
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

        for mr in listed + explicit {
            guard mr.state == "opened", mr.webURL.isGitLabMergeRequest(host: host, iid: mr.iid) else { continue }
            let id = Item.ID(projectID: mr.projectID, iid: mr.iid)
            var item = Item(
                id: id, title: mr.title, url: mr.webURL, draftCount: candidates[id]?.draftCount ?? 0,
                draftFromTodo: candidates[id]?.draftFromTodo ?? false, mergeRequest: mr, isAuthored: mr.author.id == user.id
            )
            item.drafts = candidates[id]?.drafts ?? []
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

        var results: [Item] = []
        var failed = owned == nil || assigned == nil
        let ordered = candidates.values.sorted { ($0.id.projectID, $0.id.iid) < ($1.id.projectID, $1.id.iid) }
        // Limit simultaneous glab processes while still checking the entire list.
        for start in stride(from: 0, to: ordered.count, by: 4) {
            guard isCurrent(account) else { return }
            let batch = ordered[start..<min(start + 4, ordered.count)]
            await withTaskGroup(of: (Item, Bool, ReReviewFeedback?).self) { group in
                for item in batch {
                    let approvedHead = approvedHeads[item.id]
                    let failedHead = failedApprovalHeads[item.id]
                    let autoApproves = item.mergeRequest.map {
                        autoApproveApplies(to: $0, host: host, username: account.username)
                    } ?? false
                    group.addTask { [glab] in
                        var updated = item
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
                        updated.autoApproveReady = false
                        if drafts?.isEmpty == true, !item.isAuthored,
                           let request = item.mergeRequest, request.author.id != user.id, request.draft != true,
                           let head = request.sha, head != approvedHead,
                           ReviewVerdictStore.verdict(
                               host: host, projectID: request.projectID, iid: request.iid, in: verdictDirectory
                           )?.headSHA == head {
                            let check = await Self.approvalCheck(request, user: user, host: host, glab: glab)
                            let currentVerdict = check.discussions.map {
                                ReviewVerdictStore.verdict(host: host, projectID: request.projectID, iid: request.iid, in: verdictDirectory)?
                                    .approves(head: head, discussions: $0, reviewerID: user.id,
                                              publishedDrafts: ReviewVerdictStore.seenDrafts(
                                                  host: host, projectID: request.projectID, iid: request.iid, in: verdictDirectory
                                              )) == true
                            } ?? false
                            // After GitLab refused an automatic approval, offer the button instead of retrying.
                            let automatic = autoApproves && head != failedHead
                            updated.canApprove = currentVerdict && check.ownReady && !automatic
                            updated.autoApproveReady = currentVerdict && check.ownReady && check.allResolved && automatic
                        }
                        let hasReplies = (drafts ?? item.drafts).contains { $0.discussionID != nil }
                        let discussions = if item.authoredRequest != nil || hasReplies {
                            try? await glab.fetchMergeRequestDiscussions(
                                projectID: item.id.projectID, iid: item.id.iid, host: host
                            )
                        } else { nil as [GitLabMergeRequestDiscussion]? }
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
                        return (updated, draftCount != nil && (item.authoredRequest == nil || discussions != nil), feedback)
                    }
                }
                for await (var item, success, feedback) in group {
                    let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: item.id.projectID, iid: item.id.iid)
                    if item.isAuthored, agentWorks.contains(work), let settings {
                        let run = FollowUpVerificationStore.latestRun(for: work, username: user.username, settings: settings)
                        if let run { FollowUpVerificationStore.register(run, pushAllowed: settings.automation.allowFollowUpPush, in: followUpDirectory) }
                        let receipt = FollowUpVerificationStore.receipt(work: work, username: user.username, in: followUpDirectory)
                        item.awaitingRemoteVerification = !item.drafts.isEmpty && settings.automation.publishesAutomatically(any: item.drafts) && (!settings.automation.allowFollowUpPush || run?.followUpPushAllowed == false || item.drafts.contains { draft in
                            guard let run, let receipt, let request = item.mergeRequest else { return true }
                            return !receipt.covers(draft, request: request, host: host, user: user, runID: run.id)
                        })
                    }
                    if success, let feedback, let request = item.authoredRequest {
                        await requestReReviewsIfReady(for: request, feedback: feedback, draftCount: item.draftCount,
                                                      account: account, user: user)
                    }
                    if item.isAuthored {
                        let receipts = settings?.reReviewReceipts.filter {
                            $0.key.host == host && $0.key.authorID == user.id && $0.key.projectID == item.id.projectID
                                && $0.key.iid == item.id.iid
                        }.values
                        item.reReviewUnconfirmed = receipts?.contains { $0.unconfirmed } ?? false
                        item.reReviewRequested = receipts?.contains { $0.requested == true } ?? false
                    }
                    results.append(item)
                    failed = failed || !success
                }
            }
        }
        guard isCurrent(account) else { return }
        for index in results.indices {
            let id = results[index].id
            guard let published = publishedDrafts[id] else { continue }
            // Suppress only exact drafts already sent; preserve newly added/edited ones.
            results[index].drafts.removeAll { published.contains($0) }
            results[index].draftCount = results[index].drafts.count
        }
        items = Item.ordered(results.filter(\.needsAttention))
        hasError = failed || explicitFetchFailed
        hasCurrentOwnListing = owned != nil
        let openIDs = Set((listed + explicit).filter { $0.state == "opened" }.map {
            Item.ID(projectID: $0.projectID, iid: $0.iid)
        })
        for item in results where openIDs.contains(item.id) && item.mergeRequest?.state == "opened" {
            retainedCatalog[item.id] = item
        }
        for request in recordedReviews {
            let id = Item.ID(projectID: request.projectID, iid: request.iid)
            retainedCatalog[id] = Item(id: id, title: request.title, url: request.webURL, mergeRequest: request)
        }
        // Retention belongs only to the read-only catalog. Stale rows do not become
        // new publication, approval or re-review action candidates.
        openItems = Item.ordered(Array(retainedCatalog.values))
        await publishSettledDrafts(agentWorks: agentWorks, account: account)
        for item in results where item.autoApproveReady {
            guard let request = item.mergeRequest, let head = request.sha else { continue }
            if await performApproval(of: item.id, head: head, requireAllResolved: true) {
                onAutoApproved?(request)
            }
        }
        if let reportDirectory, owned != nil || assigned != nil {
            CodexDesktopRelay.publishMergeRequestStatus(requests: openItems.filter { listedIDs.contains($0.id) },
                                                      complete: owned != nil && assigned != nil && !failed && !explicitFetchFailed,
                                                      in: reportDirectory)
        }
    }

    // MARK: - Ready for your OK

    private func assistantWorks(username: String) -> Set<AssistantAutomationRunner.MergeRequestWork> {
        guard let settings else { return [] }
        let handoffs = settings.assistantHandoffs.filter { $0.key.username == username }.map(\.key.work)
        let chats = settings.assistantChats.keys.filter { $0.username == username }.map(\.work)
        return Set(handoffs).union(chats)
    }

    func autoApproveApplies(to request: GitLabMergeRequest, host: String, username: String) -> Bool {
        guard let settings, settings.automation.autoApproveEnabled,
              settings.automation.scope.permits(request, host: host, username: username) else { return false }
        let target = MRAutomationScope.Target(host: host, username: username, projectID: request.projectID, iid: request.iid)
        return !settings.autoApproveOptOuts.contains(target)
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

    /// With "Publish comments without confirmation" on, publishes assistant drafts once they are
    /// unchanged across two polls, so a draft the assistant is still writing is never sent.
    private func publishSettledDrafts(
        agentWorks: Set<AssistantAutomationRunner.MergeRequestWork>, account: Account
    ) async {
        let earlier = previousDrafts
        previousDrafts = Dictionary(uniqueKeysWithValues: items.filter { !$0.drafts.isEmpty }.map { ($0.id, $0.drafts) })
        guard let settings, settings.automation.publishDraftsWithoutConfirmation || settings.automation.publishAIRepliesWithoutConfirmation else { return }
        for item in items where !item.drafts.isEmpty && earlier[item.id] == item.drafts {
            let work = AssistantAutomationRunner.MergeRequestWork(host: account.host, projectID: item.id.projectID, iid: item.id.iid)
            guard agentWorks.contains(work), let request = item.mergeRequest,
                  settings.automation.scope.permits(request, host: account.host, username: account.username)
            else { continue }
            if settings.automation.publishDraftsWithoutConfirmation {
                guard item.drafts.contains(where: AICommentAssessmentStore.safeForAutomaticPublication) else { continue }
                await publishDrafts(of: item.id, automatic: true)
            } else {
                await publishAIReplies(of: item, account: account)
            }
        }
    }

    /// Cheap filters and reads do not disable the manual action or pretend a publication started.
    private func publishAIReplies(of item: Item, account: Account) async {
        guard let user, !isConfirming(item.id) else { return }
        let id = item.id
        let candidates = item.drafts.filter {
            $0.discussionID != nil && AICommentAssessmentStore.safeForAutomaticPublication($0)
        }
        guard !candidates.isEmpty else { return }
        let discussions: [GitLabMergeRequestDiscussion]
        var duoIDs: Set<Int> = []
        do {
            discussions = try await glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
            let possibleDuo = Set(discussions.flatMap(\.notes).compactMap { note in
                note.author?.username?.lowercased() == "gitlabduo" ? note.author?.id : nil
            })
            for authorID in possibleDuo {
                if (try? await glab.isGitLabDuo(userID: authorID, host: account.host)) == true { duoIDs.insert(authorID) }
            }
        } catch {
            Log.monitor.error("Could not check AI reply eligibility: \(String(describing: error), privacy: .private)")
            return
        }
        func qualifies(_ draft: GitLabDraftNote, in threads: [GitLabMergeRequestDiscussion]) -> Bool {
            AICommentAssessmentStore.eligible(draft, discussions: threads, userID: user.id, duoUserIDs: duoIDs,
                host: account.host, projectID: id.projectID, iid: id.iid, in: aiAssessmentDirectory)
        }
        let eligible = candidates.filter { qualifies($0, in: discussions) }
        guard !eligible.isEmpty, isCurrent(account), !isConfirming(id) else { return }
        let generation = accountGeneration
        confirmationStates[id] = .publishing
        defer { if generation == accountGeneration, confirmationStates[id] == .publishing { confirmationStates[id] = nil } }
        var published = false
        var attemptedPublish = false
        do {
            for draft in eligible {
                guard isCurrent(account), let settings, settings.automation.publishAIRepliesWithoutConfirmation,
                      let request = item.mergeRequest,
                      settings.automation.scope.permits(request, host: account.host, username: account.username)
                else { break }
                let liveDiscussions = try await glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
                let latest = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
                guard latest.contains(draft), let draftID = draft.id, qualifies(draft, in: liveDiscussions),
                      isCurrent(account), settings.automation.publishAIRepliesWithoutConfirmation,
                      settings.automation.scope.permits(request, host: account.host, username: account.username) else { continue }
                guard await permitsAutomaticAuthorPublication(draft, id: id, account: account),
                      isCurrent(account), settings.automation.publishAIRepliesWithoutConfirmation,
                      settings.automation.scope.permits(request, host: account.host, username: account.username) else { continue }
                attemptedPublish = true
                try await glab.publishDraftNote(projectID: id.projectID, iid: id.iid, draftID: draftID, host: account.host)
                attemptedPublish = false
                guard isCurrent(account) else { return }
                published = true
                publishedDrafts[id, default: []].append(draft)
                updateItem(id) {
                    $0.drafts.removeAll { $0 == draft }
                    $0.draftCount = $0.drafts.count
                }
            }
        } catch {
            if attemptedPublish, isCurrent(account) { confirmationStates[id] = .failed }
            Log.monitor.error("Could not publish AI reply: \(String(describing: error), privacy: .private)")
        }
        if published, isCurrent(account) {
            previousDrafts[id] = nil
            await refreshReReviewAfterPublication(id, account: account, user: user)
        }
    }

    func publishDrafts(of id: Item.ID, automatic: Bool = false) async {
        guard let account, isCurrent(account), let user,
              let expected = items.first(where: { $0.id == id })?.drafts, !expected.isEmpty,
              !isConfirming(id) else { return }
        let generation = accountGeneration
        confirmationStates[id] = .publishing
        defer { if generation == accountGeneration, confirmationStates[id] == .publishing { confirmationStates[id] = nil } }
        var publishedAny = false
        var attemptedPublish = false
        do {
            let current = try await glab.fetchOwnDraftNotes(
                projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id
            )
            guard isCurrent(account) else { return }
            guard current == expected else {
                updateItem(id) {
                    $0.drafts = current
                    $0.draftCount = current.count
                }
                confirmationStates[id] = automatic ? nil : .changed
                return
            }
            if automatic {
                guard let settings, settings.automation.publishDraftsWithoutConfirmation,
                      let request = openItems.first(where: { $0.id == id })?.mergeRequest,
                      settings.automation.scope.permits(request, host: account.host, username: account.username) else {
                    confirmationStates[id] = nil
                    return
                }
            }
            if automatic {
                // Never include a new, unseen draft saved after the snapshot was checked.
                for draft in current {
                    let latest = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
                    guard latest.contains(draft), let draftID = draft.id, isCurrent(account),
                          let settings, settings.automation.publishDraftsWithoutConfirmation,
                          let request = openItems.first(where: { $0.id == id })?.mergeRequest,
                          settings.automation.scope.permits(request, host: account.host, username: account.username),
                          AICommentAssessmentStore.safeForAutomaticPublication(draft) else { continue }
                    guard await permitsAutomaticAuthorPublication(draft, id: id, account: account),
                          isCurrent(account), settings.automation.publishDraftsWithoutConfirmation,
                          settings.automation.scope.permits(request, host: account.host, username: account.username) else { continue }
                    attemptedPublish = true
                    try await glab.publishDraftNote(projectID: id.projectID, iid: id.iid, draftID: draftID, host: account.host)
                    attemptedPublish = false
                    guard isCurrent(account) else { return }
                    publishedAny = true
                    publishedDrafts[id, default: []].append(draft)
                    updateItem(id) { $0.drafts.removeAll { $0 == draft }; $0.draftCount = $0.drafts.count }
                }
                let remaining = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id)
                guard isCurrent(account) else { return }
                updateItem(id) { $0.drafts = remaining; $0.draftCount = remaining.count }
            } else {
                attemptedPublish = true
                try await glab.publishDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host)
                attemptedPublish = false
                guard isCurrent(account) else { return }
                publishedAny = true
                publishedDrafts[id, default: []].append(contentsOf: current)
                updateItem(id) { $0.drafts = []; $0.draftCount = 0 }
            }
            guard publishedAny else { return }
            confirmationStates[id] = nil
        } catch {
            if isCurrent(account) { confirmationStates[id] = !automatic || attemptedPublish ? .failed : nil }
            Log.monitor.error("Could not publish drafts: \(String(describing: error), privacy: .private)")
        }
        // A later read or PUT can fail after an earlier draft was successfully published.
        if publishedAny, isCurrent(account) {
            previousDrafts[id] = nil
            await refreshReReviewAfterPublication(id, account: account, user: user)
        }
    }

    /// Review drafts on others' MRs stay read-only. Author replies need evidence for this run,
    /// the exact draft body and actual files on the current remote source commit.
    private func permitsAutomaticAuthorPublication(_ draft: GitLabDraftNote, id: Item.ID, account: Account) async -> Bool {
        guard let user, let request = openItems.first(where: { $0.id == id })?.mergeRequest else { return false }
        if request.author.id != user.id { return true }
        func blocked() -> Bool {
            updateItem(id) { $0.awaitingRemoteVerification = true }
            return false
        }
        guard let settings, settings.automation.allowFollowUpPush else { return blocked() }
        let work = AssistantAutomationRunner.MergeRequestWork(host: account.host, projectID: id.projectID, iid: id.iid)
        guard let run = FollowUpVerificationStore.latestRun(for: work, username: user.username, settings: settings),
              run.followUpPushAllowed == true,
              let receipt = FollowUpVerificationStore.receipt(work: work, username: user.username, in: followUpDirectory),
              receipt.covers(draft, request: request, host: account.host, user: user, runID: run.id) else { return blocked() }
        do {
            let live = try await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
            guard receipt.covers(draft, request: live, host: account.host, user: user, runID: run.id) else { return blocked() }
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
            let (currentUser, currentMR, currentSource, freshDrafts) = try await (freshUser, freshMR, sourceHead, currentDrafts)
            guard currentUser == user, currentSource == receipt.headSHA, freshDrafts.contains(draft),
                  receipt.covers(draft, request: currentMR, host: account.host, user: currentUser, runID: run.id),
                  isCurrent(account), settings.automation.allowFollowUpPush,
                  FollowUpVerificationStore.latestRun(for: work, username: user.username, settings: settings)?.id == run.id,
                  settings.automation.scope.permits(currentMR, host: account.host, username: account.username) else { return blocked() }
            return true
        } catch {
            Log.monitor.error("Author follow-up is awaiting remote verification: \(String(describing: error), privacy: .private)")
            return blocked()
        }
    }

    func approve(_ id: Item.ID) async {
        guard let item = items.first(where: { $0.id == id }), item.canApprove,
              let head = item.mergeRequest?.sha else { return }
        _ = await performApproval(of: id, head: head, requireAllResolved: false)
    }

    /// Re-checks the live MR, approves at `head` and reports whether GitLab confirmed it.
    private func performApproval(of id: Item.ID, head: String, requireAllResolved: Bool) async -> Bool {
        guard let account, isCurrent(account), let user, !isConfirming(id) else { return false }
        confirmationStates[id] = .approving
        do {
            let host = account.host
            async let fresh = glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: host)
            async let pending = glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: host, userID: user.id)
            async let threads = glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: host)
            let (current, drafts, discussions) = try await (fresh, pending, threads)
            guard isCurrent(account) else {
                confirmationStates[id] = nil
                return false
            }
            let verdict = ReviewVerdictStore.verdict(host: host, projectID: id.projectID, iid: id.iid, in: verdictDirectory)
            guard current.state == "opened", current.draft != true, current.sha == head, current.author.id != user.id,
                  drafts.isEmpty,
                  verdict?.approves(head: head, discussions: discussions, reviewerID: user.id,
                                    publishedDrafts: ReviewVerdictStore.seenDrafts(
                                        host: host, projectID: id.projectID, iid: id.iid, in: verdictDirectory
                                    )) == true,
                  !requireAllResolved || (Self.allResolved(discussions)
                      && autoApproveApplies(to: current, host: host, username: account.username))
            else {
                updateItem(id) { $0.canApprove = false }
                confirmationStates[id] = requireAllResolved ? nil : .changed
                return false
            }
            try await glab.approveMergeRequest(projectID: id.projectID, iid: id.iid, headSHA: head, host: host, userID: user.id)
            approvedHeads[id] = head
            failedApprovalHeads[id] = nil
            updateItem(id) { $0.canApprove = false }
            confirmationStates[id] = nil
            return true
        } catch {
            confirmationStates[id] = .failed
            if requireAllResolved { failedApprovalHeads[id] = head }
            Log.monitor.error("Could not approve merge request: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    private func isConfirming(_ id: Item.ID) -> Bool {
        confirmationStates[id] == .publishing || confirmationStates[id] == .approving
    }

    private func updateItem(_ id: Item.ID, _ change: (inout Item) -> Void) {
        guard var item = items.first(where: { $0.id == id }) ?? openItems.first(where: { $0.id == id }) else { return }
        change(&item)
        if item.drafts.isEmpty { item.awaitingRemoteVerification = false }
        else if item.isAuthored, let settings, let account, let user, let request = item.mergeRequest {
            let work = AssistantAutomationRunner.MergeRequestWork(host: account.host, projectID: id.projectID, iid: id.iid)
            if assistantWorks(username: user.username).contains(work) {
                let run = FollowUpVerificationStore.latestRun(for: work, username: user.username, settings: settings)
                let receipt = FollowUpVerificationStore.receipt(work: work, username: user.username, in: followUpDirectory)
                // The warning only matters when something would otherwise be published without you.
                item.awaitingRemoteVerification = settings.automation.publishesAutomatically(any: item.drafts) && (
                    item.awaitingRemoteVerification || !settings.automation.allowFollowUpPush
                        || run?.followUpPushAllowed == false || item.drafts.contains { draft in
                            guard let run, let receipt else { return true }
                            return !receipt.covers(draft, request: request, host: account.host, user: user, runID: run.id)
                        })
            }
        }
        items.removeAll { $0.id == id }
        if item.needsAttention { items.append(item) }
        if let index = openItems.firstIndex(where: { $0.id == id }) { openItems[index] = item }
        items = Item.ordered(items)
        openItems = Item.ordered(openItems)
    }

    /// A short, visible-only check notices publication in the browser without a full MR poll.
    func refreshPendingDrafts() async {
        guard !isLoading, !isRefreshingDrafts, let account, isCurrent(account), let user else { return }
        isRefreshingDrafts = true
        defer { isRefreshingDrafts = false }
        for item in items where !item.drafts.isEmpty && !isConfirming(item.id) {
            guard var current = try? await glab.fetchOwnDraftNotes(
                projectID: item.id.projectID, iid: item.id.iid, host: account.host, userID: user.id
            ), isCurrent(account), !isLoading, !isConfirming(item.id),
                  items.first(where: { $0.id == item.id })?.drafts == item.drafts else { continue }
            current.removeAll { publishedDrafts[item.id]?.contains($0) == true }
            updateItem(item.id) { $0.drafts = current; $0.draftCount = current.count }
            if current != item.drafts {
                confirmationStates[item.id] = nil
                previousDrafts[item.id] = nil
                await refreshReReviewAfterPublication(item.id, account: account, user: user)
            }
        }
    }

    private func refreshReReviewAfterPublication(_ id: Item.ID, account: Account, user: GitLabAuthenticatedUser) async {
        guard openItems.first(where: { $0.id == id })?.isAuthored == true,
              let request = try? await glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host),
              request.author.id == user.id,
              let drafts = try? await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: user.id),
              let discussions = try? await glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host),
              isCurrent(account) else { return }
        await requestReReviewsIfReady(for: request, feedback: ReReviewFeedback(discussions: discussions, authorID: user.id),
                                      draftCount: drafts.count, account: account, user: user)
    }

    private func requestReReviewsIfReady(
        for request: GitLabMergeRequest, feedback: ReReviewFeedback, draftCount: Int,
        account: Account, user: GitLabAuthenticatedUser
    ) async {
        guard let settings, settings.automation.autoReReviewEnabled,
              isCurrent(account),
              settings.automation.scope.permits(request, host: account.host, username: account.username) else { return }
        let host = account.host
        let target = MRAutomationScope.Target(host: host, username: account.username, projectID: request.projectID, iid: request.iid)
        guard reReviewsInProgress.insert(target).inserted else { return }
        defer { reReviewsInProgress.remove(target) }
        let baseline = settings.reReviewDraftBaselines[target]
        if draftCount > 0 {
            if baseline == nil {
                settings.reReviewDraftBaselines[target] = feedback.latestPublishedReplyID
                settings.save()
            }
            return
        }
        let observedPublication = baseline.map { feedback.latestPublishedReplyID > $0 } == true
        if baseline != nil, !observedPublication {
            settings.reReviewDraftBaselines.removeValue(forKey: target)
            settings.save()
        }
        guard request.draft == false, let head = request.sha, !feedback.hasUnansweredFeedback else { return }
        let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: request.projectID, iid: request.iid)
        let usedAssistant = settings.assistantHandoffs.contains {
            $0.key.work == work && $0.key.username == user.username
                && ($0.relayComplete == true || $0.openedAt != nil)
                && !feedback.addressedNotes.isDisjoint(with: $0.feedbackNoteIDs ?? [])
        }
        guard usedAssistant || observedPublication else { return }
        var finished = true
        for (reviewerID, noteID) in feedback.addressedByReviewer.sorted(by: { $0.key < $1.key }) {
            let key = ReReviewReceipt.Key(host: host, authorID: user.id, projectID: request.projectID,
                                          iid: request.iid, reviewerID: reviewerID)
            guard (settings.reReviewReceipts[key]?.noteID ?? 0) < noteID else { continue }
            do {
                guard let username = try await glab.activeHumanReviewerUsername(userID: reviewerID, host: host) else {
                    guard isCurrent(account), settings.automation.autoReReviewEnabled else { return }
                    settings.reReviewReceipts[key] = ReReviewReceipt(noteID: noteID)
                    settings.save()
                    continue
                }
                let reviewers = try await glab.fetchMergeRequestReviewers(projectID: request.projectID, iid: request.iid, host: host)
                let reviewer = reviewers.first { $0.user.id == reviewerID }
                async let fresh = glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
                async let discussions = glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
                async let drafts = glab.fetchOwnDraftNoteCount(projectID: request.projectID, iid: request.iid, host: host, userID: user.id)
                let (current, liveDiscussions, draftCount) = try await (fresh, discussions, drafts)
                let currentFeedback = ReReviewFeedback(discussions: liveDiscussions, authorID: user.id)
                guard draftCount == 0, current.state == "opened", current.draft == false, current.sha == head,
                      current.author.id == user.id, current.webURL.isGitLabMergeRequest(host: host, iid: current.iid),
                      !currentFeedback.hasUnansweredFeedback, currentFeedback.addressedByReviewer == feedback.addressedByReviewer,
                      try await glab.fetchAuthenticatedUser(host: host, expectedUsername: account.username) == user,
                      isCurrent(account), settings.automation.autoReReviewEnabled,
                      settings.automation.scope.permits(current, host: host, username: account.username) else { return }
                if reviewer?.state == "unreviewed" || reviewer?.state == "review_started" {
                    settings.reReviewReceipts[key] = ReReviewReceipt(noteID: noteID, requested: true)
                    settings.save()
                    continue
                }

                // Recheck after the reads, then reserve before the notification-producing request.
                guard (settings.reReviewReceipts[key]?.noteID ?? 0) < noteID else { continue }
                settings.reReviewReceipts[key] = ReReviewReceipt(noteID: noteID, unconfirmed: true)
                settings.save()
                try await glab.requestReview(of: current, userID: reviewerID, username: username,
                                             alreadyAssigned: reviewer != nil, host: host)
                settings.reReviewReceipts[key]?.unconfirmed = false
                settings.reReviewReceipts[key]?.requested = true
                settings.save()
            } catch {
                finished = false
                Log.monitor.error("Could not confirm automatic re-review: \(String(describing: error), privacy: .private)")
            }
        }
        if observedPublication, finished {
            settings.reReviewDraftBaselines.removeValue(forKey: target)
            settings.save()
        }
    }
}
