import Foundation

/// Semantic assessment is content-bound. The app, rather than the model, selects recipients
/// and performs a final live account/head/discussion/draft check before notifying anyone.
struct ReReviewAssessment: Codable, Sendable {
    /// A private hypothesis for the stronger reviewer, never an attributed reviewer finding.
    struct CodeReviewRequest: Codable, Equatable, Sendable, Identifiable {
        enum Kind: String, Codable, Sendable { case feedbackVerification, potentialDefect }
        let sourceNoteID: Int
        let sourceQuote: String
        let kind: Kind
        let summary: String
        let question: String

        var id: String { "\(sourceNoteID)/\(kind.rawValue)/\(question)" }

        func matches(_ note: GitLabMergeRequestDiscussion.Note, authorID: Int) -> Bool {
            note.id == sourceNoteID && note.system == false && (note.author?.id ?? 0) > 0
                && note.author?.id != authorID && !sourceQuote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && sourceQuote.count <= 500 && note.body?.contains(sourceQuote) == true
                && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && question.count <= 600
                && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && summary.count <= 200
        }
    }

    struct Note: Codable, Sendable {
        struct ManualDecision: Codable, Equatable, Sendable {
            let context: String
            let verifiedFacts: String
            let missingEvidence: String
            let question: String
            let mergeImpact: String

            var isValid: Bool {
                [(context, 2_000), (verifiedFacts, 2_000), (missingEvidence, 2_000),
                 (question, 1_000), (mergeImpact, 1_000)].allSatisfy {
                    !$0.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.0.count <= $0.1
                }
            }
        }
        struct ReviewerOptOut: Codable, Sendable {
            let sourceQuote: String
        }
        struct ReviewSummaryCoverage: Codable, Sendable {
            let referencedNoteIDs: [Int]
            let noIndependentExpectation: Bool
        }
        enum State: String, Codable, Sendable { case addressed, rejected, informational, blocking, uncertain, ignoredByUser }
        enum InformationalPurpose: String, Codable, Sendable {
            case concreteCodeReviewFeedback, reviewSummary, automatedReviewReport, other
        }
        let noteID: Int
        let state: State
        let reason: String
        var summary: String? = nil
        var acceptanceNoteID: Int? = nil
        // Legacy assessments omit this field and never authorize a reaction or informational closure.
        var informationalAcknowledgementSafe: Bool? = nil
        // Purpose describes the note, never whether a human used AI to write it.
        var informationalPurpose: InformationalPurpose? = nil
        var ignoredDecisionIDs: [UUID]? = nil
        /// A semantically verified, published author reply covering this exact concern,
        /// including supporting evidence in another discussion. Reply obligations are evaluated separately.
        var publishedReplyNoteID: Int? = nil
        /// Within the enclosing head/text/discussion-bound assessment, this summary adds no obligation beyond the named findings.
        var reviewSummaryCoverage: ReviewSummaryCoverage? = nil
        var reviewerOptOut: ReviewerOptOut? = nil
        var manualDecision: ManualDecision? = nil

        var needsAutomaticWork: Bool {
            state == .blocking || state == .uncertain && manualDecision == nil
        }
    }
    let notes: [Note]
    var completedBlockedRunIDs: [UUID]? = nil
    var codeReviewRequests: [CodeReviewRequest]? = nil

    var reviewRequests: [CodeReviewRequest] { codeReviewRequests ?? [] }

    var automaticWorkNoteIDs: Set<Int> {
        Set(notes.filter(\.needsAutomaticWork).map(\.noteID)).union(reviewRequests.map(\.sourceNoteID))
    }

