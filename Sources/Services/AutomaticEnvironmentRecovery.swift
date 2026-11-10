import Foundation

/// Starts one fresh, policy-bound follow-up after a proven local temporary-file failure.
@MainActor
final class AutomaticEnvironmentRecovery {
    struct Snapshot {
        let request: GitLabMergeRequest
        let user: GitLabAuthenticatedUser
        let discussions: [GitLabMergeRequestDiscussion]
    }
    typealias Fetch = @MainActor (AssistantAutomationRunner.Handoff) async throws -> Snapshot
    typealias Launch = @MainActor (AssistantAutomationRunner.Handoff, Snapshot, String) async throws -> AssistantAutomationRunner.Handoff
    private let settings: SettingsManager
    private let fetch: Fetch
    private let launch: Launch
    private var checking: Set<UUID> = []
    var onScheduled: ((UUID, AssistantAutomationRunner.Handoff) -> Void)?

    init(settings: SettingsManager, fetch: @escaping Fetch, launch: @escaping Launch) {
        self.settings = settings; self.fetch = fetch; self.launch = launch
    }

    func recover(host: String, username: String) async {
        let candidates = settings.assistantHandoffs.filter {
            $0.key.work.host == host && $0.key.username == username && eligible($0)
        }
        for original in candidates {
            guard !Task.isCancelled, checking.insert(original.id).inserted else { continue }
            defer { checking.remove(original.id) }
            let configuration = settings.automation
            do {
                let first = try await fetch(original)
                guard valid(first, for: original), eligible(original) else { continue }
                let fresh = try await fetch(original)
                guard !Task.isCancelled, settings.automation == configuration,
                      valid(fresh, for: original), sameEvidence(first, fresh),
                      let index = settings.assistantHandoffs.firstIndex(where: { $0.id == original.id }),
                      eligible(settings.assistantHandoffs[index]),
                      valid(fresh, for: settings.assistantHandoffs[index]) else { continue }
                // Persist before scheduling: an interrupted/ambiguous launch must not
                // replay automatically after a restart.
                guard settings.saveEnvironmentRecoveryAttempt(original.id) else { continue }
                let prompt = """
                    Start one fresh follow-up assessment after a proven local temporary-file failure.
                    Before acting, re-read the live MR, every relevant discussion, existing replies and private drafts.
                    Do not replay the earlier run's commands or assume its remote changes failed. Reconcile existing work,
                    make only still-needed corrections, and preserve user-created drafts. Use the private writable TMPDIR
                    and inherited JAVA_TOOL_OPTIONS java.io.tmpdir for every verification command. Verify meaningfully;
                    do not skip tests or reduce their coverage to hide an environment failure.
                    \(original.taskPrompt ?? "Assess and address current reviewer feedback within the configured permissions.")
                    """
                let replacement = try await launch(original, fresh, prompt)
                guard let next = settings.assistantHandoffs.firstIndex(where: { $0.id == replacement.id }) else { continue }
                settings.assistantHandoffs[next].environmentRecoveryOf = original.id
                settings.save()
                let target = MRAutomationScope.Target(host: host, username: username,
                    projectID: original.key.work.projectID, iid: original.key.work.iid)
                settings.recordAutomationEvent(target: target, action: .retry, origin: .automatic, state: .queued,
                    message: String(localized: .AutomationHistory.automationHistoryEnvironmentRecoveryQueued),
                    jobID: replacement.id, relatedJobID: original.id)
                onScheduled?(original.id, settings.assistantHandoffs[next])
            } catch {
                // Original result and diagnostics remain visible. A failed fresh
                // read is not permission to schedule a worker.
                continue
            }
        }
    }

    private func eligible(_ original: AssistantAutomationRunner.Handoff) -> Bool {
        let configuration = settings.automation
        let project = original.mergeRequestURL?.gitLabProjectPath ?? ""
        let target = MRAutomationScope.Target(host: original.key.work.host, username: original.key.username,
            projectID: original.key.work.projectID, iid: original.key.work.iid)
        guard configuration.hasAutomaticActionConsent, configuration.allowFollowUpPush,
              configuration.assistant == original.key.assistant, configuration.scope.resolve(target).active,
              original.key.access != .configuredTools || configuration.permitsAssistantTools(project: project),
              !settings.ignoredMergeRequests.contains(target), original.workflow == .followUp,
              original.followUpPushAllowed == true, original.execution?.state == .blocked,
              original.environmentRecoveryAttempted != true, original.environmentRecoveryOf == nil,
              !settings.assistantHandoffs.contains(where: {
                  $0.key.work == original.key.work && $0.key.username == original.key.username
                      && ($0.execution?.state.isActive == true || $0.createdAt > original.createdAt)
              }) else { return false }
        let rule = configuration.authorFeedback
        let workflow = configuration.workflowRules[.newDiscussion]
        guard (rule.isEnabled && rule.runner == .assistant && rule.isConfigured)
                || workflow.mode == .assistant else { return false }
        let diagnostics = [original.execution?.output, original.execution?.blocker, original.execution?.summary]
            .compactMap { $0 }.joined(separator: "\n").lowercased()
        return (diagnostics.contains("operation not permitted") || diagnostics.contains("permission denied"))
            && (diagnostics.contains("createtempfile") || diagnostics.contains("temporary-file creation"))
    }

    private func valid(_ snapshot: Snapshot, for original: AssistantAutomationRunner.Handoff) -> Bool {
        let request = snapshot.request
        let configuration = settings.automation
        let rule = configuration.authorFeedback
        let workflow = configuration.workflowRules[.newDiscussion]
        let project = request.webURL.gitLabProjectPath
        let triggerEnabled = (rule.isEnabled && rule.runner == .assistant && rule.isConfigured && rule.includes(project: project))
            || (workflow.mode == .assistant && workflow.includes(request))
        return snapshot.user.username == original.key.username && request.author.id == snapshot.user.id
            && request.projectID == original.key.work.projectID && request.iid == original.key.work.iid
            && request.webURL.isGitLabMergeRequest(host: original.key.work.host, iid: request.iid)
            && request.state == "opened"
            && configuration.scope.permits(request, host: original.key.work.host, username: original.key.username)
            && request.sha != nil && request.sha == original.expectedHeadSHA
            && triggerEnabled
    }

    private func sameEvidence(_ first: Snapshot, _ next: Snapshot) -> Bool {
        let a = first.request, b = next.request
        return first.user == next.user && a.webURL == b.webURL && a.author == b.author
            && a.sha == b.sha && a.semanticContextFingerprint == b.semanticContextFingerprint
            && a.sourceProjectID == b.sourceProjectID && a.sourceBranch == b.sourceBranch
            && a.targetProjectID == b.targetProjectID && a.targetBranch == b.targetBranch
            && ReviewVerdict.fingerprint(first.discussions) == ReviewVerdict.fingerprint(next.discussions)
    }
}
