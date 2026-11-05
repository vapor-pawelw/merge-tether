import Foundation
import Observation

@MainActor
@Observable
final class GlabService {
    /// Path to the resolved `glab` executable. Set by `OnboardingDetector` / `recheck()`.
    var glabPath: URL?

    /// Username on the default host, set only when that host is authenticated.
    var currentUsername: String?

    /// Resolved GitLab host, e.g. `"gitlab.com"` or a self-hosted instance.
    var resolvedHost: String?

    /// All hosts glab reports as logged in.
    var authedHosts: [AuthedHost] = []

    /// Authentication state relative to the default host.
    var authStatus: AuthStatus = .unknown

    /// Dashboard URL for "Open in browser" links in the menu header.
    var dashboardTodosURL: URL? {
        guard let resolvedHost else { return nil }
        return URL(string: "https://\(resolvedHost)/dashboard/todos")
    }

    struct AuthedHost: Sendable, Equatable, Hashable {
        let host: String
        let username: String
    }

    enum AuthStatus: Sendable, Equatable {
        case unknown
        case authenticated
        case wrongDefaultHost(authedHosts: [AuthedHost])
        case notAuthenticated
    }

    // MARK: - Commands

    func fetchTodos(host: String? = nil) async -> Result<[Todo], GlabError> {
        guard let glabPath else { return .failure(.glabNotInstalled) }
        let output: ProcessRunner.Output
        do {
            output = try await ProcessRunner.run(
                glabPath,
                arguments: ["api", "--paginate", "/todos?per_page=100&state=pending"] + Self.hostArguments(host),
                environment: Self.shellEnvironment,
                timeout: 45
            )
        } catch ProcessRunner.RunError.timedOut {
            return .failure(.timedOut)
        } catch {
            return .failure(.unknown(String(describing: error)))
        }

        guard output.exitCode == 0 else {
            return .failure(GlabError.classify(exitCode: output.exitCode, stderr: output.stderr))
        }
        do {
            let todos = try Self.decodeTodos(output.stdout)
            return .success(todos)
        } catch {
            let snippet = String(data: output.stdout.prefix(200), encoding: .utf8) ?? ""
            Log.glab.error("Decode failed: \(error.localizedDescription, privacy: .public) — \(snippet, privacy: .public)")
            return .failure(.decoding(error.localizedDescription))
        }
    }

    func markAsDone(id: Int, host: String? = nil) async -> Result<Void, GlabError> {
        guard let glabPath else { return .failure(.glabNotInstalled) }
        let output: ProcessRunner.Output
        do {
            output = try await ProcessRunner.run(
                glabPath,
                arguments: ["api", "--method", "POST", "/todos/\(id)/mark_as_done"] + Self.hostArguments(host),
                environment: Self.shellEnvironment,
                timeout: 15
            )
        } catch ProcessRunner.RunError.timedOut {
            return .failure(.timedOut)
        } catch {
            return .failure(.unknown(String(describing: error)))
        }
        guard output.exitCode == 0 else {
            return .failure(GlabError.classify(exitCode: output.exitCode, stderr: output.stderr))
        }
        return .success(())
    }

    func mergeRequestAuthor(projectID: Int, iid: Int, host: String) async throws -> Todo.Author {
        guard let glabPath else { throw GlabError.glabNotInstalled }
        let output = try await ProcessRunner.run(
            glabPath,
            arguments: ["api", "/projects/\(projectID)/merge_requests/\(iid)", "--hostname", host],
            environment: Self.shellEnvironment,
            timeout: 15
        )
        guard output.exitCode == 0 else {
            throw GlabError.classify(exitCode: output.exitCode, stderr: output.stderr)
        }
        struct MergeRequest: Decodable {
            let author: Todo.Author
        }
        return try JSONDecoder().decode(MergeRequest.self, from: output.stdout).author
    }

    private static func hostArguments(_ host: String?) -> [String] {
        host.map { ["--hostname", $0] } ?? []
    }