    func reviewerOptOutIDs(in discussions: [GitLabMergeRequestDiscussion], authorID: Int) -> Set<Int> {
        Set(discussions.flatMap(\.notes).compactMap { source -> Int? in
            guard source.system == false, let id = source.id, let participant = source.author?.id,
                  participant != authorID, participant > 0,
                  let proof = notes.first(where: { $0.noteID == id })?.reviewerOptOut,
                  !proof.sourceQuote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  proof.sourceQuote.count <= 500, source.body?.contains(proof.sourceQuote) == true else { return nil }
            return participant
        })
    }

    func pureReviewerOptOutNoteIDs(in discussions: [GitLabMergeRequestDiscussion], authorID: Int) -> Set<Int> {
        let excluded = reviewerOptOutIDs(in: discussions, authorID: authorID)
        return Set(notes.compactMap { note in
            guard let proof = note.reviewerOptOut, !proof.sourceQuote.isEmpty, proof.sourceQuote.count <= 500,
                  note.state == .informational,
                  note.informationalPurpose == .other, note.informationalAcknowledgementSafe != true,
                  note.acceptanceNoteID == nil, (note.ignoredDecisionIDs ?? []).isEmpty,
                  !reviewRequests.contains(where: { $0.sourceNoteID == note.noteID }),
                  discussions.flatMap(\.notes).contains(where: {
                      $0.id == note.noteID && $0.author.map { excluded.contains($0.id) } == true
                          && $0.body?.contains(proof.sourceQuote) == true
                  }) else { return nil }
            return note.noteID
        })
    }

    func normalizingCoveredReviewSummaries(in discussions: [GitLabMergeRequestDiscussion], authorID: Int,
                                          ignoredSuggestions: [IgnoredFeedbackSuggestion] = [], excludedReplyAuthorIDs: Set<Int> = []) throws -> Self {
        let active = GitLabMergeRequestDiscussion.activeForReview(discussions)
        let closedIDs = Set(discussions.filter(\.isResolvedForReview).flatMap(\.notes).compactMap(\.id))
        let assessment = Self(notes: notes.filter { !closedIDs.contains($0.noteID) },
            completedBlockedRunIDs: completedBlockedRunIDs, codeReviewRequests: codeReviewRequests?.filter {
                !closedIDs.contains($0.sourceNoteID)
            })
        _ = try assessment.reviewers(in: discussions, authorID: authorID, ignoredSuggestions: ignoredSuggestions,
            excludedReplyAuthorIDs: excludedReplyAuthorIDs)
        let summaries = assessment.coveredReviewSummaryIDs(in: active, authorID: authorID, excludedReplyAuthorIDs: excludedReplyAuthorIDs)
        return .init(notes: assessment.notes.map { note in
            guard summaries.contains(note.noteID) else { return note }
            return .init(noteID: note.noteID, state: .informational, reason: note.reason, summary: note.summary,
                informationalAcknowledgementSafe: note.informationalAcknowledgementSafe,
                informationalPurpose: note.informationalPurpose, reviewSummaryCoverage: note.reviewSummaryCoverage)
        }, completedBlockedRunIDs: completedBlockedRunIDs, codeReviewRequests: assessment.codeReviewRequests)
    }

    var readiness: ReReviewReadiness {
        let blockers = readinessBlockers
        return notes.contains { $0.state == .blocking } ? .blocked(blockers) : .uncertain(blockers)
    }

    var readinessBlockers: [ReReviewReadiness.Blocker] {
        let concerns = notes.filter { $0.state == .blocking } + notes.filter { $0.state == .uncertain }
        var blockers = concerns.map {
            ReReviewReadiness.Blocker(noteID: $0.noteID, reason: $0.reason, summary: $0.summary, isUncertain: $0.state == .uncertain)
        }
        var represented = Set(concerns.map(\.noteID))
        for request in reviewRequests where represented.insert(request.sourceNoteID).inserted {
            blockers.append(.init(noteID: request.sourceNoteID, reason: request.question, summary: request.summary,
                isUncertain: true, isPrivateCodeQuestion: true))
        }
        return blockers
    }

