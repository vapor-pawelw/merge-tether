import Foundation

/// Receives to-do events into durable MR work before acknowledging them in GitLab.
/// An acknowledgement proves routing, never review or fix completion.
@MainActor
final class MergeRequestTodoRouter {
    typealias Launcher = @MainActor (MRTodoIntent, Bool) async throws -> UUID
    private let settings: SettingsManager
    private let glab: GlabService
    private let canAutomate: @MainActor () async -> Bool
    private let launcher: Launcher?
    private let proofDirectory: URL
    private let cancelJob: @MainActor (UUID, SettingsManager) -> Void
    private var processing = false
    private var launching: Set<UUID> = []
    private(set) var acknowledgementError: GlabError?
    var onAcceptedIntent: (@MainActor (MRTodoIntent) -> Void)?
    var followUpAssessment: (@MainActor (GitLabMergeRequest, [GitLabMergeRequestDiscussion]) -> ReReviewAssessment?)?
    var followUpVerificationPending: (@MainActor (GitLabMergeRequest, [GitLabMergeRequestDiscussion]) -> Bool)?
    var blockedFollowUpCompletionProof: (@MainActor (AssistantAutomationRunner.Handoff, GitLabMergeRequest, [GitLabMergeRequestDiscussion]) -> Bool)?
    var mentionDisposition: (@MainActor (GitLabMergeRequest, [GitLabMergeRequestDiscussion], GitLabAuthenticatedUser, Int) async -> MRTodoMentionDisposition)?

    /// Reconcile app evidence without receiving events, starting workers or writing to GitLab.
    func refreshCompletionEvidence(host: String, username: String) async {
        guard !Task.isCancelled, isCurrent(host, username) else { return }
        await synchronize(host: host, username: username, cachedRequests: [:])
    }

    init(settings: SettingsManager, glab: GlabService,
         canAutomate: @escaping @MainActor () async -> Bool, launcher: Launcher? = nil,
         proofDirectory: URL = ReviewVerdictStore.directory,
         cancelJob: @escaping @MainActor (UUID, SettingsManager) -> Void = { AssistantAutomationRunner.cancel($0, settings: $1) }) {
        self.settings = settings
        self.glab = glab
        self.canAutomate = canAutomate
        self.launcher = launcher
        self.proofDirectory = proofDirectory
        self.cancelJob = cancelJob
    }

    func process(_ todos: [Todo], host: String, username: String,
                 managed: Set<MRAutomationScope.Target>, automatically: Bool = true) async -> Set<Int> {
        guard isCurrent(host, username) else { return [] }
        // A manual Add/handle pass must wait for the current refresh, not be
        // discarded. The wait yields the actor and exits promptly on cancellation.
        while processing {
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { return [] }
            guard isCurrent(host, username) else { return [] }
        }
        guard !Task.isCancelled, isCurrent(host, username) else { return [] }
        processing = true
        defer { processing = false }
        acknowledgementError = nil
        var acknowledged: Set<Int> = []
        let user: GitLabAuthenticatedUser
        do { user = try await glab.fetchAuthenticatedUser(host: host, expectedUsername: username) }
        catch { return [] }
        guard isCurrent(host, username) else { return [] }
        var requests: [MRAutomationScope.Target: GitLabMergeRequest] = [:]
        for todo in todos {
            guard !Task.isCancelled, isCurrent(host, username), todo.targetType == .mergeRequest, let iid = todo.target.iid,
                  todo.targetURL.gitLabTodoMergeRequestURL(host: host, iid: iid) != nil else { continue }
            let target = MRAutomationScope.Target(host: host, username: username, projectID: todo.project.id, iid: iid)
            let priorReceipt = settings.routedMRTodoReceipts.first { $0.target == target && $0.event == todo.feedbackIdentity }
            let persistedIntent = settings.mrActionIntents.first { $0.target == target && $0.sourceEvents.contains(todo.feedbackIdentity) }
            if priorReceipt != nil || persistedIntent != nil || settings.ignoredMergeRequests.contains(target) {
                if await acknowledge(todo, target: target, intentID: priorReceipt?.intentID ?? persistedIntent?.id) { acknowledged.insert(todo.id) }
                continue
            }
            let request: GitLabMergeRequest
            do {
                if let cached = requests[target] { request = cached }
                else {
                    request = try await glab.fetchMergeRequest(projectID: todo.project.id, iid: iid, host: host)
                    requests[target] = request
                }
            } catch { continue }
            guard isCurrent(host, username), let head = request.sha, !head.isEmpty,
                  request.projectID == target.projectID, request.iid == iid,
                  request.webURL.isGitLabMergeRequest(host: host, iid: iid) else { continue }
            let classification: (MRTodoIntent.Kind, Set<Int>)
            do {
                guard let result = try await classify(todo, request: request, user: user, host: host) else { continue }
                classification = result
            } catch { continue }
            guard isCurrent(host, username) else { continue }
            let kind = classification.0
            let explicitlyPaused = settings.automation.scope[target] == .paused
                || (settings.automation.scope[target] == .inherit && settings.automation.scope[target.repository] == .paused)
            guard request.author.id == user.id || !explicitlyPaused else { continue }
            let alreadyManaged = request.author.id == user.id || managed.contains(target)
                || settings.mrActionIntents.contains { $0.target == target && $0.grantsManagement }
                || settings.automation.scope.isManaged(target)
            var autoAdopt = false
            if shouldAdoptAutomatically(kind, request: request, target: target) {
                autoAdopt = await canAutomate()
                guard isCurrent(host, username) else { return acknowledged }
                autoAdopt = autoAdopt && shouldAdoptAutomatically(kind, request: request, target: target)
            }
            // A content-verified notice records receipt only. It never grants
            // management or executable review permission for an arbitrary mention.
            let informationalMention = kind == .refresh && (todo.actionName == .mentioned || todo.actionName == .directlyAddressed)
                && request.author.id != user.id
            guard alreadyManaged || autoAdopt || informationalMention else { continue }
            if !alreadyManaged && autoAdopt {
                settings.automation.scope[target] = .active
                settings.automation.scope.rememberRepository(request.webURL.gitLabProjectPath, for: target)
                settings.save()
            }
            let attempt = TodoAutomationReceipt(host: host, username: username, todoID: todo.id)
            let previousAttempt = settings.automationReceipts.contains(attempt) || settings.automationAttemptReceipts.contains(attempt)
                || settings.assistantHandoffs.contains { job in
                    job.key.work.host == host && job.key.work.projectID == target.projectID && job.key.work.iid == iid
                        && job.key.username == username && job.execution == nil
                        && (job.feedbackTodos?.contains(todo.feedbackIdentity) == true
                            || todo.linkedNoteID.map { job.feedbackNoteIDs?.contains($0) == true } == true)
                }
            let intentID = persist(todo, kind: kind, notes: classification.1, request: request, target: target,
                                   head: head, previousAttempt: previousAttempt)
            // The action is durable before any remote acknowledgement or worker dispatch.
            if automatically, let accepted = settings.mrActionIntents.first(where: { $0.id == intentID }) {
                onAcceptedIntent?(accepted)
            }
            if await acknowledge(todo, target: target, intentID: intentID) { acknowledged.insert(todo.id) }
        }
        await synchronize(host: host, username: username, cachedRequests: requests)
        guard !Task.isCancelled, isCurrent(host, username) else { return acknowledged }
        for intent in settings.mrActionIntents where intent.target.host == host && intent.target.username == username
            && intent.state == .pending && intent.jobID == nil {
            if shouldRunAutomatically(intent.kind, request: intent.request, target: intent.target), await canAutomate() {
                await run(intent.id, manual: false)
            }
        }
        return acknowledged
    }

