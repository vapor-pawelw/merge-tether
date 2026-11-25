import Foundation

extension SettingsManager {
    struct CommentReviewProgress: Codable, Equatable {
        struct RegeneratedDraft: Codable, Hashable {
            let id: Int
            let authorID: Int
            let bodyDigest: String

            init?(_ draft: GitLabDraftNote) {
                guard let id = draft.id, id > 0, draft.authorID > 0, let body = draft.note else { return nil }
                self.id = id
                authorID = draft.authorID
                bodyDigest = AICommentAssessmentStore.digest(body)
            }
        }

        struct AutomaticPublication: Codable, Equatable {
            let userID: Int
            let requestContext: String
            let snapshot: CommentReviewSnapshot
            var publishedBodyDigests: [Int: String] = [:]

            init?(request: GitLabMergeRequest?, snapshot: CommentReviewSnapshot?, userID: Int) {
                guard let request, let snapshot, snapshot.covers(request), userID > 0 else { return nil }
                self.userID = userID
                requestContext = request.draftProofRecoveryContextFingerprint
                self.snapshot = snapshot
            }
        }

        var observedDraftIDs: Set<Int> = []
        var automaticallyPublishedDraftIDs: Set<Int> = []
        var automaticPublication: AutomaticPublication?
        var regeneratedDrafts: Set<RegeneratedDraft>?
    }

    func holdRegeneratedDraft(_ draft: GitLabDraftNote, for target: MRAutomationScope.Target) -> Bool {
        guard target.iid != nil, let held = CommentReviewProgress.RegeneratedDraft(draft) else { return false }
        pendingCommentReviews.insert(target)
        var progress = commentReviewProgress[target] ?? .init()
        progress.observedDraftIDs.insert(held.id)
        progress.automaticallyPublishedDraftIDs.remove(held.id)
        progress.automaticPublication = nil
        var regenerated = progress.regeneratedDrafts ?? []
        regenerated.insert(held)
        progress.regeneratedDrafts = regenerated
        commentReviewProgress[target] = progress
        return save() && persistenceDegraded.isEmpty
    }

    func holdsRegeneratedDraft(_ draft: GitLabDraftNote, for target: MRAutomationScope.Target) -> Bool {
        guard let held = CommentReviewProgress.RegeneratedDraft(draft) else { return false }
        return commentReviewProgress[target]?.regeneratedDrafts?.contains(held) == true
    }

    func commentReviewRevision(for target: MRAutomationScope.Target) -> UInt64 {
        commentReviewRevisions[target, default: 0]
    }

    func observeCommentReview(_ drafts: [GitLabDraftNote], for target: MRAutomationScope.Target, revision: UInt64) {
        guard !drafts.isEmpty, target.iid != nil, commentReviewRevision(for: target) == revision else { return }
        let inserted = pendingCommentReviews.insert(target).inserted
        let previous = commentReviewProgress[target]
        var progress = previous ?? .init()
        progress.observedDraftIDs.formUnion(drafts.compactMap(\.id))
        commentReviewProgress[target] = progress
        if inserted || progress != previous { save() }
    }

    func recordAutomaticCommentPublication(_ drafts: [GitLabDraftNote], for target: MRAutomationScope.Target,
                                           revision: UInt64? = nil, evidence: CommentReviewProgress.AutomaticPublication? = nil) {
        guard pendingCommentReviews.contains(target),
              revision == nil || revision == commentReviewRevision(for: target) else { return }
        let previous = commentReviewProgress[target]
        var progress = previous ?? .init()
        if let evidence {
            // Keep the context from before the first successful write, including across batches.
            if progress.automaticallyPublishedDraftIDs.isEmpty { progress.automaticPublication = evidence }
            if progress.automaticPublication?.userID == evidence.userID,
               progress.automaticPublication?.requestContext == evidence.requestContext {
                for draft in drafts {
                    guard let id = draft.id, let body = draft.note, draft.authorID == evidence.userID else { continue }
                    progress.automaticPublication?.publishedBodyDigests[id] = AICommentAssessmentStore.digest(body)
                }
            }
        }
        progress.automaticallyPublishedDraftIDs.formUnion(drafts.compactMap(\.id))
        commentReviewProgress[target] = progress
        if progress != previous { save() }
    }

