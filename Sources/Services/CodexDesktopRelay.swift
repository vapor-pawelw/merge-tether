import Foundation
import Darwin

@MainActor
enum CodexDesktopRelay {
    static let directory = InstallationStorage.current.evidence

    static func clearMergeRequestStatus(in directory: URL = directory) {
        try? FileManager.default.removeItem(at: directory.appending(path: "mr-status.json"))
    }

    nonisolated static func isClaudeSessionID(_ id: String) -> Bool {
        id.hasPrefix("local_") && UUID(uuidString: String(id.dropFirst(6))) != nil && id == id.lowercased()
    }
}

// MARK: - Retired GUI delivery migration
extension CodexDesktopRelay {
    /// Returns false only when a legacy listener owns the lock; the next refresh retries.
    /// Existing claims/receipts are evidence and are deliberately never moved.
    nonisolated static func retirePendingGUIJobs(in directory: URL) throws -> Bool {
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else {
            if [ENOENT, ELOOP, ENOTDIR].contains(errno) { return true }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(root) }
        let lock = openat(root, ".plugin.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if [EWOULDBLOCK, EAGAIN].contains(errno) { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(lock, LOCK_UN) }
        for queue in ["jobs", "claude-jobs"] {
            let source = openat(root, queue, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard source >= 0 else {
                if [ENOENT, ELOOP, ENOTDIR].contains(errno) { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { close(source) }
            let names = try retirementJSONNames(in: source)
            guard !names.isEmpty else { continue }
            let archiveRoot = try retirementDirectory("retired-gui-jobs", parent: root)
            defer { close(archiveRoot) }
            let destination = try retirementDirectory(queue, parent: archiveRoot)
            defer { close(destination) }
            for name in names {
                // Exclusive rename preserves any earlier archive with the same job ID.
                if renameatx_np(source, name, destination, name, UInt32(RENAME_EXCL)) == 0 { continue }
                if errno == ENOENT { continue }
                guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let unique = UUID().uuidString.lowercased() + "-" + name
                guard renameatx_np(source, name, destination, unique, UInt32(RENAME_EXCL)) == 0 else {
                    if errno == ENOENT { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        return true
    }

    private nonisolated static func retirementDirectory(_ name: String, parent: Int32) throws -> Int32 {
        if mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return descriptor
    }

    private nonisolated static func retirementJSONNames(in descriptor: Int32) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard let stream = fdopendir(copy) else {
            close(copy)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes -> String in
                String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            guard name.hasSuffix(".json"), !name.contains("/") else { continue }
            var metadata = stat()
            guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG else { continue }
            names.append(name)
        }
        return names
    }
}
