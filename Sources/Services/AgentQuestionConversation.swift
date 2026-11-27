import Foundation
import MergeTetherRemote
import Observation
import OSLog

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
        var people: [URL: RemotePerson]?
        var noteLinks: Set<URL>?
    }

    private struct Transcript: Codable {
        let owner: Owner
        var session: UUID?
        var messages: [Message] = []
    }

    private struct Prompt: Encodable {
        let question: String
        let snapshot: AgentQuestionContext?
        let mergeRequestDetails: [AgentQuestionContext.Detail]
        let installedHelp: [String]
        let source: AgentQuestionSource.Evidence?
        let evidenceResponse: Bool
    }

    enum Failure: String, Equatable {
        case answer, invalidResponse, timedOut, storage

        init(answerError: Error) {
            if let processError = answerError as? ProcessRunner.RunError, case .timedOut = processError {
                self = .timedOut
            } else if (answerError as? AgentQuestionCLI.Failure) == .invalidResponse || answerError is DecodingError {
                self = .invalidResponse
            } else {
                self = .answer
            }
        }

        var message: LocalizedStringResource {
            switch self {
            case .answer: .AgentQuestion.agentQuestionFailed
            case .invalidResponse: .AgentQuestion.agentQuestionInvalidResponse
            case .timedOut: .AgentQuestion.agentQuestionTimedOut(AgentQuestionCLI.timeoutSeconds)
            case .storage: .AgentQuestion.agentQuestionStorageFailed
            }
        }
    }

    private static let log = Logger(subsystem: "com.vaporpw.MergeTether", category: "agent-question")
    private enum AnswerStage: String { case question, requestedEvidence }

    private struct Answer {
        let turn: AgentQuestionCLI.Turn
        var notice: AgentQuestionSource.Notice? = nil
        let details: [AgentQuestionContext.Detail]
    }

    @ObservationIgnored private let root: URL
    @ObservationIgnored private let source: AgentQuestionSource
    @ObservationIgnored private var transcript: Transcript?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?
    private var owner: Owner?
    private(set) var messages: [Message] = []
    private(set) var isRunning = false
    private(set) var failure: Failure?

    var unansweredQuestion: String? {
        guard !isRunning, let last = messages.last, last.role == .user,
              last.text != "?" else { return nil }
        return last.text
    }

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

    func submit(_ text: String, owner: Owner, executable: URL,
                configuration: AgentQuestionCLI.Configuration, monitor: TodoMonitorService) {
        guard self.owner == owner, monitor.agentQuestionOwner == owner, !isRunning else { return }
        let cleaned = GlabService.redactWorkflowEvidence(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleaned.isEmpty else { return }
        let original = unansweredQuestion
        let retry = (cleaned == "?" || cleaned == original) ? original : nil
        failure = nil
        if retry == nil { append(.init(role: .user, text: String(cleaned.prefix(AgentQuestionInput.maximumLength)))) }
        guard let question = AgentQuestionInput(retry ?? cleaned) else {
            append(.init(role: .refusal, text: ""))
            return
        }
        let revision = monitor.glab.accountRevision
        let snapshot = monitor.agentQuestionContext()
        let iids = Self.mentionedIIDs(in: question.text)
        let directory = root.appending(path: "Workspace", directoryHint: .isDirectory)
        let id = UUID()
        requestID = id
        isRunning = true
        let session = transcript?.session
        pending = Task {
            defer { if requestID == id { cancel() } }
            let started = ContinuousClock.now
            var stage = AnswerStage.question
            do {
                guard current(id, owner: owner, revision: revision, monitor: monitor) else { return }
                try Self.createPrivateDirectory(directory)
                let details = await monitor.freshAgentQuestionDetails(for: iids)
                guard current(id, owner: owner, revision: revision, monitor: monitor) else { return }
                var helpTopics = [question.text]
                if details.contains(where: \.assignmentClaimOffered) { helpTopics.append("Claim merge request") }
                let installedHelp = AgentQuestionSource.installedHelp(for: helpTopics)
                let initial = Prompt(question: question.text, snapshot: snapshot, mergeRequestDetails: details,
                                     installedHelp: installedHelp, source: nil, evidenceResponse: false)
                let first = try await ask(initial, owner: owner, executable: executable, session: session,
                                          configuration: configuration, directory: directory)
                guard current(id, owner: owner, revision: revision, monitor: monitor) else { return }
                if first.reply.requestsEvidence { stage = .requestedEvidence }
                let response = try await complete(first, question: question, details: details, installedHelp: installedHelp,
                    owner: owner, executable: executable, configuration: configuration, directory: directory, monitor: monitor,
                    isCurrent: { self.current(id, owner: owner, revision: revision, monitor: monitor) })
                guard current(id, owner: owner, revision: revision, monitor: monitor) else { return }
                guard let answer = response.turn.reply.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else {
                    throw AgentQuestionCLI.Failure.invalidResponse
                }
                transcript?.session = response.turn.session
                append(answerMessage(answer, response: response))
            } catch {
                guard current(id, owner: owner, revision: revision, monitor: monitor) else { return }
                let cause = Failure(answerError: error)
                let seconds = started.duration(to: .now).components.seconds
                Self.log.warning("Agent question failed provider=\(owner.assistant.rawValue, privacy: .public) model=\(configuration.model, privacy: .public) effort=\(configuration.thinking.rawValue, privacy: .public) stage=\(stage.rawValue, privacy: .public) elapsedSeconds=\(seconds, privacy: .public) reason=\(cause.rawValue, privacy: .public)")
                failure = cause
            }
        }
    }

    private func complete(_ first: AgentQuestionCLI.Turn, question: AgentQuestionInput, details: [AgentQuestionContext.Detail],
                          installedHelp: [String],
                          owner: Owner, executable: URL,
                          configuration: AgentQuestionCLI.Configuration, directory: URL,
                          monitor: TodoMonitorService, isCurrent: () -> Bool)
        async throws -> Answer {
        guard first.reply.requestsEvidence else { return .init(turn: first, details: details) }
        guard isCurrent() else { throw CancellationError() }

        var request = first
        var help = installedHelp
        var iids = Self.mentionedIIDs(in: question.text)
        var history = details
        let requestedIIDs = (first.reply.mergeRequestIIDs ?? []).filter { !iids.contains($0) }
        if !requestedIIDs.isEmpty {
            iids += requestedIIDs
            history = await monitor.freshAgentQuestionDetails(for: iids)
        }
        guard isCurrent() else { throw CancellationError() }
        let additionalHelp = AgentQuestionSource.installedHelp(for: first.reply.sourceTerms ?? [], matching: .topics)
            .filter { !installedHelp.contains($0) }
        if !additionalHelp.isEmpty {
            help += additionalHelp
            let guide = Prompt(question: question.text, snapshot: nil, mergeRequestDetails: history,
                               installedHelp: help, source: nil, evidenceResponse: false)
            request = try await ask(guide, owner: owner, executable: executable, session: request.session,
                                    configuration: configuration, directory: directory)
            guard isCurrent() else { throw CancellationError() }
            guard request.reply.requestsEvidence else { return .init(turn: request, details: history) }
            let additionalIIDs = (request.reply.mergeRequestIIDs ?? []).filter { !iids.contains($0) }
            if !additionalIIDs.isEmpty {
                iids += additionalIIDs
                history = await monitor.freshAgentQuestionDetails(for: iids)
            }
        }

        let evidence: AgentQuestionSource.Evidence?
        if let terms = request.reply.sourceTerms, !terms.isEmpty {
            evidence = try await source.evidence(for: terms, build: .installed)
        } else { evidence = nil }
        guard isCurrent() else { throw CancellationError() }
        let prompt = Prompt(question: question.text, snapshot: nil, mergeRequestDetails: history,
                            installedHelp: help, source: evidence, evidenceResponse: true)
        let turn = try await ask(prompt, owner: owner, executable: executable, session: request.session,
                                 configuration: configuration, directory: directory)
        return .init(turn: turn, notice: evidence?.notice, details: history)
    }

    private func answerMessage(_ answer: String, response: Answer) -> Message {
        let text = String(GlabService.redactWorkflowEvidence(answer).prefix(16_000))
        var people: [URL: RemotePerson] = [:]
        var noteLinks = Set<URL>()
        for message in messages {
            people.merge((message.people ?? [:]).filter { text.contains($0.key.absoluteString) },
                         uniquingKeysWith: { _, latest in latest })
            noteLinks.formUnion((message.noteLinks ?? []).filter { text.contains($0.absoluteString) })
        }
        for detail in response.details {
            for link in detail.people where text.contains(link.url.absoluteString) {
                if people[link.url]?.avatarURL == nil || link.person.avatarURL != nil { people[link.url] = link.person }
            }
            noteLinks.formUnion(detail.eventLog.compactMap(\.noteURL).filter { text.contains($0.absoluteString) })
            noteLinks.formUnion((detail.openDiscussions ?? []).compactMap(\.noteURL).filter { text.contains($0.absoluteString) })
        }
        return .init(role: .agent, text: text, sourceNotice: response.notice,
                     people: people.isEmpty ? nil : people, noteLinks: noteLinks.isEmpty ? nil : noteLinks)
    }

    private func ask(_ prompt: Prompt, owner: Owner, executable: URL, session: UUID?,
                     configuration: AgentQuestionCLI.Configuration, directory: URL) async throws -> AgentQuestionCLI.Turn {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try await AgentQuestionCLI.run(owner.assistant, executable: executable, session: session,
                                             configuration: configuration, directory: directory, input: encoder.encode(prompt))
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

    var agentQuestionConfiguration: AgentQuestionCLI.Configuration {
        .init(assistant: settings.automation.assistant, settings: settings.automation)
    }
}
