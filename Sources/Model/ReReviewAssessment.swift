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
        enum State: String, Codable, Sendable { case addressed, informational, blocking, uncertain, ignoredByUser }
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
        /// including supporting evidence in another discussion. Never waives this thread's reply.
        var publishedReplyNoteID: Int? = nil
    }
    let notes: [Note]
    var completedBlockedRunIDs: [UUID]? = nil
    var codeReviewRequests: [CodeReviewRequest]? = nil

    var reviewRequests: [CodeReviewRequest] { codeReviewRequests ?? [] }

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

    /// Addressed code or an explanation elsewhere does not replace this thread's reply.
    /// Includes actionable general comments; private drafts never prove publication.
    func missingPublishedReplyNoteIDs(in discussions: [GitLabMergeRequestDiscussion], authorID: Int) -> Set<Int> {
        let addressed = Set(notes.filter { $0.state == .addressed }.map(\.noteID))
        return Set(discussions.flatMap { thread in
            thread.notes.compactMap { note -> Int? in
                guard let id = note.id, addressed.contains(id), note.system == false,
                      note.author?.id != authorID, note.resolved != true,
                      !thread.notes.contains(where: {
                          $0.system == false && $0.author?.id == authorID && ($0.id ?? 0) > id
                      }) else { return nil }
                return id
            }
        })
    }

    /// The thread root anchors presentation, while each owed note remains the worker's scope.
    func missingPublishedRepliesByThread(in discussions: [GitLabMergeRequestDiscussion], authorID: Int) -> [Int: Set<Int>] {
        let owed = missingPublishedReplyNoteIDs(in: discussions, authorID: authorID)
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
        guard note.state == .addressed, let replyID = note.publishedReplyNoteID, replyID > note.noteID else { return false }
        let matching = discussions.flatMap(\.notes).filter { $0.id == replyID }
        guard matching.count == 1, let reply = matching.first, reply.system == false, reply.author?.id == authorID,
              let body = reply.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    func hasNoRemainingAuthorWork(in discussions: [GitLabMergeRequestDiscussion], authorID: Int,
                                 ignoredSuggestions: [IgnoredFeedbackSuggestion] = []) -> Bool {
        guard reviewRequests.isEmpty,
              (try? reviewers(in: discussions, authorID: authorID, ignoredSuggestions: ignoredSuggestions)) != nil else { return false }
        return notes.allSatisfy { [.addressed, .informational, .ignoredByUser].contains($0.state) }
            && missingPublishedReplyNoteIDs(in: discussions, authorID: authorID).isEmpty
    }

    func reviewers(in discussions: [GitLabMergeRequestDiscussion], authorID: Int,
                   ignoredSuggestions: [IgnoredFeedbackSuggestion] = []) throws -> [Int: Int] {
        let external = discussions.flatMap(\.notes).filter { $0.system != true && $0.author?.id != authorID }
        guard external.allSatisfy({ ($0.id ?? 0) > 0 && ($0.author?.id ?? 0) > 0 && $0.body != nil }),
              Set(external.compactMap(\.id)).count == external.count,
              notes.count == external.count, Set(notes.map(\.noteID)) == Set(external.compactMap(\.id)),
              notes.allSatisfy({ !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.reason.count <= 600 })
        else { throw ValidationError.incompleteEvidence }
        let byID = Dictionary(uniqueKeysWithValues: notes.map { ($0.noteID, $0) })
        guard reviewRequests.count <= 12, Set(reviewRequests.map(\.id)).count == reviewRequests.count,
              reviewRequests.allSatisfy({ request in
                  guard let source = external.first(where: { $0.id == request.sourceNoteID }),
                        let assessment = byID[request.sourceNoteID], request.matches(source, authorID: authorID),
                        (assessment.ignoredDecisionIDs ?? []).isEmpty,
                        !ignoredSuggestions.contains(where: { $0.matches(source) }),
                        [.addressed, .blocking, .uncertain].contains(assessment.state) else { return false }
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
            let ignoredIDs = assessment.ignoredDecisionIDs ?? []
            guard Set(ignoredIDs).count == ignoredIDs.count,
                  Set(ignoredIDs).isSubset(of: activeIDs),
                  assessment.state != .ignoredByUser || !ignoredIDs.isEmpty,
                  assessment.state != .ignoredByUser || (assessment.acceptanceNoteID == nil && assessment.informationalAcknowledgementSafe != true),
                  ignoredIDs.isEmpty || [.ignoredByUser, .addressed, .blocking, .uncertain].contains(assessment.state),
                  assessment.publishedReplyNoteID == nil || hasPublishedReply(for: assessment, in: discussions, authorID: authorID),
                  ignoredSuggestions.filter({ ignoredIDs.contains($0.id) }).allSatisfy({ $0.matches(note) })
            else { throw ValidationError.incompleteEvidence }
            switch assessment.state {
            case .addressed: ready[reviewer] = max(ready[reviewer] ?? 0, id)
            case .blocking, .uncertain: blocked.insert(reviewer)
            case .informational, .ignoredByUser: break
            }
        }
        for request in reviewRequests {
            if let reviewer = external.first(where: { $0.id == request.sourceNoteID })?.author?.id { blocked.insert(reviewer) }
        }
        return ready.filter { !blocked.contains($0.key) }
    }
}