    /// A verified correction or rejection does not replace this thread's reply.
    /// Includes actionable general comments; private drafts never prove publication.
    func missingPublishedReplyNoteIDs(in discussions: [GitLabMergeRequestDiscussion], authorID: Int,
                                     excludedReplyAuthorIDs: Set<Int> = []) -> Set<Int> {
        let active = GitLabMergeRequestDiscussion.activeForReview(discussions)
        let owed = repliesOwedByAddressedNotes(in: active, authorID: authorID, excludedReplyAuthorIDs: excludedReplyAuthorIDs)
        return owed
            .subtracting(coveredReviewSummaryIDs(in: active, authorID: authorID, excludedReplyAuthorIDs: excludedReplyAuthorIDs))
            .subtracting(answeredReviewOverviewIDs(in: discussions, authorID: authorID, owed: owed))
    }

    /// A non-resolvable overview comment published in the same review submission as a resolvable
    /// finding by the same reviewer is answered by the verified reply in that finding's thread.
    /// The semantic check already proved the reply covers the whole overview; this only waives the
    /// duplicate local reply. Standalone general comments and separate findings keep their own reply.
    private func answeredReviewOverviewIDs(in discussions: [GitLabMergeRequestDiscussion], authorID: Int, owed: Set<Int>) -> Set<Int> {
        let byID = Dictionary(notes.map { ($0.noteID, $0) }, uniquingKeysWith: { first, _ in first })
        let questions = Set(reviewRequests.map(\.sourceNoteID))
        return Set(owed.compactMap { id -> Int? in
            guard let assessment = byID[id], let replyID = assessment.publishedReplyNoteID,
                  (assessment.ignoredDecisionIDs ?? []).isEmpty, !questions.contains(id),
                  let overview = discussions.first(where: { $0.reviewRoot?.id == id })?.reviewRoot,
                  hasPublishedReply(for: assessment, in: discussions, authorID: authorID),
                  let replyThread = discussions.first(where: { $0.notes.contains { $0.id == replyID } }),
                  replyThread.reviewRoot?.id != id else { return nil }
            if replyThread.isResolvedForReview {
                return Self.isResolvedOverviewReply(replyThread, replyID: replyID,
                    assessment: assessment, overview: overview) ? id : nil
            }
            let answersSiblingFinding = replyThread.notes.contains { finding in
                guard let findingID = finding.id, findingID < replyID,
                      Self.isSameReviewFinding(finding, as: overview),
                      let verified = byID[findingID], [.addressed, .rejected, .informational].contains(verified.state),
                      (verified.ignoredDecisionIDs ?? []).isEmpty, !questions.contains(findingID),
                      !owed.contains(findingID) else { return false }
                return true
            }
            return answersSiblingFinding ? id : nil
        })
    }

    /// Include only resolved findings that could contain a published answer to an active overview.
    static func resolvedOverviewReplyEvidence(in discussions: [GitLabMergeRequestDiscussion],
                                              authorID: Int, overviewIDs: Set<Int>? = nil) -> [GitLabMergeRequestDiscussion] {
        let overviews = GitLabMergeRequestDiscussion.activeForReview(discussions).compactMap(\.reviewRoot).filter {
            $0.resolvable == false && $0.author?.id != authorID && (overviewIDs?.contains($0.id ?? 0) ?? true)
        }
        return discussions.filter { thread in
            guard thread.isResolvedForReview, let finding = thread.reviewRoot, let findingID = finding.id else { return false }
            return overviews.contains { overview in
                guard let overviewID = overview.id, isSameReviewFinding(finding, as: overview) else { return false }
                return thread.notes.contains { isAuthorReply($0, after: max(findingID, overviewID), authorID: authorID) }
            }
        }
    }

