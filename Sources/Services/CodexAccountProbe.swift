import Foundation

/// Asks Codex's own account endpoints whether the account can run work.
///
/// `codex exec --json` reports failures as prose only, so an unrecognized failure is
/// confirmed through the structured `account/read` and `account/rateLimits/read` requests
/// of `codex app-server`. Any probe problem yields no verdict; it never invents a hold.
enum CodexAccountProbe {
    private static let accountID = 2
    private static let limitsID = 3

    static func issue(fromResponses lines: [String], now: Date = Date()) -> AssistantCLIHealthIssue? {
        var account: [String: Any]?
        var limits: [String: Any]?
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? Int, let result = object["result"] as? [String: Any] else { continue }
            if id == accountID { account = result } else if id == limitsID { limits = result }
        }
        if let account, account["account"] is NSNull || account["account"] == nil,
           account["requiresOpenaiAuth"] as? Bool == true {
            return .init(kind: .loginRequired)
        }
        guard let limits else { return nil }
        let snapshot = limits["rateLimits"] as? [String: Any]
        let blocked = limits["ordinaryUsageAllowed"] as? Bool == false
            || (limits["ordinaryUsageAllowed"] == nil && snapshot?["rateLimitReachedType"] is String)
        guard blocked else { return nil }
        let windows = ["primary", "secondary"].compactMap { snapshot?[$0] as? [String: Any] }
        let exhausted = windows.filter { ($0["usedPercent"] as? Double ?? 0) >= 100 }
        let resets = (exhausted.isEmpty ? windows : exhausted).compactMap { $0["resetsAt"] as? Double }.filter { $0 > 0 }.max()
        return .init(kind: .rateLimited, resetsAt: resets.map { Date(timeIntervalSince1970: $0) })
    }

    static func probe(executable: URL, environment: [String: String], timeout: TimeInterval = 10) async -> AssistantCLIHealthIssue? {
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
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer { if process.isRunning { process.terminate() } }
        let collector = LineCollector(expecting: [accountID, limitsID])
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; collector.finish() } else { collector.append(data) }
        }
        defer { output.fileHandleForReading.readabilityHandler = nil }
        // stdin stays open: the server exits at EOF before it answers.
        for request in requests { input.fileHandleForWriting.write(Data((request + "\n").utf8)) }
        let lines = await collector.wait(timeout: timeout)
        try? input.fileHandleForWriting.close()
        return issue(fromResponses: lines)
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
            Task { try? await Task.sleep(for: .seconds(timeout)); finish() }
            return await withCheckedContinuation { continuation in
                lock.lock()
                if done { let result = lines; lock.unlock(); continuation.resume(returning: result); return }
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
