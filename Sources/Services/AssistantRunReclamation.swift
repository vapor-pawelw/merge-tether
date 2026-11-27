import Darwin
import Foundation

enum AssistantRunReclamation {
    typealias Handoff = AssistantAutomationRunner.Handoff
    struct Candidate: Equatable, Sendable {
        let id: UUID
        let path: String
        let finishedAt: Date
        let state: AssistantJobExecution.State

        func hasExpired(at date: Date) -> Bool {
            let lifetime = state == .succeeded ? successfulWorkspaceLifetime : diagnosticWorkspaceLifetime
            return finishedAt <= date.addingTimeInterval(-lifetime)
        }
    }

    private static let successfulWorkspaceLifetime: TimeInterval = 24 * 60 * 60
    private static let diagnosticWorkspaceLifetime: TimeInterval = 7 * 24 * 60 * 60
    private static let rawLogLifetime: TimeInterval = 7 * 24 * 60 * 60
    private static let rawLogTailBytes = 128 * 1024
    private static let claims = Claims()

    private actor Claims {
        private var paths: Set<String> = []
        func acquire(_ path: String) -> Bool { paths.insert(path).inserted }
        func release(_ path: String) { paths.remove(path) }
    }

    static func candidate(_ job: Handoff, storage: InstallationStorage, finishedBy: Date) -> Candidate? {
        guard let execution = job.execution, !execution.state.isActive,
              execution.pendingWorkerAudit == nil, let finishedAt = execution.finishedAt, finishedAt <= finishedBy,
              let path = execution.workingDirectory, [storage.runs, storage.legacyRuns].contains(where: {
                  $0.appending(path: job.id.uuidString, directoryHint: .isDirectory).path == path
              }) else { return nil }
        let candidate = Candidate(id: job.id, path: path, finishedAt: finishedAt, state: execution.state)
        return candidate.state == .succeeded || candidate.hasExpired(at: finishedBy) ? candidate : nil
    }

    /// Avoid GitLab reads for runs whose repository was already reclaimed.
    static func hasFilesToInspect(_ candidate: Candidate, isListedOpen: Bool, at now: Date) -> Bool {
        guard !isListedOpen || candidate.hasExpired(at: now),
              let run = AssistantRunDirectory.open(candidate.path) else { return false }
        if !isListedOpen, candidate.state == .succeeded,
           expiredRawLogs(in: run, finishedAt: candidate.finishedAt, now: now) != nil { return true }
        return !discoverRepositories(in: run).isEmpty
    }

    /// Called by the queue after it persists a successful completion and before it admits more work.
    @MainActor
    static func reclaimGeneratedFiles(after handoff: Handoff, storage: InstallationStorage = .current) async {
        guard let candidate = candidate(handoff, storage: storage, finishedBy: Date()),
              candidate.state == .succeeded else { return }
        let task = Task.detached(priority: .utility) {
            await reclaim(candidate, trimLogsAt: nil, anchors: [], authorize: { !Task.isCancelled })
        }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    static func reclaimObservedRuns(_ candidates: [Candidate], request: GitLabMergeRequest, readStartedAt: Date,
                                    authorize: @escaping @MainActor @Sendable (Candidate) -> Bool) async {
        guard [.opened, .closed, .merged].contains(request.state),
              let head = request.sha, GlabService.isFullGitSHA(head) else { return }
        let diff = request.diffRefs.flatMap { $0.headSHA == head ? $0 : nil }
        let anchors = [head, diff?.baseSHA, diff?.startSHA].compactMap { $0 }.filter(GlabService.isFullGitSHA)
        let task = Task.detached(priority: .utility) {
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                guard !request.isOpen || candidate.hasExpired(at: readStartedAt) else { continue }
                let trimLogsAt = !request.isOpen && candidate.state == .succeeded ? readStartedAt : nil
                await reclaim(candidate, trimLogsAt: trimLogsAt, anchors: anchors, authorize: { authorize(candidate) })
            }
        }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private static func reclaim(_ candidate: Candidate, trimLogsAt: Date?, anchors: [String],
                                authorize: @escaping @MainActor @Sendable () -> Bool) async {
        guard await claims.acquire(candidate.path) else { return }
        await reclaimClaimedRun(candidate, trimLogsAt: trimLogsAt, anchors: anchors, authorize: authorize)
        await claims.release(candidate.path)
    }

    private static func reclaimClaimedRun(_ candidate: Candidate, trimLogsAt: Date?, anchors: [String],
                                          authorize: @escaping @MainActor @Sendable () -> Bool) async {
        guard await authorize(), let run = AssistantRunDirectory.open(candidate.path), !hasProcess(in: run.path) else { return }
        if let trimLogsAt, await authorize() {
            trimExpiredRawLogs(in: run, finishedAt: candidate.finishedAt, now: trimLogsAt)
        }
        if let tmp = run.child("tmp"), await authorize() { reclaimJavaTemporaryFiles(in: tmp) }
        for directory in discoverRepositories(in: run) {
            guard await authorize() else { return }
            guard let repository = await AssistantRunRepository.inspect(directory, in: run) else { continue }
            await repository.reclaimGeneratedFiles(authorize: authorize)
            if !anchors.isEmpty {
                await repository.reclaimIfReproducible(anchors: anchors, authorize: authorize)
            }
        }
        if await authorize() { run.child("tmp")?.removeIfEmpty() }
    }

    private static func expiredRawLogs(in run: AssistantRunDirectory, finishedAt: Date, now: Date)
        -> (AssistantRunDirectory, [(String, AssistantRunDirectory.Entry)])? {
        let cutoff = now.addingTimeInterval(-rawLogLifetime)
        guard finishedAt <= cutoff, let logs = run.child("cli-output") else { return nil }
        let expired = ["stdout", "stderr"].compactMap { name -> (String, AssistantRunDirectory.Entry)? in
            guard let entry = logs.entry(name), entry.isFile, entry.isOwned,
                  entry.modified <= cutoff, entry.bytes > rawLogTailBytes else { return nil }
            return (name, entry)
        }
        return expired.isEmpty ? nil : (logs, expired)
    }

    private static func trimExpiredRawLogs(in run: AssistantRunDirectory, finishedAt: Date, now: Date) {
        guard let (logs, expired) = expiredRawLogs(in: run, finishedAt: finishedAt, now: now) else { return }
        for (name, entry) in expired {
            guard let handle = logs.openFile(name, matching: entry, writable: true) else { continue }
            do {
                try handle.seek(toOffset: UInt64(entry.bytes - Int64(rawLogTailBytes)))
                guard let tail = try handle.read(upToCount: rawLogTailBytes), tail.count == rawLogTailBytes,
                      try handle.seekToEnd() == UInt64(entry.bytes) else { continue }
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: tail)
                try handle.truncate(atOffset: UInt64(tail.count))
            } catch {
                Log.monitor.error("Could not compact an expired assistant run log")
            }
        }
    }

