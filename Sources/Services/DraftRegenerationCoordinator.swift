import Foundation
import MergeTetherRemote
import Observation

@MainActor
@Observable
final class DraftRegenerationCoordinator {
    struct Candidate {
        let request: GitLabMergeRequest
        let drafts: [GitLabDraftNote]

        var id: MergeRequestAttentionMonitor.Item.ID { .init(projectID: request.projectID, iid: request.iid) }
    }

    private struct Account: Equatable, Sendable {
        let host: String
        let username: String
        let revision: UInt64
        let executable: URL
    }

    private struct CapturedDrafts: Encodable {
        let mergeRequest: String
        let head: String?
        let drafts: [GitLabDraftNote]
    }

    private struct LiveContext {
        let request: GitLabMergeRequest
        let user: GitLabAuthenticatedUser
        let discussionFingerprint: String
        let drafts: [GitLabDraftNote]
    }

    private struct Prepared {
        let context: LiveContext
        let draft: GitLabDraftNote
    }

    private enum ContextError: Error { case changed, busy }

    private let glab: GlabService
    private let settings: SettingsManager?
    private let provenanceDirectory: URL
    private let candidates: @MainActor () -> [Candidate]
    private let isBusy: @MainActor (MergeRequestAttentionMonitor.Item.ID) -> Bool
    private let onUpdate: @MainActor (MergeRequestAttentionMonitor.Item.ID, GitLabDraftNote, GitLabDraftNote) -> Void
    private let generate: @MainActor (DraftRegenerationGenerationInput) async throws -> [DraftRegenerationGeneratedDraft]

    private var currentBatch: DraftRegenerationBatch?
    private var batchAccount: Account?
    private var terminating = false
    @ObservationIgnored private var generation: Task<Void, Never>?
    @ObservationIgnored private var application: Task<RemoteCommandResult.Status, Never>?
    @ObservationIgnored private var prepared: [String: Prepared] = [:]
    @ObservationIgnored private var reserved: [MergeRequestAttentionMonitor.Item.ID: [GitLabDraftNote]] = [:]

    init(glab: GlabService, settings: SettingsManager?, provenanceDirectory: URL = AICommentProvenanceStore.directory,
         candidates: @escaping @MainActor () -> [Candidate],
         isBusy: @escaping @MainActor (MergeRequestAttentionMonitor.Item.ID) -> Bool = { _ in false },
         onUpdate: @escaping @MainActor (MergeRequestAttentionMonitor.Item.ID, GitLabDraftNote, GitLabDraftNote) -> Void = { _, _, _ in },
         generate: @escaping @MainActor (DraftRegenerationGenerationInput) async throws -> [DraftRegenerationGeneratedDraft] = DraftRegenerationGenerator.generate) {
        self.glab = glab
        self.settings = settings
        self.provenanceDirectory = provenanceDirectory
        self.candidates = candidates
        self.isBusy = isBusy
        self.onUpdate = onUpdate
        self.generate = generate
    }

    private var account: Account? {
        guard let host = glab.resolvedHost, !host.isEmpty, let username = glab.currentUsername, !username.isEmpty,
              let executable = glab.glabPath else { return nil }
        return .init(host: host, username: username, revision: glab.accountRevision, executable: executable)
    }

    var isAvailable: Bool { !terminating && account != nil && settings != nil }
    var batch: DraftRegenerationBatch? { batchAccount == account ? currentBatch : nil }

    var mergeRequestCount: Int { selection(for: .all).count }

    func count(for scope: DraftRegenerationScope) -> Int {
        selection(for: scope).reduce(0) { $0 + $1.drafts.count }
    }

    func scopeToken(for scope: DraftRegenerationScope) -> String? { token(selection(for: scope)) }

    private func token(_ selection: [Candidate]) -> String? {
        guard !selection.isEmpty else { return nil }
        return try? RemoteDigest.token(selection.map {
            CapturedDrafts(mergeRequest: $0.request.draftProofRecoveryContextFingerprint, head: $0.request.sha, drafts: $0.drafts)
        })
    }

