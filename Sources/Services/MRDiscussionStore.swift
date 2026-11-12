import Foundation
import Observation

private final class FeedbackAccountKindObservation: Sendable {
    let source: GlabService
    let token: UUID

    init(source: GlabService, token: UUID) { self.source = source; self.token = token }

    @MainActor func cancel() { source.removeFeedbackAccountObserver(token) }

    deinit {
        let source = source, token = token
        Task { @MainActor in source.removeFeedbackAccountObserver(token) }
    }
}

@MainActor @Observable
final class MRDiscussionStore {
    enum IdentityError: Error { case accountChanged }
    typealias Load = @MainActor (MRDiscussionTarget) async throws -> [GitLabMergeRequestDiscussion]
    typealias VerifyAssistant = @MainActor (Int, String) async throws -> Bool
    typealias VerifyAuthorKind = @MainActor (Int, String) async throws -> AuthorFeedbackPolicy.AccountKind
    private let load: Load?
    private let verifyAssistant: VerifyAssistant?
    private let verifyAuthorKind: VerifyAuthorKind?
    @ObservationIgnored private var authorKindObservation: FeedbackAccountKindObservation?
    @ObservationIgnored private(set) var authorKindTask: Task<Void, Never>?
    private var authorKindVersions: [Int: UInt64] = [:]
    private let assessmentDirectory: URL
    private let legacyAssessmentDirectory: URL?
    private let displayAssessmentDirectory: URL?
    private let provenanceDirectory: URL
    private var authenticatedUserID: Int?
    private var loadedRevision: UInt64?
    private var generation = 0
    private(set) var target: MRDiscussionTarget?
    private(set) var discussions: [GitLabMergeRequestDiscussion] = []
    private(set) var origins: [Int: MRDiscussionSnapshot.Origin] = [:]
    private(set) var authorKinds: [Int: AuthorFeedbackPolicy.AccountKind] = [:]
    private(set) var isLoading = false
    private(set) var hasError = false
    private(set) var hasLoaded = false

    init(load: Load? = nil, verifyAssistant: VerifyAssistant? = nil, verifyAuthorKind: VerifyAuthorKind? = nil,
         assessmentDirectory: URL = AICommentAssessmentStore.directory,
         provenanceDirectory: URL = AICommentProvenanceStore.directory, legacyAssessmentDirectory: URL? = nil,
         displayAssessmentDirectory: URL? = nil) {
        self.load = load
        self.verifyAssistant = verifyAssistant
        self.verifyAuthorKind = verifyAuthorKind
        self.assessmentDirectory = assessmentDirectory
        self.legacyAssessmentDirectory = legacyAssessmentDirectory
        self.displayAssessmentDirectory = displayAssessmentDirectory
        self.provenanceDirectory = provenanceDirectory
    }

