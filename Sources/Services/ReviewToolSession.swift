import Foundation
import Network

private struct ReviewToolRequest: Codable, Sendable {
    let token: String
    let arguments: [String]
}

struct ReviewToolReply: Codable, Sendable {
    let text: String
    var failed = false
}

/// One authenticated, loopback-only connection per call. The model has no raw API transport.
@MainActor
final class ReviewToolSession {
    struct Endpoint: Sendable {
        let port: UInt16
        let token: String
    }

    nonisolated private static let queue = DispatchQueue(label: "com.vaporpw.MergeTether.review-tool")
    private let listener: NWListener
    private let token = UUID().uuidString + UUID().uuidString
    private let service: ReviewReadService
    private var startup: CheckedContinuation<Endpoint, any Error>?
    private var reads = 0
    private var active = true
    private var requiredReads: [ReviewCommand] = []
    private(set) var issue: String?

    var readRequiredEvidence: Bool { [.context, .diff, .discussions].allSatisfy(requiredReads.contains) }

    init(service: ReviewReadService) throws {
        self.service = service
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.didChangeState(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: Self.queue)
            ReviewToolWire.receive(on: connection, maximum: 4096) { data in
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    let reply = await self.reply(to: data)
                    ReviewToolWire.send(reply, on: connection) { connection.cancel() }
                }
            }
            Self.queue.asyncAfter(deadline: .now() + 90) { connection.cancel() }
        }
    }

    func start() async throws -> Endpoint {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startup = continuation
                listener.start(queue: Self.queue)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.stop() }
        }
    }

    func stop() {
        active = false
        listener.cancel()
        startup?.resume(throwing: CancellationError())
        startup = nil
    }

    private func didChangeState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener.port else { stop(); return }
            startup?.resume(returning: .init(port: port.rawValue, token: token))
            startup = nil
        case .failed, .waiting, .cancelled: stop()
        default: break
        }
    }

    private func reply(to data: Data?) async -> ReviewToolReply {
        guard active, let data, let request = try? JSONDecoder().decode(ReviewToolRequest.self, from: data),
              request.token == token, let command = try? ReviewCommand(arguments: request.arguments) else {
            return .init(text: "Invalid review command or session.", failed: true)
        }
        guard reads < 128 else { return .init(text: "Review read limit reached.", failed: true) }
        reads += 1
        do {
            let text = try await service.read(command)
            if command == .context || command == .diff || command == .discussions { requiredReads.append(command) }
            return .init(text: text)
        } catch {
            let message = (error as? ReviewReadService.Error)?.localizedDescription ?? "GitLab could not provide the requested context."
            issue = message
            return .init(text: message, failed: true)
        }
    }
}

private enum ReviewToolWire {
    static func send(_ value: some Encodable, on connection: NWConnection, finished: @escaping @Sendable () -> Void) {
        guard var data = try? JSONEncoder().encode(value) else { finished(); return }
        data.append(10)
        connection.send(content: data, completion: .contentProcessed { _ in finished() })
    }

    static func receive(on connection: NWConnection, maximum: Int, buffer: Data = Data(),
                        received: @escaping @Sendable (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
            guard error == nil else { received(nil); return }
            var bytes = buffer
            if let data { bytes.append(data) }
            if let end = bytes.firstIndex(of: 10), end <= maximum {
                received(Data(bytes[..<end]))
            } else if complete || bytes.count > maximum {
                received(nil)
            } else {
                receive(on: connection, maximum: maximum, buffer: bytes, received: received)
            }
        }
    }
}

/// The standalone command and the two CLI runtimes' stdio tool use the same parser and transport.
enum ReviewToolClient {
    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ReviewToolReply?
        var value: ReviewToolReply? { lock.withLock { stored } }
        func finish(_ reply: ReviewToolReply) { lock.withLock { stored = reply } }
    }

    static func call(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> ReviewToolReply {
        guard let command = try? ReviewCommand(arguments: arguments) else {
            return .init(text: "Unsupported command. Run mergetether --help.", failed: true)
        }
        if command == .help { return .init(text: ReviewCommand.helpText) }
        guard let value = environment["MERGETETHER_REVIEW_PORT"], let port = NWEndpoint.Port(value),
              let token = environment["MERGETETHER_REVIEW_SESSION"] else {
            return .init(text: "No active MergeTether review session.", failed: true)
        }
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let result = Result()
        let completed = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            ReviewToolWire.send(ReviewToolRequest(token: token, arguments: arguments), on: connection) {}
            ReviewToolWire.receive(on: connection, maximum: 3_145_728) { data in
                if let data, let reply = try? JSONDecoder().decode(ReviewToolReply.self, from: data) { result.finish(reply) }
                completed.signal()
            }
        }
        connection.start(queue: DispatchQueue(label: "com.vaporpw.MergeTether.review-command"))
        _ = completed.wait(timeout: .now() + 85)
        connection.stateUpdateHandler = nil
        connection.cancel()
        return result.value ?? .init(text: "The MergeTether review session is unavailable.", failed: true)
    }

    static func serve() {
        while let line = readLine(), line.utf8.count <= 16_384 {
            guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let method = message["method"] as? String, let id = message["id"] else { continue }
            let parameters = message["params"] as? [String: Any] ?? [:]
            var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
            switch method {
            case "initialize":
                response["result"] = ["protocolVersion": parameters["protocolVersion"] as? String ?? "2024-11-05",
                    "capabilities": ["tools": [:] as [String: String]], "serverInfo": ["name": "mergetether", "version": "1"]]
            case "ping": response["result"] = [:] as [String: String]
            case "tools/list":
                response["result"] = ["tools": [["name": "mergetether", "description": "Read the assigned review. Start with arguments [\"--help\"], then call [\"context\"].",
                    "inputSchema": ["type": "object", "properties": ["arguments": ["type": "array", "items": ["type": "string"]]],
                                    "required": ["arguments"], "additionalProperties": false]]]]
            case "tools/call":
                guard parameters["name"] as? String == "mergetether", let values = parameters["arguments"] as? [String: Any],
                      let arguments = values["arguments"] as? [String] else {
                    response["error"] = ["code": -32602, "message": "Invalid tool arguments."]
                    write(response)
                    continue
                }
                let reply = call(arguments)
                response["result"] = ["content": [["type": "text", "text": reply.text]], "isError": reply.failed]
            default: response["error"] = ["code": -32601, "message": "Method not found."]
            }
            write(response)
        }
    }

    private static func write(_ response: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: response) else { return }
        data.append(10)
        FileHandle.standardOutput.write(data)
    }
}
