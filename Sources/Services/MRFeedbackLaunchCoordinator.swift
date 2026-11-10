import Foundation
import Observation

/// Owns feedback preflight attempts only. Admitted execution and replay budgets remain durable owners' work.
@MainActor @Observable
final class MRFeedbackLaunchCoordinator {
    typealias Item = MergeRequestAttentionMonitor.Item
    typealias Outcome = TodoAutomationService.FeedbackPreparationOutcome
    struct Account: Hashable {
        let host: String
        let username: String
        let revision: UInt64
    }
    struct Context {
        let source: MergeRequestDependencySummary.Context
        let semanticContext: String
        let authorID: Int
        let authorUsername: String
        let draft: Bool?
        let noteIDs: [Int]
        let discussionFingerprint: String?
        let noteRevisions: [Int: String]?
        let configuration: AutomationSettings
        let decisionRevision: String?

        init(request: GitLabMergeRequest, noteIDs: [Int], fingerprint: String?,
             notes: [GitLabMergeRequestDiscussion.Note]? = nil, configuration: AutomationSettings,
             decisionRevision: String? = nil) {
            source = .init(request); semanticContext = request.semanticContextFingerprint
            authorID = request.author.id; authorUsername = request.author.username; draft = request.draft
            self.noteIDs = Array(Set(noteIDs)).sorted(); discussionFingerprint = fingerprint
            noteRevisions = notes.map { notes in
                Dictionary(notes.compactMap { note -> (Int, String)? in
                    guard let id = note.id, noteIDs.contains(id), let revision = IgnoredFeedbackSuggestion.revision(of: note) else { return nil }
                    return (id, revision)
                }, uniquingKeysWith: { first, _ in first })
            }
            self.configuration = configuration; self.decisionRevision = decisionRevision
        }
        func isSameOperation(as other: Context) -> Bool {
            guard source == other.source, semanticContext == other.semanticContext, authorID == other.authorID,
                  authorUsername == other.authorUsername, draft == other.draft, noteIDs == other.noteIDs,
                  discussionFingerprint == other.discussionFingerprint, configuration == other.configuration,
                  decisionRevision == other.decisionRevision else { return false }
            if let noteRevisions, let otherRevisions = other.noteRevisions { return noteRevisions == otherRevisions }
            // A known full snapshot has one identity across raw and verified entry points.
            return discussionFingerprint != nil || noteRevisions == other.noteRevisions
        }
        func matches(_ item: Item, configuration: AutomationSettings, decisionRevision: String?) -> Bool {
            guard let request = item.mergeRequest,
                  source == .init(request), semanticContext == request.semanticContextFingerprint,
                  authorID == request.author.id, authorUsername == request.author.username, draft == request.draft,
                  self.configuration == configuration, self.decisionRevision == decisionRevision,
                  discussionFingerprint == item.observedDiscussionFingerprint,
                  Set(noteIDs).isSubset(of: Set(item.feedback.compactMap(\.id))) else { return false }
            if let noteRevisions {
                return noteRevisions == Context(request: request, noteIDs: noteIDs, fingerprint: item.observedDiscussionFingerprint,
                    notes: item.feedback, configuration: configuration, decisionRevision: decisionRevision).noteRevisions
            }
            return true
        }
    }
    struct Failure {
        let account: Account
        let context: Context
        func matches(_ item: Item, host: String, username: String, revision: UInt64, configuration: AutomationSettings,
                     decisionRevision: String? = nil) -> Bool {
            account == .init(host: host, username: username, revision: revision)
                && context.matches(item, configuration: configuration, decisionRevision: decisionRevision)
        }
    }
    private struct Key: Hashable { let account: Account; let id: Item.ID }
    private struct Attempt { let id: UUID; let key: Key; let context: Context }
    private enum Phase { case preparing, failed }
    private struct Operation { let attempt: Attempt; var phase: Phase }
    private var operations: [Key: Operation] = [:]
    private let settings: SettingsManager
    private let glab: GlabService
    private let automation: TodoAutomationService
    private let inbox: InboxTodoStore
    private let providers: AssistantDependencyMonitor
    private let health: AssistantCLIHealthStore
    private let residualLookup: @MainActor (GitLabMergeRequest, String) -> AuthorFeedbackResidual?

