import Foundation

extension GlabService {
    func fetchMergeActionPolicy(projectID: Int, host: String, request: GitLabMergeRequest? = nil) async throws -> GitLabMergeActionPolicy {
        struct Project: Decodable {
            let mergeTrainsEnabled: Bool?
            let requiresResolution: Bool?
            let resetsApprovals: Bool?
            enum CodingKeys: String, CodingKey {
                case mergeTrainsEnabled = "merge_trains_enabled"
                case requiresResolution = "only_allow_merge_if_all_discussions_are_resolved"
                case resetsApprovals = "reset_approvals_on_push"
            }
        }
        let project: Project = try await mergeRequestAPI("/projects/\(projectID)", host: host)
        let usesTrain = project.mergeTrainsEnabled == true
        let waitsForPipeline = request.map { $0.isReadyForMergeSubmission(.enqueue) && !$0.isReadyForMergeSubmission(.mergeNow) } == true
        var action: MergeSubmissionAction?
        if project.mergeTrainsEnabled == false, !waitsForPipeline { action = .mergeNow }
        if usesTrain || project.mergeTrainsEnabled == false && waitsForPipeline {
            struct Version: Decodable { let version: String }
            let server: Version = try await mergeRequestAPI("/version", host: host)
            let parts = server.version.split(separator: ".")
            if parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]),
               major > 17 || major == 17 && minor >= 11 { action = .enqueue }
        }
        var reset = project.resetsApprovals
        if reset == nil { reset = try? await projectResetsApprovalsOnPush(projectID: projectID, host: host) }
        return .init(action: action, requiresResolvedDiscussions: project.requiresResolution,
                     resetsApprovalsOnPush: reset, usesMergeTrain: usesTrain)
    }

    func observedMergeSubmission(_ request: GitLabMergeRequest, action: MergeSubmissionAction,
                                 host: String, usesMergeTrain: Bool = true) async throws -> MergeSubmissionState {
        if request.state == "merged" { return .merged }
        guard request.state == "opened" else { return .changed }
        if action == .enqueue, usesMergeTrain,
           try await fetchActiveMergeTrainIIDs(projectID: request.projectID, host: host).contains(request.iid) { return .inTrain }
        return request.hasQueuedMerge ? .queued : .none
    }
}