    private func selection(for scope: DraftRegenerationScope) -> [Candidate] {
        guard let account else { return [] }
        return candidates().compactMap { candidate -> Candidate? in
            let request = candidate.request
            guard request.state == "opened", request.projectID > 0, request.iid > 0,
                  request.webURL.isGitLabMergeRequest(host: account.host, iid: request.iid),
                  let head = request.sha, GlabService.isFullGitSHA(head) else { return nil }
            let draftID: Int?
            switch scope {
            case .all:
                draftID = nil
            case .mergeRequest(let projectID, let iid):
                guard request.projectID == projectID, request.iid == iid else { return nil }
                draftID = nil
            case .draft(let projectID, let iid, let id):
                guard request.projectID == projectID, request.iid == iid else { return nil }
                draftID = id
            }
            let counts = candidate.drafts.reduce(into: [Int: Int]()) { counts, draft in
                if let id = draft.id { counts[id, default: 0] += 1 }
            }
            let drafts = candidate.drafts.filter { draft in
                guard let id = draft.id, counts[id] == 1, DraftPublicationSelection.canSelect(draft) else { return false }
                return draftID == nil || id == draftID
            }.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
            return drafts.isEmpty ? nil : .init(request: request, drafts: drafts)
        }.sorted { ($0.id.projectID, $0.id.iid) < ($1.id.projectID, $1.id.iid) }
    }

    /// Starts a run requested by a paired phone. Remote clients cannot supply prompt text:
    /// they may only choose a style whose wording is defined here on the Mac.
    @discardableResult
    func startRemote(_ scope: DraftRegenerationScope, instructions: String?, style: DraftRegenerationStyle?,
                     expectedToken: String) -> Bool {
        guard instructions == nil else { return false }
        return start(scope, instructions: style.map(Self.instructions(for:)), expectedToken: expectedToken)
    }

    static func instructions(for style: DraftRegenerationStyle) -> String {
        switch style {
        case .concise: "Make each comment shorter and more concise while keeping its substantiated point."
        case .friendlier: "Make each comment friendlier and more collaborative while keeping its substantiated point."
        case .moreDetailed: "Explain the reasoning behind each comment more clearly, using only verified context."
        case .moreDirect: "Make each comment more direct and actionable while staying polite."
        }
    }

    @discardableResult
    func start(_ scope: DraftRegenerationScope, instructions: String?, expectedToken: String? = nil) -> Bool {
        guard !terminating, let account, let settings, batch == nil,
              settings.automation.selectedAssistant != nil else { return false }
        let instructions = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let instructions, instructions.isEmpty || instructions.utf8.count > DraftRegenerationScope.maximumInstructionsBytes { return false }
        let selection = selection(for: scope)
        guard !selection.isEmpty, expectedToken == nil || expectedToken == token(selection) else { return false }
        cancelAndClear()
        reserved = Dictionary(selection.map { ($0.id, $0.drafts) }, uniquingKeysWith: { first, _ in first })
        let id = UUID()
        batchAccount = account
        currentBatch = .init(id: id, scope: scope, total: selection.reduce(0) { $0 + $1.drafts.count },
            completed: 0, phase: .generating, proposals: [])
        let configuration = settings.automation
        generation = Task { [weak self] in
            await self?.prepare(selection, id: id, account: account, instructions: instructions, configuration: configuration)
        }
        return true
    }

    @discardableResult
    func discard(_ batchID: UUID) -> Bool {
        guard let batch, batch.id == batchID, batch.phase != .saving else { return false }
        cancelAndClear()
        return true
    }

    func cancelAndClear() {
        generation?.cancel()
        application?.cancel()
        generation = nil
        application = nil
        currentBatch = nil
        batchAccount = nil
        prepared.removeAll()
        reserved.removeAll()
    }

    func prepareForTermination() -> Task<Void, Never>? {
        terminating = true
        let generation = self.generation, application = self.application
        cancelAndClear()
        guard generation != nil || application != nil else { return nil }
        return Task {
            await generation?.value
            _ = await application?.value
        }
    }

    func isSaving(_ id: MergeRequestAttentionMonitor.Item.ID) -> Bool {
        batch?.phase == .saving && reserved[id] != nil
    }

    func isHeldForAutomaticPublication(_ draft: GitLabDraftNote, in id: MergeRequestAttentionMonitor.Item.ID) -> Bool {
        guard let account else { return false }
        if let batch, batch.phase != .finished, reserved[id]?.contains(draft) == true { return true }
        return settings?.holdsRegeneratedDraft(draft, for: target(id, account: account)) == true
    }

    private func target(_ id: MergeRequestAttentionMonitor.Item.ID, account: Account) -> MRAutomationScope.Target {
        .init(host: account.host, username: account.username, projectID: id.projectID, iid: id.iid)
    }

    private func active(_ id: UUID, _ account: Account) -> Bool {
        !Task.isCancelled && currentBatch?.id == id && self.account == account
    }

