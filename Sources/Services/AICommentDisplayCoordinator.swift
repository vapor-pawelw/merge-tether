import Foundation
import Observation

/// Evaluates viewed conversation messages without producing action-authorizing origin evidence.
@MainActor @Observable final class AICommentDisplayCoordinator {
    struct PersistedOrigin: Equatable, Sendable {
        let noteID: Int
        let authorID: Int
        let bodySHA256: String
        let classification: AICommentOriginAssessment.Classification
        let confidence: AICommentOriginAssessment.Confidence
        let revision: UInt64
    }
    struct PersistedOrigins: Sendable {
        let target: MRAutomationScope.Target
        let request: GitLabMergeRequest
        let accountRevision: UInt64
        let origins: [PersistedOrigin]
    }
    typealias CacheRead = @MainActor @Sendable ([GitLabMergeRequestDiscussion.Note], MRAutomationScope.Target, URL, URL, String?) async -> [GitLabMergeRequestDiscussion.Note]

    private struct Queue {
        let notes: [GitLabMergeRequestDiscussion.Note]
        let generation: UUID
        var offset = 0
    }
    private struct Context {
        let request: GitLabMergeRequest
        let revision: UInt64
    }
    private let glab: GlabService
    private let settings: SettingsManager
    var activeCriteriaOverride: String? { settings.automation.aiCommentCriteriaOverride }
    private let assessmentDirectory: URL
    let displayDirectory: URL
    private let canAutomate: @MainActor (AutomationAssistant) async -> Bool
    private let publicationIsChecking: @MainActor (AssistantAutomationRunner.MergeRequestWork) -> Bool
    private let assess: AICommentOriginCoordinator.Assess
    private let cacheRead: CacheRead
    private var contexts: [MRAutomationScope.Target: Context] = [:]
    private var queued: [MRAutomationScope.Target: Queue] = [:]
    private var latest: [MRAutomationScope.Target: UUID] = [:]
    @ObservationIgnored private var scans: [MRAutomationScope.Target: (id: UUID, task: Task<Void, Never>)] = [:]
    private(set) var revision: UInt64 = 0
    @ObservationIgnored private lazy var coordinator = makeCoordinator()
    @ObservationIgnored private var originObservers: [UUID: @MainActor (PersistedOrigins) -> Void] = [:]
    private struct OriginKey: Hashable { let target: MRAutomationScope.Target; let noteID: Int }
    private var originVersions: [OriginKey: UInt64] = [:]
    private var originRevision: UInt64 = 0

    func observePersistedOrigins(_ observer: @escaping @MainActor (PersistedOrigins) -> Void) -> UUID {
        let id = UUID(); originObservers[id] = observer; return id
    }

    func removeOriginObserver(_ id: UUID) { originObservers.removeValue(forKey: id) }

    func notifyPersistedOrigins(target: MRAutomationScope.Target, request: GitLabMergeRequest, accountRevision: UInt64,
                                notes: [GitLabMergeRequestDiscussion.Note], assessment: AICommentOriginAssessment) {
        guard permitsSourceRead(request: request, accountRevision: accountRevision),
              glab.resolvedHost == target.host, glab.currentUsername == target.username,
              request.projectID == target.projectID, request.iid == target.iid,
              (try? AICommentOriginAssessor.validate(assessment, noteIDs: notes.compactMap(\.id))) != nil else { return }
        originRevision &+= 1
        let serial = originRevision, actionDirectory = assessmentDirectory, displayDirectory = self.displayDirectory
        let criteriaOverride = settings.automation.aiCommentCriteriaOverride
        let userID = glab.authenticatedUserID
        let names = settings.unambiguousLegacyUsernames(for: .init(host: target.host, username: target.username, userID: userID))
        for note in notes { if let id = note.id { originVersions[.init(target: target, noteID: id)] = serial } }
        Task { [weak self] in
            let origins = await Task.detached {
                notes.compactMap { note -> PersistedOrigin? in
                    // The user's verdict outranks a late model result for the same comment.
                    if let iid = target.iid, AICommentOriginOverrideStore.override(for: note, host: target.host,
                        projectID: target.projectID, iid: iid, username: target.username, userID: userID,
                        legacyUsernames: names, in: actionDirectory) != nil { return nil }
                    guard let id = note.id, let authorID = note.author?.id, authorID > 0, let body = note.body,
                          let iid = target.iid, let record = AICommentAssessmentStore.completedResult(for: note, host: target.host,
                            projectID: target.projectID, iid: iid, username: target.username, userID: userID, legacyUsernames: names,
                            criteriaOverride: criteriaOverride, in: actionDirectory, displayDirectory: displayDirectory),
                          let classification = AICommentOriginAssessment.Classification(rawValue: record.classification),
                          let confidence = AICommentOriginAssessment.Confidence(rawValue: record.confidence) else { return nil }
                    return .init(noteID: id, authorID: authorID, bodySHA256: AICommentAssessmentStore.digest(body),
                        classification: classification, confidence: confidence, revision: serial)
                }
            }.value
            guard let self, !Task.isCancelled, permitsSourceRead(request: request, accountRevision: accountRevision),
                  glab.resolvedHost == target.host, glab.currentUsername == target.username,
                  settings.automation.aiCommentCriteriaOverride == criteriaOverride else { return }
            let fresh = origins.filter { originVersions[.init(target: target, noteID: $0.noteID)] == $0.revision }
            guard !fresh.isEmpty else { return }
            let event = PersistedOrigins(target: target, request: request, accountRevision: accountRevision, origins: fresh)
            for observer in Array(originObservers.values) { observer(event) }
        }
    }

