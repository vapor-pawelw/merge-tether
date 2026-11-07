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

    var hasIdentityConditions: Bool {
        !repositories.isEmpty || !mergeRequestAuthors.isEmpty || !sourceCommentAuthors.isEmpty
    }
    var hasConditions: Bool { requireAI || hasIdentityConditions }

    static func defaults(for preset: AutomationPreset?) -> Self {
        .init(requireAI: preset == .full || preset == .checkpoints)
    }
}

struct AutomaticPublicationPolicy: Equatable, Sendable {
    let mode: AutomationPublicationMode
    let restrictions: AutomaticPublicationRestrictions

    func allows(_ draft: GitLabDraftNote, request: GitLabMergeRequest,
                discussions: [GitLabMergeRequestDiscussion]?, userID: Int, host: String,
                aiNoteIDs: Set<Int>) -> Bool {
        guard couldAllow(draft, request: request, userID: userID, host: host) else { return false }
        guard requiresSources else { return true }
        guard let sources = Self.sourceNotes(for: draft, discussions: discussions, userID: userID),
              !sources.isEmpty else { return false }
        return sources.allSatisfy { note in
            guard let authorID = note.author?.id, let noteID = note.id else { return false }
            return matches(restrictions.sourceCommentAuthors, host: host, id: authorID)
                && (!requiresAI || aiNoteIDs.contains(noteID))
        }
    }

    /// A cheap necessary-condition check for proof warnings. It can prove that
    /// a draft is excluded without guessing missing discussion/AI evidence.
    func couldAllow(_ draft: GitLabDraftNote, request: GitLabMergeRequest, userID: Int, host: String) -> Bool {
        guard mode != .manual, userID > 0, (draft.id ?? 0) > 0, draft.authorID == userID,
              Self.safeForAutomaticPublication(draft), request.projectID > 0, request.iid > 0,
              request.author.id > 0, request.webURL.isGitLabMergeRequest(host: host, iid: request.iid) else { return false }
        if mode == .all { return true }
        guard mode != .filtered || restrictions.hasConditions,
              matches(restrictions.repositories, host: host, id: request.projectID),
              matches(restrictions.mergeRequestAuthors, host: host, id: request.author.id) else { return false }
        return !requiresSources || draft.discussionID.map { !$0.isEmpty } == true
    }

    var requiresAI: Bool { mode != .all && (mode == .aiReplies || restrictions.requireAI) }
    private var requiresSources: Bool { mode != .all && (requiresAI || !restrictions.sourceCommentAuthors.isEmpty) }

    private func matches(_ identities: [PublicationIdentity], host: String, id: Int) -> Bool {
        identities.isEmpty || identities.contains { $0.host == host && $0.entityID == id && id > 0 }
    }

    static func safeForAutomaticPublication(_ draft: GitLabDraftNote) -> Bool {
        guard draft.resolveDiscussion != true, let body = draft.note,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // Even a slash-command example inside a fence can execute a GitLab quick action.
        return !body.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("/")
        }
    }

    /// Sources are every external comment after our latest published reply. A human
    /// follow-up in an AI-started thread must never inherit the first comment's identity.
    static func sourceNotes(for draft: GitLabDraftNote, discussions: [GitLabMergeRequestDiscussion]?,
                            userID: Int) -> [GitLabMergeRequestDiscussion.Note]? {
        guard let threadID = draft.discussionID, !threadID.isEmpty,
              let threads = discussions?.filter({ $0.id == threadID }), threads.count == 1 else { return nil }
        let notes = threads[0].notes.filter { $0.system != true }
        guard notes.allSatisfy({ ($0.id ?? 0) > 0 && ($0.author?.id ?? 0) > 0 }),
              Set(notes.compactMap(\.id)).count == notes.count else { return nil }
        let lastReply = notes.filter { $0.author?.id == userID }.compactMap(\.id).max() ?? 0
        return notes.filter { $0.author?.id != userID && ($0.id ?? 0) > lastReply }
    }
}

enum AutomationCheckpoint: CaseIterable {
    case approval, followUpPush, ownThreadResolution, acceptedFeedbackResolution
}

extension AutomationSettings {
    var automaticPublicationPolicy: AutomaticPublicationPolicy {
        .init(mode: publicationMode, restrictions: publicationRestrictions)
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
        publicationMode = aiReplies ? .aiReplies : publicationRestrictions.hasIdentityConditions ? .filtered : .manual
    }

    mutating func resetPublication(to preset: AutomationPreset) {
        setPublishAllComments(preset == .full)
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
        case .ownThreadResolution: autoResolveOwnReviewThreads = defaults.autoResolveOwnReviewThreads
        case .acceptedFeedbackResolution: autoResolveAcceptedFeedback = defaults.autoResolveAcceptedFeedback
        }
    }
}