    func run(_ id: UUID, manual: Bool) async {
        guard launching.insert(id).inserted else { return }
        defer { launching.remove(id) }
        guard !Task.isCancelled, let original = settings.mrActionIntents.first(where: { $0.id == id }), original.state != .completed,
              let iid = original.target.iid, isCurrent(original.target.host, original.target.username) else { return }
        let origin: MRAutomationEvent.Origin = manual ? .manual : .automatic
        if manual {
            settings.recordAutomationEvent(target: original.target, action: .retry, origin: .manual, state: .requested,
                intentID: id, jobID: original.jobID)
        }
        let work = AssistantAutomationRunner.MergeRequestWork(host: original.target.host, projectID: original.target.projectID, iid: iid)
        if original.kind == .review || original.kind == .followUp {
            let rule = original.kind == .review ? settings.automation.reviewRequested : settings.automation.authorFeedback
            guard rule.runner == .assistant else {
                update(id, origin: origin) { $0.state = .failed; $0.error = String(localized: .TodoRouting.todoRoutingShellUnsupported) }
                return
            }
        }
        if let existing = settings.assistantHandoffs.last(where: { job in
            job.key.work == work && job.key.username == original.target.username && job.execution != nil
                && (job.execution?.state.isActive == true || (!manual && job.execution?.state == .succeeded))
                && job.expectedHeadSHA == original.headSHA
                && !original.sourceEvents.isEmpty
                && original.sourceEvents.allSatisfy { job.feedbackTodos?.contains($0) == true }
        }) {
            update(id, origin: origin) { $0.jobID = existing.id; $0.state = .running; $0.error = nil }
            return
        }
        if !manual, original.sourceEvents.contains(where: { event in
            let receipt = TodoAutomationReceipt(host: original.target.host, username: original.target.username, todoID: event.id)
            return settings.automationAttemptReceipts.contains(receipt) || settings.automationReceipts.contains(receipt)
                || settings.assistantHandoffs.contains { job in
                    job.key.work == work && job.key.username == original.target.username && job.execution == nil
                        && job.feedbackTodos?.contains(event) == true
                }
        }) {
            update(id, origin: origin) { $0.state = .failed; $0.error = String(localized: .TodoRouting.todoRoutingPreviousAttempt) }
            return
        }
        if !manual, let previous = settings.assistantHandoffs.last(where: { job in
            job.key.work == work && job.key.username == original.target.username
                && job.execution != nil && job.execution?.state.isActive == false && job.execution?.state != .succeeded
                && !original.sourceEvents.isEmpty && original.sourceEvents.allSatisfy { job.feedbackTodos?.contains($0) == true }
        }) {
            update(id, origin: origin) { $0.jobID = previous.id; $0.state = .failed; $0.error = String(localized: .TodoRouting.todoRoutingPreviousAttempt) }
            return
        }
        if AssistantAutomationRunner.isWorking(on: work) || settings.assistantHandoffs.contains(where: {
            $0.key.work == work && $0.key.username == original.target.username && $0.execution?.state.isActive == true
        }) {
            if manual {
                settings.recordAutomationEvent(target: original.target, action: .retry, origin: .manual, state: .blocked,
                    message: String(localized: .AutomationRuntime.runtimeAlreadyActive), intentID: id, jobID: original.jobID)
            }
            return
        }
        let invocationConfiguration = settings.automation
        guard await canAutomate() else {
            if manual {
                settings.recordAutomationEvent(target: original.target, action: .retry, origin: .manual, state: .blocked,
                    message: String(localized: .TodoRouting.todoRoutingAssistantUnavailable), intentID: id, jobID: original.jobID)
            }
            return
        }
        guard manual || shouldRunAutomatically(original.kind, request: original.request, target: original.target) else { return }
        do {
            let request = try await glab.fetchMergeRequest(projectID: original.target.projectID, iid: iid, host: original.target.host)
            guard invocationConfiguration.preservingScope(from: settings.automation) == settings.automation,
                  isCurrent(original.target.host, original.target.username), request.state == "opened",
                  request.projectID == original.target.projectID, request.iid == iid,
                  request.webURL.isGitLabMergeRequest(host: original.target.host, iid: iid),
                  let head = request.sha, !settings.ignoredMergeRequests.contains(original.target),
                  manual || shouldRunAutomatically(original.kind, request: request, target: original.target) else {
                if manual {
                    settings.recordAutomationEvent(target: original.target, action: .retry, origin: .manual, state: .blocked,
                        message: String(localized: .TodoRouting.todoRoutingNeedsRecheck), intentID: id, jobID: original.jobID)
                }
                return
            }
            if original.kind == .pipeline {
                let user = try await glab.fetchAuthenticatedUser(host: original.target.host, expectedUsername: original.target.username)
                let originalJob = original.jobID.flatMap { id in settings.assistantHandoffs.first { $0.id == id } }
                let refreshed = try await glab.refreshStaleFailedPipeline(for: request, host: original.target.host,
                    expectedUser: user, settings: settings, shouldProceed: {
                        self.isCurrent(original.target.host, original.target.username)
                            && !self.settings.ignoredMergeRequests.contains(original.target)
                            && invocationConfiguration.preservingScope(from: self.settings.automation) == self.settings.automation
                            && self.matchesCompletionSnapshot(original, job: originalJob)
                            && (manual || self.shouldRunAutomatically(original.kind, request: request, target: original.target))
                    })
                if refreshed {
                    update(id, origin: origin) { $0.request = request; $0.state = .completed; $0.error = nil }
                    return
                }
                guard isCurrent(original.target.host, original.target.username),
                      invocationConfiguration.preservingScope(from: settings.automation) == settings.automation else { return }
            }
            var current = original
            current.request = request
            current.headSHA = head
            let jobID: UUID
            if let launcher { jobID = try await launcher(current, manual) }
            else { jobID = try await launch(current, manual: manual) }
            guard isCurrent(original.target.host, original.target.username),
                  !settings.ignoredMergeRequests.contains(original.target),
                  invocationConfiguration.preservingScope(from: settings.automation) == settings.automation,
                  manual || shouldRunAutomatically(original.kind, request: request, target: original.target) else {
                cancelJob(jobID, settings)
                update(id, origin: origin) { $0.jobID = jobID; $0.state = .failed; $0.error = String(localized: .TodoRouting.todoRoutingNeedsRecheck) }
                return
            }
            update(id, origin: origin) { $0.request = request; $0.headSHA = head; $0.jobID = jobID; $0.state = .running; $0.error = nil }
            if manual {
                settings.recordAutomationEvent(target: original.target, action: .retry, origin: .manual, state: .queued,
                    intentID: id, jobID: jobID, relatedJobID: original.jobID)
            }
        } catch PipelineRefreshError.ownershipReserved {
            // Another task owns this pipeline. Wait without starting a worker
            // or presenting the lease race as a failed agent execution.
            update(id, origin: origin) { $0.state = .pending; $0.error = nil }
        } catch {
            update(id, origin: origin) { $0.state = .failed; $0.error = String(describing: error) }
        }
    }

