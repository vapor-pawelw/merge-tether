import Foundation

/// Application decisions that cannot be reconstructed from a worker's persisted execution.
struct MRAutomationEvent: Codable, Identifiable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case retry, review, followUp, draftReply, verification, pipeline, conflict, refresh }
    enum Origin: String, Codable, Sendable { case manual, automatic }
    enum State: String, Codable, Sendable { case requested, queued, failed, completed, blocked }
    let id: UUID
    let target: MRAutomationScope.Target
    let createdAt: Date
    let action: Action
    let origin: Origin
    let state: State
    let message: String?
    var intentID: UUID? = nil
    var jobID: UUID? = nil
    var relatedJobID: UUID? = nil
}

/// A read-only chronology; run lifecycle remains owned by AssistantJobExecution.
@MainActor
struct MRAutomationHistory {
    struct Entry: Identifiable {
        enum Source {
            case job(AssistantAutomationRunner.Handoff, attempt: Int)
            case workflow(MergeWorkflowActivityEntry)
            case event(MRAutomationEvent)
        }
        let id: String
        let createdAt: Date
        let source: Source

        var isAutomatic: Bool {
            switch source {
            case .job(let job, _): job.manual == false
            case .workflow: true
            case .event(let event): event.origin == .automatic
            }
        }
    }
    let entries: [Entry]

    func associatedRuns(for entry: Entry) -> [AssistantAutomationRunner.Handoff] {
        let ids: [UUID]
        switch entry.source {
        case .job(let job, _): ids = [job.id]
        case .workflow(let workflow): ids = [workflow.assistantJobID].compactMap { $0 }
        case .event(let event): ids = [event.jobID, event.relatedJobID].compactMap { $0 }
        }
        var result: [AssistantAutomationRunner.Handoff] = []
        for id in ids where !result.contains(where: { $0.id == id }) {
            for candidate in entries {
                if case .job(let job, _) = candidate.source, job.id == id { result.append(job); break }
            }
        }
        return result
    }

    init(target: MRAutomationScope.Target, handoffs: [AssistantAutomationRunner.Handoff],
         workflows: [MergeWorkflowActivityEntry], events: [MRAutomationEvent]) {
        guard let iid = target.iid else { entries = []; return }
        let runs = handoffs.filter {
            $0.key.work.host == target.host && $0.key.username == target.username
                && $0.key.work.projectID == target.projectID && $0.key.work.iid == iid
        }.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
        let runEntries = runs.enumerated().map { offset, run in
            Entry(id: "job/\(run.id)",
                  createdAt: run.execution?.finishedAt ?? run.execution?.startedAt ?? run.createdAt,
                  source: .job(run, attempt: offset + 1))
        }
        let workflowEntries = workflows.filter {
            $0.host == target.host && $0.user.username == target.username
                && $0.event.mergeRequest.projectID == target.projectID && $0.event.mergeRequest.iid == iid
                && $0.event.mergeRequest.webURL.isGitLabMergeRequest(host: target.host, iid: iid)
        }.map { Entry(id: "workflow/\($0.id)", createdAt: $0.createdAt, source: .workflow($0)) }
        let decisionEntries = events.filter { $0.target == target }
            .map { Entry(id: "event/\($0.id)", createdAt: $0.createdAt, source: .event($0)) }
        entries = (runEntries + workflowEntries + decisionEntries).sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
    }
}

extension SettingsManager {
    func recordAutomationEvent(target: MRAutomationScope.Target, action: MRAutomationEvent.Action,
                               origin: MRAutomationEvent.Origin, state: MRAutomationEvent.State,
                               message: String? = nil, intentID: UUID? = nil, jobID: UUID? = nil,
                               relatedJobID: UUID? = nil, now: Date = Date()) {
        guard target.iid != nil else { return }
        let event = MRAutomationEvent(id: UUID(), target: target, createdAt: now, action: action,
            origin: origin, state: state, message: message.map(GlabService.redactWorkflowEvidence),
            intentID: intentID, jobID: jobID, relatedJobID: relatedJobID)
        var counts: [MRAutomationScope.Target: Int] = [:]
        automationEvents = ([event] + automationEvents).sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }.filter {
            counts[$0.target, default: 0] += 1
            return counts[$0.target, default: 0] <= 100
        }
        automationEvents = Array(automationEvents.prefix(1_000))
        save()
    }
}
