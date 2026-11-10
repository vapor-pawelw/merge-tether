import Foundation
import Testing
@testable import GitLabTodos

/// Stateful external boundary for workflow tests. No executable or network is used.
/// Evidence-store/persistence tests may still keep their own files on disk.
@MainActor
final class InMemoryGitLab {
    struct Request {
        let arguments: [String]
        var endpoint: String { arguments[1] == "--method" ? arguments[3] : arguments[1] }
        var command: String { arguments.joined(separator: " ") }
        var method: String {
            guard let index = arguments.firstIndex(of: "--method") else { return "GET" }
            return arguments[index + 1]
        }
    }

    var files: [String: String] = [:]
    var requests: [Request] = []
    var handler: ((Request) async throws -> ProcessRunner.Output)?
    private var waiters: [String: [CheckedContinuation<Void, any Error>]] = [:]
    private var closed = false

    func service(host: String, username: String) -> GlabService {
        let service = GlabService(commandRunner: { [self] _, arguments, _, _ in
            try Task.checkCancellation()
            // External commands suspend; preserve that scheduling boundary without
            // process startup or a wall-clock delay.
            await Task.yield()
            try Task.checkCancellation()
            guard !closed, arguments.count >= 2 else { throw CancellationError() }
            let request = Request(arguments: arguments)
            requests.append(request)
            guard let handler else {
                Issue.record("Unexpected GitLab command: \(request.command)")
                throw GlabError.unknown("No in-memory GitLab handler")
            }
            return try await handler(request)
        })
        service.glabPath = URL(fileURLWithPath: "/in-memory/glab")
        service.resolvedHost = host
        service.currentUsername = username
        return service
    }

    func has(_ name: String) -> Bool { files[name] != nil }
    func text(_ name: String) -> String { files[name] ?? "" }
    func data(_ name: String) -> Data { Data(text(name).utf8) }
    func write(_ name: String, _ text: String = "") {
        files[name] = text
        for waiter in waiters.removeValue(forKey: name) ?? [] { waiter.resume() }
    }
    func remove(_ name: String) { files.removeValue(forKey: name) }
    func append(_ name: String, _ text: String) { write(name, self.text(name) + text) }
    func copy(_ source: String, _ destination: String) throws {
        guard let value = files[source] else { throw CocoaError(.fileReadNoSuchFile) }
        write(destination, value)
    }
    func response(_ name: String) throws -> ProcessRunner.Output {
        guard let text = files[name] else { throw CocoaError(.fileReadNoSuchFile) }
        return Self.output(text)
    }
    func editArray(_ name: String, _ edit: (inout [[String: Any]]) -> Void) throws {
        var values = try #require(JSONSerialization.jsonObject(with: data(name)) as? [[String: Any]])
        edit(&values)
        write(name, String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self))
    }
    static func output(_ text: String = "", error: String = "", code: Int32 = 0) -> ProcessRunner.Output {
        .init(stdout: Data(text.utf8), stderr: error, exitCode: code)
    }
    static func json(_ value: Any) throws -> ProcessRunner.Output {
        .init(stdout: try JSONSerialization.data(withJSONObject: value), stderr: "", exitCode: 0)
    }
    func unexpected(_ request: Request) throws -> ProcessRunner.Output {
        Issue.record("Unexpected GitLab command: \(request.command)")
        throw GlabError.unknown("Unexpected fixture request")
    }
    func pause(ifPresent flag: String, entered: String, until release: String) async throws {
        guard has(flag) else { return }
        write(entered)
        try await waitFor(release)
    }
    func waitFor(_ name: String) async throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if has(name) { return }
        try await withCheckedThrowingContinuation { waiters[name, default: []].append($0) }
        try Task.checkCancellation()
    }
    func close() {
        closed = true
        let pending = waiters.values.flatMap { $0 }
        waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: CancellationError()) }
        handler = nil
    }
}

extension String {
    @MainActor func store(in gitlab: InMemoryGitLab, as name: String) throws {
        gitlab.write(name, self)
    }
}

extension Data {
    @MainActor func store(in gitlab: InMemoryGitLab, as name: String) throws {
        gitlab.write(name, String(decoding: self, as: UTF8.self))
    }
}
