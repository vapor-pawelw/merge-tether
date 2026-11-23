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

/// Deterministic preconditions for automatic approval that a model-produced verdict cannot satisfy.
/// They are checked by the app against its own fresh GitLab reads, independently of the verdict.
enum AutomaticApprovalGate {
    /// Larger changes always wait for a person, whatever the review verdict says.
    static let maximumChangedFiles = 50

    enum Refusal: Equatable, Sendable {
        /// The sealed review predates target binding or was captured without diff refs.
        case reviewTargetUnbound
        case targetChanged
        case pipelineNotPassed
        case changeSizeUnknown
        case changeTooLarge
    }

    static func refusal(for request: GitLabMergeRequest, head: String,
                        reviewed: ReviewTargetBinding?) -> Refusal? {
        guard let reviewed else { return .reviewTargetUnbound }
        guard reviewed.headSHA == head, ReviewTargetBinding(request) == reviewed else { return .targetChanged }
        guard let pipeline = request.headPipeline, pipeline.status == "success", pipeline.sha == head
        else { return .pipelineNotPassed }
        guard let count = request.changesCount.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), count >= 0
        else { return .changeSizeUnknown }
        return count > maximumChangedFiles ? .changeTooLarge : nil
    }

    static func permits(_ request: GitLabMergeRequest, head: String, reviewed: ReviewTargetBinding?) -> Bool {
        refusal(for: request, head: head, reviewed: reviewed) == nil
    }
}
