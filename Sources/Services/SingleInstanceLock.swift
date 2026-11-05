import Darwin
import Foundation

/// Both installed and development builds share this lock, regardless of bundle ID.
final class SingleInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }

    static func acquire(in directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/com.vaporpw.GitLabTodos", directoryHint: .isDirectory)
    ) throws -> SingleInstanceLock? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appending(path: "instance.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw error(errno) }

        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw error(code)
        }
        // Keep the file in place; unlinking it would let another process lock a different inode.
        return SingleInstanceLock(descriptor: descriptor)
    }

    private static func error(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
