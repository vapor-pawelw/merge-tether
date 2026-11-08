import Foundation
import Observation

@MainActor @Observable
final class AICommentOriginCoordinator {
    typealias Note = GitLabMergeRequestDiscussion.Note
    typealias Assess = @MainActor (MRAutomationScope.Target, [Note], AutomationAssistant, String) async throws -> AICommentOriginAssessment
    typealias FetchCurrent = @MainActor (MRAutomationScope.Target) async throws -> [Note]
    typealias IsCurrent = @MainActor (MRAutomationScope.Target, AutomationAssistant, String) -> Bool
    private struct Request {
        let id = UUID()
        let target: MRAutomationScope.Target
        let notes: [Note]
        let assistant: AutomationAssistant
        let model: String
        var signature: String { notes.map { "\($0.id ?? 0):\($0.author?.id ?? 0):\(AICommentAssessmentStore.digest($0.body ?? ""))" }.sorted().joined(separator: "/") }
    }
    private let directory: URL
    private let assess: Assess
    private let fetchCurrent: FetchCurrent
    private let isCurrent: IsCurrent
    private let retryWait: ReadOnlyAssessmentRetry.Wait
    private let now: ReadOnlyAssessmentRetry.Clock
    @ObservationIgnored private var pending: [MRAutomationScope.Target: Request] = [:]
    @ObservationIgnored private var running: [MRAutomationScope.Target: (Request, Task<Void, Never>)] = [:]
    @ObservationIgnored private var attempted: [String: Date] = [:]
    private var checking: Set<MRAutomationScope.Target> = []
    private struct Failure {
        let target: MRAutomationScope.Target
        let reason: String
        let assistant: AutomationAssistant
        let model: String
    }
    private var failures: [String: Failure] = [:]
    private struct ValidatedAssessment {
        let target: MRAutomationScope.Target
        let note: AICommentOriginAssessment.Note
    }
    @ObservationIgnored private var validated: [String: ValidatedAssessment] = [:]
    var onChange: (() -> Void)?

    init(directory: URL = AICommentAssessmentStore.directory,
         assess: @escaping Assess = { try await AICommentOriginAssessor.verify(target: $0, notes: $1, assistant: $2, model: $3) },
         fetchCurrent: @escaping FetchCurrent, isCurrent: @escaping IsCurrent,
         retryWait: @escaping ReadOnlyAssessmentRetry.Wait = ReadOnlyAssessmentRetry.wait,
         now: @escaping ReadOnlyAssessmentRetry.Clock = { Date() }) {
        self.directory = directory; self.assess = assess; self.fetchCurrent = fetchCurrent; self.isCurrent = isCurrent
        self.retryWait = retryWait
        self.now = now
    }

    private func key(_ request: Request, _ note: Note) -> String {
        "\(request.target.host)/\(request.target.username)/\(request.target.projectID)/\(request.target.iid ?? 0)/\(note.id ?? 0)/\(note.author?.id ?? 0)/\(AICommentAssessmentStore.digest(note.body ?? ""))/\(request.assistant.rawValue)/\(request.model)/\(AICommentOriginAssessor.criteriaVersion)"
    }

    func schedule(target: MRAutomationScope.Target, notes: [Note], assistant: AutomationAssistant, model: String) {
        guard isCurrent(target, assistant, model), target.iid != nil, !notes.isEmpty, notes.count <= 100,
              notes.allSatisfy({ ($0.id ?? 0) > 0 && $0.body != nil && $0.system != true && ($0.author?.id ?? 0) > 0 }),
              Set(notes.compactMap(\.id)).count == notes.count else { return }
        let candidate = Request(target: target, notes: notes, assistant: assistant, model: model)
        let incomingKeys = Set(notes.map { key(candidate, $0) })
        for stale in failures.filter({ $0.value.target == target && !incomingKeys.contains($0.key) }).keys {
            failures.removeValue(forKey: stale)
            attempted.removeValue(forKey: stale)
        }
        for stale in validated.filter({ $0.value.target == target && !incomingKeys.contains($0.key) }).keys {
            validated.removeValue(forKey: stale)
        }
        let uncovered = notes.filter { note in
            let identity = key(candidate, note)
            if let attemptedAt = attempted[identity] {
                guard failures[identity] != nil,
                      now().timeIntervalSince(attemptedAt) >= ReadOnlyAssessmentRetry.cooldown else { return false }
            }
            if let record = AICommentAssessmentStore.result(for: note, host: target.host, projectID: target.projectID, iid: target.iid!, in: directory) {
                if record.qualifiesAsAI { return false }
                if record.provider == assistant.rawValue && record.model == model
                    && record.criteriaVersion == AICommentOriginAssessor.criteriaVersion { return false }
            }
            return true
        }
        guard !uncovered.isEmpty else { return }
        let request = Request(target: target, notes: uncovered, assistant: assistant, model: model)
        if let prior = running[target]?.0, prior.signature == request.signature && prior.assistant == assistant && prior.model == model { return }
        if let prior = pending[target], prior.signature == request.signature && prior.assistant == assistant && prior.model == model { return }
        running[target]?.1.cancel()
        pending[target] = request
        updateChecking(); startNext()
    }

    func isChecking(work: AssistantAutomationRunner.MergeRequestWork) -> Bool {
        checking.contains { $0.host == work.host && $0.projectID == work.projectID && $0.iid == work.iid }
    }

    func failure(work: AssistantAutomationRunner.MergeRequestWork) -> String? {
        failures.values.first {
            $0.target.host == work.host && $0.target.projectID == work.projectID && $0.target.iid == work.iid
                && isCurrent($0.target, $0.assistant, $0.model)
        }?.reason
    }

