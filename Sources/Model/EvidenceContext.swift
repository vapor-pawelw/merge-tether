import Foundation

/// Distinguishes evidence produced by different hashing rules while keeping the existing wire value.
struct EvidenceDigest<Kind>: Codable, Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) { self.rawValue = rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum DiscussionContentEvidence {}
enum DiscussionStateEvidence {}
enum SemanticContextEvidence {}
enum DraftRecoveryEvidence {}
enum CommentBodyEvidence {}
enum ReviewDiffEvidence {}
enum SavedVerdictEvidence {}

typealias DiscussionContentDigest = EvidenceDigest<DiscussionContentEvidence>
typealias DiscussionStateDigest = EvidenceDigest<DiscussionStateEvidence>
typealias SemanticContextDigest = EvidenceDigest<SemanticContextEvidence>
typealias DraftRecoveryDigest = EvidenceDigest<DraftRecoveryEvidence>
typealias CommentBodyDigest = EvidenceDigest<CommentBodyEvidence>
typealias ReviewDiffDigest = EvidenceDigest<ReviewDiffEvidence>
typealias SavedVerdictDigest = EvidenceDigest<SavedVerdictEvidence>

/// The evidence available from one record or observation. A binding policy selects the
/// fields the caller needs. Authorization, draft identity, file proof and other workflow
/// requirements still belong to their existing checks.
struct EvidenceContext: Sendable {
    struct Target: Equatable, Sendable {
        let projectID: Int
        let branch: String
        let base: String
    }

    var account: GitLabAccountIdentity?
    var accountRevision: UInt64?
    var mergeRequestID: GitLabMergeRequestID?
    var head: String?
    var targetHead: String?
    var target: Target?
    var discussionContent: DiscussionContentDigest?
    var activeDiscussionContent: DiscussionContentDigest?
    var discussionState: DiscussionStateDigest?
    var semanticContext: SemanticContextDigest?
    var recoveryContext: DraftRecoveryDigest?
    var commentBody: CommentBodyDigest?
    var commentText: String?
    var commentBatch: String?
    var reviewDiff: ReviewDiffDigest?
    var savedVerdict: SavedVerdictDigest?

    enum BindingPolicy: CaseIterable, Sendable {
        /// Account-scoped work with no captured session revision.
        case accountIdentity
        /// Async work belongs to the same account and login revision.
        case accountSession
        /// Persisted ownership binds both the account and the MR ID.
        case accountAndRequest
        /// A head-only comparison, including two absent heads where no head was captured.
        case head
        /// A text-only comparison after the caller has independently verified the MR revision.
        case semanticText
        /// The observed source head and MR title/description must agree.
        case requestText
        /// Automatic approval requires the app-captured head, target project, branch and diff base.
        case approvalTarget
        /// The same non-system discussion notes, authors and bodies, independent of resolution.
        case discussionContent
        /// Manual resolution also binds topology, timestamps, resolvability and position.
        case discussionState
        /// A review covers the head and discussion content, including separately verified publication normalization.
        case reviewContent
        /// In-progress feedback binds the head and any recorded MR text, before discussions are verified.
        case feedbackProgress
        /// Displayed complete feedback requires a recorded head, MR text and observed discussion content.
        case observedFeedback
        /// An assessment used for workflow decisions must match head, full discussion content and MR text.
        case verifiedFeedback
        /// A human action or approval readback compares the exact head, discussion and text values it captured.
        case feedbackPresentation
        /// A raw follow-up source compares head and conversation, preserving equality of absent observations.
        case followUpPresentation
        /// In-memory re-review results bind the session, MR, head, all and active discussions, and MR text.
        case reReviewAssessment
        /// Draft recovery binds the observed head and the full recovery context digest.
        case draftRecovery
        /// A legacy follow-up proof binds its head and any MR text and recovery digests it recorded.
        case legacyFollowUpProof
        /// An uncertain re-review fence with a known head applies to that head only.
        case uncertainReReviewReceipt
        /// A captured login revision alone must match. Callers retain their separate account checks.
        case accountRevision
        /// Conflict and pipeline refresh receipts bind both captured branch tip commits.
        case sourceAndTargetHeads
        /// A persisted origin assessment, override or provenance receipt requires the note's body digest.
        case commentBody
        /// In-flight origin assessments and publication provenance recheck optional text using Swift string equality.
        case commentText
        /// Origin scheduling coalesces identical batches, including their assessment directory.
        case commentBatch
        /// Merge submission checks each fingerprint the caller supplied. Missing expectations impose no check.
        case mergeSubmissionEvidence
        /// Comment-review publication uses the full recovery digest without separately comparing a head.
        case recoveryDigest
        /// Incremental review can recognize the same normalized diff across different heads.
        case reviewDiff
        /// A review update distinguishes the verdict previously observed or reported at a head.
        case savedVerdict
    }