    func rebindJob(oldID: UUID, replacement: AssistantAutomationRunner.Handoff) {
        var changed = false
        for index in settings.mrActionIntents.indices {
            let original = settings.mrActionIntents[index]
            guard original.jobID == oldID, original.state != .completed,
                  original.target.host == replacement.key.work.host, original.target.username == replacement.key.username,
                  original.target.projectID == replacement.key.work.projectID, original.target.iid == replacement.key.work.iid else { continue }
            if original.state == .failed { recordIntentEvent(original, state: .failed) }
            settings.mrActionIntents[index].jobID = replacement.id
            settings.mrActionIntents[index].headSHA = replacement.expectedHeadSHA ?? original.headSHA
            settings.mrActionIntents[index].state = replacement.execution?.state.isActive == true ? .running : .failed
            settings.mrActionIntents[index].error = nil
            settings.mrActionIntents[index].updatedAt = Date()
            changed = true
        }
        if changed { settings.save() }
    }

    func dismiss(_ id: UUID) {
        guard let intent = settings.mrActionIntents.first(where: { $0.id == id }),
              isCurrent(intent.target.host, intent.target.username) else { return }
        update(id, origin: .manual) { $0.state = .completed; $0.error = nil }
    }

    private func classify(_ todo: Todo, request: GitLabMergeRequest, user: GitLabAuthenticatedUser,
                          host: String) async throws -> (MRTodoIntent.Kind, Set<Int>)? {
        let owned = request.author.id == user.id
        switch todo.actionName {
        case .reviewRequested, .approvalRequired:
            guard !owned else { return nil }
            return (request.state == "opened" ? .review : .refresh, [])
        case .buildFailed:
            guard let pipelineSHA = request.headPipeline?.sha, !pipelineSHA.isEmpty,
                  let status = request.headPipeline?.status, !status.isEmpty else { return nil }
            // A known stale/merged-result pipeline updates the MR card but must
            // never authorize a fix against a different source revision.
            guard status == "failed" else { return (.refresh, []) }
            do { _ = try await glab.verifiedFailedPipeline(for: request, host: host, expectedUser: user) }
            catch GitLabPipelineEvidenceError.staleTarget(_) {
                return (owned ? .pipeline : .refresh, [])
            }
            catch is CancellationError { return (.refresh, []) }
            return (.pipeline, [])
        case .unmergeable:
            guard let conflicts = request.hasConflicts else { return nil }
            return (conflicts ? .conflict : .refresh, [])
        case .reviewSubmitted:
            guard owned, request.state == "opened" else { return (.refresh, []) }
            let discussions = try await glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
            // General review comments are assessed by AuthorFeedbackCoordinator
            // before it dispatches warranted work. Do not race that verifier
            // with a second worker or require fix proof for a no-change summary.
            let notes = GitLabMergeRequestDiscussion.unresolvedFeedback(in: discussions, excluding: user.id)
                .filter { $0.author?.id == todo.author.id }
            let ids = Set(notes.compactMap(\.id))
            return ids.isEmpty ? (.refresh, []) : (.followUp, ids)
        case .mentioned, .directlyAddressed:
            guard request.state == "opened", let noteID = todo.linkedNoteID else { return nil }
            let accountRevision = glab.accountRevision
            let discussions = try await glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
            if !owned {
                guard settings.automation.scope.permits(request, host: host, username: user.username),
                      let note = discussions.flatMap(\.notes).first(where: { $0.id == noteID }),
                      note.system == false, note.author?.id == todo.author.id, note.body != nil,
                      let fingerprint = MRNoticeClassifier.contextFingerprint(
                        request: request, discussions: discussions, user: user, noteID: noteID),
                      await mentionDisposition?(request, discussions, user, noteID) == .informational,
                      isCurrent(host, user.username) else { return nil }
                let live = try await glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
                let liveDiscussions = try await glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
                let liveUser = try await glab.fetchAuthenticatedUser(host: host, expectedUsername: user.username)
                guard isCurrent(host, user.username), glab.accountRevision == accountRevision, liveUser == user,
                      live.projectID == request.projectID, live.iid == request.iid, live.webURL == request.webURL,
                      live.author == request.author, live.sha == request.sha, live.state == request.state,
                      settings.automation.scope.permits(live, host: host, username: user.username),
                      live.semanticContextFingerprint == request.semanticContextFingerprint,
                      MRNoticeClassifier.contextFingerprint(request: live, discussions: liveDiscussions,
                                                            user: liveUser, noteID: noteID) == fingerprint else { return nil }
                return (.refresh, [noteID])
            }
            let feedback = GitLabMergeRequestDiscussion.unresolvedFeedback(in: discussions, excluding: user.id)
                .filter { note in
                    if let linked = todo.linkedNoteID { return note.id == linked }
                    return note.author?.id == todo.author.id
                }
            let ids = Set(feedback.compactMap(\.id))
            return ids.isEmpty ? nil : (.followUp, ids)
        default: return nil
        }
    }

