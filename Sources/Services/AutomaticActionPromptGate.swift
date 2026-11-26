import Foundation

/// A verifier decision is additional permission for one action and one observed MR snapshot.
@MainActor
final class AutomaticActionPromptGate {
    typealias Verifier = AutomaticActionPromptVerifier

    struct Policy: Equatable, Sendable {
        let criteria: String
        let configuration: Verifier.Configuration

        @MainActor init?(_ action: MRAutomaticAction, target: MRAutomationScope.Target, settings: SettingsManager) {
            guard settings.actionPreference(action, for: target) == .default else { return nil }
            let automation = settings.automation
            let prompt: AutomaticActionPrompt
            switch action {
            case .approval:
                guard automation.autoApproveMode == .prompt else { return nil }
                prompt = automation.autoApprovePrompt
            case .merge:
                guard automation.autoMergeMode == .prompt else { return nil }
                prompt = automation.autoMergePrompt
            case .commentPublication: return nil
            }
            criteria = prompt.criteria.trimmingCharacters(in: .whitespacesAndNewlines)
            configuration = .init(automation)
        }
    }

    struct Candidate: Equatable, Sendable {
        let action: MRAutomaticAction
        let mergeAction: MergeSubmissionAction?
        let target: MRAutomationScope.Target
        let userID: Int
        let accountRevision: UInt64
        let policy: Policy
        let requestDigest: String
        let discussionDigest: String

        init?(action: MRAutomaticAction, mergeAction: MergeSubmissionAction? = nil,
              target: MRAutomationScope.Target, userID: Int, accountRevision: UInt64, policy: Policy,
              request: GitLabMergeRequest, discussions: [GitLabMergeRequestDiscussion]) {
            guard request.projectID == target.projectID, request.iid == target.iid, request.isOpen,
                  request.webURL.isGitLabMergeRequest(host: target.host, iid: request.iid),
                  request.sha?.isEmpty == false,
                  let requestDigest = Verifier.digest(request),
                  let discussionDigest = Verifier.digest(discussions) else { return nil }
            self.action = action
            self.mergeAction = mergeAction
            self.target = target
            self.userID = userID
            self.accountRevision = accountRevision
            self.policy = policy
            self.requestDigest = requestDigest
            self.discussionDigest = discussionDigest
        }

        func matches(_ request: GitLabMergeRequest) -> Bool { Verifier.digest(request) == requestDigest }
        func matches(_ discussions: [GitLabMergeRequestDiscussion]) -> Bool { Verifier.digest(discussions) == discussionDigest }
    }

    private struct Recent {
        let candidate: Candidate
        let allowed: Bool
        let retryAfter: Date
    }

    private let verify: Verifier.Verify
    private var recent: [MRAutomationScope.Target: Recent] = [:]

    init(verify: @escaping Verifier.Verify) { self.verify = verify }

    func allows(_ candidate: Candidate, request: GitLabMergeRequest, discussions: [GitLabMergeRequestDiscussion],
                settings: SettingsManager, accountIsCurrent: () -> Bool, isEligible: () -> Bool) async -> Bool {
        guard !Task.isCancelled, accountIsCurrent(), isEligible() else { return false }
        let now = Date()
        if let previous = recent[candidate.target], previous.candidate == candidate, previous.retryAfter > now {
            return previous.allowed
        }
        var allowed = false
        var state = MRAutomationEvent.State.blocked
        let message: LocalizedStringResource
        if candidate.policy.criteria.isEmpty {
            message = .AutomationHistory.automationHistoryPromptEmpty
        } else {
            let input = Verifier.Input(action: candidate.action, mergeAction: candidate.mergeAction,
                criteria: candidate.policy.criteria, target: candidate.target, userID: candidate.userID,
                request: request, discussions: discussions)
            do {
                let result = try await verify(input, candidate.policy.configuration)
                guard let reason = result.validatedReason else { throw Verifier.Failure.invalidOutput }
                switch result.decision {
                case .allow:
                    allowed = true
                    state = .completed
                    message = .AutomationHistory.automationHistoryPromptAllowed(reason)
                case .deny: message = .AutomationHistory.automationHistoryPromptDenied(reason)
                case .uncertain: message = .AutomationHistory.automationHistoryPromptUncertain(reason)
                }
            } catch Verifier.Failure.unavailable {
                state = .failed
                message = .AutomationHistory.automationHistoryPromptUnavailable
            } catch {
                state = .failed
                message = .AutomationHistory.automationHistoryPromptFailed
            }
        }
        guard accountIsCurrent() else { return false }
        let current = !Task.isCancelled && isEligible()
        settings.recordAutomationEvent(target: candidate.target,
            action: candidate.action == .approval ? .approvalPrompt : .mergePrompt,
            origin: .automatic, state: current ? state : .blocked,
            message: String(localized: current ? message : .AutomationHistory.automationHistoryPromptChanged(String(localized: message))))
        guard current, settings.automaticActionsAllowed else { return false }
        let finished = Date()
        recent = recent.filter { $0.value.retryAfter > finished }
        recent[candidate.target] = Recent(candidate: candidate, allowed: allowed,
            retryAfter: finished.addingTimeInterval(ReadOnlyAssessmentRetry.cooldown))
        return allowed
    }
}