    func refresh(target requested: MRDiscussionTarget, glab: GlabService) async {
        guard matchesAccount(requested, glab: glab) else { clear(); return }
        guard target != requested || !isLoading else { return }
        if target != requested { clear(); target = requested }
        observeAuthorKinds(glab)
        authorKindTask?.cancel(); authorKindTask = nil
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
            var assessed = await cachedOrigins(in: result, target: requested, userID: authenticatedUserID)
            guard isCurrent(current, target: requested, glab: glab, revision: revision) else { return }
            var verifiedAssistantIDs: Set<Int> = []
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
                    verifiedAssistantIDs.insert(id)
                    for note in result.flatMap(\.notes) where note.system != true && note.author?.id == id {
                        if let noteID = note.id { assessed[noteID] = .verifiedAssistant }
                    }
                }
            }
            let authors = Set(result.flatMap(\.notes).filter { $0.system != true }.compactMap { $0.author?.id })
            var kinds = loadedRevision == revision ? authorKinds.filter { authors.contains($0.key) } : [:]
            for id in authors where id > 0 {
                let cached: AuthorFeedbackPolicy.AccountKind = verifiedAssistantIDs.contains(id) ? .automation : kinds[id] ?? .unknown
                let effective = glab.feedbackDisplayAccountKind(userID: id, kind: cached, host: requested.host, username: requested.username)
                if effective != .unknown || kinds[id] != nil { kinds[id] = effective }
            }
            self.authenticatedUserID = authenticatedUserID
            loadedRevision = revision
            discussions = result
            origins = assessed
            authorKinds = kinds
            hasLoaded = true
            if load == nil || verifyAuthorKind != nil {
                enrichAuthorKinds(in: result, current: current, target: requested, glab: glab, revision: revision)
            }
        } catch {
            guard isCurrent(current, target: requested, glab: glab, revision: revision) else { return }
            // A 401 cannot prove the account changed. Keep its readable cache;
            // discard it only after the server actually identifies another user.
            if error is IdentityError {
                self.authenticatedUserID = nil
                loadedRevision = nil
                discussions = []
                origins = [:]
                authorKinds = [:]
                hasLoaded = false
            }
            hasError = true
        }
    }

    func reloadOrigins(glab: GlabService) async {
        guard let target, hasLoaded, loadedRevision == glab.accountRevision, matchesAccount(target, glab: glab) else { return }
        let current = generation, revision = glab.accountRevision
        var updated = await cachedOrigins(in: discussions, target: target, userID: authenticatedUserID)
        guard isCurrent(current, target: target, glab: glab, revision: revision) else { return }
        for (id, origin) in origins where origin == .verifiedAssistant { updated[id] = origin }
        origins = updated
    }

    private func cachedOrigins(in result: [GitLabMergeRequestDiscussion], target: MRDiscussionTarget,
                               userID: Int?) async -> [Int: MRDiscussionSnapshot.Origin] {
        let directory = assessmentDirectory
        let legacyDirectory = legacyAssessmentDirectory
        let displayDirectory = displayAssessmentDirectory
        let provenanceDirectory = self.provenanceDirectory
        return await Task.detached {
            let generated = userID.map { userID in
                AICommentProvenanceStore.snapshot(context: .init(host: target.host, username: target.username,
                    userID: userID, projectID: target.projectID, iid: target.iid), in: provenanceDirectory)
            }
            var origins: [Int: MRDiscussionSnapshot.Origin] = [:]
            for thread in result {
                for note in thread.notes where note.system != true {
                    if let id = note.id, generated?.contains(note, discussionID: thread.id) == true {
                        origins[id] = .appGenerated
                        continue
                    }
                    if let id = note.id, id > 0, let record = AICommentAssessmentStore.displayResult(for: note,
                        host: target.host, projectID: target.projectID, iid: target.iid,
                        username: target.username, in: directory, legacyDirectory: legacyDirectory, displayDirectory: displayDirectory),
                       record.username == nil || record.username == target.username {
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
    }

    func cancel() {
        generation += 1; isLoading = false
        authorKindTask?.cancel(); authorKindTask = nil
        authorKindObservation?.cancel(); authorKindObservation = nil
    }

    private func observeAuthorKinds(_ glab: GlabService) {
        guard authorKindObservation?.source !== glab else { return }
        authorKindObservation?.cancel()
        authorKindVersions = [:]
        let token = glab.observeFeedbackAccountKinds { [weak self] event in
            guard let self, let target, hasLoaded, loadedRevision == event.accountRevision,
                  target.host == event.host, target.username == event.username,
                  event.revision > authorKindVersions[event.userID, default: 0],
                  discussions.flatMap(\.notes).contains(where: { $0.author?.id == event.userID }) else { return }
            authorKinds[event.userID] = event.kind
            authorKindVersions[event.userID] = event.revision
        }
        authorKindObservation = FeedbackAccountKindObservation(source: glab, token: token)
    }

    private func enrichAuthorKinds(in notes: [GitLabMergeRequestDiscussion], current: Int, target: MRDiscussionTarget,
                                   glab: GlabService, revision: UInt64) {
        let ids = Array(Set(notes.flatMap(\.notes).compactMap { note in
            note.system != true ? (note.author?.id).flatMap { $0 > 0 ? $0 : nil } : nil
        }).sorted().prefix(64))
        authorKindTask = Task { [self] in
            defer { if generation == current { authorKindTask = nil } }
            for start in stride(from: 0, to: ids.count, by: 4) {
                guard isCurrent(current, target: target, glab: glab, revision: revision) else { return }
                let versions = authorKindVersions
                let batch = ids[start..<min(start + 4, ids.count)]
                let values = await withTaskGroup(of: (Int, AuthorFeedbackPolicy.AccountKind).self) { group in
                    for id in batch {
                        group.addTask { [self] in
                            (id, await readAuthorKind(id, current: current, target: target, glab: glab, revision: revision))
                        }
                    }
                    var values: [(Int, AuthorFeedbackPolicy.AccountKind)] = []
                    for await value in group { values.append(value) }
                    return values
                }
                guard isCurrent(current, target: target, glab: glab, revision: revision) else { return }
                for (id, kind) in values where versions[id, default: 0] == authorKindVersions[id, default: 0] {
                    authorKinds[id] = glab.feedbackDisplayAccountKind(userID: id, kind: kind, host: target.host, username: target.username)
                }
            }
        }
    }

    private func readAuthorKind(_ id: Int, current: Int, target: MRDiscussionTarget,
                                glab: GlabService, revision: UInt64) async -> AuthorFeedbackPolicy.AccountKind {
        guard isCurrent(current, target: target, glab: glab, revision: revision) else { return .unknown }
        if let verifyAuthorKind { return (try? await verifyAuthorKind(id, target.host)) ?? .unknown }
        return (try? await glab.feedbackAccountKind(userID: id, host: target.host)) ?? .unknown
    }

    func clear() {
        cancel()
        target = nil
        authenticatedUserID = nil
        loadedRevision = nil
        discussions = []
        origins = [:]
        authorKinds = [:]
        authorKindVersions = [:]
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
