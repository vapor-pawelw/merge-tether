import Foundation

/// Stable GitLab identity; the label is presentation only.
struct PublicationIdentity: Codable, Equatable, Sendable, Identifiable {
    let host: String
    let entityID: Int
    let label: String
    var id: String { "\(host)/\(entityID)" }
}

/// Conditional publication uses these restrictions; all mode ignores them. Empty lists add no condition.
struct AutomaticPublicationRestrictions: Codable, Equatable, Sendable {
    var repositories: [PublicationIdentity] = []
    var mergeRequestAuthors: [PublicationIdentity] = []
    var sourceCommentAuthors: [PublicationIdentity] = []
    var requireAI = false
    var allowBotReplies = false

    var hasIdentityConditions: Bool {
        !repositories.isEmpty || !mergeRequestAuthors.isEmpty || !sourceCommentAuthors.isEmpty
    }
    var hasConditions: Bool { requireAI || allowBotReplies || hasIdentityConditions }

    static func defaults(for preset: AutomationPreset?) -> Self {
        .init(requireAI: preset == .full || preset == .checkpoints || preset == .trusted,
              allowBotReplies: preset == .full || preset == .trusted)
    }
}

extension AutomaticPublicationRestrictions {
    private enum CodingKeys: String, CodingKey {
        case repositories, mergeRequestAuthors, sourceCommentAuthors, requireAI, allowBotReplies
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(repositories: try values.decodeIfPresent([PublicationIdentity].self, forKey: .repositories) ?? [],
                  mergeRequestAuthors: try values.decodeIfPresent([PublicationIdentity].self, forKey: .mergeRequestAuthors) ?? [],
                  sourceCommentAuthors: try values.decodeIfPresent([PublicationIdentity].self, forKey: .sourceCommentAuthors) ?? [],
                  requireAI: try values.decodeIfPresent(Bool.self, forKey: .requireAI) ?? false,
                  allowBotReplies: try values.decodeIfPresent(Bool.self, forKey: .allowBotReplies) ?? false)
    }
}

struct AutomaticPublicationPolicy: Equatable, Sendable {
    let mode: AutomationPublicationMode
    let restrictions: AutomaticPublicationRestrictions
    var aiCommentCriteriaOverride: String? = nil
    var treatAssignedMergeRequestsAsOwn = true

    func allows(_ draft: GitLabDraftNote, request: GitLabMergeRequest,
                discussions: [GitLabMergeRequestDiscussion]?, userID: Int, host: String,
                aiNoteIDs: Set<Int>, botNoteIDs: Set<Int> = []) -> Bool {
        guard couldAllow(draft, request: request, userID: userID, host: host) else { return false }
        if let discussionID = draft.discussionID,
           let discussion = discussions?.first(where: { $0.id == discussionID }) {
            guard !discussion.isResolvedForReview else { return false }
            let coAssignees = Set((request.assignees ?? []).map(\.id)).subtracting([userID])
            let body = DuplicateReplyDrafts.normalized(draft.note)
            if !body.isEmpty, discussion.notes.contains(where: { note in
                note.system != true && note.author.map { coAssignees.contains($0.id) } == true
                    && DuplicateReplyDrafts.normalized(note.body) == body
            }) { return false }
        }
        guard requiresSources || request.isOwned(by: userID, includingAssignee: treatAssignedMergeRequestsAsOwn) else { return true }
        guard let sources = Self.sourceNotes(for: draft, discussions: discussions, userID: userID),
              !sources.isEmpty else { return false }
        if mode == .all { return true }
        return sources.allSatisfy { note in
            guard let authorID = note.author?.id, let noteID = note.id else { return false }
            return matches(restrictions.sourceCommentAuthors, host: host, id: authorID)
                && (!(requiresAI || allowsBotReplies)
                    || (requiresAI && aiNoteIDs.contains(noteID))
                    || (allowsBotReplies && botNoteIDs.contains(noteID)))
        }
    }

    /// A cheap necessary-condition check for proof warnings. It can prove that
    /// a draft is excluded without guessing missing discussion/AI evidence.
    func couldAllow(_ draft: GitLabDraftNote, request: GitLabMergeRequest, userID: Int, host: String) -> Bool {
        guard mode != .manual, userID > 0, (draft.id ?? 0) > 0, draft.authorID == userID,
              Self.safeForAutomaticPublication(draft), request.projectID > 0, request.iid > 0,
              request.author.id > 0, request.webURL.isGitLabMergeRequest(host: host, iid: request.iid) else { return false }
        // A standalone status report becomes an unresolved self-discussion in GitLab.
        let owned = request.isOwned(by: userID, includingAssignee: treatAssignedMergeRequestsAsOwn)
        if (owned || request.author.id == userID), draft.discussionID?.isEmpty != false { return false }
        return covers(request, host: host) && (!requiresSources || draft.discussionID.map { !$0.isEmpty } == true)
    }

    func covers(_ request: GitLabMergeRequest, host: String) -> Bool {
        switch mode {
        case .manual: return false
        case .all: return true
        case .filtered where !restrictions.hasConditions: return false
        case .filtered, .aiReplies:
            return matches(restrictions.repositories, host: host, id: request.projectID)
                && matches(restrictions.mergeRequestAuthors, host: host, id: request.author.id)
        }
    }

