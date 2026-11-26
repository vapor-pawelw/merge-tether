import Foundation

/// The reviewed diff's target, captured by the app from its own live read when it seals a review completion.
/// A head SHA alone does not identify a diff: retargeting an MR changes what an approval covers.
struct ReviewTargetBinding: Codable, Equatable, Sendable {
    let targetProjectID: Int
    let targetBranch: String
    let baseSHA: String
    let headSHA: String

    var evidenceContext: EvidenceContext {
        .init(head: headSHA, target: .init(projectID: targetProjectID, branch: targetBranch, base: baseSHA))
    }

    /// Requires a single-MR read whose diff refs describe the current head.
    init?(_ request: GitLabMergeRequest) {
        guard let head = request.sha, let target = request.evidenceTarget else { return nil }
        self.targetProjectID = target.projectID
        self.targetBranch = target.branch
        self.baseSHA = target.base
        self.headSHA = head
    }
}

/// Automatic approval requires a verdict for the diff target the app reads from GitLab.
enum AutomaticApprovalGate {
    enum Refusal: Equatable, Sendable {
        /// The sealed review predates target binding or was captured without diff refs.
        case reviewTargetUnbound
        case targetChanged
    }

    static func refusal(for request: GitLabMergeRequest, head: String,
                        reviewed: ReviewTargetBinding?) -> Refusal? {
        guard let reviewed else { return .reviewTargetUnbound }
        guard let current = ReviewTargetBinding(request), current.headSHA == head,
              reviewed.evidenceContext.binds(to: current.evidenceContext, policy: .approvalTarget) else { return .targetChanged }
        return nil
    }

    static func permits(_ request: GitLabMergeRequest, head: String, reviewed: ReviewTargetBinding?) -> Bool {
        refusal(for: request, head: head, reviewed: reviewed) == nil
    }
}
