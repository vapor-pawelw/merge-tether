import Foundation

/// Execution is reported separately from evidence that a GitLab action was verified.
struct AssistantJobExecution: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case queued, running, succeeded, blocked, failed, cancelled, interrupted
        var isActive: Bool { self == .queued || self == .running }
    }

    var state: State
    var startedAt: Date?
    var finishedAt: Date?
    var summary: String?
    var output: String?
    var error: String?
    var workingDirectory: String?
    var blocker: String? = nil

    var attentionExplanation: String? {
        guard state == .blocked || state == .failed else { return nil }
        for candidate in [blocker, error] {
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
           currentRequest.author.username == username, currentRequest.projectID == work.projectID,
           currentRequest.iid == work.iid, currentRequest.webURL.isGitLabMergeRequest(host: work.host, iid: work.iid),
           feedbackStatus.head == currentRequest.sha, feedbackStatus.fingerprint == discussionFingerprint,
           feedbackStatus.semanticContextFingerprint == currentRequest.semanticContextFingerprint {
            return true
        }
        let latest = handoffs.filter {
            !$0.isObsoleteReminder && $0.key.work == work && $0.key.username == username
                && !PipelineJobReconciliation.isObsolete($0, request: currentRequest)
        }
            .max { $0.createdAt < $1.createdAt }
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
    }

    let status: Status
    let summary: String
    var blocker: String? = nil
    var generatedDrafts: [GeneratedDraft]? = nil

    static let schema = #"{"type":"object","additionalProperties":false,"properties":{"status":{"type":"string","enum":["succeeded","blocked"]},"summary":{"type":"string"},"blocker":{"type":["string","null"],"maxLength":240},"generatedDrafts":{"type":"array","maxItems":100,"items":{"type":"object","additionalProperties":false,"properties":{"id":{"type":"integer","minimum":1},"bodySHA256":{"type":"string","pattern":"^[0-9a-f]{64}$"},"extraContext":{"type":["string","null"],"maxLength":4000}},"required":["id","bodySHA256","extraContext"]}}},"required":["status","summary","blocker","generatedDrafts"]}"#

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
