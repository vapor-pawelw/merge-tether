import Foundation

enum ProcessRunner {
    struct Output: Sendable {
        let stdout: Data
        let stderr: String
        let exitCode: Int32
    }

    enum RunError: Error {
        case timedOut
        case launchFailed(String)
        case outputCaptureFailed(String)
    }

    static func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 30,
        input: Data? = nil,
        onOutput: (@Sendable (Output) -> Void)? = nil
    ) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        if let input {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: file.path, contents: input, attributes: [.posixPermissions: 0o600]) else {
                throw RunError.launchFailed("Could not prepare process input")
            }
            defer { try? FileManager.default.removeItem(at: file) }
            process.standardInput = try FileHandle(forReadingFrom: file)
        }

        let outputCollector: ProcessOutputCollector
        do {
            outputCollector = try ProcessOutputCollector()
        } catch {
            throw RunError.outputCaptureFailed(error.localizedDescription)
        }
        process.standardOutput = outputCollector.stdout.writer
        process.standardError = outputCollector.stderr.writer
        let state = ProcessRunState()
        let tree = OwnedProcessTree()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Output, Error>) in
                process.terminationHandler = { finished in
                    guard let reason = state.finish() else { return }
                    finished.terminationHandler = nil
                    tree.finish()

                    // Capture available bytes even after a timeout or cancellation. Accounting
                    // observers must not change the process's original completion semantics.
                    let captured = Result {
                        try Output(stdout: outputCollector.stdout.read(),
                            stderr: String(data: outputCollector.stderr.read(), encoding: .utf8) ?? "",
                            exitCode: finished.terminationStatus)
                    }
                    if case .success(let output) = captured { onOutput?(output) }

                    switch reason {
                    case .completed:
                        do {
                            cont.resume(returning: try captured.get())
                        } catch {
                            cont.resume(throwing: RunError.outputCaptureFailed(error.localizedDescription))
                        }
                    case .timedOut:
                        cont.resume(throwing: RunError.timedOut)
                    case .cancelled:
                        cont.resume(throwing: CancellationError())
                    }
                }

                do {
                    try process.run()
                    tree.start(process.processIdentifier)

                    let timeoutTask = Task.detached {
                        try? await Task.sleep(
                            nanoseconds: UInt64(max(0, timeout) * 1_000_000_000)
                        )
                        guard !Task.isCancelled else { return }
                        if state.request(.timedOut) {
                            stop(process, tree: tree)
                        }
                    }
                    state.setTimeoutTask(timeoutTask)

                    if Task.isCancelled {
                        _ = state.request(.cancelled)
                        stop(process, tree: tree)
                    }
                } catch {
                    process.terminationHandler = nil
                    if state.failLaunch() {
                        cont.resume(throwing: RunError.launchFailed(error.localizedDescription))
                    }
                }
            }
        } onCancel: {
            if state.request(.cancelled) {
                stop(process, tree: tree)
            }
        }
    }

    private static func stop(_ process: Process, tree: OwnedProcessTree) {
        tree.terminate()
        // A process that exited before the tracker could read its identity has
        // no live tracked root; Foundation still owns its unreaped child here.
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    }

}

private final class ProcessRunState: @unchecked Sendable {
    enum Reason {
        case completed
        case timedOut
        case cancelled
    }

    private let lock = NSLock()
    private var reason = Reason.completed
    private var isFinished = false
    private var timeoutTask: Task<Void, Never>?

    func request(_ requestedReason: Reason) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinished, reason == .completed else { return false }
        reason = requestedReason
        return true
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        if isFinished {
            lock.unlock()
            task.cancel()
        } else {
            timeoutTask = task
            lock.unlock()
        }
    }

    func finish() -> Reason? {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return nil
        }
        isFinished = true
        let result = reason
        let task = timeoutTask
        timeoutTask = nil
        lock.unlock()

        task?.cancel()
        return result
    }

    func failLaunch() -> Bool {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return false
        }
        isFinished = true
        let task = timeoutTask
        timeoutTask = nil
        lock.unlock()

        task?.cancel()
        return true
    }
}

private struct ProcessOutputCollector: Sendable {
    let stdout: Stream
    let stderr: Stream

    init() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        // Open descriptors stay valid after unlinking the files.
        defer { try? files.removeItem(at: directory) }
        stdout = try Stream(url: directory.appendingPathComponent("stdout"))
        stderr = try Stream(url: directory.appendingPathComponent("stderr"))
    }

    struct Stream: Sendable {
        private let reader: FileHandle
        let writer: FileHandle

        init(url: URL) throws {
            try Data().write(to: url)
            reader = try FileHandle(forReadingFrom: url)
            writer = try FileHandle(forWritingTo: url)
        }

        func read() throws -> Data {
            // A background child can still own stdout or stderr. Read the
            // current file length without waiting for that child to close it.
            let length = try reader.seekToEnd()
            try reader.seek(toOffset: 0)
            return try reader.read(upToCount: Int(length)) ?? Data()
        }
    }
}
