import Darwin
import Foundation

struct ExistingPipelineWorkDetector: Sendable {
    struct Key: Codable, Sendable {
        let host: String
        let projectID: Int
        let mergeRequestIID: Int
        let pipelineID: Int
    }

    enum Status: Equatable {
        case registered
        case unverified
    }

    private enum ClaimError: Error {
        case invalidKey
        case ownershipConflict
    }

    let directory: URL

    init(directory: URL = URL.homeDirectory
        .appending(path: "Library/Application Support/com.vaporpw.GitLabTodos/Pipeline Work", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    func status(for key: Key) -> Status {
        guard let active = try? externalRegistrationURL(for: key) else { return .unverified }
        let files = FileManager.default
        if files.fileExists(atPath: active.path) || files.fileExists(atPath: receiptURL(for: key, active: active).path) {
            return .registered
        }
        return .unverified
    }

    /// An external task may create this directory exclusively before beginning
    /// work and remove it with rmdir after finishing. It covers the whole MR.
    func externalRegistrationURL(for key: Key) throws -> URL {
        let host = key.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filenameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard !host.isEmpty, key.projectID > 0, key.mergeRequestIID > 0, key.pipelineID > 0,
              let escapedHost = host.addingPercentEncoding(withAllowedCharacters: filenameCharacters) else {
            throw ClaimError.invalidKey
        }
        return directory
            .appending(path: "host-\(escapedHost)", directoryHint: .isDirectory)
            .appending(path: "project-\(key.projectID)", directoryHint: .isDirectory)
            .appending(path: "mr-\(key.mergeRequestIID)", directoryHint: .isDirectory)
            .appending(path: "active", directoryHint: .isDirectory)
    }

    /// Call after the user confirms this handoff. The MR reservation and the
    /// pipeline receipt are stored before launching the assistant.
    func registerHandoff(for key: Key) throws -> Bool {
        let active = try externalRegistrationURL(for: key)
        try FileManager.default.createDirectory(
            at: active.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard try createExclusiveDirectory(active) else { return false }

        let owner = ownerURL(for: key, active: active)
        var hasOwner = false
        var retained = false
        defer {
            if !retained {
                if hasOwner { _ = try? removeEmptyDirectory(owner) }
                _ = try? removeEmptyDirectory(active)
            }
        }
        guard try createExclusiveDirectory(owner) else { throw ClaimError.ownershipConflict }
        hasOwner = true
        retained = try createExclusiveDirectory(receiptURL(for: key, active: active))
        return retained
    }

    /// Release only the active reservation belonging to a successful call to
    /// registerHandoff. Keep the receipt even if a turn's outcome is uncertain.
    func finishHandoff(for key: Key) throws {
        let active = try externalRegistrationURL(for: key)
        guard try removeEmptyDirectory(ownerURL(for: key, active: active)) else { return }
        _ = try removeEmptyDirectory(active)
    }

    private func ownerURL(for key: Key, active: URL) -> URL {
        active.appending(path: "handoff-\(key.pipelineID)", directoryHint: .isDirectory)
    }

    private func receiptURL(for key: Key, active: URL) -> URL {
        active.deletingLastPathComponent().appending(path: "pipeline-\(key.pipelineID)", directoryHint: .isDirectory)
    }

    private func createExclusiveDirectory(_ url: URL) throws -> Bool {
        let error = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return EINVAL }
            return mkdir(path, 0o700) == 0 ? 0 : errno
        }
        if error == EEXIST { return false }
        guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        return true
    }

    private func removeEmptyDirectory(_ url: URL) throws -> Bool {
        let error = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return EINVAL }
            return rmdir(path) == 0 ? 0 : errno
        }
        if error == ENOENT { return false }
        guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        return true
    }
}
