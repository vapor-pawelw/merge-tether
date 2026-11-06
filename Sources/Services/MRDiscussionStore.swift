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
    private var generation = 0
    private(set) var target: MRDiscussionTarget?
    private(set) var discussions: [GitLabMergeRequestDiscussion] = []
    private(set) var origins: [Int: MRDiscussionSnapshot.Origin] = [:]
    private(set) var isLoading = false
    private(set) var hasError = false
    private(set) var hasLoaded = false

    init(load: Load? = nil, verifyAssistant: VerifyAssistant? = nil,
         assessmentDirectory: URL = AICommentAssessmentStore.directory) {
        self.load = load
        self.verifyAssistant = verifyAssistant
        self.assessmentDirectory = assessmentDirectory
    }

    func refresh(target requested: MRDiscussionTarget, glab: GlabService) async {
        guard matchesAccount(requested, glab: glab) else { clear(); return }
        guard target != requested || !isLoading else { return }
        if target != requested { clear(); target = requested }
        generation += 1
        let current = generation
        isLoading = true
        hasError = false
        defer { if generation == current { isLoading = false } }
        do {
            let result: [GitLabMergeRequestDiscussion]
            if let load { result = try await load(requested) }
            else {
                let user: GitLabAuthenticatedUser = try await glab.mergeRequestAPI("/user", host: requested.host)
                guard user.id > 0, !user.username.isEmpty else { throw GlabError.notAuthenticated }
                guard user.username == requested.username else { throw IdentityError.accountChanged }
                guard isCurrent(current, target: requested, glab: glab) else { return }
                result = try await glab.fetchMergeRequestDiscussions(projectID: requested.projectID,
                    iid: requested.iid, host: requested.host)
            }
            guard isCurrent(current, target: requested, glab: glab) else { return }
            let directory = assessmentDirectory
            var assessed = await Task.detached {
                var origins: [Int: MRDiscussionSnapshot.Origin] = [:]
                for note in result.flatMap(\.notes) where note.system != true {
                    if let id = note.id, let record = AICommentAssessmentStore.assessment(for: note,
                        host: requested.host, projectID: requested.projectID, iid: requested.iid, in: directory) {
                        origins[id] = .assessed(evidence: record.evidence)
                    }
                }
                return origins
            }.value
            guard isCurrent(current, target: requested, glab: glab) else { return }
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
                guard isCurrent(current, target: requested, glab: glab) else { return }
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
            guard isCurrent(current, target: requested, glab: glab) else { return }
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

    private func isCurrent(_ current: Int, target: MRDiscussionTarget, glab: GlabService) -> Bool {
        guard generation == current, self.target == target else { return false }
        guard matchesAccount(target, glab: glab) else { clear(); return false }
        return !Task.isCancelled
    }
}
