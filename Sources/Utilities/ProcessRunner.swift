import Darwin
import Foundation

enum ProcessRunner {
    #if DEBUG
    static func permitsTestExecutable(_ executable: URL, environment: [String: String], temporaryDirectory: URL) -> Bool {
        guard ApplicationLaunchMode.resolve(environment: environment) == .testHost else { return true }
        let resolved = executable.resolvingSymlinksInPath()
        let serviceCLIs: Set<String> = ["glab", "codex", "claude"]
        guard serviceCLIs.contains(executable.lastPathComponent.lowercased())
                || serviceCLIs.contains(resolved.lastPathComponent.lowercased()) else { return true }
        if resolved.path.hasPrefix(temporaryDirectory.resolvingSymlinksInPath().path + "/") { return true }
        guard let home = environment["MERGETETHER_TEST_FIXTURE_HOME"], !home.isEmpty,
              environment["HOME"] == home, environment["CFFIXED_USER_HOME"] == home else { return false }
        let fixtureHome = URL(fileURLWithPath: home).resolvingSymlinksInPath()
        guard (try? String(contentsOf: fixtureHome.appendingPathComponent(".mergetether-test-home"), encoding: .utf8))
                == "MergeTether test home\n" else { return false }
        return resolved.path.hasPrefix(fixtureHome.path + "/")
    }
    #endif

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

    struct WorkerInterruption: Error {
        enum Reason {
            case workspaceLost(URL)
            case standardOutputLimitExceeded
            case outputCaptureFailed(String)
            case resultUnavailable
        }

        let reason: Reason
        let output: Output?
    }

    static func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 30,
        input: Data? = nil,
        outputDirectory: URL? = nil,
        requiredWorkerDirectories: [URL] = [],
        onOutput: (@Sendable (Output) -> Void)? = nil,
        authorizeLaunch: (@MainActor @Sendable () -> Bool)? = nil,
        onStarted: (@Sendable () -> Void)? = nil
    ) async throws -> Output {
        #if DEBUG
        guard permitsTestExecutable(executable, environment: ProcessInfo.processInfo.environment,
                                    temporaryDirectory: FileManager.default.temporaryDirectory) else {
            try? FileHandle.standardError.write(contentsOf: Data("MergeTether test guard rejected service CLI \(executable.path)\n".utf8))
            throw RunError.launchFailed("Test hosts must use temporary service CLI fixtures: \(executable.path)")
        }
        #endif
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

        var workspace: WorkerWorkspace?
        if outputDirectory != nil, let currentDirectory {
            do { workspace = try WorkerWorkspace(directories: [currentDirectory] + requiredWorkerDirectories) }
            catch { throw RunError.launchFailed(error.localizedDescription) }
        }
        let outputCollector: ProcessOutputCollector
        do {
            outputCollector = try ProcessOutputCollector(directory: outputDirectory, keepParent: workspace != nil)
            if let outputDirectory { try workspace?.add(outputDirectory) }
        } catch {
            throw RunError.outputCaptureFailed(error.localizedDescription)
        }
        let watchedWorkspace = workspace
        process.standardOutput = outputCollector.stdout.writer
        process.standardError = outputCollector.stderr.writer
        let state = ProcessRunState()
        let tree = OwnedProcessTree()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Output, Error>) in
                process.terminationHandler = { finished in
                    guard let requestedReason = state.finish() else { return }
                    finished.terminationHandler = nil
                    tree.finish()

                    // Capture available bytes even after a timeout or cancellation. Accounting
                    // observers must not change the process's original completion semantics.
                    let captured = Result { try outputCollector.read(exitCode: finished.terminationStatus) }
                        .mapError { RunError.outputCaptureFailed($0.localizedDescription) }
                    let output = try? captured.get()
                    if let output { onOutput?(output) }

                    // The timeout can wake after the command has exited but before
                    // Foundation delivers this callback. A normal exit wins that race.
                    let reason: ProcessRunState.Reason = requestedReason == .timedOut && finished.terminationReason == .exit
                        ? .completed : requestedReason
                    switch reason {
                    case .completed:
                        if let path = watchedWorkspace?.lostDirectory {
                            cont.resume(throwing: WorkerInterruption(reason: .workspaceLost(path), output: output))
                            return
                        }
                        do {
                            let output = try captured.get()
                            if outputCollector.stdout.wasCapped {
                                throw WorkerInterruption(reason: .standardOutputLimitExceeded, output: output)
                            }
                            cont.resume(returning: output)
                        } catch let interruption as WorkerInterruption {
                            cont.resume(throwing: interruption)
                        } catch {
                            if outputDirectory != nil {
                                cont.resume(throwing: WorkerInterruption(reason: .outputCaptureFailed(error.localizedDescription), output: nil))
                            } else {
                                cont.resume(throwing: error)
                            }
                        }
                    case .workspaceLost(let path):
                        cont.resume(throwing: WorkerInterruption(reason: .workspaceLost(path), output: output))
                    case .timedOut:
                        cont.resume(throwing: RunError.timedOut)
                    case .cancelled:
                        cont.resume(throwing: CancellationError())
                    }
                }

                @Sendable func startTimeout() {
                    let timeoutTask = Task.detached {
                        try? await Task.sleep(
                            nanoseconds: UInt64(max(0, timeout) * 1_000_000_000)
                        )
                        guard !Task.isCancelled else { return }
                        if state.request(.timedOut) { tree.terminate() }
                    }
                    state.addMonitor(timeoutTask)
                }
                @Sendable func watchWorkspace() {
                    guard let watchedWorkspace else { return }
                    let task = Task.detached {
                        while !Task.isCancelled {
                            if let path = watchedWorkspace.lostDirectory {
                                if state.request(.workspaceLost(path)) { tree.terminate() }
                                return
                            }
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    }
                    state.addMonitor(task)
                }
                @Sendable func launch(authorized: Bool) {
                    do {
                        guard authorized else { throw CancellationError() }
                        try state.launch {
                            if let path = watchedWorkspace?.lostDirectory {
                                throw RunError.launchFailed("Worker directory was unavailable before launch: \(path.path)")
                            }
                            try process.run()
                            tree.start(process.processIdentifier)
                            outputCollector.closeChildWriters()
                            onStarted?()
                        }
                        watchWorkspace()
                        if authorizeLaunch == nil { startTimeout() }
                    } catch {
                        process.terminationHandler = nil
                        guard let reason = state.finish() else { return }
                        if reason == .timedOut { cont.resume(throwing: RunError.timedOut) }
                        else if reason == .cancelled || error is CancellationError { cont.resume(throwing: CancellationError()) }
                        else if let error = error as? RunError { cont.resume(throwing: error) }
                        else { cont.resume(throwing: RunError.launchFailed(error.localizedDescription)) }
                    }
                }
                if let authorizeLaunch {
                    startTimeout()
                    // Consent and process.run share one actor turn; no scheduling gap follows the check.
                    Task { @MainActor in launch(authorized: state.permitsLaunch && authorizeLaunch()) }
                } else { launch(authorized: true) }
            }
        } onCancel: {
            if state.request(.cancelled) { tree.terminate() }
        }
    }
}