    private static func isSameReviewFinding(_ finding: GitLabMergeRequestDiscussion.Note,
                                            as overview: GitLabMergeRequestDiscussion.Note) -> Bool {
        guard overview.system == false, overview.resolvable == false, let reviewer = overview.author?.id, reviewer > 0,
              finding.system == false, finding.resolvable == true, finding.author?.id == reviewer,
              let submitted = date(overview.createdAt), let posted = date(finding.createdAt) else { return false }
        return abs(posted.timeIntervalSince(submitted)) <= 60
    }

    private static func isResolvedOverviewReply(_ thread: GitLabMergeRequestDiscussion, replyID: Int,
                                                assessment: Note, overview: GitLabMergeRequestDiscussion.Note) -> Bool {
        guard thread.isResolvedForReview, assessment.informationalPurpose == .reviewSummary,
              let finding = thread.reviewRoot, let findingID = finding.id, findingID < replyID,
              isSameReviewFinding(finding, as: overview) else { return false }
        return thread.notes.contains { $0.id == replyID }
    }

    private static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private func repliesOwedByAddressedNotes(in discussions: [GitLabMergeRequestDiscussion], authorID: Int,
                                           excludedReplyAuthorIDs: Set<Int> = []) -> Set<Int> {
        let addressed = Set(notes.filter { $0.state == .addressed || $0.state == .rejected }.map(\.noteID))
        let excluded = excludedReplyAuthorIDs.union(reviewerOptOutIDs(in: discussions, authorID: authorID))
        return Set(discussions.flatMap { thread in
            thread.notes.compactMap { note -> Int? in
                guard let id = note.id, addressed.contains(id), note.system == false,
                      note.author?.id != authorID, note.resolved != true,
                      note.author.map({ !excluded.contains($0.id) }) == true,
                      !thread.notes.contains(where: {
                          $0.system == false && $0.author?.id == authorID && ($0.id ?? 0) > id
                      }) else { return nil }
                return id
            }
        })
    }

