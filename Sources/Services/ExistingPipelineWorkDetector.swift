import Darwin
import Foundation

struct ExistingPipelineWorkDetector: Sendable {
    struct Key: Codable, Sendable {
        let host: String
        let projectID: Int
        let mergeRequestIID: Int
        let pipelineID: Int
        var reservationID: UUID?
    }

    enum Status: Equatable {
        case registered
        case unverified
    }

    private enum ClaimError: Error {
        case invalidKey
        case ownershipConflict
    }

    enum ProcessState: Equatable, Sendable { case alive, dead, unknown }
    struct Owner: Codable, Equatable, Sendable {
        let version: Int
        let installationID: String
        let sessionID: UUID
        let processID: Int32
        let reservationID: UUID
    }
    struct ReservationOwner: Equatable, Sendable {
        let owner: Owner
        let runID: UUID?
    }
    struct AdmissionIO: Sendable {
        var openActive: @Sendable (Int32) throws -> Int32 = { parent in
            let descriptor = openat(parent, "active", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return descriptor
        }
        var createOwner: @Sendable (Int32, String) throws -> Void = { parent, name in
            guard mkdirat(parent, name, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        var writeMetadata: @Sendable (Int32, Data) throws -> Void = { descriptor, bytes in
            try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: bytes)
        }
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let kind: mode_t

        init(_ metadata: stat) {
            device = metadata.st_dev
            inode = metadata.st_ino
            kind = metadata.st_mode & S_IFMT
        }
        init(descriptor: Int32) throws {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            self.init(metadata)
        }
        init(name: String, parent: Int32) throws {
            var metadata = stat()
            guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            self.init(metadata)
        }
        func matches(name: String, parent: Int32) -> Bool {
            (try? FileIdentity(name: name, parent: parent)) == self
        }
    }

    private struct RunBinding: Codable { let runID: UUID }
    private static let sessionID = UUID()
    let directory: URL
    private let legacyDirectory: URL?
    private let installationID: String
    private let processID: Int32
    private let processState: @Sendable (Int32) -> ProcessState
    private let admissionIO: AdmissionIO

    init(directory: URL = InstallationStorage.current.pipelineWork, legacyDirectory: URL? = nil,
         installationID: String = InstallationStorage.current.bundleIdentifier,
         processID: Int32 = getpid(),
         processState: @escaping @Sendable (Int32) -> ProcessState = { ExistingPipelineWorkDetector.probeProcess($0) },
         admissionIO: AdmissionIO = .init()) {
        self.directory = directory
        let storage = InstallationStorage.current
        self.legacyDirectory = legacyDirectory ?? (directory == storage.pipelineWork && directory != storage.legacy.pipelineWork
            ? storage.legacy.pipelineWork : nil)
        self.installationID = installationID
        self.processID = processID
        self.processState = processState
        self.admissionIO = admissionIO
    }

    private static func probeProcess(_ pid: Int32) -> ProcessState {
        guard pid > 0 else { return .unknown }
        if kill(pid, 0) == 0 { return .alive }
        return errno == ESRCH ? .dead : .unknown
    }

    private var legacyDetector: ExistingPipelineWorkDetector? {
        guard let legacyDirectory, legacyDirectory != directory else { return nil }
        return ExistingPipelineWorkDetector(directory: legacyDirectory)
    }

    func status(for key: Key) -> Status {
        if legacyDetector?.status(for: key) == .registered { return .registered }
        guard let active = try? externalRegistrationURL(for: key) else { return .unverified }
        let files = FileManager.default
        if files.fileExists(atPath: active.path) || files.fileExists(atPath: receiptURL(for: key, active: active).path) {
            return .registered
        }
        return .unverified
    }

    /// Finished pipeline receipts prevent repeating workers but do not mean
    /// that another task still holds the MR's exclusive reservation.
    func hasActiveReservation(for key: Key) -> Bool {
        if legacyDetector?.hasActiveReservation(for: key) == true { return true }
        guard let active = try? externalRegistrationURL(for: key) else { return true }
        return FileManager.default.fileExists(atPath: active.path)
    }

    func hasEmptyPipelineReceipt(for key: Key) -> Bool {
        guard let active = try? externalRegistrationURL(for: key) else { return false }
        let receipt = receiptURL(for: key, active: active)
        guard let values = try? receipt.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let contents = try? FileManager.default.contentsOfDirectory(atPath: receipt.path) else { return false }
        return contents.isEmpty
    }

    func ownsReservation(for key: Key) -> Bool {
        guard key.reservationID != nil else { return false }
        return (try? withOwner(key) { _, _, _ in true }) ?? false
    }

    /// Only known app metadata is diagnostic evidence. Missing metadata means an
    /// external/legacy reservation and never authorizes stale-lock recovery.
    func reservationOwner(for key: Key) -> ReservationOwner? {
        try? withOwner(key) { owner, _, _ in try readOwner(owner, key: key) }
    }

    func activeReservationOwner(for key: Key) -> ReservationOwner? {
        guard let parent = try? reservationParent(for: key, create: false) else { return nil }
        defer { close(parent) }
        let active = openat(parent, "active", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard active >= 0 else { return nil }
        defer { close(active) }
        guard let names = try? contents(active), names.count == 1, let name = names.first else { return nil }
        let parts = name.split(separator: "-", maxSplits: 2)
        guard parts.count == 3, parts[0] == "handoff", let pipelineID = Int(parts[1]),
              let token = UUID(uuidString: String(parts[2])) else { return nil }
        let owned = Key(host: key.host, projectID: key.projectID, mergeRequestIID: key.mergeRequestIID,
                        pipelineID: pipelineID, reservationID: token)
        return reservationOwner(for: owned)
    }

    func reservationSummary(for key: Key) -> String? {
        guard hasActiveReservation(for: key) else { return nil }
        if let diagnostic = activeReservationOwner(for: key), let runID = diagnostic.runID {
            return String(localized: .PipelineAutomation.pipelineReservationOwner(
                diagnostic.owner.installationID, String(diagnostic.owner.processID), runID.uuidString.lowercased()))
        }
        return String(localized: .PipelineAutomation.pipelineReservationUnknownOwner)
    }

    func bindRun(_ runID: UUID, to key: Key) throws {
        try withOwner(key) { descriptor, _, _ in
            let recorded = try readOwner(descriptor, key: key)
            guard recorded.owner.installationID == installationID,
                  recorded.owner.sessionID == Self.sessionID,
                  recorded.owner.processID == processID else { throw ClaimError.ownershipConflict }
            if let existing = recorded.runID {
                guard existing == runID else { throw ClaimError.ownershipConflict }
                return
            }
            try writeExclusive(RunBinding(runID: runID), name: "run.json", in: descriptor)
        }
    }

    /// A reused or inaccessible PID is deliberately not considered dead. A
    /// terminal settings record alone cannot clear an active external process.
    @discardableResult
    func recoverTerminalRun(_ runID: UUID, reservation key: Key, state: AssistantJobExecution.State) throws -> Bool {
        guard [.succeeded, .blocked, .failed, .cancelled].contains(state),
              let recorded = reservationOwner(for: key),
              recorded.owner.installationID == installationID, recorded.runID == runID,
              processState(recorded.owner.processID) == .dead else { return false }
        return try release(key, expected: recorded)
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
        try registerHandoff(for: key, explicitRetry: false)
    }

    /// New CLI runs receive an ownership token. An explicit retry may reuse the
    /// immutable pipeline receipt, but must acquire a new exclusive MR claim.
    func registerRun(for key: Key, explicitRetry: Bool = false) throws -> Key? {
        var owned = key
        owned.reservationID = UUID()
        return try registerHandoff(for: owned, explicitRetry: explicitRetry) ? owned : nil
    }

    private func registerHandoff(for key: Key, explicitRetry: Bool) throws -> Bool {
        guard !legacyBlocks(key, explicitRetry: explicitRetry) else { return false }
        let active = try externalRegistrationURL(for: key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let parent = try reservationParent(for: key, create: true)
        defer { close(parent) }
        guard mkdirat(parent, "active", 0o700) == 0 else {
            if errno == EEXIST { return false }
            throw posixError()
        }
        let ownerName = ownerURL(for: key, active: active).lastPathComponent
        var activeIdentity: FileIdentity?
        var ownerIdentity: FileIdentity?
        var metadataIdentity: FileIdentity?
        var activeDescriptor: Int32 = -1
        var ownerDescriptor: Int32 = -1
        var retained = false
        // Rollback depends on the objects this admission created, not on being
        // able to decode metadata whose write may have failed halfway through.
        defer {
            if !retained {
                if ownerDescriptor >= 0, let metadataIdentity,
                   metadataIdentity.matches(name: "owner.json", parent: ownerDescriptor) {
                    _ = unlinkat(ownerDescriptor, "owner.json", 0)
                }
                if activeDescriptor >= 0, let ownerIdentity,
                   ownerIdentity.matches(name: ownerName, parent: activeDescriptor) {
                    _ = unlinkat(activeDescriptor, ownerName, AT_REMOVEDIR)
                }
                if let activeIdentity, activeIdentity.matches(name: "active", parent: parent) {
                    _ = unlinkat(parent, "active", AT_REMOVEDIR)
                }
            }
            if ownerDescriptor >= 0 { close(ownerDescriptor) }
            if activeDescriptor >= 0 { close(activeDescriptor) }
        }
        activeIdentity = try FileIdentity(name: "active", parent: parent)
        guard activeIdentity?.kind == S_IFDIR else { throw ClaimError.ownershipConflict }
        activeDescriptor = try admissionIO.openActive(parent)
        guard try FileIdentity(descriptor: activeDescriptor) == activeIdentity else { throw ClaimError.ownershipConflict }
        try admissionIO.createOwner(activeDescriptor, ownerName)
        ownerIdentity = try FileIdentity(name: ownerName, parent: activeDescriptor)
        guard ownerIdentity?.kind == S_IFDIR else { throw ClaimError.ownershipConflict }
        ownerDescriptor = openat(activeDescriptor, ownerName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard ownerDescriptor >= 0 else { throw posixError() }
        guard try FileIdentity(descriptor: ownerDescriptor) == ownerIdentity else { throw ClaimError.ownershipConflict }
        if let token = key.reservationID {
            metadataIdentity = try writeExclusive(Owner(version: 1, installationID: installationID, sessionID: Self.sessionID,
                processID: processID, reservationID: token), name: "owner.json", in: ownerDescriptor,
                writer: admissionIO.writeMetadata)
        }
        guard !legacyBlocks(key, explicitRetry: explicitRetry) else { return false }
        let receiptName = receiptURL(for: key, active: active).lastPathComponent
        if mkdirat(parent, receiptName, 0o700) == 0 { retained = true }
        else if errno == EEXIST, explicitRetry {
            let receipt = openat(parent, receiptName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if receipt >= 0 { close(receipt); retained = true }
        } else if errno != EEXIST { throw posixError() }
        return retained
    }

    /// Legacy state only blocks duplicate work. It is never imported as current
    /// ownership or proof, and only the new installation root receives writes.
    private func legacyBlocks(_ key: Key, explicitRetry: Bool) -> Bool {
        guard let legacy = legacyDetector else { return false }
        return legacy.hasActiveReservation(for: key) || (!explicitRetry && legacy.status(for: key) == .registered)
    }

    /// Release only this exact ownership token; immutable pipeline receipts stay.
    func finishHandoff(for key: Key) throws {
        _ = try release(key, expected: nil, requireDeadOwner: false)
    }

    private func release(_ key: Key, expected: ReservationOwner?, requireDeadOwner: Bool = true) throws -> Bool {
        do {
            return try withOwner(key) { descriptor, active, parent in
                let recorded = try? readOwner(descriptor, key: key)
                if let expected {
                    guard recorded == expected,
                          !requireDeadOwner || processState(expected.owner.processID) == .dead else { return false }
                }
                let names = try contents(descriptor)
                // Legacy owners are empty. Unknown files and metadata never get
                // removed to make a reservation fit the expected shape.
                if names.isEmpty { return try removeOwner(key, descriptor: descriptor, active: active, parent: parent) }
                guard let recorded, recorded.owner.installationID == installationID,
                      Set(names) == Set(recorded.runID == nil ? ["owner.json"] : ["owner.json", "run.json"]),
                      try readOwner(descriptor, key: key) == recorded else { throw ClaimError.ownershipConflict }
                if let expected {
                    guard recorded == expected, processState(expected.owner.processID) == .dead || !requireDeadOwner else { return false }
                }
                if recorded.runID != nil, unlinkat(descriptor, "run.json", 0) != 0 { throw posixError() }
                guard unlinkat(descriptor, "owner.json", 0) == 0 else { throw posixError() }
                return try removeOwner(key, descriptor: descriptor, active: active, parent: parent)
            }
        } catch let error as POSIXError where [ENOENT, ELOOP, ENOTDIR].contains(error.code.rawValue) {
            return false
        }
    }

    private func removeOwner(_ key: Key, descriptor: Int32, active: Int32, parent: Int32) throws -> Bool {
        let name = ownerURL(for: key, active: directory).lastPathComponent
        guard sameDirectory(descriptor, named: name, in: active) else { return false }
        guard unlinkat(active, name, AT_REMOVEDIR) == 0 else { throw posixError() }
        if sameDirectory(active, named: "active", in: parent), unlinkat(parent, "active", AT_REMOVEDIR) != 0,
           errno != ENOTEMPTY && errno != EEXIST { throw posixError() }
        return true
    }

    private func sameDirectory(_ descriptor: Int32, named name: String, in parent: Int32) -> Bool {
        var opened = stat(), current = stat()
        return fstat(descriptor, &opened) == 0 && fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0
            && current.st_mode & S_IFMT == S_IFDIR && opened.st_dev == current.st_dev && opened.st_ino == current.st_ino
    }

    private func withOwner<T>(_ key: Key, body: (Int32, Int32, Int32) throws -> T) throws -> T {
        let parent = try reservationParent(for: key, create: false)
        defer { close(parent) }
        let active = openat(parent, "active", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard active >= 0 else { throw posixError() }
        defer { close(active) }
        let owner = openat(active, ownerURL(for: key, active: directory).lastPathComponent,
                           O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard owner >= 0 else { throw posixError() }
        defer { close(owner) }
        return try body(owner, active, parent)
    }

    private func reservationParent(for key: Key, create: Bool) throws -> Int32 {
        let active = try externalRegistrationURL(for: key)
        let components = [active.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                          "project-\(key.projectID)", "mr-\(key.mergeRequestIID)"]
        var descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        do {
            for component in components {
                if create, mkdirat(descriptor, component, 0o700) != 0, errno != EEXIST { throw posixError() }
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw posixError() }
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private func readOwner(_ descriptor: Int32, key: Key) throws -> ReservationOwner {
        let owner: Owner = try read(Owner.self, name: "owner.json", in: descriptor)
        guard owner.version == 1, owner.processID > 0, owner.reservationID == key.reservationID else {
            throw ClaimError.ownershipConflict
        }
        let run: RunBinding?
        do { run = try read(RunBinding.self, name: "run.json", in: descriptor) }
        catch let error as POSIXError where error.code == .ENOENT { run = nil }
        return ReservationOwner(owner: owner, runID: run?.runID)
    }

    private func read<T: Decodable>(_ type: T.Type, name: String, in directory: Int32) throws -> T {
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw posixError() }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size < 4096 else { throw ClaimError.ownershipConflict }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        return try JSONDecoder().decode(type, from: handle.readToEnd() ?? Data())
    }

    @discardableResult
    private func writeExclusive<T: Encodable>(_ value: T, name: String, in directory: Int32,
        writer: @Sendable (Int32, Data) throws -> Void = { descriptor, bytes in
            try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: bytes)
        }) throws -> FileIdentity {
        let bytes = try JSONEncoder().encode(value)
        let file = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw posixError() }
        var identity: FileIdentity?
        var completed = false
        defer {
            if !completed, let identity, identity.matches(name: name, parent: directory) {
                _ = unlinkat(directory, name, 0)
            }
            close(file)
        }
        let created = try FileIdentity(descriptor: file)
        identity = created
        try writer(file, bytes)
        completed = true
        return created
    }

    private func contents(_ descriptor: Int32) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw posixError() }
        guard let stream = fdopendir(copy) else { close(copy); throw posixError() }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private func ownerURL(for key: Key, active: URL) -> URL {
        let suffix = key.reservationID.map { "-" + $0.uuidString.lowercased() } ?? ""
        return active.appending(path: "handoff-\(key.pipelineID)\(suffix)", directoryHint: .isDirectory)
    }

    private func receiptURL(for key: Key, active: URL) -> URL {
        active.deletingLastPathComponent().appending(path: "pipeline-\(key.pipelineID)", directoryHint: .isDirectory)
    }

}