    private func persist(_ todo: Todo, kind: MRTodoIntent.Kind, notes: Set<Int>, request: GitLabMergeRequest,
                         target: MRAutomationScope.Target, head: String, previousAttempt: Bool) -> UUID {
        if let index = settings.mrActionIntents.firstIndex(where: {
            !previousAttempt && !launching.contains($0.id) && !hasAttemptOverlap($0)
                && $0.target == target && $0.kind == kind && (kind == .review || $0.headSHA == head)
                && $0.state == .pending && $0.jobID == nil
        }) {
            settings.mrActionIntents[index].todoIDs.insert(todo.id)
            settings.mrActionIntents[index].noteIDs.formUnion(notes)
            if !settings.mrActionIntents[index].sourceEvents.contains(todo.feedbackIdentity) {
                settings.mrActionIntents[index].sourceEvents.append(todo.feedbackIdentity)
            }
            settings.mrActionIntents[index].headSHA = head
            settings.mrActionIntents[index].request = request
            settings.mrActionIntents[index].updatedAt = Date()
            settings.mrActionIntents[index].sourceTodo = todo
            settings.save()
            return settings.mrActionIntents[index].id
        }
        let intent = MRTodoIntent(id: UUID(), target: target, kind: kind,
            state: kind == .refresh ? .completed : (previousAttempt ? .failed : .pending),
            todoIDs: [todo.id], noteIDs: notes, sourceEvents: [todo.feedbackIdentity], request: request, headSHA: head,
            error: previousAttempt ? String(localized: .TodoRouting.todoRoutingPreviousAttempt) : nil, updatedAt: Date(), sourceTodo: todo)
        settings.mrActionIntents.append(intent)
        settings.save()
        return intent.id
    }

