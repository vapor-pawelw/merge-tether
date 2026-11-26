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

typealias DiscussionContentDigest = EvidenceDigest<DiscussionContentEvidence>
typealias DiscussionStateDigest = EvidenceDigest<DiscussionStateEvidence>
typealias SemanticContextDigest = EvidenceDigest<SemanticContextEvidence>
typealias DraftRecoveryDigest = EvidenceDigest<DraftRecoveryEvidence>

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
    var target: Target?
    var discussionContent: DiscussionContentDigest?
    var activeDiscussionContent: DiscussionContentDigest?
    var discussionState: DiscussionStateDigest?
    var semanticContext: SemanticContextDigest?
    var recoveryContext: DraftRecoveryDigest?

    enum BindingPolicy: CaseIterable, Sendable {
        /// Account-scoped work with no captured session revision.
        case accountIdentity
        /// Async work belongs to the same host, username and login revision.
        case accountSession
        /// Persisted ownership uses host, username and MR ID. The caller checks the GitLab user ID.
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
        /// Displayed complete feedback and partial-read invalidation also require the observed discussion content.
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
        /// A legacy uncertain re-review write can still prevent replay if it did not record a head.
        case uncertainReReviewReceipt
    }

    /// The receiver is the recorded evidence. For legacy policies the direction matters.
    func binds(to current: EvidenceContext, policy: BindingPolicy) -> Bool {
        switch policy {
        case .accountIdentity:
            return matches(account, current.account)
        case .accountSession:
            return matches(account, current.account) && matches(accountRevision, current.accountRevision)
        case .accountAndRequest:
            return matches(account, current.account) && matches(mergeRequestID, current.mergeRequestID)
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
            return binds(to: current, policy: .feedbackProgress) && matches(discussionContent, current.discussionContent)
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
            return current.head != nil && matchesIfRecorded(head, current.head)
        }
    }

    private func matches<Value: Equatable>(_ recorded: Value?, _ current: Value?) -> Bool {
        recorded != nil && recorded == current
    }

    private func matchesIfRecorded<Value: Equatable>(_ recorded: Value?, _ current: Value?) -> Bool {
        recorded == nil || recorded == current
    }
}