    var requiresAI: Bool { mode == .aiReplies || (mode == .filtered && restrictions.requireAI) }
    var allowsBotReplies: Bool { mode != .manual && mode != .all && restrictions.allowBotReplies }
    private var requiresSources: Bool { requiresAI || allowsBotReplies || (mode != .all && !restrictions.sourceCommentAuthors.isEmpty) }

    private func matches(_ identities: [PublicationIdentity], host: String, id: Int) -> Bool {
        identities.isEmpty || identities.contains { $0.host == host && $0.entityID == id && id > 0 }
    }

    static func safeForAutomaticPublication(_ draft: GitLabDraftNote) -> Bool {
        draft.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && !DraftPublicationRisk.hasSideEffects(draft)
    }

    /// Sources are the incoming exchange after our last reply before the newest
    /// external comment. Our later replies do not erase that exchange.
    static func sourceNotes(for draft: GitLabDraftNote, discussions: [GitLabMergeRequestDiscussion]?,
                            userID: Int) -> [GitLabMergeRequestDiscussion.Note]? {
        guard let threadID = draft.discussionID, !threadID.isEmpty,
              let threads = discussions?.filter({ $0.id == threadID }), threads.count == 1 else { return nil }
        return sourceNotes(in: threads[0], userID: userID)
    }

    static func incomingDiscussionIDs(in discussions: [GitLabMergeRequestDiscussion]?, userID: Int) -> Set<String>? {
        guard let discussions, userID > 0 else { return nil }
        var seen: Set<String> = [], incoming: Set<String> = []
        for thread in discussions {
            guard let id = thread.id, !id.isEmpty, seen.insert(id).inserted,
                  let sources = sourceNotes(in: thread, userID: userID) else { return nil }
            if !sources.isEmpty { incoming.insert(id) }
        }
        return incoming
    }

    private static func sourceNotes(in thread: GitLabMergeRequestDiscussion, userID: Int) -> [GitLabMergeRequestDiscussion.Note]? {
        let notes = thread.notes.filter { $0.system != true }
        guard notes.allSatisfy({ ($0.id ?? 0) > 0 && ($0.author?.id ?? 0) > 0 }),
              Set(notes.compactMap(\.id)).count == notes.count else { return nil }
        let lastIncoming = notes.filter { $0.author?.id != userID }.compactMap(\.id).max() ?? 0
        let lastReply = notes.filter { $0.author?.id == userID && ($0.id ?? 0) < lastIncoming }
            .compactMap(\.id).max() ?? 0
        return notes.filter { $0.author?.id != userID && ($0.id ?? 0) > lastReply }
    }
}

enum AutomationCheckpoint: CaseIterable {
    case approval, followUpPush, pipelineOwnership, startNewReviews, ownThreadResolution, acceptedFeedbackResolution
}

extension AutomationSettings {
    var automaticPublicationPolicy: AutomaticPublicationPolicy {
        .init(mode: publicationMode, restrictions: publicationRestrictions, aiCommentCriteriaOverride: aiCommentCriteriaOverride)
    }
    var needsAIAssessment: Bool { automaticPublicationPolicy.requiresAI }
    var publishesAllComments: Bool { publicationMode == .all }
    var automaticAIReplies: Bool {
        switch publicationMode {
        case .all, .filtered: publicationRestrictions.requireAI
        case .aiReplies: true
        case .manual: false
        }
    }

    mutating func setPublishAllComments(_ enabled: Bool) {
        if enabled {
            publicationRestrictions.requireAI = automaticAIReplies
            publicationMode = .all
        } else { setConditionalPublication(aiReplies: automaticAIReplies) }
    }

    mutating func setAutomaticAIReplies(_ enabled: Bool) {
        let wasAll = publishesAllComments
        publicationRestrictions.requireAI = enabled
        if wasAll { publicationMode = .all }
        else { setConditionalPublication(aiReplies: enabled) }
    }

    mutating func publicationFiltersChanged() {
        if !publishesAllComments { setConditionalPublication(aiReplies: automaticAIReplies) }
    }

    private mutating func setConditionalPublication(aiReplies: Bool) {
        publicationRestrictions.requireAI = aiReplies
        publicationMode = aiReplies ? .aiReplies : publicationRestrictions.hasConditions ? .filtered : .manual
    }

    mutating func resetPublication(to preset: AutomationPreset) {
        if preset == .checkpoints { setPublishAllComments(false) }
        else { publicationMode = preset.defaultPublicationMode }
    }

    mutating func resetPublicationRestrictions() {
        let wasAll = publishesAllComments
        publicationRestrictions = .defaults(for: baselinePreset)
        if wasAll { publicationMode = .all }
        else { setAutomaticAIReplies(publicationRestrictions.requireAI) }
    }

    mutating func resetCheckpoint(_ checkpoint: AutomationCheckpoint, to preset: AutomationPreset) {
        var defaults = self
        defaults.applyPreset(preset, for: assistant)
        switch checkpoint {
        case .approval: autoApproveEnabled = defaults.autoApproveEnabled
        case .followUpPush: allowFollowUpPush = defaults.allowFollowUpPush
        case .pipelineOwnership: autoClaimPipelineFailures = defaults.autoClaimPipelineFailures
        case .startNewReviews: startNewReviewsAutomatically = defaults.startNewReviewsAutomatically
        case .ownThreadResolution: autoResolveOwnReviewThreads = defaults.autoResolveOwnReviewThreads
        case .acceptedFeedbackResolution: autoResolveAcceptedFeedback = defaults.autoResolveAcceptedFeedback
        }
    }
}