    func automaticCommentReviewCompletion(for target: MRAutomationScope.Target) -> CommentReviewProgress.AutomaticPublication? {
        guard canAutomaticallyFinishCommentReview(for: target), let progress = commentReviewProgress[target],
              let evidence = progress.automaticPublication,
              progress.observedDraftIDs.isSubset(of: Set(evidence.publishedBodyDigests.keys)) else { return nil }
        return evidence
    }

    func invalidateAutomaticCommentReviewCompletion(for target: MRAutomationScope.Target) {
        guard commentReviewProgress[target]?.automaticPublication != nil else { return }
        commentReviewProgress[target]?.automaticPublication = nil
        save()
    }

    func canAutomaticallyFinishCommentReview(for target: MRAutomationScope.Target) -> Bool {
        guard pendingCommentReviews.contains(target), let progress = commentReviewProgress[target],
              !progress.observedDraftIDs.isEmpty else { return false }
        return progress.observedDraftIDs.isSubset(of: progress.automaticallyPublishedDraftIDs)
    }

    func beginCommentReview(for target: MRAutomationScope.Target) {
        guard target.iid != nil, pendingCommentReviews.insert(target).inserted else { return }
        save()
    }

    func completeCommentReview(for target: MRAutomationScope.Target) {
        guard pendingCommentReviews.remove(target) != nil else { return }
        commentReviewProgress.removeValue(forKey: target)
        commentReviewRevisions[target, default: 0] &+= 1
        save()
    }

    func storedActionPreference(_ action: MRAutomaticAction, for target: MRAutomationScope.Target) -> MRAutomationPreference {
        if action == .approval, let independent = independentApprovalPreferences[target] { return independent }
        let optedOut = switch action {
        case .commentPublication: autoPublishOptOuts.contains(target)
        case .merge: autoMergeOptOuts.contains(target)
        case .approval: autoApproveOptOuts.contains(target)
        }
        if optedOut { return .off }
        let optedIn = action == .merge ? autoMergeOptIns.contains(target) : automaticActionOptIns[action]?.contains(target) == true
        return optedIn ? .on : .default
    }

    func actionPreference(_ action: MRAutomaticAction, for target: MRAutomationScope.Target) -> MRAutomationPreference {
        if automation.scope[target] == .paused { return .off }
        if action == .approval, let independent = independentApprovalPreferences[target] { return independent }
        if automation.scope.followsActionDefaults(for: target) { return .default }
        return storedActionPreference(action, for: target)
    }

    func autoMergePreference(for target: MRAutomationScope.Target) -> MRAutomationPreference {
        actionPreference(.merge, for: target)
    }

    func setAutoMergePreference(_ preference: MRAutomationPreference, for target: MRAutomationScope.Target) {
        setActionPreference(preference, for: .merge, target: target)
    }

    func setActionPreference(_ preference: MRAutomationPreference, for action: MRAutomaticAction, target: MRAutomationScope.Target) {
        guard target.iid != nil else { return }
        if action == .approval, independentApprovalPreferences[target] != nil {
            independentApprovalPreferences[target] = preference == .default ? nil : preference
        }
        func update(_ targets: inout Set<MRAutomationScope.Target>, when selected: MRAutomationPreference) {
            if preference == selected { targets.insert(target) }
            else { targets.remove(target) }
        }
        switch action {
        case .commentPublication: update(&autoPublishOptOuts, when: .off)
        case .approval: update(&autoApproveOptOuts, when: .off)
        case .merge:
            update(&autoMergeOptOuts, when: .off)
            update(&autoMergeOptIns, when: .on)
            return
        }
        var optedIn = automaticActionOptIns[action] ?? []
        update(&optedIn, when: .on)
        automaticActionOptIns[action] = optedIn.isEmpty ? nil : optedIn
    }

