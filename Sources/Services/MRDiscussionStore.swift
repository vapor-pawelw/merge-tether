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

/// Callers that asked for a discussion read while an equivalent read was already in flight.
/// They share exactly one follow-up read, because the in-flight one may predate the change they observed.
@MainActor private final class MRDiscussionRefreshBatch {
    var glab: GlabService
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(glab: GlabService) { self.glab = glab }

    func wait() async { await withCheckedContinuation { waiters.append($0) } }

    func finish() {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }
}

@MainActor @Observable
final class MRDiscussionStore {
    enum IdentityError: Error { case accountChanged }
    typealias Load = @MainActor (MRDiscussionTarget) async throws -> [GitLabMergeRequestDiscussion]
    typealias VerifyAssistant = @MainActor (Int, String) async throws -> Bool
    typealias VerifyAuthorKind = @MainActor (Int, String) async throws -> AuthorFeedbackPolicy.AccountKind
    typealias LoadOrigins = @MainActor (MRDiscussionTarget, [GitLabMergeRequestDiscussion]) async
        -> ([Int: MRDiscussionSnapshot.Origin], AICommentProvenanceStore.ExtraContexts)
    private let load: Load?
    /// Test seam replacing the local origin and provenance reads; nil reads the configured directories.
    private let loadOrigins: LoadOrigins?
    private let verifyAssistant: VerifyAssistant?
    private let verifyAuthorKind: VerifyAuthorKind?
    @ObservationIgnored private var authorKindObservation: FeedbackAccountKindObservation?
    @ObservationIgnored private(set) var authorKindTask: Task<Void, Never>?
    private var authorKindVersions: [Int: UInt64] = [:]
    private let assessmentDirectory: URL
    private let legacyAssessmentDirectory: URL?
    private let displayAssessmentDirectory: URL?
    private let provenanceDirectory: URL
    private(set) var authenticatedUserID: Int?
    private(set) var currentUser: PersonIdentity?
    private var loadedRevision: UInt64?
    private var assessmentCriteria: String?
    private var generation = 0
    @ObservationIgnored private var queuedRefresh: MRDiscussionRefreshBatch?
    @ObservationIgnored private(set) var followUpTask: Task<Void, Never>?
    @ObservationIgnored private var followUpToken = 0
    /// Advances when an origin reload starts or a full read applies origins; only the latest result may apply.
    @ObservationIgnored private var originToken = 0
    @ObservationIgnored private(set) var originReloadTask: Task<Void, Never>?
    private(set) var target: MRDiscussionTarget?
    private var discussionContent: MRDiscussionContent?
    var discussions: [GitLabMergeRequestDiscussion] { discussionContent?.discussions ?? [] }
    var activity: [MRGitLabActivity] { discussionContent?.activity ?? [] }
    var discussionFingerprint: String? { discussionContent?.fingerprint }
    var activeDiscussionFingerprint: String? { discussionContent?.activeFingerprint }
    @ObservationIgnored private let presentation = MRDiscussionPresentation()
    private(set) var origins: [Int: MRDiscussionSnapshot.Origin] = [:]
    /// App-only agent explanations for drafts and published notes; never part of a GitLab write.
    private(set) var extraContexts: AICommentProvenanceStore.ExtraContexts = .empty
    private(set) var authorKinds: [Int: AuthorFeedbackPolicy.AccountKind] = [:]
    private(set) var isLoading = false
    private(set) var hasError = false
    private(set) var hasLoaded = false

