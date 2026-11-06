import Darwin
import Foundation

/// Retains start-time identities for descendants while their ancestry is known.
/// A detached session remains owned after reparenting; reused PIDs never do.
final class OwnedProcessTree: @unchecked Sendable {
    private struct Identity: Equatable {
        let pid: pid_t
        let seconds: UInt64
        let microseconds: UInt64
        let uid: uid_t

        static func read(_ pid: pid_t, parentPID: pid_t? = nil) -> Identity? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            if let parentPID, info.pbi_ppid != UInt32(parentPID) { return nil }
            return .init(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec, uid: info.pbi_uid)
        }
        var isCurrent: Bool { Self.read(pid) == self }
    }

    private let lock = NSLock()
    private var root: Identity?
    private var known: [pid_t: Identity] = [:]
    private var finished = false
    private var poller: Task<Void, Never>?

    func start(_ pid: pid_t) {
        lock.lock()
        root = Identity.read(pid)
        collectLocked()
        lock.unlock()
        let task = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self, self.collect() else { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        lock.lock()
        if finished { task.cancel() } else { poller = task }
        lock.unlock()
    }

    /// Cancellation freezes known parents before the final recursive scan so
    /// they cannot fork new work between discovery and termination.
    func terminate() {
        lock.lock()
        collectLocked()
        if let root, root.isCurrent { _ = kill(root.pid, SIGSTOP) }
        for _ in 0..<2 {
            collectLocked()
            for identity in known.values where identity.isCurrent { _ = kill(identity.pid, SIGSTOP) }
        }
        for identity in known.values where identity.isCurrent { _ = kill(identity.pid, SIGKILL) }
        if let root, root.isCurrent { _ = kill(root.pid, SIGKILL) }
        finished = true
        poller?.cancel()
        poller = nil
        lock.unlock()
    }

    /// Background descendants must not keep writing after their CLI reports completion.
    func finish() {
        lock.lock()
        collectLocked()
        for identity in known.values where identity.isCurrent { _ = kill(identity.pid, SIGKILL) }
        finished = true
        poller?.cancel()
        poller = nil
        lock.unlock()
    }

    private func collect() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        collectLocked()
        return true
    }

    private func collectLocked() {
        // Keep live detached ancestors, but discard exited identities so a long
        // build doesn't repeatedly scan thousands of already-finished processes.
        known = known.filter { $0.value.isCurrent }
        var queue = Array(known.values)
        if let root { queue.append(root) }
        var visited: Set<pid_t> = []
        while let parent = queue.popLast(), visited.count < 4_096 {
            guard visited.insert(parent.pid).inserted, parent.isCurrent else { continue }
            let estimate = Int(proc_listchildpids(parent.pid, nil, 0))
            var children = [pid_t](repeating: 0, count: min(4_096, max(32, estimate + 16)))
            let count = children.withUnsafeMutableBytes {
                proc_listchildpids(parent.pid, $0.baseAddress, Int32($0.count))
            }
            guard count > 0 else { continue }
            for pid in children.prefix(min(Int(count), children.count)) where pid > 0 {
                guard let child = Identity.read(pid, parentPID: parent.pid), child.uid == root?.uid else { continue }
                known[pid] = child
                queue.append(child)
            }
        }
    }
}
