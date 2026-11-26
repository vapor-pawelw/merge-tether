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
        guard request.isOpen, !request.hasQueuedMerge,
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
        return observation(EvidenceContext.sameHead(conflict.targetSHA, target) ? conflict : nil)
    }

    func verifyFailedTrainPipeline(_ receipt: MergeSubmissionReceipt, replacement: GitLabMergeRequest,
                                   activeQueue: Bool, host: String) async throws -> Set<Int>? {
        guard let baseline = receipt.trainNoteIDBeforeAttempt else { return nil }
        let discussions = try await fetchMergeRequestDiscussions(projectID: replacement.projectID, iid: replacement.iid, host: host)
        let notes = discussions.flatMap(\.notes)
        let trainEvents = notes.filter { note in
            guard note.system == true, (note.id ?? 0) > baseline, let body = note.body else { return false }
            return Self.isTrainAdmission(body) || body.hasPrefix("removed this merge request from the merge train")
                || body.hasPrefix(Self.trainAutoAddNote) || body.hasPrefix("canceled the automatic merge")
        }.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        let automaticallyAdmitted = trainEvents.first?.body?.hasPrefix(Self.trainAutoAddNote) == true
            && trainEvents.first?.author?.id == receipt.userID
        let lifecycle = trainEvents.dropFirst(automaticallyAdmitted ? 1 : 0)
        guard activeQueue || lifecycle.count == 2,
              let admission = lifecycle.first, let removal = lifecycle.dropFirst().first else { return nil }
        guard admission.body.map(Self.isTrainAdmission) == true,
              removal.body?.hasPrefix("removed this merge request from the merge train because the pipeline did not succeed.") == true,
              admission.author?.id == receipt.userID, removal.author?.id == receipt.userID,
              let admittedAt = MergeRequestReviewHistory.date(admission.createdAt),
              let removedAt = MergeRequestReviewHistory.date(removal.createdAt), removedAt > admittedAt else { return nil }

        struct TrainPipeline: Decodable {
            let id: Int
            let projectID: Int
            let ref: String
            let status: GitLabPipelineStatus
            let createdAt: String
            let updatedAt: String
            enum CodingKeys: String, CodingKey {
                case id, ref, status
                case projectID = "project_id"
                case createdAt = "created_at"
                case updatedAt = "updated_at"
            }
        }
        let mrPath = "/projects/\(replacement.projectID)/merge_requests/\(replacement.iid)"
        let pipelines: [TrainPipeline] = try await mergeRequestAPI(
            "\(mrPath)/pipelines?per_page=100", host: host, arguments: ["--paginate"], timeout: 45,
            decode: { try GlabPaginatedJSON.decode(TrainPipeline.self, from: $0) }
        )
        let trainRef = "refs/merge-requests/\(replacement.iid)/train"
        let trainPipelines = pipelines.filter {
            guard $0.projectID == replacement.projectID, $0.ref == trainRef,
                  let created = MergeRequestReviewHistory.date($0.createdAt) else { return false }
            return created >= admittedAt && created <= removedAt
        }
        guard let failed = trainPipelines.max(by: { $0.id < $1.id }), failed.status == .failed,
              let finishedAt = MergeRequestReviewHistory.date(failed.updatedAt), finishedAt <= removedAt else { return nil }

        // A source update drops the car from GitLab's train. Bind the single
        // admission and removal to the source SHA in GitLab's diff history.
        struct Version: Decodable {
            let head: String
            let createdAt: String
            enum CodingKeys: String, CodingKey {
                case head = "head_commit_sha"
                case createdAt = "created_at"
            }
        }
        let versions: [Version] = try await mergeRequestAPI(
            "\(mrPath)/versions?per_page=100",
            host: host, arguments: ["--paginate"], timeout: 45,
            decode: { try GlabPaginatedJSON.decode(Version.self, from: $0) }
        )
        let history = versions.compactMap { version in
            MergeRequestReviewHistory.date(version.createdAt).map { (head: version.head, date: $0) }
        }.sorted { $0.date < $1.date }
        guard history.count == versions.count,
              let previous = history.last(where: { $0.date <= admittedAt }), receipt.context.evidenceContext.binds(to: .init(head: previous.head), policy: .head),
              history.filter({ $0.date >= previous.date && $0.date <= removedAt }).allSatisfy({ EvidenceContext.sameHead(previous.head, $0.head) }),
              let current = history.last, current.date > removedAt, EvidenceContext.sameHead(replacement.sha, current.head) else { return nil }
        if activeQueue {
            guard let event = trainEvents.last, let body = event.body,
                  Self.isTrainAdmission(body) || body.hasPrefix(Self.trainAutoAddNote),
                  let queuedAt = MergeRequestReviewHistory.date(event.createdAt), queuedAt >= current.date else { return nil }
        }
        return Set(notes.compactMap(\.id))
    }

    private static let trainAutoAddNote = "enabled automatic add to merge train"

    private static func isTrainAdmission(_ body: String) -> Bool {
        body.hasPrefix("started a [merge train]") || body.hasPrefix("added this merge request to the merge train at position ")
    }

    func verifyReplacementPipeline(for request: GitLabMergeRequest, host: String) async throws -> GitLabMergeRequest.Pipeline {
        guard let head = request.headPipeline, head.status == .success, let id = head.id, id > 0,
              let project = head.projectID, project > 0, let sha = head.sha, Self.isFullGitSHA(sha),
              let source = request.sha else { throw CancellationError() }
        let pipeline: GitLabMergeRequest.Pipeline = try await mergeRequestAPI("/projects/\(project)/pipelines/\(id)", host: host)
        guard pipeline.status == .success, pipeline.id == id, pipeline.projectID == project, EvidenceContext.sameHead(sha, pipeline.sha),
              let ref = pipeline.ref, head.ref == nil || head.ref == ref else { throw CancellationError() }
        if ref == "refs/merge-requests/\(request.iid)/merge", project == request.targetProjectID {
            struct Commit: Decodable {
                let id: String
                let parentIDs: [String]
                enum CodingKeys: String, CodingKey { case id; case parentIDs = "parent_ids" }
            }
            let commit: Commit = try await mergeRequestAPI("/projects/\(project)/repository/commits/\(sha)", host: host)
            // GitLab creates the merge result with target first and source second.
            // The train builds a new pipeline against the target it will merge into.
            guard EvidenceContext.sameHead(sha, commit.id), commit.parentIDs.count == 2,
                  EvidenceContext.sameHead(source, commit.parentIDs.last),
                  let base = commit.parentIDs.first, !EvidenceContext.sameHead(source, base),
                  Self.isFullGitSHA(base) else { throw CancellationError() }
        } else {
            let sourceBranch = ref == request.sourceBranch && project == request.sourceProjectID
            let mrHead = ref == "refs/merge-requests/\(request.iid)/head"
                && (project == request.sourceProjectID || project == request.targetProjectID)
            guard EvidenceContext.sameHead(source, sha), sourceBranch || mrHead else { throw CancellationError() }
        }
        return pipeline
    }

    func fetchMergeActionPolicy(projectID: Int, host: String, request: GitLabMergeRequest? = nil) async throws -> GitLabMergeActionPolicy {
        struct Project: Decodable {
            let mergeTrainsEnabled: Bool?
            let requiresResolution: Bool?
            enum CodingKeys: String, CodingKey {
                case mergeTrainsEnabled = "merge_trains_enabled"
                case requiresResolution = "only_allow_merge_if_all_discussions_are_resolved"
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
        return .init(action: action, requiresResolvedDiscussions: project.requiresResolution, usesMergeTrain: usesTrain)
    }

    func observedMergeSubmission(_ request: GitLabMergeRequest, action: MergeSubmissionAction,
                                 host: String, usesMergeTrain: Bool = true) async throws -> MergeSubmissionState {
        if request.state == .merged { return .merged }
        guard request.isOpen else { return .changed }
        if action == .enqueue, usesMergeTrain,
           try await fetchActiveMergeTrainIIDs(projectID: request.projectID, host: host).contains(request.iid) { return .inTrain }
        return request.hasQueuedMerge ? .queued : .none
    }
}
