import Foundation
import Observation

@MainActor @Observable
final class MRDiscussionStore {
    enum IdentityError: Error { case accountChanged }
    typealias Load = @MainActor (MRDiscussionTarget) async throws -> [GitLabMergeRequestDiscussion]
    typealias VerifyAssistant = @MainActor (Int, String) async throws -> Bool
    private let load: Load?
    private let verifyAssistant: VerifyAssistant?
    private let assessmentDirectory: URL
    private let provenanceDirectory: URL
    private var generation = 0
    private(set) var target: MRDiscussionTarget?
    private(set) var discussions: [GitLabMergeRequestDiscussion] = []
    private(set) var origins: [Int: MRDiscussionSnapshot.Origin] = [:]
    private(set) var isLoading = false
    private(set) var hasError = false
    private(set) var hasLoaded = false

    init(load: Load? = nil, verifyAssistant: VerifyAssistant? = nil,
         assessmentDirectory: URL = AICommentAssessmentStore.directory,
         provenanceDirectory: URL = AICommentProvenanceStore.directory) {
        self.load = load
        self.verifyAssistant = verifyAssistant
        self.assessmentDirectory = assessmentDirectory
        self.provenanceDirectory = provenanceDirectory
    }

    func refresh(target requested: MRDiscussionTarget, glab: GlabService) async {
        guard matchesAccount(requested, glab: glab) else { clear(); return }
        guard target != requested || !isLoading else { return }
        if target != requested { clear(); target = requested }
        generation += 1
        let current = generation
        let revision = glab.accountRevision
        isLoading = true
        hasError = false
        defer { if generation == current { isLoading = false } }
        do {
            let result: [GitLabMergeRequestDiscussion]
            let authenticatedUserID: Int?
            if let load { result = try await load(requested); authenticatedUserID = nil }
            else {
                let user: GitLabAuthenticatedUser = try await glab.mergeRequestAPI("/user", host: requested.host)
                guard user.id > 0, !user.username.isEmpty else { throw GlabError.notAuthenticated }
                guard user.username == requested.username else { throw IdentityError.accountChanged }
                authenticatedUserID = user.id
                guard isCurrent(current, target: requested, glab: glab, revision: revision) else { return }
                result = try await glab.fetchMergeRequestDiscussions(projectID: requested.projectID,
                    iid: requested.iid, host: requested.host)
            }
            guard isCurrent(current, target: requested, glab: glab, revision: revision) else { return }
            let directory = assessmentDirectory
            let provenanceDirectory = self.provenanceDirectory
            var assessed = await Task.detached {
                let generated = authenticatedUserID.map { userID in
                    AICommentProvenanceStore.snapshot(context: .init(host: requested.host, username: requested.username,
                        userID: userID, projectID: requested.projectID, iid: requested.iid), in: provenanceDirectory)
                }
                var origins: [Int: MRDiscussionSnapshot.Origin] = [:]
                for thread in result {
                    for note in thread.notes where note.system != true {
                        if let id = note.id, generated?.contains(note, discussionID: thread.id) == true {
                            origins[id] = .appGenerated
                            continue
                        }
                        if let id = note.id, id > 0, let record = AICommentAssessmentStore.result(for: note,
                            host: requested.host, projectID: requested.projectID, iid: requested.iid, in: directory),
                           record.username == nil || record.username == requested.username {
                            if record.qualifiesAsAI {
                                origins[id] = .assessed(evidence: record.evidence)
                            } else if record.criteriaVersion == AICommentOriginAssessor.criteriaVersion {
                                origins[id] = record.classification == "manual_likely" && record.confidence != "uncertain"
                                    ? .humanLikely(evidence: record.evidence) : .uncertain(evidence: record.evidence)
                            }
                        }
                    }
                }
                return origins
            }.value
            guard isCurrent(current, target: requested, glab: glab, revision: revision) else { return }
            // A username is only a lookup hint. GitLab must confirm this is its assistant account.
            let candidates = Set(result.flatMap(\.notes).compactMap { note -> Int? in
                guard note.system != true, note.author?.username?.lowercased() == "gitlabduo",
                      let id = note.author?.id, id > 0 else { return nil }
                return id
            })
            for id in candidates {
                let verified: Bool
                if let verifyAssistant { verified = (try? await verifyAssistant(id, requested.host)) == true }
                else { verified = (try? await glab.isGitLabDuo(userID: id, host: requested.host)) == true }
                guard isCurrent(current, target: requested, glab: glab, revision: revision) else { return }
                if verified {
                    for note in result.flatMap(\.notes) where note.system != true && note.author?.id == id {
                        if let noteID = note.id { assessed[noteID] = .verifiedAssistant }
                    }
                }
            }
            discussions = result
            origins = assessed
            hasLoaded = true
        } catch {
            guard isCurrent(current, target: requested, glab: glab, revision: revision) else { return }
            // A 401 cannot prove the account changed. Keep its readable cache;
            // discard it only after the server actually identifies another user.
            if error is IdentityError {
                discussions = []
                origins = [:]
                hasLoaded = false
            }
            hasError = true
        }
    }

    func cancel() { generation += 1; isLoading = false }

    func clear() {
        cancel()
        target = nil
        discussions = []
        origins = [:]
        hasError = false
        hasLoaded = false
    }

    private func matchesAccount(_ target: MRDiscussionTarget, glab: GlabService) -> Bool {
        glab.resolvedHost == target.host && glab.currentUsername == target.username
            && !target.username.isEmpty && target.projectID > 0 && target.iid > 0
            && target.url.isGitLabMergeRequest(host: target.host, iid: target.iid)
    }

    private func isCurrent(_ current: Int, target: MRDiscussionTarget, glab: GlabService, revision: UInt64) -> Bool {
        guard generation == current, self.target == target else { return false }
        guard matchesAccount(target, glab: glab), glab.accountRevision == revision else { clear(); return false }
        return !Task.isCancelled
    }
}