    init(load: Load? = nil, verifyAssistant: VerifyAssistant? = nil, verifyAuthorKind: VerifyAuthorKind? = nil,
         assessmentDirectory: URL = AICommentAssessmentStore.directory,
         provenanceDirectory: URL = AICommentProvenanceStore.directory, legacyAssessmentDirectory: URL? = nil,
         displayAssessmentDirectory: URL? = nil, loadOrigins: LoadOrigins? = nil) {
        self.load = load
        self.loadOrigins = loadOrigins
        self.verifyAssistant = verifyAssistant
        self.verifyAuthorKind = verifyAuthorKind
        self.assessmentDirectory = assessmentDirectory
        self.legacyAssessmentDirectory = legacyAssessmentDirectory
        self.displayAssessmentDirectory = displayAssessmentDirectory
        self.provenanceDirectory = provenanceDirectory
    }

    /// Returns after a read issued no earlier than this call has finished, or after the request was
    /// superseded, cancelled or cleared. An equivalent read already in flight is followed by one shared read.
    func refresh(target requested: MRDiscussionTarget, glab: GlabService, criteriaOverride: String? = nil) async {
        guard matchesAccount(requested, glab: glab) else { clear(); return }
        if target == requested, assessmentCriteria == criteriaOverride, isLoading {
            let batch = queuedRefresh ?? MRDiscussionRefreshBatch(glab: glab)
            batch.glab = glab
            queuedRefresh = batch
            await batch.wait()
            return
        }
        if target != requested { clear(); target = requested }
        assessmentCriteria = criteriaOverride
        // A newer read for this target answers callers queued behind the read it supersedes.
        let superseded = queuedRefresh
        queuedRefresh = nil
        await read(target: requested, glab: glab, criteriaOverride: criteriaOverride)
        superseded?.finish()
    }

    private func read(target requested: MRDiscussionTarget, glab: GlabService, criteriaOverride: String?) async {
        observeAuthorKinds(glab)
        authorKindTask?.cancel(); authorKindTask = nil
        generation += 1
        let current = generation
        let revision = glab.accountRevision
        isLoading = true
        hasError = false
        defer {
            if generation == current {
                scheduleFollowUp(target: requested, criteriaOverride: criteriaOverride, revision: revision)
            }
        }
        do {
            let result: [GitLabMergeRequestDiscussion]
            let authenticatedUserID: Int?
            let currentUser: PersonIdentity?
            if let load { result = try await load(requested); authenticatedUserID = nil; currentUser = nil }
            else {
                let user: GitLabWorkflowUser = try await glab.mergeRequestAPI("/user", host: requested.host)
                guard user.id > 0, let username = user.username, !username.isEmpty else { throw GlabError.notAuthenticated }
                guard username == requested.username else { throw IdentityError.accountChanged }
                authenticatedUserID = user.id
                currentUser = user.person
                guard isCurrent(current, target: requested, glab: glab, revision: revision) else { return }
                result = try await glab.fetchMergeRequestDiscussions(projectID: requested.projectID,
                    iid: requested.iid, host: requested.host)
            }
            guard isCurrent(current, target: requested, glab: glab, revision: revision) else { return }
            let originsRequested = originToken
            let preparedContent = Task.detached { MRDiscussionContent(result) }
            let cached = await cachedOrigins(in: result, target: requested, userID: authenticatedUserID,
                criteriaOverride: criteriaOverride, glab: glab)
            let content = await preparedContent.value
            var assessed = cached.0
            let contexts = cached.1
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
                        if let noteID = note.id, assessed[noteID]?.isManual != true { assessed[noteID] = .verifiedAssistant }
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
            self.currentUser = currentUser
            loadedRevision = revision
            discussionContent = content
            // Origin reloads already running used the previous discussions and older local records; supersede
            // them. One that started after this read's origin lookup is repeated so its change is not lost.
            let missedOriginReload = originToken != originsRequested
            originToken += 1
            origins = assessed
            extraContexts = contexts
            authorKinds = kinds
            hasLoaded = true
            if load == nil || verifyAuthorKind != nil {
                enrichAuthorKinds(in: result, current: current, target: requested, glab: glab, revision: revision)
            }
            if missedOriginReload { scheduleOriginReload(glab: glab) }
        } catch {
            guard isCurrent(current, target: requested, glab: glab, revision: revision) else { return }
            // A 401 cannot prove the account changed. Keep its readable cache;
            // discard it only after the server actually identifies another user.
            if error is IdentityError {
                self.authenticatedUserID = nil
                currentUser = nil
                loadedRevision = nil
                discussionContent = nil
                origins = [:]
                extraContexts = .empty
                authorKinds = [:]
                hasLoaded = false
            }
            hasError = true
        }
    }