private final class ProcessRunState: @unchecked Sendable {
    enum Reason: Equatable {
        case completed
        case timedOut
        case cancelled
        case workspaceLost(URL)
    }

    private let lock = NSLock()
    private var reason = Reason.completed
    private var isFinished = false
    private var monitors: [Task<Void, Never>] = []

    var permitsLaunch: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isFinished && reason == .completed
    }

    func launch(_ operation: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished, reason == .completed else {
            if reason == .timedOut { throw ProcessRunner.RunError.timedOut }
            throw CancellationError()
        }
        try operation()
    }

    func request(_ requestedReason: Reason) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinished, reason == .completed else { return false }
        reason = requestedReason
        return true
    }

    func addMonitor(_ task: Task<Void, Never>) {
        lock.lock()
        if isFinished {
            lock.unlock()
            task.cancel()
        } else {
            monitors.append(task)
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
        let tasks = monitors
        monitors = []
        lock.unlock()

        for task in tasks { task.cancel() }
        return result
    }
}

private struct WorkerWorkspace: Sendable {
    private struct Directory: Sendable {
        let url: URL
        // Keep the original directory identity allocated, even after unlink.
        let handle: FileHandle
        let device: dev_t
        let inode: ino_t

        init(url: URL) throws {
            var identity = stat()
            let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            guard fstat(descriptor, &identity) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            self.url = url
            device = identity.st_dev
            inode = identity.st_ino
        }

        var isLost: Bool {
            var identity = stat()
            if lstat(url.path, &identity) == 0 {
                return identity.st_dev != device || identity.st_ino != inode
            }
            return errno == ENOENT || errno == ENOTDIR
        }
    }

    private var directories: [Directory]

    init(directories: [URL]) throws {
        self.directories = try directories.map(Directory.init)
    }

    mutating func add(_ url: URL) throws {
        directories.append(try Directory(url: url))
    }

    var lostDirectory: URL? { directories.first(where: \.isLost)?.url }
}

