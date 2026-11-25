import Darwin
import Foundation

/// Asks Codex's own account endpoints whether the account can run work.
///
/// `codex exec --json` reports failures as prose only, so an unrecognized failure is
/// confirmed through the structured `account/read` and `account/rateLimits/read` requests
/// of `codex app-server`. An incomplete response has no verdict.
enum CodexAccountProbe {
    private static let accountID = 2
    private static let limitsID = 3

    static func issue(fromResponses lines: [String], now: Date = Date()) -> AssistantCLIHealthIssue? {
        check(fromResponses: lines).issue
    }

    static func check(fromResponses lines: [String]) -> AssistantCLIHealthCheck {
        var account: [String: Any]?
        var limits: [String: Any]?
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? Int, let result = object["result"] as? [String: Any] else { continue }
            if id == accountID { account = result } else if id == limitsID { limits = result }
        }
        if let account, account["account"] is NSNull || account["account"] == nil,
           account["requiresOpenaiAuth"] as? Bool == true {
            return .held(.init(kind: .loginRequired))
        }
        guard let limits else { return .unavailable }
        let snapshot = limits["rateLimits"] as? [String: Any]
        let blocked = limits["ordinaryUsageAllowed"] as? Bool == false
            || (limits["ordinaryUsageAllowed"] == nil && snapshot?["rateLimitReachedType"] is String)
        guard blocked else {
            let authenticated = account?["account"] is [String: Any] || account?["requiresOpenaiAuth"] as? Bool == false
            return authenticated && limits["ordinaryUsageAllowed"] as? Bool == true ? .available : .unavailable
        }
        let windows = ["primary", "secondary"].compactMap { snapshot?[$0] as? [String: Any] }
        let exhausted = windows.filter { ($0["usedPercent"] as? Double ?? 0) >= 100 }
        let resets = (exhausted.isEmpty ? windows : exhausted).compactMap { $0["resetsAt"] as? Double }
            .filter { $0.isFinite && $0 > 0 }.max()
        return .held(.init(kind: .rateLimited, resetsAt: resets.map { Date(timeIntervalSince1970: $0) }))
    }

    static func probe(executable: URL, environment: [String: String], timeout: TimeInterval = 10) async -> AssistantCLIHealthIssue? {
        await check(executable: executable, environment: environment, timeout: timeout).issue
    }

    static func check(executable: URL, environment: [String: String], timeout: TimeInterval = 10) async -> AssistantCLIHealthCheck {
        #if DEBUG
        guard ProcessRunner.permitsTestExecutable(executable, environment: ProcessInfo.processInfo.environment,
            temporaryDirectory: FileManager.default.temporaryDirectory) else {
            try? FileHandle.standardError.write(contentsOf: Data("MergeTether test guard rejected service CLI \(executable.path)\n".utf8))
            return .unavailable
        }
        #endif
        guard !Task.isCancelled else { return .unavailable }
        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"MergeTether","version":"1"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":\#(accountID),"method":"account/read","params":{"refreshToken":false}}"#,
            #"{"id":\#(limitsID),"method":"account/rateLimits/read"}"#,
        ]
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = environment
        let input = Pipe(), output = Pipe()
        let writer = input.fileHandleForWriting
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { return .unavailable }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .unavailable }
        defer { if process.isRunning { process.terminate() } }
        let collector = LineCollector(expecting: [accountID, limitsID])
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; collector.finish() } else { collector.append(data) }
        }
        defer { output.fileHandleForReading.readabilityHandler = nil }
        // stdin stays open: the server exits at EOF before it answers.
        defer { try? writer.close() }
        do { try writer.write(contentsOf: Data((requests.joined(separator: "\n") + "\n").utf8)) }
        catch { return .unavailable }
        let lines = await collector.wait(timeout: timeout)
        return Task.isCancelled ? .unavailable : check(fromResponses: lines)
    }

    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var lines: [String] = []
        private var seen = Set<Int>()
        private var continuation: CheckedContinuation<[String], Never>?
        private var done = false
        private let expecting: Set<Int>

        init(expecting: [Int]) { self.expecting = Set(expecting) }

        func append(_ data: Data) {
            lock.lock()
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                lines.append(line)
                if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let id = object["id"] as? Int { seen.insert(id) }
            }
            let complete = expecting.isSubset(of: seen)
            lock.unlock()
            if complete { finish() }
        }

        func finish() {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            let pending = continuation, result = lines
            continuation = nil
            lock.unlock()
            pending?.resume(returning: result)
        }

        func wait(timeout: TimeInterval) async -> [String] {
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(timeout)) }
                catch { return }
                finish()
            }
            defer { deadline.cancel() }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if done { let result = lines; lock.unlock(); continuation.resume(returning: result); return }
                    self.continuation = continuation
                    lock.unlock()
                }
            } onCancel: {
                self.finish()
            }
        }
    }
}