    /// Starts the one store-owned origin reload, cancelling an older one so it cannot apply.
    func scheduleOriginReload(glab: GlabService) {
        originReloadTask?.cancel()
        originReloadTask = Task { [self] in await reloadOrigins(glab: glab) }
    }

    func reloadOrigins(glab: GlabService) async {
        guard !Task.isCancelled, let target, hasLoaded, loadedRevision == glab.accountRevision,
              matchesAccount(target, glab: glab) else { return }
        originToken += 1
        let current = generation, revision = glab.accountRevision, token = originToken
        let cached = await cachedOrigins(in: discussions, target: target, userID: authenticatedUserID,
            criteriaOverride: assessmentCriteria, glab: glab)
        var updated = cached.0
        let contexts = cached.1
        guard originToken == token, isCurrent(current, target: target, glab: glab, revision: revision) else { return }
        for (id, origin) in origins where origin == .verifiedAssistant && updated[id]?.isManual != true { updated[id] = origin }
        origins = updated
        extraContexts = contexts
    }

    private func cachedOrigins(in result: [GitLabMergeRequestDiscussion], target: MRDiscussionTarget,
                               userID: Int?, criteriaOverride: String?, glab: GlabService) async
        -> ([Int: MRDiscussionSnapshot.Origin], AICommentProvenanceStore.ExtraContexts) {
        if let loadOrigins { return await loadOrigins(target, result) }
        let directory = assessmentDirectory
        let legacyDirectory = legacyAssessmentDirectory
        let displayDirectory = displayAssessmentDirectory
        let provenanceDirectory = self.provenanceDirectory
        let viewer = GitLabAccountIdentity(host: target.host, username: target.username, userID: userID)
        let legacyUsernames = glab.unambiguousAccountUsernames?(viewer) ?? [target.username]
        let context = userID.map { id in
            let account = GitLabAccountIdentity(host: target.host, username: target.username, userID: id)
            return AICommentProvenanceStore.Context(host: target.host, username: target.username, userID: id,
                projectID: target.projectID, iid: target.iid, legacyUsernames: glab.knownAccountUsernames?(account) ?? [])
        }
        return await Task.detached {
            let generated = context.map { AICommentProvenanceStore.reconcile(result, context: $0, in: provenanceDirectory) }
            var contexts = context.map {
                AICommentProvenanceStore.extraContexts(context: $0, snapshot: generated, in: provenanceDirectory)
            } ?? .empty
            var origins: [Int: MRDiscussionSnapshot.Origin] = [:]
            for thread in result {
                for note in thread.notes where note.system != true {
                    let isGenerated = generated?.contains(note, discussionID: thread.id) == true
                    if let id = note.id, !isGenerated { contexts.removeNote(id) }
                    if let id = note.id, let override = AICommentOriginOverrideStore.override(for: note, host: target.host,
                        projectID: target.projectID, iid: target.iid, username: target.username, userID: userID,
                        legacyUsernames: legacyUsernames, in: directory) {
                        origins[id] = .manual(override.badge)
                        continue
                    }
                    if let id = note.id, isGenerated {
                        origins[id] = .appGenerated
                        continue
                    }
                    if let declared = AICommentOriginAssessor.declaredAttribution(for: note) {
                        origins[declared.noteID] = .assessed(evidence: declared.evidence)
                        continue
                    }
                    if let id = note.id, id > 0, let record = AICommentAssessmentStore.displayResult(for: note,
                        host: target.host, projectID: target.projectID, iid: target.iid,
                        username: target.username, userID: userID, legacyUsernames: legacyUsernames,
                        criteriaOverride: criteriaOverride, in: directory, legacyDirectory: legacyDirectory,
                        displayDirectory: displayDirectory) {
                        if record.qualifiesAsAI {
                            origins[id] = .assessed(evidence: record.evidence)
                        } else if record.criteriaVersion == AICommentOriginAssessor.criteriaVersion {
                            origins[id] = record.classification == "manual_likely" && record.confidence != "uncertain"
                                ? .humanLikely(evidence: record.evidence) : .uncertain(evidence: record.evidence)
                        }
                    }
                }
            }
            return (origins, contexts)
        }.value
    }