    private func hasAttemptOverlap(_ intent: MRTodoIntent) -> Bool {
        intent.sourceEvents.contains { event in
            let receipt = TodoAutomationReceipt(host: intent.target.host, username: intent.target.username, todoID: event.id)
            return settings.automationReceipts.contains(receipt) || settings.automationAttemptReceipts.contains(receipt)
                || settings.assistantHandoffs.contains { job in
                    job.key.work.host == intent.target.host && job.key.username == intent.target.username
                        && job.key.work.projectID == intent.target.projectID && job.key.work.iid == intent.target.iid
                        && job.feedbackTodos?.contains(event) == true
                }
        }
    }

    private func acknowledge(_ todo: Todo, target: MRAutomationScope.Target, intentID: UUID?) async -> Bool {
        guard isCurrent(target.host, target.username) else { return false }
        // Persist acceptance before the remote write. A failed acknowledgement
        // retries only this receipt, even if the worker finishes in the meantime.
        settings.routedMRTodoReceipts.insert(.init(target: target, event: todo.feedbackIdentity, intentID: intentID))
        settings.save()
        switch await glab.markAsDone(id: todo.id, host: target.host) {
        case .success:
            settings.routedMRTodoReceipts.insert(.init(target: target, event: todo.feedbackIdentity, intentID: intentID))
            settings.save()
            return true
        case .failure(let error): acknowledgementError = error; return false
        }
    }

    private func shouldRunAutomatically(_ kind: MRTodoIntent.Kind, request: GitLabMergeRequest,
                                        target: MRAutomationScope.Target) -> Bool {
        settings.automation.scope.permits(request, host: target.host, username: target.username)
            && shouldAdoptAutomatically(kind, request: request, target: target)
    }

    /// Tracking follows ordinary scope; execution separately applies the current Draft policy.
    private func shouldAdoptAutomatically(_ kind: MRTodoIntent.Kind, request: GitLabMergeRequest,
                                          target: MRAutomationScope.Target) -> Bool {
        guard settings.automation.packageDecision != .disabled, !settings.ignoredMergeRequests.contains(target),
              settings.automation.scope.resolve(target).active, request.state == "opened" else { return false }
        let project = request.webURL.gitLabProjectPath
        switch kind {
        case .review:
            let rule = settings.automation.reviewRequested
            return rule.isEnabled && rule.runner == .assistant && rule.isConfigured && rule.includes(project: project)
        case .followUp:
            return settings.automation.followUpAutomationHold(for: request, target: target,
                ignored: settings.ignoredMergeRequests.contains(target), includeDraftPolicy: false) == nil
        case .pipeline:
            let rule = settings.automation.workflowRules[.pipelineFailure]
            return request.author.username == target.username && settings.automation.autoClaimPipelineFailures
                && request.headPipeline?.status == "failed" && rule.mode == .assistant && rule.includes(request)
        case .conflict, .refresh:
            // Conflict handoff confirmation and its separate push permission remain explicit.
            return false
        }
    }

