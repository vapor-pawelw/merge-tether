import Foundation

struct AuthorFeedbackAttempt: Codable, Hashable {
    let target: MRAutomationScope.Target
    let noteID: Int
    let revision: String
    var recoveryRootID: UUID? = nil
    var decisionRevision: String? = nil
}

/// Concrete residual work assessed after a completed follow-up. The run ID
/// fences the assessment's timing; it does not grant permission to replay that run.
struct AuthorFeedbackResidual: Sendable {
    let assessedRunID: UUID
    let notes: [ReReviewAssessment.Note]
    var semanticContextFingerprint: String? = nil
}

/// Decides which external threads on the user's own MR may be resolved. A thread is ready only when
/// every actionable participant has no blocking or uncertain note anywhere in the MR and has consented
/// through a current approval or a later, verified acceptance comment. A separately proven purely
/// informational thread needs no approval and grants no consent for other concerns. The caller
/// supplies current evidence and rechecks live account/head/discussion/draft state before every write.
struct AuthorFeedbackPolicy {
    enum State: String, Codable, Sendable { case ready, needsChanges, needsVerification, waitingAcceptance, waitingPublication, disabled }

    struct Finding: Identifiable, Equatable, Sendable {
        let id: Int
        let discussionID: String?
        let reviewerID: Int
        let reviewerUsername: String
        let state: State
        let reason: String?
        let waitingForReviewers: [String]
        var summary: String? = nil
        /// Exact assessment note whose explanation is displayed; the thread root can differ.
        var sourceNoteID: Int? = nil
        var canResolve: Bool { state == .ready && discussionID != nil }
    }

    struct InformationalAcknowledgement: Equatable {
        let discussionID: String?
        let noteIDs: [Int]
        let canResolve: Bool
    }

    /// Informational classification alone is not permission to acknowledge unrelated feedback.
    /// Every external note needs explicit proof that the entire thread has no remaining expectation.
    static func informationalAcknowledgements(discussions: [GitLabMergeRequestDiscussion], assessment: ReReviewAssessment,
                                              authorID: Int, enabled: Bool = true,
                                              pendingDraftCount: Int = 0,
                                              ignoredSuggestions: [IgnoredFeedbackSuggestion] = []) -> [InformationalAcknowledgement] {
        guard enabled, pendingDraftCount == 0,
              (try? assessment.reviewers(in: discussions, authorID: authorID, ignoredSuggestions: ignoredSuggestions)) != nil else { return [] }
        let verdicts = Dictionary(uniqueKeysWithValues: assessment.notes.map { ($0.noteID, $0) })
        return discussions.compactMap { discussion in
            let relevant = discussion.notes.filter { $0.system != true }
            let external = relevant.filter { $0.author?.id != authorID }
            guard discussion.notes.first?.resolved != true, !external.isEmpty, relevant.allSatisfy({
                ($0.id ?? 0) > 0 && ($0.author?.id ?? 0) > 0 && $0.body != nil
            }), external.allSatisfy({ note in
                guard let verdict = verdicts[note.id ?? 0] else { return false }
                return verdict.state == .informational && verdict.informationalAcknowledgementSafe == true
            }) else { return nil }
            let root = discussion.notes.first
            let canResolve = discussion.id?.isEmpty == false && root?.system == false
                && root?.author?.id != authorID && root?.resolvable == true && root?.resolved == false
            return .init(discussionID: discussion.id, noteIDs: external.compactMap(\.id), canResolve: canResolve)
        }
    }

    /// GitLab's regular account type does not prove who operated it. Explicit automated-report
    /// provenance therefore remains a separate content classification, independent of AI assistance.
    enum AccountKind: Sendable { case regular, automation, unknown }

    static func permitsInformationalReaction(_ note: ReReviewAssessment.Note, accountKind: AccountKind) -> Bool {
        guard note.state == .informational, note.informationalAcknowledgementSafe == true,
              let purpose = note.informationalPurpose, purpose != .automatedReviewReport else { return false }
        switch accountKind {
        case .regular: return purpose == .concreteCodeReviewFeedback || purpose == .reviewSummary
        case .automation: return purpose == .concreteCodeReviewFeedback
        case .unknown: return false
        }
    }