    init(glab: GlabService, settings: SettingsManager,
         assessmentDirectory: URL = AICommentAssessmentStore.directory, displayDirectory: URL? = nil,
         canAutomate: @escaping @MainActor (AutomationAssistant) async -> Bool,
         publicationIsChecking: @escaping @MainActor (AssistantAutomationRunner.MergeRequestWork) -> Bool = { _ in false },
         assess: @escaping AICommentOriginCoordinator.Assess = { try await AICommentOriginAssessor.verify(target: $0, notes: $1,
            assistant: $2, model: $3, thinking: $4, criteriaOverride: $5, authorContexts: $6) },
         cacheRead: CacheRead? = nil) {
        self.glab = glab; self.settings = settings; self.assessmentDirectory = assessmentDirectory
        self.displayDirectory = displayDirectory ?? AICommentAssessmentStore.displayDirectory(for: assessmentDirectory)
        self.canAutomate = canAutomate; self.publicationIsChecking = publicationIsChecking; self.assess = assess
        self.cacheRead = cacheRead ?? { notes, target, actionDirectory, displayDirectory, criteriaOverride in
            let userID = glab.authenticatedUserID
            let names = settings.unambiguousLegacyUsernames(for: .init(host: target.host, username: target.username, userID: userID))
            return await Task.detached {
                Self.missing(notes, target: target, userID: userID, legacyUsernames: names,
                    actionDirectory: actionDirectory, displayDirectory: displayDirectory, criteriaOverride: criteriaOverride)
            }.value
        }
    }

    func schedule(request: GitLabMergeRequest, notes: [GitLabMergeRequestDiscussion.Note], knownNoteIDs: Set<Int> = []) async {
        guard let host = glab.resolvedHost, let username = glab.currentUsername, !username.isEmpty,
              settings.automaticWritesAllowed, request.webURL.isGitLabMergeRequest(host: host, iid: request.iid),
              settings.automation.scope.permits(request, host: host, username: username) else { return }
        let target = MRAutomationScope.Target.mergeRequest(host: host, username: username, projectID: request.projectID, iid: request.iid)
        let configuration = settings.automation, accountRevision = glab.accountRevision
        let invocation = UUID()
        latest[target] = invocation
        let counts = Dictionary(grouping: notes.filter { $0.system != true }, by: \.id).mapValues(\.count)
        let candidates = notes.filter {
            guard let id = $0.id, id > 0 else { return false }
            return $0.system != true && ($0.author?.id ?? 0) > 0 && $0.body?.isEmpty == false
                && counts[id] == 1 && !knownNoteIDs.contains(id)
                && AICommentOriginAssessor.declaredAttribution(for: $0) == nil
        }.sorted { ($0.author!.id, $0.id!) < ($1.author!.id, $1.id!) }
        let actionDirectory = assessmentDirectory, displayDirectory = self.displayDirectory
        let missing = await cacheRead(candidates, target, actionDirectory, displayDirectory, configuration.aiCommentCriteriaOverride)
        guard latest[target] == invocation, !Task.isCancelled, settings.automation == configuration,
              EvidenceContext.sameAccountRevision(accountRevision, glab.accountRevision), glab.resolvedHost == host,
              glab.currentUsername == username, settings.automaticWritesAllowed else { return }
        guard !missing.isEmpty else { queued.removeValue(forKey: target); return }
        guard configuration.selectedAssistant != nil, await canAutomate(configuration.assistant), latest[target] == invocation, !Task.isCancelled,
              settings.automation == configuration, EvidenceContext.sameAccountRevision(accountRevision, glab.accountRevision),
              glab.resolvedHost == host, glab.currentUsername == username, settings.automaticWritesAllowed else { return }
        contexts[target] = .init(request: request, revision: accountRevision)
        queued[target] = .init(notes: missing, generation: invocation)
        drain()
    }

