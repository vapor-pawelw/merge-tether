import Foundation
@testable import MergeTether

/// Writes and reads assessment files the way the app does: sealed for the host, MR and note in their path.
enum SealedAssessmentFile {
    private static func context(_ path: URL) throws -> String {
        let host = path.deletingLastPathComponent().lastPathComponent
        let parts = path.deletingPathExtension().lastPathComponent.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { throw CocoaError(.fileReadInvalidFileName) }
        return AICommentAssessmentStore.sealContext(host: host, projectID: parts[0], iid: parts[1], noteID: parts[2])
    }

    static func write(_ payload: Data, to path: URL) throws {
        try EvidenceSeal.seal(payload, context: context(path)).write(to: path)
    }

    static func write(_ record: AICommentAssessment, to path: URL) throws {
        try write(JSONEncoder().encode(record), to: path)
    }

    /// The stored record's JSON, whether or not the app could seal it.
    static func payload(at path: URL) throws -> Data {
        let data = try Data(contentsOf: path)
        return EvidenceSeal.open(data, context: try context(path)) ?? data
    }
}
