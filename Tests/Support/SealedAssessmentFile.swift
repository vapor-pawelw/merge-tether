import Foundation
@testable import MergeTether

/// Writes and reads assessment files the way the app does: sealed for the host, MR and note in their path.
enum SealedAssessmentFile {
    static func write(_ payload: Data, to path: URL) throws {
        try EvidenceSeal.seal(payload, context: AICommentAssessmentStore.sealContext(for: path)).write(to: path)
    }

    static func write(_ record: AICommentAssessment, to path: URL) throws {
        try write(JSONEncoder().encode(record), to: path)
    }

    /// The stored record's JSON, whether or not the app could seal it.
    static func payload(at path: URL) throws -> Data {
        let data = try Data(contentsOf: path)
        return EvidenceSeal.open(data, context: AICommentAssessmentStore.sealContext(for: path)) ?? data
    }
}