    func isChecking(work: AssistantAutomationRunner.MergeRequestWork) -> Bool {
        coordinator.isChecking(work: work) || queued.contains { target, queue in
            queue.offset < queue.notes.count && target.host == work.host && target.projectID == work.projectID && target.iid == work.iid
        } || scans.keys.contains { $0.host == work.host && $0.projectID == work.projectID && $0.iid == work.iid }
    }

    func resume() { drain() }

    func cancel(outsideScope scope: MRAutomationScope? = nil) {
        coordinator.cancel(outsideScope: scope)
        for target in Set(contexts.keys).union(latest.keys).union(queued.keys).union(originVersions.keys.map(\.target)) where scope.map({ !$0.resolve(target).active }) ?? true {
            contexts.removeValue(forKey: target); queued.removeValue(forKey: target); latest.removeValue(forKey: target)
            scans.removeValue(forKey: target)?.task.cancel()
            for key in Array(originVersions.keys) where key.target == target { originVersions.removeValue(forKey: key) }
        }
    }

    private func isCurrent(_ target: MRAutomationScope.Target, assistant: AutomationAssistant,
                           model: String, thinking: VerificationThinking) -> Bool {
        guard let context = contexts[target], EvidenceContext.sameAccountRevision(context.revision, glab.accountRevision),
              glab.resolvedHost == target.host, glab.currentUsername == target.username,
              settings.automaticWritesAllowed, settings.automation.selectedAssistant == assistant,
              settings.automation.verificationThinking == thinking,
              settings.automation.scope.permits(context.request, host: target.host, username: target.username) else { return false }
        return model == (assistant == .codex ? settings.automation.codexVerificationModel.rawValue
                         : settings.automation.claudeVerificationModel.rawValue)
    }

    private func makeCoordinator() -> AICommentOriginCoordinator {
        let worker = AICommentOriginCoordinator(directory: displayDirectory, overrideDirectory: assessmentDirectory, purpose: .display,
            assess: { [weak self] target, notes, assistant, model, thinking, criteriaOverride, contexts in
                guard let self, let generation = latest[target], isCurrent(target, assistant: assistant, model: model, thinking: thinking),
                      await canAutomate(assistant), !Task.isCancelled, latest[target] == generation,
                      isCurrent(target, assistant: assistant, model: model, thinking: thinking) else { throw CancellationError() }
                let current = try await readCurrent(target)
                guard !Task.isCancelled, latest[target] == generation, notes.allSatisfy({ original in
                    let matches = current.filter { $0.id == original.id }
                    return matches.count == 1 && original.matchesOriginSource(matches[0])
                }), isCurrent(target, assistant: assistant, model: model, thinking: thinking),
                      settings.automation.aiCommentCriteriaOverride == criteriaOverride else { throw CancellationError() }
                return try await assess(target, notes, assistant, model, thinking, criteriaOverride, contexts)
            }, fetchCurrent: { [weak self] target in
                guard let self else { throw CancellationError() }
                return try await readCurrent(target)
            }, isCurrent: { [weak self] target, assistant, model, thinking in
                self?.isCurrent(target, assistant: assistant, model: model, thinking: thinking) == true
            }, criteriaOverride: { [weak self] in self?.settings.automation.aiCommentCriteriaOverride },
            overrideAccount: { [weak self] target in
                .init(host: target.host, username: target.username, userID: self?.glab.authenticatedUserID)
            }, legacyUsernames: { [weak self] in self?.settings.unambiguousLegacyUsernames(for: $0) ?? [$0.username] },
            authorHistories: { [weak self] account, notes in
                self?.settings.reviewParticipationPreferences.authorHistories(for: notes, host: account.host,
                    accountID: account.userID) ?? [:]
            })
        worker.onChange = { [weak self] in
            guard let self else { return }
            revision &+= 1
            drain()
        }
        worker.onPersisted = { [weak self] target, notes, assessment in
            guard let self, let context = contexts[target] else { return }
            notifyPersistedOrigins(target: target, request: context.request, accountRevision: context.revision,
                                   notes: notes, assessment: assessment)
        }
        return worker
    }

