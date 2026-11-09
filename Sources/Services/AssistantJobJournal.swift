import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Only authenticated, app-validated completions can restore execution state.
@MainActor
enum AssistantJobJournal {
    private struct Checkpoint: Codable {
        let runID: UUID
        let key: AssistantAutomationRunner.ChatKey
        let head: String?
        let result: AssistantJobResult
        let output: String
        let finishedAt: Date
    }
    private struct Sealed: Codable { let payload: Data; let signature: Data }
    private static let testing = Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private static let directory = testing
        ? FileManager.default.temporaryDirectory.appendingPathComponent("MergeTether-CheckpointTests-\(UUID())")
        : URL.homeDirectory.appending(path: "Library/Application Support/MergeTether/Worker Checkpoints")
    private static let keyLoader: AssistantCheckpointKeyLoader = {
        if testing {
            return AssistantCheckpointKeyLoader { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
        }
        return AssistantCheckpointKeyLoader { try? AssistantJobJournal.readKey() }
    }()
    static var isKeyReady: Bool { keyLoader.cached != nil }
    static func hasCheckpoint(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: checkpointURL(for: id).path) }
    static func loadKey() async -> Bool { await keyLoader.key(timeout: .seconds(3)) != nil }
    private static var savedInThisProcess: Set<UUID> = []

    static func checkpointURL(for id: UUID) -> URL { directory.appendingPathComponent("\(id).json") }
    static func didSave(_ id: UUID) -> Bool { savedInThisProcess.contains(id) }
    static func prepare(_ id: UUID) throws {
        savedInThisProcess.remove(id)
        let file = checkpointURL(for: id)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    static func save(_ outcome: AssistantJobCoordinator.Outcome, for handoff: AssistantAutomationRunner.Handoff) async throws {
        guard let bytes = await keyLoader.key(timeout: .seconds(3)) else { throw KeyError(status: errSecInteractionNotAllowed) }
        let signingKey = SymmetricKey(data: bytes)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let checkpoint = Checkpoint(runID: handoff.id, key: handoff.key, head: handoff.expectedHeadSHA,
            result: .init(status: outcome.result.status,
                summary: String(GlabService.redactWorkflowEvidence(outcome.result.summary).prefix(32_000)),
                blocker: outcome.result.blocker.map { String(GlabService.redactWorkflowEvidence($0).prefix(300)) }),
            output: String(GlabService.redactWorkflowEvidence(outcome.output).prefix(262_144)), finishedAt: Date())
        let payload = try JSONEncoder().encode(checkpoint)
        let sealed = Sealed(payload: payload, signature: Data(HMAC<SHA256>.authenticationCode(for: payload, using: signingKey)))
        let file = checkpointURL(for: handoff.id)
        try JSONEncoder().encode(sealed).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        savedInThisProcess.insert(handoff.id)
    }

    static func recover(_ handoff: AssistantAutomationRunner.Handoff, allowCompletion: Bool = true) -> AssistantJobExecution? {
        guard var execution = handoff.execution else { return nil }
        if allowCompletion, let data = boundedData(checkpointURL(for: handoff.id), limit: 1_048_576),
           let sealed = try? JSONDecoder().decode(Sealed.self, from: data),
           let bytes = keyLoader.cached,
           HMAC<SHA256>.isValidAuthenticationCode(sealed.signature, authenticating: sealed.payload, using: SymmetricKey(data: bytes)),
           let checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: sealed.payload),
           checkpoint.runID == handoff.id, checkpoint.key == handoff.key, checkpoint.head == handoff.expectedHeadSHA,
           !checkpoint.result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            execution.state = checkpoint.result.status == .succeeded ? .succeeded : .blocked
            execution.summary = checkpoint.result.summary
            execution.blocker = checkpoint.result.blocker
            execution.output = checkpoint.output
            execution.finishedAt = checkpoint.finishedAt
            execution.error = nil
            return execution
        }
        execution = execution.recoverAfterRestart()
        guard execution.output?.isEmpty != false, let path = execution.workingDirectory else { return execution }
        let folder = URL(fileURLWithPath: path)
        let output = ["stdout", "stderr"].compactMap {
            boundedData(folder.appendingPathComponent("cli-output/\($0)"), limit: 131_072, tail: true)
                .map { String(decoding: $0, as: UTF8.self) }
        }.joined(separator: "\n")
        if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            execution.output = GlabService.redactWorkflowEvidence(output)
        }
        return execution
    }

    private static func boundedData(_ file: URL, limit: Int, tail: Bool = false) -> Data? {
        guard let reader = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? reader.close() }
        if tail, let size = try? reader.seekToEnd() { try? reader.seek(toOffset: size > UInt64(limit) ? size - UInt64(limit) : 0) }
        return try? reader.read(upToCount: limit)
    }

    nonisolated private static func readKey() throws -> Data {
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "MergeTether") + ".worker-checkpoints",
            kSecAttrAccount as String: "signing-v1", kSecUseAuthenticationContext as String: authentication]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &value)
        let data: Data
        if status == errSecItemNotFound {
            data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeyError(status: added) }
        } else {
            guard status == errSecSuccess, let stored = value as? Data, stored.count == 32 else { throw KeyError(status: status) }
            data = stored
        }
        return data
    }
    private struct KeyError: Error { let status: OSStatus }
}

/// Keychain consent must never block startup, result capture, or Quit on the main actor.
@MainActor
final class AssistantCheckpointKeyLoader {
    private(set) var cached: Data?
    private var loading = false
    private let load: @Sendable () -> Data?
    init(load: @escaping @Sendable () -> Data?) { self.load = load }

    func key(timeout: Duration) async -> Data? {
        if let cached { return cached }
        if !loading {
            loading = true
            let read = Task.detached(priority: .utility, operation: load)
            Task { @MainActor [weak self] in
                let value = await read.value
                self?.cached = value
                self?.loading = false
            }
        }
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: timeout)
        while cached == nil && loading && clock.now < deadline {
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cached
    }
}