    private func synchronize(host: String, username: String,
                             cachedRequests: [MRAutomationScope.Target: GitLabMergeRequest]) async {
        // Completion decisions use a new read after acknowledgements/worker state,
        // rather than the earlier classification snapshot.
        var requests: [MRAutomationScope.Target: GitLabMergeRequest] = [:]
        for original in settings.mrActionIntents where original.target.host == host && original.target.username == username
            && original.state != .completed {
            guard isCurrent(host, username), let iid = original.target.iid else { return }
            let job = original.jobID.flatMap { id in settings.assistantHandoffs.first { $0.id == id } }
            let request: GitLabMergeRequest
            do {
                if let current = requests[original.target] { request = current }
                else {
                    request = try await glab.fetchMergeRequest(projectID: original.target.projectID, iid: iid, host: host)
                    requests[original.target] = request
                }
            } catch { continue }
            guard isCurrent(host, username), request.projectID == original.target.projectID, request.iid == iid,
                  request.webURL.isGitLabMergeRequest(host: host, iid: iid) else { continue }
            guard matchesCompletionSnapshot(original, job: job) else { continue }
            // Preserve current readiness so an adopted Draft can start naturally
            // when the author marks it ready, without a second incoming event.
            if original.request.draft != request.draft || original.request.sha != request.sha
                || original.request.state != request.state {
                update(original.id) { $0.request = request }
            }
            var successfulPipeline = false
            if original.kind == .pipeline, request.headPipeline?.status == "success" {
                successfulPipeline = (try? await glab.verifiedSuccessfulPipeline(for: request, host: host)) != nil
                guard isCurrent(host, username), matchesCompletionSnapshot(original, job: job) else { continue }
            }
            let resolvedByState = request.state != "opened"
                || successfulPipeline
                || (original.kind == .conflict && request.hasConflicts == false)
            if resolvedByState { update(original.id) { $0.state = .completed; $0.error = nil }; continue }
            if original.jobID != nil && job == nil {
                update(original.id) { $0.state = .failed; $0.error = String(localized: .TodoRouting.todoRoutingMissingRun) }
                continue
            }
            if let execution = job?.execution, execution.state.isActive { continue }
            let stoppedFollowUp = original.kind == .followUp && job.map {
                AuthorFeedbackStatus.canReconcile($0, request: request)
                    && $0.key.work.host == original.target.host && $0.key.username == original.target.username
                    && Set($0.feedbackNoteIDs ?? []) == original.noteIDs
            } == true
            if let execution = job?.execution, [.failed, .blocked, .interrupted, .cancelled].contains(execution.state),
               !stoppedFollowUp {
                update(original.id) { $0.state = .failed; $0.error = execution.attentionExplanation ?? execution.error ?? execution.summary }
                continue
            }
            var sameReviewedHead = false
            if original.kind == .review, let job, job.execution?.state == .succeeded, job.expectedHeadSHA == request.sha {
                sameReviewedHead = await reviewMatches(job, request: request)
            }
            var provedFollowUp = original.kind == .followUp && job?.execution?.state == .succeeded
                && job.map { followUpMatches($0, request: request) } == true
            var checkingFollowUp = false
            // An earlier unbound routing failure is not a worker result. Current
            // independent evidence can finish it without replaying that attempt.
            let unboundFollowUp = original.jobID == nil
            if original.kind == .followUp, job?.execution?.state == .succeeded || unboundFollowUp || stoppedFollowUp, !provedFollowUp {
                switch await followUpNeedsNoWork(original, request: request, requireNoDrafts: stoppedFollowUp,
                    stoppedJob: stoppedFollowUp ? job : nil) {
                case .proved: provedFollowUp = true
                case .checking: checkingFollowUp = true
                case .unverified: break
                }
            }
            guard isCurrent(host, username) else { return }
            // A retry, cancellation or dismissal may replace this intent while evidence is read.
            // The old worker's result must not finish or fail the replacement attempt.
            guard matchesCompletionSnapshot(original, job: job) else { continue }
            if sameReviewedHead || provedFollowUp {
                update(original.id) { $0.state = .completed; $0.error = nil }
            } else if checkingFollowUp {
                update(original.id) { $0.state = .running; $0.error = nil }
            } else if stoppedFollowUp, let execution = job?.execution {
                update(original.id) { $0.state = .failed; $0.error = execution.attentionExplanation ?? execution.error ?? execution.summary }
            } else if job?.execution?.state == .succeeded {
                update(original.id) {
                    $0.state = .failed
                    $0.error = String(localized: original.kind == .followUp
                        ? .TodoRouting.todoRoutingFollowUpNeedsEvidence : .TodoRouting.todoRoutingNeedsRecheck)
                }
            }
        }
    }

    private func matchesCompletionSnapshot(_ original: MRTodoIntent, job: AssistantAutomationRunner.Handoff?) -> Bool {
        guard let current = settings.mrActionIntents.first(where: { $0.id == original.id }),
              current.jobID == original.jobID, current.headSHA == original.headSHA,
              current.noteIDs == original.noteIDs, current.state == original.state else { return false }
        let currentJob = original.jobID.flatMap { id in settings.assistantHandoffs.first { $0.id == id } }
        guard currentJob?.id == job?.id && currentJob?.execution?.state == job?.execution?.state else { return false }
        if let job, job.execution?.state == .blocked {
            guard let currentJob, currentJob.key == job.key, currentJob.workflow == job.workflow,
                  currentJob.expectedHeadSHA == job.expectedHeadSHA, currentJob.feedbackNoteIDs == job.feedbackNoteIDs,
                  currentJob.allowsPush == job.allowsPush, currentJob.pipelineReservation == nil,
                  AuthorFeedbackStatus.blockedContext(for: currentJob) == AuthorFeedbackStatus.blockedContext(for: job)
            else { return false }
        }
        return true
    }

    private func reviewMatches(_ job: AssistantAutomationRunner.Handoff, request: GitLabMergeRequest) async -> Bool {
        guard let verdict = ReviewVerdictStore.verdict(host: job.key.work.host, projectID: request.projectID,
                    iid: request.iid, in: proofDirectory), verdict.headSHA == request.sha,
              verdict.discussionFingerprint != nil,
              let modified = try? ReviewVerdictStore.fileURL(host: job.key.work.host, projectID: request.projectID,
                    iid: request.iid, in: proofDirectory).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              modified >= job.createdAt,
              let discussions = try? await glab.fetchMergeRequestDiscussions(projectID: request.projectID,
                    iid: request.iid, host: job.key.work.host) else { return false }
        guard let user = try? await glab.fetchAuthenticatedUser(host: job.key.work.host, expectedUsername: job.key.username) else { return false }
        return verdict.covers(head: request.sha ?? "", discussions: discussions, reviewerID: user.id,
            publishedDrafts: ReviewVerdictStore.seenDrafts(host: job.key.work.host,
                projectID: request.projectID, iid: request.iid, in: proofDirectory))
    }

    private func followUpMatches(_ job: AssistantAutomationRunner.Handoff, request: GitLabMergeRequest) -> Bool {
        guard let proof = FollowUpVerificationStore.receipt(work: job.key.work, username: job.key.username,
                                                          in: proofDirectory.deletingLastPathComponent()) else { return false }
        return proof.sealed && proof.runID == job.id && proof.headSHA == request.sha
    }