    private func readCurrent(_ target: MRAutomationScope.Target) async throws -> [GitLabMergeRequestDiscussion.Note] {
        guard !Task.isCancelled, let iid = target.iid, let generation = latest[target], let context = contexts[target],
              EvidenceContext.sameAccountRevision(context.revision, glab.accountRevision) else { throw CancellationError() }
        let user = try await glab.fetchAuthenticatedUser(host: target.host, expectedUsername: target.username)
        guard !Task.isCancelled, latest[target] == generation, contexts[target] != nil,
              EvidenceContext.sameAccountRevision(context.revision, glab.accountRevision) else { throw CancellationError() }
        let request = try await glab.fetchMergeRequest(projectID: target.projectID, iid: iid, host: target.host)
        guard !Task.isCancelled, latest[target] == generation, contexts[target] != nil,
              user.username == target.username, settings.automaticWritesAllowed,
              EvidenceContext.sameAccountRevision(context.revision, glab.accountRevision), glab.resolvedHost == target.host, glab.currentUsername == target.username,
              request.webURL == context.request.webURL else { throw CancellationError() }
        contexts[target] = .init(request: request, revision: context.revision)
        guard settings.automation.scope.permits(request, host: target.host, username: target.username) else { throw CancellationError() }
        let notes = try await glab.fetchMergeRequestDiscussions(projectID: target.projectID, iid: iid, host: target.host).flatMap(\.notes)
        guard !Task.isCancelled, latest[target] == generation, contexts[target] != nil,
              EvidenceContext.sameAccountRevision(context.revision, glab.accountRevision), glab.resolvedHost == target.host,
              glab.currentUsername == target.username, settings.automaticWritesAllowed else { throw CancellationError() }
        return notes
    }

    var sourceAssessmentDirectory: URL { assessmentDirectory }

    func permitsSourceRead(request: GitLabMergeRequest, accountRevision: UInt64) -> Bool {
        guard !Task.isCancelled, EvidenceContext.sameAccountRevision(accountRevision, glab.accountRevision), settings.automaticWritesAllowed,
              let host = glab.resolvedHost, let username = glab.currentUsername, !username.isEmpty,
              request.webURL.isGitLabMergeRequest(host: host, iid: request.iid) else { return false }
        return settings.automation.scope.permits(request, host: host, username: username)
    }

    private func drain() {
        let configuration = settings.automation
        let model = configuration.assistant == .codex ? configuration.codexVerificationModel.rawValue : configuration.claudeVerificationModel.rawValue
        for target in Array(queued.keys) {
            let work = AssistantAutomationRunner.MergeRequestWork(host: target.host, projectID: target.projectID, iid: target.iid ?? 0)
            guard scans[target] == nil, !coordinator.isChecking(work: work), !publicationIsChecking(work),
                  isCurrent(target, assistant: configuration.assistant, model: model, thinking: configuration.verificationThinking),
                  let queue = queued[target], queue.generation == latest[target], queue.offset < queue.notes.count else { continue }
            var batch: [GitLabMergeRequestDiscussion.Note] = [], bytes = 0
            for note in queue.notes.dropFirst(queue.offset) {
                let size = note.body?.utf8.count ?? 0
                if !batch.isEmpty && (batch.count == 100 || bytes + size > 120_000) { break }
                batch.append(note); bytes += size
            }
            let scanID = UUID(), actionDirectory = assessmentDirectory, displayDirectory = self.displayDirectory
            let task = Task { [weak self] in
                guard let self else { return }
                defer {
                    if scans[target]?.id == scanID { scans.removeValue(forKey: target) }
                    drain()
                }
                let missing = await cacheRead(batch, target, actionDirectory, displayDirectory, configuration.aiCommentCriteriaOverride)
                guard !Task.isCancelled, scans[target]?.id == scanID, latest[target] == queue.generation,
                      queued[target]?.generation == queue.generation, settings.automation == configuration,
                      isCurrent(target, assistant: configuration.assistant, model: model, thinking: configuration.verificationThinking),
                      !publicationIsChecking(work) else { return }
                queued[target]?.offset += batch.count
                if queued[target]?.offset == queue.notes.count { queued.removeValue(forKey: target) }
                guard !missing.isEmpty else { return }
                coordinator.schedule(target: target, notes: missing, assistant: configuration.assistant, model: model,
                                     thinking: configuration.verificationThinking)
            }
            scans[target] = (scanID, task)
        }
    }

    private nonisolated static func missing(_ notes: [GitLabMergeRequestDiscussion.Note], target: MRAutomationScope.Target,
        userID: Int?, legacyUsernames: Set<String>, actionDirectory: URL, displayDirectory: URL,
        criteriaOverride: String?) -> [GitLabMergeRequestDiscussion.Note] {
        notes.filter { note in
            if let iid = target.iid, AICommentOriginOverrideStore.override(for: note, host: target.host,
                projectID: target.projectID, iid: iid, username: target.username, userID: userID,
                legacyUsernames: legacyUsernames, in: actionDirectory) != nil { return false }
            guard let iid = target.iid else { return false }
            return AICommentAssessmentStore.completedResult(for: note, host: target.host,
                projectID: target.projectID, iid: iid, username: target.username, userID: userID, legacyUsernames: legacyUsernames,
                criteriaOverride: criteriaOverride, in: actionDirectory, displayDirectory: displayDirectory) == nil
        }
    }
}
