import Darwin
import Foundation

enum AssistantRunReclamation {
    typealias Handoff = AssistantAutomationRunner.Handoff
    typealias Target = MRAutomationScope.Target

    struct Candidate: Equatable, Sendable {
        let id: UUID
        let path: String
        let finishedAt: Date
        let expectedHead: String?
    }

    private static let rawLogLifetime: TimeInterval = 7 * 24 * 60 * 60
    private static let rawLogTailBytes = 128 * 1024
    private static let claims = Claims()

    private actor Claims {
        private var paths: Set<String> = []
        func acquire(_ path: String) -> Bool { paths.insert(path).inserted }
        func release(_ path: String) { paths.remove(path) }
    }

    static func candidate(_ job: Handoff, storage: InstallationStorage, finishedBy: Date) -> Candidate? {
        guard let execution = job.execution, execution.state == .succeeded,
              execution.pendingWorkerAudit == nil, let finishedAt = execution.finishedAt, finishedAt <= finishedBy,
              let path = execution.workingDirectory, [storage.runs, storage.legacyRuns].contains(where: {
                  $0.appending(path: job.id.uuidString, directoryHint: .isDirectory).path == path
              }) else { return nil }
        return Candidate(id: job.id, path: path, finishedAt: finishedAt, expectedHead: job.expectedHeadSHA)
    }

    /// Called by the queue after it persists a successful completion and before it admits more work.
    @MainActor
    static func reclaimGeneratedFiles(after handoff: Handoff, storage: InstallationStorage = .current) async {
        guard let candidate = candidate(handoff, storage: storage, finishedBy: Date()) else { return }
        let task = Task.detached(priority: .utility) {
            await reclaim(candidate, terminalAt: nil, anchors: [], authorize: { !Task.isCancelled })
        }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    static func reclaimTerminalRuns(_ candidates: [Candidate], request: GitLabMergeRequest, readStartedAt: Date,
                                    authorize: @escaping @MainActor @Sendable (Candidate) -> Bool) async {
        guard request.state == .closed || request.state == .merged,
              let head = request.sha, GlabService.isFullGitSHA(head) else { return }
        let diff = request.diffRefs.flatMap { $0.headSHA == head ? $0 : nil }
        let anchors = [head, diff?.baseSHA, diff?.startSHA].compactMap { $0 }.filter(GlabService.isFullGitSHA)
        let task = Task.detached(priority: .utility) {
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                let known = anchors + [candidate.expectedHead].compactMap { $0 }.filter(GlabService.isFullGitSHA)
                await reclaim(candidate, terminalAt: readStartedAt, anchors: known, authorize: { authorize(candidate) })
            }
        }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private static func reclaim(_ candidate: Candidate, terminalAt: Date?, anchors: [String],
                                authorize: @escaping @MainActor @Sendable () -> Bool) async {
        guard await claims.acquire(candidate.path) else { return }
        await reclaimClaimedRun(candidate, terminalAt: terminalAt, anchors: anchors, authorize: authorize)
        await claims.release(candidate.path)
    }

    private static func reclaimClaimedRun(_ candidate: Candidate, terminalAt: Date?, anchors: [String],
                                          authorize: @escaping @MainActor @Sendable () -> Bool) async {
        guard await authorize(), let run = AssistantRunDirectory.open(candidate.path), !hasProcess(in: run.path) else { return }
        if let terminalAt, await authorize() {
            trimExpiredRawLogs(in: run, finishedAt: candidate.finishedAt, now: terminalAt)
        }
        if let tmp = run.child("tmp"), await authorize() { reclaimJavaTemporaryFiles(in: tmp) }
        for clone in discoverClones(in: run) {
            guard await authorize() else { return }
            guard let repository = await AssistantRunRepository.inspect(clone, in: run) else { continue }
            await repository.reclaimGeneratedFiles(authorize: authorize)
            if terminalAt != nil {
                await repository.reclaimIfReproducible(anchors: anchors, authorize: authorize)
            }
        }
        if await authorize() { run.child("tmp")?.removeIfEmpty() }
    }

    private static func trimExpiredRawLogs(in run: AssistantRunDirectory, finishedAt: Date, now: Date) {
        let cutoff = now.addingTimeInterval(-rawLogLifetime)
        guard finishedAt <= cutoff, let logs = run.child("cli-output") else { return }
        for name in ["stdout", "stderr"] {
            guard let entry = logs.entry(name), entry.modified <= cutoff, entry.bytes > rawLogTailBytes,
                  let handle = logs.openFile(name, matching: entry, writable: true) else { continue }
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

    private static func discoverClones(in run: AssistantRunDirectory) -> [AssistantRunDirectory] {
        var pending: [(AssistantRunDirectory, Int)] = [(run, 0)]
        var clones: [AssistantRunDirectory] = []
        var inspected = 0
        while let (folder, depth) = pending.popLast(), inspected < 256 {
            inspected += 1
            if folder.entry(".git") != nil {
                if folder !== run, folder.entry(".git")?.isDirectory == true { clones.append(folder) }
                continue
            }
            guard depth < 5 else { continue }
            for name in (folder.names() ?? []).sorted().reversed() where isWorkspaceDirectoryName(name) {
                guard let child = folder.child(name) else { continue }
                pending.append((child, depth + 1))
            }
        }
        return clones
    }

    static func isWorkspaceDirectoryName(_ name: String) -> Bool {
        let preservedNames = ["approval", "checkpoint", "draft", "evidence", "proof", "receipt"]
        return !name.hasPrefix(".") && name != "cli-output" && !preservedNames.contains(where: name.lowercased().contains)
    }
}