    func retryReadOnlyFailures() {
        for (key, failure) in failures where isCurrent(failure.target, failure.assistant, failure.model) {
            attempted[key] = .distantPast
        }
    }

    func cancel(outsideScope scope: MRAutomationScope? = nil) {
        for target in Set(pending.keys).union(running.keys).union(failures.values.map(\.target)).union(validated.values.map(\.target)) where scope.map({ !$0.resolve(target).active }) ?? true {
            pending.removeValue(forKey: target); running[target]?.1.cancel()
            for key in failures.filter({ $0.value.target == target }).keys {
                failures.removeValue(forKey: key)
                attempted.removeValue(forKey: key)
            }
            for key in validated.filter({ $0.value.target == target }).keys { validated.removeValue(forKey: key) }
        }
        updateChecking()
    }

    private func updateChecking() {
        let requests = Array(pending.values) + running.values.filter { !$0.1.isCancelled }.map(\.0)
        checking = Set(requests.filter { isCurrent($0.target, $0.assistant, $0.model) }.map(\.target))
    }

    private func startNext() {
        for (target, entry) in running where !isCurrent(target, entry.0.assistant, entry.0.model) { entry.1.cancel() }
        while running.count < 2, let (target, request) = pending.first(where: { running[$0.key] == nil }) {
            pending.removeValue(forKey: target)
            guard isCurrent(target, request.assistant, request.model) else { continue }
            let task = Task { [weak self] in
                guard let self else { return }
                defer {
                    if running[target]?.0.id == request.id { running.removeValue(forKey: target) }
                    updateChecking(); startNext(); onChange?()
                }
                do {
                    try await ReadOnlyAssessmentRetry.run(isCurrent: {
                        self.isCurrent(target, request.assistant, request.model)
                    }, wait: retryWait) {
                        for note in request.notes where self.validated[self.key(request, note)] == nil {
                            if let restored = try AICommentAssessmentStore.pendingVerdict(for: note, target: target,
                                assistant: request.assistant, model: request.model, in: self.directory) {
                                self.validated[self.key(request, note)] = .init(target: target, note: restored)
                            }
                        }
                        let missing = request.notes.filter { self.validated[self.key(request, $0)] == nil }
                        if !missing.isEmpty {
                            let fresh = try await self.assess(target, missing, request.assistant, request.model)
                            try AICommentOriginAssessor.validate(fresh, noteIDs: missing.compactMap(\.id))
                            guard !Task.isCancelled, self.isCurrent(target, request.assistant, request.model) else { throw CancellationError() }
                            for note in missing {
                                guard let assessment = fresh.notes.first(where: { $0.noteID == note.id }) else {
                                    throw AICommentOriginAssessor.AssessmentError.invalidEvidence
                                }
                                self.validated[self.key(request, note)] = .init(target: target, note: assessment)
                            }
                        }
                        // Journal every validated opinion before final I/O. A retry or restart must not solicit another vote.
                        for note in request.notes {
                            guard let assessment = self.validated[self.key(request, note)]?.note else {
                                throw AICommentOriginAssessor.AssessmentError.invalidEvidence
                            }
                            let preserved = try AICommentAssessmentStore.preservePendingVerdict(assessment, for: note,
                                target: target, assistant: request.assistant, model: request.model, in: self.directory)
                            self.validated[self.key(request, note)] = .init(target: target, note: preserved)
                        }
                        let result = AICommentOriginAssessment(notes: request.notes.compactMap { self.validated[self.key(request, $0)]?.note })
                        try AICommentOriginAssessor.validate(result, noteIDs: request.notes.compactMap(\.id))
                        guard !Task.isCancelled, self.isCurrent(target, request.assistant, request.model) else { throw CancellationError() }
                        let live = try await self.fetchCurrent(target)
                        guard !Task.isCancelled, self.isCurrent(target, request.assistant, request.model) else { throw CancellationError() }
                        guard request.notes.allSatisfy({ original in
                            let matches = live.filter { $0.id == original.id }
                            return matches.count == 1 && matches[0].body == original.body && matches[0].author?.id == original.author?.id
                        }) else { throw CancellationError() }
                        try AICommentAssessmentStore.persist(result, target: target, notes: request.notes,
                            assistant: request.assistant, model: request.model, in: self.directory)
                        for note in request.notes {
                            // The ordinary record is authoritative now; leftover pending data cannot qualify on its own.
                            try? AICommentAssessmentStore.removePendingVerdict(for: note, target: target,
                                assistant: request.assistant, model: request.model, in: self.directory)
                        }
                    }
                    for note in request.notes {
                        failures.removeValue(forKey: key(request, note))
                        validated.removeValue(forKey: key(request, note))
                    }
                } catch is CancellationError { return }
                catch {
                    // A failed assessment never establishes either AI or handwritten origin.
                    for note in request.notes {
                        failures[key(request, note)] = .init(target: target,
                            reason: String(GlabService.redactWorkflowEvidence(String(describing: error)).prefix(600)),
                            assistant: request.assistant, model: request.model)
                    }
                }
                guard !Task.isCancelled else { return }
                for note in request.notes { attempted[key(request, note)] = now() }
                if attempted.count > 512 {
                    attempted = Dictionary(uniqueKeysWithValues: attempted.sorted { $0.value > $1.value }.prefix(512).map { ($0.key, $0.value) })
                }
            }
            running[target] = (request, task)
        }
        updateChecking()
    }
}
