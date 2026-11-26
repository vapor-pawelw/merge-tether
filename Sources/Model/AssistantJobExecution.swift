import Foundation

/// Execution is reported separately from evidence that a GitLab action was verified.
struct AssistantJobExecution: Codable, Equatable, Sendable {
    enum CancellationOrigin: String, Codable, Sendable { case user, policy }
    enum RemoteEffect: String, Codable, Sendable, Identifiable {
        case publishedComment, approval, resolvedDiscussion, sourceHead

        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .publishedComment: .AssistantJobs.assistantJobsAuditPublishedComment
            case .approval: .AssistantJobs.assistantJobsAuditApproval
            case .resolvedDiscussion: .AssistantJobs.assistantJobsAuditResolvedDiscussion
            case .sourceHead: .AssistantJobs.assistantJobsAuditSourceHead
            }
        }
    }

    enum State: String, Codable, Sendable {
        case queued, running, succeeded, blocked, failed, cancelled, interrupted, feedbackResolved
        var isActive: Bool { self == .queued || self == .running }
    }

    struct DiskAdmissionIssue: Codable, Equatable, Sendable {
        enum Cause: String, Codable, Sendable { case insufficientCapacity, capacityUnavailable }
        let cause: Cause
        let requiredBytes: Int64

        var waitingTitle: LocalizedStringResource {
            switch cause {
            case .insufficientCapacity: .AssistantJobs.assistantJobsWaitingForMacDisk
            case .capacityUnavailable: .AssistantJobs.assistantJobsWaitingToCheckMacDisk
            }
        }

        var errorTitle: LocalizedStringResource {
            switch cause {
            case .insufficientCapacity: .AssistantJobs.assistantJobsErrorMacDiskFull
            case .capacityUnavailable: .AssistantJobs.assistantJobsErrorMacDiskUnavailable
            }
        }
    }

    struct SourceHeadChange: Codable, Equatable, Sendable {
        let previousSHA: String
        let currentSHA: String
        let previousObservation: Date?
        let currentObservation: Date
        let accountID: Int
        var pushActorID: Int?

        var attributedToAnotherAccount: Bool {
            pushActorID.map { $0 > 0 && $0 != accountID } == true
        }
    }

    var state: State
    var startedAt: Date?
    var finishedAt: Date?
    var summary: String?
    var output: String?
    var error: String?
    var workingDirectory: String?
    var blocker: String? = nil
    var cancellationOrigin: CancellationOrigin? = nil
    var remoteEffects: [RemoteEffect]? = nil
    var pendingWorkerAudit: AssistantWorkerAudit.Pending? = nil
    var sourceHeadChange: SourceHeadChange? = nil
    var diskAdmissionIssue: DiskAdmissionIssue? = nil

    var prelaunchDiskFailure: DiskAdmissionIssue? {
        state == .failed && startedAt == nil ? diskAdmissionIssue : nil
    }

    var statusTitle: LocalizedStringResource {
        switch state {
        case .queued: diskAdmissionIssue?.waitingTitle ?? .AssistantJobs.assistantJobsQueued
        case .running: .AssistantJobs.assistantJobsRunning
        case .succeeded: .AssistantJobs.assistantJobsSucceeded
        case .blocked: .AssistantJobs.assistantJobsBlocked
        case .failed: .AssistantJobs.assistantJobsFailed
        case .cancelled: .AssistantJobs.assistantJobsCancelled
        case .interrupted: .AssistantJobs.assistantJobsInterrupted
        case .feedbackResolved: .AssistantJobs.assistantJobsFeedbackResolved
        }
    }

    var errorExplanation: String? {
        if let issue = prelaunchDiskFailure { return String(localized: issue.errorTitle) }
        return error.map { GlabService.redactWorkflowEvidence(AssistantJobExecutor.ExecutionError.displayMessage(for: $0)) }
    }

    var attentionExplanation: String? {
        guard state == .blocked || state == .failed else { return nil }
        for candidate in [blocker, errorExplanation] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return GlabService.redactWorkflowEvidence(text)
            }
        }
        // Earlier workers put the remaining blocker after their completed work.
        // Keep that actual explanation visible when loading an older run.
        let paragraph = summary?.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty && $0.range(of: #"^\[[^\]]+\]\([^\n]+\)$"#, options: .regularExpression) == nil }
        return paragraph.map(GlabService.redactWorkflowEvidence)
    }

    @MainActor
    static func hasUnfinishedWork(in handoffs: [AssistantAutomationRunner.Handoff],
                                  for work: AssistantAutomationRunner.MergeRequestWork, username: String,
                                  currentRequest: GitLabMergeRequest? = nil,
                                  feedbackStatus: AuthorFeedbackStatus? = nil,
                                  discussionFingerprint: String? = nil) -> Bool {
        if let currentRequest, let feedbackStatus, !feedbackStatus.codeReviewRequests.isEmpty,
           currentRequest.isOwned(by: username, includingAssignee: true), currentRequest.projectID == work.projectID,
           currentRequest.iid == work.iid, currentRequest.webURL.isGitLabMergeRequest(host: work.host, iid: work.iid),
           feedbackStatus.head == currentRequest.sha, feedbackStatus.fingerprint == discussionFingerprint,
           feedbackStatus.semanticContextFingerprint == currentRequest.semanticContextFingerprint {
            return true
        }
        let matching = handoffs.filter {
            !$0.isObsoleteReminder && $0.key.work == work && $0.key.username == username
                && !PipelineJobReconciliation.isObsolete($0, request: currentRequest)
        }
        let resolved = matching.filter { $0.execution?.state == .feedbackResolved }
        let latest = matching.lazy.filter { job in
            guard let execution = job.execution else { return true }
            if execution.state == .feedbackResolved { return false }
            if execution.state == .succeeded || execution.state.isActive { return true }
            let notes = job.selectedFollowUpNotes
            return notes.isEmpty || !resolved.contains {
                $0.createdAt > job.createdAt && notes.isSubset(of: $0.selectedFollowUpNotes)
            }
        }.max { $0.createdAt < $1.createdAt }
        guard let latest else { return false }
        if let currentRequest, feedbackStatus?.reconciles(latest, request: currentRequest,
            discussionFingerprint: discussionFingerprint) == true { return false }
        guard let state = latest.execution?.state else { return true }
        return state != .succeeded
    }

    func recoverAfterRestart(now: Date = Date()) -> Self {
        guard state.isActive else { return self }
        var recovered = self
        recovered.state = .interrupted
        recovered.diskAdmissionIssue = nil
        recovered.finishedAt = now
        return recovered
    }
}