    private typealias Note = GitLabMergeRequestDiscussion.Note
    private typealias Verdict = ReReviewAssessment.Note

    static func evaluate(discussions: [GitLabMergeRequestDiscussion], assessment: ReReviewAssessment?, authorID: Int,
                         approvedReviewerIDs: Set<Int>, enabled: Bool = true, pendingDraftCount: Int = 0,
                         ignoredSuggestions: [IgnoredFeedbackSuggestion] = []) -> [Finding] {
        let gate: State? = !enabled ? .disabled : pendingDraftCount > 0 ? .waitingPublication : nil
        let verified = assessment.flatMap { (try? $0.reviewers(in: discussions, authorID: authorID, ignoredSuggestions: ignoredSuggestions)) == nil ? nil : $0 }
        let verdicts = Dictionary(uniqueKeysWithValues: (verified?.notes ?? []).map { ($0.noteID, $0) })
        let informationalThreads = Set(verified.map {
            informationalAcknowledgements(discussions: discussions, assessment: $0, authorID: authorID, ignoredSuggestions: ignoredSuggestions)
                .filter(\.canResolve).compactMap(\.discussionID)
        } ?? [])
        let published = discussions.flatMap(\.notes).filter { $0.system == false }
        let notesByID = Dictionary(published.compactMap { note in note.id.map { ($0, note) } }, uniquingKeysWith: { first, _ in first })
        var blockers: [Int: Verdict] = [:]
        for note in published {
            guard let id = note.id, let reviewer = note.author?.id, let verdict = verdicts[id], isBlocking(verdict) else { continue }
            if blockers[reviewer] == nil || verdict.state == .blocking && blockers[reviewer]?.state == .uncertain {
                blockers[reviewer] = verdict
            }
        }

        func accepted(_ concern: Note) -> Bool {
            guard let id = concern.id, let reviewer = concern.author?.id, let ackID = verdicts[id]?.acceptanceNoteID,
                  ackID > id, let ack = notesByID[ackID], ack.system == false, ack.author?.id == reviewer,
                  let edited = date(concern.updatedAt ?? concern.createdAt), let posted = date(ack.createdAt)
            else { return false }
            return posted > edited
        }

        var findings: [Finding] = []
        var represented: Set<Int> = []
        for (index, discussion) in discussions.enumerated() {
            guard let discussionID = discussion.id, !discussionID.isEmpty, let root = discussion.notes.first,
                  let rootID = root.id, rootID > 0, let owner = root.author, owner.id > 0, owner.id != authorID,
                  root.system == false, root.resolvable == true, root.resolved == false else { continue }
            represented.insert(index)
            let thread = discussion.notes.filter { $0.system == false && $0.author.map { $0.id != authorID } == true }
            var participants = [owner]
            for note in thread where note.id != rootID {
                guard let author = note.author, verdicts[note.id ?? 0]?.state != .informational,
                      !participants.contains(where: { $0.id == author.id }) else { continue }
                participants.append(author)
            }
            let purelyInformational = informationalThreads.contains(discussionID)
            let blocked = purelyInformational ? [] : participants.filter { blockers[$0.id] != nil }
            // A user decision retires local suggestion work. It is neither reviewer
            // consent nor permission to resolve the original GitLab discussion.
            if blocked.isEmpty, thread.contains(where: { !(verdicts[$0.id ?? 0]?.ignoredDecisionIDs ?? []).isEmpty }) { continue }
            let waiting = purelyInformational ? [] : participants.filter { participant in
                blockers[participant.id] != nil || !approvedReviewerIDs.contains(participant.id) && !thread.filter {
                    $0.author?.id == participant.id && ($0.id == rootID || verdicts[$0.id ?? 0]?.state == .addressed)
                }.allSatisfy(accepted)
            }
            let remaining = thread.compactMap { verdicts[$0.id ?? 0] }.filter(isBlocking)
            let localConcern = remaining.first { $0.state == .blocking } ?? remaining.first
            let inherited = blocked.compactMap { blockers[$0.id] }
            let explanation = blocked.isEmpty ? verdicts[rootID]
                : (localConcern ?? inherited.first { $0.state == .blocking } ?? inherited.first)
            let semanticState: State = verified == nil ? .needsVerification
                : !blocked.isEmpty ? (explanation?.state == .blocking ? .needsChanges : .needsVerification)
                : !waiting.isEmpty ? .waitingAcceptance : .ready
            let state = pendingDraftCount > 0 ? .waitingPublication
                : semanticState == .ready ? (gate ?? .ready) : semanticState
            findings.append(Finding(id: rootID, discussionID: discussionID, reviewerID: owner.id,
                                    reviewerUsername: handle(owner), state: state, reason: explanation?.reason,
                                    waitingForReviewers: verified == nil ? [] : waiting.map(handle), summary: explanation?.summary,
                                    sourceNoteID: explanation?.noteID))
        }

        for (index, discussion) in discussions.enumerated() where !represented.contains(index) {
            for note in discussion.notes {
                guard let id = note.id, let author = note.author, let verdict = verdicts[id], isBlocking(verdict) else { continue }
                findings.append(Finding(id: id, discussionID: note.resolvable == true ? discussion.id : nil,
                                        reviewerID: author.id, reviewerUsername: handle(author),
                                        state: pendingDraftCount > 0 ? .waitingPublication
                                            : verdict.state == .blocking ? .needsChanges : .needsVerification,
                                        reason: verdict.reason, waitingForReviewers: [handle(author)], summary: verdict.summary, sourceNoteID: verdict.noteID))
            }
        }
        return findings
    }