    private func fetch(_ expected: GitLabMergeRequest, account: Account, batchID: UUID) async throws -> LiveContext {
        let id = MergeRequestAttentionMonitor.Item.ID(projectID: expected.projectID, iid: expected.iid)
        guard active(batchID, account) else { throw ContextError.changed }
        guard !isBusy(id) else { throw ContextError.busy }
        async let user = glab.fetchAuthenticatedUser(host: account.host, expectedUsername: account.username)
        async let request = glab.fetchMergeRequest(projectID: id.projectID, iid: id.iid, host: account.host)
        async let threads = glab.fetchMergeRequestDiscussions(projectID: id.projectID, iid: id.iid, host: account.host)
        let (authenticated, live, discussions) = try await (user, request, threads)
        guard active(batchID, account), !isBusy(id), authenticated.id > 0,
              live.sha == expected.sha, live.draftProofRecoveryContextFingerprint == expected.draftProofRecoveryContextFingerprint,
              let fingerprint = ManualDiscussionResolution.fingerprint(discussions) else { throw ContextError.changed }
        let drafts = try await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid, host: account.host, userID: authenticated.id)
        guard active(batchID, account), !isBusy(id) else { throw ContextError.changed }
        return .init(request: live, user: authenticated, discussionFingerprint: fingerprint, drafts: drafts)
    }

    private func prepare(_ selection: [Candidate], id: UUID, account: Account,
                         instructions: String?, configuration: AutomationSettings) async {
        defer { if currentBatch?.id == id { generation = nil } }
        for candidate in selection {
            guard active(id, account) else { return }
            do {
                let context = try await fetch(candidate.request, account: account, batchID: id)
                let liveDrafts = candidate.drafts.filter { matches($0, in: context) }
                let changed = candidate.drafts.filter { !liveDrafts.contains($0) }
                append(changed.map { proposal(for: $0, request: candidate.request, issue: .changed) }, to: id, account: account)
                for start in stride(from: 0, to: liveDrafts.count, by: 8) {
                    guard active(id, account) else { return }
                    let chunk = Array(liveDrafts[start..<min(start + 8, liveDrafts.count)])
                    await prepare(chunk, context: context, id: id, account: account,
                                  instructions: instructions, configuration: configuration)
                }
            } catch {
                let issue: DraftRegenerationProposal.Issue = (error as? ContextError) == .changed ? .changed : .unavailable
                append(candidate.drafts.map { proposal(for: $0, request: candidate.request, issue: issue) }, to: id, account: account)
            }
        }
        guard active(id, account) else { return }
        currentBatch?.phase = .ready
    }

    private func prepare(_ drafts: [GitLabDraftNote], context: LiveContext, id: UUID, account: Account,
                         instructions: String?, configuration: AutomationSettings) async {
        let request = context.request
        do {
            guard settings?.automation.selectedAssistant == configuration.selectedAssistant else { throw ContextError.changed }
            let output = try await generate(.init(drafts: drafts, instructions: instructions, request: request,
                                                  host: account.host, user: context.user, configuration: configuration))
            guard active(id, account) else { return }
            let results = Dictionary(grouping: output, by: \.draftID)
            let proposals = drafts.map { draft -> DraftRegenerationProposal in
                guard let draftID = draft.id, results[draftID]?.count == 1, let result = results[draftID]?.first else {
                    return proposal(for: draft, request: request, issue: .failed)
                }
                guard let body = result.body else {
                    let explanation = result.explanation.map { GlabService.redactWorkflowEvidence(String($0.prefix(800))) }
                    return proposal(for: draft, request: request, issue: .outdated, explanation: explanation)
                }
                guard DraftRegenerationGeneratedDraft.isValidBody(body) else {
                    return proposal(for: draft, request: request, issue: .failed)
                }
                guard body != draft.note else { return proposal(for: draft, request: request, issue: .unchanged) }
                let origin = provenance(for: context, account: account)
                let recorded = AICommentProvenanceStore.generation(for: draft, context: origin, in: provenanceDirectory) != nil
                let proposal = proposal(for: draft, request: request, replacement: body, selectedByDefault: recorded)
                prepared[proposal.id] = .init(context: context, draft: draft)
                return proposal
            }
            append(proposals, to: id, account: account)
        } catch {
            let issue: DraftRegenerationProposal.Issue = error is DraftRegenerationGenerator.Unavailable ? .unavailable : .failed
            append(drafts.map { proposal(for: $0, request: request, issue: issue) }, to: id, account: account)
        }
    }

    private func append(_ proposals: [DraftRegenerationProposal], to batchID: UUID, account: Account) {
        guard active(batchID, account) else { return }
        currentBatch?.proposals.append(contentsOf: proposals)
        currentBatch?.completed += proposals.count
    }

    private func proposal(for draft: GitLabDraftNote, request: GitLabMergeRequest, replacement: String? = nil,
                          issue: DraftRegenerationProposal.Issue? = nil, selectedByDefault: Bool = false,
                          explanation: String? = nil) -> DraftRegenerationProposal {
        .init(projectID: request.projectID, iid: request.iid, draftID: draft.id ?? 0, mergeRequestTitle: request.title,
              original: draft.note ?? "", replacement: replacement, issue: issue, selectedByDefault: selectedByDefault,
              explanation: explanation)
    }

    private func matches(_ draft: GitLabDraftNote, in context: LiveContext) -> Bool {
        draft.authorID == context.user.id && context.drafts.filter { $0.id == draft.id } == [draft]
    }

    private func provenance(for context: LiveContext, account: Account) -> AICommentProvenanceStore.Context {
        .init(host: account.host, username: account.username, userID: context.user.id,
              projectID: context.request.projectID, iid: context.request.iid)
    }

    func apply(_ ids: Set<String>, batchID: UUID) async -> RemoteCommandResult.Status {
        guard !terminating, let account, let batch, batch.id == batchID, batch.phase == .ready, !ids.isEmpty,
              ids.isSubset(of: Set(prepared.keys)), let settings else { return .changed }
        currentBatch?.savingTotal = ids.count
        currentBatch?.savingCompleted = 0
        currentBatch?.phase = .saving
        let task = Task {
            await saveSelected(ids, batch: batch, account: account, settings: settings)
        }
        application = task
        return await task.value
    }

    private func saveSelected(_ ids: Set<String>, batch: DraftRegenerationBatch, account: Account,
                              settings: SettingsManager) async -> RemoteCommandResult.Status {
        let batchID = batch.id
        defer {
            if currentBatch?.id == batchID {
                currentBatch?.phase = .finished
                application = nil
                reserved.removeAll()
                prepared.removeAll()
            }
        }
        var issues: [DraftRegenerationProposal.Issue] = []
        for (index, proposal) in batch.proposals.enumerated() where ids.contains(proposal.id) {
            guard active(batchID, account) else { return .uncertain }
            guard let entry = prepared[proposal.id], let body = proposal.replacement else { continue }
            let issue = await save(entry, body: body, account: account, batchID: batchID, settings: settings)
            guard active(batchID, account) else { return .uncertain }
            issues.append(issue)
            currentBatch?.proposals[index] = self.proposal(for: entry.draft, request: entry.context.request,
                                                           replacement: body, issue: issue)
            currentBatch?.savingCompleted = issues.count
        }
        let saved = issues.filter { $0 == .saved }.count
        if saved == ids.count { return .completed }
        if saved > 0 { return .partial }
        return issues.allSatisfy { $0 == .changed } ? .changed : .failed
    }

    private func save(_ entry: Prepared, body: String, account: Account, batchID: UUID,
                      settings: SettingsManager) async -> DraftRegenerationProposal.Issue {
        let request = entry.context.request, draft = entry.draft
        let id = MergeRequestAttentionMonitor.Item.ID(projectID: request.projectID, iid: request.iid)
        do {
            let live = try await fetch(request, account: account, batchID: batchID)
            guard matches(draft, in: live), entry.context.user == live.user,
                  entry.context.discussionFingerprint == live.discussionFingerprint,
                  let draftID = draft.id, let head = live.request.sha else { return .changed }
            let reviewTarget = target(id, account: account)
            let replacement = draft.replacingBody(body)
            // The hold must be durable before an update can survive a lost response or restart.
            guard settings.holdRegeneratedDraft(replacement, for: reviewTarget) else { return .failed }
            let updated: GitLabDraftNote
            do {
                updated = try await glab.updateDraftNote(draft, body: body, projectID: id.projectID, iid: id.iid,
                    host: account.host, shouldProceed: { self.active(batchID, account) && !self.isBusy(id) })
            } catch {
                guard active(batchID, account),
                      let remaining = try? await glab.fetchOwnDraftNotes(projectID: id.projectID, iid: id.iid,
                                                                       host: account.host, userID: live.user.id),
                      let actual = remaining.first(where: { $0.matchesBodyUpdate(replacement) }),
                      remaining.filter({ $0.id == draftID }).count == 1 else { throw error }
                updated = actual
            }
            guard active(batchID, account) else { return .failed }
            try? AICommentProvenanceStore.recordGenerated([.init(id: draftID, bodySHA256: AICommentAssessmentStore.digest(body))],
                baseline: [draft], current: [updated], context: provenance(for: live, account: account), runID: batchID,
                headSHA: head, in: provenanceDirectory)
            onUpdate(id, draft, updated)
            return .saved
        } catch ContextError.changed {
            return .changed
        } catch ContextError.busy {
            return .unavailable
        } catch {
            Log.monitor.error("Could not update private draft: \(String(describing: error), privacy: .private)")
            return .failed
        }
    }
}