private struct ProcessOutputCollector: Sendable {
    let stdout: Stream
    let stderr: Stream

    init(directory persistentDirectory: URL?, keepParent: Bool) throws {
        let files = FileManager.default
        let directory = persistentDirectory ?? files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: persistentDirectory != nil && !keepParent,
                attributes: [.posixPermissions: 0o700])
        } catch let error as CocoaError {
            guard keepParent, error.code == .fileWriteFileExists else { throw error }
        }
        // Open descriptors stay valid after unlinking the files.
        defer { if persistentDirectory == nil { try? files.removeItem(at: directory) } }
        stdout = try Stream(url: directory.appendingPathComponent("stdout"), limit: persistentDirectory == nil ? nil : 16 * 1_048_576)
        stderr = try Stream(url: directory.appendingPathComponent("stderr"), limit: persistentDirectory == nil ? nil : 1_048_576)
    }

    func closeChildWriters() {
        stdout.closeChildWriter()
        stderr.closeChildWriter()
    }

    func read(exitCode: Int32) throws -> ProcessRunner.Output {
        // Finish both drains even when one sink failed.
        let stdoutCapture = Result { try stdout.read() }
        let stderrCapture = Result { try stderr.read() }
        let stderrData = try stderrCapture.get()
        let diagnostics = stderr.wasCapped
            ? String(decoding: stderrData, as: UTF8.self) + "\n[Worker stderr exceeded its capture limit.]"
            : String(data: stderrData, encoding: .utf8) ?? ""
        return try .init(stdout: stdoutCapture.get(), stderr: diagnostics, exitCode: exitCode)
    }

    struct Stream: Sendable {
        private let reader: FileHandle
        private let limiter: ProcessStreamLimiter?
        let writer: FileHandle
        var wasCapped: Bool { limiter?.wasCapped == true }

        init(url: URL, limit: Int?) throws {
            try Data().write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            reader = try FileHandle(forReadingFrom: url)
            let sink = try FileHandle(forWritingTo: url)
            if let limit {
                let pipe = Pipe()
                limiter = try ProcessStreamLimiter(reader: pipe.fileHandleForReading, sink: sink, limit: limit)
                writer = pipe.fileHandleForWriting
            } else {
                limiter = nil
                writer = sink
            }
        }

        func closeChildWriter() {
            if limiter != nil { try? writer.close() }
        }

        func read() throws -> Data {
            try limiter?.finish()
            // A background child can still own stdout or stderr. Read the
            // current file length without waiting for that child to close it.
            let length = try reader.seekToEnd()
            try reader.seek(toOffset: 0)
            return try reader.read(upToCount: Int(length)) ?? Data()
        }
    }
}

/// Drain the pipe independently of the subprocess and keep only the bounded prefix.
private final class ProcessStreamLimiter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MergeTether.worker-output")
    private let reader: FileHandle
    private let sink: FileHandle
    private let limit: Int
    private let source: DispatchSourceRead
    private var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    private var retained = 0
    private var capped = false
    private var ended = false
    private var error: Error?

    var wasCapped: Bool { queue.sync { capped } }

    init(reader: FileHandle, sink: FileHandle, limit: Int) throws {
        let descriptor = reader.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        self.reader = reader
        self.sink = sink
        self.limit = limit
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in _ = self?.drain() }
        source.setCancelHandler { try? reader.close() }
        source.activate()
    }

    deinit { source.cancel() }

    func finish() throws {
        try queue.sync {
            // Read the buffered tail even if a detached descendant still has the
            // writer. Bound the drain in case that descendant keeps writing.
            for _ in 0..<16 {
                if !drain() {
                    ended = true
                    source.cancel()
                    if let error { throw error }
                    return
                }
            }
            ended = true
            source.cancel()
            throw POSIXError(.EIO)
        }
    }

    /// Returns true when a chunk was read, false for EOF, failure or no available bytes.
    private func drain() -> Bool {
        guard !ended else { return false }
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(reader.fileDescriptor, bytes.baseAddress, bytes.count)
        }
        if count > 0 {
            guard error == nil else { return true }
            let keep = min(count, limit - retained)
            capped = capped || keep < count
            if keep > 0 {
                do {
                    try sink.write(contentsOf: buffer.prefix(keep))
                    retained += keep
                } catch {
                    self.error = error
                }
            }
            return true
        }
        if count < 0 {
            if errno == EINTR { return true }
            if errno == EAGAIN || errno == EWOULDBLOCK { return false }
            error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        ended = true
        source.cancel()
        return false
    }
}