    private static func isBlocking(_ verdict: Verdict) -> Bool {
        verdict.state == .blocking || verdict.state == .uncertain
    }

    /// Closed threads still carry consent, so a later poll does not ask the same
    /// reviewer to re-review a fix they have already explicitly accepted.
    static func acceptedReviewers(discussions: [GitLabMergeRequestDiscussion], assessment: ReReviewAssessment,
                                  authorID: Int, approvedReviewerIDs: Set<Int>,
                                  ignoredSuggestions: [IgnoredFeedbackSuggestion] = []) -> Set<Int> {
        guard (try? assessment.reviewers(in: discussions, authorID: authorID, ignoredSuggestions: ignoredSuggestions)) != nil else { return [] }
        let verdicts = Dictionary(uniqueKeysWithValues: assessment.notes.map { ($0.noteID, $0) })
        let external = discussions.flatMap(\.notes).filter { $0.system == false && $0.author?.id != authorID }
        let byID = Dictionary(uniqueKeysWithValues: external.compactMap { note in note.id.map { ($0, note) } })
        return Set(Dictionary(grouping: external, by: { $0.author!.id }).compactMap { reviewer, notes in
            guard !notes.contains(where: {
                verdicts[$0.id ?? 0].map(isBlocking) == true
            }) else { return nil }
            let actionable = notes.filter { verdicts[$0.id ?? 0]?.state == .addressed }
            guard !actionable.isEmpty else { return nil }
            if approvedReviewerIDs.contains(reviewer) { return reviewer }
            return actionable.allSatisfy { concern in
                guard let ackID = verdicts[concern.id ?? 0]?.acceptanceNoteID, ackID > (concern.id ?? 0),
                      let ack = byID[ackID], ack.author?.id == reviewer,
                      let edited = date(concern.updatedAt ?? concern.createdAt), let posted = date(ack.createdAt) else { return false }
                return posted > edited
            } ? reviewer : nil
        })
    }

    private static func handle(_ user: GitLabWorkflowUser) -> String {
        user.username ?? user.name ?? String(user.id)
    }

    private static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
