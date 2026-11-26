import Foundation
import Observation

@MainActor @Observable
final class AgentQuestionConversation {
    struct Owner: Codable, Hashable, Sendable {
        let assistant: AutomationAssistant
        let host: String?
        let username: String?
    }

    struct Message: Codable, Equatable, Identifiable {
        enum Role: String, Codable { case user, agent, refusal }
        var id = UUID()
        let role: Role
        let text: String
        var sourceNotice: AgentQuestionSource.Notice?
    }

    private struct Transcript: Codable {
        let owner: Owner
        var session: UUID?
        var messages: [Message] = []
    }

    private struct Prompt: Encodable {
        let question: String?
        let snapshot: AgentQuestionContext?
        let mergeRequestDetails: [AgentQuestionContext.Detail]
        let source: AgentQuestionSource.Evidence?
        let evidenceResponse: Bool
    }

    enum Failure { case answer, storage }

    @ObservationIgnored private let root: URL
    @ObservationIgnored private let source: AgentQuestionSource
    @ObservationIgnored private var transcript: Transcript?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?
    private var owner: Owner?
    private(set) var messages: [Message] = []
    private(set) var isRunning = false
    private(set) var failure: Failure?

    init(root: URL = InstallationStorage.current.root.appending(path: "Agent Questions"),
         source: AgentQuestionSource = .init()) {
        self.root = root
        self.source = source
    }

    func activate(_ owner: Owner?) {
        guard self.owner != owner else { return }
        cancel()
        self.owner = owner
        failure = nil
        messages = []
        guard let owner else { return }
        if transcript == nil {
            transcript = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Transcript.self, from: $0) }
        }
        if transcript?.owner != owner {
            transcript = .init(owner: owner)
            discardSavedTranscript()
        }
        messages = transcript?.messages ?? []
    }

    func clear() {
        guard let owner else { return }
        cancel()
        failure = nil
        transcript = .init(owner: owner)
        messages = []
        discardSavedTranscript()
    }

    func submit(_ text: String, owner: Owner, executable: URL, model: String, monitor: TodoMonitorService) {
        guard self.owner == owner, monitor.agentQuestionOwner == owner, !isRunning else { return }
        let cleaned = GlabService.redactWorkflowEvidence(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleaned.isEmpty else { return }
        failure = nil
        append(.init(role: .user, text: String(cleaned.prefix(AgentQuestionInput.maximumLength))))
        guard let question = AgentQuestionInput(cleaned) else {
            append(.init(role: .refusal, text: ""))
            return
        }
        let revision = monitor.glab.accountRevision
        let snapshot = monitor.agentQuestionContext()
        let iids = Self.mentionedIIDs(in: question.text)
        let details = monitor.agentQuestionDetails(for: iids)
        let directory = root.appending(path: "Workspace", directoryHint: .isDirectory)
        let id = UUID()
        requestID = id
        isRunning = true
        let session = transcript?.session
        pending = Task {
            defer { if requestID == id { cancel() } }
            do {
                guard current(id, owner: owner, revision: revision, monitor: monitor) else { return }
                try Self.createPrivateDirectory(directory)
                let initial = Prompt(question: question.text, snapshot: snapshot, mergeRequestDetails: details,
                                     source: nil, evidenceResponse: false)
                let first = try await ask(initial, owner: owner, executable: executable, session: session,
                                          model: model, directory: directory)
                guard current(id, owner: owner, revision: revision, monitor: monitor) else { return }
                let (turn, notice) = try await complete(first, owner: owner, executable: executable, model: model,
                    directory: directory, monitor: monitor, isCurrent: { self.current(id, owner: owner, revision: revision, monitor: monitor) })
                guard current(id, owner: owner, revision: revision, monitor: monitor) else { return }
                guard let answer = turn.reply.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else {
                    throw AgentQuestionCLI.Failure.invalidResponse
                }
                transcript?.session = turn.session
                append(.init(role: .agent, text: String(GlabService.redactWorkflowEvidence(answer).prefix(16_000)), sourceNotice: notice))
            } catch {
                if current(id, owner: owner, revision: revision, monitor: monitor) { failure = .answer }
            }
        }
    }

    private func complete(_ first: AgentQuestionCLI.Turn, owner: Owner, executable: URL, model: String,
                          directory: URL, monitor: TodoMonitorService, isCurrent: () -> Bool)
        async throws -> (AgentQuestionCLI.Turn, AgentQuestionSource.Notice?) {
        if first.reply.answer != nil { return (first, nil) }
        let details = monitor.agentQuestionDetails(for: first.reply.mergeRequestIIDs ?? [])
        let evidence: AgentQuestionSource.Evidence?
        if let terms = first.reply.sourceTerms, !terms.isEmpty {
            evidence = try await source.evidence(for: terms, build: .installed)
        } else { evidence = nil }
        guard isCurrent() else { throw CancellationError() }
        let prompt = Prompt(question: nil, snapshot: nil, mergeRequestDetails: details, source: evidence, evidenceResponse: true)
        let turn = try await ask(prompt, owner: owner, executable: executable, session: first.session,
                                 model: model, directory: directory)
        return (turn, evidence?.notice)
    }

    private func ask(_ prompt: Prompt, owner: Owner, executable: URL, session: UUID?, model: String, directory: URL)
        async throws -> AgentQuestionCLI.Turn {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try await AgentQuestionCLI.run(owner.assistant, executable: executable, session: session,
                                              model: model, directory: directory, input: encoder.encode(prompt))
    }

    private func current(_ id: UUID, owner: Owner, revision: UInt64, monitor: TodoMonitorService) -> Bool {
        !Task.isCancelled && requestID == id && self.owner == owner
            && monitor.agentQuestionOwner == owner && monitor.glab.accountRevision == revision
    }

    func prepareForTermination() -> Task<Void, Never>? {
        let task = pending
        cancel()
        return task
    }

    private func cancel() {
        requestID = nil
        pending?.cancel()
        pending = nil
        isRunning = false
    }

    private var file: URL { root.appending(path: "conversation.json") }

    private func append(_ message: Message) {
        guard var transcript else { return }
        transcript.messages.append(message)
        let limit = 160
        if transcript.messages.count > limit { transcript.messages.removeFirst(transcript.messages.count - limit) }
        self.transcript = transcript
        messages = transcript.messages
        do {
            try Self.createPrivateDirectory(root)
            try JSONEncoder().encode(transcript).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { failure = .storage }
    }

    private func discardSavedTranscript() {
        do { try FileManager.default.removeItem(at: file) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        catch { failure = .storage }
    }

    private static func createPrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    nonisolated static func mentionedIIDs(in text: String) -> [Int] {
        text.matches(of: /!([0-9]{1,10})\b/).compactMap { Int($0.1) }
    }
}

@MainActor extension TodoMonitorService {
    var agentQuestionOwner: AgentQuestionConversation.Owner? {
        guard let assistant = settings.automation.selectedAssistant else { return nil }
        if glab.currentUsername == nil, glab.authStatus == .unknown { return nil }
        return .init(assistant: assistant, host: glab.resolvedHost, username: glab.currentUsername)
    }

    var agentQuestionModel: String {
        let automation = settings.automation
        return automation.assistant == .codex ? automation.codexVerificationModel.rawValue : automation.claudeVerificationModel.rawValue
    }
}