    private static func reclaimJavaTemporaryFiles(in tmp: AssistantRunDirectory) {
        let magic: Set<Data> = [Data([0xca, 0xfe, 0xc0, 0xc0]), Data([0xc0, 0xc0, 0xfe, 0xca])]
        for name in tmp.names() ?? [] where name.hasPrefix("hsperfdata_") {
            guard let statistics = tmp.child(name) else { continue }
            for file in statistics.names() ?? [] where Int32(file).map({ $0 > 0 && String($0) == file }) == true {
                guard let pid = Int32(file), kill(pid, 0) == -1, errno == ESRCH,
                      let entry = statistics.entry(file), let handle = statistics.openFile(file, matching: entry),
                      let header = try? handle.read(upToCount: 4), magic.contains(header) else { continue }
                statistics.unlink(file, matching: entry)
            }
            statistics.removeIfEmpty()
        }
    }

    private static func hasProcess(in path: String) -> Bool {
        let user = geteuid()
        let estimate = Int(proc_listpids(UInt32(PROC_UID_ONLY), user, nil, 0))
        guard estimate > 0 else { return true }
        var pids = [pid_t](repeating: 0, count: estimate / MemoryLayout<pid_t>.size + 128)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), user, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0, Int(bytes) < pids.count * MemoryLayout<pid_t>.size else { return true }
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { continue }
            let workingDirectory = withUnsafeBytes(of: info.pvi_cdir.vip_path) {
                String(validatingCString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if let workingDirectory, workingDirectory == path || workingDirectory.hasPrefix(path + "/") { return true }
        }
        return false
    }

    private static func discoverRepositories(in run: AssistantRunDirectory) -> [AssistantRunDirectory] {
        var pending: [(AssistantRunDirectory, Int)] = [(run, 0)]
        var repositories: [AssistantRunDirectory] = []
        var inspected = 0
        while let (folder, depth) = pending.popLast(), inspected < 256 {
            inspected += 1
            if let git = folder.entry(".git") {
                if folder !== run, git.isDirectory { repositories.append(folder) }
                continue
            }
            if folder !== run, AssistantRunRepository.isBareWithWorktrees(folder) {
                repositories.append(folder)
                continue
            }
            guard depth < 5 else { continue }
            for name in (folder.names() ?? []).sorted().reversed() where isWorkspaceDirectoryName(name) {
                guard let child = folder.child(name) else { continue }
                pending.append((child, depth + 1))
            }
        }
        return repositories
    }

    static func isWorkspaceDirectoryName(_ name: String) -> Bool {
        let preservedNames = ["approval", "checkpoint", "draft", "evidence", "proof", "receipt"]
        return !name.hasPrefix(".") && name != "cli-output" && !preservedNames.contains(where: name.lowercased().contains)
    }
}
