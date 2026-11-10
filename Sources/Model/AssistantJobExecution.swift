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

    let status: Status
    let summary: String
    var blocker: String? = nil

    static let schema = #"{"type":"object","additionalProperties":false,"properties":{"status":{"type":"string","enum":["succeeded","blocked"]},"summary":{"type":"string"},"blocker":{"type":["string","null"],"maxLength":240}},"required":["status","summary","blocker"]}"#

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
