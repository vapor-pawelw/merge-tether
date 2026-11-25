import Foundation

extension AssistantAutomationRunner {
    static func originatingBlockerDiagnosis(for job: Handoff, settings: SettingsManager) -> MergeBlockerDiagnosis? {
        if let diagnosis = job.blockerDiagnosis { return diagnosis }
        return settings.workflowActivity.first {
            $0.assistantJobID == job.id && $0.host == job.key.work.host && $0.user.username == job.key.username
                && $0.event.mergeRequest.projectID == job.key.work.projectID && $0.event.mergeRequest.iid == job.key.work.iid
                && $0.event.mergeRequest.sha == job.expectedHeadSHA
        }?.event.blockerDiagnosis
    }

    static func originatingWorkflowEvent(for job: Handoff, settings: SettingsManager) -> MergeWorkflowTrigger? {
        let kinds = Set(settings.workflowActivity.filter {
            $0.assistantJobID == job.id && $0.host == job.key.work.host && $0.user.username == job.key.username
                && $0.event.mergeRequest.projectID == job.key.work.projectID && $0.event.mergeRequest.iid == job.key.work.iid
        }.map(\.event.kind))
        return kinds.count == 1 ? kinds.first : nil
    }

    static func migrateTaskOrigins(settings: SettingsManager) {
        var changed = false
        for index in settings.assistantHandoffs.indices {
            let job = settings.assistantHandoffs[index]
            if job.workflowEventKind == nil, job.workflowOriginKnown != true,
               let kind = originatingWorkflowEvent(for: job, settings: settings) {
                settings.assistantHandoffs[index].workflowEventKind = kind
                settings.assistantHandoffs[index].workflowOriginKnown = true
                changed = true
            }
            if job.taskIntent == nil, job.workflow == nil, job.reviewModel == nil,
               job.pipelineReservation == nil, job.foreignPipelineDiagnosis == nil,
               let source = job.expectedHeadSHA, GlabService.isFullGitSHA(source),
               settings.conflictReceipts.contains(where: {
                   $0.jobID == job.id && $0.host == job.key.work.host && $0.projectID == job.key.work.projectID
                       && $0.iid == job.key.work.iid && $0.sourceSHA == source && $0.userID > 0
                       && GlabService.isFullGitSHA($0.targetSHA) && $0.allowsPush == job.allowsPush
               }) {
                settings.assistantHandoffs[index].taskIntent = .conflictResolution
                settings.assistantHandoffs[index].workflowOriginKnown = true
                changed = true
            }
        }
        if changed { settings.save() }
    }
    /// Shared admission policy for initial retry checks and the final live MR snapshot.
    static func automaticRetryPermission(for job: Handoff, configuration: AutomationSettings,
                                         request: GitLabMergeRequest? = nil, origin: MergeWorkflowTrigger? = nil,
                                         confirmedPipelineClaim: Bool = false) -> Bool {
        let project = request?.webURL.gitLabProjectPath ?? job.mergeRequestURL?.gitLabProjectPath ?? ""
        guard configuration.hasAutomaticActionConsent,
              job.key.access != .configuredTools || configuration.permitsAssistantTools(project: project),
              !job.allowsPush || configuration.permitsConflictPush(project: project) else { return false }
        let trigger = job.workflowEventKind ?? origin
        let pipeline = job.pipelineReservation != nil || job.foreignPipelineDiagnosis != nil || job.taskIntent == .pipelineDiagnosis
        func permits(_ rule: MergeWorkflowRule) -> Bool {
            rule.mode == .assistant && (request.map { rule.includes($0) } ?? rule.includes(project: project))
        }
        if pipeline || trigger == .pipelineFailure {
            guard configuration.autoClaimPipelineFailures || confirmedPipelineClaim,
                  permits(configuration.workflowRules[.pipelineFailure]) else { return false }
        }
        if let trigger { return permits(configuration.workflowRules[trigger]) }
        if pipeline { return true }
        if job.taskIntent == .conflictResolution || job.allowsPush { return configuration.conflictTasksEnabled }
        guard job.workflowOriginKnown == true else { return false }
        if job.workflow == .review || job.reviewModel != nil {
            let rule = configuration.reviewRequested
            return rule.isEnabled && rule.runner == .assistant && rule.isConfigured && rule.includes(project: project)
        }
        if job.workflow == .followUp {
            let rule = configuration.authorFeedback
            let target = MRAutomationScope.Target(host: job.key.work.host, username: job.key.username,
                projectID: job.key.work.projectID, iid: job.key.work.iid)
            return rule.isEnabled && rule.runner == .assistant && rule.isConfigured && rule.includes(project: project)
                && (request.map { configuration.scope.permits($0, host: target.host, username: target.username) } ?? true)
        }
        return false
    }

}