    func cancel() {
        generation += 1; isLoading = false
        authorKindTask?.cancel(); authorKindTask = nil
        authorKindObservation?.cancel(); authorKindObservation = nil
        originToken += 1
        originReloadTask?.cancel(); originReloadTask = nil
        followUpTask?.cancel(); followUpTask = nil
        let queued = queuedRefresh
        queuedRefresh = nil
        queued?.finish()
    }

    /// Called when the current read finishes. Keeps `isLoading` set while a queued follow-up is pending
    /// so later equivalent requests join the next batch instead of starting a parallel read.
    private func scheduleFollowUp(target requested: MRDiscussionTarget, criteriaOverride: String?, revision: UInt64) {
        guard let batch = queuedRefresh, target == requested, assessmentCriteria == criteriaOverride else {
            isLoading = false
            return
        }
        queuedRefresh = nil
        followUpToken += 1
        let token = followUpToken, scheduled = generation
        followUpTask = Task { [self] in
            defer {
                if followUpToken == token { followUpTask = nil }
                batch.finish()
            }
            // cancel(), clear(), a target change and a newer read all advance the generation.
            guard generation == scheduled, target == requested, !Task.isCancelled else { return }
            guard matchesAccount(requested, glab: batch.glab), batch.glab.accountRevision == revision else {
                clear()
                return
            }
            await read(target: requested, glab: batch.glab, criteriaOverride: criteriaOverride)
        }
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
        currentUser = nil
        loadedRevision = nil
        discussionContent = nil
        origins = [:]
        extraContexts = .empty
        authorKinds = [:]
        authorKindVersions = [:]
        hasError = false
        hasLoaded = false
    }

    func hasCurrentTarget(_ requested: MRDiscussionTarget?, accountRevision: UInt64) -> Bool {
        guard let requested, target == requested else { return false }
        return loadedRevision == nil || loadedRevision == accountRevision
    }

    func citationContext(target requested: MRDiscussionTarget, request: GitLabMergeRequest?,
                         accountRevision: UInt64) -> MRCommentCitation.Context? {
        presentation.citationContext(target: requested, request: request, accountRevision: accountRevision) {
            guard hasCurrentTarget(requested, accountRevision: accountRevision) else { return nil }
            return MRCommentCitation.Context(target: requested, loadedTarget: target, request: request,
                content: discussionContent, hasLoaded: hasLoaded, hasError: hasError)
        }
    }

    func presentationSnapshot(target requested: MRDiscussionTarget?, accountRevision: UInt64,
                              drafts: [GitLabDraftNote], assessment: ReReviewAssessment?,
                              authorID: Int?) -> MRDiscussionSnapshot {
        presentation.snapshot(target: requested, accountRevision: accountRevision, drafts: drafts,
            assessment: assessment, authorID: authorID) {
            let current = hasCurrentTarget(requested, accountRevision: accountRevision)
            return MRDiscussionSnapshot(discussions: current ? discussions : [], drafts: drafts,
                origins: current ? origins : [:], assessment: current ? assessment : nil, authorID: authorID,
                authorKinds: current ? authorKinds : [:])
        }
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
