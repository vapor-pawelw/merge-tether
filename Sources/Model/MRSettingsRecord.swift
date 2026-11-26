import Foundation

/// GitLab project and MR numbers are host-local. Account names or numeric user IDs
/// stay on the individual entries so old receipts keep their original binding.
struct MRSettingsKey: Codable, Hashable {
    let host: String
    let request: GitLabMergeRequestID

    init?(host: String, projectID: Int, iid: Int?) {
        guard !host.isEmpty, projectID > 0, let iid, iid > 0 else { return nil }
        self.host = host
        self.request = .init(projectID: projectID, iid: iid)
    }

    init?(_ target: MRAutomationScope.Target) {
        self.init(host: target.host, projectID: target.projectID, iid: target.iid)
    }
}

struct MRSettingsRecord: Codable {
    typealias Target = MRAutomationScope.Target

    struct Scoped<Value: Codable>: Codable {
        let target: Target
        let value: Value
    }

    struct Ordered<Value: Codable>: Codable {
        let position: Int
        let value: Value
    }

    struct ActionOptIn: Codable {
        let action: MRAutomaticAction
        let target: Target
    }

    struct Hide: Codable {
        let target: Target
        let detail: HiddenReview?
    }

    struct ReviewReceipt: Codable {
        let key: ReReviewReceipt.Key
        let value: ReReviewReceipt
    }

    struct ReviewerApproval: Codable {
        let user: GitLabAuthenticatedUser
        let baseline: ReviewApprovalBaseline
    }

    var autoApproveOptOuts: [Target]?
    var independentApprovalPreferences: [Scoped<MRAutomationPreference>]?
    var autoPublishOptOuts: [Target]?
    var autoMergeOptOuts: [Target]?
    var autoMergeOptIns: [Target]?
    var automaticActionOptIns: [ActionOptIn]?
    var mergeSubmissions: [Ordered<MergeSubmissionReceipt>]?
    var hiddenReviews: [Hide]?
    var newReviewTargets: [Target]?
    var newReviewGenerations: [Scoped<UUID>]?
    var heldNewReviewTargets: [Target]?
    var automationReceipts: [TodoAutomationReceipt]?
    var automationAttemptReceipts: [TodoAutomationReceipt]?
    var pendingTodoAcknowledgements: [TodoActionAcknowledgement]?
    var authorFeedbackAttempts: [AuthorFeedbackAttempt]?
    var assistantAutomaticRetryAttempts: [Ordered<AssistantAutomaticRetryAttempt>]?
    var pipelineRefreshAttempts: [PipelineRefreshAttempt]?
    var pipelineClaimAssessmentAttempts: [Ordered<PipelineClaimAssessmentAttempt>]?
    var conflictReceipts: [MergeConflictReceipt]?
    var reReviewReceipts: [ReviewReceipt]?
    var reReviewDraftBaselines: [Scoped<Int>]?
    var assistantHandoffs: [Ordered<AssistantAutomationRunner.Handoff>]?
    var workflowActivity: [Ordered<MergeWorkflowActivityEntry>]?
    var automationEvents: [Ordered<MRAutomationEvent>]?
    var mrActionIntents: [Ordered<MRTodoIntent>]?
    var routedMRTodoReceipts: [MRTodoRouteReceipt]?
    var boardPins: [BoardCardPin]?
    var pendingCommentReviews: [Target]?
    var commentReviewProgress: [Scoped<SettingsManager.CommentReviewProgress>]?
    var reviewerApprovals: [ReviewerApproval]?

    var isEmpty: Bool {
        autoApproveOptOuts == nil && independentApprovalPreferences == nil && autoPublishOptOuts == nil
            && autoMergeOptOuts == nil && autoMergeOptIns == nil && automaticActionOptIns == nil
            && mergeSubmissions == nil && hiddenReviews == nil && newReviewTargets == nil
            && newReviewGenerations == nil && heldNewReviewTargets == nil
            && automationReceipts == nil && automationAttemptReceipts == nil && pendingTodoAcknowledgements == nil
            && authorFeedbackAttempts == nil
            && assistantAutomaticRetryAttempts == nil && pipelineRefreshAttempts == nil
            && pipelineClaimAssessmentAttempts == nil && conflictReceipts == nil && reReviewReceipts == nil
            && reReviewDraftBaselines == nil && assistantHandoffs == nil && workflowActivity == nil
            && automationEvents == nil && mrActionIntents == nil && routedMRTodoReceipts == nil
            && boardPins == nil && pendingCommentReviews == nil && commentReviewProgress == nil && reviewerApprovals == nil
    }
}

struct MRSettingsArchive: Codable {
    private let version: Int
    private(set) var records: [MRSettingsKey: MRSettingsRecord] = [:]
    /// Unmatched legacy to-dos, repository preferences and pins for other card kinds.
    private var unscoped = MRSettingsRecord()
    var emptyActionOptIns: Set<MRAutomaticAction>?
    var mirrorFingerprints: [String: Data] = [:]

    private enum CodingKeys: String, CodingKey {
        case version, records, unscoped, emptyActionOptIns, mirrorFingerprints
    }

    init() { version = 1 }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported MR settings version")
        }
        records = try values.decode([MRSettingsKey: MRSettingsRecord].self, forKey: .records)
        unscoped = try values.decode(MRSettingsRecord.self, forKey: .unscoped)
        emptyActionOptIns = try values.decodeIfPresent(Set<MRAutomaticAction>.self, forKey: .emptyActionOptIns)
        mirrorFingerprints = try values.decode([String: Data].self, forKey: .mirrorFingerprints)
    }

    func values<Value>(_ field: KeyPath<MRSettingsRecord, [Value]?>) -> [Value] {
        records.values.flatMap { $0[keyPath: field] ?? [] } + (unscoped[keyPath: field] ?? [])
    }

    mutating func setReviewerApprovals(_ values: [MRSettingsRecord.ReviewerApproval], for key: MRSettingsKey) {
        records[key, default: .init()].reviewerApprovals = values.isEmpty ? nil : values
    }

    mutating func replace<Value>(_ field: WritableKeyPath<MRSettingsRecord, [Value]?>, with values: [Value],
                                 keyedBy key: (Value) -> MRSettingsKey?) {
        let groups = Dictionary(grouping: values, by: key)
        for id in Set(records.keys).union(groups.keys.compactMap { $0 }) {
            records[id, default: .init()][keyPath: field] = groups[id]
        }
        unscoped[keyPath: field] = groups[nil]
    }

    mutating func discardEmptyRecords() {
        records = records.filter { !$0.value.isEmpty }
    }
}