    func hasAutoMergeOptIn(host: String?, username: String?) -> Bool {
        guard let host, let username else { return false }
        return autoMergeOptIns.contains {
            $0.host == host && $0.username == username && $0.iid != nil && actionPreference(.merge, for: $0) == .on
        }
    }

    func hasAutomaticActionOptIn(host: String? = nil, username: String? = nil) -> Bool {
        MRAutomaticAction.allCases.contains { action in
            var optedIn = action == .merge ? autoMergeOptIns : automaticActionOptIns[action] ?? []
            if action == .approval { optedIn.formUnion(independentApprovalPreferences.keys) }
            return optedIn.contains { target in
                target.iid != nil && (host == nil || host == target.host) && (username == nil || username == target.username)
                    && actionPreference(action, for: target) == .on
            }
        }
    }

    func hasConfiguredAutomation(for target: MRAutomationScope.Target) -> Bool {
        configuredAutomation.hasEnabledAutomation || (configuredAutomation.hasAutomaticPublicActionConsent
            && MRAutomaticAction.allCases.contains { actionPreference($0, for: target) == .on })
    }

    /// Action preference only. Automatic writes also require consent, scope and fresh evidence.
    func actionIsAutomatic(_ action: MRAutomaticAction, for target: MRAutomationScope.Target) -> Bool {
        actionPreference(action, for: target) != .off
    }

    func setActionAutomatic(_ action: MRAutomaticAction, enabled: Bool, for target: MRAutomationScope.Target) {
        setActionPreference(enabled ? .default : .off, for: action, target: target)
    }

    func publicationPolicy(for target: MRAutomationScope.Target) -> AutomaticPublicationPolicy {
        let mode = automation.publicationMode
        let effectiveMode: AutomationPublicationMode = switch actionPreference(.commentPublication, for: target) {
        case .default: mode
        case .on: mode == .manual ? .aiReplies : mode
        case .off: .manual
        }
        return .init(mode: effectiveMode, restrictions: automation.publicationRestrictions,
                     aiCommentCriteriaOverride: automation.aiCommentCriteriaOverride)
    }

    /// A pending audit affects automatic execution for this account and MR until its reads recover.
    var effectiveAutomationScope: MRAutomationScope {
        assistantHandoffs.reduce(into: automation.scope) { scope, handoff in
            if handoff.execution?.pendingWorkerAudit != nil {
                scope[handoff.key.automationTarget] = .paused
            }
        }
    }

    /// Policy admission only. Action executors retain their current fresh evidence checks.
    /// Presentation passes `ignoringGlobalSuspension` so the killswitch does not change how MRs look.
    func permitsAutomaticAction(_ action: MRAutomaticAction, for request: GitLabMergeRequest,
                                target: MRAutomationScope.Target, ignoringGlobalSuspension: Bool = false) -> Bool {
        let automation = ignoringGlobalSuspension ? configuredAutomation : automation
        guard automaticActionsAllowed, automation.hasAutomaticPublicActionConsent,
              effectiveAutomationScope[target] != .paused else { return false }
        if action != .commentPublication, pendingCommentReviews.contains(target) { return false }
        guard request.projectID == target.projectID, request.iid == target.iid,
              request.webURL.isGitLabMergeRequest(host: target.host, iid: request.iid),
              actionIsAutomatic(action, for: target),
              automation.scope.permits(request, host: target.host, username: target.username) else { return false }
        return switch action {
        case .commentPublication: publicationPolicy(for: target).mode != .manual
        case .merge:
            request.author.username == target.username && request.draft == false
                && request.detailedMergeStatus != "draft_status"
                && automation.permitsAutoMerge(project: request.webURL.gitLabProjectPath,
                    optedIn: autoMergePreference(for: target) == .on)
        case .approval: automation.autoApproveEnabled || actionPreference(.approval, for: target) == .on
        }
    }
}
