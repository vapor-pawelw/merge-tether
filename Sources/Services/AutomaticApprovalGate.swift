import Foundation

/// The reviewed diff's target, captured by the app from its own live read when it seals a review completion.
/// A head SHA alone does not identify a diff: retargeting an MR changes what an approval covers.
struct ReviewTargetBinding: Codable, Equatable, Sendable {
    let targetProjectID: Int
    let targetBranch: String
    let baseSHA: String
    let headSHA: String

    /// Requires a single-MR read whose diff refs describe the current head.
    init?(_ request: GitLabMergeRequest) {
        guard let head = request.sha, !head.isEmpty,
              let targetProjectID = request.targetProjectID, targetProjectID > 0,
              !request.targetBranch.isEmpty,
              let refs = request.diffRefs, refs.headSHA == head,
              let base = refs.baseSHA, !base.isEmpty else { return nil }
        self.targetProjectID = targetProjectID
        self.targetBranch = request.targetBranch
        self.baseSHA = base
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
        guard reviewed.headSHA == head, ReviewTargetBinding(request) == reviewed else { return .targetChanged }
        return nil
    }

    static func permits(_ request: GitLabMergeRequest, head: String, reviewed: ReviewTargetBinding?) -> Bool {
        refusal(for: request, head: head, reviewed: reviewed) == nil
    }
}