    /// Refreshes `resolvedHost`, `authedHosts`, `authStatus` and `currentUsername`
    /// by parsing `glab auth status`. Returns a hard error only when we can't
    /// reach glab at all; the "wrong default host" and "not authenticated"
    /// cases are surfaced via `authStatus`, not as thrown errors.
    @discardableResult
    func recheck() async -> GlabError? {
        guard let glabPath else {
            authStatus = .notAuthenticated
            return .glabNotInstalled
        }

        if let host = await resolveHost(executable: glabPath) {
            resolvedHost = host
        }

        authedHosts = await probeAuthedHosts(executable: glabPath)

        if let defaultHost = resolvedHost,
           let entry = authedHosts.first(where: { $0.host == defaultHost }) {
            currentUsername = entry.username
            authStatus = .authenticated
            return nil
        }

        currentUsername = nil

        if authedHosts.isEmpty {
            authStatus = .notAuthenticated
            return nil
        }

        authStatus = .wrongDefaultHost(authedHosts: authedHosts)
        return nil
    }

    private func resolveHost(executable: URL) async -> String? {
        let output: ProcessRunner.Output
        do {
            output = try await ProcessRunner.run(
                executable,
                arguments: ["config", "get", "host"],
                environment: Self.shellEnvironment,
                timeout: 5
            )
        } catch {
            return nil
        }
        guard output.exitCode == 0 else { return nil }
        let host = String(data: output.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host, !host.isEmpty else { return nil }
        return host
    }

    private func probeAuthedHosts(executable: URL) async -> [AuthedHost] {
        let output: ProcessRunner.Output
        do {
            output = try await ProcessRunner.run(
                executable,
                arguments: ["auth", "status"],
                environment: Self.shellEnvironment,
                timeout: 10
            )
        } catch {
            return []
        }
        // glab writes the status report to stderr; parse both streams just in case.
        let stdoutString = String(data: output.stdout, encoding: .utf8) ?? ""
        return Self.parseAuthedHosts(from: output.stderr + "\n" + stdoutString)
    }

    /// Backfills `resolvedHost` from a fetched todo's `target_url` when
    /// `glab config get host` didn't return anything. Call after a successful
    /// fetch when `resolvedHost == nil`.
    func resolveHostFromTodos(_ todos: [Todo]) {
        guard resolvedHost == nil,
              let host = Self.parseHost(from: todos.first?.targetURL)
        else { return }
        resolvedHost = host
    }

    // MARK: - Pure helpers (used by the service and tests)

    nonisolated static func decodeTodos(_ data: Data) throws -> [Todo] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let primary = ISO8601DateFormatter()
            primary.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = primary.date(from: raw) { return date }
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            if let date = fallback.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(raw)"
            )
        }
        return try GlabPaginatedJSON.decode(Todo.self, from: data, decoder: decoder)
    }

    nonisolated static func parseHost(from url: URL?) -> String? {
        guard let url, let host = url.host, !host.isEmpty else { return nil }
        return host
    }

    /// Parses `Logged in to <host> as <username>` lines out of `glab auth status`
    /// output. Deduplicates on host, preserving the first occurrence.
    nonisolated static func parseAuthedHosts(from text: String) -> [AuthedHost] {
        guard let regex = try? NSRegularExpression(pattern: #"Logged in to (\S+) as (\S+)"#) else {
            return []
        }
        var seen = Set<String>()
        var results: [AuthedHost] = []
        for raw in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(raw)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges >= 3,
                  let hostRange = Range(match.range(at: 1), in: line),
                  let userRange = Range(match.range(at: 2), in: line)
            else { continue }
            let host = String(line[hostRange])
            if seen.insert(host).inserted {
                results.append(AuthedHost(host: host, username: String(line[userRange])))
            }
        }
        return results
    }

    static var shellEnvironment: [String: String] {
        var env: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
        ]
        let passthrough = [
            "USER", "LOGNAME", "LANG", "LC_ALL",
            "XDG_CONFIG_HOME", "GLAB_CONFIG_DIR",
            "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
        ]
        for key in passthrough {
            if let value = ProcessInfo.processInfo.environment[key] {
                env[key] = value
            }
        }
        return env
    }
}