    /// Finishing a no-op action needs current independent evidence, but no publication receipt.
    /// This changes only the local intent; drafts keep their separate remote-proof gate.
    private enum FollowUpCompletion { case proved, checking, unverified }

    private func followUpNeedsNoWork(_ intent: MRTodoIntent, request: GitLabMergeRequest,
                                     requireNoDrafts: Bool = false,
                                     stoppedJob: AssistantAutomationRunner.Handoff? = nil) async -> FollowUpCompletion {
        let accountRevision = glab.accountRevision
        let decisionRevision = settings.feedbackSuggestionDecisions.revision(for: intent.target)
        guard let iid = intent.target.iid, request.author.username == intent.target.username,
              let head = request.sha, !head.isEmpty,
              let discussions = try? await glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: iid, host: intent.target.host),
              let fingerprint = ReviewVerdict.fingerprint(discussions) else { return .unverified }
        guard let assessment = followUpAssessment?(request, discussions) else {
            return followUpVerificationPending?(request, discussions) == true ? .checking : .unverified
        }
        let ignored = settings.feedbackSuggestionDecisions.applicable(in: discussions, for: intent.target)
        guard (try? assessment.reviewers(in: discussions, authorID: request.author.id, ignoredSuggestions: ignored)) != nil else { return .unverified }
        let assessed = Dictionary(uniqueKeysWithValues: assessment.notes.map { ($0.noteID, $0.state) })
        let selected = intent.noteIDs.isEmpty ? Set(assessed.keys) : intent.noteIDs
        guard !selected.isEmpty,
              selected.allSatisfy({ assessed[$0] == .addressed || assessed[$0] == .informational || assessed[$0] == .ignoredByUser }) else { return .unverified }
        guard assessment.missingPublishedReplyNoteIDs(in: discussions, authorID: request.author.id).isDisjoint(with: selected)
        else { return .unverified }
        if requireNoDrafts {
            guard let count = try? await glab.fetchOwnDraftNoteCount(projectID: request.projectID, iid: iid,
                host: intent.target.host, userID: request.author.id), count == 0 else { return .unverified }
        }
        guard let live = try? await glab.fetchMergeRequest(projectID: request.projectID, iid: iid, host: intent.target.host),
              let liveDiscussions = try? await glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: iid, host: intent.target.host),
              let liveUser = try? await glab.fetchAuthenticatedUser(host: intent.target.host, expectedUsername: intent.target.username),
              isCurrent(intent.target.host, intent.target.username),
              glab.accountRevision == accountRevision, liveUser.id == request.author.id,
              settings.feedbackSuggestionDecisions.revision(for: intent.target) == decisionRevision,
              live.projectID == request.projectID, live.iid == request.iid, live.webURL == request.webURL,
              live.author == request.author, live.state == "opened", live.draft == request.draft, live.sha == head,
              live.semanticContextFingerprint == request.semanticContextFingerprint,
              ReviewVerdict.fingerprint(liveDiscussions) == fingerprint else { return .unverified }
        if let stoppedJob, stoppedJob.execution?.state == .blocked {
            guard blockedFollowUpCompletionProof?(stoppedJob, live, liveDiscussions) == true else { return .unverified }
        }
        return .proved
    }

    /// Uses the original event context for actor/URL placeholders and the current
    /// configured template so user scope and local-only restrictions survive routing.
    static func configuredAssistantContext(_ intent: MRTodoIntent, configuration: AutomationSettings) -> (title: String, instructions: String) {
        guard intent.kind == .review || intent.kind == .followUp else { return (intent.request.title, "") }
        let event: TodoAutomationEvent = intent.kind == .review ? .reviewRequested : .authorFeedback
        let context: TodoAutomationContext
        if let source = intent.sourceTodo {
            context = .init(todo: source, event: event, author: intent.request.author, iid: intent.request.iid)
        } else { context = .init(request: intent.request, feedback: []) }
        let rule = configuration[event]
        let title = context.render(rule.titleTemplate, titleAuthor: intent.request.author.assistantTitleName(viewerUsername: intent.target.username))
        let instructions = rule.promptTemplate == AutomationSettings()[event].promptTemplate
            ? "" : "\n\nMy additional instructions: " + context.render(rule.promptTemplate)
        return (title.isEmpty ? intent.request.title : title, instructions)
    }

    private func launch(_ intent: MRTodoIntent, manual: Bool) async throws -> UUID {
        guard let iid = intent.target.iid else { throw CancellationError() }
        let work = AssistantAutomationRunner.MergeRequestWork(host: intent.target.host, projectID: intent.target.projectID, iid: iid)
        let workflow: AssistantAutomationRunner.MRWorkflow? = switch intent.kind {
        case .review: .review
        case .followUp: .followUp
        case .pipeline: intent.request.author.username == intent.target.username ? .followUp : .review
        case .conflict, .refresh: nil
        }
        let task: String = switch intent.kind {
        case .review: "Review or re-review the current merge request. Save warranted findings as private GitLab drafts."
        case .followUp: "First assess the specified reviewer comments on my MR against the current code and discussion. Informational summaries or accepted feedback require no code changes or reply. For warranted actionable feedback only, implement fixes, verify and push only within the configured author-follow-up permission, then save verified private replies."
        case .pipeline: "Diagnose this MR's failed pipeline and prepare an in-scope verified fix."
        case .conflict: "Resolve conflicts in an isolated worktree. Do not push unless the separate conflict-push permission below authorizes it."
        case .refresh: "Refresh current merge request state."
        }
        let configured = Self.configuredAssistantContext(intent, configuration: settings.automation)
        let conflictPush = intent.kind == .conflict && settings.automation.permitsConflictPush(project: intent.request.webURL.gitLabProjectPath)
        let isolation = workflow == .followUp || intent.kind == .conflict
            ? "\n" + AssistantAutomationRunner.isolatedFixInstructions : ""
        let prompt = task + "\nFocus on these GitLab note IDs: " + intent.noteIDs.sorted().map(String.init).joined(separator: ", ")
            + configured.instructions + isolation
            + (conflictPush ? "\nSeparate conflict-push permission is ON for this MR; push only the verified in-scope conflict resolution." : "")
        let permittedTools = settings.automation.permitsAssistantTools(project: intent.request.webURL.gitLabProjectPath)
        let access: AssistantAutomationRunner.Access = permittedTools ? .configuredTools : (intent.kind == .conflict ? .preparation : .gitLabRead)
        let reservation = try Self.reservePipeline(for: intent, manual: manual)
        var transferred = false
        defer { if !transferred, let reservation { try? ExistingPipelineWorkDetector().finishHandoff(for: reservation) } }
        let job = try await AssistantAutomationRunner.launch(settings.automation.assistant, title: configured.title,
            mergeRequestURL: intent.request.webURL, prompt: prompt, workspace: settings.automation.assistantWorkspace,
            access: access, work: work, username: intent.target.username, settings: settings, allowsPush: conflictPush,
            pipelineReservation: reservation,
            feedbackNoteIDs: intent.noteIDs.sorted(), feedbackTodos: intent.sourceEvents, isReview: intent.kind == .review, mrWorkflow: workflow, manual: manual)
        transferred = true
        return job.id
    }

    static func reservePipeline(for intent: MRTodoIntent, manual: Bool,
                                detector: ExistingPipelineWorkDetector = ExistingPipelineWorkDetector()) throws -> ExistingPipelineWorkDetector.Key? {
        guard intent.kind == .pipeline, intent.request.author.username == intent.target.username else { return nil }
        guard let iid = intent.target.iid, let pipeline = intent.request.headPipeline,
              let pipelineID = pipeline.id, pipelineID > 0, pipeline.status == "failed" else { throw CancellationError() }
        let key = ExistingPipelineWorkDetector.Key(host: intent.target.host, projectID: intent.target.projectID,
                                                   mergeRequestIID: iid, pipelineID: pipelineID)
        let explicitRetry = manual && (intent.state == .failed || intent.jobID != nil)
        guard let owned = try detector.registerRun(for: key, explicitRetry: explicitRetry) else {
            throw AssistantAutomationRunner.HandoffError.executionUnavailable
        }
        return owned
    }

    // Origin describes this transition's trigger; background reconciliation is automatic.
    private func update(_ id: UUID, origin: MRAutomationEvent.Origin? = nil, _ mutate: (inout MRTodoIntent) -> Void) {
        guard let index = settings.mrActionIntents.firstIndex(where: { $0.id == id }) else { return }
        let previous = settings.mrActionIntents[index]
        mutate(&settings.mrActionIntents[index])
        let current = settings.mrActionIntents[index]
        let changed = previous.state != current.state || previous.error != current.error || previous.jobID != current.jobID
        // Preserve a historical application rejection even when fresh evidence repairs it.
        if previous.state == .failed, current.state != .failed || current.error != previous.error || current.jobID != previous.jobID {
            recordIntentEvent(previous, state: .failed)
        }
        if current.state == .failed {
            recordIntentEvent(current, state: .failed, origin: origin ?? (changed ? .automatic : nil),
                now: origin != nil || changed ? Date() : nil)
        }
        if changed {
            if current.state == .completed { recordIntentEvent(current, state: .completed, origin: origin ?? .automatic, now: Date()) }
        }
        settings.mrActionIntents[index].updatedAt = Date()
        settings.save()
    }

    private func recordIntentEvent(_ intent: MRTodoIntent, state: MRAutomationEvent.State,
                                   origin: MRAutomationEvent.Origin? = nil, now: Date? = nil) {
        guard let action = MRAutomationEvent.Action(rawValue: intent.kind.rawValue),
              !settings.automationEvents.contains(where: { $0.target == intent.target && $0.intentID == intent.id
                  && $0.jobID == intent.jobID && $0.state == state
                  && (origin == nil || $0.origin == origin)
                  && $0.message == intent.error.map(GlabService.redactWorkflowEvidence) }) else { return }
        // Historical capture keeps an existing trigger; new transitions supply their own origin.
        settings.recordAutomationEvent(target: intent.target, action: action, origin: origin ?? .automatic,
            state: state, message: intent.error, intentID: intent.id, jobID: intent.jobID, now: now ?? intent.updatedAt)
    }
    private func isCurrent(_ host: String, _ username: String) -> Bool {
        glab.resolvedHost == host && glab.currentUsername == username
    }
}
