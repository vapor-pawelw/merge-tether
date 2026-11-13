import Foundation

/// The latest semantic author-feedback assessment for one merge request, kept across launches so an
/// unchanged snapshot does not repeat a verifier run. `keyDigest` binds every verifier input; any
/// change to the diff, discussion text, decisions or verifier model makes the record a cache miss.
/// A missed record still serves as the prior pass, so already assessed notes gain no new concerns.
enum AuthorFeedbackAssessmentStore {
    struct Record: Codable, Sendable {
        let version: Int
        let target: MRAutomationScope.Target
        let keyDigest: String
        let completedFollowUpJobID: UUID?
        let assessment: ReReviewAssessment
        var noteRevisions: [Int: String]? = nil
        var diffDigest: String? = nil
    }

    nonisolated static let version = 1
    nonisolated static let directory = InstallationStorage.current.evidence
        .appending(path: "author-feedback-assessments", directoryHint: .isDirectory)

    nonisolated static func fileURL(_ target: MRAutomationScope.Target, in directory: URL) -> URL {
        let identity = UserAttentionSnapshot.digest("\(target.host)\n\(target.username)\n\(target.projectID)\n\(target.iid)")
        return directory.appending(path: identity + ".json")
    }

    nonisolated static func load(_ target: MRAutomationScope.Target, keyDigest: String, in directory: URL) -> Record? {
        guard let data = try? Data(contentsOf: fileURL(target, in: directory)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == version, record.target == target, record.keyDigest == keyDigest else { return nil }
        return record
    }

    nonisolated static func latest(_ target: MRAutomationScope.Target, in directory: URL) -> Record? {
        guard let data = try? Data(contentsOf: fileURL(target, in: directory)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == version, record.target == target else { return nil }
        return record
    }

    nonisolated static func save(_ record: Record, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: fileURL(record.target, in: directory), options: .atomic)
    }

    nonisolated static func remove(_ target: MRAutomationScope.Target, in directory: URL) {
        try? FileManager.default.removeItem(at: fileURL(target, in: directory))
    }
}
