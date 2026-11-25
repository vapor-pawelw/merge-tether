import Foundation

/// The user's own verdict on one comment's origin. It is bound to the comment's author
/// and exact body, so editing the comment returns it to automatic assessment.
struct AICommentOriginOverride: Codable, Equatable, Sendable {
    enum Classification: String, Codable, CaseIterable, Sendable { case ai, uncertain, human }

    let version: Int
    let host: String
    let username: String
    let projectID: Int
    let iid: Int
    let noteID: Int
    let authorID: Int
    let bodySHA256: String
    let classification: Classification
    let createdAt: Date
    /// An override that widens automatic publication waits until this moment, so it can still be undone.
    let activatesAt: Date

    func isActive(at now: Date) -> Bool { activatesAt <= now }

    var badge: MRDiscussionSnapshot.OriginBadge {
        switch classification {
        case .ai: .ai
        case .uncertain: .uncertain
        case .human: .human
        }
    }
}

enum AICommentOriginOverrideStore {
    struct Key: Hashable, Sendable {
        let host: String
        let projectID: Int
        let iid: Int
        let noteID: Int
    }

    /// Kept beside the action-authorizing assessments so the publication gate and the display read the same verdict.
    nonisolated static func directory(in assessmentDirectory: URL) -> URL {
        assessmentDirectory.appending(path: ".origin-overrides", directoryHint: .isDirectory)
    }

    nonisolated static func fileURL(_ key: Key, in assessmentDirectory: URL) -> URL {
        directory(in: assessmentDirectory).appending(path: key.host)
            .appending(path: "\(key.projectID)-\(key.iid)-\(key.noteID).json")
    }

    /// Returns the stored record only while it still describes this exact comment.
    nonisolated static func override(for note: GitLabMergeRequestDiscussion.Note, host: String, projectID: Int, iid: Int,
                                      username: String? = nil, in assessmentDirectory: URL) -> AICommentOriginOverride? {
        guard let id = note.id, id > 0, let authorID = note.author?.id, authorID > 0, let body = note.body,
              let record = stored(.init(host: host, projectID: projectID, iid: iid, noteID: id), in: assessmentDirectory),
              record.authorID == authorID, record.bodySHA256 == AICommentAssessmentStore.digest(body),
              username.map({ $0 == record.username }) ?? true else { return nil }
        return record
    }

    nonisolated static func sealContext(_ key: Key) -> String {
        "ai-origin-override:\(key.host):\(key.projectID):\(key.iid):\(key.noteID)"
    }

    /// An unsealed record, such as an older override or one written outside the app, can only narrow
    /// automatic publication. An unsealed AI override is ignored, so the comment returns to assessment.
    nonisolated static func stored(_ key: Key, in assessmentDirectory: URL) -> AICommentOriginOverride? {
        guard let data = try? Data(contentsOf: fileURL(key, in: assessmentDirectory)), data.count < 4096 else { return nil }
        let payload = EvidenceSeal.open(data, context: sealContext(key))
        guard let record = try? decoder.decode(AICommentOriginOverride.self, from: payload ?? data),
              record.version == 1, record.host == key.host, record.projectID == key.projectID,
              record.iid == key.iid, record.noteID == key.noteID, !record.username.isEmpty,
              payload != nil || record.classification != .ai else { return nil }
        return record
    }

    nonisolated static func save(_ record: AICommentOriginOverride, in assessmentDirectory: URL) throws {
        let path = fileURL(.init(host: record.host, projectID: record.projectID, iid: record.iid, noteID: record.noteID),
                           in: assessmentDirectory)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let key = Key(host: record.host, projectID: record.projectID, iid: record.iid, noteID: record.noteID)
        let encoded = try encoder.encode(record)
        let stored: Data
        do { stored = try EvidenceSeal.seal(encoded, context: sealContext(key)) }
        catch {
            // A narrowing override stays effective without the key; widening requires a seal.
            guard record.classification != .ai else { throw error }
            stored = encoded
        }
        try stored.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    nonisolated static func remove(_ key: Key, in assessmentDirectory: URL) throws {
        do { try FileManager.default.removeItem(at: fileURL(key, in: assessmentDirectory)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
    }

    /// Restores exactly what was stored before a change: the earlier override, or none.
    nonisolated static func restore(_ key: Key, to previous: AICommentOriginOverride?, in assessmentDirectory: URL) throws {
        if let previous { try save(previous, in: assessmentDirectory) } else { try remove(key, in: assessmentDirectory) }
    }

    nonisolated private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    nonisolated private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