    private func coveredReviewSummaryIDs(in discussions: [GitLabMergeRequestDiscussion], authorID: Int,
                                         excludedReplyAuthorIDs: Set<Int> = []) -> Set<Int> {
        let externalIDs = Set(discussions.flatMap(\.notes).filter {
            $0.system == false && $0.author?.id != authorID
        }.compactMap(\.id))
        guard notes.count == externalIDs.count, Set(notes.map(\.noteID)) == externalIDs else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: notes.map { ($0.noteID, $0) })
        let owed = repliesOwedByAddressedNotes(in: discussions, authorID: authorID, excludedReplyAuthorIDs: excludedReplyAuthorIDs)
        let questions = Set(reviewRequests.map(\.sourceNoteID))
        return Set(notes.compactMap { summary in
            guard let proof = summary.reviewSummaryCoverage, proof.noIndependentExpectation,
                  summary.informationalPurpose == .reviewSummary,
                  [.addressed, .rejected, .informational].contains(summary.state),
                  (summary.ignoredDecisionIDs ?? []).isEmpty, !questions.contains(summary.noteID),
                  externalIDs.contains(summary.noteID),
                  !proof.referencedNoteIDs.isEmpty, proof.referencedNoteIDs.count <= 12,
                  Set(proof.referencedNoteIDs).count == proof.referencedNoteIDs.count,
                  !proof.referencedNoteIDs.contains(summary.noteID),
                  proof.referencedNoteIDs.allSatisfy({ id in
                      guard externalIDs.contains(id), let reference = byID[id] else { return false }
                      return [.addressed, .rejected, .informational].contains(reference.state)
                          && reference.informationalPurpose != .reviewSummary && reference.reviewSummaryCoverage == nil
                          && (reference.ignoredDecisionIDs ?? []).isEmpty
                          && !owed.contains(id) && !questions.contains(id)
                  }) else { return nil }
            return summary.noteID
        })
    }

    /// The thread root anchors presentation, while each owed note remains the worker's scope.
    func missingPublishedRepliesByThread(in discussions: [GitLabMergeRequestDiscussion], authorID: Int,
                                         excludedReplyAuthorIDs: Set<Int> = []) -> [Int: Set<Int>] {
        let owed = missingPublishedReplyNoteIDs(in: discussions, authorID: authorID, excludedReplyAuthorIDs: excludedReplyAuthorIDs)
        var threads: [Int: Set<Int>] = [:]
        for discussion in discussions {
            guard let rootID = discussion.notes.first?.id else { continue }
            let scoped = Set(discussion.notes.compactMap(\.id)).intersection(owed)
            if !scoped.isEmpty { threads[rootID, default: []].formUnion(scoped) }
        }
        return threads
    }

    enum ValidationError: Error { case incompleteEvidence }

    private func hasPublishedReply(for note: Note, in discussions: [GitLabMergeRequestDiscussion], authorID: Int) -> Bool {
        guard [.addressed, .rejected].contains(note.state), let replyID = note.publishedReplyNoteID else { return false }
        let matching = discussions.flatMap(\.notes).filter { $0.id == replyID }
        guard matching.count == 1, let reply = matching.first else { return false }
        return Self.isAuthorReply(reply, after: note.noteID, authorID: authorID)
    }

    private static func isAuthorReply(_ note: GitLabMergeRequestDiscussion.Note, after sourceID: Int, authorID: Int) -> Bool {
        note.system == false && note.author?.id == authorID && (note.id ?? 0) > sourceID
            && note.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func hasNoRemainingAuthorWork(in discussions: [GitLabMergeRequestDiscussion], authorID: Int,
                                 ignoredSuggestions: [IgnoredFeedbackSuggestion] = [], excludedReplyAuthorIDs: Set<Int> = []) -> Bool {
        guard let assessment = try? normalizingCoveredReviewSummaries(in: discussions, authorID: authorID,
            ignoredSuggestions: ignoredSuggestions, excludedReplyAuthorIDs: excludedReplyAuthorIDs),
              assessment.reviewRequests.isEmpty else { return false }
        return assessment.notes.allSatisfy { [.addressed, .rejected, .informational, .ignoredByUser].contains($0.state) }
            && assessment.missingPublishedReplyNoteIDs(in: discussions, authorID: authorID, excludedReplyAuthorIDs: excludedReplyAuthorIDs).isEmpty
    }

    func reviewers(in allDiscussions: [GitLabMergeRequestDiscussion], authorID: Int,
                   ignoredSuggestions: [IgnoredFeedbackSuggestion] = [], excludedReplyAuthorIDs: Set<Int> = []) throws -> [Int: Int] {
        let discussions = GitLabMergeRequestDiscussion.activeForReview(allDiscussions)
        let external = discussions.flatMap(\.notes).filter { $0.system != true && $0.author?.id != authorID }
        guard external.allSatisfy({ ($0.id ?? 0) > 0 && ($0.author?.id ?? 0) > 0 && $0.body != nil }),
              Set(external.compactMap(\.id)).count == external.count,
              notes.count == external.count, Set(notes.map(\.noteID)) == Set(external.compactMap(\.id)),
              notes.allSatisfy({ !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.reason.count <= 600 })
        else { throw ValidationError.incompleteEvidence }
        let byID = Dictionary(uniqueKeysWithValues: notes.map { ($0.noteID, $0) })
        let coveredSummaries = coveredReviewSummaryIDs(in: discussions, authorID: authorID, excludedReplyAuthorIDs: excludedReplyAuthorIDs)
        guard notes.allSatisfy({ $0.reviewSummaryCoverage == nil || coveredSummaries.contains($0.noteID) }) else {
            throw ValidationError.incompleteEvidence
        }
        guard reviewRequests.count <= 12, Set(reviewRequests.map(\.id)).count == reviewRequests.count,
              reviewRequests.allSatisfy({ request in
                  guard let source = external.first(where: { $0.id == request.sourceNoteID }),
                        let assessment = byID[request.sourceNoteID], request.matches(source, authorID: authorID),
                        (assessment.ignoredDecisionIDs ?? []).isEmpty,
                        !ignoredSuggestions.contains(where: { $0.matches(source) }),
                        [.addressed, .rejected, .blocking, .uncertain].contains(assessment.state) else { return false }
                  return request.kind == .potentialDefect || assessment.state == .uncertain
              }) else { throw ValidationError.incompleteEvidence }
        let activeIDs = Set(ignoredSuggestions.map(\.id))
        guard activeIDs.count == ignoredSuggestions.count else { throw ValidationError.incompleteEvidence }
        var ready: [Int: Int] = [:]
        var blocked: Set<Int> = []
        for note in external {
            guard let id = note.id, let reviewer = note.author?.id, let assessment = byID[id] else {
                throw ValidationError.incompleteEvidence
            }
            if let decision = assessment.manualDecision {
                guard assessment.state == .uncertain, decision.isValid,
                      assessment.acceptanceNoteID == nil, assessment.informationalAcknowledgementSafe != true,
                      assessment.reviewSummaryCoverage == nil, assessment.reviewerOptOut == nil,
                      (assessment.ignoredDecisionIDs ?? []).isEmpty,
                      !reviewRequests.contains(where: { $0.sourceNoteID == id }) else {
                    throw ValidationError.incompleteEvidence
                }
            }
            let ignoredIDs = assessment.ignoredDecisionIDs ?? []
            let validPublishedReply = assessment.publishedReplyNoteID.map { replyID in
                if hasPublishedReply(for: assessment, in: discussions, authorID: authorID) { return true }
                return discussions.contains { $0.reviewRoot?.id == id }
                    && allDiscussions.contains {
                        Self.isResolvedOverviewReply($0, replyID: replyID, assessment: assessment, overview: note)
                    }
                    && hasPublishedReply(for: assessment, in: allDiscussions, authorID: authorID)
            } ?? true
            if let proof = assessment.reviewerOptOut {
                guard !proof.sourceQuote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      proof.sourceQuote.count <= 500, note.body?.contains(proof.sourceQuote) == true,
                      assessment.informationalAcknowledgementSafe != true, assessment.acceptanceNoteID == nil,
                      assessment.reviewSummaryCoverage == nil,
                      assessment.state != .ignoredByUser else { throw ValidationError.incompleteEvidence }
                guard assessment.state != .informational || assessment.informationalPurpose == .other else {
                    throw ValidationError.incompleteEvidence
                }
            }
            guard Set(ignoredIDs).count == ignoredIDs.count,
                  Set(ignoredIDs).isSubset(of: activeIDs),
                  assessment.state != .ignoredByUser || !ignoredIDs.isEmpty,
                  assessment.state != .ignoredByUser || (assessment.acceptanceNoteID == nil && assessment.informationalAcknowledgementSafe != true),
                  ignoredIDs.isEmpty || [.ignoredByUser, .addressed, .rejected, .blocking, .uncertain].contains(assessment.state),
                  validPublishedReply,
                  ignoredSuggestions.filter({ ignoredIDs.contains($0.id) }).allSatisfy({ $0.matches(note) })
            else { throw ValidationError.incompleteEvidence }
            switch assessment.state {
            case .addressed, .rejected:
                if !coveredSummaries.contains(id) { ready[reviewer] = max(ready[reviewer] ?? 0, id) }
            case .blocking, .uncertain: blocked.insert(reviewer)
            case .informational, .ignoredByUser: break
            }
        }
        for request in reviewRequests {
            if let reviewer = external.first(where: { $0.id == request.sourceNoteID })?.author?.id { blocked.insert(reviewer) }
        }
        let optedOut = reviewerOptOutIDs(in: discussions, authorID: authorID)
        return ready.filter { !blocked.contains($0.key) && !optedOut.contains($0.key) }
    }
}