struct AssistantJobResult: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case succeeded, blocked }
    enum Error: Swift.Error { case invalidResult, assistantFailed }

    struct GeneratedDraft: Codable, Equatable, Sendable {
        let id: Int
        let bodySHA256: String
        /// App-only Markdown for the MergeTether user. It is stored locally and never sent to GitLab.
        var extraContext: String? = nil
        var proposedSolution: Bool? = nil
    }

    struct SourceAssessment: Codable, Equatable, Sendable {
        let noteID: Int
        let bodySHA256: String
        let classification: AICommentOriginAssessment.Classification
        let confidence: AICommentOriginAssessment.Confidence
        let evidence: String
    }

    let status: Status
    let summary: String
    var blocker: String? = nil
    var generatedDrafts: [GeneratedDraft]? = nil
    var sourceAssessments: [SourceAssessment]? = nil

    static let schema = #"{"type":"object","additionalProperties":false,"properties":{"status":{"type":"string","enum":["succeeded","blocked"]},"summary":{"type":"string"},"blocker":{"type":["string","null"],"maxLength":240},"generatedDrafts":{"type":"array","maxItems":100,"items":{"type":"object","additionalProperties":false,"properties":{"id":{"type":"integer","minimum":1},"bodySHA256":{"type":"string","pattern":"^[0-9a-f]{64}$"},"extraContext":{"type":["string","null"],"maxLength":4000},"proposedSolution":{"type":"boolean"}},"required":["id","bodySHA256","extraContext","proposedSolution"]}},"sourceAssessments":{"type":"array","maxItems":100,"items":{"type":"object","additionalProperties":false,"properties":{"noteID":{"type":"integer","minimum":1},"bodySHA256":{"type":"string","pattern":"^[0-9a-f]{64}$"},"classification":{"type":"string","enum":["ai_assisted","manual_likely","uncertain"]},"confidence":{"type":"string","enum":["very_high","high","uncertain"]},"evidence":{"type":"string","maxLength":600}},"required":["noteID","bodySHA256","classification","confidence","evidence"]}}},"required":["status","summary","blocker","generatedDrafts","sourceAssessments"]}"#

    static let extraContextInstructions = """
        extraContext is optional app-only Markdown shown to the MergeTether user beside that draft, and later beside
        the published comment. It is never posted to GitLab. Leave it null by default; most comments need none.
        Add it only when it would help the user decide whether to publish the draft or understand the actual problem
        without knowing this codebase: a simpler, less precise explanation, background on the code involved, why it
        matters, and the trade-offs or alternatives. Keep the GitLab comment itself as concise as the task, the user's
        guidelines and skills require; extra detail belongs here instead. Write in the language of the comment, at
        most 4000 characters, with short paragraphs, lists and inline code. Do not repeat the comment, invent facts,
        or include secrets, credentials, tokens, personal data or raw tool output. Never copy extraContext into a
        draft body, reply, description or any other GitLab write, and never use it to carry quick actions.
        Set proposedSolution to true when the comment recommends a concrete solution for the recipient to consider.
        For a proposal, provide extraContext describing why you recommend it and any assumptions that matter.
        Set proposedSolution to false for ordinary explanations, requests for clarification, and reports of completed fixes.
        MergeTether displays the proposal label locally.
        """

    static func codex(_ data: Data) throws -> Self {
        guard let result = try? JSONDecoder().decode(Self.self, from: data),
              !result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Error.invalidResult }
        return result
    }

    static func validateCodexEvents(_ data: Data) throws {
        struct Event: Decodable { let type: String }
        var completed = false
        for line in data.split(separator: 10) where !line.isEmpty {
            guard let event = try? JSONDecoder().decode(Event.self, from: Data(line)),
                  event.type != "error", event.type != "turn.failed" else { throw Error.assistantFailed }
            if event.type == "turn.completed" { completed = true }
        }
        guard completed else { throw Error.invalidResult }
    }

    static func claude(_ data: Data) throws -> Self {
        struct Envelope: Decodable {
            struct Denial: Decodable {}
            let is_error: Bool?
            let subtype: String?
            let permission_denials: [Denial]?
            let structured_output: AssistantJobResult?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.is_error == false,
              envelope.subtype == nil || envelope.subtype == "success",
              envelope.permission_denials?.isEmpty != false else {
            throw Error.assistantFailed
        }
        guard let result = envelope.structured_output,
              !result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Error.invalidResult }
        return result
    }
}
