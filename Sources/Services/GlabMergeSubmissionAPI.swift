import Foundation

extension GlabService {
    struct MergeTrainPreparationObservation {
        let latestNoteID: Int
        let conflict: MergeTrainPreparationConflict?
    }

    func fetchMergeTrainPreparationConflict(_ request: GitLabMergeRequest, host: String) async throws -> MergeTrainPreparationConflict? {
        try await fetchMergeTrainPreparation(request, host: host).conflict
    }

    func fetchMergeTrainPreparation(_ request: GitLabMergeRequest, host: String) async throws -> MergeTrainPreparationObservation {
        guard request.state == "opened", !request.hasQueuedMerge,
              request.webURL.isGitLabMergeRequest(host: host, iid: request.iid) else {
            return .init(latestNoteID: 0, conflict: nil)
        }
        let discussions = try await fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
        let latestNoteID = discussions.flatMap(\.notes).compactMap(\.id).max() ?? 0
        func observation(_ conflict: MergeTrainPreparationConflict? = nil) -> MergeTrainPreparationObservation {
            .init(latestNoteID: latestNoteID, conflict: conflict)
        }
        guard let conflict = MergeTrainPreparationConflict.latest(in: discussions, for: request) else { return observation() }
        guard try await fetchActiveMergeTrainIIDs(projectID: request.projectID, host: host).contains(request.iid) == false else { return observation() }
        guard let project = request.targetProjectID else { throw GlabError.decoding("GitLab did not provide the merge train target project") }
        // A train base can be a synthetic result including other MRs. Only the actual
        // current target branch is evidence for this branch's conflict repair permission.
        let target = try await fetchBranchHeadSHA(projectID: project, branch: request.targetBranch, host: host)
        return observation(target == conflict.targetSHA ? conflict : nil)
    }

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