    /// The receiver is the recorded evidence. For legacy policies the direction matters.
    func binds(to current: EvidenceContext, policy: BindingPolicy) -> Bool {
        switch policy {
        case .accountIdentity:
            guard let account, let currentAccount = current.account else { return false }
            return account.matches(currentAccount)
        case .accountSession:
            return binds(to: current, policy: .accountIdentity) && matches(accountRevision, current.accountRevision)
        case .accountAndRequest:
            return binds(to: current, policy: .accountIdentity) && matches(mergeRequestID, current.mergeRequestID)
        case .head:
            return head == current.head
        case .semanticText:
            return matches(semanticContext, current.semanticContext)
        case .requestText:
            return head == current.head && matches(semanticContext, current.semanticContext)
        case .approvalTarget:
            return matches(head, current.head) && matches(target, current.target)
        case .discussionContent:
            return matches(discussionContent, current.discussionContent)
        case .discussionState:
            return matches(discussionState, current.discussionState)
        case .reviewContent:
            return matches(head, current.head) && matches(discussionContent, current.discussionContent)
        case .feedbackProgress:
            return matches(head, current.head) && matchesIfRecorded(semanticContext, current.semanticContext)
        case .observedFeedback:
            return matches(head, current.head) && matches(semanticContext, current.semanticContext)
                && matches(discussionContent, current.discussionContent)
        case .verifiedFeedback:
            return binds(to: current, policy: .requestText) && matches(discussionContent, current.discussionContent)
        case .feedbackPresentation:
            return binds(to: current, policy: .followUpPresentation) && semanticContext == current.semanticContext
        case .followUpPresentation:
            return head == current.head && discussionContent == current.discussionContent
        case .reReviewAssessment:
            return binds(to: current, policy: .accountSession) && matches(mergeRequestID, current.mergeRequestID)
                && binds(to: current, policy: .verifiedFeedback) && matches(activeDiscussionContent, current.activeDiscussionContent)
        case .draftRecovery:
            return head == current.head && matches(recoveryContext, current.recoveryContext)
        case .legacyFollowUpProof:
            return matches(head, current.head) && matchesIfRecorded(semanticContext, current.semanticContext)
                && matchesIfRecorded(recoveryContext, current.recoveryContext)
        case .uncertainReReviewReceipt:
            return matches(head, current.head)
        case .accountRevision:
            return matches(accountRevision, current.accountRevision)
        case .sourceAndTargetHeads:
            return matches(head, current.head) && matches(targetHead, current.targetHead)
        case .commentBody:
            return matches(commentBody, current.commentBody)
        case .commentText:
            return commentText == current.commentText
        case .commentBatch:
            return matches(commentBatch, current.commentBatch)
        case .mergeSubmissionEvidence:
            return matchesIfRecorded(semanticContext, current.semanticContext)
                && matchesIfRecorded(discussionContent, current.discussionContent)
        case .recoveryDigest:
            return matches(recoveryContext, current.recoveryContext)
        case .reviewDiff:
            return matches(reviewDiff, current.reviewDiff)
        case .savedVerdict:
            return matches(savedVerdict, current.savedVerdict)
        }
    }

    static func sameHead(_ recorded: String?, _ current: String?) -> Bool {
        EvidenceContext(head: recorded).binds(to: .init(head: current), policy: .head)
    }

    static func sameAccountRevision(_ recorded: UInt64?, _ current: UInt64?) -> Bool {
        EvidenceContext(accountRevision: recorded).binds(to: .init(accountRevision: current), policy: .accountRevision)
    }

    private func matches<Value: Equatable>(_ recorded: Value?, _ current: Value?) -> Bool {
        recorded != nil && recorded == current
    }

    private func matchesIfRecorded<Value: Equatable>(_ recorded: Value?, _ current: Value?) -> Bool {
        recorded == nil || recorded == current
    }
}