    init(settings: SettingsManager, glab: GlabService, automation: TodoAutomationService, inbox: InboxTodoStore,
         providers: AssistantDependencyMonitor, health: AssistantCLIHealthStore,
         residualLookup: @escaping @MainActor (GitLabMergeRequest, String) -> AuthorFeedbackResidual? = { _, _ in nil }) {
        self.settings = settings; self.glab = glab; self.automation = automation; self.inbox = inbox
        self.providers = providers; self.health = health; self.residualLookup = residualLookup
    }
    private var account: Account? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return nil }
        return .init(host: host, username: username, revision: glab.accountRevision)
    }
    var failures: [Failure] {
        operations.values.compactMap { operation in
            let attempt = operation.attempt
            guard attempt.key.account == account, case .failed = operation.phase,
                  attempt.context.configuration == settings.automation,
                  attempt.context.decisionRevision == decisionRevision(account: attempt.key.account, id: attempt.key.id) else { return nil }
            return .init(account: operation.attempt.key.account, context: operation.attempt.context)
        }
    }
    private func work(_ account: Account, _ id: Item.ID) -> AssistantAutomationRunner.MergeRequestWork {
        .init(host: account.host, projectID: id.projectID, iid: id.iid)
    }
    private func decisionRevision(account: Account, id: Item.ID) -> String? {
        AssistantAutomationRunner.feedbackDecisionRevision(work: work(account, id), username: account.username, settings: settings)
    }
    private func noteIDs(for item: Item, account: Account) -> [Int] {
        let notes = TodoAutomationEvent.feedbackWithoutTodo(item.feedback, todos: inbox.allTodos,
            host: account.host, projectID: item.id.projectID, iid: item.id.iid, username: account.username).compactMap(\.id)
        return AssistantAutomationRunner.unhandledFeedback(notes, work: work(account, item.id), username: account.username, settings: settings)
    }
    func automaticallyHandlesFeedback(_ item: Item) -> Bool {
        guard settings.automaticActionsAllowed, let account, let request = item.authoredRequest,
              request.state == "opened", request.author.username == account.username,
              item.url.isGitLabMergeRequest(host: account.host, iid: item.id.iid),
              settings.automation.scope.permits(request, host: account.host, username: account.username) else { return false }
        let rule = settings.automation.workflowRules[.newDiscussion], feedback = settings.automation.authorFeedback
        return feedback.runner == .assistant && feedback.isConfigured && feedback.includes(project: item.url.gitLabProjectPath)
            && (feedback.isEnabled || (rule.mode == .assistant && rule.includes(request)))
    }
    func action(for item: Item) -> TodoAutomationService.ActionState? {
        guard let account, inbox.host == account.host, let request = item.authoredRequest,
              request.author.username == account.username, item.url.isGitLabMergeRequest(host: account.host, iid: item.id.iid),
              providers.available.contains(settings.automation.assistant), health.hold(for: settings.automation.assistant) == nil else { return nil }
        let rule = settings.automation.authorFeedback
        guard rule.runner == .assistant, rule.isConfigured, rule.includes(project: item.url.gitLabProjectPath) else { return nil }
        let operation = operations[.init(account: account, id: item.id)]
        if let operation, case .preparing = operation.phase { return .running }
        guard !noteIDs(for: item, account: account).isEmpty else { return nil }
        if let operation, case .failed = operation.phase,
           operation.attempt.context.matches(item, configuration: settings.automation,
               decisionRevision: decisionRevision(account: account, id: item.id)) { return .failed }
        return .ready(.assistant)
    }
    private func begin(account: Account, id: Item.ID, context: Context, manual: Bool) -> Attempt? {
        guard self.account == account else { return nil }
        let key = Key(account: account, id: id)
        if let operation = operations[key] {
            if case .preparing = operation.phase { return nil }
            if !manual, case .failed = operation.phase, operation.attempt.context.isSameOperation(as: context) { return nil }
        }
        // Command boundary only: reading ActionState never cleans or dispatches anything.
        operations = operations.filter { $0.key.account == account }
        let attempt = Attempt(id: UUID(), key: key, context: context)
        operations[key] = .init(attempt: attempt, phase: .preparing)
        return attempt
    }
    private func owns(_ attempt: Attempt) -> Bool {
        account == attempt.key.account && operations[attempt.key]?.attempt.id == attempt.id
    }
    private func discardPreparing(_ attempt: Attempt) {
        guard owns(attempt), let operation = operations[attempt.key], case .preparing = operation.phase else { return }
        operations[attempt.key] = nil
    }
    private func finish(_ attempt: Attempt, outcome: Outcome) {
        guard owns(attempt) else { return }
        // Neither admission nor a silent guard return is a new error or an admission cache.
        // Existing command sources and durable guards decide any later command.
        operations[attempt.key] = nil
    }
    private func fail(_ attempt: Attempt) {
        guard owns(attempt), settings.automation == attempt.context.configuration,
              attempt.context.decisionRevision == decisionRevision(account: attempt.key.account, id: attempt.key.id) else { return }
        operations[attempt.key]?.phase = .failed
    }

    func runAttentionFeedback(for item: Item, manual: Bool = true) async {
        guard manual || settings.automaticActionsAllowed,
              let action = action(for: item), action == .ready(.assistant) || action == .failed,
              let account, let request = item.authoredRequest else { return }
        let notes = noteIDs(for: item, account: account)
        let context = Context(request: request, noteIDs: notes, fingerprint: item.observedDiscussionFingerprint,
            notes: item.feedback, configuration: settings.automation,
            decisionRevision: decisionRevision(account: account, id: item.id))
        guard let attempt = begin(account: account, id: item.id, context: context, manual: manual) else { return }
        defer { discardPreparing(attempt) }
        do {
            let outcome = try await automation.prepareFeedback(work: work(account, item.id), noteIDs: notes,
                username: account.username, settings: settings, glab: glab, manual: manual) {
                    self.owns(attempt) && self.inbox.host == account.host
                        && self.noteIDs(for: item, account: account) == notes
                        && (manual || self.automaticallyHandlesFeedback(item))
                }
            finish(attempt, outcome: outcome)
        } catch {
            fail(attempt)
            Log.monitor.error("Could not prepare MR feedback: \(String(describing: error), privacy: .private)")
        }
    }

    func runVerifiedAuthorFeedback(request: GitLabMergeRequest, noteIDs: Set<Int>, fingerprint: String,
                                  residual: AuthorFeedbackResidual? = nil, manual: Bool = true) async {
        guard manual || settings.automaticActionsAllowed, let account,
              request.author.username == account.username, !noteIDs.isEmpty,
              request.webURL.isGitLabMergeRequest(host: account.host, iid: request.iid) else { return }
        let configuration = settings.automation, rule = configuration.authorFeedback
        let workflow = configuration.workflowRules[.newDiscussion]
        guard rule.runner == .assistant, rule.isConfigured, rule.includes(project: request.webURL.gitLabProjectPath),
              manual || (configuration.packageDecision != .disabled
                  && configuration.scope.permits(request, host: account.host, username: account.username)
                  && (rule.isEnabled || (workflow.mode == .assistant && workflow.includes(request)))) else { return }
        let id = Item.ID(projectID: request.projectID, iid: request.iid)
        guard !AssistantAutomationRunner.isWorking(on: work(account, id)) else { return }
        let context = Context(request: request, noteIDs: noteIDs.sorted(), fingerprint: fingerprint, configuration: configuration,
            decisionRevision: decisionRevision(account: account, id: id))
        guard let attempt = begin(account: account, id: id, context: context, manual: manual) else { return }
        defer { discardPreparing(attempt) }
        do {
            let outcome = try await automation.prepareFeedback(work: work(account, id), noteIDs: noteIDs.sorted(),
                username: account.username, settings: settings, glab: glab, manual: manual, verifiedFingerprint: fingerprint,
                expectedHeadSHA: request.sha, verifiedResidual: residual ?? residualLookup(request, fingerprint)) {
                    self.owns(attempt) && self.settings.automation == configuration
                        && (manual || self.settings.automaticActionsAllowed)
                }
            finish(attempt, outcome: outcome)
        } catch {
            fail(attempt)
            Log.monitor.error("Could not handle verified author feedback: \(String(describing: error), privacy: .private)")
        }
    }
}
